import Accelerate
import AudioKit
import AudioKitEX
import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// Master bus profiles (plan sections 3.7 and 8.7) rendered through the real graph in manual mode.
@MainActor
@Suite(.serialized)
struct LofiMasterBusTests {
    static let format = AudioKit.Settings.audioFormat
    static var rate: Double { format.sampleRate }

    /// Two program sources into one output node, rendered offline.
    @MainActor final class Rig {
        let archive = ArchiveVoice.BufferSource()
        let lofi = ArchiveVoice.BufferSource()
        let audio = AudioEngine()

        func start(_ output: Node) throws {
            audio.output = output
            try audio.avEngine.enableManualRenderingMode(.offline, format: LofiMasterBusTests.format,
                                                         maximumFrameCount: 4096)
            try audio.start()
        }

        func schedule(_ source: ArchiveVoice.BufferSource, _ channels: [[Float]]) throws {
            let count = channels[0].count
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: LofiMasterBusTests.format,
                                                       frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let pcm = try #require(buffer.floatChannelData)
            for c in 0..<2 { channels[c].withUnsafeBufferPointer { pcm[c].update(from: $0.baseAddress!, count: count) } }
            source.player.scheduleBuffer(buffer)
            source.player.play()
        }

        /// Renders `frames` more frames in `chunk`-frame blocks, calling `between` after each block.
        func render(_ frames: Int, chunk: Int = 1024, between: ((Int) async throws -> Void)? = nil) async throws -> [[Float]] {
            let av = audio.avEngine
            let block = try #require(AVAudioPCMBuffer(pcmFormat: LofiMasterBusTests.format, frameCapacity: 4096))
            var out = [[Float](), [Float]()]
            out[0].reserveCapacity(frames)
            out[1].reserveCapacity(frames)
            while out[0].count < frames {
                let count = min(chunk, frames - out[0].count)
                let status = try av.renderOffline(AVAudioFrameCount(count), to: block)
                try #require(status == .success)
                let pcm = try #require(block.floatChannelData)
                for c in 0..<2 { out[c].append(contentsOf: UnsafeBufferPointer(start: pcm[c], count: Int(block.frameLength))) }
                try await between?(out[0].count)
            }
            return out
        }

        func stop() { audio.stop() }
    }

    // MARK: Programs

    /// The stress program of `combinedMasterLeavesHeadroomAndDoesNotBoostQuietMaterial`, split across the
    /// two inputs: quiet tone, loud tone, phase-alternating overload, a 36-sample spike and a 57 Hz burst.
    static func stressProgram(_ total: Int) -> (archive: [[Float]], lofi: [[Float]], sum: [[Float]]) {
        var parts = [[[Float]](repeating: [Float](repeating: 0, count: total), count: 2),
                     [[Float]](repeating: [Float](repeating: 0, count: total), count: 2)]
        var sum = [[Float]](repeating: [Float](repeating: 0, count: total), count: 2)
        for j in 0..<2 {
            for c in 0..<2 {
                for i in 0..<total {
                    let time = Double(i) / rate
                    let angle = 2 * .pi * (c == 0 ? 220.0 : 540) * time
                    let swing: Float = j == 0 ? 0.63 : 0.37
                    let x: Float
                    if (0.10...0.37).contains(time) {
                        x = 0.065 * Float(sin(angle))
                    } else if (0.45...1.10).contains(time) {
                        x = 0.72 * Float(sin(angle))
                    } else if (1.45...2.05).contains(time) {
                        let envelope = min(1, (time - 1.45) / 0.03, (2.05 - time) / 0.03)
                        let polarity = (i % 4 < 2) == (c == 0) ? 1.0 : -1
                        x = Float(envelope * polarity * 1.10)
                    } else if (Int(rate * 2.5)..<Int(rate * 2.5) + 36).contains(i) {
                        x = (i % 4 < 2 ? 1.48 : -1.48) * (c == 0 ? 1 : 0.73)
                    } else if (2.52...3.30).contains(time) {
                        let envelope = max(0, min(1, (time - 2.52) / 0.003, (3.30 - time) / 0.16))
                        x = Float(envelope * 0.85 * sin(2 * .pi * 57 * time))
                    } else {
                        x = 0
                    }
                    parts[j][c][i] = swing * x
                    sum[c][i] += swing * x
                }
            }
        }
        return (parts[0], parts[1], sum)
    }

