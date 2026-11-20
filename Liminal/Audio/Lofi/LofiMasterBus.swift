import AudioKit
import AudioKitEX
import AVFoundation
import Foundation
import OSLog
import Synchronization

/// Shared final path for Ambient, Lo-Fi and all archive returns, also used by offline graph captures.
///
/// Graph: `input -> glue (Apple) -> trim -> limiter (Apple) -> finisher -> output`.
/// `ambient` keeps the legacy chain (Apple glue and sample limiter, -4.8 dB safety fader) with the
/// finisher in pass-through, so it only adds the finisher's constant delay. `lofi` bypasses both Apple
/// units, leaves only the slow calibration gain on `trim` and the output fader at 0 dB, and runs
/// `LofiMasterFinisher` (glue, soft clip and the -1 dBTP true-peak limiter; plan section 8.7).
@MainActor
final class LofiMasterBus {
    enum Profile: String, Sendable { case ambient, lofi }

    // The system sample limiter can miss about 3 dB between samples on phase-offset transients.
    // Match moderate-level gain around the conservative guard so its reserve only costs peak room.
    nonisolated static let safetyTrimDB: Float = -4.8
    private static let nominalInputTrimDB: Float = 3.3
    nonisolated static let ambientTargetLUFS: Float = -18
    nonisolated static let lofiTargetLUFS: Float = -12
    /// Default length of each half of a profile change (fade down, swap, fade up).
    nonisolated static let switchRamp: Double = 0.04
    /// Lo-Fi finisher drive, chosen on the 32-bar `ref` capture (plan 8.7, wave 2) with the stems as they were
    /// before the per-bus chains: +4 dB into a -12 dB glue threshold is the loudest setting found that keeps
    /// soft-clip use (C-M9), kick-synchronous dips (C-M8) and limiter reduction (C-M6) inside their bounds
    /// with some margin (-12.5 LUFS). The section 8.7 start (+6 dB, -14 dB) reached -11.7 LUFS but failed
    /// C-M8 and C-M9 on the raw drum peaks. Revisit once the drum bus chain controls those peaks.
    nonisolated static let lofiSettings: LofiMasterSettings = {
        var settings = LofiMasterSettings.lofi
        settings.inputGainDB = 4
        settings.glue?.thresholdDB = -12
        return settings
    }()

    let input: Mixer
    let glue: Compressor
    let trim: Fader
    let limiter: PeakLimiter
    let finisher: LofiMasterFinisher
    let output: Fader
    /// The requested profile. The applied chain (`activeChain`) is `ambient` when the finisher is not operational.
    private(set) var profile: Profile
    /// The chain currently configured in the graph.
    private(set) var activeChain: Profile
    let lofiFinisherSettings: LofiMasterSettings
    private var switchTask: Task<Void, Never>?
    private var capture: LofiMasterCapture?
    private var calibrationTask: Task<Void, Never>?
    private var calibrationDb: Float = 0
    private var beatDuration = 60.0 / 70.0
    private static var reportedFallback = false
    private let renderedFrames = LofiRenderedFrames()

    convenience init(archiveAndAmbient: Node, lofi: Node) {
        self.init(archiveAndAmbient: archiveAndAmbient, lofi: lofi, forceFinisherFallback: false)
    }

