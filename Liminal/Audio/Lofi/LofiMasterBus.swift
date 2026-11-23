import AudioKit
import AudioKitEX
import AVFoundation
import Foundation
import OSLog
import Synchronization

/// Final path for the Lo-Fi stems and the film bed, also used by offline graph captures.
///
/// Graph: `input -> glue (Apple) -> trim -> limiter (Apple) -> finisher -> output`.
/// The `finisher` chain bypasses both Apple units, leaves only the slow calibration gain on `trim` and the
/// output fader at 0 dB, and runs `LofiMasterFinisher` (glue, soft clip and the -1 dBTP true-peak limiter;
/// plan section 8.7). When the finisher unit cannot be instantiated, the `fallback` chain runs the Apple
/// glue and sample limiter with a -4.8 dB safety fader and the finisher in pass-through. The chain is
/// fixed when the bus is built.
@MainActor
final class LofiMasterBus {
    enum Chain: String, Sendable { case finisher, fallback }

    // The system sample limiter can miss about 3 dB between samples on phase-offset transients.
    // Match moderate-level gain around the conservative guard so its reserve only costs peak room.
    nonisolated static let safetyTrimDB: Float = -4.8
    private static let nominalInputTrimDB: Float = 3.3
    /// Where live calibration steers the fallback chain.
    nonisolated static let fallbackTargetLUFS: Float = -18
    /// Where live calibration steers the finisher: the `ref` capture's reading at `lofiSettings`
    /// (-13.9 LUFS, 20 November 2026, D121), so calibration is at rest on the reference programme.
    nonisolated static let targetLUFS: Float = -14
    /// Lo-Fi finisher drive and soft-clip threshold (D121, 20 November 2026). The net drive is +2 dB over
    /// the pre-master sum (written as `2 - lofiStagingDB`: the finisher makes the -2 dB staging up first),
    /// into a -12 dB glue threshold and a soft clip that starts at -2 dBFS.
    ///
    /// History: +4 dB net (plan 8.7, wave 2) was the loudest setting that kept C-M6, C-M8 and C-M9 in bounds
    /// on the stems as they were before the per-bus chains. With the bus chains and the D119 strike layer the
    /// kick and bass peaks landed 5.8 dB over the clip threshold: on the 32-bar `ref` capture the clip fired in
    /// 185 bursts, reached its 2 dB cap, and left a -18.9 dB residual in 1-4 kHz while engaged
    /// (`scripts/distortion-report.py`). A hook sweep (+3.5 to +2 dB net, clip at -3 and -2 dBFS) found only
    /// this row passing the distortion gates G1 to G3 (clip at most 0.29 dB, residual while reducing
    /// -51.5 dB): -13.9 LUFS, PLR 12.7 dB, limiter at most 1.13 dB.
    ///
    /// Gain staging (19 November 2026): both branches enter `input` at `lofiStagingDB`, so the pre-master
    /// sum keeps 2 dB of headroom, and the finisher input makes those 2 dB up.
    nonisolated static let lofiSettings: LofiMasterSettings = {
        var settings = LofiMasterSettings.lofi
        settings.inputGainDB = 2 - lofiStagingDB
        settings.glue?.thresholdDB = -12
        settings.clipThresholdDB = -2
        return settings
    }()

    /// Level of both branches into `input`. Both move together, so the film bed keeps its balance against
    /// the music. The finisher makes it up at its input, the fallback chain on `trim`. Captures check that
    /// the pre-master is the staging gain times the sum of the `lofi` and `footage` taps
    /// (`preMasterStagingDb` in `masterDynamics`).
    nonisolated static let lofiStagingDB: Float = -2
    /// The film bed branch and the Lo-Fi bus into `input`.
    let archiveTrim: Fader
    let lofiTrim: Fader
    let input: Mixer
    let glue: Compressor
    let trim: Fader
    let limiter: PeakLimiter
    let finisher: LofiMasterFinisher
    let output: Fader
    /// The chain configured in the graph: `fallback` only when the finisher is not operational.
    let chain: Chain
    let lofiFinisherSettings: LofiMasterSettings
    private var capture: LofiMasterCapture?
    private var calibrationTask: Task<Void, Never>?
    private var calibrationDb: Float = 0
    private var beatDuration = 60.0 / 70.0
    private static var reportedFallback = false

