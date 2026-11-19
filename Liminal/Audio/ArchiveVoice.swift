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
    /// Static Lo-Fi dip in the dialogue slot; bypassed in Ambient so that chain is unchanged.
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

    /// Lo-Fi film bed (plan 8.6). Ambient keeps the constants above.
    enum LofiBed {
        static let highpassHz: Float = 120
        static let lowpassHz: Float = 6500
        /// The second low-pass stage is opened rather than removed, so the graph is the same in both modes.
        static let openLowpassHz: Float = 16000
        static let dipHz: Float = 2200
        static let dipDB: Float = -2.5
        static let dipQ: Float = 0.7
        static let phaserMix: ClosedRange<Float> = 0.10...0.18
        static let directDB: ClosedRange<Float> = -3...0
        static let sends: ClosedRange<Float> = 0.25...0.45
        /// Context gain under a featured chop, with its own down and up times.
        static let duckDB: Float = -3
        static let duckDown = 0.04
        static let duckUp = 0.3
        /// Strip trim relative to `baseTrim` (the 1.76 and 1.31 context factors are gone, plan 8.6).
        static let trim: Float = 1
    }

    /// Dialogue chop returns (plan 8.5). Levels are relative to the 0.72 dry path.
    enum ChopBus {
        static let dryGain: Float = 0.72
        static let echoBeats: Float = 0.75
        static let echoFeedback: Float = 0.25
        static let echoBand: (low: Float, high: Float) = (400, 3000)
        static let echoUnderDryDB: Float = -16
        static let roomBand: (low: Float, high: Float) = (300, 4000)
        static let roomMidRelease: Float = 0.9
        static let roomLowRelease: Float = 0.6
        static let roomDamping: Float = 2200
        /// Return gain that puts the room's energy about 20 dB under the dry path for a 1 kHz line
        /// (0.2 measured 18.5 dB under).
        static let roomReturnGain: Float = 0.17
    }

    /// Ducking of the Lo-Fi music buses under a featured chop (plan 8.5). Drums and bass are not ducked.
    enum MusicDuck {
        static let leadDB: Float = -2
        static let midsDB: Float = -3
        static let spaceDB: Float = -4
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
    private var lastChopGain: Float = 0
    /// Not yet queued chops, sorted by start, and the ones already on the player (pruned).
    private var storedChops: [ScheduledChop] = []
    private var queuedChops: [ScheduledChop] = []
    private var timeline: ChopTimeline?
    /// The newest cue token whose bed has begun; plans for older tokens are stale.
    private var currentCueToken: Int?
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

    /// The bed's context gain: 1 normally and -3 dB under a featured chop in Lo-Fi (40 ms down,
    /// 300 ms up, plan 8.6); always 1 in Ambient. Called on every conductor step in Lo-Fi, so the
    /// down ramp starts within half a step of 40 ms before the chop.
    private func blendSoundtrack(at time: Double) {
        let ahead = time + 0.01 + LofiBed.duckDown
        let underDrop = dropWindows.contains { ahead >= $0.lowerBound && time + 0.01 < $0.upperBound }
        let gain: Float = beatLocked && underDrop ? dbToGain(LofiBed.duckDB) : 1
        guard gain != lastBedGain else { return }
        ParamRamp.setGain(bed, gain, over: gain < lastBedGain ? LofiBed.duckDown : LofiBed.duckUp)
        lastBedGain = gain
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
        presenceDip = PeakingParametricEqualizerFilter(lowpass2, centerFrequency: LofiBed.dipHz,
                                                       gain: dbToGain(LofiBed.dipDB), q: LofiBed.dipQ)
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

    /// The filters are bypassed (no DSP) while nothing plays. The Lo-Fi dip runs only when beat-locked,
    /// so the Ambient chain is exactly the previous one.
    private func setFilters(running: Bool) {
        for n in [highpass, lowpass, lowpass2, spectralSweep] as [Node] { if running { n.start() } else { n.stop() } }
        if running && beatLocked { presenceDip.start() } else { presenceDip.stop() }
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
    private func beginChops(for cue: Cue, now: Double, seconds: Double) {
        lastTime = now
        let token = cue.token ?? (max(currentCueToken ?? 0, planRevisions.keys.max() ?? 0) + 1)
        currentCueToken = token
        storedChops.removeAll { $0.token < token }
        planRevisions = planRevisions.filter { $0.key >= token }
        chopsUntil = now + seconds + Self.chopTailSeconds
        if !cue.chops.isEmpty, beatLocked {
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
        if let stored = planRevisions[plan.token], plan.revision <= stored { return }
        planRevisions[plan.token] = plan.revision
        storedChops.removeAll { $0.token == plan.token && $0.start >= plan.replaceFrom }
        let queuedEnd = queuedChops.filter { $0.token == plan.token }.map(\.end).max() ?? -.infinity
        let incoming = plan.chops.map {
            ScheduledChop(token: plan.token, start: $0.event.startTime, buffer: $0.buffer, duck: plan.bedDuck,
                          texture: $0.event.role == .texture)
        }.filter { $0.start >= plan.replaceFrom && $0.start >= queuedEnd }
        store(incoming)
        LMLog.audio.info("Lo-Fi dialogue plan cue=\(plan.token) revision=\(plan.revision) stored \(incoming.count) chops")
        blendSoundtrack(at: now)
        updateChopGain(at: now)
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

    private func stopChopTimeline() {
        chops.player.stop()
        timeline = nil
        storedChops.removeAll()
        queuedChops.removeAll()
        planRevisions.removeAll()
        dropWindows.removeAll()
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
        guard beatLocked, let first = storedChops.first, first.start < now + Self.chopQueueAhead else { return }
        let timeline = startChopTimeline(at: t)
        let rate = format.sampleRate
        var dropped = 0
        while let chop = storedChops.first, chop.start < now + Self.chopQueueAhead {
            storedChops.removeFirst()
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
        Self.baseTrim * max(0, gain) * (beatLocked ? LofiBed.trim : 1)
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
        chopsUntil = -.infinity
        releaseBed()
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

    /// Lo-Fi bed (plan 8.6): a clear, mostly direct film. HPF 120 Hz, one 6.5 kHz low-pass stage (the
    /// second opened), a -2.5 dB dip at 2.2 kHz, light phasing, direct sound -3 to 0 dB with the one
    /// clarity swell per picture, and sends of 0.25 to 0.45 following the room and echo contours.
    private func updateLofiMix(_ cueMix: CueMix, progress: Double) {
        let u = Float(max(0, 1 - abs(progress - cueMix.revealCenter) / cueMix.revealHalfWidth))
        let reveal = u * u * (3 - 2 * u)
        let motion = cueMix.movement.value(at: progress)
        let room = min(1, max(0, (cueMix.room.value(at: progress) - 0.95) / 0.90))
        let echo = min(1, max(0, (cueMix.echo.value(at: progress) - 0.95) / 1.0))
        let sends = LofiBed.sends, mix = LofiBed.phaserMix, direct = LofiBed.directDB
        ParamRamp.set(spectralSweep.$notchMaximumFrequency, 900 + 970 * motion, over: 0.13)
        ParamRamp.set(spectralSweep.$dryWetMix, mix.lowerBound + (mix.upperBound - mix.lowerBound) * motion, over: 0.13)
        ParamRamp.set(highpass.$cutoffFrequency, LofiBed.highpassHz, over: 0.12)
        ParamRamp.set(lowpass.$cutoffFrequency, LofiBed.lowpassHz, over: 0.12)
        ParamRamp.set(lowpass2.$cutoffFrequency, LofiBed.openLowpassHz, over: 0.12)
        ParamRamp.set(presenceDip.$gain, dbToGain(LofiBed.dipDB), over: 0.12)
        if let dry = strip.dryGain {
            let db = direct.lowerBound + (direct.upperBound - direct.lowerBound) * reveal
            ParamRamp.setGain(dry, dbToGain(db), over: 0.12)
        }
        strip.setSends(reverb: sends.lowerBound + (sends.upperBound - sends.lowerBound) * room,
                       delay: sends.lowerBound + (sends.upperBound - sends.lowerBound) * echo, over: 0.12)
    }

    private var lastPan: Float = 0
    private func setPanIfNeeded(_ t: Double) {
        let p = 0.4 * panWalk.value(at: t)
        if abs(p - lastPan) > 0.005 { strip.setPan(p, over: 0.12); lastPan = p }
    }
}
