import Accelerate
import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// The two-layer bass voice of plan 2.2 (synth sub plus sampled body) and the dub throw of plan 2.4.
@Suite(.serialized)
struct LofiBassVoiceTests {
    static let rate = 48_000.0
    static let clock = LofiClock(tempo: 72, sampleRate: rate)
    static let strokes: [LofiScore.BassStroke] = [.thump, .walk, .hold, .ghost]

    static func length(_ stroke: LofiScore.BassStroke) -> Double {
        switch stroke {
        case .thump: 0.25
        case .walk: 0.6
        case .hold: 1.5
        case .ghost: 0.16
        }
    }

    static func note(_ midi: Int, _ stroke: LofiScore.BassStroke, velocity: Float = 0.8, beat: Double = 0) -> LofiScore.Note {
        var n = LofiScore.Note(part: .bass, midi: midi, beat: beat, length: length(stroke), velocity: velocity, send: 0)
        n.stroke = stroke
        return n
    }

    static func render(_ voice: LofiBassVoice, _ note: LofiScore.Note, frames: Int = 96_000) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: 0, count: frames), right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in LofiBassVoice.add(note, voice: voice, clock: clock, left: l, right: r) }
        }
        return (left, right)
    }

    static func rms(_ x: ArraySlice<Float>) -> Double {
        var value: Float = 0
        x.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &value, vDSP_Length($0.count)) }
        return Double(value)
    }

    /// Power spectrum (Hann, zero-padded to a power of two) and its bin width.
    static func spectrum(_ x: [Float]) -> (power: [Float], resolution: Double) {
        let n = 1 << Int(ceil(log2(Double(x.count))))
        var frame = [Float](repeating: 0, count: n)
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: x.count, isHalfWindow: false)
        for i in x.indices { frame[i] = x[i] * window[i] }
        let log2n = vDSP_Length(log2(Double(n)))
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        var real = [Float](repeating: 0, count: n / 2), imag = real, power = real
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                frame.withUnsafeBufferPointer { f in
                    f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        power[0] = 0
        return (power, rate / Double(n))
    }

    static func band(_ s: (power: [Float], resolution: Double), _ low: Double, _ high: Double) -> Double {
        let lo = max(1, Int(low / s.resolution)), hi = min(s.power.count - 1, Int(high / s.resolution))
        return s.power[lo...hi].reduce(0) { $0 + Double($1) }
    }

    // MARK: Voice

    /// Mono; the sub within 5 cents of the note after the thump's drop; exactly zero after the release;
    /// nothing above 5 kHz within 60 dB of the strongest bin; a `thump` without a click step.
    @Test func twoLayerVoicesAreMonoTunedBandLimitedAndEndExactly() {
        var worstStep = 0.0
        for voice in [LofiBassVoice.upright, .flatwound] {
            for stroke in Self.strokes {
                for midi in [28, 33, 38, 41] {
                    let note = Self.note(midi, stroke)
                    let out = Self.render(voice, note)
                    let x = out.left
                    let label = "\(voice) \(stroke) MIDI \(midi)"
                    #expect(out.left == out.right, "\(label) is mono")
                    #expect(abs(x[0]) < 1e-4, "\(label) starts from zero")
                    let span = Self.clock.frame(at: note.length)
                    let end = span + Int(Self.rate * LofiBassVoice.shape(stroke).release)
                    #expect(x[end...].allSatisfy { $0 == 0 }, "\(label) is zero after its release")
                    #expect(abs(x[end - 1]) < 1e-3, "\(label) last sample \(x[end - 1])")
                    #expect(x.allSatisfy { $0.isFinite })

                    // The sub alone: every upward zero crossing period within 5 cents after 20 ms.
                    let sub = LofiBassVoice.render(note, kit: voice.kit!, clock: Self.clock, limit: x.count, layers: .sub)
                    let f0 = 440 * pow(2, (Double(midi) - 69) / 12)
                    var crossings: [Double] = []
                    for i in Int(0.020 * Self.rate)..<span where sub[i - 1] < 0 && sub[i] >= 0 {
                        crossings.append(Double(i - 1) + Double(-sub[i - 1] / (sub[i] - sub[i - 1])))
                    }
                    let cents = zip(crossings, crossings.dropFirst()).map { 1200 * log2(Self.rate / ($1 - $0) / f0) }
                    #expect(!cents.isEmpty && cents.allSatisfy { abs($0) <= 5 }, "\(label) worst \(cents.map(abs).max() ?? 0) cents")

                    let spectrum = Self.spectrum(Array(x[0..<end]))
                    let strongest = Double(spectrum.power.max() ?? 0)
                    let high = Double(spectrum.power[Int(5_000 / spectrum.resolution)...].max() ?? 0)
                    let highDB = 10 * log10(high / strongest)
                    #expect(highDB <= -60, "\(label): \(highDB) dB above 5 kHz")

                    let peak = Double(x.map(abs).max() ?? 1)
                    let step = Double(zip(x, x.dropFirst()).map { abs($1 - $0) }.max() ?? 0) / peak
                    if stroke == .thump { worstStep = max(worstStep, step) }
                    #expect(step <= 0.12, "\(label): max step \(step) of the peak")
                }
            }
        }
        BassReport.log(String(format: "BASSVOICE worst thump step %.4f of the peak", worstStep))
    }

    /// The two kits play the same note at the same level, per stroke (within 1 dB RMS).
    @Test func kitsAreLoudnessMatchedPerStroke() {
        for stroke in Self.strokes {
            for midi in [28, 33, 38, 41] {
                let note = Self.note(midi, stroke)
                let span = Self.clock.frame(at: note.length) + Int(Self.rate * LofiBassVoice.shape(stroke).release)
                let upright = Self.rms(Self.render(.upright, note).left[0..<span])
                let flat = Self.rms(Self.render(.flatwound, note).left[0..<span])
                let difference = 20 * log10(upright / flat)
                #expect(abs(difference) <= 1, "\(stroke) MIDI \(midi): upright minus flatwound \(difference) dB")
            }
        }
    }

    /// The body carries the note above the sub: 150-800 Hz against 40-150 Hz on a held note, and the
    /// velocity drives brightness (0.9 to 2.5 kHz rises with velocity faster than the level).
    @Test func theBodyCarriesTheNoteAndVelocityDrivesBrightness() {
        for voice in [LofiBassVoice.upright, .flatwound] {
            for midi in [28, 33, 38, 41] {
                let loud = Self.render(voice, Self.note(midi, .walk, velocity: 0.9)).left
                let soft = Self.render(voice, Self.note(midi, .walk, velocity: 0.4)).left
                let a = Self.spectrum(Array(loud[0..<30_000])), b = Self.spectrum(Array(soft[0..<30_000]))
                let carry = 10 * log10(Self.band(a, 150, 800) / Self.band(a, 40, 150))
                let tilt = 10 * log10(Self.band(a, 900, 2_500) / Self.band(a, 40, 150))
                    - 10 * log10(Self.band(b, 900, 2_500) / Self.band(b, 40, 150))
                BassReport.log(String(format: "BASSVOICE %@ MIDI %d: 150-800 vs 40-150 %.1f dB, brightness loud minus soft %.1f dB",
                             "\(voice)", midi, carry, tilt))
                // The 180 Hz crossover (plan 9) leaves MIDI 28 a little under -16.
                #expect(carry >= -18, "\(voice) MIDI \(midi): body \(carry) dB")
                #expect(tilt > 1, "\(voice) MIDI \(midi): velocity brightness \(tilt) dB")
            }
        }
    }

    @Test func lowRiseLeadCacheReturnsTheUncachedValue() {
        for voice in LofiBassVoice.allCases {
            for stroke in Self.strokes {
                for midi in [28, 36, 41] {
                    let cached = voice.lowRiseLead(midi: midi, stroke: stroke)
                    #expect(cached == voice.uncachedLowRiseLead(midi: midi, stroke: stroke))
                    #expect(cached == voice.lowRiseLead(midi: midi, stroke: stroke))
                }
            }
        }
    }

    // MARK: Rendering and throws

    @Test func phraseRenderingIsDeterministicAndFinite() throws {
        for (seed, phrase) in [(UInt64(2077), 0), (5, 2), (11, 5)] {
            let a = try LofiRenderer.render(seed: seed, section: LofiScore.section(at: phrase), options: .init(tempo: 72),
                                            sampleRate: 24_000, drift: .init(seed: seed), startBeat: Double(phrase * 16))
            let b = try LofiRenderer.render(seed: seed, section: LofiScore.section(at: phrase), options: .init(tempo: 72),
                                            sampleRate: 24_000, drift: .init(seed: seed), startBeat: Double(phrase * 16))
            let n = Int(a.bass.frameLength)
            for buffers in [(a.bass, b.bass), (a.wet, b.wet)] {
                let x = UnsafeBufferPointer(start: buffers.0.floatChannelData![0], count: n)
                let y = UnsafeBufferPointer(start: buffers.1.floatChannelData![0], count: n)
                #expect(Array(x) == Array(y))
                #expect(x.allSatisfy { $0.isFinite })
            }
        }
    }

    /// The throw return, isolated by rendering the phrase with and without throws: nothing below 200 Hz
    /// within 40 dB of its strongest band, and its strongest 400 ms 18 to 24 dB under the bass stem's.
    @Test func throwReturnIsHighPassedAndSitsUnderTheBass() throws {
        var levels: [Double] = []
        for seed in [UInt64(2077), 7, 19] {
            let render = { try LofiRenderer.render(seed: seed, section: .breakdown, options: .init(tempo: 72),
                                                   sampleRate: Self.rate, drift: .init(seed: seed), startBeat: 32) }
            let with = try render()
            let without = try LofiBassThrow.$isEnabled.withValue(false) { try render() }
            #expect(LofiScore.make(seed: seed, section: .breakdown, drift: .init(seed: seed), startBeat: 32).notes
                .contains { $0.part == .bass && $0.send > 0 })
            let n = Int(with.wet.frameLength)
            let w = UnsafeBufferPointer(start: with.wet.floatChannelData![0], count: n)
            let o = UnsafeBufferPointer(start: without.wet.floatChannelData![0], count: n)
            // The throw also raises the phrase's balance meter, which trims dry, texture and wet together:
            // the dry stems give that ratio, so the rest of the wet stem cancels exactly.
            let dw = UnsafeBufferPointer(start: with.dry.floatChannelData![0], count: n)
            let dn = UnsafeBufferPointer(start: without.dry.floatChannelData![0], count: n)
            let ratio = Float(Self.rms(Array(dw)[...]) / max(1e-12, Self.rms(Array(dn)[...])))
            let throwReturn = zip(w, o).map { $0 - ratio * $1 }
            let bass = Array(UnsafeBufferPointer(start: with.bass.floatChannelData![0], count: n))
            func strongest(_ x: [Float]) -> Double {
                let window = Int(0.4 * Self.rate)
                return stride(from: 0, to: x.count - window, by: window / 4).map { Self.rms(x[$0..<($0 + window)]) }.max() ?? 0
            }
            let level = 20 * log10(strongest(bass) / max(1e-12, strongest(throwReturn)))
            levels.append(level)
            // The return itself through the space filters (the wet difference also carries the boundary
            // of the soft wet ceiling).
            let score = LofiScore.make(seed: seed, section: .breakdown, drift: .init(seed: seed), startBeat: 32,
                                       beatSeconds: Self.clock.beatDuration)
            var alone = LofiBassThrow.render(score.notes.filter { $0.part == .bass && $0.send > 0 },
                                             kit: score.bassVoice.kit!, clock: Self.clock, frames: 2 * n, sweep: score.bassSweep)
            LofiStemChains.applySpace(left: &alone.left, right: &alone.right, sampleRate: Self.rate)
            let s = Self.spectrum(alone.left)
            let bands = stride(from: 0.0, to: 25.0, by: 1.0).map { k -> Double in
                let lo = 50 * pow(2, k / 3), hi = lo * pow(2, 1.0 / 3)
                return Self.band(s, lo, hi)
            }
            let low = Self.band(s, 20, 200)
            let lowDB = 10 * log10(low / (bands.max() ?? 1))
            BassReport.log("BASSTHROW seed \(seed) bands " + bands.map { String(format: "%.0f", 10 * log10(max($0, 1e-30))) }.joined(separator: " ")
                           + String(format: " low %.0f", 10 * log10(max(low, 1e-30))))
            BassReport.log(String(format: "BASSTHROW seed %d: return %.1f dB under the bass, below 200 Hz %.1f dB under its peak band",
                         seed, level, lowDB))
            #expect(lowDB <= -40)
            #expect((18...24).contains(level), "seed \(seed): throw \(level) dB under the bass")
        }
    }
}
