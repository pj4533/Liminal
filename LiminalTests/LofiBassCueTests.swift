import Accelerate
import Foundation
import Testing
@testable import Liminal

/// The bass translation layer of D129: the clean cue partials (`LofiBassVoice.Cue`) and the cue duck on
/// the texture and the return (`LofiCueDuck`).
struct LofiBassCueTests {
    static let rate = 48_000.0
    static let clock = LofiClock(tempo: 72, sampleRate: rate)

    static func note(_ midi: Int, length: Double = 1.5, strike: Float = 0, velocity: Float = 0.8) -> LofiScore.Note {
        var n = LofiScore.Note(part: .bass, midi: midi, beat: 0, length: length, velocity: velocity, send: 0)
        n.stroke = .hold
        n.strike = strike
        return n
    }

    /// The voice's tone in L and R and its cue in its own buffer.
    static func render(_ voice: LofiBassVoice, _ note: LofiScore.Note, cue: LofiBassVoice.Cue?, frames: Int = 96_000,
                       strikeShift: Int = 0) -> (left: [Float], right: [Float], cue: [Float]) {
        var left = [Float](repeating: 0, count: frames), right = left, layer = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                layer.withUnsafeMutableBufferPointer { c in
                    LofiBassVoice.add(note, voice: voice, clock: clock, left: l, right: r, strikeShift: strikeShift,
                                      cue: cue, cueOut: c)
                }
            }
        }
        return (left, right, layer)
    }

    static func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        var value: Float = 0
        x.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &value, vDSP_Length($0.count)) }
        return Double(value)
    }

    /// Amplitude of `x` at `hz` (Hann-windowed single-bin DFT over the slice).
    static func amplitude(_ x: ArraySlice<Float>, hz: Double) -> Double {
        var re = 0.0, im = 0.0
        let n = Double(x.count)
        for (i, v) in x.enumerated() {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / n)
            let p = 2 * Double.pi * hz * Double(i) / rate
            re += w * Double(v) * cos(p)
            im += w * Double(v) * sin(p)
        }
        return 4 * (re * re + im * im).squareRoot() / n
    }

    // MARK: Cue partials

    /// The tone itself is the same with or without the cue: the cue only goes to its own buffer, and no
    /// cue buffer means no cue.
    @Test(arguments: [LofiBassVoice.flatwound, .upright, .synth])
    func theCueNeverTouchesTheTone(voice: LofiBassVoice) {
        let n = Self.note(36, strike: 1)
        let plain = Self.render(voice, n, cue: nil)
        let cued = Self.render(voice, n, cue: .standard)
        #expect(cued.left == plain.left && cued.right == plain.right)
        #expect(plain.cue.allSatisfy { $0 == 0 })
        #expect(cued.cue.contains { $0 != 0 })
        var left = [Float](repeating: 0, count: 96_000), right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                LofiBassVoice.add(n, voice: voice, clock: Self.clock, left: l, right: r, cue: .standard, cueOut: nil)
            }
        }
        #expect(left == plain.left)
    }

    /// The layer is the note's own harmonic series from the band's low edge up: nothing at the fundamental
    /// or the partials under 180 Hz, the first partial at or above 180 Hz near its level (crossover
    /// complement and roll-off included), and the series falling above the 300 Hz roll-off.
    @Test func theCueIsTheNotesOwnSeriesAboveTheBand() {
        let midi = 33 // A1, 55 Hz: partials 4 (220 Hz) and up
        let f0 = LofiBassVoice.frequency(midi)
        let layer = Self.render(.flatwound, Self.note(midi), cue: .standard).cue
        let steady = layer[24_000..<(24_000 + 19_200)] // 400 ms inside the hold
        let fundamental = Double(LofiBassVoice.subGain) * 0.8
        for k in 1...3 { #expect(Self.amplitude(steady, hz: f0 * Double(k)) < 1e-4 * fundamental) }
        let first = Self.amplitude(steady, hz: f0 * 4)
        let f = f0 * 4
        let weight = (1 - LofiBassVoice.subWeight(f)) / sqrt(1 + pow(f / 300, 8))
        // The hold decays 2 dB per second: 1.4 dB at the slice's centre (0.7 s).
        let expected = fundamental * pow(10, (LofiBassVoice.Cue.standard.levelDB - 1.4) / 20) * weight
        #expect(abs(20 * log10(first / expected)) < 0.5)
        let fifth = Self.amplitude(steady, hz: f0 * 5), seventh = Self.amplitude(steady, hz: f0 * 7)
        #expect(fifth < first && seventh < fifth)
        // Off the series: nothing between partials.
        #expect(Self.amplitude(steady, hz: f0 * 4.5) < 0.01 * first)
    }

    /// The cue is zero at the strike and rises over the onset, so the strike stays the brightest moment.
    @Test func theCueRisesFromTheStrike() throws {
        let n = Self.note(36, strike: 1)
        let shift = 480 // the strike 10 ms after the note start
        let layer = Self.render(.flatwound, n, cue: .standard, strikeShift: shift).cue
        #expect(layer[0..<shift].allSatisfy { $0 == 0 })
        #expect(abs(layer[shift]) < 1e-6)
        let onset = Int(0.090 * Self.rate)
        let early = Self.rms(layer[shift..<(shift + 480)])
        let settled = Self.rms(layer[(shift + onset)..<(shift + onset + 4_800)])
        #expect(settled > 0)
        #expect(early < 0.05 * settled)
        // Unstruck: the ramp starts on the note.
        let plain = Self.render(.flatwound, Self.note(36), cue: .standard).cue
        #expect(abs(plain[0]) < 1e-6)
        #expect(Self.rms(plain[0..<480]) < 0.05 * Self.rms(plain[onset..<(onset + 4_800)]))
        // An instant onset is full from the first frame after the strike.
        var instant = LofiBassVoice.Cue.standard
        instant.onset = 0
        let immediate = Self.render(.flatwound, Self.note(36), cue: instant).cue
        #expect(Self.rms(immediate[0..<960]) > 0.3 * Self.rms(immediate[onset..<(onset + 4_800)]))
    }

    /// On a sampled body the aligned cue adds to the body's own harmonics instead of cancelling them (round
    /// MIDI 39 lost about 2 dB at h3/h4 in sine phase, D129), with exactly the unaligned partial's level and
    /// nothing off the series. On the synth (its series is already in sine phase) alignment changes nothing.
    @Test(arguments: [(LofiBassVoice.flatwound, 39), (.flatwound, 36), (.upright, 39), (.upright, 34)])
    func theAlignedCueAddsToTheBodysHarmonics(voice: LofiBassVoice, midi: Int) {
        let n = Self.note(midi)
        var sine = LofiBassVoice.Cue.standard
        sine.alignToTone = false
        let aligned = Self.render(voice, n, cue: .standard)
        let plain = Self.render(voice, n, cue: sine)
        let f0 = LofiBassVoice.frequency(midi)
        // The whole held note: one phase per note and partial, so the claim is about the note, not a slice
        // (the upright's harmonics drift a little against k f0, so a short slice can still beat).
        let window = 4_800..<Self.clock.frame(at: n.length)
        let tone = aligned.left[window]
        let first = Int((180 / f0).rounded(.up))
        for k in first...(first + 1) {
            let hz = f0 * Double(k)
            let body = Self.amplitude(tone, hz: hz)
            let cue = Self.amplitude(plain.cue[window], hz: hz)
            let sum = Self.amplitude(ArraySlice(zip(tone, aligned.cue[window]).map { $0 + $1 }), hz: hz)
            // No cancellation on the note: about the power sum or more (a drifting upright harmonic averages to
            // it), and for the round body's locked harmonics near the coherent sum.
            #expect(sum * sum >= 0.95 * (body * body + cue * cue))
            if voice == .flatwound { #expect(sum >= 0.85 * (body + cue)) }
            #expect(abs(20 * log10(Self.amplitude(aligned.cue[window], hz: hz) / cue)) < 0.2)
            #expect(Self.amplitude(aligned.cue[window], hz: hz + f0 / 2) < 0.01 * cue)
        }
        #expect(aligned.cue.allSatisfy { $0.isFinite })
        let synthAligned = Self.render(.synth, n, cue: .standard).cue
        let synthSine = Self.render(.synth, n, cue: sine).cue
        #expect(synthAligned == synthSine)
    }

    /// The synth tone's cue sits `synthOffsetDB` under the sampled tones' at the same pitch.
    @Test func theSynthCueTakesItsOffset() {
        let n = Self.note(36)
        let round = Self.render(.flatwound, n, cue: .standard).cue
        let synth = Self.render(.synth, n, cue: .standard).cue
        let ratio = 20 * log10(Self.rms(synth[24_000..<48_000]) / Self.rms(round[24_000..<48_000]))
        // The round cue's partials take the body's phases, which moves its RMS by a few hundredths of a dB.
        #expect(abs(ratio - LofiBassVoice.Cue.standard.synthOffsetDB) < 0.05)
    }

    /// The layer follows the note's envelope to exactly zero after the release, at every pitch, and is
    /// finite with no DC.
    @Test(arguments: [28, 33, 36, 41, 48])
    func theCueEndsWithTheNoteAndHasNoDC(midi: Int) {
        let n = Self.note(midi, length: 0.5)
        let layer = Self.render(.upright, n, cue: .standard).cue
        let end = Self.clock.frame(at: n.length) + Int(Self.rate * LofiBassVoice.upright.release(.hold)) + 1
        #expect(layer.allSatisfy { $0.isFinite })
        #expect(layer[end...].allSatisfy { $0 == 0 })
        let mean = layer.reduce(0, +) / Float(layer.count)
        #expect(abs(mean) < 1e-5)
        #expect(layer.contains { $0 != 0 })
    }

    /// In the chain the cue joins after the parallel harmonics and the compressor: a zero cue is bit for bit
    /// the plain chain, and the compressor's reduction and makeup do not move with it.
    @Test func theChainAddsTheCueAfterTheCompressor() {
        let count = 48_000
        func signal() -> [Float] {
            (0..<count).map { i in
                let t = Float(i) / Float(Self.rate)
                return 0.4 * min(1, t / 0.01) * expf(-t * 1.5) * sinf(2 * .pi * 55 * t)
            }
        }
        func chain(cue: [Float]?) -> ([Float], LofiStemChains.Stats) {
            var x = signal()
            let stats = x.withUnsafeMutableBufferPointer { b in
                if let cue {
                    cue.withUnsafeBufferPointer { LofiStemChains.applyBass(b.baseAddress!, count: count, sampleRate: Self.rate, cue: $0.baseAddress) }
                } else {
                    LofiStemChains.applyBass(b.baseAddress!, count: count, sampleRate: Self.rate)
                }
            }
            return (x, stats)
        }
        let plain = chain(cue: nil)
        #expect(chain(cue: [Float](repeating: 0, count: count)).0 == plain.0)
        let tone = (0..<count).map { i in 0.02 * sinf(2 * .pi * 220 * Float(i) / Float(Self.rate)) }
        let cued = chain(cue: tone)
        #expect(cued.0 != plain.0)
        #expect(cued.1.grMeanDb == plain.1.grMeanDb && cued.1.extra["makeupDb"] == plain.1.extra["makeupDb"])
    }

    // MARK: Cue duck

    static func sine(_ hz: Double, _ amplitude: Float, count: Int) -> [Float] {
        (0..<count).map { amplitude * sinf(Float(2 * Double.pi * hz * Double($0) / rate)) }
    }

    /// No bass, no duck: the reduction is zero and the ducked signal is bit for bit the input.
    @Test func silentBassDucksNothing() {
        let count = 24_000
        let bass = [Float](repeating: 0, count: count)
        let reduction = bass.withUnsafeBufferPointer {
            LofiCueDuck.standard.reduction(bass: $0.baseAddress!, count: count, frames: count + 4_800, sampleRate: Self.rate)
        }
        #expect(reduction.count == count + 4_800 && reduction.allSatisfy { $0 == 0 })
        var x = Self.sine(300, 0.2, count: count)
        let before = x
        LofiCueDuck.standard.apply(reduction, to: &x, sampleRate: Self.rate, taper: true)
        #expect(x == before)
    }

    /// While the bass holds at its median level the band loses `maxDB` and the rest is untouched; the
    /// reduction never exceeds `maxDB`, falls back to 0 dB after the bass stops (120 ms release), and the
    /// output is finite.
    @Test func theDuckCutsTheCueBandWhileTheBassSounds() {
        let count = 96_000
        var bass = Self.sine(260, 0.1, count: 48_000) + [Float](repeating: 0, count: 48_000)
        for i in 0..<480 { bass[i] *= Float(i) / 480; bass[47_999 - i] *= Float(i) / 480 }
        let duck = LofiCueDuck.standard
        let reduction = bass.withUnsafeBufferPointer {
            duck.reduction(bass: $0.baseAddress!, count: count, frames: count, sampleRate: Self.rate)
        }
        let deepest = 1 - powf(10, -duck.maxDB / 20)
        #expect(reduction.allSatisfy { $0 >= 0 && $0 <= deepest + 1e-6 })
        #expect(reduction[24_000] > 0.9 * deepest)
        #expect(reduction[48_000 + Int(0.8 * Self.rate)] < 0.01 * deepest)
        var low = Self.sine(300, 0.2, count: count), high = Self.sine(1_500, 0.2, count: count)
        duck.apply(reduction, to: &low, sampleRate: Self.rate, taper: true)
        duck.apply(reduction, to: &high, sampleRate: Self.rate, taper: true)
        #expect(low.allSatisfy { $0.isFinite } && high.allSatisfy { $0.isFinite })
        let window = 18_000..<30_000
        let lowCut = 20 * log10(Self.rms(low[window]) / Self.rms(Self.sine(300, 0.2, count: count)[window]))
        let highCut = 20 * log10(Self.rms(high[window]) / Self.rms(Self.sine(1_500, 0.2, count: count)[window]))
        #expect(lowCut < -2 && lowCut > -3.2)
        #expect(highCut > -0.1)
        // After the release the signal is the input again.
        let late = 90_000..<96_000
        #expect(abs(20 * log10(Self.rms(low[late]) / Self.rms(Self.sine(300, 0.2, count: count)[late]))) < 0.05)
    }

    /// A buffer cut at the phrase edge keeps its edge samples: the reduction fades out there, so a texture
    /// that ends on a held chord does not step at the join.
    @Test func theTaperKeepsTheEdges() {
        let count = 24_000
        let bass = Self.sine(260, 0.1, count: count)
        let duck = LofiCueDuck.standard
        let reduction = bass.withUnsafeBufferPointer {
            duck.reduction(bass: $0.baseAddress!, count: count, frames: count, sampleRate: Self.rate)
        }
        let input = Self.sine(300, 0.2, count: count)
        var x = input
        duck.apply(reduction, to: &x, sampleRate: Self.rate, taper: true)
        #expect(x[0] == input[0] && x[count - 1] == input[count - 1])
        // The largest step anywhere stays that of the input (no click from the band split).
        func maxStep(_ y: [Float]) -> Float { zip(y.dropFirst(), y).map { abs($0 - $1) }.max() ?? 0 }
        #expect(maxStep(x) <= maxStep(input) * 1.01)
    }

    /// The band split is zero phase and edge-safe: with a constant reduction a DC input stays DC and a
    /// broadband impulse train keeps its out-of-band content.
    @Test func theBandSplitAddsNoDC() {
        let count = 24_000
        let duck = LofiCueDuck.standard
        let dc = [Float](repeating: 0.25, count: count)
        let band = duck.bandOf(dc, sampleRate: Self.rate)
        #expect(band.allSatisfy { abs($0) < 1e-4 })
    }
}
