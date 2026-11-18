import Foundation

/// A break has a principal piano, two contrasting voices, and a return to the piano.
/// Acoustic pianos and plucks predominate, with an occasional quiet organ registration.
nonisolated struct LofiPreset: Equatable, Sendable {
    enum Family: Int, CaseIterable, Sendable { case piano, strings, organ }

    struct Space: Sendable {
        let taps: (left: Double, right: Double)
        let feedback: Float
        let diffusion: Float
        let particles: Float
        let stereo: Float

        static let standard = Self(taps: LofiClock.musicEchoBeats, feedback: 0.52,
                                   diffusion: 0.9, particles: 0.9, stereo: 0.48)
    }

    let name: String
    let sampleGroup: String
    let family: Family
    let brightness: Double
    let movement: Double
    let attack: Double
    let release: Double
    let gain: Float
    let space: Space

    static func selection(seed: UInt64, phrase: Int) -> Self {
        let root = MusicRNG(seed: seed).fork(253)
        let record = phrase / 4
        let pianos = bank.filter { $0.family == .piano }
        let plucks = bank.filter { $0.family == .strings }
        let organ = organProgram
        let piano = root.fork(100).shuffledCycle(pianos, index: record)
        let strings = root.fork(101).shuffledCycle(plucks, index: record)
        var order = root.fork(UInt64(record) + 615)
        let voices = order.chance(0.60) ? [piano, strings, organ, piano] : [piano, organ, strings, piano]
        return voices[phrase % 4]
    }

    private init(_ name: String, _ sampleGroup: String, _ family: Family, _ brightness: Double, _ movement: Double,
                 _ attack: Double, _ release: Double, _ gain: Float, _ taps: (Double, Double),
                 _ feedback: Float, _ diffusion: Float, _ particles: Float, _ stereo: Float) {
        self.name = name
        self.sampleGroup = sampleGroup
        self.family = family
        self.brightness = brightness
        self.movement = movement
        self.attack = attack
        self.release = release
        self.gain = gain
        self.space = Space(taps: taps, feedback: feedback, diffusion: diffusion, particles: particles, stereo: stereo)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name }

    private static let organProgram = Self("Quiet Pipe Organ", "organ", .organ, 0.38, 0.09, 0.021, 0.24, 0.34, (0.5, 1.5), 0.39, 0.91, 0.59, 0.34)

    private static let bank: [Self] = [
        .init("Steinway Grand", "grand", .piano, 0.62, 0.32, 0.003, 0.27, 0.49, (0.75, 1.5), 0.52, 1.04, 0.84, 0.42),
        .init("Knight Upright", "upright", .piano, 0.49, 0.18, 0.006, 0.31, 0.50, (1, 1.75), 0.50, 1.10, 0.80, 0.57),
        .init("Yamaha Upright", "yamaha", .piano, 0.47, 0.20, 0.006, 0.30, 0.52, (1, 1.5), 0.48, 1.13, 0.80, 0.52),
        .init("Pizzicato Viola", "pizz", .strings, 0.61, 0.26, 0.004, 0.22, 0.54, (0.75, 1.75), 0.61, 1.06, 0.87, 0.73),
        .init("Pizzicato Cello", "cellopluck", .strings, 0.50, 0.19, 0.006, 0.29, 0.55, (0.75, 1.5), 0.53, 1.12, 0.86, 0.60),
        .init("Concert Harp", "harp", .strings, 0.51, 0.16, 0.004, 0.29, 0.51, (1, 1.75), 0.51, 1.18, 0.88, 0.61),
        .init("Plucked Psaltery", "psaltery", .strings, 0.40, 0.14, 0.004, 0.27, 0.46, (0.75, 1.25), 0.42, 0.99, 0.69, 0.46),
        organProgram
    ]
}
