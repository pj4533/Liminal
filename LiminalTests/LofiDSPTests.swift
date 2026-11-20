import Accelerate
import Foundation
import Testing
@testable import Liminal

/// Offline DSP toolkit: filters, dynamics, saturation, stereo, true peak and loudness.
struct LofiDSPTests {
    static let rate = 48_000.0

    // MARK: Helpers

    /// Magnitude at frequency `hz` by direct DFT over the given range (Double accumulation).
    static func amplitude(_ x: [Float], hz: Double, rate: Double, range: Range<Int>) -> Double {
        var re = 0.0, im = 0.0
        let w = 2 * Double.pi * hz / rate
        for i in range {
            re += Double(x[i]) * cos(w * Double(i))
            im -= Double(x[i]) * sin(w * Double(i))
        }
        return 2 * (re * re + im * im).squareRoot() / Double(range.count)
    }

    static func sine(_ hz: Double, amplitude: Float, count: Int, phase: Double = 0, rate: Double = rate) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / rate + phase)) }
    }

    static func rms(_ x: ArraySlice<Float>) -> Float {
        let a = Array(x)
        return vDSP.rootMeanSquare(a)
    }

    struct Noise {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2_000_001) / 1_000_000 - 1
        }
    }

    // Analog prototypes evaluated at the prewarped frequency, the definition RBJ designs are exact for.
    static func analogDB(_ kind: LofiBiquad.Kind, at f: Double, rate: Double) -> Double {
        func mag(_ num: (Double, Double, Double), _ den: (Double, Double, Double), _ omega: Double) -> Double {
            // H(s) = (n2 s^2 + n1 s + n0) / (d2 s^2 + d1 s + d0), s = j omega
            let nr = num.2 - num.0 * omega * omega, ni = num.1 * omega
            let dr = den.2 - den.0 * omega * omega, di = den.1 * omega
            return 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
        }
        func omega(_ f0: Double) -> Double { tan(Double.pi * f / rate) / tan(Double.pi * f0 / rate) }
        let shelfQ = 1 / 2.0.squareRoot()
        switch kind {
        case let .lowpass(f0, q): return mag((0, 0, 1), (1, 1 / q, 1), omega(f0))
        case let .highpass(f0, q): return mag((1, 0, 0), (1, 1 / q, 1), omega(f0))
        case let .bandpass(f0, q): return mag((0, 1 / q, 0), (1, 1 / q, 1), omega(f0))
        case let .allpass(f0, q): return mag((1, -1 / q, 1), (1, 1 / q, 1), omega(f0))
        case let .peak(f0, q, g):
            let a = pow(10, g / 40)
            return mag((1, a / q, 1), (1, 1 / (a * q), 1), omega(f0))
        case let .lowShelf(f0, g):
            let a = pow(10, g / 40), k = a.squareRoot() / shelfQ
            return 20 * log10(a) + mag((1, k, a), (a, k, 1), omega(f0))
        case let .highShelf(f0, g):
            let a = pow(10, g / 40), k = a.squareRoot() / shelfQ
            return 20 * log10(a) + mag((a, k, 1), (1, k, a), omega(f0))
        }
    }

    static let kinds: [(LofiBiquad.Kind, Double)] = [
        (.highpass(hz: 1_000, q: 0.707), 1_000), (.lowpass(hz: 2_000, q: 1.2), 2_000),
        (.peak(hz: 1_000, q: 1.4, gainDB: 6), 1_000), (.lowShelf(hz: 200, gainDB: -4), 200),
        (.highShelf(hz: 6_000, gainDB: 3), 6_000), (.bandpass(hz: 3_000, q: 2), 3_000),
        (.allpass(hz: 1_500, q: 0.7), 1_500),
    ]

    // MARK: Filters

    @Test func everyBiquadKindMatchesItsAnalyticResponseAndItsMeasuredSineResponse() {
        for (kind, f0) in Self.kinds {
            let filter = LofiBiquad(kind, sampleRate: Self.rate)
            for f in [f0 / 3, f0, min(f0 * 2.5, 18_000)] {
                let expected = Self.analogDB(kind, at: f, rate: Self.rate)
                #expect(abs(filter.magnitudeDB(at: f) - expected) < 0.2, "\(kind) at \(f) Hz")
                var running = LofiBiquad(kind, sampleRate: Self.rate)
                let x = Self.sine(f, amplitude: 0.5, count: 24_000)
                let y = x.map { running.process($0) }
                let measured = 20 * log10(Self.amplitude(y, hz: f, rate: Self.rate, range: 12_000..<24_000)
                    / Self.amplitude(x, hz: f, rate: Self.rate, range: 12_000..<24_000))
                #expect(abs(measured - expected) < 0.2, "\(kind) measured at \(f) Hz: \(measured) vs \(expected)")
            }
        }
    }

    @Test func filterChainBlocksEqualPerSampleProcessing() {
        let kinds: [LofiBiquad.Kind] = [.highpass(hz: 80, q: 0.707), .peak(hz: 1_000, q: 1, gainDB: -3),
                                        .lowShelf(hz: 150, gainDB: 2), .lowpass(hz: 8_000, q: 0.707)]
        var noise = Noise(state: 7)
        let count = 20_000
        let left = (0..<count).map { _ in 0.8 * noise.next() }
        let right = (0..<count).map { _ in 0.8 * noise.next() }
        var reference = kinds.map { LofiBiquad($0, sampleRate: Self.rate) }
        var referenceR = reference
        var expectedL = left, expectedR = right
        for i in 0..<count {
            for s in reference.indices {
                expectedL[i] = reference[s].process(expectedL[i])
                expectedR[i] = referenceR[s].process(expectedR[i])
            }
        }
        var chain = LofiFilterChain(kinds, sampleRate: Self.rate)
        var outL = left, outR = right
        var offset = 0
        for size in [1, 37, 512, 4_096, 8_191, count] where offset < count {
            let n = min(size, count - offset)
            outL.withUnsafeMutableBufferPointer { l in
                outR.withUnsafeMutableBufferPointer { r in
                    chain.process(left: l.baseAddress! + offset, right: r.baseAddress! + offset, count: n)
                }
            }
            offset += n
        }
        let errorL = zip(outL, expectedL).map { abs($0 - $1) }.max() ?? 1
        let errorR = zip(outR, expectedR).map { abs($0 - $1) }.max() ?? 1
        print("Filter chain block versus per-sample max error L=\(errorL) R=\(errorR)")
        #expect(errorL < 1e-4 && errorR < 1e-4)
        let combined = kinds.reduce(0.0) { $0 + LofiBiquad($1, sampleRate: Self.rate).magnitudeDB(at: 1_000) }
        #expect(abs(chain.magnitudeDB(at: 1_000) - combined) < 1e-9)
        // A copied chain keeps independent state.
        var copy = chain
        var probe: [Float] = [1, 0, 0, 0], probe2: [Float] = [1, 0, 0, 0]
        copy.process(left: &probe, right: &probe2)
        var silent: [Float] = [0, 0, 0, 0], silent2: [Float] = [0, 0, 0, 0]
        chain.reset()
        chain.process(left: &silent, right: &silent2)
        #expect(silent == [0, 0, 0, 0])
    }

    // MARK: Dynamics

    static func expectedReduction(_ x: Float, t: Float, r: Float, w: Float) -> Float {
        if 2 * (x - t) < -w { return 0 }
        if 2 * abs(x - t) <= w { return (1 - 1 / r) * (x - t + w / 2) * (x - t + w / 2) / (2 * w) }
        return (x - t) * (1 - 1 / r)
    }

    @Test func compressorStaticCurveMatchesThresholdRatioAndKnee() {
        let settings = LofiCompressor.Settings(thresholdDB: -20, ratio: 4, kneeDB: 6, attack: 0.001, release: 0.01)
        for levelDB: Float in [-40, -24, -21, -20, -18.5, -17, -10, -3, 0] {
            var compressor = LofiCompressor(settings, sampleRate: Self.rate)
            let level = dbToGain(levelDB)
            for _ in 0..<24_000 { _ = compressor.gain(detectorLeft: level, detectorRight: -0.5 * level) }
            let expected = Self.expectedReduction(levelDB, t: -20, r: 4, w: 6)
            #expect(abs(compressor.reductionDB - expected) < 0.2, "level \(levelDB): \(compressor.reductionDB) vs \(expected)")
            let g = compressor.gain(detectorLeft: level, detectorRight: level)
            #expect(abs(20 * log10f(g) + expected) < 0.2)
        }
        var makeup = LofiCompressor(.init(thresholdDB: -20, ratio: 2, kneeDB: 0, attack: 0.001, release: 0.01,
                                          makeupDB: 3), sampleRate: Self.rate)
        var g: Float = 0
        for _ in 0..<4_800 { g = makeup.gain(detectorLeft: 0.01, detectorRight: 0.01) }
        #expect(abs(20 * log10f(g) - 3) < 0.01)
    }

    @Test func compressorAttackAndReleaseTimeConstantsAreWithinFifteenPercent() {
        let attack = 0.010, release = 0.100
        var compressor = LofiCompressor(.init(thresholdDB: -30, ratio: 10, kneeDB: 0, attack: attack, release: release),
                                        sampleRate: Self.rate)
        let quiet = dbToGain(-60), loud = dbToGain(-10)
        for _ in 0..<4_800 { _ = compressor.gain(detectorLeft: quiet, detectorRight: quiet) }
        let full: Float = 20 * 0.9
        var attackFrames = -1
        for i in 0..<48_000 {
            _ = compressor.gain(detectorLeft: loud, detectorRight: loud)
            if attackFrames < 0, compressor.reductionDB >= full * (1 - exp(-1)) { attackFrames = i + 1 }
        }
        #expect(abs(compressor.reductionDB - full) < 0.05)
        var releaseFrames = -1
        for i in 0..<96_000 {
            _ = compressor.gain(detectorLeft: quiet, detectorRight: quiet)
            if releaseFrames < 0, compressor.reductionDB <= full * exp(-1) { releaseFrames = i + 1 }
        }
        let measuredAttack = Double(attackFrames) / Self.rate, measuredRelease = Double(releaseFrames) / Self.rate
        print("Compressor attack \(measuredAttack * 1000) ms release \(measuredRelease * 1000) ms")
        #expect(abs(measuredAttack - attack) / attack < 0.15)
        #expect(abs(measuredRelease - release) / release < 0.15)
    }

    @Test func compressorSidechainHighpassIgnoresALowTone() {
        let tone = Self.sine(50, amplitude: dbToGain(-12), count: 48_000)
        func maximumReduction(_ sidechain: Double?) -> Float {
            var c = LofiCompressor(.init(thresholdDB: -30, ratio: 4, kneeDB: 0, attack: 0.005, release: 0.05,
                                         sidechainHighpassHz: sidechain), sampleRate: Self.rate)
            var l = tone, r = tone
            return c.process(left: &l, right: &r).maxDB
        }
        let filtered = maximumReduction(400), plain = maximumReduction(nil)
        print("Sidechain 50 Hz reduction filtered=\(filtered) dB plain=\(plain) dB")
        #expect(filtered < 0.5)
        #expect(plain > 10)
        var rms = LofiCompressor(.init(thresholdDB: -30, ratio: 4, kneeDB: 0, attack: 0.005, release: 0.05,
                                       rmsWindow: 0.05), sampleRate: Self.rate)
        var l = Self.sine(1_000, amplitude: dbToGain(-12), count: 24_000), r = l
        let stats = rms.process(left: &l, right: &r)
        // RMS of the sine is -15 dBFS: 15 dB over the threshold, 3:1 slope of 3/4 gives about 11.25 dB.
        #expect(abs(rms.reductionDB - 11.25) < 0.5)
        #expect(stats.maxDB >= stats.meanDB)
    }

    @Test func deEsserReducesASibilantBurstAndLeavesMidrangeAlone() {
        let count = 24_000
        func run(_ x: [Float]) -> [Float] {
            var d = LofiDeEsser(band: 5_000...8_000, maxReductionDB: 6, sampleRate: Self.rate)
            return x.map { d.process($0) }
        }
        var burst = [Float](repeating: 0, count: count)
        let tone = Self.sine(6_500, amplitude: 0.5, count: count)
        for i in 4_800..<9_600 { burst[i] = tone[i] }
        let processed = run(burst)
        let reduction = 20 * log10f(Self.rms(processed[7_200..<9_600]) / Self.rms(burst[7_200..<9_600]))
        let mid = Self.sine(1_000, amplitude: 0.5, count: count)
        let midOut = run(mid)
        let midChange = 20 * log10f(Self.rms(midOut[4_800..<24_000]) / Self.rms(mid[4_800..<24_000]))
        print("De-esser 6.5 kHz burst \(reduction) dB, 1 kHz change \(midChange) dB")
        #expect(reduction < -3)
        #expect(abs(midChange) < 0.3)
    }

    // MARK: Saturation

    @Test func saturatorsAreSymmetricMonotonicAndBounded() {
        var previousTape = -Float.infinity, previousClip = -Float.infinity
        for i in -4_000...4_000 {
            let x = Float(i) / 400
            let t = LofiSaturation.tape(x, drive: 2.5)
            let c = LofiSaturation.softClip(x, threshold: 0.5, ceiling: 0.9)
            #expect(t == -LofiSaturation.tape(-x, drive: 2.5))
            #expect(c == -LofiSaturation.softClip(-x, threshold: 0.5, ceiling: 0.9))
            #expect(t >= previousTape && c >= previousClip)
            #expect(abs(c) <= 0.9)
            if abs(x) <= 0.5 { #expect(c == x) }
            previousTape = t
            previousClip = c
        }
        #expect(abs(LofiSaturation.tape(1e-4, drive: 3) / 1e-4 - 1) < 1e-3)
        #expect(LofiSaturation.softClip(1_000, threshold: 0.5, ceiling: 0.9) <= 0.9)
        #expect(LofiSaturation.tape(0.3, drive: 0) == 0.3)
        // C1 continuity at the threshold.
        let slope = (LofiSaturation.softClip(0.5 + 1e-3, threshold: 0.5, ceiling: 0.9) - 0.5) / 1e-3
        #expect(abs(slope - 1) < 0.01)
    }

    @Test func oversampledSaturationSuppressesFoldedHarmonics() {
        let count = 24_000
        let tone = Self.sine(5_000, amplitude: 0.8, count: count)
        let window = 7_200..<(7_200 + 9_600)
        func aliasPower(_ factor: Int) -> (alias: Double, harmonic: Double) {
            var l = tone, r = tone
            LofiSaturation.process(left: &l, right: &r, drive: 3, oversampling: factor)
            var alias = 0.0
            for k in 1...19 where k != 5 && k != 15 {
                let a = Self.amplitude(l, hz: Double(k) * 1_000, rate: Self.rate, range: window)
                alias += a * a
            }
            let h = Self.amplitude(l, hz: 15_000, rate: Self.rate, range: window)
            return (alias, h * h)
        }
        let plain = aliasPower(1), two = aliasPower(2), four = aliasPower(4)
        let improvement4 = 10 * log10(plain.alias / max(four.alias, 1e-30))
        let improvement2 = 10 * log10(plain.alias / max(two.alias, 1e-30))
        print("Saturation alias power below 20 kHz: 1x \(10 * log10(plain.alias)) dB, 2x \(10 * log10(two.alias)) dB, 4x \(10 * log10(four.alias)) dB; 15 kHz harmonic 1x \(10 * log10(plain.harmonic)) 4x \(10 * log10(four.harmonic))")
        #expect(improvement4 >= 40)
        #expect(improvement2 >= 30)
        // The 3rd harmonic survives oversampling (it is in band).
        #expect(abs(10 * log10(four.harmonic / plain.harmonic)) < 1.5)
        // Alignment: a quiet sine passes nearly unchanged and in phase.
        var l = Self.sine(1_000, amplitude: 0.01, count: count), r = l
        let original = l
        LofiSaturation.process(left: &l, right: &r, drive: 1, oversampling: 4)
        let error = zip(l[1_000..<23_000], original[1_000..<23_000]).map { abs($0 - $1) }.max() ?? 1
        #expect(error < 2e-4)
    }

    // MARK: Stereo

    @Test func monoBelowCollapsesTheLowBandAndKeepsTheSumFlat() {
        let count = 48_000
        var left = Self.sine(40, amplitude: 0.5, count: count)
        var right = Self.sine(40, amplitude: 0.5, count: count, phase: .pi / 2)
        #expect(abs(LofiStereo.correlation(left: Array(left[12_000...]), right: Array(right[12_000...]))) < 0.05)
        LofiStereo.monoBelow(120, left: &left, right: &right, sampleRate: Self.rate)
        let low = LofiStereo.correlation(left: Array(left[12_000...]), right: Array(right[12_000...]))
        var highL = Self.sine(2_000, amplitude: 0.5, count: count)
        var highR = highL.map { -$0 }
        LofiStereo.monoBelow(120, left: &highL, right: &highR, sampleRate: Self.rate)
        let high = LofiStereo.correlation(left: Array(highL[12_000...]), right: Array(highR[12_000...]))
        print("monoBelow correlation 40 Hz \(low), 2 kHz antiphase \(high)")
        #expect(low > 0.99)
        #expect(high < -0.99)
        for f in [30.0, 90, 120, 160, 500, 5_000] {
            var l = Self.sine(f, amplitude: 0.5, count: count), r = l
            let original = l
            LofiStereo.monoBelow(120, left: &l, right: &r, sampleRate: Self.rate)
            let change = 20 * log10(Self.amplitude(l, hz: f, rate: Self.rate, range: 24_000..<48_000)
                / Self.amplitude(original, hz: f, rate: Self.rate, range: 24_000..<48_000))
            #expect(abs(change) < 0.3, "flat sum at \(f) Hz: \(change) dB")
        }
        #expect(LofiStereo.correlation(left: [0, 0], right: [1, 1]) == 0)
    }

    // MARK: True peak and loudness

    @Test func truePeakMeterReconstructsTheQuarterRateSineAtFortyFiveDegrees() {
        // Raised-cosine edges keep the reconstruction free of truncation (Gibbs) overshoot.
        let count = 9_600
        let x = Self.sine(Self.rate / 4, amplitude: 0.5, count: count, phase: .pi / 4).enumerated().map { i, v in
            let edge = min(1, Double(min(i, count - 1 - i)) / 1_200)
            return v * Float(0.5 - 0.5 * cos(Double.pi * edge))
        }
        let sample = 20 * log10f(vDSP.maximumMagnitude(x))
        for factor in [4, 16] {
            let tp = 20 * log10f(LofiTruePeak.linear(x, factor: factor))
            print("True peak fs/4 at 45 degrees factor \(factor): +\(tp - sample) dB over sample peak")
            #expect(abs(tp - sample - 3.0103) < 0.1)
        }
        // A low tone's true peak is its amplitude (the sample peak may fall slightly short of it).
        let low = Self.sine(997, amplitude: 0.5, count: count).enumerated().map { i, v in
            v * Float(min(1, Double(min(i, count - 1 - i)) / 1_200))
        }
        #expect(abs(20 * log10f(LofiTruePeak.linear(low, factor: 16) / 0.5)) < 0.01)
        var impulse = [Float](repeating: 0, count: 256)
        impulse[100] = -0.8
        #expect(abs(LofiTruePeak.linear(impulse, factor: 4) - 0.8) < 1e-6)
        #expect(LofiTruePeak.linear([], factor: 16) == 0)
        #expect(abs(LofiTruePeak.dbtp(left: x, right: low) - (sample + 3.0103)) < 0.1)
        #expect(LofiTruePeak.linear(x, factor: 1) == vDSP.maximumMagnitude(x))
    }

    @Test func loudnessMeterReadsMinusTwentyThreeOnTheReferenceTone() {
        for rate in [48_000.0, 44_100] {
            let count = Int(rate * 10)
            let tone = Self.sine(997, amplitude: dbToGain(-23), count: count, rate: rate)
            let result = LofiLoudness.measure(left: tone, right: tone, sampleRate: rate)
            print("Loudness 997 Hz at \(rate): I=\(result.integrated) S=\(result.shortTermMax) M=\(result.momentaryMax) LRA=\(result.range)")
            #expect(abs(result.integrated + 23) < 0.1)
            #expect(abs(result.shortTermMax + 23) < 0.1)
            #expect(abs(result.momentaryMax + 23) < 0.15)
            #expect(result.range < 0.5)
        }
        let rate = Self.rate
        let mono = Self.sine(997, amplitude: 1, count: Int(rate * 5))
        let silent = [Float](repeating: 0, count: mono.count)
        #expect(abs(LofiLoudness.measure(left: mono, right: silent, sampleRate: rate).integrated + 3.01) < 0.1)
        #expect(LofiLoudness.measure(left: silent, right: silent, sampleRate: rate).integrated == -.infinity)
        // Two levels 10 dB apart give a range of about 10 LU.
        let stepped = Self.sine(997, amplitude: dbToGain(-20), count: Int(rate * 20)).enumerated().map { i, x in
            i < Int(rate * 10) ? x : x * dbToGain(-10)
        }
        let range = LofiLoudness.measure(left: stepped, right: stepped, sampleRate: rate).range
        #expect(abs(range - 10) < 0.6)
    }
}
