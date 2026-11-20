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
        /// Legacy sampler hits (absolute transport seconds), converted to the same scheduled-chop list as plans.
        var chops: [LofiDialogueSampler.Hit] = []
        /// The footage service's cue token. Plans with this token belong to this cue. Nil means a new one.
        var token: Int? = nil
        /// The Lo-Fi transport when the bed was posted: places the theme return's bed dip without any
        /// dialogue plan (a film with no speech still dips under the hook).
        var transport: LofiTransportInfo? = nil
    }

    /// A dialogue performance for one cue (plan 3.6, 6.3), posted with `MusicControl.archiveChops`.
    /// Chop start times are transport seconds: host uptime live, conductor seconds in manual rendering.
    struct ChopPlan: @unchecked Sendable {
        let token: Int
        /// 0 for the acoustic plan; a higher revision replaces stored chops from `replaceFrom`.
        let revision: Int
        let replaceFrom: Double
        let chops: [DialogueChop]
        /// The chops open drop windows in the film bed (the existing ducking).
        let bedDuck: Bool

        init(token: Int, revision: Int, replaceFrom: Double = -.infinity, chops: [DialogueChop], bedDuck: Bool = true) {
            self.token = token
            self.revision = revision
            self.replaceFrom = replaceFrom
            self.chops = chops
            self.bedDuck = bedDuck
        }
    }

    /// One statement on the persistent chop timeline.
    private struct ScheduledChop {
        let token: Int
        /// Transport seconds.
        let start: Double
        let buffer: AVAudioPCMBuffer
        let duck: Bool
        /// Texture fills never duck the music or the bed, whatever their length (plan 8.5).
        var texture = false
        var end: Double { start + Double(buffer.frameLength) / buffer.format.sampleRate }
        /// A featured line: at least `featuredSeconds` long and not a texture fill.
        var featured: Bool { !texture && Double(buffer.frameLength) / buffer.format.sampleRate >= ArchiveVoice.featuredSeconds }
    }

    /// Sample 0 of the chop player: transport seconds and conductor seconds.
    private struct ChopTimeline {
        let anchor: Double
        let conductorAnchor: Double
        /// Seconds a chop must still be ahead of `now` to be queued (presentation latency plus render lead).
        let margin: Double
    }

    /// Chops are queued this far ahead of their start on every modulation tick.
    static let chopQueueAhead = 1.0
    /// The chop echo and room may ring this long after the cue's end before the chop fader closes.
    static let chopTailSeconds = 2.0

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
    /// The dry chop path: mono, centred, 0.72 (capture tap `dialogue-dry`).
    let chopDry: Fader
    let chopEcho: VariableDelay
    /// Echo and room returns, each band-limited (plan 8.5).
    let chopEchoReturn: Fader
    let chopRoom: ZitaReverb
    let chopRoomReturn: Fader
    let chopWet: Mixer
    let chopOutput: Fader
    let highpass: HighPassButterworthFilter
    let lowpass: LowPassButterworthFilter
    let lowpass2: LowPassButterworthFilter
    /// Dip in the dialogue slot, kept in the graph but bypassed in both modes: the Lo-Fi bed keeps its
    /// baseline chain (user direction, 19 November 2026).
    let presenceDip: PeakingParametricEqualizerFilter
    let spectralSweep: Phaser
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

    /// Lo-Fi film bed. The user's direction of 19 November 2026 (docs/plans/mpc-chopping.md) keeps the
    /// baseline effected bed: mostly wet, dark band-limiting (HPF about 205-290 Hz, two low-pass stages at
    /// 2.1-3.2 kHz), the beat-locked phaser at 0.36-0.58 wet and sends at 1.18 times the contours. Plan 8.6's
    /// clarity pass (drier direct sound, smaller sends, an opened low-pass) is not applied.
    enum LofiBed {
        /// Context gain outside and under a chop that ducks the bed (chops may duck the bed; the bed keys nothing).
        /// Mix calibration raised both by 2.5 dB (1.76 and 1.31 at the baseline): the bed stays at least
        /// 10 dB under the music in gaps on every matrix case while its audibility index rises.
        static let contextGain: Float = 2.35
        static let underChopGain: Float = 1.749
        /// Under the theme return's opening bar the bed steps down so the hook is heard over it (C-B6);
        /// the music stays on top of the bed, the bed still keys nothing. Gain relative to `contextGain`.
        static let returnDipGain: Float = 0.126
        /// Beats of the return's first bar the dip covers (the revealed notes sound by beat 3.5). It starts
        /// `returnDipLeadBeats` before the downbeat: the bed is mostly reverb and tape echo, and its tail
        /// needs that long to fall away under the hook.
        static let returnDipBeats = 4.0
        static let returnDipLeadBeats = 3.0
        static let returnDipDown = 0.3
        static let returnDipUp = 0.4
        static let duckDown = 0.065
        static let duckUp = 0.15
    }

    /// Dialogue chop returns (plan 8.5). Levels are relative to the 0.72 dry path.
    enum ChopBus {
        /// Tuck pass (19 November 2026): 8 dB under the calibrated 0.72, so the chops sit with the
        /// melodic stems instead of 9 to 15 dB over them in 250 Hz-4 kHz.
        static let dryGain: Float = 0.28
        static let echoBeats: Float = 0.75
        /// Heavier chop effects (user direction of 19 November 2026, "heavier... echo more, more repeats,
        /// more reverb"): feedback 0.55 with the return 5 dB under dry (0.42 at -11 dB after calibration,
        /// 0.25 at -16 dB before), and a long, clearly wet room (2.4 s at 0.6; 1.5 s at 0.32 before).
        static let echoFeedback: Float = 0.55
        static let echoBand: (low: Float, high: Float) = (400, 2500)
        static let echoUnderDryDB: Float = -5
        static let roomBand: (low: Float, high: Float) = (300, 3000)
        static let roomMidRelease: Float = 2.4
        static let roomLowRelease: Float = 1.2
        static let roomDamping: Float = 2200
        /// Return gain that puts the room's energy about 14 dB under the dry path for a 1 kHz line
        /// (0.2 measured 18.5 dB under with the 0.9 s room; 0.17 was the baseline).
        static let roomReturnGain: Float = 0.38
    }

    /// Ducking of the Lo-Fi music buses under a featured chop (plan 8.5). Drums and bass are not ducked.
    enum MusicDuck {
        /// Barely there (-3, -4, -5 after calibration; -2, -3, -4 in plan 8.5). Ducking the music under a
        /// vocal is how a mix puts the vocal on top; the user's direction after the calibrated clip
        /// (19 November 2026: the chops "way too loud... need to fit into the mids and melody") is the
        /// opposite, so the chops are tucked by level, EQ and shared space instead.
        static let leadDB: Float = -1
        static let midsDB: Float = -1
        static let spaceDB: Float = -1.5
        static let attack = 0.03
        static let lead = 0.02
        static let release = 0.3
    }

    /// Chops at least this long are featured lines: they duck the bed and the music.
    static let featuredSeconds = 0.5

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

    /// Featured queued chops in conductor seconds: they duck the bed (when the plan asks) and the music.
    private var dropWindows: [Range<Double>] = []
    private var duckWindows: [Range<Double>] = []
    private var musicDuck: (lead: Fader, mids: Fader, space: Fader)?
    private var musicDucked = false
    private var lastBedGain: Float = 1
    /// Beat seconds of the Lo-Fi transport (from `setEchoTempo`) and the theme returns it implies.
    private var chopBeat: Double?
    /// Theme return downbeats (transport seconds). `precise` ones come from the transport or a plan's
    /// events; the others are estimated from the audible phrase callback and yield to a precise one.
    private struct ReturnMark { let start: Double; let precise: Bool }
    private var returnStarts: [ReturnMark] = []
    private var lastChopGain: Float = 0
    /// Not yet queued chops, sorted by start, and the ones already on the player (pruned).
    private var storedChops: [ScheduledChop] = []
    private var queuedChops: [ScheduledChop] = []
    private var timeline: ChopTimeline?
    /// The newest cue token whose bed has begun; plans for older tokens are stale. Only chops with
    /// this token are queued (and duck anything): a plan for a later cue waits, inert, for its bed.
    private var currentCueToken: Int?
    /// Cues the footage service abandoned after their analysis started (`archiveChopsCancel`). A late
    /// plan for one of them is ignored. Tokens below the current cue are pruned (already stale).
    private var cancelledTokens: Set<Int> = []
    /// Highest plan revision stored per cue token.
    private var planRevisions: [Int: Int] = [:]
    /// Conductor seconds after which the chop fader closes (the cue's end plus the tail).
    private var chopsUntil = -Double.infinity
    private var lastTime = 0.0

    /// The chop fader follows the Footage audio setting and beat lock, with its own 50 ms ramp.
    /// It no longer follows the bed's fade-in (plan 6.3).
    private func updateChopGain(at t: Double) {
        let gain: Float = beatLocked && t < chopsUntil ? min(cueGain, 1.15) : 0
        guard abs(gain - lastChopGain) > 0.0001 else { return }
        ParamRamp.setGain(chopOutput, gain, over: 0.05)
        lastChopGain = gain
    }

    /// Diagnostics and tests: chops stored but not yet on the player, and those queued.
    var chopCounts: (stored: Int, queued: Int) { (storedChops.count, queuedChops.count) }

    /// The bed's context gain in Lo-Fi: 1.76, and 1.31 under a featured chop that ducks the bed (65 ms
    /// down, 150 ms up, the baseline values); always 1 in Ambient. Called on every conductor step in Lo-Fi, so the
    /// down ramp starts within half a step of 40 ms before the chop.
    private func blendSoundtrack(at time: Double) {
        let ahead = time + 0.01 + LofiBed.duckDown
        let underDrop = dropWindows.contains { ahead >= $0.lowerBound && time + 0.01 < $0.upperBound }
        let inReturn = beatLocked && inReturnDip(at: time)
        var gain: Float = beatLocked ? (underDrop ? LofiBed.underChopGain : LofiBed.contextGain) : 1
        if inReturn { gain = min(gain, LofiBed.contextGain * LofiBed.returnDipGain) }
        guard gain != lastBedGain else { return }
        let returning = inReturn || lastBedGain < LofiBed.underChopGain * 0.99
        let over = gain < lastBedGain ? (returning ? LofiBed.returnDipDown : LofiBed.duckDown)
                                      : (returning ? LofiBed.returnDipUp : LofiBed.duckUp)
        ParamRamp.setGain(bed, gain, over: over)
        lastBedGain = gain
    }

    /// Whether conductor time `t` lies in the opening bar of a theme return, from the stored return
    /// starts (transport seconds) on the chop timeline. The dip starts `returnDipLeadBeats` early.
    private func inReturnDip(at t: Double) -> Bool {
        guard let timeline, let beat = chopBeat, !returnStarts.isEmpty else { return false }
        let now = timeline.anchor + (t + 0.01 - timeline.conductorAnchor)
        let length = LofiBed.returnDipBeats * beat, lead = LofiBed.returnDipLeadBeats * beat
        return returnStarts.contains { now + lead >= $0.start && now < $0.start + length }
    }

    /// Adds one return downbeat. Duplicates within a quarter second (precise) or 0.75 s (an estimate)
    /// merge; a precise time replaces an estimate. The dip needs the chop timeline's conductor-to-transport
    /// mapping even when no chop has been queued (a film with no speech), so the next modulation tick
    /// starts it: only that tick's time is exact in manual rendering (a control's is a step old).
    private func addReturn(_ start: Double, precise: Bool) {
        guard start.isFinite else { return }
        if let i = returnStarts.firstIndex(where: { abs($0.start - start) < (precise && $0.precise ? 0.25 : 0.75) }) {
            if precise && !returnStarts[i].precise { returnStarts[i] = ReturnMark(start: start, precise: true) }
            return
        }
        returnStarts.append(ReturnMark(start: start, precise: precise))
        let horizon = (returnStarts.map(\.start).max() ?? 0) - 600
        returnStarts.removeAll { $0.start < horizon }
    }

    /// Return downbeats of the take the transport describes and, when it is already queued, the next
    /// one: the returns are the phrases `LofiScore.section(at:)` names `.returnTheme`.
    private func noteReturnStarts(_ info: LofiTransportInfo) {
        let phrases = LofiDrumTake.phraseCount
        let phraseBeats = Int(LofiClock.beats)
        for k in 0..<phrases where LofiScore.section(at: info.phraseAtTakeStart + k) == .returnTheme {
            addReturn(info.origin + Double(k * phraseBeats) * info.beatDuration, precise: true)
        }
        guard let next = info.nextBeatDuration else { return }
        let nextOrigin = info.origin + Double(phrases * phraseBeats) * info.beatDuration
        for k in 0..<phrases where LofiScore.section(at: info.phraseAtTakeStart + phrases + k) == .returnTheme {
            addReturn(nextOrigin + Double(k * phraseBeats) * next, precise: true)
        }
    }

    /// The Lo-Fi phrase `index` just became audible (`LofiPlayback.onPhrase` through the conductor).
    /// When the next phrase is a theme return, its downbeat is about one phrase from now. An estimate:
    /// the callback is polled, so it may be a few tens of milliseconds late; the dip's 3-beat lead and
    /// 0.3 s ramp absorb that. A transport or plan time replaces it.
    func notePhrase(_ index: Int, beatDuration: Double, now: Double) {
        guard beatLocked, beatDuration.isFinite, beatDuration > 0,
              LofiScore.section(at: index + 1) == .returnTheme else { return }
        addReturn(transportNow(now) + LofiClock.beats * beatDuration, precise: false)
    }

    /// Return starts (transport seconds) implied by a plan's events: every event knows its block (the
    /// global phrase) and sixteenth slot, and the return is the fourth phrase of each 16-bar take
    /// (`LofiScore`). Events of the take's first three blocks place it before it begins.
    /// Fallback beside the transport and phrase sources above (kept for the offline capture, whose
    /// cues carry no transport).
    private func noteReturnStarts(_ events: [DialogueEvent]) {
        guard let beat = chopBeat else { return }
        for event in events where event.block >= 0 {
            let position = event.block % 4
            let blockStart = event.accentTime - Double(event.slot) * beat / 4
            addReturn(blockStart + Double(3 - position) * 16 * beat, precise: true)
        }
    }

    /// The Lo-Fi lead, mids and space faders this voice ducks under featured chops. Call once after
    /// both objects exist and before the conductor runs (the graph and the capture harness).
    func attachMusicDuck(lead: Fader, mids: Fader, space: Fader) {
        musicDuck = (lead, mids, space)
        musicDucked = false
        for f in [lead, mids, space] { ParamRamp.setGain(f, 1, over: 0.02) }
    }

    /// Every conductor step in Lo-Fi (20 ms): the music duck and the bed's context gain follow the
    /// windows of queued featured chops. The attack starts 20 ms before the chop (within half a step).
    func updateDucks(at t: Double) {
        guard beatLocked else { return }
        let probe = t + 0.01
        let ducked = duckWindows.contains { probe + MusicDuck.lead >= $0.lowerBound && probe < $0.upperBound }
        if ducked != musicDucked, let duck = musicDuck {
            let over = ducked ? MusicDuck.attack : MusicDuck.release
            ParamRamp.setGain(duck.lead, ducked ? dbToGain(MusicDuck.leadDB) : 1, over: over)
            ParamRamp.setGain(duck.mids, ducked ? dbToGain(MusicDuck.midsDB) : 1, over: over)
            ParamRamp.setGain(duck.space, ducked ? dbToGain(MusicDuck.spaceDB) : 1, over: over)
            musicDucked = ducked
        }
        if playing { blendSoundtrack(at: t) }
    }

    /// Beat lock off, reset and power down: the music faders return to unity.
    private func releaseMusicDuck() {
        duckWindows.removeAll()
        musicDucked = false
        guard let duck = musicDuck else { return }
        for f in [duck.lead, duck.mids, duck.space] { ParamRamp.setGain(f, 1, over: 0.05) }
    }

    /// Tests: whether the music faders are currently ducked.
    var isMusicDucked: Bool { musicDucked }

    func setEchoTempo(_ beat: Double) {
        guard beat.isFinite, (0.35...1.5).contains(beat) else { return }
        chopBeat = beat
        let time = Float(0.75 * beat)
        guard let parameter = chopEcho.$time.parameter, abs(parameter.value - time) > 0.0001 else { return }
        ParamRamp.set(chopEcho.$time, time, over: 0.12)
    }

    func setBeatLocked(_ enabled: Bool) {
        if !enabled { stopChopTimeline() }
        beatLocked = enabled
        blendSoundtrack(at: cueStart)
        updateChopGain(at: lastTime)
        if playing {
            setGain(cueGain)
            setFilters(running: true)
        }
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
    var presence: Float { playing ? level * min(1, cueGain) : 0 }
    var isPlaying: Bool { playing }

    init(format: AVAudioFormat = Settings.audioFormat) {
        self.format = format
        bed = Fader(source)
        chopDry = Fader(chops, gain: ChopBus.dryGain)
        chopEcho = VariableDelay(chops, time: 0.64, feedback: ChopBus.echoFeedback, maximumTime: 2, dryWetMix: 1)
        // Echo return: one 0.75-beat slap band-passed to 400 Hz-3 kHz, about 16 dB under the dry line.
        let echoBand = LowPassButterworthFilter(HighPassButterworthFilter(chopEcho, cutoffFrequency: ChopBus.echoBand.low),
                                                cutoffFrequency: ChopBus.echoBand.high)
        chopEchoReturn = Fader(echoBand, gain: ChopBus.dryGain * dbToGain(ChopBus.echoUnderDryDB))
        // A small, dark room (mid RT about 0.9 s) returned through 300 Hz-4 kHz, about 20 dB under dry.
        chopRoom = ZitaReverb(Mixer(chops, chopEchoReturn), predelay: 18, crossoverFrequency: 300,
                              lowReleaseTime: ChopBus.roomLowRelease, midReleaseTime: ChopBus.roomMidRelease,
                              dampingFrequency: ChopBus.roomDamping, dryWetMix: 1)
        let roomBand = LowPassButterworthFilter(HighPassButterworthFilter(chopRoom, cutoffFrequency: ChopBus.roomBand.low),
                                                cutoffFrequency: ChopBus.roomBand.high)
        chopRoomReturn = Fader(roomBand, gain: ChopBus.roomReturnGain)
        chopWet = Mixer(chopEchoReturn, chopRoomReturn)
        chopOutput = Fader(Mixer(chopDry, chopWet), gain: 0)
        highpass = HighPassButterworthFilter(bed, cutoffFrequency: Self.highpassHz)
        lowpass = LowPassButterworthFilter(highpass, cutoffFrequency: Self.lowpassHz)
        lowpass2 = LowPassButterworthFilter(lowpass, cutoffFrequency: Self.lowpassHz)
        presenceDip = PeakingParametricEqualizerFilter(lowpass2, centerFrequency: 2200, gain: 1, q: 0.7)
        spectralSweep = Phaser(presenceDip, notchMinimumFrequency: 200, notchMaximumFrequency: 1300,
                               notchWidth: 510, vibratoMode: 0, depth: 0.52, feedback: 0.12,
                               lfoBPM: 28, dryWetMix: 0.12)
        strip = LayerStrip(source: source, filter: spectralSweep, trim: Self.baseTrim, reverb: Self.reverbSend,
                           delay: Self.delaySend, pan: 0, dry: Self.dryGain)
        setFilters(running: false)
        // Offline captures separate the dry chops and the filtered bed (before its strip).
        LofiCaptureHooks.tap("dialogue-dry", chopDry.avAudioNode)
        LofiCaptureHooks.tap("bed-post", spectralSweep.avAudioNode)
    }

    /// The filters are bypassed (no DSP) while nothing plays. The presence dip never runs.
    private func setFilters(running: Bool) {
        for n in [highpass, lowpass, lowpass2, spectralSweep] as [Node] { if running { n.start() } else { n.stop() } }
        presenceDip.stop()
    }

    /// Start a segment. If another one is still audible it fades out briefly first.
    func begin(_ cue: Cue, now: Double) {
        guard cue.buffer.format.isEqual(format) || (cue.buffer.format.sampleRate == format.sampleRate
                                                    && cue.buffer.format.channelCount == format.channelCount) else {
            LMLog.audio.error("📼🔊 archive cue format mismatch \(cue.buffer.format.description, privacy: .public) vs \(self.format.description, privacy: .public)")
            return
        }
        // The cue owns the chop timeline from the moment its bed is posted, also while the old bed
        // fades out for 0.27 s: its chops in that crossfade still play.
        var cue = cue
        cue.token = adoptChopToken(cue.token)
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
        strip.trim = trim(for: cueGain)
        let seconds = Double(cue.buffer.frameLength) / cue.buffer.format.sampleRate
        cueStart = now
        cueDuration = max(1, seconds - 1)
        cueMix = CueMix(seed: cue.claritySeed, duration: cueDuration)
        activityEnvelope = cue.activity
        updateMix(progress: 0)
        p.scheduleBuffer(cue.buffer, at: nil, options: [], completionHandler: nil)
        p.play()
        playing = true
        beginChops(for: cue, now: now, seconds: seconds)
        label = cue.label
        stopAt = nil
        endAt = now + seconds
        strip.fade(to: 1, over: cue.fadeIn, now: now)
        LMLog.audio.info("📼🔊 archive audio begin \"\(cue.label, privacy: .public)\" \(String(format: "%.1f", seconds), privacy: .public)s gain=\(String(format: "%.1f", 20 * log10(max(cue.gain, 1e-6))), privacy: .public)dB fadeIn=\(String(format: "%.1f", cue.fadeIn), privacy: .public)s")
    }

    // MARK: Chop timeline (plan 6.3)

    /// A new bed adopts its token: older cues' unqueued chops are dropped (the old bed is fading out),
    /// and legacy sampler hits join the same scheduled list as plan chops.
    /// Makes `requested` (or a fresh token) the current cue's: only its chops are queued from now on,
    /// and older cues' unqueued chops, revisions and cancellations go.
    private func adoptChopToken(_ requested: Int?) -> Int {
        let token = requested ?? (max(currentCueToken ?? 0, planRevisions.keys.max() ?? 0) + 1)
        currentCueToken = token
        storedChops.removeAll { $0.token < token }
        planRevisions = planRevisions.filter { $0.key >= token }
        cancelledTokens = cancelledTokens.filter { $0 >= token }
        return token
    }

    private func beginChops(for cue: Cue, now: Double, seconds: Double) {
        lastTime = now
        let token = adoptChopToken(cue.token)
        chopsUntil = now + seconds + Self.chopTailSeconds
        if beatLocked, let info = cue.transport { noteReturnStarts(info) }
        if !cue.chops.isEmpty, beatLocked, !cancelledTokens.contains(token) {
            planRevisions[token] = max(planRevisions[token] ?? 0, 0)
            store(cue.chops.map { ScheduledChop(token: token, start: $0.time, buffer: $0.buffer, duck: true) })
            LMLog.audio.info("Lo-Fi film sampler stored \(cue.chops.count) hits for this picture")
        }
        blendSoundtrack(at: now)
        updateChopGain(at: now)
    }

    /// Stores a plan's chops. Stale tokens and revisions are ignored; a higher revision replaces
    /// stored, not yet queued chops at or after `replaceFrom`. Queued audio is never moved.
    func perform(_ plan: ChopPlan, now: Double) {
        lastTime = now
        guard beatLocked else { return }
        if let current = currentCueToken, plan.token < current {
            LMLog.audio.info("Lo-Fi dialogue plan for stale cue \(plan.token) ignored")
            return
        }
        if cancelledTokens.contains(plan.token) {
            LMLog.audio.info("Lo-Fi dialogue plan for cancelled cue \(plan.token) ignored")
            return
        }
        if let stored = planRevisions[plan.token], plan.revision <= stored { return }
        planRevisions[plan.token] = plan.revision
        storedChops.removeAll { $0.token == plan.token && $0.start >= plan.replaceFrom }
        let queuedEnd = queuedChops.filter { $0.token == plan.token }.map(\.end).max() ?? -.infinity
        let incoming = plan.chops.map {
            ScheduledChop(token: plan.token, start: $0.event.startTime, buffer: $0.buffer, duck: plan.bedDuck,
                          texture: $0.event.role == .texture)
        }.filter { $0.start >= plan.replaceFrom && $0.start >= queuedEnd }
        store(incoming)
        noteReturnStarts(plan.chops.map(\.event))
        LMLog.audio.info("Lo-Fi dialogue plan cue=\(plan.token) revision=\(plan.revision) stored \(incoming.count) chops")
        blendSoundtrack(at: now)
        updateChopGain(at: now)
    }

    /// The footage service abandoned cue `token` (its bed never began, or footage stopped): its stored
    /// chops and revisions go, and any later plan for it is ignored. Queued audio is never moved.
    func cancelChops(token: Int) {
        if let current = currentCueToken, token < current { return }
        cancelledTokens.insert(token)
        let before = storedChops.count
        storedChops.removeAll { $0.token == token }
        planRevisions[token] = nil
        LMLog.audio.info("Lo-Fi dialogue cue=\(token) cancelled, \(before - self.storedChops.count) stored chops dropped")
    }

    private func store(_ chops: [ScheduledChop]) {
        guard !chops.isEmpty else { return }
        storedChops += chops
        storedChops.sort { $0.start < $1.start }
    }

    private var isOffline: Bool { chops.player.engine?.isInManualRenderingMode == true }

    /// Transport seconds now: host uptime live, conductor seconds in manual rendering.
    private func transportNow(_ t: Double) -> Double {
        isOffline ? t : Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }

    /// Starts the persistent chop player once per beat-locked session. The live anchor is the same
    /// host clock as the drum player, compensated for the route's presentation latency (read once).
    private func startChopTimeline(at t: Double) -> ChopTimeline {
        if let timeline { return timeline }
        let player = chops.player
        let made: ChopTimeline
        if isOffline {
            made = ChopTimeline(anchor: t, conductorAnchor: t, margin: 0)
            player.play()
        } else {
            let latency = player.outputPresentationLatency
            let lead = max(0.06, latency + 0.025)
            let host = mach_absolute_time()
            let anchor = Double(DispatchTime.now().uptimeNanoseconds) / 1e9 + lead + latency
            made = ChopTimeline(anchor: anchor, conductorAnchor: t + lead, margin: latency + 0.03)
            player.play(at: AVAudioTime(hostTime: host + AVAudioTime.hostTime(forSeconds: lead)))
        }
        timeline = made
        return made
    }

    /// Keeps `cancelledTokens`: a late plan for an abandoned cue must not come back after a restart.
    private func stopChopTimeline() {
        chops.player.stop()
        timeline = nil
        storedChops.removeAll()
        queuedChops.removeAll()
        planRevisions.removeAll()
        dropWindows.removeAll()
        returnStarts.removeAll()
        releaseMusicDuck()
    }

    /// Queues every stored chop that starts within the next second at its sample time on the
    /// persistent timeline; chops already in the past are dropped. Only the modulation tick calls
    /// this: its time is exact in manual rendering (a control's `now` is one conductor step old),
    /// and plans always arrive at least 0.3 s ahead, more than the 0.1 s tick.
    private func queueDueChops(at t: Double) {
        let now = transportNow(t)
        queuedChops.removeAll { $0.end < now - 1 }
        dropWindows.removeAll { $0.upperBound < t - 1 }
        duckWindows.removeAll { $0.upperBound < t - 1 }
        // Only the begun cue's chops are due. A later cue's plan stays stored, inert (no audio, no duck),
        // until its bed begins and `beginChops` adopts its token; it never blocks the current cue's chops.
        let horizon = now + Self.chopQueueAhead
        if beatLocked, timeline == nil, !returnStarts.isEmpty { _ = startChopTimeline(at: t) }
        guard beatLocked, let current = currentCueToken,
              storedChops.contains(where: { $0.token == current && $0.start < horizon }) else { return }
        let timeline = startChopTimeline(at: t)
        let rate = format.sampleRate
        var dropped = 0
        let due = storedChops.filter { $0.token == current && $0.start < horizon }
        storedChops.removeAll { $0.token <= current && $0.start < horizon }
        for chop in due {
            let frame = AVAudioFramePosition(((chop.start - timeline.anchor) * rate).rounded())
            guard chop.start >= now + timeline.margin, frame >= 0 else {
                dropped += 1
                continue
            }
            chops.player.scheduleBuffer(chop.buffer, at: AVAudioTime(sampleTime: frame, atRate: rate),
                                        options: [], completionHandler: nil)
            queuedChops.append(chop)
            if chop.featured {
                let start = timeline.conductorAnchor + (chop.start - timeline.anchor)
                let window = start..<(start + Double(chop.buffer.frameLength) / rate)
                duckWindows.append(window)
                if chop.duck { dropWindows.append(window) }
            }
        }
        if dropped > 0 { LMLog.audio.warning("Lo-Fi dialogue dropped \(dropped) late chops") }
    }

    /// Fade out over `fade` seconds; the player stops once the fade is complete.
    func end(fade: Double, now: Double) {
        pending = nil
        guard playing else { return }
        strip.fade(to: 0, over: fade, now: now)
        stopAt = now + fade + 0.3
        // Chops inside the fade still sound; later ones are dropped and the fader closes after the tail.
        let cutoff = transportNow(now) + fade
        if let token = currentCueToken { storedChops.removeAll { $0.token <= token && $0.start > cutoff } }
        chopsUntil = min(chopsUntil, now + fade + Self.chopTailSeconds)
        LMLog.audio.info("📼🔊 archive audio end fade=\(String(format: "%.1f", fade), privacy: .public)s")
    }

    /// "Footage audio" changed while a segment plays.
    func setGain(_ gain: Float) {
        guard playing else { return }
        cueGain = gain
        strip.trim = trim(for: cueGain)
    }

    /// Strip trim for a Footage audio gain: linear in the setting (monotonic, zero is silent).
    private func trim(for gain: Float) -> Float {
        Self.baseTrim * max(0, gain)
    }

    /// Stop at once (engine stop, conductor restart).
    func reset(now: Double) {
        pending = nil
        strip.fade(to: 0, over: 0, now: now)
        strip.tick(now: now)
        powerDown()
    }

    /// Engine stop and reset: the bed and the chop timeline stop.
    func powerDown() {
        stopChopTimeline()
        retireCurrentCue()
        chopsUntil = -.infinity
        releaseBed()
    }

    /// After a stop or reset (a route recovery re-arms the transport through one) the current cue's bed
    /// is gone and its chop fader stays closed, so none of its chops can sound. Its token is retired
    /// like a cancelled cue: a plan for it that arrives later (one built on the old transport revision
    /// that was still in flight, or the rebuild on the new grid) is ignored instead of queueing inaudible
    /// chops that would still duck the music and the bed. The footage service's next cue has a new token.
    private func retireCurrentCue() {
        guard let token = currentCueToken else { return }
        cancelledTokens.insert(token)
        planRevisions[token] = nil
    }

    /// The bed finished (or was replaced): the persistent chop timeline keeps running.
    private func releaseBed() {
        if playing { source.player.stop() }
        playing = false
        updateChopGain(at: lastTime)
        stopAt = nil
        endAt = nil
        label = nil
        speechActivity = 0
        setFilters(running: false)
    }

    /// 10 Hz with the other strips.
    func modulate(t: Double) {
        lastTime = t
        queueDueChops(at: t)
        if playing {
            // A buffer that ran out (it ends with its own 80 ms fade) is released like a finished fade.
            if let e = endAt, t >= e + 0.2, stopAt == nil { stopAt = t }
            if let s = stopAt, t >= s {
                if let next = pending {
                    pending = nil
                    start(next, now: t)
                } else {
                    strip.fade(to: 0, over: 0, now: t)
                    releaseBed()
                }
            }
            if playing {
                updateMix(progress: (t - cueStart) / cueDuration)
                blendSoundtrack(at: t)
                setPanIfNeeded(t)
            }
        }
        strip.tick(now: t)
        updateChopGain(at: t)
        let window = Int(max(0, t - cueStart) / ArchiveAudioMath.activityWindow)
        speechActivity = playing && activityEnvelope.indices.contains(window) ? presence * activityEnvelope[window] : 0
    }

    private func updateMix(progress: Double) {
        guard let cueMix else { return }
        if beatLocked {
            updateLofiMix(cueMix, progress: progress)
            return
        }
        let value = cueMix.clarity.value(at: progress)
        // Keep both effects present even at full clarity. The consonants come forward
        // mainly through the wider filter, with only a small dip in the sends.
        let wetScale: Float = 1 - 0.18 * value
        let reverb = cueMix.room.value(at: progress) * wetScale
        let echo = cueMix.echo.value(at: progress) * wetScale
        let cutoff = Self.lowpassHz + 1650 * value
        let motion = cueMix.movement.value(at: progress)
        ParamRamp.set(spectralSweep.$notchMaximumFrequency, 900 + 970 * motion, over: 0.13)
        ParamRamp.set(spectralSweep.$dryWetMix, 0.05 + 0.49 * motion * (1 - 0.55 * value), over: 0.13)
        ParamRamp.set(highpass.$cutoffFrequency, Self.highpassHz - 110 * value, over: 0.12)
        ParamRamp.set(lowpass.$cutoffFrequency, cutoff, over: 0.12)
        ParamRamp.set(lowpass2.$cutoffFrequency, cutoff, over: 0.12)
        if let dry = strip.dryGain {
            let direct = Self.dryGain + (Self.clearDryGain - Self.dryGain) * value
            ParamRamp.setGain(dry, direct, over: 0.12)
        }
        strip.setSends(reverb: reverb, delay: echo, over: 0.12)
    }

    /// Lo-Fi bed: the baseline effected chain the user asked to keep. Sends at 1.18 times the room and
    /// echo contours, the beat-locked phaser at 0.36-0.58 wet, HPF 290-205 Hz and two low-pass stages at
    /// 2.1-3.2 kHz, direct sound 0.27-0.60, with one short clarity swell per picture.
    private func updateLofiMix(_ cueMix: CueMix, progress: Double) {
        let value = cueMix.clarity.value(at: progress)
        let wetScale: Float = 1.18 * (1 - 0.18 * value)
        let reverb = cueMix.room.value(at: progress) * wetScale
        let echo = cueMix.echo.value(at: progress) * wetScale
        let u = Float(max(0, 1 - abs(progress - cueMix.revealCenter) / cueMix.revealHalfWidth))
        let reveal = u * u * (3 - 2 * u)
        let cutoff = 2100 + 1100 * reveal
        let motion = cueMix.movement.value(at: progress)
        ParamRamp.set(spectralSweep.$notchMaximumFrequency, 900 + 970 * motion, over: 0.13)
        ParamRamp.set(spectralSweep.$dryWetMix, 0.36 + 0.22 * motion, over: 0.13)
        ParamRamp.set(highpass.$cutoffFrequency, 290 - 85 * reveal, over: 0.12)
        ParamRamp.set(lowpass.$cutoffFrequency, cutoff, over: 0.12)
        ParamRamp.set(lowpass2.$cutoffFrequency, cutoff, over: 0.12)
        if let dry = strip.dryGain {
            ParamRamp.setGain(dry, 0.27 + 0.33 * reveal, over: 0.12)
        }
        strip.setSends(reverb: reverb, delay: echo, over: 0.12)
    }

    private var lastPan: Float = 0
    private func setPanIfNeeded(_ t: Double) {
        let p = 0.4 * panWalk.value(at: t)
        if abs(p - lastPan) > 0.005 { strip.setPan(p, over: 0.12); lastPan = p }
    }
}
