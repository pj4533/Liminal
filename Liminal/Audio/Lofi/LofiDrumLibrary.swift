import Accelerate
import AVFoundation
import Foundation

/// Reads the verified AJ Hall recordings installed with a private build.
nonisolated enum LofiDrumLibrary {
    struct Entry: Codable, Equatable, Sendable {
        let name: String
        let sha256: String
        let bpm: Double
        let beats: Int
        let sampleRate: Double
        let channels: Int
        let frameCount: Int
        let framesPerBeat: Double
        let onsetPhaseMilliseconds: Double
        let beatSupport: Double
        var filename: String { sha256 + ".wav" }
        var hasFileHash: Bool {
            sha256.utf8.count == 64 && sha256.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
        }
    }

    struct Break: Sendable {
        let entry: Entry
        let left: [Float]
        let right: [Float]
        let gain: Float
    }

    struct Asset: Equatable, Sendable {
        let entry: Entry
        let url: URL
    }

    enum LibraryError: Error {
        case badRecording, invalidManifest
    }

    private static let directory = URL.applicationSupportDirectory.appending(path: "Liminal/Slow Burn Vol. 3", directoryHint: .isDirectory)

    static func assets() -> [Asset] {
        let fm = FileManager.default
        let bundled = manifest(Bundle.main.url(forResource: "SlowBurnBeatGrid", withExtension: "json")).compactMap { entry -> Asset? in
            guard tempo(in: entry.name) == entry.bpm,
                  entry.name == (entry.name as NSString).lastPathComponent,
                  let url = Bundle.main.url(forResource: entry.name, withExtension: "wav") else { return nil }
            return Asset(entry: entry, url: url)
        }
        if !bundled.isEmpty { return bundled }

        // Private builds can include the WAVs alone. A full-length file and its labeled tempo
        // give us the source grid without shipping a catalog of the recordings.
        let local = (Bundle.main.urls(forResourcesWithExtension: "wav", subdirectory: nil) ?? [])
            .compactMap { bundledBreak(at: $0) }
            .sorted { $0.entry.name < $1.entry.name }
        if !local.isEmpty { return local }

        // Older builds stored verified copies in Application Support.
        return manifest(directory.appending(path: "breaks.json")).compactMap { entry in
            guard entry.hasFileHash else { return nil }
            let url = directory.appending(component: entry.filename)
            guard fm.fileExists(atPath: url.path) else { return nil }
            return Asset(entry: entry, url: url)
        }
    }

    private static func bundledBreak(at url: URL) -> Asset? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("AJ_HALL_DRUM_BREAK_"), let bpm = tempo(in: name),
              let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        let channels = Int(file.processingFormat.channelCount)
        let frames = Int(file.length)
        let beats = 64
        guard (1...2).contains(channels), (22050...96000).contains(rate),
              abs(Double(frames) - Double(beats) * rate * 60 / bpm) <= 2 else { return nil }
        let entry = Entry(name: name, sha256: "", bpm: bpm, beats: beats, sampleRate: rate, channels: channels,
                          frameCount: frames, framesPerBeat: Double(frames) / Double(beats),
                          onsetPhaseMilliseconds: 0, beatSupport: 0)
        return Asset(entry: entry, url: url)
    }

    private static func manifest(_ url: URL?) -> [Entry] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    static func load(_ asset: Asset) throws -> Break {
        let entry = asset.entry
        guard entry.bpm.isFinite, (45...120).contains(entry.bpm), entry.beats == 64, entry.frameCount > 0,
           entry.framesPerBeat.isFinite, entry.framesPerBeat > 0 else { throw LibraryError.invalidManifest }
        let pcm = try read(asset.url)
        guard Int(pcm.0.frameLength) == entry.frameCount, pcm.0.format.sampleRate == entry.sampleRate, Int(pcm.0.format.channelCount) == entry.channels else { throw LibraryError.invalidManifest }
        let n = entry.frameCount
        let left = Array(UnsafeBufferPointer(start: pcm.1[0], count: n))
        let right = entry.channels == 1 ? left : Array(UnsafeBufferPointer(start: pcm.1[1], count: n))
        return normalizedBreak(entry: entry, left: left, right: right)
    }

    /// Apply the whole-take stereo calibration used by playback and by offline drum fixtures.
    static func normalizedBreak(entry: Entry, left: [Float], right: [Float]) -> Break {
        let energy = 0.5 * (vDSP.meanSquare(left) + vDSP.meanSquare(right))
        let gain = min(2.6, 0.11 / max(0.025, energy.squareRoot()))
        return Break(entry: entry, left: left, right: right, gain: gain)
    }

    static func tempo(in filename: String) -> Double? {
        let pattern = #"(?i)(?<![\d.])(\d{2,3}(?:\.\d+)?)\s*[-_ ]?\s*bpm\b"#
        let alternate = #"(?i)\bbpm\s*[-_ ]?\s*(\d{2,3}(?:\.\d+)?)"#
        let trailing = #"(?:^|[\s_-])(\d{2,3}(?:\.\d+)?)(?:[\s_)]*)$"#
        for expression in [pattern, alternate, trailing] {
            guard let regex = try? NSRegularExpression(pattern: expression),
                  let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
                  let range = Range(match.range(at: 1), in: filename),
                  let bpm = Double(filename[range]), (45...120).contains(bpm) else { continue }
            return bpm
        }
        return nil
    }

    private static func read(_ url: URL) throws -> (AVAudioPCMBuffer, UnsafePointer<UnsafeMutablePointer<Float>>) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard (1...2).contains(Int(format.channelCount)), (22050...96000).contains(format.sampleRate),
              file.length > 0, Double(file.length) / format.sampleRate <= 70,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { throw LibraryError.badRecording }
        try file.read(into: buffer)
        guard let samples = buffer.floatChannelData else { throw LibraryError.badRecording }
        return (buffer, samples)
    }

}