    /// `forceFinisherFallback` builds the finisher's pass-through fallback node (tests).
    init(archiveAndAmbient: Node, lofi: Node, forceFinisherFallback: Bool) {
        let hooks = LofiCaptureHooks.isEnabled
        let requested: Profile = hooks
            ? LofiCaptureHooks.option("masterProfile").flatMap(Profile.init(rawValue:)) ?? .lofi
            : .ambient
        lofiFinisherSettings = hooks ? Self.captureOverrides(Self.lofiSettings) : Self.lofiSettings
        input = Mixer(archiveAndAmbient, lofi)
        glue = Compressor(input, threshold: -15, headRoom: 9, attackTime: 0.027, releaseTime: 0.27, masterGain: 0)
        let finisherReady = !forceFinisherFallback
        let chain: Profile = requested == .lofi && finisherReady ? .lofi : .ambient
        trim = Fader(glue, gain: dbToGain(Self.nominalTrimDB(chain)))
        limiter = PeakLimiter(trim, attackTime: 0.005, decayTime: 0.06, preGain: 0)
        finisher = LofiMasterFinisher(limiter, settings: .passthrough, forceFallback: forceFinisherFallback)
        // The system unit is a sample limiter. Leave reconstruction headroom and keep the post node attenuating.
        output = Fader(finisher, gain: dbToGain(Self.outputDB(chain)))
        profile = requested
        activeChain = .ambient
        let applied = Self.chain(for: requested, operational: finisher.isOperational)
        if applied == .lofi {
            configure(.lofi)
        } else if chain == .lofi {
            // The unit failed to instantiate after all: restore the Ambient gains.
            trim.gain = dbToGain(Self.nominalInputTrimDB)
            output.gain = dbToGain(Self.safetyTrimDB)
        }
        _ = output.avAudioNode.auAudioUnit.token(byAddingRenderObserver: Self.renderObserver(renderedFrames))
        if hooks { registerCaptureHooks() }
    }

    // MARK: Profiles

    private static func chain(for profile: Profile, operational: Bool) -> Profile {
        guard profile == .lofi, !operational else { return profile }
        if !reportedFallback {
            reportedFallback = true
            LMLog.audio.error("Lo-Fi master finisher unavailable; Lo-Fi uses the Ambient master chain")
        }
        return .ambient
    }

    private static func outputDB(_ chain: Profile) -> Float { chain == .lofi ? 0 : safetyTrimDB }
    private static func nominalTrimDB(_ chain: Profile) -> Float { chain == .lofi ? 0 : nominalInputTrimDB }

    /// Selects a profile. With `ramp > 0` while the graph renders, the output fades to silence over `ramp`,
    /// the chain is swapped once that fade has been rendered, and the output rises to the new level over
    /// `ramp`. The output is therefore lowered before the protection changes and raised only after the new
    /// chain is in place, and the latency difference between the chains never reaches the output as a step.
    /// With `ramp == 0` or a graph that is not rendering, the change is immediate.
    func setProfile(_ requested: Profile, ramp: Double) {
        profile = requested
        let target = Self.chain(for: requested, operational: finisher.isOperational)
        let switching = switchTask != nil
        switchTask?.cancel()
        switchTask = nil
        guard target != activeChain || switching else { return }
        guard ramp > 0, output.avAudioNode.engine?.isRunning == true else {
            configure(target)
            output.gain = dbToGain(Self.outputDB(target))
            return
        }
        let fade = max(ParamRamp.minimum, ramp)
        let rate = output.avAudioNode.outputFormat(forBus: 0).sampleRate
        // A ramp starts at the next render cycle; allow for the largest slice in use (visionOS: 100 ms).
        let slice = max(4096, Int(0.1 * rate))
        let frames = Int((fade * rate).rounded()) + slice
        let start = renderedFrames.value
        ParamRamp.setGain(output, 0, over: fade)
        switchTask = Task { [weak self] in
            guard let self else { return }
            await waitForRender(until: start + frames)
            guard !Task.isCancelled else { return }
            configure(target)
            // Re-enabled Apple units start from empty delay lines: let their onset pass while still silent.
            let settle = renderedFrames.value + slice + Int((latencySeconds * rate).rounded())
            await waitForRender(until: settle)
            guard !Task.isCancelled else { return }
            ParamRamp.setGain(output, dbToGain(Self.outputDB(target)), over: fade)
            switchTask = nil
        }
    }

    /// True while a ramped profile change is in progress (the output is fading or held silent).
    var isSwitchingProfile: Bool { switchTask != nil }

    /// Reported latency of every unit in the chain (the Apple units report theirs even when bypassed).
    private var latencySeconds: Double {
        [glue.avAudioNode, limiter.avAudioNode, finisher.avAudioNode].map(\.auAudioUnit.latency).reduce(0, +)
    }