    /// `forceFinisherFallback` builds the finisher's pass-through fallback node (tests).
    init(archive: Node, lofi: Node, forceFinisherFallback: Bool = false) {
        let hooks = LofiCaptureHooks.isEnabled
        lofiFinisherSettings = hooks ? Self.captureOverrides(Self.lofiSettings) : Self.lofiSettings
        archiveTrim = Fader(archive)
        lofiTrim = Fader(lofi)
        input = Mixer(archiveTrim, lofiTrim)
        glue = Compressor(input, threshold: -15, headRoom: 9, attackTime: 0.027, releaseTime: 0.27, masterGain: 0)
        trim = Fader(glue)
        limiter = PeakLimiter(trim, attackTime: 0.005, decayTime: 0.06, preGain: 0)
        finisher = LofiMasterFinisher(limiter, settings: .passthrough, forceFallback: forceFinisherFallback)
        output = Fader(finisher)
        chain = finisher.isOperational ? .finisher : .fallback
        if chain == .fallback && !Self.reportedFallback {
            Self.reportedFallback = true
            LMLog.audio.error("Lo-Fi master finisher unavailable; using the Apple glue and limiter")
        }
        let finishing = chain == .finisher
        glue.avAudioNode.auAudioUnit.shouldBypassEffect = finishing
        limiter.avAudioNode.auAudioUnit.shouldBypassEffect = finishing
        finisher.apply(finishing ? lofiFinisherSettings : .passthrough, ramp: 0)
        archiveTrim.gain = dbToGain(Self.lofiStagingDB)
        lofiTrim.gain = dbToGain(Self.lofiStagingDB)
        trim.gain = dbToGain(trimDB)
        // The system unit is a sample limiter. Leave reconstruction headroom and keep the post node attenuating.
        output.gain = dbToGain(finishing ? 0 : Self.safetyTrimDB)
        if hooks { registerCaptureHooks() }
    }

    /// `trim` without the calibration gain: 0 dB on the finisher; on the fallback chain the nominal input
    /// trim plus the make-up for the staging.
    private var trimDB: Float { chain == .finisher ? 0 : Self.nominalInputTrimDB - Self.lofiStagingDB }

    // MARK: Capture hooks

    /// Harness-only overrides used while choosing the drive (`--hook masterInputGainDb=7`).
    private static func captureOverrides(_ base: LofiMasterSettings) -> LofiMasterSettings {
        var settings = base
        func value(_ key: String) -> Float? { LofiCaptureHooks.option(key).flatMap(Float.init) }
        if let gain = value("masterInputGainDb") { settings.inputGainDB = gain }
        if let threshold = value("masterGlueThresholdDb") { settings.glue?.thresholdDB = threshold }
        if let ratio = value("masterGlueRatio") { settings.glue?.ratio = ratio }
        if let clip = value("masterClipThresholdDb") { settings.clipThresholdDB = clip }
        return settings
    }

    private func registerCaptureHooks() {
        LofiCaptureHooks.tap("master-in", trim.avAudioNode)
        let rate = AudioKit.Settings.audioFormat.sampleRate
        let hop = LofiMasterKernel.traceHopFrames
        finisher.startTrace(capacity: Int(320 * rate) / hop + 2)
        let finisher = finisher
        let profile = chain == .finisher ? "lofi" : "fallback"
        let staging = Double(Self.lofiStagingDB)
        let settings = chain == .finisher ? lofiFinisherSettings : LofiMasterSettings.passthrough
        LofiCaptureHooks.onFinish {
            let meters = finisher.meters
            let trace = finisher.takeTrace()
            func stage(_ value: (mean: Float, p95: Float, max: Float)) -> [String: Double] {
                ["meanDb": Double(value.mean), "p95Db": Double(value.p95), "maxDb": Double(value.max)]
            }
            var clip = stage(meters.clipDB)
            clip["engagedFraction"] = Double(meters.clipEngagedFraction)
            var limiter = stage(meters.limiterDB)
            limiter["above3dbFraction"] = Double(meters.limiterAbove3dBFraction)
            var applied: [String: Any] = ["inputGainDb": Double(settings.inputGainDB),
                                          "highpassHz": settings.highpassHz, "lookaheadSeconds": settings.lookahead,
                                          "limiterEnabled": settings.limiterEnabled]
            if let glue = settings.glue {
                applied["glueThresholdDb"] = Double(glue.thresholdDB)
                applied["glueRatio"] = Double(glue.ratio)
            }
            if let clipThreshold = settings.clipThresholdDB { applied["clipThresholdDb"] = Double(clipThreshold) }
            let dynamics: [String: Any] = [
                "profile": profile, "operational": finisher.isOperational,
                "ceilingDbtp": Double(settings.ceilingDBTP), "latencyFrames": finisher.latencyFrames,
                "preMasterStagingDb": staging,
                "glue": stage(meters.glueDB), "clip": clip, "limiter": limiter,
                "frames": meters.frames, "guardClampCount": meters.guardClampCount,
                "traceFile": "master-gr.csv", "traceHopFrames": hop, "tracePoints": trace.count,
                "settings": applied,
            ]
            LofiCaptureHooks.report("masterDynamics", dynamics)
            LofiCaptureHooks.file("master-gr.csv", LofiMasterBus.traceCSV(trace))
        }
    }

