import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// Render probe for guitar programs (D114 loudness match, D128 gate): eight phrases per program at
/// 72 BPM and 48 kHz through `LofiRenderer.render`, the guitar forced by the audition, against eight
/// Steinway Grand phrases of the same seed. Prints the integrated level and loudest 400 ms of
/// dry + texture + wet, and the 2-5 kHz share of that sum and of the dry stem alone.
/// Disabled unless `LIMINAL_STRUM_PROBE` is set (`TEST_RUNNER_LIMINAL_STRUM_PROBE=1 xcodebuild test ...
/// -only-testing:LiminalTests/LofiStrumProbeTests`). Lines start with `STRUM-PROBE` and are appended to
/// `LIMINAL_DIAG` (default: the temporary directory) and recorded as an attachment.
struct LofiStrumProbeTests {
    static let rate = 48_000.0
    static let tempo = 72.0
    static let seed: UInt64 = 1042

    struct Reading {
        let integrated: Double
        let momentaryMax: Double
        let share: Double
        let dryShare: Double
    }

    static func render(_ phrase: Int, audition: LofiScore.Audition = .none) throws -> LofiRenderer.Phrase {
        try LofiRenderer.render(seed: seed, section: LofiScore.section(at: phrase), options: .init(tempo: tempo),
                                sampleRate: rate, drift: .init(seed: seed),
                                startBeat: Double(phrase) * LofiClock.beats, audition: audition)
    }

    static func samples(_ buffer: AVAudioPCMBuffer, _ channel: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
    }

    static func bandShare(_ left: [Float], _ right: [Float]) -> Double {
        var l = left, r = right
        let q = LofiStemChains.butterworthQ
        var chain = LofiFilterChain([.highpass(hz: 2_000, q: q), .highpass(hz: 2_000, q: q),
                                     .lowpass(hz: 5_000, q: q), .lowpass(hz: 5_000, q: q)], sampleRate: rate)
        chain.process(left: &l, right: &r)
        let band = zip(l, r).reduce(0.0) { $0 + Double($1.0 * $1.0 + $1.1 * $1.1) }
        let total = zip(left, right).reduce(0.0) { $0 + Double($1.0 * $1.0 + $1.1 * $1.1) }
        return 10 * log10(max(band, 1e-20) / max(total, 1e-20))
    }

    static func measure(_ phrases: [LofiRenderer.Phrase]) -> Reading {
        var left = [Float](), right = [Float](), dryL = [Float](), dryR = [Float]()
        for phrase in phrases {
            let d = (samples(phrase.dry, 0), samples(phrase.dry, 1))
            let t = (samples(phrase.texture, 0), samples(phrase.texture, 1))
            let w = (samples(phrase.wet, 0), samples(phrase.wet, 1))
            for i in d.0.indices {
                left.append(d.0[i] + t.0[i] + w.0[i])
                right.append(d.1[i] + t.1[i] + w.1[i])
            }
            dryL += d.0
            dryR += d.1
        }
        let loudness = LofiLoudness.measure(left: left, right: right, sampleRate: rate)
        return Reading(integrated: loudness.integrated, momentaryMax: loudness.momentaryMax,
                       share: bandShare(left, right), dryShare: bandShare(dryL, dryR))
    }

    static func log(_ line: String, into lines: inout [String]) {
        print(line)
        lines.append(line)
        let path = ProcessInfo.processInfo.environment["LIMINAL_DIAG"]
            ?? NSTemporaryDirectory() + "liminal-strum-probe.txt"
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIMINAL_STRUM_PROBE"] != nil))
    func guitarProgramsAgainstTheGrand() throws {
        var lines: [String] = []
        let grandPhrases = (0..<512).filter { LofiPreset.selection(seed: Self.seed, phrase: $0).name == "Steinway Grand" }
        let grand = Self.measure(try grandPhrases.prefix(8).map { try Self.render($0) })
        Self.log(String(format: "STRUM-PROBE grand integrated %.2f LUFS momentaryMax %.2f share %.1f dB dryShare %.1f dB",
                        grand.integrated, grand.momentaryMax, grand.share, grand.dryShare), into: &lines)
        for program in LofiPreset.guitars {
            // Alternate the guitar between the variation (phrase 1) and the breakdown (phrase 2) of eight takes.
            let phrases = try (0..<8).map { record -> LofiRenderer.Phrase in
                let slot = record.isMultiple(of: 2) ? 1 : 2
                let audition = LofiScore.Audition(guitarProgram: program.name, guitarSlot: slot)
                let phrase = try Self.render(record * 4 + slot, audition: audition)
                #expect(phrase.score.preset.name == program.name)
                return phrase
            }
            let reading = Self.measure(phrases)
            Self.log(String(format: "STRUM-PROBE %@ level %.2f brightness %.2f integrated %.2f (%+.2f LU) momentaryMax %+.2f dB over grand share %.1f dB dryShare %.1f dB",
                            program.name, Double(program.levelDB), program.brightness, reading.integrated,
                            reading.integrated - grand.integrated, reading.momentaryMax - grand.momentaryMax,
                            reading.share, reading.dryShare), into: &lines)
        }
        Attachment.record(lines.joined(separator: "\n") + "\n", named: "strum-probe.txt")
    }
}