    static func tone(_ total: Int, amplitude: Float, hz: Double = 220) -> [[Float]] {
        // 20 ms raised-cosine fade in, so the onset itself is not a step.
        func fade(_ i: Int) -> Float { Float(0.5 - 0.5 * cos(.pi * min(1, Double(i) / (0.02 * rate)))) }
        let left = (0..<total).map { fade($0) * amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
        let right = (0..<total).map { fade($0) * amplitude * Float(sin(2 * .pi * hz * 1.5 * Double($0) / rate + 0.7)) }
        return [left, right]
    }

    static func db(_ x: Float) -> Float { 20 * log10f(max(x, 1e-12)) }

    static func rms(_ x: [Float], _ range: Range<Int>) -> Float { vDSP.rootMeanSquare(Array(x[range])) }

    static func maximumStep(_ channels: [[Float]], _ range: Range<Int>) -> Float {
        var step: Float = 0
        for channel in channels {
            for i in max(1, range.lowerBound)..<min(channel.count, range.upperBound) {
                step = max(step, abs(channel[i] - channel[i - 1]))
            }
        }
        return step
    }

    /// Independent 49-tap Blackman-windowed sinc, as in `LofiMasterCharacterizationTests`: 16x peak.
    static func reconstructedPeak(_ signal: [Float]) -> Float {
        let radius = 24
        let taps = 2 * radius + 1
        let edge = [Float](repeating: 0, count: radius)
        let padded = edge + signal + edge
        var result = vDSP.maximumMagnitude(signal)
        var filtered = [Float](repeating: 0, count: signal.count)
        for phase in 1..<16 {
            let fraction = Double(phase) / 16
            var kernel = (0..<taps).map { tap -> Float in
                let delta = Double(tap - radius) - fraction
                let cosine = .pi * delta / Double(radius + 1)
                let window = 0.42 + 0.5 * cos(cosine) + 0.08 * cos(2 * cosine)
                return Float(window * sin(.pi * delta) / (.pi * delta))
            }
            let total = kernel.reduce(0, +)
            kernel = kernel.map { $0 / total }
            vDSP_conv(padded, 1, kernel, 1, &filtered, 1, vDSP_Length(signal.count), vDSP_Length(taps))
            result = max(result, vDSP.maximumMagnitude(filtered))
        }
        return result
    }

    // MARK: Ambient

    @Test func ambientProfileEqualsTheLegacyChainDelayedByTheFinisher() async throws {
        let total = Int(Self.rate * 3.5)
        let program = Self.stressProgram(total)

        let candidate = Rig()
        let master = LofiMasterBus(archiveAndAmbient: candidate.archive, lofi: candidate.lofi)
        #expect(master.profile == .ambient && master.activeChain == .ambient)
        try candidate.start(master.output)
        defer { candidate.stop() }

        // The chain as it was before the profiles: glue -> +3.3 dB -> sample limiter -> -4.8 dB.
        let reference = Rig()
        let input = Mixer(reference.archive, reference.lofi)
        let glue = Compressor(input, threshold: -15, headRoom: 9, attackTime: 0.027, releaseTime: 0.27, masterGain: 0)
        let trim = Fader(glue, gain: dbToGain(3.3))
        let limiter = PeakLimiter(trim, attackTime: 0.005, decayTime: 0.06, preGain: 0)
        let output = Fader(limiter, gain: dbToGain(-4.8))
        try reference.start(output)
        defer { reference.stop() }

        for rig in [candidate, reference] {
            try rig.schedule(rig.archive, program.archive)
            try rig.schedule(rig.lofi, program.lofi)
        }
        let latency = master.finisher.latencyFrames
        #expect(master.finisher.isOperational && latency > 0)
        let new = try await candidate.render(total + latency)
        let old = try await reference.render(total)
        var error: Float = 0
        for c in 0..<2 {
            for i in 0..<total { error = max(error, abs(new[c][i + latency] - old[c][i])) }
        }
        let lead = max(vDSP.maximumMagnitude(Array(new[0][0..<latency])), vDSP.maximumMagnitude(Array(new[1][0..<latency])))
        let peak = max(vDSP.maximumMagnitude(old[0]), vDSP.maximumMagnitude(old[1]))
        print("Ambient profile versus legacy chain: max difference \(error), latency \(latency) frames, legacy peak \(Self.db(peak)) dBFS")
        #expect(error <= 1e-5)
        #expect(lead <= 1e-6)
        #expect(peak > 0.1)
    }

    // MARK: Lo-Fi

    @Test func lofiProfileKeepsTheStressProgramUnderTheTruePeakCeilingAndRaisesQuietMaterial() async throws {
        let total = Int(Self.rate * 4)
        let program = Self.stressProgram(total)
        let rig = Rig()
        let master = LofiMasterBus(archiveAndAmbient: rig.archive, lofi: rig.lofi)
        master.setProfile(.lofi, ramp: 0)
        #expect(master.profile == .lofi && master.activeChain == .lofi)
        #expect(master.glue.avAudioNode.auAudioUnit.shouldBypassEffect)
        #expect(master.limiter.avAudioNode.auAudioUnit.shouldBypassEffect)
        try rig.start(master.output)
        defer { rig.stop() }
        try rig.schedule(rig.archive, program.archive)
        try rig.schedule(rig.lofi, program.lofi)
        let out = try await rig.render(total)
        #expect(out.allSatisfy { $0.allSatisfy(\.isFinite) })

        func gain(_ start: Double, _ end: Double) -> Float {
            let range = Int(Self.rate * start)..<Int(Self.rate * end)
            return Self.db(Self.rms(out[0], range) / Self.rms(program.sum[0], range))
        }
        let quiet = gain(0.19, 0.34)
        let loud = gain(0.91, 1.07)
        let ceiling = dbToGain(-1.0)
        let windows = ["ordinary": 0.43...1.18, "phase": 1.41...2.14, "transient": 2.48...3.37, "all": 0.0...3.99]
        for name in windows.keys.sorted() {
            let time = try #require(windows[name])
            let frames = Int(Self.rate * time.lowerBound)..<Int(Self.rate * time.upperBound)
            let sample = out.map { vDSP.maximumMagnitude(Array($0[frames])) }.max() ?? 0
            let reconstructed = out.map { Self.reconstructedPeak(Array($0[frames])) }.max() ?? 0
            print("Lo-Fi master stress \(name): sample \(Self.db(sample)) dBFS, 16x \(Self.db(reconstructed)) dBTP, quiet gain \(quiet) dB, loud gain \(loud) dB")
            #expect(Self.db(reconstructed) <= -1.0)
            #expect(sample <= ceiling)
        }
        // Both branches enter at the staging gain and the finisher input makes it up: the net drive is the
        // +4 dB chosen before the gain staging change of 19 November 2026.
        let drive = master.lofiFinisherSettings.inputGainDB + LofiMasterBus.lofiStagingDB
        #expect(abs(drive - 4) < 1e-4)
        #expect(abs(master.archiveTrim.gain - dbToGain(LofiMasterBus.lofiStagingDB)) < 1e-6)
        #expect(abs(master.lofiTrim.gain - dbToGain(LofiMasterBus.lofiStagingDB)) < 1e-6)
        #expect(quiet > drive - 1 && quiet < drive + 0.5)
        #expect(loud < quiet - 1.0)
        let meters = master.finisher.meters
        #expect(meters.guardClampCount == 0)
        #expect(meters.limiterDB.max > 1)
    }

    @Test func profileChangesWhileRenderingProduceNoStep() async throws {
        let total = Int(Self.rate * 4.5)
        let rig = Rig()
        let master = LofiMasterBus(archiveAndAmbient: rig.archive, lofi: rig.lofi)
        try rig.start(master.output)
        defer { rig.stop() }
        try rig.schedule(rig.lofi, Self.tone(total, amplitude: 0.3))
        let toLofi = Int(Self.rate * 1.0), toAmbient = Int(Self.rate * 2.5)
        var seen: [LofiMasterBus.Profile] = []
        var requested = 0
        let out = try await rig.render(total, chunk: 256) { rendered in
            if requested == 0 && rendered >= toLofi { master.setProfile(.lofi, ramp: 0.03); requested = 1 }
            if requested == 1 && rendered >= toAmbient { master.setProfile(.ambient, ramp: 0.03); requested = 2 }
            if seen.last != master.activeChain { seen.append(master.activeChain) }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(seen == [.ambient, .lofi, .ambient])
        #expect(!master.isSwitchingProfile)
        let second = Int(Self.rate)
        let steady = [Self.maximumStep(out, second / 2..<toLofi),
                      Self.maximumStep(out, toLofi + second / 2..<toAmbient),
                      Self.maximumStep(out, toAmbient + second / 2..<total)]
        let largest = Self.maximumStep(out, 1..<total)
        let levels = [Self.rms(out[0], second / 2..<toLofi), Self.rms(out[0], toLofi + second / 2..<toAmbient),
                      Self.rms(out[0], toAmbient + second / 2..<total)].map(Self.db)
        print("Profile switch: steady steps \(steady), largest \(largest), levels \(levels) dB")
        #expect(largest <= (steady.max() ?? 0) + 0.02)
        // Lo-Fi drives the same tone harder than the Ambient chain, and Ambient returns to its level.
        #expect(levels[1] > levels[0] + 2)
        #expect(abs(levels[2] - levels[0]) < 0.3)
    }

    @Test func lofiChainDelaysByTheFinisherLatency() async throws {
        let total = 16_384
        let rig = Rig()
        let master = LofiMasterBus(archiveAndAmbient: rig.archive, lofi: rig.lofi)
        master.setProfile(.lofi, ramp: 0)
        try rig.start(master.output)
        defer { rig.stop() }
        var impulse = [[Float](repeating: 0, count: total), [Float](repeating: 0, count: total)]
        impulse[0][4_000] = 0.25
        impulse[1][4_000] = 0.25
        try rig.schedule(rig.lofi, impulse)
        let out = try await rig.render(total)
        let index = vDSP.indexOfMaximumMagnitude(out[0]).0
        let reported = [master.glue.avAudioNode.auAudioUnit.latency, master.limiter.avAudioNode.auAudioUnit.latency,
                        master.finisher.latency].map { $0 * Self.rate }
        print("Lo-Fi chain impulse delay \(Int(index) - 4_000) frames; reported glue, limiter, finisher \(reported)")
        #expect(Int(index) - 4_000 == master.finisher.latencyFrames)
    }

    // MARK: Capture hooks

    @Test func captureHooksSelectTheProfileAndExportDynamicsAndTheTrace() async throws {
        LofiCaptureHooks.begin(options: ["masterProfile": "lofi"])
        defer { LofiCaptureHooks.end() }
        let rig = Rig()
        let master = LofiMasterBus(archiveAndAmbient: rig.archive, lofi: rig.lofi)
        #expect(master.profile == .lofi && master.activeChain == .lofi)
        #expect(LofiCaptureHooks.taps.contains { $0.name == "master-in" && $0.node === master.trim.avAudioNode })
        try rig.start(master.output)
        defer { rig.stop() }
        let frames = 64 * 1_500
        let program = Self.stressProgram(frames)
        try rig.schedule(rig.lofi, program.sum)
        _ = try await rig.render(frames)
        LofiCaptureHooks.runFinishers()

        let dynamics = try #require(LofiCaptureHooks.reports["masterDynamics"] as? [String: Any])
        #expect(JSONSerialization.isValidJSONObject(dynamics))
        #expect(dynamics["profile"] as? String == "lofi")
        #expect(dynamics["traceFile"] as? String == "master-gr.csv")
        #expect(dynamics["traceHopFrames"] as? Int == 64)
        #expect(dynamics["latencyFrames"] as? Int == master.finisher.latencyFrames)
        #expect(abs((dynamics["ceilingDbtp"] as? Double ?? 0) + 1) < 1e-9)
        let limiter = try #require(dynamics["limiter"] as? [String: Double])
        #expect(Set(limiter.keys) == ["meanDb", "p95Db", "maxDb", "above3dbFraction"])
        #expect((limiter["maxDb"] ?? 0) > 0)
        let clip = try #require(dynamics["clip"] as? [String: Double])
        #expect(clip["engagedFraction"] != nil && clip["maxDb"] != nil)
        let glue = try #require(dynamics["glue"] as? [String: Double])
        #expect(glue["meanDb"] != nil && glue["p95Db"] != nil && glue["maxDb"] != nil)

        let data = try #require(LofiCaptureHooks.files["master-gr.csv"])
        let lines = try #require(String(data: data, encoding: .utf8)).split(separator: "\n")
        #expect(lines.first == "frame,glue_db,clip_db,limiter_db")
        let rows = lines.dropFirst().map { $0.split(separator: ",").compactMap { Double($0) } }
        #expect(rows.count == frames / 64)
        #expect(rows.allSatisfy { $0.count == 4 })
        #expect(rows.enumerated().allSatisfy { Int($0.element[0]) == $0.offset * 64 })
        #expect((rows.map { $0[3] }.max() ?? 0) > 0)
    }

    @Test func captureHooksCanSelectTheAmbientProfile() {
        LofiCaptureHooks.begin(options: ["masterProfile": "ambient"])
        defer { LofiCaptureHooks.end() }
        let master = LofiMasterBus(archiveAndAmbient: ArchiveVoice.BufferSource(), lofi: ArchiveVoice.BufferSource())
        #expect(master.profile == .ambient && master.activeChain == .ambient)
        #expect(!master.glue.avAudioNode.auAudioUnit.shouldBypassEffect)
        LofiCaptureHooks.runFinishers()
        let dynamics = LofiCaptureHooks.reports["masterDynamics"] as? [String: Any]
        #expect(dynamics?["profile"] as? String == "ambient")
    }

    // MARK: Calibration

    @Test func calibrationAimsAtTheProfileTargetAndHoldsUnderLimiterLoad() {
        typealias Meter = LofiMasterMeter
        let light = Meter.LimiterLoad(meanDB: 0.8, p95DB: 2.0)
        // Lo-Fi aims at -12 LUFS; the sample peak no longer gates upward steps.
        #expect(Meter.calibratedTrim(current: 0, observation: .init(lufs: -16, samplePeak: 0.89), target: -12, limiter: light) == 1)
        #expect(Meter.calibratedTrim(current: 0, observation: .init(lufs: -12.5, samplePeak: 0.5), target: -12, limiter: light) == 0)
        #expect(Meter.calibratedTrim(current: 0, observation: .init(lufs: -9, samplePeak: 0.5), target: -12, limiter: light) == -1)
        #expect(Meter.calibratedTrim(current: 1.8, observation: .init(lufs: -16, samplePeak: 0.5), target: -12, limiter: light) == 2)
        #expect(Meter.calibratedTrim(current: -2.5, observation: .init(lufs: -8, samplePeak: 0.5), target: -12, limiter: light) == -3)
        // Heavy limiter reduction holds upward steps but still allows downward ones.
        for load in [Meter.LimiterLoad(meanDB: 2.6, p95DB: 3), Meter.LimiterLoad(meanDB: 1, p95DB: 4.6)] {
            #expect(load.blocksUpward)
            #expect(Meter.calibratedTrim(current: 0, observation: .init(lufs: -16, samplePeak: 0.5), target: -12, limiter: load) == 0)
            #expect(Meter.calibratedTrim(current: 0, observation: .init(lufs: -9, samplePeak: 0.5), target: -12, limiter: load) == -1)
        }
        // Ambient keeps -18 LUFS and the sample-peak test.
        #expect(Meter.calibratedTrim(current: 0, observation: .init(lufs: -23, samplePeak: 0.3)) == 1)
        #expect(Meter.calibratedTrim(current: 0, observation: .init(lufs: -16, samplePeak: 0.3)) == -0.8)
        #expect(Meter.calibratedTrim(current: 0, observation: .init(lufs: -23, samplePeak: 0.55)) == 0)
    }

    @Test func busCalibrationFollowsTheActiveChainAndTheFinisherMeters() async throws {
        let ambient = LofiMasterBus(archiveAndAmbient: ArchiveVoice.BufferSource(), lofi: ArchiveVoice.BufferSource())
        ambient.applyObservation(.init(lufs: -23, samplePeak: 0.2))
        #expect(ambient.calibrationOffsetDB == 1)
        ambient.applyObservation(.init(lufs: -15, samplePeak: 0.2))
        #expect(abs(ambient.calibrationOffsetDB - 0) < 1e-6)

        // Light program: the finisher barely limits, so Lo-Fi steps toward -12 LUFS.
        let rig = Rig()
        let lofi = LofiMasterBus(archiveAndAmbient: rig.archive, lofi: rig.lofi)
        lofi.setProfile(.lofi, ramp: 0)
        try rig.start(lofi.output)
        defer { rig.stop() }
        let frames = Int(Self.rate)
        try rig.schedule(rig.lofi, Self.tone(frames, amplitude: 0.05))
        _ = try await rig.render(frames)
        lofi.applyObservation(.init(lufs: -20, samplePeak: 0.95))
        #expect(lofi.calibrationOffsetDB == 1)

        // Loud program: heavy limiter reduction holds the trim even though the estimate is low.
        // About +12 dBFS: more than the 1.7:1 glue and the 2 dB clip can take, so the limiter carries over 3 dB.
        try rig.schedule(rig.lofi, Self.tone(frames, amplitude: 4, hz: 90))
        _ = try await rig.render(frames)
        let meters = lofi.finisher.meters
        print("Loud Lo-Fi epoch: limiter \(meters.limiterDB), glue \(meters.glueDB), clip \(meters.clipDB)")
        #expect(meters.limiterDB.mean > 2.5)
        lofi.applyObservation(.init(lufs: -20, samplePeak: 0.89))
        #expect(lofi.calibrationOffsetDB == 1)
        lofi.applyObservation(.init(lufs: -9, samplePeak: 0.89))
        #expect(lofi.calibrationOffsetDB == 0)
    }

    // MARK: Fallback

    @Test func nonOperationalFinisherFallsBackToTheAmbientChain() async throws {
        let total = Int(Self.rate * 3.5)
        let program = Self.stressProgram(total)
        let rig = Rig()
        let master = LofiMasterBus(archiveAndAmbient: rig.archive, lofi: rig.lofi, forceFinisherFallback: true)
        #expect(!master.finisher.isOperational)
        master.setProfile(.lofi, ramp: 0.05)
        #expect(master.profile == .lofi && master.activeChain == .ambient)
        #expect(!master.glue.avAudioNode.auAudioUnit.shouldBypassEffect)
        #expect(!master.limiter.avAudioNode.auAudioUnit.shouldBypassEffect)
        try rig.start(master.output)
        defer { rig.stop() }
        try rig.schedule(rig.archive, program.archive)
        try rig.schedule(rig.lofi, program.lofi)
        let out = try await rig.render(total)
        let sample = out.map(vDSP.maximumMagnitude).max() ?? 1
        print("Fallback chain stress sample peak \(Self.db(sample)) dBFS")
        #expect(Self.db(sample) < LofiMasterBus.safetyTrimDB + 0.03)
        #expect(out.allSatisfy { $0.allSatisfy(\.isFinite) })
    }
}
