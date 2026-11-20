import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation

/// A value snapshot published by the conductor after modulation. Held voices never follow later
/// harmony, preset or filter changes. Values come from the actual layer, including inactive layers.
nonisolated struct ControllerAmbientTimbre: Sendable {
    var name: String
    var cutoff: Float = 20000
    var index: Float = 0
    var indexFloor: Float = 0
    var indexSeconds: Double = 1.5
    var ratio: Float = 1
    var detune: Float = 0
    var attack: Double = 0.3
    var release: Double = 1
    var decay: Double? = nil
    var partials: [Float] = []
    var offsets: [Float] = []
    var trim: Float = 1
}

/// Prebuilt, layer-specific native synthesis. The tables/configuration factories are shared with
/// automatic voices; there is no fallback oscillator for an unsupported instrument.
nonisolated final class ControllerAmbientVoice {
    let output: Fader
    private let envelope: Fader
    private let oscs: [Oscillator]
    private let fm: FMOscillator?
    private let morph: [MorphingOscillator]
    private let lead: VoiceLayer?
    private let noise: WhiteNoise?
    private let low: LowPassButterworthFilter?
    private let ladder: MoogLadder?
    private let bands: [BandPassButterworthFilter]
    private let channel: ControllerChannel
    private var generators: [Node] = []

    init(channel: ControllerChannel) {
        self.channel = channel
        var oscs: [Oscillator] = [], morph: [MorphingOscillator] = []
        var fm: FMOscillator?, lead: VoiceLayer?, noise: WhiteNoise?
        var low: LowPassButterworthFilter?, ladder: MoogLadder?
        var bands: [BandPassButterworthFilter] = []
        let source: Node
        switch channel {
        case .drone:
            oscs = DroneLayer.makeOscillators()
            low = LowPassButterworthFilter(Mixer(oscs), cutoffFrequency: 500)
            source = low!
        case .pad:
            morph = (0..<2).map { _ in PadLayer.makeOscillator() }
            let l = Mixer(morph[0]); l.pan = -0.6
            let r = Mixer(morph[1]); r.pan = 0.6
            ladder = MoogLadder(Mixer(l, r), cutoffFrequency: 1200, resonance: 0.1)
            source = ladder!
        case .ambientLead:
            lead = VoiceLayer(config: LeadLayer.voiceConfiguration)
            low = LowPassButterworthFilter(lead!.output, cutoffFrequency: 1900)
            source = low!
        case .keys, .drips:
            fm = KeysLayer.makeOscillator()
            low = LowPassButterworthFilter(fm!, cutoffFrequency: 1600)
            source = low!
        case .grains, .pluck:
            oscs = [channel == .pluck ? PluckLayer.makeOscillator() : GrainLayer.makeOscillator()]
            if channel == .pluck { low = LowPassButterworthFilter(oscs[0], cutoffFrequency: 1200) }
            source = low.map { $0 as Node } ?? oscs[0]
        case .air:
            noise = WhiteNoise(amplitude: 0)
            bands = AirLayer.makeBands(noise!); source = bands[1]
        default: preconditionFailure("No ambient instrument for channel")
        }
        self.oscs = oscs; self.fm = fm; self.morph = morph; self.lead = lead
        self.noise = noise; self.low = low; self.ladder = ladder; self.bands = bands
        envelope = Fader(source, gain: 0)
        output = Fader(envelope, gain: 1)
        generators = oscs.map { $0 as Node } + morph.map { $0 as Node }
        if let fm { generators.append(fm) }
        if let noise { generators.append(noise) }
        if let lead { generators += lead.oscillators }
        generators.forEach { $0.stop() }
    }

    func start(midi: Int, velocity: Float, timbre: ControllerAmbientTimbre) {
        // Only parameter writes and generator starts; all graph construction happened before Play.
        let f = Scale.midiToFrequency(midi)
        low?.cutoffFrequency = timbre.cutoff
        ladder?.cutoffFrequency = timbre.cutoff
        for (i, osc) in oscs.enumerated() {
            let offset = i < timbre.offsets.count ? timbre.offsets[i] : 0
            osc.frequency = f * powf(2, offset / 12) + (i == 2 && channel == .drone ? timbre.detune : 0)
            osc.amplitude = i < timbre.partials.count ? timbre.partials[i] : 0.5
        }
        for (i, osc) in morph.enumerated() {
            osc.frequency = f * powf(2, (i == 0 ? -timbre.detune : timbre.detune) / 1200)
            osc.index = min(3, timbre.index + (i == 0 ? 0 : 0.15))
            osc.amplitude = 0.11 * Float(max(0.4, 1 - 0.012 * Double(midi - 60)))
        }
        if let fm {
            fm.baseFrequency = f; fm.modulatingMultiplier = timbre.ratio
            fm.modulationIndex = timbre.index * (channel == .keys ? (0.7 + 0.3 * min(velocity, 0.7)) : 1)
            fm.amplitude = 0.5 * Float(max(0.55, 1 - 0.02 * Double(max(0, midi - 64))))
        }
        if let noise {
            let center = min(1200, max(250, f))
            noise.amplitude = timbre.partials.first ?? 0.5
            for (i, band) in bands.enumerated() {
                band.centerFrequency = center
                band.bandwidth = center * timbre.ratio * (i == 0 ? 1 : 1.3)
            }
        }
        if let lead {
            lead.setFrequency(f)
            lead.setEnvelope(attack: Float(timbre.attack), release: Float(timbre.release))
            lead.setAmplitude(0.5)
        }
        generators.forEach { $0.start() }
        lead?.openGate()
        ParamRamp.setGain(output, 1, over: 0.025)
        ParamRamp.setGain(envelope, timbre.trim * velocity, over: lead == nil ? timbre.attack : 0.025)
    }
    func decay(timbre: ControllerAmbientTimbre, over duration: Double) {
        if let fm { ParamRamp.set(fm.$modulationIndex, timbre.indexFloor, over: timbre.indexSeconds) }
        ParamRamp.setGain(envelope, 0, over: duration)
    }
    func pressure(_ gain: Float) { ParamRamp.setGain(output, gain, over: 0.03) }
    func release(over duration: Double) { ParamRamp.setGain(envelope, 0, over: duration) }
    func stop() { lead?.closeGate(); generators.forEach { $0.stop() } }
}
