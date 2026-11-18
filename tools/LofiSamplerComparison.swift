import AudioToolbox
import AVFoundation
import Foundation

@main struct CompareSamplers {
    static func main() throws {
        let sampleRoot = URL(filePath: "Liminal/Audio/Lofi/InstrumentSamples", directoryHint: .isDirectory)
        let source = sampleRoot.appending(path: "LofiLead-grand-62.wav")
        let scoreClock = LofiClock(tempo: 70, sampleRate: 48_000)
        let note = LofiScore.Note(part: .lead, midi: 60, beat: 0.5, length: 0.6, velocity: 0.57)
        let total = 80_000
        let onset = scoreClock.frame(at: note.beat)
        let release = scoreClock.frame(at: note.beat + note.length)
        let preset = (0..<72).map { LofiPreset.selection(seed: 32, phrase: $0) }.first { $0.sampleGroup == "grand" }!
        let started = ProcessInfo.processInfo.systemUptime
        let bank = LofiSampleBank(urls: [source])
        let sample = bank.sample(for: preset, midi: note.midi, velocity: note.velocity)!
        let nativeLoaded = ProcessInfo.processInfo.systemUptime
        var nativeLeft = [Float](repeating: 0, count: total)
        var nativeRight = nativeLeft
        nativeLeft.withUnsafeMutableBufferPointer { l in
            nativeRight.withUnsafeMutableBufferPointer { r in
                LofiSampleBank.add(note, from: sample, preset: preset, clock: scoreClock, left: l, right: r)
            }
        }
        let nativeRendered = ProcessInfo.processInfo.systemUptime

        var component = AudioComponentDescription(componentType: kAudioUnitType_MusicDevice,
                                                  componentSubType: kAudioUnitSubType_Sampler,
                                                  componentManufacturer: kAudioUnitManufacturer_Apple,
                                                  componentFlags: 0, componentFlagsMask: 0)
        guard AudioComponentFindNext(nil, &component) != nil else {
            throw NSError(domain: "Apple's Sampler Audio Unit is unavailable in this process", code: 1)
        }
        let auStarted = ProcessInfo.processInfo.systemUptime
        let stillUnmapped = try appleSampler(source: source, tune: 0, score: note, total: total, onset: onset, release: release)
        // A root-tagged Apple instrument would do this per zone, rather than as a global adjustment.
        let mapped = try appleSampler(source: source, tune: -200, score: note, total: total, onset: onset, release: release)
        let auRendered = ProcessInfo.processInfo.systemUptime

        func describe(_ name: String, samples: [Float]) {
            let peak = samples.reduce(0) { max($0, abs($1)) }
            let first = samples.firstIndex { abs($0) > 0.01 * peak } ?? total
            let final = samples.lastIndex { abs($0) > 0.01 * peak } ?? 0
            print(name, "peak", peak, "onset_1pct_samples", first - onset,
                  "release_1pct_ms", 1000.0 * Double(final - release) / scoreClock.sampleRate)
            func power(at f: Double) -> Double {
                var re = 0.0, im = 0.0
                for i in 0..<10_000 {
                    let phase = 2 * Double.pi * f * Double(i) / scoreClock.sampleRate
                    let s = Double(samples[onset + 2500 + i]) * (0.5 - 0.5 * cos(2 * Double.pi * Double(i) / 10_000))
                    re += s * cos(phase)
                    im += s * sin(phase)
                }
                return re * re + im * im
            }
            let winner = stride(from: 230.0, through: 330, by: 0.25).max { power(at: $0) < power(at: $1) }!
            print(name, "dominant_fundamental_hz", winner)
        }

        print("clock", scoreClock.sampleRate, "prompt_midi", note.midi, "source_root", sample.root,
              "source_bytes", (try FileManager.default.attributesOfItem(atPath: source.path)[.size])!,
              "pcm_bytes", MemoryLayout<Float>.stride * sample.pcm.count)
        describe("Liminal", samples: nativeLeft)
        describe("Apple file load", samples: stillUnmapped)
        describe("Apple mapped", samples: mapped)
        print("load/render_ms", (nativeLoaded - started) * 1000, (nativeRendered - nativeLoaded) * 1000,
              "AU_two_graphs_and_renders_ms", (auRendered - auStarted) * 1000)
        if let directory = CommandLine.arguments.dropFirst().first {
            let output = URL(filePath: directory, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try audition("liminal.wav", nativeLeft, onset: onset, sampleRate: scoreClock.sampleRate, output: output)
            try audition("apple.wav", mapped, onset: onset, sampleRate: scoreClock.sampleRate, output: output)
        }
    }

    // Level match the shared 210 ms of steady-state body and preserve both releases.
    private static func audition(_ name: String, _ samples: [Float], onset: Int, sampleRate: Double,
                                 output: URL) throws {
        let range = onset + 2500..<onset + 12_500
        let rms = sqrtf(samples[range].reduce(0) { $0 + $1 * $1 } / Float(range.count))
        let gain = 0.065 / max(rms, 1e-6)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for frame in samples.indices {
            buffer.floatChannelData![0][frame] = gain * samples[frame]
        }
        let file = try AVAudioFile(forWriting: output.appending(path: name), settings: format.settings)
        try file.write(from: buffer)
    }

    private static func appleSampler(source: URL, tune: Float, score: LofiScore.Note,
                                     total: Int, onset: Int, release: Int) throws -> [Float] {
        let engine = AVAudioEngine()
        let sampler = AVAudioUnitSampler()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: format)
        try sampler.loadAudioFiles(at: [source])
        sampler.globalTuning = tune
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        try engine.start()

        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                      frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var result = [Float]()
        var rendered = 0
        while rendered < total {
            if rendered == onset {
                sampler.startNote(UInt8(score.midi), withVelocity: UInt8(score.velocity * 127), onChannel: 0)
            }
            if rendered == release { sampler.stopNote(UInt8(score.midi), onChannel: 0) }
            let end = min(rendered + 512, [onset, release, total].first { $0 > rendered }!)
            let status = try engine.renderOffline(AVAudioFrameCount(end - rendered), to: buffer)
            guard status == .success, let left = buffer.floatChannelData?[0] else {
                throw NSError(domain: "CompareSamplers", code: status.rawValue)
            }
            result.append(contentsOf: UnsafeBufferPointer(start: left, count: Int(buffer.frameLength)))
            rendered = end
        }
        engine.stop()
        return result
    }
}
