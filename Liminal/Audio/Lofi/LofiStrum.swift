import Foundation

/// One strummed gesture of the hook line (D128) and the notes it sounds. A stroke is a few strings
/// struck one after another (`spreadMs` apart, low first on a down-stroke, high first on an up-stroke),
/// then choked by the hand (`damp`) or left to ring (holds and harp rolls).
///
/// Each string's velocity is `L / sqrt(N)` times a taper (down: 1.10 on the lowest string to 0.90 on
/// the highest; up: 1.05 on the highest to 0.85 on the lowest), so an event's summed power is about the
/// same whatever its string count. The first sounding string lands on the event's `beat`.
nonisolated enum LofiStrum {
    enum Kind: Int, CaseIterable, Sendable { case stab, hold, up, dead, dyad, roll }
    /// Where an event sits against the drums: the eighth after a snare, two steps before a kick, with
    /// a kick (top strings only), or in a gap with no drum hit near it.
    enum Site: Int, CaseIterable, Sendable { case answer, push, withKick, gap }

    struct Event: Equatable, Sendable {
        /// Phrase-local bar 0...3 and sixteenth 0...15.
        var bar: Int
        var step: Int
        /// Onset of the first sounding string, in phrase beats.
        var beat: Double
        var kind: Kind
        var down: Bool
        /// MIDI, low to high.
        var strings: [Int]
        var spreadMs: Double
        /// Dry length in beats: every string is choked (or released) at `beat + length`.
        var length: Double
        var thrown: Bool
        var site: Site
        var archetype: Int
    }

    /// Per-kind starting values (plan 2.3); stage 5 tunes these against captures.
    enum Tuning {
        struct Shape: Sendable {
            let strings: ClosedRange<Int>
            let spreadMs: ClosedRange<Double>
            let length: ClosedRange<Double>
            /// Seconds; 0 rings for the program's release.
            let damp: Double
            /// The event's level L (summed over its strings).
            let level: Float
            /// Colour against the melody's tone, or the absolute colour when `absoluteColor`.
            let color: Double
            var absoluteColor = false
        }

        static let stab = Shape(strings: 3...4, spreadMs: 6...11, length: 0.25...0.5, damp: 0.025, level: 0.42, color: -0.08)
        static let dyad = Shape(strings: 2...2, spreadMs: 8...12, length: 0.5...0.5, damp: 0.025, level: 0.38, color: -0.06)
        /// An up-stroke's spread is `upSpreadScale` times the stab before it.
        static let up = Shape(strings: 2...3, spreadMs: 4.2...7.7, length: 0.2...0.2, damp: 0.025, level: 0.30, color: -0.02)
        static let dead = Shape(strings: 2...3, spreadMs: 10...14, length: 0.07...0.07, damp: 0.015, level: 0.14,
                                color: 0, absoluteColor: true)
        static let hold = Shape(strings: 4...5, spreadMs: 18...30, length: 1.5...2.5, damp: 0, level: 0.46, color: -0.04)
        static let roll = Shape(strings: 3...5, spreadMs: 40...70, length: 1.0...2.5, damp: 0, level: 0.44, color: 0)

        static let upSpreadScale = 0.7
        /// Stab length, and archetype B's answer.
        static let stabLength = 0.25
        static let answerLength = 0.5
        /// Down-stroke taper, lowest to highest string; up-stroke taper, highest to lowest.
        static let downTaper: (first: Float, last: Float) = (1.10, 0.90)
        static let upTaper: (first: Float, last: Float) = (1.05, 0.85)
        /// Send of a plain and of a thrown event (the renderer maps it to `0.10 + 1.25 * send`).
        static let plainSend: Float = 0.10
        static let thrownSend: Float = 0.90

        static func shape(_ kind: Kind) -> Shape {
            switch kind {
            case .stab: stab
            case .dyad: dyad
            case .up: up
            case .dead: dead
            case .hold: hold
            case .roll: roll
            }
        }
    }

    /// The `.strum` notes of `event`, in stroke order. `tone` is the melody's colour for the program.
    static func notes(for event: Event, tone: Double, beatSeconds: Double) -> [LofiScore.Note] {
        let count = event.strings.count
        guard count > 0 else { return [] }
        let shape = Tuning.shape(event.kind)
        let beat = max(0.001, beatSeconds)
        let spread = event.spreadMs / 1000 / beat
        let end = event.beat + event.length
        let perString = shape.level / sqrtf(Float(count))
        let color = min(1, max(0, shape.absoluteColor ? shape.color : tone + shape.color))
        let send = event.thrown ? Tuning.thrownSend : Tuning.plainSend
        let taper = event.down ? Tuning.downTaper : Tuning.upTaper
        // Stroke order: low to high on a down-stroke, high to low on an up-stroke.
        let order = event.down ? Array(event.strings) : Array(event.strings.reversed())
        return order.enumerated().map { k, midi in
            let u = count > 1 ? Float(k) / Float(count - 1) : 0
            let onset = event.beat + Double(k) * spread
            var note = LofiScore.Note(part: .strum, midi: midi, beat: onset, length: max(0.02, end - onset),
                                      velocity: perString * (taper.first + (taper.last - taper.first) * u),
                                      color: color, send: send)
            note.damp = shape.damp
            return note
        }
    }
}
