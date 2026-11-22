import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// Waveform onsets of chop pads (D126): where a cut's sound begins, which frame lands on the step,
/// and where the pad starts.
struct DialogueOnsetTests {
    static let rate = 48_000.0

    /// `seconds` of a -66 dBFS noise floor.
    static func floor(_ seconds: Double, seed: UInt64 = 7) -> [Float] {
        var rng = MusicRNG(seed: seed)
        return (0..<Int(seconds * rate)).map { _ in 0.0005 * (rng.unit() * 2 - 1) }
    }

    /// Adds a 300 Hz + 1.2 kHz voiced tone from `at` for `length` seconds with a linear `rise`.
    static func vowel(_ x: inout [Float], at: Double, length: Double, rise: Double, level: Float = 0.5) {
        let a = Int(at * rate)
        for i in 0..<Int(length * rate) where a + i < x.count {
            let t = Double(i) / rate
            let g = Float(min(1, rise > 0 ? t / rise : 1) * min(1, (length - t) / 0.03))
            x[a + i] += level * g * Float(0.7 * sin(2 * .pi * 300 * t) + 0.3 * sin(2 * .pi * 1200 * t))
        }
    }

    /// Adds band noise (a fricative or breath) of `length` seconds at `at`.
    static func hiss(_ x: inout [Float], at: Double, length: Double, level: Float, hz: Double = 2500, seed: UInt64 = 3) {
        var rng = MusicRNG(seed: seed)
        let white = (0..<Int(length * rate)).map { _ in rng.unit() * 2 - 1 }
        let band = DialogueFixtures.bandpass(white, hz: hz, q: 1.2, rate: rate)
        let a = Int(at * rate)
        let n = band.count
        for i in 0..<n where a + i < x.count {
            let t = Float(i) / Float(n)
            x[a + i] += level * 3 * band[i] * min(1, t * 10) * min(1, (1 - t) * 10)
        }
    }

    static func attack(_ x: [Float], search: Range<Double>, line: Bool = false) -> DialogueAttack {
        x.withUnsafeBufferPointer { p in
            let span = Int(search.lowerBound * rate)..<Int(search.upperBound * rate)
            let e = DialogueOnsetEnvelope(samples: p.baseAddress!, count: x.count, rate: rate,
                                          span: max(0, span.lowerBound - Int(0.2 * rate))..<span.upperBound)
            return DialogueOnset.attack(e, samples: p.baseAddress!, count: x.count, rate: rate, search: span, line: line)
        }
    }

    static func ms(_ frames: Int) -> Double { Double(frames) / rate * 1000 }

    @Test func aPlosiveIsHardAndItsBurstIsTheBeat() {
        var x = Self.floor(1.0)
        Self.vowel(&x, at: 0.400, length: 0.25, rise: 0.0005)
        let a = Self.attack(x, search: 0.30..<0.70)
        let onset = Int(0.400 * Self.rate)
        #expect(a.hard)
        #expect(abs(Self.ms(a.beatFrame - onset)) <= 1, "beat \(Self.ms(a.beatFrame - onset)) ms from the burst")
        #expect(abs(Self.ms(a.audibleFrame - onset)) <= 1.5)
        // The pad starts about 2 ms before the burst, with a 2 ms fade.
        #expect((0...3.5).contains(Self.ms(onset - a.startFrame)), "start \(Self.ms(onset - a.startFrame)) ms before")
        #expect(a.fadeIn == Int((DialogueOnset.hardFadeInSeconds * Self.rate).rounded()))
    }

    @Test func aLongFricativeKeepsThirtyMillisecondsBeforeItsVowel() {
        var x = Self.floor(1.0)
        Self.hiss(&x, at: 0.300, length: 0.100, level: 0.08)
        Self.vowel(&x, at: 0.400, length: 0.25, rise: 0.020)
        let a = Self.attack(x, search: 0.25..<0.70)
        #expect(!a.hard)
        // The sound begins with the fricative, the beat is the vowel's rise.
        #expect(abs(Self.ms(a.audibleFrame - Int(0.300 * Self.rate))) <= 6, "audible \(Self.ms(a.audibleFrame) - 300) ms")
        #expect((0...14).contains(Self.ms(a.beatFrame - Int(0.400 * Self.rate))), "beat \(Self.ms(a.beatFrame) - 400) ms")
        let lead = Self.ms(a.beatFrame - a.startFrame)
        #expect((30...33.5).contains(lead), "lead \(lead) ms")
        #expect(a.fadeIn == Int((DialogueOnset.softFadeInSeconds * Self.rate).rounded()))
    }

