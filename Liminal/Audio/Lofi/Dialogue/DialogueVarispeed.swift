import Foundation

/// Offline, line-local turntable matching. No random pitch independent of the speech cadence.
nonisolated enum DialogueVarispeed {
    static let maximumSemitones = 2.5

    static func transform(line: SpeechUnit, features: DialogueFeatures? = nil, sampleRate: Double, beatDuration: Double) -> DialogueTransform {
        guard line.nuclei >= 2, sampleRate > 0 else { return .native }
        let onsets = features?.nuclei.filter { line.frames.contains($0.onsetFrame) }.map(\.onsetFrame) ?? []
        let intervals = zip(onsets, onsets.dropFirst()).map { Double($1 - $0) / sampleRate }
            .filter { (0.08...0.8).contains($0) }.sorted()
        let period = intervals.isEmpty ? Double(line.frames.count) / sampleRate / Double(line.nuclei)
            : intervals[intervals.count / 2]
        return transform(period: period, beatDuration: beatDuration)
    }

    /// Place the average natural syllable interval on the closest metrical subdivision. Compare in
    /// pitch space, then limit the coupled speed/pitch change to keep the sentence recognizable.
    static func transform(period: Double, beatDuration: Double) -> DialogueTransform {
        guard period.isFinite, period > 0, beatDuration.isFinite, beatDuration > 0 else { return .native }
        let candidates = [0.25, 0.5, 1.0, 2.0].map { 12 * log2(period / (beatDuration * $0)) }
        let nearest = candidates.min { abs($0) < abs($1) } ?? 0
        let semitones = min(maximumSemitones, max(-maximumSemitones, nearest))
        return abs(semitones) < 1e-9 ? .native : .linkedRate(semitones: semitones)
    }
}
