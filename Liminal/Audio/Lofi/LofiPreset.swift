import Foundation

/// Hidden instrument programs. Families rotate in a seeded order and all registrations
/// within a family are heard before they repeat.
nonisolated struct LofiPreset: Equatable, Sendable {
    enum Family: Int, CaseIterable, Sendable { case organ, piano, strings, winds, brass, mallets }

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
        let families = Family.allCases
        let family = root.shuffledCycle(families, index: phrase)
        var registration = root.fork(UInt64(family.rawValue) + 100)
        let program = (phrase / families.count + registration.int(0...1)) % 2
        return bank[family.rawValue * 2 + program]
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

    private static let bank: [Self] = [
        .init("Renaissance Organ", "chapel", .organ, 0.58, 0.22, 0.024, 0.20, 0.47, (1.5, 2.25), 0.58, 1.24, 0.96, 0.38),
        .init("Pipe Organ", "pipe", .organ, 0.64, 0.30, 0.024, 0.20, 0.48, (0.75, 1.25), 0.57, 0.90, 0.65, 0.48),
        .init("Steinway Grand", "grand", .piano, 0.62, 0.32, 0.003, 0.27, 0.49, (0.75, 1.5), 0.52, 1.04, 0.84, 0.42),
        .init("FM Electric Piano", "tines", .piano, 0.73, 0.55, 0.004, 0.22, 0.50, (0.5, 1.25), 0.59, 0.92, 1.10, 0.67),
        .init("Bowed Cello", "cello", .strings, 0.49, 0.29, 0.022, 0.29, 0.51, (1, 1.5), 0.52, 1.30, 0.97, 0.49),
        .init("Pizzicato Viola", "pizz", .strings, 0.66, 0.34, 0.004, 0.22, 0.54, (0.75, 1.75), 0.61, 1.06, 0.87, 0.73),
        .init("Flute", "flute", .winds, 0.71, 0.18, 0.018, 0.17, 0.45, (0.75, 1.5), 0.58, 1.17, 0.94, 0.64),
        .init("Clarinet", "clarinet", .winds, 0.66, 0.22, 0.018, 0.19, 0.47, (1, 1.75), 0.52, 1.05, 1.00, 0.54),
        .init("Harmon Trumpet", "trumpet", .brass, 0.53, 0.17, 0.02, 0.17, 0.45, (0.75, 1.25), 0.57, 1.15, 0.82, 0.47),
        .init("French Horn", "horn", .brass, 0.62, 0.29, 0.022, 0.26, 0.46, (1.25, 2), 0.54, 1.26, 1.12, 0.64),
        .init("Vibraphone", "vibes", .mallets, 0.59, 0.33, 0.003, 0.26, 0.51, (0.5, 1.5), 0.59, 1.02, 1.04, 0.68),
        .init("Marimba", "marimba", .mallets, 0.69, 0.22, 0.003, 0.21, 0.53, (1, 1.5), 0.54, 1.21, 1.13, 0.63)
    ]
}
