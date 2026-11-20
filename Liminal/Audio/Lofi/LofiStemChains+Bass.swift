import Accelerate
import Foundation

nonisolated extension LofiStemChains {
    /// Bass, per phrase, mono (plan 2.3). The headroom guard, edge and split kick duck follow in the renderer.
    struct Bass: Sendable, Equatable {
        var highpass: [LofiBiquad.Kind] = [.highpass(hz: 30, q: butterworthQ)]
        /// Parallel harmonics: an asymmetric tanh normalized to the phrase peak, band-passed so only the
        /// generated harmonics between 200 and 900 Hz are added. A 150 Hz corner let the 3rd harmonic of
        /// MIDI 31 and 33 beat with the fundamental inside the C-B2 band, and 1.2 kHz put the bass's 1-4 kHz
        /// band over -55 dB (20 November 2026). A small bias keeps it mostly odd order, like tape.
        var saturationDrive: Float = 4.0
        var saturationBias: Float = 0.03
        var saturationBand: [LofiBiquad.Kind] = [.highpass(hz: 200, q: butterworthQ), .lowpass(hz: 900, q: butterworthQ)]
        var saturationMix: Float = 0.40
        var compressor = Dynamics(ratio: 4, kneeDB: 6, attack: 0.025, release: 0.150, thresholdBelowReferenceDB: 7)
        var maxMakeupDB: Float = 5
        /// Output level after the EQ and the slap (C-B3: bass against drums in 60 to 250 Hz).
        var outputTrimDB: Float = -3.5
        var filters: [LofiBiquad.Kind] = [.peak(hz: 80, q: 0.9, gainDB: 0.5), .peak(hz: 280, q: 1.0, gainDB: -2),
                                          .peak(hz: 700, q: 0.8, gainDB: 2), .lowpass(hz: 2_400, q: butterworthQ)]
        /// Tape slap on the band above `slapHighpass` only: one repeat `slapBeats` late, light feedback,
        /// dark, `slapUnderDB` under that band. Mono, so the stem stays L = R.
        var slapHighpass = 220.0
        var slapBeats = 0.125
        var slapFeedback: Float = 0.15
        var slapLowpass = 1_800.0
        var slapUnderDB: Float = 15
        var dynamicsEnabled = true
        static let standard = Bass()
    }

    /// Bass of one phrase, mono in place (the caller copies it to both channels). `beatSeconds` turns on
    /// the tape slap (its delay is an eighth of a beat).
    @discardableResult
    static func applyBass(_ mono: UnsafeMutablePointer<Float>, count: Int, sampleRate: Double,
                          settings: Bass = .standard, beatSeconds: Double? = nil) -> Stats {
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
        var eq = LofiFilterChain(settings.filters, sampleRate: sampleRate)
        eq.process(mono, count: count)
        if settings.dynamicsEnabled, let beatSeconds, beatSeconds > 0 {
            slap(mono, count: count, sampleRate: sampleRate, beatSeconds: beatSeconds, settings: settings)
        }
        if settings.dynamicsEnabled, settings.outputTrimDB != 0 {
            var trim = dbToGain(settings.outputTrimDB)
            vDSP_vsmul(mono, 1, &trim, mono, 1, vDSP_Length(count))
        }
        (stats.outPeakDb, stats.outRmsDb) = level(mono, mono, count)
        return stats
    }

    /// The tape slap: the band above `slapHighpass`, repeated `slapBeats` late through a low-pass, with
    /// light feedback (the feedback's first three repeats, each through one more low-pass), added
    /// `slapUnderDB` under that band. Vector filters only.
    static func slap(_ mono: UnsafeMutablePointer<Float>, count: Int, sampleRate: Double, beatSeconds: Double,
                     settings: Bass) {
        let delay = max(1, Int((settings.slapBeats * beatSeconds * sampleRate).rounded()))
        guard delay < count else { return }
        var repeatBand = Array(UnsafeBufferPointer(start: mono, count: count))
        var split = LofiFilterChain([.highpass(hz: settings.slapHighpass, q: butterworthQ)], sampleRate: sampleRate)
        repeatBand.withUnsafeMutableBufferPointer { split.process($0.baseAddress!, count: count) }
        var level = dbToGain(-settings.slapUnderDB)
        var tone = LofiFilterChain([.lowpass(hz: settings.slapLowpass, q: butterworthQ)], sampleRate: sampleRate)
        for k in 1...3 {
            let offset = k * delay
            guard offset < count else { break }
            repeatBand.withUnsafeMutableBufferPointer { tone.process($0.baseAddress!, count: count) }
            repeatBand.withUnsafeBufferPointer { b in
                vDSP_vsma(b.baseAddress!, 1, &level, mono + offset, 1, mono + offset, 1, vDSP_Length(count - offset))
            }
            level *= settings.slapFeedback
            tone = LofiFilterChain([.lowpass(hz: settings.slapLowpass, q: butterworthQ)], sampleRate: sampleRate)
        }
    }
}
