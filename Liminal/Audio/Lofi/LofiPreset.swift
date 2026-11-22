import Foundation

/// Each take introduces a piano hook, a plucked string and a guitar in its middle phrases, then the
/// same hook. Programs are rows of a table: several may share one sample group and differ only in
/// tone, wow and space, so a new recording or a new effect amount is one line (D114).
nonisolated struct LofiPreset: Equatable, Sendable {
    enum Family: Int, CaseIterable, Sendable { case piano, strings, guitar }

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
    /// Guitar programs only: 0 leans to strummed chords and double stops, 1 to fingerpicked
    /// broken chords (`LofiGuitarPhrasing`).
    let fingerstyle: Double
    /// Level trim in dB on the phrase's instrument stems after the instrument balance, from the D114
    /// per-program loudness match (integrated level of dry, mids and effects against the Steinway Grand), -6 to +2 dB.
    let levelDB: Float

    /// `audition` forces a guitar or plucked-string program and the guitar's middle phrase for A/B
    /// captures; with `.none` the draw is the seed's own. Phrases 0 and 3 of a take never change.
    static func selection(seed: UInt64, phrase: Int, audition: LofiScore.Audition = .none) -> Self {
        let root = MusicRNG(seed: seed).fork(253)
        let record = phrase / 4
        let piano = root.fork(100).shuffledCycle(keys, index: record)
        let strings = audition.pluckProgram.flatMap { program(named: $0, in: plucks) }
            ?? root.fork(101).shuffledCycle(plucks, index: record)
        let answer = audition.guitarProgram.flatMap { program(named: $0, in: guitars) }
            ?? root.fork(102).shuffledCycle(guitars, index: record)
        var order = root.fork(UInt64(record) + 615)
        let drawnStringsFirst = order.chance(0.60)
        let stringsFirst = audition.guitarSlot.map { $0 == 2 } ?? drawnStringsFirst
        let voices = stringsFirst ? [piano, strings, answer, piano] : [piano, answer, strings, piano]
        return voices[phrase % 4]
    }

    /// The guitar program called `name`, matched as `LofiScore.Audition.key` does ("nylonstrum").
    static func guitar(named name: String) -> Self? { program(named: name, in: guitars) }

    /// The plucked-string program called `name`, matched as `LofiScore.Audition.key` does.
    static func pluck(named name: String) -> Self? { program(named: name, in: plucks) }

    private static func program(named name: String, in table: [Self]) -> Self? {
        let key = LofiScore.Audition.key(name)
        return table.first { LofiScore.Audition.key($0.name) == key }
    }

    private init(_ name: String, _ sampleGroup: String, _ family: Family, _ brightness: Double, _ movement: Double,
                 _ attack: Double, _ release: Double, _ gain: Float, _ taps: (Double, Double),
                 _ feedback: Float, _ diffusion: Float, _ particles: Float, _ stereo: Float,
                 fingerstyle: Double = 0, level: Float = 0) {
        self.name = name
        self.sampleGroup = sampleGroup
        self.family = family
        self.brightness = brightness
        self.movement = movement
        self.attack = attack
        self.release = release
        self.gain = gain
        self.space = Space(taps: taps, feedback: feedback, diffusion: diffusion, particles: particles, stereo: stereo)
        self.fingerstyle = fingerstyle
        self.levelDB = min(2, max(-6, level))
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name }

    // Columns: name, sample group, family, brightness, movement (wow), attack, release, gain,
    // echo taps (beats), echo feedback, room (diffusion), grains (particles), stereo; then the
    // guitar's fingerstyle lean and the loudness-match trim.
    // Acoustic and lo-fi pianos only. "Felt" and "tape" rows are darker, softer at the hammer,
    // wobblier and wetter; "close" rows are drier; the rest sit in between (D114).
    static let keys: [Self] = [
        .init("Steinway Grand", "grand", .piano, 0.62, 0.32, 0.003, 0.27, 0.49, (0.75, 1.5), 0.52, 1.04, 0.84, 0.42),
        .init("Felt Steinway", "grand", .piano, 0.30, 0.46, 0.013, 0.34, 0.49, (1, 1.75), 0.56, 1.22, 0.96, 0.55),
        .init("Kawai Grand", "kawai", .piano, 0.52, 0.22, 0.004, 0.30, 0.49, (1, 1.5), 0.50, 1.18, 0.86, 0.50,
              level: -0.8),
        .init("Close Kawai", "kawai", .piano, 0.48, 0.12, 0.004, 0.24, 0.49, (0.75, 1.25), 0.40, 0.84, 0.62, 0.36),
        .init("Felt Osiris", "osiris", .piano, 0.28, 0.52, 0.012, 0.36, 0.49, (1, 1.75), 0.57, 1.26, 1.00, 0.58,
              level: -0.4),
        .init("Quiet Osiris", "osiris", .piano, 0.44, 0.16, 0.006, 0.28, 0.49, (0.75, 1.25), 0.42, 0.88, 0.66, 0.40,
              level: -1.4),
        .init("Living Room Upright", "uprightkw", .piano, 0.42, 0.30, 0.006, 0.30, 0.50, (1, 1.5), 0.50, 1.12, 0.84, 0.50,
              level: 0.3),
        .init("Knight Upright", "upright", .piano, 0.49, 0.18, 0.006, 0.31, 0.50, (1, 1.75), 0.50, 1.10, 0.80, 0.57,
              level: -0.5),
        .init("Tape Upright", "upright", .piano, 0.30, 0.55, 0.010, 0.33, 0.50, (0.75, 1.5), 0.55, 1.16, 1.00, 0.52,
              level: -0.9),
        .init("Yamaha Upright", "yamaha", .piano, 0.47, 0.20, 0.006, 0.30, 0.52, (1, 1.5), 0.48, 1.13, 0.80, 0.52,
              level: 0.5)
    ]

    static let plucks: [Self] = [
        .init("Pizzicato Viola", "pizz", .strings, 0.61, 0.26, 0.004, 0.22, 0.54, (0.75, 1.75), 0.61, 1.06, 0.87, 0.73,
              level: 1.9),
        .init("Pizzicato Cello", "cellopluck", .strings, 0.50, 0.19, 0.006, 0.29, 0.55, (0.75, 1.5), 0.53, 1.12, 0.86, 0.60,
              level: -0.2),
        .init("Concert Harp", "harp", .strings, 0.51, 0.16, 0.004, 0.29, 0.51, (1, 1.75), 0.51, 1.18, 0.88, 0.61,
              level: 0.7),
        .init("Folk Harp", "folkharp", .strings, 0.44, 0.20, 0.004, 0.30, 0.51, (0.75, 1.5), 0.50, 1.14, 0.84, 0.58,
              level: -1.2)
    ]

    /// Clean guitars only, never distorted. They play guitar figures, not keyboard lines.
    static let guitars: [Self] = [
        .init("Nylon Fingerstyle", "nylon", .guitar, 0.42, 0.18, 0.004, 0.30, 0.50, (0.75, 1.5), 0.50, 1.08, 0.82, 0.55,
              fingerstyle: 0.8, level: 1.5),
        .init("Nylon Strum", "nylon", .guitar, 0.36, 0.26, 0.005, 0.32, 0.50, (1, 1.75), 0.53, 1.20, 0.90, 0.60,
              fingerstyle: 0.25, level: 0.9),
        .init("Steel Acoustic", "steel", .guitar, 0.18, 0.20, 0.008, 0.30, 0.50, (0.75, 1.5), 0.50, 1.10, 0.82, 0.54,
              fingerstyle: 0.4, level: 1.0),
        .init("Archtop Acoustic", "archtop", .guitar, 0.40, 0.18, 0.004, 0.28, 0.50, (0.75, 1.25), 0.46, 1.02, 0.78, 0.50,
              fingerstyle: 0.55, level: -0.7),
        .init("Archtop Jazz", "jazzbox", .guitar, 0.30, 0.16, 0.006, 0.30, 0.48, (1, 1.5), 0.48, 1.04, 0.76, 0.48,
              fingerstyle: 0.3, level: 0.3),
        .init("Flatwound Tape", "flatwound", .guitar, 0.26, 0.46, 0.008, 0.32, 0.48, (1, 1.5), 0.55, 1.16, 0.96, 0.54,
              fingerstyle: 0.6, level: 0.7)
    ]
}
