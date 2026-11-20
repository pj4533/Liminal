import AudioKit
import AudioKitEX
import AVFoundation

/// The live player and offline captures use the same stem routing.
@MainActor
final class LofiBus {
    let drums = ArchiveVoice.BufferSource()
    let bass = ArchiveVoice.BufferSource()
    let dry = ArchiveVoice.BufferSource()
    let texture = ArchiveVoice.BufferSource()
    let wet = ArchiveVoice.BufferSource()
    let isolated = (0..<3).map { _ in ArchiveVoice.BufferSource() }
    let strips: [ControllerChannel: ControllerChannelStrip]
    private let isolatedStrips: [ControllerChannelStrip]
    private let legacyWet: Fader
    private let independentWet: Fader
    let dryFader: Fader
    let textureFader: Fader
    let wetFader: Fader
    let output: Fader
    private(set) var isolatedReady = false
    let isolatedPreparationEnabled: Bool
    /// Native Debug/Release preparation and capture qualification is deliberately pending.
    /// Never turn this on merely because a listener connects: that would add unmeasured CPU work.
    nonisolated static let isolatedPreparationQualified = false

    init(gain: Float, dialogue: Fader, isolatedPreparationEnabled: Bool = LofiBus.isolatedPreparationQualified) {
        self.isolatedPreparationEnabled = isolatedPreparationEnabled
        let drum = ControllerChannelStrip(drums), bassStrip = ControllerChannelStrip(bass)
        let lead = ControllerChannelStrip(dry), mids = ControllerChannelStrip(texture)
        isolatedStrips = isolated.map { ControllerChannelStrip($0) }
        legacyWet = Fader(wet, gain: 1)
        independentWet = Fader(Mixer(isolatedStrips.map(\.output)), gain: 0)
        let space = ControllerChannelStrip(Mixer(legacyWet, independentWet))
        let chops = ControllerChannelStrip(dialogue)
        strips = [.drums: drum, .bass: bassStrip, .lead: lead, .mids: mids, .lofiSpace: space, .chops: chops]
        dryFader = Fader(lead.output)
        textureFader = Fader(mids.output)
        wetFader = Fader(space.output)
        output = Fader(Mixer(drum.output, bassStrip.output, dryFader, textureFader, wetFader, chops.output), gain: gain)
    }

    /// ArchiveVoice exclusively owns these duck faders. Controller ramps use separate nodes.
    var duckTargets: (lead: Fader, mids: Fader, space: Fader) { (dryFader, textureFader, wetFader) }
    var players: [AVAudioPlayerNode] {
        [drums.player, bass.player, dry.player, texture.player, wet.player] + (isolatedPreparationEnabled ? isolated.map(\.player) : [])
    }
    func controlsReady(_ channel: ControllerChannel) -> Bool {
        ![ControllerChannel.bass, .lead, .mids].contains(channel) || (isolatedPreparationEnabled && isolatedReady)
    }
    /// Manual returns enter source-owned wet controls and the common Space strip; never legacy wet.
    var manualWetInputs: [ControllerChannel: Mixer] {
        [.lead: isolatedStrips[0].manualInput, .mids: isolatedStrips[1].manualInput,
         .bass: isolatedStrips[2].manualInput]
    }
    private func sourceIndex(_ channel: ControllerChannel) -> Int? {
        switch channel { case .lead: return 0; case .mids: return 1; case .bass: return 2; default: return nil }
    }
    @discardableResult func set(_ channel: ControllerChannel, parameter: ControllerParameter, value: Double) -> Bool {
        guard controlsReady(channel), let strip = strips[channel], strip.set(parameter, value: value) else { return false }
        if let index = sourceIndex(channel) { _ = isolatedStrips[index].set(parameter, value: value) }
        updateWetSelection()
        return true
    }
    @discardableResult func setAutomatic(_ channel: ControllerChannel, enabled: Bool) -> Bool {
        guard controlsReady(channel), ![ControllerChannel.lofiSpace, .chops].contains(channel), let strip = strips[channel] else { return false }
        strip.setAutomatic(enabled)
        if let index = sourceIndex(channel) { isolatedStrips[index].setAutomatic(enabled) }
        updateWetSelection()
        return true
    }
    func reset(_ channel: ControllerChannel) {
        strips[channel]?.reset()
        if let index = sourceIndex(channel) { isolatedStrips[index].reset() }
        updateWetSelection()
    }
    private func updateWetSelection() {
        let independent = [ControllerChannel.lead, .mids, .bass].contains { id in
            guard let strip = strips[id] else { return false }
            return !strip.automatic || ControllerParameter.allCases.contains { strip.values[$0] != $0.defaultValue }
        }
        // Never allow residual mixed wet into an isolated/manual channel.
        guard !independent || isolatedReady else { return }
        ParamRamp.setGain(legacyWet, independent ? 0 : 1, over: 0.03)
        ParamRamp.setGain(independentWet, independent ? 1 : 0, over: 0.03)
    }
    func syncBeat(_ duration: Double) {
        for strip in Array(strips.values) + isolatedStrips { strip.syncBeat(duration) }
    }
    func schedule(_ take: LofiDrumTake) { drums.player.scheduleBuffer(take.buffer) }
    func schedule(_ phrase: LofiRenderer.Phrase, wet override: AVAudioPCMBuffer? = nil, repeated: Bool = false, silence: AVAudioPCMBuffer? = nil) {
        bass.player.scheduleBuffer(phrase.bass)
        dry.player.scheduleBuffer(phrase.dry)
        texture.player.scheduleBuffer(phrase.texture)
        wet.player.scheduleBuffer(override ?? phrase.wet)
        if isolatedPreparationEnabled {
            isolatedReady = phrase.isolatedWet.count == 3
            for (index, lane) in phrase.isolatedWet.enumerated() {
                isolated[index].player.scheduleBuffer(repeated ? (override === silence ? (silence ?? lane.fallback) : lane.fallback) : lane.buffer)
            }
        }
    }
}
