import Accelerate
import Foundation

nonisolated extension LofiStemChains {
    /// Bass, per phrase, mono (plan 2.3, retuned by plan bass-tone-redo 3). The headroom guard, edge and
    /// split kick duck follow in the renderer.
    struct Bass: Sendable, Equatable {
        var highpass: [LofiBiquad.Kind] = [.highpass(hz: 30, q: butterworthQ)]
        /// Parallel harmonics: a gently driven asymmetric tanh normalized to the phrase peak, band-passed
        /// (zero phase) so only the generated 2nd and 3rd harmonics between 200 and 500 Hz are added, about
        /// 16 dB under the dry band. The bias makes it mostly even order. (D116 drove it at 4 into 200-900 Hz
        /// at mix 0.40 on top of a driven body: the "tinny" midrange, 20 November 2026.)
        var saturationDrive: Float = 2.0
        var saturationBias: Float = 0.08
        var saturationBand: [LofiBiquad.Kind] = [.highpass(hz: 200, q: butterworthQ), .lowpass(hz: 450, q: 0.541_196_100_146_197),
                                                 .lowpass(hz: 450, q: 1.306_562_964_876_377)]
        var saturationMix: Float = 0.15
        /// 4:1 from 9 dB under the phrase's reference: 2 to 3 dB mean reduction on the sustained line (at 7 dB
        /// the longer notes read 1.0 dB mean). The 25 ms attack lets the strike through.
        var compressor = Dynamics(ratio: 4, kneeDB: 6, attack: 0.025, release: 0.150, thresholdBelowReferenceDB: 9)
        var maxMakeupDB: Float = 5
        /// Output level after the EQ (C-B3: bass against drums in 60 to 250 Hz).
        var outputTrimDB: Float = -4.45
        /// A little weight, a light dip under the chords, and a 24 dB per octave low-pass at 1.4 kHz (two
        /// Butterworth sections): the kick supplies everything above, so no bass hiss or "tin" is left there.
        var filters: [LofiBiquad.Kind] = [.peak(hz: 80, q: 0.9, gainDB: 0.5), .peak(hz: 300, q: 1.0, gainDB: -1),
                                          .lowpass(hz: 1_400, q: 0.541_196_100_146_197),
                                          .lowpass(hz: 1_400, q: 1.306_562_964_876_377)]
        var dynamicsEnabled = true
        static let standard = Bass()
    }

    /// Bass of one phrase, mono in place (the caller copies it to both channels). `cue`, when given, is the
    /// phrase's clean cue partials (`LofiBassVoice.Cue`, D129, `count` frames): added after the parallel
    /// harmonics and the compressor's makeup, before the EQ and trim, so it is neither saturated (no
    /// intermodulation with the sub) nor able to move the compressor and with it the sub's level.
    @discardableResult
    static func applyBass(_ mono: UnsafeMutablePointer<Float>, count: Int, sampleRate: Double,
                          settings: Bass = .standard, cue: UnsafePointer<Float>? = nil) -> Stats {
        var stats = Stats()
        guard count > 0 else { return stats }
        (stats.inPeakDb, stats.inRmsDb) = level(mono, mono, count)
        var highpass = LofiFilterChain(settings.highpass, sampleRate: sampleRate)
        highpass.process(mono, count: count)
        if settings.dynamicsEnabled {
            let peak = peakLinear(mono, count)
            if peak > 1e-6 {
                let harmonics = UnsafeMutablePointer<Float>.allocate(capacity: count)
                defer { harmonics.deallocate() }
                harmonics.update(from: mono, count: count)
                let drive = settings.saturationDrive, bias = settings.saturationBias
                let offset = tanhf(drive * bias)
                let scale = peak / max(1e-6, tanhf(drive * (1 + bias)) - offset)
                LofiSaturation.oversampled(harmonics, count: count, factor: 2) { buffer, n in
                    // y = peak * (tanh(drive (x / peak + bias)) - tanh(drive bias)) / norm
                    var a = drive / peak, b = drive * bias, c = -offset, s = scale, length = Int32(n)
                    vDSP_vsmsa(buffer, 1, &a, &b, buffer, 1, vDSP_Length(n))
                    vvtanhf(buffer, buffer, &length)
                    vDSP_vsadd(buffer, 1, &c, buffer, 1, vDSP_Length(n))
                    vDSP_vsmul(buffer, 1, &s, buffer, 1, vDSP_Length(n))
                }
                // Zero phase (forward, then backward), so the added harmonics land in phase with the
                // voice's own: a causal band-pass turned the 3rd harmonic near its corner against the sub's.
                var forward = LofiFilterChain(settings.saturationBand, sampleRate: sampleRate)
                forward.process(harmonics, count: count)
                vDSP_vrvrs(harmonics, 1, vDSP_Length(count))
                var backward = LofiFilterChain(settings.saturationBand, sampleRate: sampleRate)
                backward.process(harmonics, count: count)
                vDSP_vrvrs(harmonics, 1, vDSP_Length(count))
                var mix = settings.saturationMix
                vDSP_vsma(harmonics, 1, &mix, mono, 1, mono, 1, vDSP_Length(count))
            }
            let reference = referenceDB(mono, mono, count, sampleRate: sampleRate)
            let before = level(mono, mono, count).rms
            let reduction = compress(mono, nil, count, settings: settings.compressor.settings(
                thresholdDB: reference - settings.compressor.thresholdBelowReferenceDB), sampleRate: sampleRate)
            // Makeup restores the pre-compression level (bounded), so evening the sustain never
            // turns the bass down against the kick.
            var makeup = dbToGain(min(settings.maxMakeupDB, max(0, before - level(mono, mono, count).rms)))
            vDSP_vsmul(mono, 1, &makeup, mono, 1, vDSP_Length(count))
            stats.grMeanDb = reduction.meanDB
            stats.grMaxDb = reduction.maxDB
            stats.extra["makeupDb"] = gainToDB(makeup)
        }
        if let cue { vDSP_vadd(mono, 1, cue, 1, mono, 1, vDSP_Length(count)) }
        var eq = LofiFilterChain(settings.filters, sampleRate: sampleRate)
        eq.process(mono, count: count)
        if settings.dynamicsEnabled, settings.outputTrimDB != 0 {
            var trim = dbToGain(settings.outputTrimDB)
            vDSP_vsmul(mono, 1, &trim, mono, 1, vDSP_Length(count))
        }
        (stats.outPeakDb, stats.outRmsDb) = level(mono, mono, count)
        return stats
    }
}