    /// `frame,glue_db,clip_db,limiter_db`, one row per trace point, reductions in positive dB.
    nonisolated static func traceCSV(_ trace: [LofiMasterTracePoint]) -> Data {
        func text(_ value: Float) -> String { String(format: "%.3f", Double(value)) }
        var lines = ["frame,glue_db,clip_db,limiter_db"]
        lines.reserveCapacity(trace.count + 2)
        for point in trace {
            lines.append("\(point.frame),\(text(point.glueDB)),\(text(point.clipDB)),\(text(point.limiterDB))")
        }
        lines.append("")
        return Data(lines.joined(separator: "\n").utf8)
    }

    // MARK: Calibration

    func setCalibrationGain(_ gain: Float, over: Double) {
        ParamRamp.setGain(trim, gain * dbToGain(trimDB), over: over)
    }

    func setCalibrationBeatDuration(_ duration: Double) {
        guard duration.isFinite, duration > 0 else { return }
        beatDuration = duration
        capture?.setBeatDuration(duration)
    }

    func startCalibration() {
        guard capture == nil else { return }
        let node = output.avAudioNode
        let format = node.outputFormat(forBus: 0)
        guard format.channelCount == 2, format.sampleRate >= 8_000,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { return }
        let capture = LofiMasterCapture(sampleRate: format.sampleRate, beatDuration: beatDuration)
        self.capture = capture
        finisher.resetMeters()
        node.installTap(onBus: 0, bufferSize: 4096, format: nil, block: capture.tap)
        calibrationTask = Task { [weak self, capture] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                let gaps = capture.takeClockGaps()
                if gaps > 0 { LMLog.audio.warning("Master PCM tap clock discontinuities: \(gaps)") }
                if let observation = capture.takeObservation() { applyObservation(observation) }
            }
        }
    }

    func stopCalibration() {
        calibrationTask?.cancel()
        calibrationTask = nil
        if capture != nil { output.avAudioNode.removeTap(onBus: 0) }
        capture = nil
        if calibrationDb != 0 {
            calibrationDb = 0
            setCalibrationGain(1, over: 1.5)
        }
    }

    /// One calibration epoch: on the finisher chain it also reads and restarts the finisher's meters.
    func applyObservation(_ result: LofiMasterMeter.Observation) {
        var load: LofiMasterMeter.LimiterLoad?
        if chain == .finisher {
            let meters = finisher.meters
            finisher.resetMeters()
            load = .init(meanDB: meters.limiterDB.mean, p95DB: meters.limiterDB.p95, clipMaxDB: meters.clipDB.max)
        }
        let target = chain == .finisher ? Self.targetLUFS : Self.fallbackTargetLUFS
        let next = LofiMasterMeter.calibratedTrim(current: calibrationDb, observation: result, target: target,
                                                  limiter: load)
        let adjustment = next - calibrationDb
        calibrationDb = next
        setCalibrationGain(dbToGain(calibrationDb), over: 2.5)
        LMLog.audio.info("Master epoch (\(self.chain.rawValue, privacy: .public)): estimated \(result.lufs, format: .fixed(precision: 1)) LUFS, sample peak \(result.samplePeak, format: .fixed(precision: 3)), limiter mean \(load?.meanDB ?? 0, format: .fixed(precision: 2)) dB, trim change \(adjustment, format: .fixed(precision: 2)) dB")
    }

    /// Current slow calibration offset in dB (0 at nominal).
    var calibrationOffsetDB: Float { calibrationDb }
}

