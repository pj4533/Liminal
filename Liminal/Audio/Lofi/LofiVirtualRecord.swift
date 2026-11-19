import Foundation

/// A small edit of the current original sample performance. The dry source stays intact
/// and the edit enters only the musical rack's send, so no extra recording must be stored.
nonisolated enum LofiVirtualRecord {
    struct Edit: Codable, Equatable, Sendable {
        enum Style: String, Codable, CaseIterable, Sendable {
            case replay, reverse, halfSpeed

            var rate: Double { self == .halfSpeed ? 0.5 : 1 }
        }

        let schema: Int
        let seed: UInt64
        let program: String
        let style: Style
        let sourceMIDI: Int
        let sourceBeat: Double
        let sourceOffset: Double
        let duration: Double
        let destinationBeat: Double
        let gain: Float
    }

    /// `protectedUntil` keeps every edit out of the opening span (the return's first melodic cell).
    static func choose(from notes: [LofiScore.Note], before foreground: Double,
                       section: LofiScore.Section, program: String, seed: UInt64,
                       protectedUntil: Double = 0) -> Edit? {
        guard section == .variation || section == .returnTheme, notes.count >= 2 else { return nil }
        var random = MusicRNG(seed: seed).fork(1239)
        guard random.chance(0.57) else { return nil }
        let style = random.pick([Edit.Style.replay, .replay, .reverse, .halfSpeed])
        let duration = random.range(0.29...0.48)
        // Snap the destination to an eighth-note, in the last sufficient gap. Leave space for
        // the dry note's release and to hear the original next attack as a separate gesture.
        let destinations = notes.enumerated().compactMap { index, note -> Double? in
            let start = ceil(2 * (note.beat + note.length + 0.58)) / 2
            let next = index + 1 < notes.count ? notes[index + 1].beat - 0.37 : foreground - 0.24
            return start + duration <= next && start >= protectedUntil ? start : nil
        }
        guard let destination = destinations.last else { return nil }
        let source = notes[0]
        return .init(schema: 1, seed: seed, program: program, style: style, sourceMIDI: source.midi,
                     sourceBeat: source.beat, sourceOffset: 0.052, duration: duration,
                     destinationBeat: destination, gain: random.rangeF(0.24...0.34))
    }

    static func splice(_ edit: Edit, from original: (left: [Float], right: [Float]),
                       into send: inout (left: [Float], right: [Float]), clock: LofiClock) {
        let start = clock.frame(at: edit.sourceBeat + edit.sourceOffset)
        let destination = clock.frame(at: edit.destinationBeat)
        let length = clock.frame(at: edit.duration)
        let rate = edit.style.rate
        let span = Double(length - 1) * rate
        guard length > 1, start >= 0, destination >= 0,
              start + Int(span) + 1 < min(original.left.count, original.right.count),
              destination + length <= min(send.left.count, send.right.count) else { return }
        let fade = max(1, Int(0.21 * Double(length)))
        let pole = Float(1 - exp(-2 * Double.pi * 2_150 / clock.sampleRate))
        var memory = SIMD2<Float>.zero
        for frame in 0..<length {
            let offset = Double(frame) * rate
            let position = edit.style == .reverse ? span - offset : offset
            let index = Int(position)
            let a = SIMD2(original.left[start + index], original.right[start + index])
            let b = SIMD2(original.left[start + index + 1], original.right[start + index + 1])
            let input = a + (b - a) * Float(position - Double(index))
            // A dark, gently saturated copy bleeds into the existing rack like a tiny overdub.
            memory += (input - memory) * pole
            let progress = min(1, Float(min(frame, length - 1 - frame)) / Float(fade))
            let window = progress * progress * (3 - 2 * progress)
            let peak = max(abs(memory.x), abs(memory.y))
            let wet = memory / (1 + 0.6 * peak)
            send.left[destination + frame] += wet.x * window * edit.gain
            send.right[destination + frame] += wet.y * window * edit.gain
        }
    }
}
