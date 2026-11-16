import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import AVFoundation
import Foundation
import OSLog

/// The sound of an archive film (docs/plans/archive-video.md 4, decisions A14-A18). One more static strip
/// in the music graph, built once with the others and never rewired:
///
///     buffer player -> HPF 220 Hz -> LPF 2.4 kHz -> LPF 2.4 kHz -> LayerStrip
///     LayerStrip: dry -12 dB, reverb send 1.0, delay send 0.6, slow pan walk +-0.4
///
/// Mostly wet: what is heard is the Zita tail and the dark tape delay of the existing `MixBus`, so the film
/// shares the music's room. It ducks nothing and adds no reverb of its own. The buffer arrives already slowed
/// to the footage's rate (pitched down like slowed tape) and normalised (`ArchiveAudioDecoder`). Conductor
/// queue / offline render thread only.
nonisolated final class ArchiveVoice {

    /// A decoded segment ready to play, posted with `MusicControl.archiveBegin`.
    struct Cue {
        let buffer: AVAudioPCMBuffer
        /// Linear gain on top of `baseTrim` ("Footage audio": 1 at the default 0.5, 2 at the top).
        let gain: Float
        let fadeIn: Double
        let label: String
    }

    /// Node wrapper for an `AVAudioPlayerNode` (AudioKit's `AudioPlayer` adds a mixer and file handling we
    /// do not need). Connected in the engine's format; buffers must use `format`.
    final class BufferSource: Node {
        let connections: [Node] = []
        let player = AVAudioPlayerNode()
        var avAudioNode: AVAudioNode { player }
    }

    let source = BufferSource()
    let highpass: HighPassButterworthFilter
    let lowpass: LowPassButterworthFilter
    let lowpass2: LowPassButterworthFilter
    let strip: LayerStrip
    /// The format every cue buffer must have (the engine's format when the graph was built).
    let format: AVAudioFormat

    /// Sends (plan 4): the dry path 12 dB under the sends, so the film is heard through the room.
    static let dryGain: Float = dbToGain(-12)
    static let reverbSend: Float = 1.0
    static let delaySend: Float = 0.6
    static let highpassHz: Float = 220
    static let lowpassHz: Float = 2400
    /// Strip trim at "Footage audio" 0.5. Tuned with the offline render (decision A16) so the stem's mean
    /// level over a moment's hold is about -42 dBFS with a -26 dBFS RMS source (the music is about -25).
    static let baseTrim: Float = dbToGain(-11)

    private var playing = false
    private var stopAt: Double?
    private var endAt: Double?
    private var pending: Cue?
    private var panWalk = ParameterDrift.Channel(period: 53, phase: 1.3)
    private(set) var label: String?

    /// Fade position 0...1 (tests, logs).
    var level: Float { strip.fadeValue }
    var isPlaying: Bool { playing }

    init(format: AVAudioFormat = Settings.audioFormat) {
        self.format = format
        highpass = HighPassButterworthFilter(source, cutoffFrequency: Self.highpassHz)
        lowpass = LowPassButterworthFilter(highpass, cutoffFrequency: Self.lowpassHz)
        lowpass2 = LowPassButterworthFilter(lowpass, cutoffFrequency: Self.lowpassHz)
        strip = LayerStrip(source: source, filter: lowpass2, trim: Self.baseTrim, reverb: Self.reverbSend,
                           delay: Self.delaySend, pan: 0, dry: Self.dryGain)
        setFilters(running: false)
    }

    /// The filters are bypassed (no DSP) while nothing plays.
    private func setFilters(running: Bool) {
        for n in [highpass, lowpass, lowpass2] as [Node] { if running { n.start() } else { n.stop() } }
    }

    /// Start a segment. If another one is still audible it fades out over 0.4 s first.
    func begin(_ cue: Cue, now: Double) {
        guard cue.buffer.format.isEqual(format) || (cue.buffer.format.sampleRate == format.sampleRate
                                                    && cue.buffer.format.channelCount == format.channelCount) else {
            LMLog.audio.error("📼🔊 archive cue format mismatch \(cue.buffer.format.description, privacy: .public) vs \(self.format.description, privacy: .public)")
            return
        }
        if playing && strip.fadeValue > 0.001 {
            pending = cue
            strip.fade(to: 0, over: 0.4, now: now)
            stopAt = now + 0.45
            return
        }
        start(cue, now: now)
    }

    private func start(_ cue: Cue, now: Double) {
        let p = source.player
        if playing { p.stop() }
        setFilters(running: true)
        strip.trim = Self.baseTrim * cue.gain
        p.scheduleBuffer(cue.buffer, at: nil, options: [], completionHandler: nil)
        p.play()
        playing = true
        label = cue.label
        stopAt = nil
        let seconds = Double(cue.buffer.frameLength) / cue.buffer.format.sampleRate
        endAt = now + seconds
        strip.fade(to: 1, over: cue.fadeIn, now: now)
        LMLog.audio.info("📼🔊 archive audio begin \"\(cue.label, privacy: .public)\" \(String(format: "%.1f", seconds), privacy: .public)s gain=\(String(format: "%.1f", 20 * log10(max(cue.gain, 1e-6))), privacy: .public)dB fadeIn=\(String(format: "%.1f", cue.fadeIn), privacy: .public)s")
    }

    /// Fade out over `fade` seconds; the player stops once the fade is complete.
    func end(fade: Double, now: Double) {
        pending = nil
        guard playing else { return }
        strip.fade(to: 0, over: fade, now: now)
        stopAt = now + fade + 0.3
        LMLog.audio.info("📼🔊 archive audio end fade=\(String(format: "%.1f", fade), privacy: .public)s")
    }

    /// "Footage audio" changed while a segment plays.
    func setGain(_ gain: Float) {
        guard playing else { return }
        strip.trim = Self.baseTrim * gain
    }

    /// Stop at once (engine stop, conductor restart).
    func reset(now: Double) {
        pending = nil
        strip.fade(to: 0, over: 0, now: now)
        strip.tick(now: now)
        powerDown()
    }

    func powerDown() {
        if playing { source.player.stop() }
        playing = false
        stopAt = nil
        endAt = nil
        label = nil
        setFilters(running: false)
    }

    /// 10 Hz with the other strips.
    func modulate(t: Double) {
        if playing {
            // A buffer that ran out (it ends with its own 80 ms fade) is released like a finished fade.
            if let e = endAt, t >= e + 0.2, stopAt == nil { stopAt = t }
            if let s = stopAt, t >= s {
                if let next = pending {
                    pending = nil
                    start(next, now: t)
                } else {
                    strip.fade(to: 0, over: 0, now: t)
                    powerDown()
                }
            }
            setPanIfNeeded(t)
        }
        strip.tick(now: t)
    }

    private var lastPan: Float = 0
    private func setPanIfNeeded(_ t: Double) {
        let p = 0.4 * panWalk.value(at: t)
        if abs(p - lastPan) > 0.005 { strip.setPan(p, over: 0.12); lastPan = p }
    }
}
