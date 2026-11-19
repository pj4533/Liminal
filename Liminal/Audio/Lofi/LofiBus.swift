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
    let dryFader: Fader
    let textureFader: Fader
    let wetFader: Fader
    let output: Fader

    init(gain: Float, dialogue: Fader) {
        dryFader = Fader(dry)
        textureFader = Fader(texture)
        wetFader = Fader(wet)
        output = Fader(Mixer(drums, bass, dryFader, textureFader, wetFader, dialogue), gain: gain)
    }

    var players: [AVAudioPlayerNode] { [drums.player, bass.player, dry.player, texture.player, wet.player] }

    func schedule(_ take: LofiDrumTake) {
        drums.player.scheduleBuffer(take.buffer)
    }

    func schedule(_ phrase: LofiRenderer.Phrase) {
        bass.player.scheduleBuffer(phrase.bass)
        dry.player.scheduleBuffer(phrase.dry)
        texture.player.scheduleBuffer(phrase.texture)
        wet.player.scheduleBuffer(phrase.wet)
    }
}