/// One writer consumes float PCM in the tap. The main actor only receives complete observations.
nonisolated private final class LofiMasterCapture: @unchecked Sendable {
    private let sampleRate: Double
    private var meter: LofiMasterMeter
    private let requestedFrames = Atomic<Int>(0)
    private let latest = Atomic<UInt64>(0)
    private var nextSample: AVAudioFramePosition?
    private let clockGaps = Atomic<Int>(0)

    func takeClockGaps() -> Int { clockGaps.exchange(0, ordering: .relaxed) }

    init(sampleRate: Double, beatDuration: Double) {
        self.sampleRate = sampleRate
        meter = LofiMasterMeter(sampleRate: sampleRate, epochSeconds: 64 * beatDuration)
    }

    func setBeatDuration(_ seconds: Double) {
        requestedFrames.store(LofiMasterMeter.frames(seconds: 64 * seconds, rate: sampleRate), ordering: .relaxed)
    }

    var tap: AVAudioNodeTapBlock {
        { [self] buffer, timestamp in
            if timestamp.isSampleTimeValid {
                if let nextSample, nextSample != timestamp.sampleTime {
                    clockGaps.wrappingAdd(1, ordering: .relaxed)
                }
                nextSample = timestamp.sampleTime + AVAudioFramePosition(buffer.frameLength)
            }
            guard buffer.format.sampleRate == sampleRate, buffer.format.channelCount == 2,
                  !buffer.format.isInterleaved, let channels = buffer.floatChannelData else { return }
            let left = channels[0], right = channels[1]
            let frames = requestedFrames.exchange(0, ordering: .relaxed)
            if frames > 0 { meter.nextEpochFrames = frames }
            for i in 0..<Int(buffer.frameLength) {
                if let result = meter.add(left: left[i], right: right[i]) {
                    let packed = UInt64(result.lufs.bitPattern) << 32 | UInt64(result.samplePeak.bitPattern)
                    latest.store(packed, ordering: .releasing)
                }
            }
        }
    }

    func takeObservation() -> LofiMasterMeter.Observation? {
        let packed = latest.exchange(0, ordering: .acquiring)
        guard packed != 0 else { return nil }
        return .init(lufs: Float(bitPattern: UInt32(packed >> 32)),
                     samplePeak: Float(bitPattern: UInt32(truncatingIfNeeded: packed)))
    }
}