    /// Waits until the output has rendered `frame` frames in total, or for one second of wall time without
    /// progress (the output is already faded, so applying then is still safe).
    private func waitForRender(until frame: Int) async {
        var last = renderedFrames.value
        var deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            let now = renderedFrames.value
            if now >= frame { return }
            if now != last {
                last = now
                deadline = ContinuousClock.now + .seconds(1)
            }
            do { try await Task.sleep(for: .milliseconds(2)) } catch { return }
        }
    }

    /// Render observer on the output fader: counts rendered frames with one relaxed atomic add.
    nonisolated private static func renderObserver(_ counter: LofiRenderedFrames) -> AURenderObserver {
        { flags, _, frameCount, _ in
            if flags.contains(.unitRenderAction_PostRender) { counter.add(Int(frameCount)) }
        }
    }

    private func configure(_ chain: Profile) {
        let lofi = chain == .lofi
        glue.avAudioNode.auAudioUnit.shouldBypassEffect = lofi
        limiter.avAudioNode.auAudioUnit.shouldBypassEffect = lofi
        finisher.apply(lofi ? lofiFinisherSettings : .passthrough, ramp: 0)
        activeChain = chain
        trim.gain = dbToGain(calibrationDb) * dbToGain(Self.nominalTrimDB(chain))
    }

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
        let chain = activeChain.rawValue
        let requested = profile.rawValue
        let settings = activeChain == .lofi ? lofiFinisherSettings : LofiMasterSettings.passthrough
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
                "profile": chain, "requestedProfile": requested, "operational": finisher.isOperational,
                "ceilingDbtp": Double(settings.ceilingDBTP), "latencyFrames": finisher.latencyFrames,
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
        ParamRamp.setGain(trim, gain * dbToGain(Self.nominalTrimDB(activeChain)), over: over)
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

    /// One calibration epoch: in the Lo-Fi chain it also reads and restarts the finisher's meters.
    func applyObservation(_ result: LofiMasterMeter.Observation) {
        var load: LofiMasterMeter.LimiterLoad?
        if activeChain == .lofi {
            let meters = finisher.meters
            finisher.resetMeters()
            load = .init(meanDB: meters.limiterDB.mean, p95DB: meters.limiterDB.p95)
        }
        let target = activeChain == .lofi ? Self.lofiTargetLUFS : Self.ambientTargetLUFS
        let next = LofiMasterMeter.calibratedTrim(current: calibrationDb, observation: result, target: target,
                                                  limiter: load)
        let adjustment = next - calibrationDb
        calibrationDb = next
        setCalibrationGain(dbToGain(calibrationDb), over: 2.5)
        LMLog.audio.info("Master epoch (\(self.activeChain.rawValue, privacy: .public)): estimated \(result.lufs, format: .fixed(precision: 1)) LUFS, sample peak \(result.samplePeak, format: .fixed(precision: 3)), limiter mean \(load?.meanDB ?? 0, format: .fixed(precision: 2)) dB, trim change \(adjustment, format: .fixed(precision: 2)) dB")
    }

    /// Current slow calibration offset in dB (0 at nominal).
    var calibrationOffsetDB: Float { calibrationDb }
}

/// Frames rendered by the master output, written by its render observer and read on the main actor.
nonisolated final class LofiRenderedFrames: Sendable {
    private let frames = Atomic<Int>(0)
    func add(_ count: Int) { frames.wrappingAdd(count, ordering: .relaxed) }
    var value: Int { frames.load(ordering: .relaxed) }
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

    mutating func process(_ sample: Double) -> Double { highpass.process(shelf.process(sample)) }
}

/// Bounded stereo loudness estimate for slow gain calibration. External meter qualification is separate.
nonisolated struct LofiMasterMeter {
    struct Observation {
        let lufs: Float
        let samplePeak: Float
    }

    /// Finisher limiter reduction over one epoch (positive dB).
    struct LimiterLoad: Sendable, Equatable {
        let meanDB: Float
        let p95DB: Float
        /// Upward steps are held while the limiter already works this hard.
        var blocksUpward: Bool { meanDB > 2.5 || p95DB > 4.5 }
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
    /// load (Ambient chain), peaks within 0.5 dB of the sample ceiling block upward steps; with one (Lo-Fi
    /// finisher), heavy limiter reduction over the epoch blocks them instead.
    static func calibratedTrim(current: Float, observation: Observation,
                               target: Float = LofiMasterBus.ambientTargetLUFS,
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
        let safe = blocked ? min(0, suggested) : suggested
        return min(2, max(-3, current + safe))
    }
}
