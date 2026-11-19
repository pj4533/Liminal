import AudioKit
import AVFoundation
import Foundation
import Testing
@testable import Liminal

struct LofiProductionTests {
    #if os(macOS)
    @Test @MainActor func routeResetRestartsPlaybackAndHonorsStop() async throws {
        let music = GenerativeEngine(seed: 71)
        let av = music.engine.avEngine
        try av.enableManualRenderingMode(.offline, format: Settings.audioFormat, maximumFrameCount: 1024)
        defer { music.shutdown() }
        music.start()
        try #require(av.isRunning && music.isPlaybackReady)

        av.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: av)
        let deadline = ContinuousClock.now + .seconds(30)
        while !av.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(av.isRunning && music.isPlaybackReady)

        av.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: av)
        await Task.yield()
        music.stop()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!av.isRunning && !music.isRunning && !music.isPlaybackReady)
    }
    #endif

    @Test(arguments: [8_000.0, 48_000.0])
    func actualKickDucksBassEvenWhenDrumChannelsOppose(sampleRate: Double) {
        func run(frequency: Double) -> (minimum: Float, after: Float) {
            var detector = LofiKickDuck(sampleRate: sampleRate)
            var minimum: Float = 1
            var current: Float = 1
            for i in 0..<Int(sampleRate * 0.65) {
                let t = Double(i) / sampleRate
                let hit = t < 0.055 ? Float(0.76 * sin(2 * .pi * frequency * t) * exp(-22 * t)) : 0
                current = detector.gain(drumLeft: hit, drumRight: -hit)
                minimum = min(minimum, current)
            }
            return (minimum, current)
        }
        let kick = run(frequency: 68)
        let bright = run(frequency: 1_800)
        #expect(kick.minimum < 0.83 && kick.minimum >= 0.70)
        #expect(kick.after > 0.99)
        #expect(bright.minimum > 0.97)
    }

    @Test(arguments: [44_100.0, 48_000.0])
    func stereoLoudnessEpochGatesSilenceAndTracksCalibratedTone(rate: Double) throws {
        var meter = LofiMasterMeter(sampleRate: rate, epochSeconds: 1)
        var result: LofiMasterMeter.Observation?
        for _ in 0..<Int(rate) { result = meter.add(left: 0, right: 0) ?? result }
        #expect(result == nil)
        let amplitude = pow(10, -23.0 / 20)
        for i in 0..<Int(rate) {
            let x = Float(amplitude * sin(2 * .pi * 1000 * Double(i) / rate))
            result = meter.add(left: x, right: -x) ?? result
        }
        let measured = try #require(result)
        #expect(abs(measured.lufs - (-23)) < 0.12)
        #expect(abs(measured.samplePeak - Float(amplitude)) < 0.0003)
        #expect(LofiMasterMeter.calibratedTrim(current: 0, observation: measured) == 1)
        #expect(LofiMasterMeter.calibratedTrim(current: 2, observation: measured) == 2)
        #expect(LofiMasterMeter.calibratedTrim(current: 0, observation: .init(lufs: -23, samplePeak: 0.82)) == 0)
        #expect(LofiMasterMeter.calibratedTrim(current: 0, observation: .init(lufs: -13, samplePeak: 0.82)) == -1)
        #expect(LofiMasterMeter.calibratedTrim(current: 0, observation: .init(lufs: -55, samplePeak: 0.0001)) == 0)
    }

    @Test(arguments: LofiEffects.Gesture.allCases)
    func echoRoomAndColorAreIndependentFiniteReturns(gesture: LofiEffects.Gesture) throws {
        let clock = LofiClock(tempo: 70, sampleRate: 8_000)
        let divisions = gesture.taps(for: .standard)
        var rack = LofiEffects(clock: clock, gesture: gesture)
        var firstEcho: (left: Int?, right: Int?) = (nil, nil)
        var firstRoom: Int?
        var firstColor: Int?
        var finite = true
        var finalPeak: Float = 0
        for i in 0..<clock.frame(at: 14) {
            let x: Float = i == 0 ? 0.9 : 0
            let returns = rack.processReturns(lead: (x, x), texture: (0, 0), grains: (0.3 * x, -0.3 * x), space: 0.5)
            if returns.echo.left != 0, firstEcho.left == nil { firstEcho.left = i }
            if returns.echo.right != 0, firstEcho.right == nil { firstEcho.right = i }
            if returns.room.left != 0, firstRoom == nil { firstRoom = i }
            if returns.color.left != 0, firstColor == nil { firstColor = i }
            let combined = returns.mix
            finite = finite && combined.left.isFinite && combined.right.isFinite
            if i >= clock.frame(at: 13) { finalPeak = max(finalPeak, abs(combined.left), abs(combined.right)) }
        }
        #expect(finite)
        #expect(firstEcho.left == clock.frame(at: divisions.left))
        #expect(firstEcho.right == clock.frame(at: divisions.right))
        #expect(try #require(firstRoom) >= Int(clock.sampleRate * 0.034))
        #expect(firstColor == 0)
        #expect(finalPeak < 0.002)
    }

    @Test func capturedReturnFeedsOnlyTheThreeLaterReplayWindows() {
        let clock = LofiClock(tempo: 70, sampleRate: 8_000)
        var replay = LofiEffects.ReturnReplay(lastBeat: 10, clock: clock, gesture: .cloud)
        let silence = [Float](repeating: 0, count: clock.frameCount)
        var grains = (left: silence, right: silence)
        for frame in replay.window {
            replay.capture((0.2, -0.1), at: frame, into: &grains)
        }
        let starts = [12.0, 12.625, 13.625].map { clock.frame(at: $0) }
        let runs = grains.left.indices.filter { $0 > 0 && grains.left[$0] > 0 && grains.left[$0 - 1] == 0 }
        #expect(runs == starts.map { $0 + 1 })
        #expect(grains.right.min() ?? 0 < 0)
    }

    @Test func reverseAndPitchShiftFollowTheScheduledGridAndScale() {
        let clock = LofiClock(tempo: 70, sampleRate: 8_000)
        let start = clock.frame(at: 0.75)
        let length = 2_401
        let input = (0..<(length + 1)).map { Float(sin(2 * .pi * 220 * Double($0) / clock.sampleRate)) }
        let silent = [Float](repeating: 0, count: start + length)
        var output = (left: silent, right: silent)
        let target = LofiEffects.targetPitch(source: 57, interval: 7, scale: .minor, tonic: 9)
        #expect(target == 64)
        let rate = pow(2, Double(target - 57) / 12)
        LofiEffects.replay((input, input), sourceStart: 0, sourceCount: length, into: &output,
                           destination: start, rate: rate, reverse: true, gain: 1, pan: 0)
        #expect(output.left.prefix(start).allSatisfy { $0 == 0 })
        #expect(output.left[start] == 0)
        let crossing = (200..<1_200).count { i in output.left[start + i - 1] < 0 && output.left[start + i] >= 0 }
        #expect(abs(Double(crossing) * 8 - 329.63) < 9)
        let travel = 300 * rate
        let reversed = Double(length - 1) - travel
        let i = Int(reversed)
        let expectedSign = input[i] + Float(reversed - Double(i)) * (input[i + 1] - input[i])
        #expect(output.left[start + 300] * expectedSign > 0)
        for scale in ScaleType.allCases {
            for source in 53...72 where scale.intervals.contains(source % 12) {
                for shift in [-12, -7, -5, 0, 5, 7, 12] {
                    let note = LofiEffects.targetPitch(source: source, interval: shift, scale: scale, tonic: 0)
                    #expect(scale.intervals.contains(note % 12))
                }
            }
        }
    }

    @Test func tapeColorDropsThirdHarmonicAliasAndHandlesNearEqualInputs() {
        let frames = 8_000
        let drive: Float = 1.6
        let inputFrequency = 0.22
        let aliasFrequency = 1 - 3 * inputFrequency
        var tape = LofiEffects.TapeColor()
        var raw = 0.0, antialiased = 0.0
        var finite = true
        for i in 0..<frames {
            let phase = Double(i) * 2 * .pi
            let sample = 0.83 * Float(sin(phase * inputFrequency))
            let result = tape.process(sample, drive: drive)
            let comparator = tanhf(sample * drive) / drive
            if i >= 100 {
                raw += Double(comparator) * sin(phase * aliasFrequency)
                // Compensate the half-sample delay introduced by linear interpolation in the shaping interval.
                antialiased += Double(result) * sin(phase * aliasFrequency + .pi * aliasFrequency)
            }
            finite = finite && result.isFinite && abs(result) <= 1 / drive + 0.001
        }
        #expect(finite)
        #expect(abs(antialiased) < 0.7 * abs(raw))
        for _ in 0..<10 { #expect(tape.process(0.31, drive: drive).isFinite) }
        #expect(abs(tape.process(0.3100001, drive: drive) - tanhf(0.31 * drive) / drive) < 0.0001)
    }
}