/// K-weighting shared by the finished-mix meter and the per-cut vocal leveler.
nonisolated struct LofiKWeighting {
    private struct Biquad {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var z1 = 0.0, z2 = 0.0

        @_transparent
        mutating func process(_ x: Double) -> Double {
            let y = z1 + b0 * x
            z1 = z2 + b1 * x - a1 * y
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private var shelf: Biquad
    private var highpass: Biquad

    init(sampleRate: Double) {
        // Bilinear K-weighting realization gives the published 48 kHz response while adapting to other rates.
        let shelfOmega = tan(.pi * 1681.974450955533 / sampleRate)
        let shelfQ = 0.7071752369554196
        let shelfDamping = shelfOmega / shelfQ
        let shelfSquared = shelfOmega * shelfOmega
        let shelfSum = 1 + shelfDamping + shelfSquared
        let highGain = pow(10, 3.999843853973347 / 20)
        let middleGain = pow(highGain, 0.4996667741545416)
        shelf = Biquad(b0: (highGain + middleGain * shelfDamping + shelfSquared) / shelfSum,
                           b1: 2 * (shelfSquared - highGain) / shelfSum,
                           b2: (highGain - middleGain * shelfDamping + shelfSquared) / shelfSum,
                           a1: 2 * (shelfSquared - 1) / shelfSum, a2: (1 - shelfDamping + shelfSquared) / shelfSum)
        let hpOmega = tan(.pi * 38.13547087602444 / sampleRate)
        let hpDamping = hpOmega / 0.5003270373238773
        let hpSquared = hpOmega * hpOmega
        let hpSum = 1 + hpDamping + hpSquared
        highpass = Biquad(b0: 1, b1: -2, b2: 1,
                              a1: 2 * (hpSquared - 1) / hpSum, a2: (1 - hpDamping + hpSquared) / hpSum)
    }

    @_transparent
    mutating func process(_ sample: Double) -> Double { highpass.process(shelf.process(sample)) }
}

/// Bounded stereo loudness estimate for slow gain calibration. External meter qualification is separate.
nonisolated struct LofiMasterMeter {
    struct Observation {
        let lufs: Float
        let samplePeak: Float
    }

    /// Finisher limiter reduction and the soft clip's deepest reduction over one epoch (positive dB).
    struct LimiterLoad: Sendable, Equatable {
        let meanDB: Float
        let p95DB: Float
        var clipMaxDB: Float = 0
        /// Upward steps are held while the limiter already works this hard, or while the soft clip went past
        /// 0.5 dB in the epoch (D121: a quieter programme must not be driven back into the clip; G1 allows
        /// no burst over 1 dB and few over 0.5 dB).
        var blocksUpward: Bool { meanDB > 2.5 || p95DB > 4.5 || clipMaxDB > Self.clipHoldDB }
        /// Past this the trim steps down instead of holding, so a raised trim cannot keep the clip engaged.
        var forcesDownward: Bool { clipMaxDB > Self.clipBackoffDB }
        static let clipHoldDB: Float = 0.5
        static let clipBackoffDB: Float = 1
        static let backoffStepDB: Float = -0.5
    }

    private static let maximumHops = 1_200
    private static let absoluteGate = pow(10, (-70.0 + 0.691) / 10)
    private let hopSize: Int
    private var leftWeight: LofiKWeighting, rightWeight: LofiKWeighting
    private var quarters = [Double](repeating: 0, count: 4)
    private var windows = [Double](repeating: 0, count: maximumHops)
    private var written = 0
    private var hopFrames = 0
    private var accumulated = 0.0
    private var epochIndex = 0
    private var remainingEpochFrames: Int
    private var peak: Float = 0
    var nextEpochFrames: Int

    init(sampleRate: Double, epochSeconds: Double) {
        hopSize = max(1, Int((sampleRate * 0.1).rounded()))
        remainingEpochFrames = Self.frames(seconds: epochSeconds, rate: sampleRate)
        nextEpochFrames = remainingEpochFrames
        leftWeight = LofiKWeighting(sampleRate: sampleRate)
        rightWeight = leftWeight
    }

    static func frames(seconds: Double, rate: Double) -> Int {
        let hop = max(1, Int((rate * 0.1).rounded()))
        return Int((min(Double(maximumHops * hop), max(Double(4 * hop), seconds * rate))).rounded())
    }

    // 400 ms blocks have 75% overlap. The sample peak is an independent check on upward calibration.
    mutating func add(left: Float, right: Float) -> Observation? {
        let a = left.isFinite ? min(2, max(-2, left)) : 0
        let b = right.isFinite ? min(2, max(-2, right)) : 0
        peak = max(peak, abs(a), abs(b))
        let l = leftWeight.process(Double(a))
        let r = rightWeight.process(Double(b))
        accumulated += l * l + r * r
        hopFrames += 1
        remainingEpochFrames -= 1
        if hopFrames == hopSize {
            hopFrames = 0
            quarters[epochIndex % 4] = accumulated
            accumulated = 0
            epochIndex += 1
            if epochIndex >= 4 {
                windows[written] = (quarters[0] + quarters[1] + quarters[2] + quarters[3]) / Double(4 * hopSize)
                written += 1
            }
        }
        guard remainingEpochFrames == 0 else { return nil }
        let result = observation()
        epochIndex = 0
        remainingEpochFrames = nextEpochFrames
        hopFrames = 0
        accumulated = 0
        written = 0
        peak = 0
        return result
    }

    private func observation() -> Observation? {
        func average(over gate: Double) -> Double? {
            var total = 0.0
            var count = 0
            for i in 0..<written where windows[i] >= gate {
                total += windows[i]
                count += 1
            }
            // Require material in at least a quarter of the epoch to avoid turning up a largely silent arrangement.
            return count >= max(1, written / 4) ? total / Double(count) : nil
        }
        guard let open = average(over: Self.absoluteGate),
              let gated = average(over: max(Self.absoluteGate, 0.1 * open)) else { return nil }
        return .init(lufs: Float(-0.691 + 10 * log10(gated)), samplePeak: peak)
    }

    /// One epoch's trim step toward `target`: at most 1 dB per epoch, inside -3 to +2 dB. Without a limiter
    /// load (fallback chain), peaks within 0.5 dB of the sample ceiling block upward steps; with one (Lo-Fi
    /// finisher), heavy limiter reduction or soft-clip reduction over 0.5 dB in the epoch blocks them instead, and soft-clip
    /// reduction over 1 dB steps the trim down by at least 0.5 dB.
    static func calibratedTrim(current: Float, observation: Observation,
                               target: Float = LofiMasterBus.fallbackTargetLUFS,
                               limiter: LimiterLoad? = nil) -> Float {
        guard observation.lufs.isFinite, observation.lufs > -36 else { return current }
        let difference = target - observation.lufs
        let suggested = abs(difference) < 1 ? 0 : min(1, max(-1, difference * 0.4))
        let blocked: Bool
        if let limiter {
            blocked = limiter.blocksUpward
        } else {
            blocked = observation.samplePeak >= dbToGain(LofiMasterBus.safetyTrimDB - 0.5)
        }
        var safe = blocked ? min(0, suggested) : suggested
        if let limiter, limiter.forcesDownward { safe = min(safe, LimiterLoad.backoffStepDB) }
        return min(2, max(-3, current + safe))
    }
}
