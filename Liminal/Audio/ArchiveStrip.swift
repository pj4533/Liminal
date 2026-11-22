import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation

/// The film bed's output strip: level fader, panner, a direct-sound fader and the reverb and echo
/// sends into `ArchiveMixBus`. The panner fans out to the direct fader and both sends.
nonisolated final class ArchiveStrip {
    let level: Fader
    let panner: Panner
    let dryGain: Fader
    let reverbSend: Fader
    let delaySend: Fader
    /// Linear gain at full fade (the Footage audio setting times the base trim).
    var trim: Float
    private var fade = SoftEnv(0)
    private var lastWritten: Float = -1
    private(set) var pan: Float = 0

    var outputs: (dry: Node, reverbSend: Node, delaySend: Node) { (dryGain, reverbSend, delaySend) }

    /// Fade position 0...1.
    var fadeValue: Float { fade.value }

    init(source: Node, trim: Float, reverb: Float, delay: Float, dry: Float, pan: Float = 0) {
        self.trim = trim
        level = Fader(source, gain: 0)
        let p = Panner(level, pan: pan)
        panner = p
        self.pan = pan
        reverbSend = Fader(p, gain: reverb)
        delaySend = Fader(p, gain: delay)
        dryGain = Fader(p, gain: dry)
    }

    func fade(to v: Float, over: Double, now: Double) { fade.go(to: v, over: over, now: now) }

    /// 10 Hz: advance the fade and write the level.
    func tick(now: Double) {
        let g = trim * fade.tick(now)
        if abs(g - lastWritten) > 1e-5 {
            ParamRamp.setGain(level, g, over: 0.12)
            lastWritten = g
        }
    }

    func setPan(_ p: Float, over: Double) {
        pan = min(max(p, -1), 1)
        ParamRamp.set(panner.$pan, pan, over: over)
    }

    func setSends(reverb: Float, delay: Float, over: Double) {
        ParamRamp.setGain(reverbSend, reverb, over: over)
        ParamRamp.setGain(delaySend, delay, over: over)
    }
}
