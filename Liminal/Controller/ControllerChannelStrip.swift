import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation

/// Additive performance controls. Generator/ArchiveVoice automation never writes these nodes.
/// Construct once with the graph, mutate on the owner's control queue, never in a render callback.
nonisolated final class ControllerChannelStrip {
    let automaticGate: Fader
    /// Next-stage voices connect here, upstream of the same user processing as automatic audio.
    let manualInput = Mixer()
    let input: Mixer
    let lowCut: HighPassButterworthFilter
    let highCut: LowPassButterworthFilter
    private let cutDry: Fader
    private let cutWet: Fader
    private let highDry: Fader
    private let highWet: Fader
    private let toneDry: Fader
    private let toneWet: Fader
    let tone: HighShelfParametricEqualizerFilter
    let drive: TanhDistortion
    private let dryDrive: Fader
    private let wetDrive: Fader
    private let echoFeed: [Fader]
    private let echoes: [VariableDelay]
    private let echoReturns: [Fader]
    private let echoFilters: [LowPassButterworthFilter]
    private let roomFilter: LowPassButterworthFilter
    private var echoLane = 0
    private var beatDuration: Double = 0.8333333333
    private let roomFeed: Fader
    private let room: ZitaReverb
    let output: Fader
    private(set) var values = Dictionary(uniqueKeysWithValues: ControllerParameter.allCases.map { ($0, $0.defaultValue) })
    private(set) var automatic = true

    init(_ source: Node) {
        automaticGate = Fader(source, gain: 1)
        input = Mixer(automaticGate, manualInput)
        lowCut = HighPassButterworthFilter(input, cutoffFrequency: 20)
        cutDry = Fader(input, gain: 1); cutWet = Fader(lowCut, gain: 0)
        let low = Mixer(cutDry, cutWet)
        highCut = LowPassButterworthFilter(low, cutoffFrequency: 20000)
        highDry = Fader(low, gain: 1); highWet = Fader(highCut, gain: 0)
        let high = Mixer(highDry, highWet)
        tone = HighShelfParametricEqualizerFilter(high, centerFrequency: 1500, gain: 1)
        toneDry = Fader(high, gain: 1); toneWet = Fader(tone, gain: 0)
        let colored = Mixer(toneDry, toneWet)
        drive = TanhDistortion(colored, pregain: 1, postgain: 1, dryWetMix: 1)
        dryDrive = Fader(colored, gain: 1)
        wetDrive = Fader(drive, gain: 0)
        let body = Mixer(dryDrive, wetDrive)
        echoFeed = [Fader(body, gain: 0), Fader(body, gain: 0)]
        echoes = echoFeed.map { VariableDelay($0, time: 0.625, feedback: 0.32, maximumTime: 4, dryWetMix: 1) }
        echoFilters = echoes.map { LowPassButterworthFilter($0, cutoffFrequency: 2800) }
        echoReturns = echoFilters.map { Fader($0, gain: 1) }
        roomFeed = Fader(body, gain: 0)
        room = ZitaReverb(roomFeed, predelay: 18, crossoverFrequency: 300, lowReleaseTime: 0.45,
                          midReleaseTime: 0.9, dampingFrequency: 2800, dryWetMix: 1)
        roomFilter = LowPassButterworthFilter(room, cutoffFrequency: 3200)
        output = Fader(Mixer([body, roomFilter] + echoReturns), gain: 1)
        // Stopped AudioKit effects bypass. The untouched signal only crosses unity mixers/faders.
        lowCut.stop(); highCut.stop(); tone.stop(); drive.stop()
        echoes.forEach { $0.stop() }; room.stop()
        echoFilters.forEach { $0.stop() }; roomFilter.stop()
    }

    func setAutomatic(_ enabled: Bool) {
        automatic = enabled
        ParamRamp.setGain(automaticGate, enabled ? 1 : 0, over: 0.03)
    }

    /// Strict wire validation is also enforced here for callers outside the protocol.
    @discardableResult
    func set(_ parameter: ControllerParameter, value: Double) -> Bool {
        guard value.isFinite, (0...1).contains(value) else { return false }
        values[parameter] = value
        let v = Float(value), ramp = 0.03
        switch parameter {
        case .gain: applyOutput()
        case .pan: applyOutput()
        case .low_cut:
            lowCut.start()
            ParamRamp.setGain(cutDry, value == 0 ? 1 : 0, over: ramp)
            ParamRamp.setGain(cutWet, value == 0 ? 0 : 1, over: ramp)
            ParamRamp.set(lowCut.$cutoffFrequency, value == 0 ? 12 : 20 * powf(100, v), over: ramp)
        case .high_cut:
            highCut.start()
            ParamRamp.setGain(highDry, value == 1 ? 1 : 0, over: ramp)
            ParamRamp.setGain(highWet, value == 1 ? 0 : 1, over: ramp)
            ParamRamp.set(highCut.$cutoffFrequency, value == 1 ? 20000 : 200 * powf(100, v), over: ramp)
        case .tone:
            tone.start()
            ParamRamp.setGain(toneDry, value == 0.5 ? 1 : 0, over: ramp)
            ParamRamp.setGain(toneWet, value == 0.5 ? 0 : 1, over: ramp)
            ParamRamp.set(tone.$gain, powf(10, 12 * (v - 0.5) / 20), over: ramp)
        case .drive:
            drive.start()
            let pre = powf(10, 12 * v / 20)
            ParamRamp.set(drive.$pregain, pre, over: ramp)
            ParamRamp.set(drive.$postgain, 1 / pre, over: ramp)
            let dry = cosf(v * .pi / 2), wet = sinf(v * .pi / 2)
            // Equal-power proportions, compensated for correlated dry/wet at small signal levels.
            let compensation = 1 / max(1, dry + wet)
            ParamRamp.setGain(dryDrive, dry * compensation, over: ramp)
            ParamRamp.setGain(wetDrive, wet * compensation, over: ramp)
        case .echo:
            echoes.forEach { $0.start() }; echoFilters.forEach { $0.start() }
            ParamRamp.setGain(echoFeed[echoLane], 0.35 * v, over: ramp)
        case .room:
            room.start(); roomFilter.start()
            ParamRamp.setGain(roomFeed, 0.30 * v, over: ramp)
        }
        return true
    }

    private func applyOutput() {
        let gain = Float(ControllerParameter.linearGain(values[.gain] ?? 0.5))
        let pan = Float(2 * (values[.pan] ?? 0.5) - 1)
        // Stereo balance: center unity (no -3 dB panner insertion at the default).
        ParamRamp.set(output.$leftGain, gain * (pan > 0 ? 1 - pan : 1), over: 0.03)
        ParamRamp.set(output.$rightGain, gain * (pan < 0 ? 1 + pan : 1), over: 0.03)
    }

    func syncBeat(_ seconds: Double) {
        guard seconds.isFinite, (0.25...2).contains(seconds), abs(seconds - beatDuration) > 0.0001 else { return }
        beatDuration = seconds
        // Stop feeding the old line but leave its original read position/tail unchanged.
        ParamRamp.setGain(echoFeed[echoLane], 0, over: 0.03)
        echoLane = 1 - echoLane
        // The retired lane has had an entire phrase to decay before reuse.
        echoes[echoLane].$time.parameter?.value = Float(seconds * 0.75)
        ParamRamp.setGain(echoFeed[echoLane], Float(values[.echo] ?? 0) * 0.35, over: 0.03)
    }

    func reset() {
        for p in ControllerParameter.allCases { _ = set(p, value: p.defaultValue) }
        setAutomatic(true)
    }
}