    @Test func aBreathBeforeAGapIsNotTheOnset() {
        var x = Self.floor(1.0)
        Self.hiss(&x, at: 0.200, length: 0.150, level: 0.1, hz: 900)
        Self.vowel(&x, at: 0.410, length: 0.25, rise: 0.001)
        let a = Self.attack(x, search: 0.18..<0.70)
        #expect(abs(Self.ms(a.audibleFrame - Int(0.410 * Self.rate))) <= 2, "audible \(Self.ms(a.audibleFrame) - 410) ms")
        #expect(a.startFrame >= Int(0.405 * Self.rate))
    }

    /// A weak lead syllable under half the next one's peak: a chop starts 30 ms before the strong
    /// one ("time", not "to the time"); the line keeps the weak syllable as a pickup of at most 120 ms.
    @Test func aWeakLeadSyllableIsTrimmedFromAChopButKeptByTheLine() {
        var x = Self.floor(1.2)
        // The weak syllable runs into the strong one (no gap for the onset to stop at).
        Self.vowel(&x, at: 0.300, length: 0.14, rise: 0.002, level: 0.12)
        Self.vowel(&x, at: 0.425, length: 0.25, rise: 0.002, level: 0.6)
        let chop = Self.attack(x, search: 0.25..<0.80)
        #expect(abs(Self.ms(chop.beatFrame - Int(0.425 * Self.rate))) <= 2, "beat \(Self.ms(chop.beatFrame) - 425) ms")
        #expect(Self.ms(chop.beatFrame - chop.startFrame) <= 33.5)
        let line = Self.attack(x, search: 0.25..<0.80, line: true)
        #expect(line.beatFrame == chop.beatFrame)
        let lead = Self.ms(line.beatFrame - line.startFrame)
        #expect((115...121).contains(lead), "line lead \(lead) ms")
        #expect(line.fadeIn == Int((DialogueOnset.lineClipFadeSeconds * Self.rate).rounded()))
    }

    @Test func silenceFallsBackToTheSearchStart() {
        let x = [Float](repeating: 0, count: Int(Self.rate))
        let a = Self.attack(x, search: 0.2..<0.6)
        #expect(a.startFrame == Int(0.2 * Self.rate) && a.beatFrame == a.startFrame)
    }

    /// On the synthetic voice, a word cut 40 ms before its first sound lands its beat on the
    /// word's burst or the first 15 ms of its first vowel, and its pad starts at most 32 ms before it.
    @Test func fixtureWordsLandOnTheirFirstSyllable() throws {
        let fixture = DialogueFixtures.speech(DialogueFixtures.Options(seed: 4, breaths: true))
        let x = try #require(fixture.buffer.floatChannelData?[0])
        let n = Int(fixture.buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: x, count: n))
        var misses: [String] = []
        var checked = 0
        for (k, word) in fixture.words.enumerated() where k > 0 {
            guard let first = fixture.syllables.first(where: { $0.lowerBound >= word.start - 1e-6 && $0.lowerBound < word.end }) else { continue }
            // Words that follow the previous one by less than 40 ms run together; the cut would sit in its tail.
            guard word.start - fixture.words[k - 1].end >= 0.04 else { continue }
            // The fixture ends "t", "d" and "k" words with a 0.25-level burst that is louder in the chop band
            // than its own short vowel (real release bursts sit 10 to 20 dB under the vowel); a one-syllable
            // word there has no first-syllable peak to find.
            let letters = word.text.lowercased().filter(\.isLetter)
            if let last = letters.last, "tdk".contains(last), DialogueFixtures.syllablesCount(letters) == 1 { continue }
            checked += 1
            let a = Self.attack(samples, search: (word.start - 0.04)..<word.end)
            let beat = Double(a.beatFrame) / Self.rate
            // The fixture's vowels rise linearly over 20 ms through resonant formant filters, so their half
            // peak sits 10 to 25 ms after the vowel starts.
            if beat < word.start - 0.003 || beat > first.lowerBound + 0.025 || Self.ms(a.beatFrame - a.startFrame) > 33.5 {
                misses.append("\(word.text)@\(String(format: "%.3f", word.start)) beat \(String(format: "%+.0f", (beat - first.lowerBound) * 1000)) ms")
            }
        }
        // A first syllable more than 6 dB under the next one is skipped by design (a chop starts on the
        // strong syllable); the fixture's "e" of "empty" is one.
        #expect(checked > 25)
        #expect(Double(misses.count) <= 0.05 * Double(checked), "\(misses.count) of \(checked): \(misses)")
    }
}
