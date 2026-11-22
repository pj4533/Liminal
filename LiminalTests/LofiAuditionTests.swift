import Testing
@testable import Liminal

/// The capture audition (D128 stage 1): `.none` is the app's own draw, and forcing a program only
/// changes the take's guitar or plucked-string phrase.
struct LofiAuditionTests {
    /// A copy of `LofiPreset.selection` before the audition existed (commit a72c044).
    private static func previousSelection(seed: UInt64, phrase: Int) -> LofiPreset {
        let root = MusicRNG(seed: seed).fork(253)
        let record = phrase / 4
        let piano = root.fork(100).shuffledCycle(LofiPreset.keys, index: record)
        let strings = root.fork(101).shuffledCycle(LofiPreset.plucks, index: record)
        let answer = root.fork(102).shuffledCycle(LofiPreset.guitars, index: record)
        var order = root.fork(UInt64(record) + 615)
        let voices = order.chance(0.60) ? [piano, strings, answer, piano] : [piano, answer, strings, piano]
        return voices[phrase % 4]
    }

    @Test func noAuditionKeepsTheSeedsOwnDraw() {
        for seed in UInt64(0)..<64 {
            for phrase in 0..<16 {
                let old = Self.previousSelection(seed: seed, phrase: phrase)
                #expect(LofiPreset.selection(seed: seed, phrase: phrase) == old)
                #expect(LofiPreset.selection(seed: seed, phrase: phrase, audition: .none) == old)
                #expect(LofiPreset.selection(seed: seed, phrase: phrase, audition: .init(hook: false)) == old)
            }
        }
    }

    @Test func namesMatchWithoutCaseOrSpaces() throws {
        #expect(LofiPreset.guitar(named: "nylonstrum")?.name == "Nylon Strum")
        #expect(LofiPreset.guitar(named: "Flatwound Tape")?.name == "Flatwound Tape")
        #expect(LofiPreset.guitar(named: "ARCHTOPJAZZ")?.name == "Archtop Jazz")
        #expect(LofiPreset.pluck(named: "concertharp")?.name == "Concert Harp")
        #expect(LofiPreset.guitar(named: "concertharp") == nil)
        #expect(LofiPreset.pluck(named: "nylonstrum") == nil)
        #expect(LofiScore.Audition(guitarSlot: 3).guitarSlot == nil)
    }

    @Test func forcingPlacesTheProgramInItsSlotAndLeavesTheThemeAlone() throws {
        let guitar = try #require(LofiPreset.guitar(named: "nylonstrum"))
        let harp = try #require(LofiPreset.pluck(named: "concertharp"))
        for seed in UInt64(0)..<64 {
            for slot in [1, 2] {
                let audition = LofiScore.Audition(guitarProgram: "nylonstrum", pluckProgram: "concertharp",
                                                  guitarSlot: slot)
                for phrase in 0..<16 {
                    let forced = LofiPreset.selection(seed: seed, phrase: phrase, audition: audition)
                    switch phrase % 4 {
                    case 0, 3: #expect(forced == Self.previousSelection(seed: seed, phrase: phrase))
                    case slot: #expect(forced == guitar)
                    default: #expect(forced == harp)
                    }
                }
            }
            // Forcing only the guitar keeps the seed's own pluck and order.
            let onlyGuitar = LofiScore.Audition(guitarProgram: "nylonstrum")
            for phrase in 0..<16 {
                let old = Self.previousSelection(seed: seed, phrase: phrase)
                let forced = LofiPreset.selection(seed: seed, phrase: phrase, audition: onlyGuitar)
                #expect(old.family == .guitar ? forced == guitar : forced == old)
            }
        }
    }

    @Test func scoreUsesTheAuditionedProgram() {
        let drift = LofiDrift(seed: 1042)
        let audition = LofiScore.Audition(guitarProgram: "flatwoundtape", guitarSlot: 2)
        let score = LofiScore.make(seed: 7, section: LofiScore.section(at: 2), drift: drift,
                                   startBeat: 2 * LofiClock.beats, audition: audition)
        #expect(score.preset.name == "Flatwound Tape")
        let plain = LofiScore.make(seed: 7, section: .theme, drift: drift, startBeat: 0)
        #expect(plain == LofiScore.make(seed: 7, section: .theme, drift: drift, startBeat: 0, audition: audition))
    }
}
