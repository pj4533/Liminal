import Accelerate
import Foundation

/// A recorded kick paired with the start of one bass note, both on the take's frame clock.
/// The phrase render worker chooses the note's polarity before mixing any of its layers.
nonisolated struct LofiBassKickPhase {
    let drums: LofiDrumTake
    let kickFrame: Int
    let noteFrame: Int
    let settings: LofiStemChains.Bass

    func shouldInvert(tone: [Float], strike: [Float], strikeShift: Int) -> Bool {
        guard let channels = drums.buffer.floatChannelData else { return false }
        let rate = drums.clock.sampleRate
        let span = Int(0.120 * rate), pad = Int(0.080 * rate)
        let start = max(0, kickFrame - pad)
        let end = min(Int(drums.buffer.frameLength), kickFrame + span + pad)
        guard kickFrame >= start, end >= kickFrame + span, span >= 3 else { return false }
        var kick = (start..<end).map { (channels[0][$0] + channels[1][$0]) * 0.5 }
        var bass = [Float](repeating: 0, count: kick.count)
        func add(_ layer: [Float], at frame: Int) {
            let lo = max(start, frame), hi = min(end, frame + layer.count)
            guard lo < hi else { return }
            for i in lo..<hi { bass[i - start] += layer[i - frame] }
        }
        add(tone, at: noteFrame)
        add(strike, at: noteFrame + strikeShift)
        // The shared bass chain rotates the sub through these causal filters. Its parallel
        // harmonics and cue are above this band. The compressor's phrase gain is estimated
        // at unity, so require strongly opposed waveforms as well as a substantial energy loss.
        var bassEQ = LofiFilterChain(settings.highpass + settings.filters, sampleRate: rate)
        bassEQ.process(&bass, count: bass.count)
        if settings.dynamicsEnabled {
            var trim = dbToGain(settings.outputTrimDB)
            vDSP_vsmul(bass, 1, &trim, &bass, 1, vDSP_Length(bass.count))
        }
        // Pole frequencies and Qs of a fourth-order Butterworth prototype transformed
        // to a 40–120 Hz band-pass. Common gain cancels from every ratio below.
        let band: [LofiBiquad.Kind] = [.highpass(hz: 41.190, q: 2.57594), .highpass(hz: 53.675, q: 0.96808),
                                       .lowpass(hz: 89.427, q: 0.96808), .lowpass(hz: 116.533, q: 2.57594)]
        var filter = LofiFilterChain(band, sampleRate: rate)
        filter.process(left: &kick, right: &bass)
        kick.reverse()
        bass.reverse()
        filter.reset()
        filter.process(left: &kick, right: &bass)
        kick.reverse()
        bass.reverse()
        let offset = kickFrame - start
        return Self.cancels(kick: kick[offset..<(offset + span)], bass: bass[offset..<(offset + span)])
    }

    /// The onset and the full 120 ms kick body must both oppose the note. A single deep
    /// half-cycle or a weak out-of-phase tail can otherwise turn a healthy attack around.
    static func cancels(kick: ArraySlice<Float>, bass: ArraySlice<Float>) -> Bool {
        guard kick.count == bass.count, kick.count >= 3 else { return false }
        var kk = 0.0, bb = 0.0, kb = 0.0
        let onset = kick.count / 3
        for (index, pair) in zip(kick, bass).enumerated() {
            let k = Double(pair.0), b = Double(pair.1)
            kk += k * k
            bb += b * b
            kb += k * b
            if index + 1 == onset, kb >= -0.80 * sqrt(kk * bb) { return false }
        }
        let sumPower = kk + bb + 2 * kb
        return kb < -0.707 * sqrt(kk * bb) && sumPower < pow(10, -2.5 / 10.0) * max(kk, bb)
    }
}
