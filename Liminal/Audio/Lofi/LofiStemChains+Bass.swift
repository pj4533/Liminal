import Accelerate
import Foundation

nonisolated extension LofiStemChains {
    /// Bass, per phrase, mono (plan 8.3). The kick duck and the `headroom` guard follow in the renderer.
    struct Bass: Sendable, Equatable {
        var highpass: [LofiBiquad.Kind] = [.highpass(hz: 30, q: butterworthQ)]
        /// Parallel harmonics: an asymmetric tanh normalized to the phrase peak, high-passed so only
        /// the generated 2nd and higher harmonics are added.
        var saturationDrive: Float = 4.0
        var saturationBias: Float = 0.2
        var saturationHighpass: [LofiBiquad.Kind] = [.highpass(hz: 120, q: butterworthQ)]
        var saturationMix: Float = 0.20
        var compressor = Dynamics(ratio: 3.5, kneeDB: 6, attack: 0.020, release: 0.150, thresholdBelowReferenceDB: 6)
        var maxMakeupDB: Float = 4
        /// Output level after the EQ: +1 dB puts the bass 60 to 250 Hz near -5 dB of the processed
        /// drum bus (C-B3 asks -6 to +3), measured on the reference capture.
        var outputTrimDB: Float = 1
        var filters: [LofiBiquad.Kind] = [.peak(hz: 280, q: 1.0, gainDB: -2), .lowpass(hz: 4_500, q: butterworthQ)]
        var dynamicsEnabled = true
        static let standard = Bass()
    }

    /// Bass of one phrase, mono in place (the caller copies it to both channels).
    @discardableResult
    static func applyBass(_ mono: UnsafeMutablePointer<Float>, count: Int, sampleRate: Double,
                          settings: Bass = .standard) -> Stats {
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
                var band = LofiFilterChain(settings.saturationHighpass, sampleRate: sampleRate)
                band.process(harmonics, count: count)
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
