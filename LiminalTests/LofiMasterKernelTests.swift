import Accelerate
import AudioKit
import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// Realtime master finisher: ceiling under reconstruction, timing, transparency, meters and the AU wrapper.
struct LofiMasterKernelTests {
    static let rate = 48_000.0

    // MARK: Signals

    struct Noise {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2_000_001) / 1_000_000 - 1
        }
    }

    static func sine(_ hz: Double, amplitude: Float, count: Int, phase: Double = 0) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / rate + phase)) }
    }

    static let ceilingGain = dbToGain(-1)

    /// Stress cases (left, right): 1.5 s of signal that stops abruptly, then 0.1 s of silence so the
    /// stop itself (and its reconstruction overshoot) passes through the limiter.
    static func stressSet() -> [(String, [Float], [Float])] {
        let tail = [Float](repeating: 0, count: Int(rate * 0.1))
        return stressSignals().map { ($0.0, $0.1 + tail, $0.2 + tail) }
    }

    static func stressSignals() -> [(String, [Float], [Float])] {
        let count = Int(rate * 1.5)
        var cases: [(String, [Float], [Float])] = []

        var burstsL = [Float](repeating: 0, count: count), burstsR = burstsL
        for (k, i) in stride(from: 1_000, to: count - 1_000, by: 2_400).enumerated() {
            burstsL[i] = (k.isMultiple(of: 2) ? 1 : -1) * 2.0
            burstsR[i + (k % 3)] = (k.isMultiple(of: 3) ? -1 : 1) * 1.4
        }
        cases.append(("single-sample bursts", burstsL, burstsR))

        var closeL = [Float](repeating: 0, count: count), closeR = closeL
        for start in stride(from: 2_000, to: count - 2_000, by: 4_800) {
            for (j, offset) in [0, 3, 7, 20, 45, 46, 90].enumerated() {
                let sign: Float = j.isMultiple(of: 2) ? 1 : -1
                closeL[start + offset] = sign * 1.6
                closeR[start + offset + 1] = -sign * 1.2
            }
        }
        cases.append(("closely spaced transients", closeL, closeR))

        let high = ceilingGain * dbToGain(6)
        cases.append(("phase-offset 12 kHz +6 dB", sine(12_000, amplitude: high, count: count, phase: .pi / 4),
                      sine(12_000, amplitude: high, count: count, phase: .pi / 4 + 0.37)))

        let bass = ceilingGain * dbToGain(8)
        cases.append(("57 Hz bass +8 dB", sine(57, amplitude: bass, count: count),
                      sine(57, amplitude: bass * 0.9, count: count, phase: 0.2)))

        let a = sine(3_000, amplitude: 1.2, count: count), b = sine(700, amplitude: 0.9, count: count, phase: 1)
        let mixed = zip(a, b).map { $0 + $1 }
        cases.append(("antiphase stereo", mixed, mixed.map { -$0 }))

        var noise = Noise(state: 99)
        var b0: Float = 0, b1: Float = 0, b2: Float = 0
        var pinkL = [Float](repeating: 0, count: count), pinkR = pinkL
        for i in 0..<count {
            let w = noise.next()
            b0 = 0.99765 * b0 + w * 0.0990460
            b1 = 0.96300 * b1 + w * 0.2965164
            b2 = 0.57000 * b2 + w * 1.0526913
            pinkL[i] = b0 + b1 + b2 + w * 0.1848
            pinkR[i] = 0.7 * pinkL[i] + 0.3 * noise.next()
        }
        let pinkPeak = max(vDSP.maximumMagnitude(pinkL), vDSP.maximumMagnitude(pinkR))
        let scale = ceilingGain * dbToGain(10) / pinkPeak
        cases.append(("pink-ish noise +10 dB", pinkL.map { $0 * scale }, pinkR.map { $0 * scale }))
        return cases
    }

    /// Independent 16x reconstruction: Blackman-Harris windowed sinc, 48 taps each side, per-phase DC normalized.
    static func reconstructedPeak(_ x: [Float]) -> Float {
        let radius = 48, taps = 2 * radius + 1
        let padded = [Float](repeating: 0, count: radius) + x + [Float](repeating: 0, count: radius)
        var result = vDSP.maximumMagnitude(x)
        var filtered = [Float](repeating: 0, count: x.count)
        for phase in 1..<16 {
            let fraction = Double(phase) / 16
            var kernel = (0..<taps).map { tap -> Double in
                let delta = Double(tap - radius) - fraction
                let position = (delta + Double(radius + 1)) / Double(2 * radius + 2)   // 0...1 across the window
                let t = 2 * Double.pi * position
                let window = 0.35875 - 0.48829 * cos(t) + 0.14128 * cos(2 * t) - 0.01168 * cos(3 * t)
                return window * (abs(delta) < 1e-12 ? 1 : sin(.pi * delta) / (.pi * delta))
            }
            let total = kernel.reduce(0, +)
            kernel = kernel.map { $0 / total }
            let k = kernel.map(Float.init)
            vDSP_conv(padded, 1, k, 1, &filtered, 1, vDSP_Length(x.count), vDSP_Length(taps))
            result = max(result, vDSP.maximumMagnitude(filtered))
        }
        return result
    }

    static func dbtp(_ left: [Float], _ right: [Float]) -> Float {
        20 * log10f(max(reconstructedPeak(left), reconstructedPeak(right), 1e-12))
    }

    static var limiterOnly: LofiMasterSettings {
        var s = LofiMasterSettings.passthrough
        s.limiterEnabled = true
        return s
    }

    // MARK: Ceiling

    @Test func stressSetStaysUnderTheCeilingByReconstructionWithoutGuardClamps() {
        for (label, settings) in [("lofi", LofiMasterSettings.lofi), ("limiter only", Self.limiterOnly)] {
            for (name, left, right) in Self.stressSet() {
                let out = LofiMasterKernel.processOffline(left: left, right: right, settings: settings,
                                                          sampleRate: Self.rate, blockSize: 512)
                let peak = Self.dbtp(out.left, out.right)
                let sample = 20 * log10f(max(vDSP.maximumMagnitude(out.left), vDSP.maximumMagnitude(out.right)))
                print("Master stress [\(label)] \(name): out \(peak) dBTP (sample \(sample)), limiter mean \(out.meters.limiterDB.mean) max \(out.meters.limiterDB.max), clip max \(out.meters.clipDB.max), guard \(out.meters.guardClampCount)")
                #expect(peak <= -0.95, "\(label) \(name) reconstructed \(peak) dBTP")
                #expect(out.meters.guardClampCount == 0, "\(label) \(name) guard clamps")
                #expect(out.left.allSatisfy(\.isFinite) && out.right.allSatisfy(\.isFinite))
            }
        }
    }

    // MARK: Timing and transparency

    @Test func outputIsIdenticalAcrossBlockSizes() {
        var signalL = [Float](), signalR = [Float]()
        for (_, l, r) in Self.stressSet() {
            signalL += l
            signalR += r
        }
        let reference = LofiMasterKernel.processOffline(left: signalL, right: signalR, settings: .lofi,
                                                        sampleRate: Self.rate, blockSize: 64)
        for size in [256, 1_024, 4_096] {
            let other = LofiMasterKernel.processOffline(left: signalL, right: signalR, settings: .lofi,
                                                        sampleRate: Self.rate, blockSize: size)
            let error = max(zip(reference.left, other.left).map { abs($0 - $1) }.max() ?? 1,
                            zip(reference.right, other.right).map { abs($0 - $1) }.max() ?? 1)
            print("Block size \(size) versus 64: max difference \(error)")
            #expect(error <= 1e-6)
            #expect(abs(reference.meters.limiterDB.mean - other.meters.limiterDB.mean) < 1e-3)
            #expect(reference.trace.count == other.trace.count)
        }
    }

    @Test func reportedLatencyEqualsTheMeasuredImpulseDelay() {
        for rate in [48_000.0, 44_100] {
            let kernel = LofiMasterKernel(sampleRate: rate, maximumFrames: 512)
            let expected = 32 + LofiMasterKernel.peakTapsPerPhase / 2 + Int((0.003 * rate).rounded())
            #expect(kernel.latencyFrames == expected)
            for settings in [LofiMasterSettings.passthrough, .lofi] {
                var impulse = [Float](repeating: 0, count: 4_000)
                impulse[1_000] = 0.1
                let out = LofiMasterKernel.processOffline(left: impulse, right: impulse, settings: settings,
                                                          sampleRate: rate, blockSize: 512)
                let index = out.left.indices.max { abs(out.left[$0]) < abs(out.left[$1]) } ?? -1
                print("Latency at \(rate) Hz: reported \(kernel.latencyFrames) frames, measured \(index - 1_000)")
                #expect(index - 1_000 == kernel.latencyFrames)
            }
        }
    }

    @Test func passthroughNullsAgainstTheDelayedInput() {
        var noise = Noise(state: 3)
        let count = 48_000
        let left = (0..<count).map { i in (i % 9_000 == 0 ? 3 : 0.9) * noise.next() }
        let right = (0..<count).map { _ in 0.5 * noise.next() }
        let out = LofiMasterKernel.processOffline(left: left, right: right, settings: .passthrough,
                                                  sampleRate: Self.rate, blockSize: 333)
        let latency = LofiMasterKernel(sampleRate: Self.rate, maximumFrames: 64).latencyFrames
        var error: Float = 0
        for i in 0..<(count - latency) {
            error = max(error, abs(out.left[i + latency] - left[i]), abs(out.right[i + latency] - right[i]))
        }
        #expect(error <= 1e-6)
        #expect(out.left[0..<latency].allSatisfy { $0 == 0 })
        #expect(out.meters.limiterDB.max == 0 && out.meters.guardClampCount == 0)
    }

    @Test func limiterIsTransparentBelowTheCeiling() {
        var noise = Noise(state: 11)
        let count = 48_000
        let raw = (0..<count).map { _ in noise.next() }
        let scale = dbToGain(-6) / Self.reconstructedPeak(raw)
        let left = raw.map { $0 * scale }, right = left.reversed().map { $0 }
        let out = LofiMasterKernel.processOffline(left: left, right: right, settings: Self.limiterOnly,
                                                  sampleRate: Self.rate, blockSize: 512)
        let latency = LofiMasterKernel(sampleRate: Self.rate, maximumFrames: 64).latencyFrames
        var error: Float = 0
        for i in 0..<(count - latency) {
            error = max(error, abs(out.left[i + latency] - left[i]), abs(out.right[i + latency] - right[i]))
        }
        #expect(error <= 1e-6)
        #expect(out.meters.limiterDB.max < 1e-4)
    }

    // MARK: Quality

    @Test func lofiSettingsKeepDistortionLowAtNominalLevel() {
        var settings = LofiMasterSettings.lofi
        settings.inputGainDB = 0
        let count = Int(Self.rate * 2)
        let input = Self.sine(1_000, amplitude: dbToGain(-12), count: count)
        let out = LofiMasterKernel.processOffline(left: input, right: input, settings: settings,
                                                  sampleRate: Self.rate, blockSize: 512)
        let range = Int(Self.rate)..<count
        func amplitude(_ hz: Double) -> Double {
            var re = 0.0, im = 0.0
            let w = 2 * Double.pi * hz / Self.rate
            for i in range {
                re += Double(out.left[i]) * cos(w * Double(i))
                im -= Double(out.left[i]) * sin(w * Double(i))
            }
            return 2 * (re * re + im * im).squareRoot() / Double(range.count)
        }
        let fundamental = amplitude(1_000)
        let harmonics = (2...10).map { amplitude(Double($0) * 1_000) }
        let thd = (harmonics.map { $0 * $0 }.reduce(0, +)).squareRoot() / fundamental
        print("THD 1 kHz at -12 dBFS (lofi, 0 dB input gain): \(thd * 100) %, glue mean \(out.meters.glueDB.mean) dB")
        #expect(thd <= 0.01)
    }

    @Test func metersAndTraceReportAKnownSixDecibelReduction() {
        var settings = Self.limiterOnly
        settings.ceilingDBTP = -1
        let internalCeiling = dbToGain(-1 - settings.ceilingMarginDB)
        let count = Int(Self.rate * 4)
        let input = Self.sine(1_000, amplitude: internalCeiling * dbToGain(6), count: count)
        let out = LofiMasterKernel.processOffline(left: input, right: input, settings: settings,
                                                  sampleRate: Self.rate, blockSize: 512)
        let m = out.meters
        print("Known 6 dB: limiter mean \(m.limiterDB.mean) p95 \(m.limiterDB.p95) max \(m.limiterDB.max) above3 \(m.limiterAbove3dBFraction) frames \(m.frames) trace \(out.trace.count)")
        #expect(abs(m.limiterDB.mean - 6) < 0.3)
        #expect(abs(m.limiterDB.p95 - 6) < 0.3)
        #expect(abs(m.limiterDB.max - 6) < 0.3)
        #expect(m.limiterAbove3dBFraction > 0.98)
        #expect(m.frames == count)
        #expect(m.glueDB.max == 0 && m.clipDB.max == 0 && m.clipEngagedFraction == 0)
        #expect(out.trace.count == count / LofiMasterKernel.traceHopFrames)
        let middle = out.trace[out.trace.count / 4..<(3 * out.trace.count / 4)]
        #expect(middle.allSatisfy { abs($0.limiterDB - 6) < 0.3 && $0.glueDB == 0 })
        #expect(zip(out.trace, out.trace.dropFirst()).allSatisfy { $1.frame - $0.frame == LofiMasterKernel.traceHopFrames })
        // Output level is the internal ceiling.
        let settled = Array(out.left[Int(Self.rate)...])
        #expect(abs(20 * log10f(vDSP.maximumMagnitude(settled) / internalCeiling)) < 0.05)
    }

    @Test func gainNeverExceedsUnityAfterTheInputGain() {
        for (_, left, right) in Self.stressSet() {
            let out = LofiMasterKernel.processOffline(left: left, right: right, settings: .lofi,
                                                      sampleRate: Self.rate, blockSize: 512)
            #expect(out.trace.allSatisfy { $0.glueDB >= 0 && $0.clipDB >= 0 && $0.limiterDB >= 0 })
            #expect(out.meters.glueDB.mean >= 0 && out.meters.clipDB.mean >= 0 && out.meters.limiterDB.mean >= 0)
        }
        // A quiet tone well under every threshold comes out at the input gain, not above it.
        var settings = LofiMasterSettings.lofi
        settings.inputGainDB = 0
        let input = Self.sine(440, amplitude: dbToGain(-40), count: 48_000)
        let out = LofiMasterKernel.processOffline(left: input, right: input, settings: settings,
                                                  sampleRate: Self.rate, blockSize: 512)
        let change = 20 * log10f(vDSP.rootMeanSquare(Array(out.left[24_000...])) / vDSP.rootMeanSquare(Array(input[24_000...])))
        #expect(change <= 0.01 && change > -0.2)
    }

    @Test func nonFiniteDenormalAndSilentInputStayFinite() {
        let count = 12_000
        var left = [Float](repeating: 0, count: count), right = left
        for i in 0..<count {
            switch i % 7 {
            case 0: left[i] = .nan
            case 1: left[i] = .infinity
            case 2: left[i] = -.infinity
            case 3: left[i] = 1e-40
            case 4: left[i] = Float.leastNonzeroMagnitude
            default: left[i] = 0
            }
            right[i] = i < 6_000 ? 0 : (i.isMultiple(of: 5) ? .nan : 0.5)
        }
        let tail = Self.sine(1_000, amplitude: 0.5, count: 12_000)
        let out = LofiMasterKernel.processOffline(left: left + tail, right: right + tail, settings: .lofi,
                                                  sampleRate: Self.rate, blockSize: 256)
        #expect(out.left.allSatisfy(\.isFinite) && out.right.allSatisfy(\.isFinite))
        #expect(vDSP.maximumMagnitude(Array(out.left[18_000...])) > 0.3)
        let silent = [Float](repeating: 0, count: 8_000)
        let quiet = LofiMasterKernel.processOffline(left: silent, right: silent, settings: .lofi,
                                                    sampleRate: Self.rate, blockSize: 512)
        #expect(quiet.left.allSatisfy { $0 == 0 } && quiet.meters.limiterDB.max == 0)
    }

    @Test func settingsChangesRampWithoutSteps() {
        let count = Int(Self.rate * 2)
        let input = Self.sine(1_000, amplitude: dbToGain(-20), count: count)
        let kernel = LofiMasterKernel(sampleRate: Self.rate, maximumFrames: 512, settings: .passthrough)
        var out = [Float](repeating: 0, count: count), outR = out
        var offset = 0
        input.withUnsafeBufferPointer { x in
            out.withUnsafeMutableBufferPointer { o in
                outR.withUnsafeMutableBufferPointer { r in
                    while offset < count {
                        if offset == 48_128 { kernel.apply(.lofi, ramp: 0.05) }
                        kernel.process(inL: x.baseAddress! + offset, inR: x.baseAddress! + offset,
                                       outL: o.baseAddress! + offset, outR: r.baseAddress! + offset, count: 512)
                        offset += 512
                    }
                }
            }
        }
        // Second difference of a 1 kHz sine is about 0.0171 of its amplitude; a step would spike it.
        let finalAmplitude = vDSP.maximumMagnitude(Array(out[(count - 9_600)...]))
        var worst: Float = 0
        // Skip the tone's own abrupt start; the switch happens at 1 s.
        for i in 24_000..<count {
            worst = max(worst, abs(out[i] - 2 * out[i - 1] + out[i - 2]))
        }
        print("Profile switch: final amplitude \(finalAmplitude), worst second difference \(worst / finalAmplitude) of amplitude")
        #expect(worst <= 0.03 * finalAmplitude)
        #expect(finalAmplitude > dbToGain(-20) * dbToGain(4))
    }

    @Test(.responsivePool) func kernelRunsAtLeastTenTimesRealtimeInThisBuild() throws {
        var noise = Noise(state: 5)
        let seconds = 20.0
        let count = Int(Self.rate * seconds)
        let left = (0..<count).map { _ in 1.5 * noise.next() }
        let right = (0..<count).map { _ in 1.5 * noise.next() }
        var outL = [Float](repeating: 0, count: count), outR = outL
        let kernel = LofiMasterKernel(sampleRate: Self.rate, maximumFrames: 512, settings: .lofi)
        // Load-corrected CPU time, so the parallel suite does not inflate it (see `ForegroundTiming`).
        let cost = try ForegroundTiming.measure {
            left.withUnsafeBufferPointer { l in
                right.withUnsafeBufferPointer { r in
                    outL.withUnsafeMutableBufferPointer { ol in
                        outR.withUnsafeMutableBufferPointer { or in
                            var offset = 0
                            while offset < count {
                                kernel.process(inL: l.baseAddress! + offset, inR: r.baseAddress! + offset,
                                               outL: ol.baseAddress! + offset, outR: or.baseAddress! + offset,
                                               count: min(512, count - offset))
                                offset += 512
                            }
                        }
                    }
                }
            }
        }.cost
        let cpu = cost.seconds
        let factor = seconds / cpu
        print("Master kernel realtime factor at 512-frame blocks: \(factor)x (\(cpu * 1000) ms of CPU for \(seconds) s)")
        #expect(factor >= 10)
    }

    // MARK: Audio unit

    @MainActor
    @Test func audioUnitNodeInManualRenderingMatchesTheOfflineKernel() throws {
        let source = ArchiveVoice.BufferSource()
        let finisher = LofiMasterFinisher(source, settings: .lofi)
        #expect(finisher.isOperational)
        let audio = AudioEngine()
        audio.output = finisher
        let av = audio.avEngine
        let format = AudioKit.Settings.audioFormat
        let rate = format.sampleRate
        try av.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try audio.start()
        defer { audio.stop() }
        let total = Int(rate * 2)
        var noise = Noise(state: 21)
        let tone = (0..<total).map { Float(sin(2 * Double.pi * 220 * Double($0) / rate)) }
        let left = (0..<total).map { i in 0.9 * tone[i] + 0.4 * noise.next() }
        let right = (0..<total).map { i in -0.6 * tone[i] + 0.4 * noise.next() }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)))
        buffer.frameLength = AVAudioFrameCount(total)
        let channels = try #require(buffer.floatChannelData)
        for i in 0..<total {
            channels[0][i] = left[i]
            channels[1][i] = right[i]
        }
        source.player.scheduleBuffer(buffer)
        source.player.play()
        var captured = [[Float](), [Float]()]
        let block = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        while av.manualRenderingSampleTime < AVAudioFramePosition(total) {
            let count = min(512, total - Int(av.manualRenderingSampleTime))
            let status = try av.renderOffline(AVAudioFrameCount(count), to: block)
            try #require(status == .success)
            let pcm = try #require(block.floatChannelData)
            for c in 0..<2 {
                captured[c].append(contentsOf: UnsafeBufferPointer(start: pcm[c], count: Int(block.frameLength)))
            }
        }
        let offline = LofiMasterKernel.processOffline(left: left, right: right, settings: .lofi,
                                                      sampleRate: rate, blockSize: 512)
        let error = max(zip(captured[0], offline.left).map { abs($0 - $1) }.max() ?? 1,
                        zip(captured[1], offline.right).map { abs($0 - $1) }.max() ?? 1)
        let kernelLatency = LofiMasterKernel(sampleRate: rate, maximumFrames: 512).latencyFrames
        print("AU node versus offline kernel at \(rate) Hz: max difference \(error), latency \(finisher.latency) s (\(finisher.latencyFrames) frames), meters limiter mean \(finisher.meters.limiterDB.mean)")
        #expect(captured[0].count == total)
        #expect(error <= 1e-5)
        #expect(finisher.latencyFrames == kernelLatency)
        #expect(abs(finisher.latency - Double(kernelLatency) / rate) < 1e-9)
        #expect(abs(finisher.avAudioNode.auAudioUnit.latency - finisher.latency) < 1e-12)
        #expect(finisher.meters.frames == total)
        finisher.startTrace(capacity: 16)
        #expect(finisher.takeTrace().isEmpty)
        finisher.resetMeters()
    }

    @MainActor
    @Test func fallbackNodeIsAPassThrough() throws {
        let source = ArchiveVoice.BufferSource()
        let finisher = LofiMasterFinisher(source, settings: .lofi, forceFallback: true)
        #expect(!finisher.isOperational)
        #expect(finisher.latency == 0 && finisher.meters.frames == 0 && finisher.takeTrace().isEmpty)
        finisher.apply(.passthrough, ramp: 0.1)
        let audio = AudioEngine()
        audio.output = finisher
        let av = audio.avEngine
        let format = AudioKit.Settings.audioFormat
        try av.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try audio.start()
        defer { audio.stop() }
        let total = 4_096
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)))
        buffer.frameLength = AVAudioFrameCount(total)
        let channels = try #require(buffer.floatChannelData)
        for i in 0..<total {
            channels[0][i] = 0.25 * Float(sin(Double(i) * 0.05))
            channels[1][i] = channels[0][i]
        }
        source.player.scheduleBuffer(buffer)
        source.player.play()
        let block = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        let status = try av.renderOffline(AVAudioFrameCount(total), to: block)
        try #require(status == .success)
        let pcm = try #require(block.floatChannelData)
        var error: Float = 0
        for i in 0..<total { error = max(error, abs(pcm[0][i] - channels[0][i])) }
        #expect(error < 1e-6)
    }
}
