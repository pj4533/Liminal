import AudioKit
import AudioKitEX
import SoundpipeAudioKit

/// Per-slot dark echo/room. Configured from the onset program only while silent; held voices and
/// their return never jump to a later phrase's delay time. Routed to source-owned wet, then Space.
nonisolated final class ControllerLofiReturns {
    private let feed: Fader
    private let echoes: [VariableDelay]
    private let echoTone: [LowPassButterworthFilter]
    private let room: ZitaReverb
    private let roomTone: LowPassButterworthFilter
    private let echoGain: Fader
    private let roomGain: Fader
    let output: Fader

    init(_ source: Node) {
        let feed = Fader(source, gain: 0)
        self.feed = feed
        echoes = (0..<2).map { _ in VariableDelay(feed, time: 0.5, feedback: 0.4, maximumTime: 4, dryWetMix: 1) }
        echoTone = echoes.map { LowPassButterworthFilter($0, cutoffFrequency: 2800) }
        echoGain = Fader(Mixer(echoTone), gain: 0)
        room = ZitaReverb(feed, predelay: 18, crossoverFrequency: 300, lowReleaseTime: 0.45,
                          midReleaseTime: 0.9, dampingFrequency: 2800, dryWetMix: 1)
        roomTone = LowPassButterworthFilter(room, cutoffFrequency: 3200)
        roomGain = Fader(roomTone, gain: 0)
        output = Fader(Mixer(echoGain, roomGain), gain: 0)
        stop()
    }
    func start(preset: LofiPreset, beat: Double, bass: Bool) {
        echoes[0].time = Float(min(4, preset.space.taps.left * beat))
        echoes[1].time = Float(min(4, preset.space.taps.right * beat))
        for echo in echoes { echo.feedback = min(0.65, preset.space.feedback); echo.start() }
        echoTone.forEach { $0.start() }; room.start(); roomTone.start()
        // Bass is ordinarily dry; human bass notes may use the channel's user echo/room controls.
        ParamRamp.setGain(feed, bass ? 0 : 0.25, over: 0.025)
        ParamRamp.setGain(echoGain, 0.4, over: 0.025)
        ParamRamp.setGain(roomGain, min(0.3, preset.space.diffusion * 0.2), over: 0.025)
        ParamRamp.setGain(output, 1, over: 0.025)
    }
    func release(over duration: Double) { ParamRamp.setGain(output, 0, over: duration) }
    func stop() {
        echoes.forEach { $0.stop() }; echoTone.forEach { $0.stop() }
        room.stop(); roomTone.stop()
    }
}
