import AVFoundation
import Accelerate
import Foundation

nonisolated extension LofiRenderer {
    /// One bass note into the phrase's bass buffers, with the phrase's voice and breakdown sweep.
    static func addBass(_ note: LofiScore.Note, score: LofiScore, clock: LofiClock, samples: LofiSampleBank,
                        left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>) {
        LofiBassVoice.add(note, voice: score.bassVoice, clock: clock, left: left, right: right,
                          samples: .bundled, sweep: score.bassSweep, beforeStrike: score.bassBeforeStrike(note),
                          strikeShift: score.bassStrikeShift(note, clock: clock))
    }

    /// Dub throws (plan 2.4): the body of each thrown bass note through the echo and spring, added to the
    /// phrase's space arrays (phrase plus tail) before `LofiStemChains.applySpace`. The return then takes
    /// the space filters, the lead-keyed space duck, the chop duck on the wet fader, the return's carry
    /// dip and the carried tail like every other return; the bass stem itself stays dry and mono.
    static func addBassThrow(score: LofiScore, clock: LofiClock, frames: Int,
                             spaceLeft: inout [Float], spaceRight: inout [Float]) {
        guard LofiBassThrow.isEnabled else { return }
        let thrown = score.notes.filter { $0.part == .bass && $0.send > 0 && $0.velocity > 0 }
        guard !thrown.isEmpty, score.bassVoice != .classic else { return }
        let kit = score.bassThrowKit
        // Only the frames the return can reach are rendered.
        let total = min(frames, spaceLeft.count, spaceRight.count)
        let origin = max(0, min(total, thrown.map { clock.frame(at: $0.beat) }.min() ?? total))
        let last = thrown.map { clock.frame(at: $0.beat + $0.length) + Int(0.2 * clock.sampleRate) }.max() ?? 0
        let end = min(total, last + LofiBassThrow.ringFrames(clock))
        guard end > origin else { return }
        let ret = LofiBassThrow.render(thrown, kit: kit, clock: clock, frames: end - origin, origin: origin,
                                       sweep: score.bassSweep)
        spaceLeft.withUnsafeMutableBufferPointer { l in
            vDSP_vadd(l.baseAddress! + origin, 1, ret.left, 1, l.baseAddress! + origin, 1, vDSP_Length(ret.left.count))
        }
        spaceRight.withUnsafeMutableBufferPointer { r in
            vDSP_vadd(r.baseAddress! + origin, 1, ret.right, 1, r.baseAddress! + origin, 1, vDSP_Length(ret.right.count))
        }
    }

    /// Mono chain on the rendered voice, then the headroom guard, edge envelope and the split kick duck,
    /// copied to R. Returns the chain's stats with the deepest kick duck.
    static func finishBass(left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>,
                           frames n: Int, sampleRate: Double, envelope: [Float], drums: LofiDrumTake?,
                           drumOffset: Int, anchoredKicks: [Int], kickDuck: inout LofiKickDuck) -> LofiStemChains.Stats {
        let drumChannels = drums?.buffer.floatChannelData
        guard let bassL = left.baseAddress, let bassR = right.baseAddress else { return LofiStemChains.Stats() }
        // Bass: mono chain on the rendered voice, before the edge envelope and the kick duck.
        vDSP_vadd(bassL, 1, bassR, 1, bassL, 1, vDSP_Length(n))
        var half: Float = 0.5
        vDSP_vsmul(bassL, 1, &half, bassL, 1, vDSP_Length(n))
        // Kicks the score anchored a bass note to (`anchoredKicks`, take frames) are not ducked: there the
        // kick and the bass hit together and sum (C-B2), and a duck would put the note's onset 4 dB under its
        // own body. Taken from the score, not the audio, so a downbeat kick at frame 0 counts too.
        let struck = drums.map { LofiKickDuck.anchoredKicks($0.landmarks, near: anchoredKicks, sampleRate: sampleRate) } ?? []
        var bassStats = LofiStemChains.applyBass(bassL, count: n, sampleRate: sampleRate)

        // Headroom guard after the chain, then the kick duck (mono), keyed by the take's kick landmarks when
        // it has confident kicks, else by the level detector, then the edge envelope last: the split duck's
        // zero-phase low-pass spreads signal toward the edges, so the envelope must follow it for the stem to
        // be exactly zero at both phrase edges.
        var frame = 0
        while frame < n { bassL[frame] = headroom(bassL[frame]); frame += 1 }
        var gains: [Float]?
        if let drums, let landmark = LofiKickDuck.landmarkGains(drums.landmarks, start: drumOffset, count: n,
                                                                sampleRate: sampleRate, excluding: struck) {
            gains = landmark
        } else if let drumChannels {
            let drumL = drumChannels[0] + drumOffset, drumR = drumChannels[1] + drumOffset
            gains = (0..<n).map { kickDuck.gain(drumLeft: drumL[$0], drumRight: drumR[$0]) }
        }
        if let gains {
            bassStats.extra["kickDuckMaxDb"] = -20 * log10f(gains.min() ?? 1)
            LofiKickDuck.applySplit(gains, to: bassL, count: n, sampleRate: sampleRate)
        }
        envelope.withUnsafeBufferPointer { e in vDSP_vmul(bassL, 1, e.baseAddress!, 1, bassL, 1, vDSP_Length(n)) }
        bassR.update(from: bassL, count: n)
        return bassStats
    }

    /// Capture-only: one `diagnostics.bass` element per phrase, frames on the capture timeline
    /// (phrase index times phrase frames). `attackFrame` is the note start plus the voice's attack lead
    /// (its 20 percent point). For a note anchored to a kick, `alignedKickFrame` is the kick's broadband
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
                                      "stroke": String(describing: note.stroke), "thrown": note.send > 0,
                                      "strike": note.strike, "release": score.bassRelease(note),
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
