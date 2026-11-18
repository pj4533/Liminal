import AudioKit
import AudioKitEX
import AVFoundation
import Foundation
import OSLog
import Synchronization

/// Shared final path for Ambient, Lo-Fi and all archive returns, also used by offline graph captures.
@MainActor
final class LofiMasterBus {
    // The system sample limiter can miss about 3 dB between samples on phase-offset transients.
    // Match moderate-level gain around the conservative guard so its reserve only costs peak room.
    nonisolated static let safetyTrimDB: Float = -4.8
    private static let nominalInputTrimDB: Float = 3.3
    let input: Mixer
    let glue: Compressor
    let trim: Fader
    let limiter: PeakLimiter
    let output: Fader
    private var capture: LofiMasterCapture?
    private var calibrationTask: Task<Void, Never>?
    private var calibrationDb: Float = 0
    private var beatDuration = 60.0 / 70.0

    init(archiveAndAmbient: Node, lofi: Node) {
        input = Mixer(archiveAndAmbient, lofi)
        glue = Compressor(input, threshold: -15, headRoom: 9, attackTime: 0.027, releaseTime: 0.27, masterGain: 0)
        trim = Fader(glue, gain: dbToGain(Self.nominalInputTrimDB))
        limiter = PeakLimiter(trim, attackTime: 0.005, decayTime: 0.06, preGain: 0)
        // The system unit is a sample limiter. Leave reconstruction headroom and keep the post node attenuating.
        output = Fader(limiter, gain: dbToGain(Self.safetyTrimDB))
    }

    func setCalibrationGain(_ gain: Float, over: Double) {
        ParamRamp.setGain(trim, gain * dbToGain(Self.nominalInputTrimDB), over: over)
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
        node.installTap(onBus: 0, bufferSize: 4096, format: nil, block: capture.tap)
        calibrationTask = Task { [weak self, capture] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                if let observation = capture.takeObservation() { applyObservation(observation) }
            }
        }
    }

    func stopCalibration() {
        calibrationTask?.cancel()
        calibrationTask = nil
        if capture != nil { output.avAudioNode.removeTap(onBus: 0) }
        capture = nil
        if calibrationDb != 0 { setCalibrationGain(1, over: 1.5) }
        calibrationDb = 0
    }

    private func applyObservation(_ result: LofiMasterMeter.Observation) {
        let next = LofiMasterMeter.calibratedTrim(current: calibrationDb, observation: result)
        let adjustment = next - calibrationDb
        calibrationDb = next
        setCalibrationGain(dbToGain(calibrationDb), over: 2.5)
        LMLog.audio.info("Lo-Fi mix epoch: estimated \(result.lufs, format: .fixed(precision: 1)) LUFS, sample peak \(result.samplePeak, format: .fixed(precision: 3)), trim change \(adjustment, format: .fixed(precision: 2)) dB")
    }
}

/// One writer consumes float PCM in the tap. The main actor only receives complete observations.
nonisolated private final class LofiMasterCapture: @unchecked Sendable {
    private let sampleRate: Double
    private var meter: LofiMasterMeter
    private let requestedFrames = Atomic<Int>(0)
    private let latest = Atomic<UInt64>(0)

    init(sampleRate: Double, beatDuration: Double) {
        self.sampleRate = sampleRate
        meter = LofiMasterMeter(sampleRate: sampleRate, epochSeconds: 64 * beatDuration)
    }

    func setBeatDuration(_ seconds: Double) {
        requestedFrames.store(LofiMasterMeter.frames(seconds: 64 * seconds, rate: sampleRate), ordering: .relaxed)
    }

    var tap: AVAudioNodeTapBlock {
        { [self] buffer, _ in
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

/// Bounded stereo loudness estimate for slow gain calibration. External meter qualification is separate.
nonisolated struct LofiMasterMeter {
    struct Observation {
        let lufs: Float
        let samplePeak: Float
    }

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

    private static let maximumHops = 1_200
    private static let absoluteGate = pow(10, (-70.0 + 0.691) / 10)
    private let hopSize: Int
    private var shelfL: Biquad, shelfR: Biquad
    private var highpassL: Biquad, highpassR: Biquad
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
        // Bilinear K-weighting realization gives the published 48 kHz response while adapting to other rates.
        let shelfOmega = tan(.pi * 1681.974450955533 / sampleRate)
        let shelfQ = 0.7071752369554196
        let shelfDamping = shelfOmega / shelfQ
        let shelfSquared = shelfOmega * shelfOmega
        let shelfSum = 1 + shelfDamping + shelfSquared
        let highGain = pow(10, 3.999843853973347 / 20)
        let middleGain = pow(highGain, 0.4996667741545416)
        let shelf = Biquad(b0: (highGain + middleGain * shelfDamping + shelfSquared) / shelfSum,
                           b1: 2 * (shelfSquared - highGain) / shelfSum,
                           b2: (highGain - middleGain * shelfDamping + shelfSquared) / shelfSum,
                           a1: 2 * (shelfSquared - 1) / shelfSum, a2: (1 - shelfDamping + shelfSquared) / shelfSum)
        shelfL = shelf
        shelfR = shelf
        let hpOmega = tan(.pi * 38.13547087602444 / sampleRate)
        let hpDamping = hpOmega / 0.5003270373238773
        let hpSquared = hpOmega * hpOmega
        let hpSum = 1 + hpDamping + hpSquared
        let highpass = Biquad(b0: 1, b1: -2, b2: 1,
                              a1: 2 * (hpSquared - 1) / hpSum, a2: (1 - hpDamping + hpSquared) / hpSum)
        highpassL = highpass
        highpassR = highpass
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
        let l = highpassL.process(shelfL.process(Double(a)))
        let r = highpassR.process(shelfR.process(Double(b)))
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

    static func calibratedTrim(current: Float, observation: Observation) -> Float {
        guard observation.lufs.isFinite, observation.lufs > -36 else { return current }
        let target: Float = -18
        let difference = target - observation.lufs
        let suggested = abs(difference) < 1 ? 0 : min(1, max(-1, difference * 0.4))
        // Peaks already within 0.5 dB of the sample ceiling block any upward calibration.
        let nearCeiling = observation.samplePeak >= dbToGain(LofiMasterBus.safetyTrimDB - 0.5)
        let safe = nearCeiling ? min(0, suggested) : suggested
        return min(2, max(-3, current + safe))
    }
}
