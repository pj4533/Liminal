import AVFoundation
import Foundation

/// Compact multisamples for the pitched lead. Drum recordings use their own library.
nonisolated struct LofiSampleBank: Sendable {
    struct Sample: Sendable {
        let root: Int
        let rate: Double
        let pcm: [Float]
    }

    static let bundled = Self(urls: Bundle.main.urls(forResourcesWithExtension: "wav", subdirectory: nil) ?? [])
    private let groups: [String: [Sample]]

    init(urls: [URL]) {
        var groups: [String: [Sample]] = [:]
        for url in urls {
            let fields = url.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard fields.count == 3, fields[0] == "LofiLead", let root = Int(fields[2]),
                  let sample = try? Self.load(url, root: root) else { continue }
            groups[String(fields[1]), default: []].append(sample)
        }
        self.groups = groups.mapValues { $0.sorted { $0.root < $1.root } }
    }

    func sample(for preset: LofiPreset, midi: Int) -> Sample? {
        groups[preset.sampleGroup]?.min { abs($0.root - midi) < abs($1.root - midi) }
    }

    func count(for preset: LofiPreset) -> Int { groups[preset.sampleGroup]?.count ?? 0 }

    private static func load(_ url: URL, root: Int) throws -> Sample {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.channelCount == 1, file.length > 0, file.length <= 3 * Int64(format.sampleRate),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { throw SampleError.format }
        try file.read(into: buffer)
        guard let pcm = buffer.floatChannelData?[0], buffer.frameLength > 1 else { throw SampleError.format }
        return Sample(root: root, rate: format.sampleRate,
                      pcm: Array(UnsafeBufferPointer(start: pcm, count: Int(buffer.frameLength))))
    }

    private enum SampleError: Error { case format }

    static func add(_ note: LofiScore.Note, from sample: Sample, preset: LofiPreset, clock: LofiClock,
                    left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>) {
        let start = clock.frame(at: note.beat)
        let hold = clock.frame(at: note.length)
        let rate = clock.sampleRate
        let speed = sample.rate / rate * pow(2, Double(note.midi - sample.root) / 12)
        let release = max(1, Int(preset.release * rate))
        let attack = max(1, Int(max(0.018, preset.attack + 0.013) * rate))
        let count = min(hold + release, left.count - start)
        guard count > 1 else { return }
        let pan = Float(note.midi % 5 - 2) * 0.16
        let l = sqrtf(0.5 * (1 - pan))
        let r = sqrtf(0.5 * (1 + pan))
        let presence = 1_700 + 1_500 * preset.brightness + 380 * note.color
        let color = min(presence, (preset.family == .brass || preset.family == .mallets) ? 2_400 : 3_150)
        let coefficient = Float(1 - exp(-2 * .pi * color / rate))
        let drift = preset.movement * 0.0025
        var filtered: Float = 0
        var body: Float = 0
        var position = 0.0
        for i in 0..<count {
            let j = Int(position)
            guard j + 1 < sample.pcm.count else { break }
            let fraction = Float(position - Double(j))
            let input = sample.pcm[j] + fraction * (sample.pcm[j + 1] - sample.pcm[j])
            filtered += (input - filtered) * coefficient
            body += (filtered - body) * coefficient
            let rise = min(1, Float(i) / Float(attack))
            let fall = i < hold ? 1 : 1 - Float(i - hold) / Float(release)
            let edge = min(1, Float(count - 1 - i) / 64)
            let onset = rise * rise * (3 - 2 * rise)
            let tone = (0.37 * filtered + 0.63 * body) * onset * fall * fall * edge * note.velocity * preset.gain
            left[start + i] += tone * l
            right[start + i] += tone * r
            position += speed * (1 + drift * sin(Double(i) * (2 * .pi * 0.6 / rate)))
        }
    }
}
