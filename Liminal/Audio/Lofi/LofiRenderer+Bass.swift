import AVFoundation
import Accelerate
import Foundation

nonisolated extension LofiRenderer {
    /// One bass note into the phrase's bass buffers.
    static func addBass(_ note: LofiScore.Note, score: LofiScore, clock: LofiClock, samples: LofiSampleBank,
                        left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>) {
        LofiBassVoice.add(note, voice: score.bassVoice, clock: clock, left: left, right: right)
    }

    /// Bass-line throws and fills that are not scored notes. Nothing yet.
    static func addBassThrow(score: LofiScore, clock: LofiClock, frames: Int,
                             into bass: (left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>)) {}

    /// Mono chain on the rendered voice, then the headroom guard, edge envelope and kick duck, copied to R.
    /// Returns the chain's stats with the deepest kick duck.
    static func finishBass(left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>,
                           frames n: Int, sampleRate: Double, envelope: [Float], drums: LofiDrumTake?,
                           drumOffset: Int, kickDuck: inout LofiKickDuck) -> LofiStemChains.Stats {
        let drumChannels = drums?.buffer.floatChannelData
        guard let bassL = left.baseAddress, let bassR = right.baseAddress else { return LofiStemChains.Stats() }
        // Bass: mono chain on the rendered voice, before the edge envelope and the kick duck.
        vDSP_vadd(bassL, 1, bassR, 1, bassL, 1, vDSP_Length(n))
        var half: Float = 0.5
        vDSP_vsmul(bassL, 1, &half, bassL, 1, vDSP_Length(n))
        var bassStats = LofiStemChains.applyBass(bassL, count: n, sampleRate: sampleRate)

        // Bass: headroom guard after the chain, edge envelope, then the kick duck (mono), keyed by the
        // take's kick landmarks when it has confident kicks, else by the level detector.
        let landmarkDuck = drums.flatMap {
            LofiKickDuck.landmarkGains($0.landmarks, start: drumOffset, count: n, sampleRate: sampleRate)
        }
        envelope.withUnsafeBufferPointer { envelope in
            if let landmarkDuck {
                var deepest: Float = 1
                for frame in 0..<n {
                    let kickGain = landmarkDuck[frame]
                    deepest = kickGain < deepest ? kickGain : deepest
                    bassL[frame] = headroom(bassL[frame]) * envelope[frame] * kickGain
                }
                bassStats.extra["kickDuckMaxDb"] = -20 * log10f(deepest)
            } else if let drumChannels {
                let drumL = drumChannels[0] + drumOffset, drumR = drumChannels[1] + drumOffset
                var deepest: Float = 1
                for frame in 0..<n {
                    let kickGain = kickDuck.gain(drumLeft: drumL[frame], drumRight: drumR[frame])
                    deepest = kickGain < deepest ? kickGain : deepest
                    bassL[frame] = headroom(bassL[frame]) * envelope[frame] * kickGain
                }
                bassStats.extra["kickDuckMaxDb"] = -20 * log10f(deepest)
            } else {
                for frame in 0..<n { bassL[frame] = headroom(bassL[frame]) * envelope[frame] }
            }
        }
        bassR.update(from: bassL, count: n)
        return bassStats
    }

    /// Capture-only: one `diagnostics.bass` element per phrase, frames on the capture timeline
    /// (phrase index times phrase frames). `attackFrame` is the note start plus the voice's attack lead
    /// (its 20 percent point). For an accent aligned to a kick, `alignedKickFrame` is the kick's broadband
    /// attack, `kickLowRiseFrame` the kick's 40-160 Hz half-amplitude rise measured on the take, and
    /// `bassLowRiseFrame` the same measure on this phrase's finished bass stem (after the chain, the
    /// headroom guard and the kick duck); `bassLowRiseFrame - kickLowRiseFrame` is the real alignment error.
    static func reportBass(_ score: LofiScore, clock: LofiClock, phrase: Int, bass: UnsafePointer<Float>) {
        guard LofiCaptureHooks.isEnabled else { return }
        let origin = phrase * clock.frameCount
        let lead = Int((score.bassVoice.attackLead * clock.sampleRate).rounded())
        let notes: [[String: Any]] = score.notes.filter { $0.part == .bass }.map { note in
            let local = clock.frame(at: note.beat)
            let frame = origin + local
            let kick = score.bassAnchors.first { $0.noteBeat == note.beat }
            var row: [String: Any] = ["frame": frame, "attackFrame": frame + lead, "midi": note.midi,
                                      "alignedKickFrame": kick.map { origin + clock.frame(at: $0.kickBeat) as Any } ?? NSNull()]
            if let kick {
                row["kickLowRiseFrame"] = origin + clock.frame(at: kick.kickLowRiseBeat)
                let rise = LofiDrumLandmarks.lowBandRise(bass, count: clock.frameCount, around: local + lead,
                                                         sampleRate: clock.sampleRate)
                row["bassLowRiseFrame"] = rise.map { origin + $0 as Any } ?? NSNull()
                row["plannedBassLowRiseFrame"] = frame + clock.frame(at: kick.bassLowRiseBeats)
            }
            return row
        }
        LofiCaptureHooks.appendReport("bass", ["phrase": phrase, "voice": String(describing: score.bassVoice),
                                               "notes": notes] as [String: Any])
    }
}