@MainActor
struct LofiArchiveRetimeTests {
    @Test func sharedOutputContainsBothProgramInputsAndAttenuatesAnOverload() throws {
        let archive = ArchiveVoice.BufferSource()
        let lofi = ArchiveVoice.BufferSource()
        let master = LofiMasterBus(archiveAndAmbient: archive, lofi: lofi)
        let audio = AudioEngine()
        audio.output = master.output
        let format = AudioKit.Settings.audioFormat
        let av = audio.avEngine
        try av.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try audio.start()
        defer { audio.stop() }
        let count = AVAudioFrameCount(format.sampleRate)
        let block = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        for (index, voice) in [archive, lofi].enumerated() {
            let stimulus = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
            stimulus.frameLength = count
            let pcm = try #require(stimulus.floatChannelData)
            for i in 0..<Int(count) {
                let t = Double(i) / format.sampleRate
                let amplitude = t > 0.15 && t < 0.23 ? 1.6 : 0.19
                pcm[index][i] = Float(amplitude * sin(2 * .pi * Double(index + 1) * 220 * t))
                pcm[1 - index][i] = 0
            }
            voice.player.scheduleBuffer(stimulus)
            voice.player.play()
        }
        var peakL: Float = 0, peakR: Float = 0
        while av.manualRenderingSampleTime < AVAudioFramePosition(count) + 4096 {
            let status = try av.renderOffline(1024, to: block)
            guard status == .success else { break }
            let pcm = try #require(block.floatChannelData)
            for i in 0..<Int(block.frameLength) {
                peakL = max(peakL, abs(pcm[0][i]))
                peakR = max(peakR, abs(pcm[1][i]))
            }
        }
        #expect(peakL > 0.2 && peakL < 0.85)
        #expect(peakR > 0.2 && peakR < 0.85)
    }

