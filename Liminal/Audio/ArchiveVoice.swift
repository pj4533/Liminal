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
        var activity: [Float] = []
        var chops: [LofiDialogueSampler.Hit] = []
    }

    /// Node wrapper for an `AVAudioPlayerNode` (AudioKit's `AudioPlayer` adds a mixer and file handling we
    /// do not need). Connected in the engine's format; buffers must use `format`.
    final class BufferSource: Node {
        let connections: [Node] = []
        let player = AVAudioPlayerNode()
        var avAudioNode: AVAudioNode { player }
    }

    let source = BufferSource()
    let chops = BufferSource()
    let bed: Fader
    let chopEcho: VariableDelay
    let chopWet: Mixer
    let chopOutput: Fader
    let highpass: HighPassButterworthFilter
    let lowpass: LowPassButterworthFilter
    let lowpass2: LowPassButterworthFilter
    private let spectralSweep: Phaser
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
        let movement: Contour
        let revealCenter: Double
        let revealHalfWidth: Double

        init(seed: Float, duration: Double) {
            var rng = MusicRNG(seed: UInt64(seed.bitPattern))
            let segments = max(2, Int(duration / 4))
            clarity = Contour(segments: segments + rng.int(0...2), range: 0.42...1, rng: &rng)
            room = Contour(segments: segments + rng.int(0...2), range: 0.95...1.85, rng: &rng)
            echo = Contour(segments: segments + rng.int(0...2), range: 0.95...1.95, rng: &rng)
            movement = Contour(segments: segments + rng.int(0...2), range: 0.12...0.86, rng: &rng)
            revealCenter = rng.range(0.24...0.79)
            revealHalfWidth = min(0.20, 1.75 / max(duration, 1))
        }
    }

    // The music bus receives only scheduled chops. The archive strip carries the film and its returns.
    private var beatLocked = false
    private var cueGain: Float = 1

    private var dropWindows: [Range<Double>] = []
    private var lastBedGain: Float = 1
    private var lastChopGain: Float = 0

    private func updateChopGain() {
        let gain: Float = beatLocked && playing ? min(cueGain, 1.15) * strip.fadeValue : 0
        guard abs(gain - lastChopGain) > 0.0001 else { return }
        ParamRamp.setGain(chopOutput, gain, over: 0.05)
        lastChopGain = gain
    }

    private func blendSoundtrack(at time: Double) {
        let underDrop = dropWindows.contains { $0.contains(time + 0.055) }
        let gain: Float = beatLocked ? (underDrop ? 1.31 : 1.76) : 1
        guard gain != lastBedGain else { return }
        ParamRamp.setGain(bed, gain, over: gain < lastBedGain ? 0.065 : 0.15)
        lastBedGain = gain
    }

    func setEchoTempo(_ beat: Double) {
        guard beat.isFinite, (0.35...1.5).contains(beat) else { return }
        let time = Float(0.75 * beat)
        guard let parameter = chopEcho.$time.parameter, abs(parameter.value - time) > 0.0001 else { return }
        ParamRamp.set(chopEcho.$time, time, over: 0.12)
    }

    func setBeatLocked(_ enabled: Bool) {
        if !enabled {
            chops.player.stop()
            dropWindows.removeAll()
        }
        beatLocked = enabled
        blendSoundtrack(at: cueStart)
        updateChopGain()
        if playing { setGain(cueGain) }
    }

    private var cueStart = 0.0
    private var cueDuration = 1.0
    private var cueMix: CueMix?
    private var activityEnvelope: [Float] = []
    private(set) var speechActivity: Float = 0

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
        bed = Fader(source)
        let chopDry = Fader(chops, gain: 0.72)
        chopEcho = VariableDelay(chops, time: 0.64, feedback: 0.33, maximumTime: 2, dryWetMix: 1)
        let darkEcho = Fader(LowPassButterworthFilter(chopEcho, cutoffFrequency: 2200), gain: 0.48)
        let room = ZitaReverb(Mixer(chops, darkEcho), predelay: 32, crossoverFrequency: 300,
                              lowReleaseTime: 1.0, midReleaseTime: 1.9, dampingFrequency: 2500, dryWetMix: 1)
        let darkRoom = Fader(LowPassButterworthFilter(room, cutoffFrequency: 2750), gain: 0.56)
        chopWet = Mixer(darkEcho, darkRoom)
        chopOutput = Fader(Mixer(chopDry, chopWet), gain: 0)
        highpass = HighPassButterworthFilter(bed, cutoffFrequency: Self.highpassHz)
        lowpass = LowPassButterworthFilter(highpass, cutoffFrequency: Self.lowpassHz)
        lowpass2 = LowPassButterworthFilter(lowpass, cutoffFrequency: Self.lowpassHz)
        spectralSweep = Phaser(lowpass2, notchMinimumFrequency: 200, notchMaximumFrequency: 1300,
                               notchWidth: 510, vibratoMode: 0, depth: 0.52, feedback: 0.12,
                               lfoBPM: 28, dryWetMix: 0.12)
        strip = LayerStrip(source: source, filter: spectralSweep, trim: Self.baseTrim, reverb: Self.reverbSend,
                           delay: Self.delaySend, pan: 0, dry: Self.dryGain)
        setFilters(running: false)
    }

    /// The filters are bypassed (no DSP) while nothing plays.
    private func setFilters(running: Bool) {
        for n in [highpass, lowpass, lowpass2, spectralSweep] as [Node] { if running { n.start() } else { n.stop() } }
    }

    /// Start a segment. If another one is still audible it fades out briefly first.
    func begin(_ cue: Cue, now: Double) {
        guard cue.buffer.format.isEqual(format) || (cue.buffer.format.sampleRate == format.sampleRate
                                                    && cue.buffer.format.channelCount == format.channelCount) else {
            LMLog.audio.error("📼🔊 archive cue format mismatch \(cue.buffer.format.description, privacy: .public) vs \(self.format.description, privacy: .public)")
            return
        }
        if playing && strip.fadeValue > 0.001 {
            pending = cue
            strip.fade(to: 0, over: 0.24, now: now)
            stopAt = min(stopAt ?? .greatestFiniteMagnitude, now + 0.27)
            return
        }
        start(cue, now: now)
    }

    private func start(_ cue: Cue, now: Double) {
        let p = source.player
        if playing { p.stop() }
        setFilters(running: true)
        cueGain = cue.gain
        strip.trim = Self.baseTrim * cueGain
        let seconds = Double(cue.buffer.frameLength) / cue.buffer.format.sampleRate
        cueStart = now
        cueDuration = max(1, seconds - 1)
        cueMix = CueMix(seed: cue.claritySeed, duration: cueDuration)
        activityEnvelope = cue.activity
        updateMix(progress: 0)
        p.scheduleBuffer(cue.buffer, at: nil, options: [], completionHandler: nil)
        p.play()
        scheduleChops(cue.chops, now: now)
        playing = true
        label = cue.label
        stopAt = nil
        endAt = now + seconds
        strip.fade(to: 1, over: cue.fadeIn, now: now)
        LMLog.audio.info("📼🔊 archive audio begin \"\(cue.label, privacy: .public)\" \(String(format: "%.1f", seconds), privacy: .public)s gain=\(String(format: "%.1f", 20 * log10(max(cue.gain, 1e-6))), privacy: .public)dB fadeIn=\(String(format: "%.1f", cue.fadeIn), privacy: .public)s")
    }

    private func scheduleChops(_ hits: [LofiDialogueSampler.Hit], now: Double) {
        let player = chops.player
        player.stop()
        let offline = player.engine?.isInManualRenderingMode == true
        let latency = offline ? 0 : player.outputPresentationLatency
        // All buffers use one player sample timeline. The live anchor is the same
        // host clock as the drum player; compensate for the route's presentation latency.
        let lead = max(0.06, latency + 0.025)
        let host = mach_absolute_time()
        let anchor = offline ? now : Double(DispatchTime.now().uptimeNanoseconds) / 1e9 + lead + latency
        let valid = beatLocked ? hits.filter { $0.time >= anchor } : []
        dropWindows = valid.map { hit in
            let start = now + (hit.time - anchor) + (offline ? 0 : lead)
            return start..<(start + Double(hit.buffer.frameLength) / format.sampleRate)
        }
        blendSoundtrack(at: now)
        guard !valid.isEmpty else { return }
        for hit in valid {
            let frame = AVAudioFramePosition(((hit.time - anchor) * format.sampleRate).rounded())
            player.scheduleBuffer(hit.buffer, at: AVAudioTime(sampleTime: frame, atRate: format.sampleRate))
        }
        if offline { player.play() }
        else { player.play(at: AVAudioTime(hostTime: host + AVAudioTime.hostTime(forSeconds: lead))) }
        LMLog.audio.info("Lo-Fi film sampler scheduled \(valid.count) hits for this picture")
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
        cueGain = gain
        strip.trim = Self.baseTrim * cueGain
    }

    /// Stop at once (engine stop, conductor restart).
    func reset(now: Double) {
        pending = nil
        strip.fade(to: 0, over: 0, now: now)
        strip.tick(now: now)
        powerDown()
    }

    func powerDown() {
        if playing {
            source.player.stop()
            chops.player.stop()
        }
        dropWindows.removeAll()
        playing = false
        updateChopGain()
        stopAt = nil
        endAt = nil
        label = nil
        speechActivity = 0
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
                blendSoundtrack(at: t)
                setPanIfNeeded(t)
            }
        }
        strip.tick(now: t)
        updateChopGain()
        let window = Int(max(0, t - cueStart) / ArchiveAudioMath.activityWindow)
        speechActivity = playing && activityEnvelope.indices.contains(window) ? presence * activityEnvelope[window] : 0
    }

    private func updateMix(progress: Double) {
        guard let cueMix else { return }
        let value = cueMix.clarity.value(at: progress)
        // Keep both effects present even at full clarity. The consonants come forward
        // mainly through the wider filter, with only a small dip in the sends.
        let wetScale: Float = (beatLocked ? 1.18 : 1) * (1 - 0.18 * value)
        let reverb = cueMix.room.value(at: progress) * wetScale
        let echo = cueMix.echo.value(at: progress) * wetScale
        // One short clarity swell per picture, with a smooth rise and fall.
        // Even at its crest, the original film stays below the musical sample.
        let u = Float(max(0, 1 - abs(progress - cueMix.revealCenter) / cueMix.revealHalfWidth))
        let reveal = u * u * (3 - 2 * u)
        let cutoff = beatLocked ? 2100 + 1100 * reveal : Self.lowpassHz + 1650 * value
        let motion = cueMix.movement.value(at: progress)
        ParamRamp.set(spectralSweep.$notchMaximumFrequency, 900 + 970 * motion, over: 0.13)
        ParamRamp.set(spectralSweep.$dryWetMix, beatLocked ? 0.36 + 0.22 * motion : 0.05 + 0.49 * motion * (1 - 0.55 * value), over: 0.13)
        ParamRamp.set(highpass.$cutoffFrequency, beatLocked ? 290 - 85 * reveal : Self.highpassHz - 110 * value, over: 0.12)
        ParamRamp.set(lowpass.$cutoffFrequency, cutoff, over: 0.12)
        ParamRamp.set(lowpass2.$cutoffFrequency, cutoff, over: 0.12)
        if let dry = strip.dryGain {
            let direct = beatLocked ? 0.27 + 0.33 * reveal : Self.dryGain + (Self.clearDryGain - Self.dryGain) * value
            ParamRamp.setGain(dry, direct, over: 0.12)
        }
        strip.setSends(reverb: reverb, delay: echo, over: 0.12)
    }

    private var lastPan: Float = 0
    private func setPanIfNeeded(_ t: Double) {
        let p = 0.4 * panWalk.value(at: t)
        if abs(p - lastPan) > 0.005 { strip.setPan(p, over: 0.12); lastPan = p }
    }
}
