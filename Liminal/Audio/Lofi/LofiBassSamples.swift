import AVFoundation
import Foundation

/// The sampled body layer of the bass (`LofiBass-<kit>-<stroke>-<midi>[-<rr>].wav`, plan 2.1): CC0
/// Karoryfer Sneakybass (`upright`) and Swagbass (`flatwound`), measured and retuned to within 3 cents
/// by `scripts/prepare-lofi-samples.py`. The roots in the file names are the sounding MIDI notes.
/// Mono only, at most 3 s per file, decoded like `LofiSampleBank.load`. Read off the audio thread.
nonisolated struct LofiBassSamples: Sendable {
    enum Kit: String, Sendable, CaseIterable { case upright, flatwound }
    /// The prepared articulation of a file. `short` feeds `thump`, `long` feeds `walk` and `hold`.
    enum Stroke: String, Sendable { case short, long, ghost }

    struct Sample: Sendable {
        let root: Int
        let roundRobin: Int
        let rate: Double
        let pcm: [Float]
        /// First frame within 40 dB of the file's peak, less 1 ms: playback starts here, so round robins
        /// with different lead silence (0 to 31 ms on the upright) all speak on the note's first frame.
        var onset: Int = 0
    }

    static let bundled = Self(urls: Bundle.main.urls(forResourcesWithExtension: "wav", subdirectory: nil) ?? [])

    private struct Key: Hashable { let kit: Kit; let stroke: Stroke }
    private let groups: [Key: [Sample]]

    init(urls: [URL]) {
        var groups: [Key: [Sample]] = [:]
        for url in urls {
            let fields = url.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard (4...5).contains(fields.count), fields[0] == "LofiBass",
                  let kit = Kit(rawValue: String(fields[1])), let stroke = Stroke(rawValue: String(fields[2])),
                  let root = Int(fields[3]) else { continue }
            let roundRobin = fields.count == 5 ? Int(fields[4]) ?? 1 : 1
            guard let sample = try? Self.load(url, root: root, roundRobin: roundRobin) else { continue }
            groups[Key(kit: kit, stroke: stroke), default: []].append(sample)
        }
        self.groups = groups.mapValues { $0.sorted { ($0.root, $0.roundRobin) < ($1.root, $1.roundRobin) } }
    }

    var isEmpty: Bool { groups.isEmpty }

    func count(kit: Kit) -> Int { groups.filter { $0.key.kit == kit }.values.reduce(0) { $0 + $1.count } }

    func has(kit: Kit, stroke: Stroke) -> Bool { !(groups[Key(kit: kit, stroke: stroke)]?.isEmpty ?? true) }

    /// The nearest root for `midi` (the lower root on a tie, so the body is transposed up rather than
    /// down), with the round robin chosen by `hash`.
    func sample(kit: Kit, stroke: Stroke, midi: Int, hash: UInt64 = 0) -> Sample? {
        guard let recordings = groups[Key(kit: kit, stroke: stroke)], !recordings.isEmpty else { return nil }
        let root = recordings.map(\.root).min { a, b in
            let da = abs(a - midi), db = abs(b - midi)
            return da != db ? da < db : a < b
        }!
        let robins = recordings.filter { $0.root == root }
        return robins[Int(hash % UInt64(robins.count))]
    }

    private static func load(_ url: URL, root: Int, roundRobin: Int) throws -> Sample {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.channelCount == 1, file.length > 0, file.length <= 3 * Int64(format.sampleRate),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { throw SampleError.format }
        try file.read(into: buffer)
        guard let pcm = buffer.floatChannelData?[0], buffer.frameLength > 1 else { throw SampleError.format }
        let samples = Array(UnsafeBufferPointer(start: pcm, count: Int(buffer.frameLength)))
        return Sample(root: root, roundRobin: roundRobin, rate: format.sampleRate, pcm: samples,
                      onset: onset(samples, rate: format.sampleRate))
    }

    /// First frame within 40 dB of the peak, less 1 ms (at least 0).
    static func onset(_ pcm: [Float], rate: Double) -> Int {
        let peak = pcm.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0 else { return 0 }
        let threshold = peak * 0.01
        let first = pcm.firstIndex { abs($0) >= threshold } ?? 0
        return max(0, first - Int(0.001 * rate))
    }

    private enum SampleError: Error { case format }
}