    @Test func archiveSwellsCycleThroughDistinctTempoDivisions() {
        let patterns = (0..<10).map { MixBus.ArchiveEchoPattern.choose(seed: 16, phrase: $0) }
        #expect(Set(patterns.prefix(5).map(\.main)).count == 5)
        #expect(zip(patterns, patterns.dropFirst()).allSatisfy { $0 != $1 })
        for pattern in patterns {
            #expect(pattern.main != pattern.answer)
            #expect(pattern.spread != 0 && pattern.swell > 0)
            for division in [pattern.main, pattern.answer, pattern.room] {
                #expect(division > 0 && (division * 8).rounded() == division * 8)
            }
        }
    }

    @Test func futurePlaybackOriginHoldsAtZero() {
        let bus = MusicStateBus()
        bus.setStartUptime(DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
        #expect(bus.now() == 0)
    }

    @Test func preparedTapKeepsOldRepeatAndNewInputUsesTheNewTempo() throws {
        let engine = GenerativeEngine(seed: 17)
        let format = engine.archiveFormat
        let rate = format.sampleRate
        let capacity = AVAudioFrameCount(rate * 4)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
        buffer.frameLength = capacity
        let input = try #require(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for i in 0..<Int(capacity) {
                let t = Double(i) / rate
                let present = (0.50...0.55).contains(t) || (1.20...1.25).contains(t)
                input[channel][i] = present ? 0.24 * Float(sin(2 * .pi * 540 * t)) : 0
            }
        }
        let cue = ArchiveVoice.Cue(buffer: buffer, gain: 1, fadeIn: 0.10, label: "retime impulse")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("archive-retime-\(UUID()).wav")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("score.json"))
        }
        var begun = false
        var switched = false
        try engine.renderOffline(seconds: 5, to: url, archiveBeatDuration: 0.92, configure: { engine in
            engine.mix.dryBus.volume = 0
            engine.mix.mutedReturns = ["reverb", "shimmer"]
        }, onStep: { t in
            if !begun, t >= 1.0 { begun = true; engine.post(.archiveBegin(cue)) }
            if !switched, t >= 1.84 { switched = true; engine.mix.syncDelay(toBeatDuration: 0.68) }
        })
        let file = try AVAudioFile(forReading: url)
        let rendered = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: rendered)
        let output = try #require(rendered.floatChannelData)[0]
        func peak(_ start: Double, _ end: Double) -> Float {
            (Int(rate * start)..<Int(rate * end)).reduce(0) { max($0, abs(output[$1])) }
        }
        #expect(peak(2.39, 2.51) > 0.001) // Input at 1.50, retained on the 0.92 s line.
        #expect(peak(2.85, 2.98) > 0.001) // Input at 2.20, arrived at the 0.68 s repeat.
        #expect(peak(2.12, 2.26) < 0.0002)
        #expect(peak(3.09, 3.20) < 0.0002)
    }
}
