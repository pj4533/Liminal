import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import AVFoundation
import Foundation
import OSLog

/// A static mix strip for normalised archive audio. During some cues, the direct
/// sound and speech band open up briefly, then settle back into the shared reverb and tape delay.
nonisolated final class ArchiveVoice {

    /// A decoded segment ready to play, posted with `MusicControl.archiveBegin`.
    struct Cue {
        let buffer: AVAudioPCMBuffer
        /// Linear gain on top of `baseTrim` ("Footage audio": 1 at the default 0.5, 2 at the top).
        let gain: Float
        let fadeIn: Double
        let label: String
        /// Seeded by the footage piece so successive cues vary in how clearly they emerge.
        var claritySeed: Float = 0.75
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

    static let dryGain: Float = dbToGain(-12)
    static let clearDryGain: Float = dbToGain(-1)
    static let reverbSend: Float = 1.3
    static let delaySend: Float = 1.3
    static let highpassHz: Float = 220
    static let lowpassHz: Float = 2400
    /// Strip trim at the default Footage audio setting.
    static let baseTrim: Float = dbToGain(-10.5)

    /// Independently seeded contours with irregular spacing. Smoothstep reaches each
    /// target with zero slope, including when two successive targets reverse direction.
    private struct Contour {
        private let points: [(time: Double, value: Float)]

        init(segments: Int, range: ClosedRange<Float>, rng: inout MusicRNG) {
            points = (0...segments).map { index in
                let offset = (index == 0 || index == segments) ? 0 : rng.range(-0.38...0.38)
                return ((Double(index) + offset) / Double(segments), rng.rangeF(range))
            }
        }

        func value(at progress: Double) -> Float {
            let t = min(1, max(0, progress))
            guard let next = points.indices.dropFirst().first(where: { t <= points[$0].time }) else {
                return points[points.count - 1].value
            }
            let a = points[next - 1], b = points[next]
            let u = Float((t - a.time) / (b.time - a.time))
            return a.value + (b.value - a.value) * (u * u * (3 - 2 * u))
        }
    }

    private struct CueMix {
        let clarity: Contour
        let room: Contour
        let echo: Contour

        init(seed: Float, duration: Double) {
            var rng = MusicRNG(seed: UInt64(seed.bitPattern))
            let segments = max(2, Int(duration / 4))
            clarity = Contour(segments: segments + rng.int(0...2), range: 0.42...1, rng: &rng)
            room = Contour(segments: segments + rng.int(0...2), range: 0.95...1.85, rng: &rng)
            echo = Contour(segments: segments + rng.int(0...2), range: 0.95...1.95, rng: &rng)
        }
    }

    private var cueStart = 0.0
    private var cueDuration = 1.0
    private var cueMix: CueMix?

    private var playing = false
    private var stopAt: Double?
    private var endAt: Double?
    private var pending: Cue?
    private var panWalk = ParameterDrift.Channel(period: 53, phase: 1.3)
    private(set) var label: String?

    /// Fade position 0...1 (tests, logs).
    var level: Float { strip.fadeValue }
    var presence: Float { playing ? level * min(1, strip.trim / Self.baseTrim) : 0 }
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
        let seconds = Double(cue.buffer.frameLength) / cue.buffer.format.sampleRate
        cueStart = now
        cueDuration = max(1, seconds - 1)
        cueMix = CueMix(seed: cue.claritySeed, duration: cueDuration)
        updateMix(progress: 0)
        p.scheduleBuffer(cue.buffer, at: nil, options: [], completionHandler: nil)
        p.play()
        playing = true
        label = cue.label
        stopAt = nil
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
            if playing {
                updateMix(progress: (t - cueStart) / cueDuration)
                setPanIfNeeded(t)
            }
        }
        strip.tick(now: t)
    }

    private func updateMix(progress: Double) {
        guard let cueMix else { return }
        let value = cueMix.clarity.value(at: progress)
        // Keep both effects present even at full clarity. The consonants come forward
        // mainly through the wider filter, with only a small dip in the sends.
        let wetScale = 1 - 0.18 * value
        let reverb = cueMix.room.value(at: progress) * wetScale
        let echo = cueMix.echo.value(at: progress) * wetScale
        let cutoff = Self.lowpassHz + 2100 * value
        ParamRamp.set(highpass.$cutoffFrequency, Self.highpassHz - 110 * value, over: 0.12)
        ParamRamp.set(lowpass.$cutoffFrequency, cutoff, over: 0.12)
        ParamRamp.set(lowpass2.$cutoffFrequency, cutoff, over: 0.12)
        if let dry = strip.dryGain {
            ParamRamp.setGain(dry, Self.dryGain + (Self.clearDryGain - Self.dryGain) * value, over: 0.12)
        }
        strip.setSends(reverb: reverb, delay: echo, over: 0.12)
    }

    private var lastPan: Float = 0
    private func setPanIfNeeded(_ t: Double) {
        let p = 0.4 * panWalk.value(at: t)
        if abs(p - lastPan) > 0.005 { strip.setPan(p, over: 0.12); lastPan = p }
    }
}
