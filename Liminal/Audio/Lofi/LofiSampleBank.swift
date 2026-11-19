import AVFoundation
import Foundation

/// Compact multisamples for the pitched lead. Drum recordings use their own library.
nonisolated struct LofiSampleBank: Sendable {
    struct Sample: Sendable {
        let root: Int
        let layer: Int
        let recordedRoot: Int
        let rate: Double
        let pcm: [Float]
    }

    static let bundled = Self(urls: Bundle.main.urls(forResourcesWithExtension: "wav", subdirectory: nil) ?? [])
    // These original files retain source labels one octave below concert pitch.
    private static let octaveLowLabels: Set<String> = ["upright", "yamaha", "pizz", "cellopluck", "organ", "psaltery"]
    private let groups: [String: [Sample]]

    init(urls: [URL]) {
        var groups: [String: [Sample]] = [:]
        for url in urls {
            let fields = url.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard (3...4).contains(fields.count), fields[0] == "LofiLead", let root = Int(fields[2])
            else { continue }
            let layer = fields.count == 4 ? Int(fields[3]) ?? 2 : 2
            let group = String(fields[1])
            let recordedRoot = Self.octaveLowLabels.contains(group) ? root + 12 : root
            guard let sample = try? Self.load(url, root: root, layer: layer, recordedRoot: recordedRoot)
            else { continue }
            groups[group, default: []].append(sample)
        }
        self.groups = groups.mapValues { samples in
            samples.sorted { $0.root == $1.root ? $0.layer < $1.layer : $0.root < $1.root }
        }
    }

    func sample(for preset: LofiPreset, midi: Int, velocity: Float = 0.55) -> Sample? {
        guard let recordings = groups[preset.sampleGroup] else { return nil }
        let layer = velocity >= 0.60 ? 3 : 2
        return recordings.min { a, b in
            let distanceA = abs(a.root - midi)
            let distanceB = abs(b.root - midi)
            if distanceA != distanceB { return distanceA < distanceB }
            return abs(a.layer - layer) < abs(b.layer - layer)
        }
    }

    func count(for preset: LofiPreset) -> Int { groups[preset.sampleGroup]?.count ?? 0 }

    private static func load(_ url: URL, root: Int, layer: Int, recordedRoot: Int) throws -> Sample {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.channelCount == 1, file.length > 0, file.length <= 3 * Int64(format.sampleRate),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { throw SampleError.format }
        try file.read(into: buffer)
        guard let pcm = buffer.floatChannelData?[0], buffer.frameLength > 1 else { throw SampleError.format }
        return Sample(root: root, layer: layer, recordedRoot: recordedRoot, rate: format.sampleRate,
                      pcm: Array(UnsafeBufferPointer(start: pcm, count: Int(buffer.frameLength))))
    }

    private enum SampleError: Error { case format }

    static func add(_ note: LofiScore.Note, from sample: Sample, preset: LofiPreset, clock: LofiClock,
                    left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>) {
        let start = clock.frame(at: note.beat)
        let hold = clock.frame(at: note.length)
        let rate = clock.sampleRate
        let speed = sample.rate / rate * pow(2, Double(note.midi - sample.recordedRoot) / 12)
        let release = max(1, Int(preset.release * rate))
        let attack = max(1, Int(max(0.003, preset.attack) * rate))
        let count = min(hold + release, left.count - start)
        guard count > 1 else { return }
        let pan: Float = 0.04
        let l = sqrtf(0.5 * (1 - pan))
        let r = sqrtf(0.5 * (1 + pan))
        let presence = 2_150 + 1_750 * preset.brightness + 410 * note.color
        let color = min(presence, rate * 0.22)
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
            let tone = (0.57 * filtered + 0.43 * body) * onset * fall * fall * edge * note.velocity * preset.gain
            left[start + i] += tone * l
            right[start + i] += tone * r
            position += speed * (1 + drift * sin(Double(i) * (2 * .pi * 0.6 / rate)))
        }
    }
}
