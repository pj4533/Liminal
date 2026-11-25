//
//  ArchiveFootageService.swift
//  Liminal
//
//  Owns the archive footage feature (docs/plans/archive-video.md 1-3, decision A27): the Internet Archive
//  client, the clip cache and its prefetch, the footage weaver (ticked at 2 Hz off the main actor) and
//  two video frame sources, one per piece of a crossfade. The render loops call only `frame(image:)` and
//  `update(_:)`, each a lock access plus a little arithmetic: no scheduling, I/O or decoding on the main
//  actor. While footage is on, some film always shows: a continuous stream of short pieces.
//  The pieces' sound (decoded off the main actor, posted to the music conductor) comes and goes on its
//  own, and the "Archive Footage" settings (on/off, audio level) apply at once. Piece changes follow the
//  drum grid the transport publishes; the weaver waits for it.
//

import AVFoundation
import CoreGraphics
import Foundation
import Metal
import os

nonisolated final class ArchiveFootageService: @unchecked Sendable {
    static let shared = ArchiveFootageService()

    /// What a render loop draws this frame: layer A (slot 0, texture 7) and layer B (slot 1, texture 8).
    struct Frame {
        let texture: MTLTexture?
        let textureB: MTLTexture?
        let state: VideoCompositeState

        static let off = Frame(texture: nil, textureB: nil, state: .off)
    }

    private struct Shared {
        var running = false
        var startUptime: Double = 0
        /// The weaver's pieces (at most two), published after every tick.
        var pieces: [FootagePiece] = []
        var aspects: [Float] = [4.0 / 3.0, 4.0 / 3.0]
        var conditions = FootageWeaver.Conditions()
        var grid: LofiTakeGrid?
        // Tint eased toward the current picture's colours.
        var tint = SIMD3<Float>(0.9, 0.85, 0.75)
        var shade = SIMD3<Float>(0.06, 0.05, 0.05)
        var tintTarget = SIMD3<Float>(0.9, 0.85, 0.75)
        var shadeTarget = SIMD3<Float>(0.06, 0.05, 0.05)
        /// Shadowplay key polarity (VideoCompositeState.keyPolarity), eased like the tint.
        var polarity: Float = 1
        var polarityTarget: Float = 1
        var coverage: Float = 0.35
        var coverageTarget: Float = 0.35
        var tintKey: ObjectIdentifier?
        var lastFrameUptime: Double = 0
        /// Loud music pulls the footage back a little (eased, 0.7...1).
        var calm: Float = 1
        /// Master fade: linear 0...1, toward 0 while the setting is being turned off (2 s), else 1.
        var master: Float = 1
        var status = "Footage starts with playback"
        // Settings and lifecycle: footage runs while playback wants it AND the setting is on.
        var wantsRun = false
        var enabled = true
        var audioLevel: Float = 0.5
        /// The setting was turned off: fade everything out over 2 s, then stop.
        var disabling = false
        var disablingSince: Double?
        var audio: AudioState?
        var pendingAudio: AudioState?
        var attemptedAudioPiece: Int?
    }

    /// A piece's sound (plan 4, A27).
    private struct AudioState {
        let cue: ArchiveAudioCuePlan
        let token: Int
        let pieceIndex: Int
        var begun = false
        var ended = false
    }

    /// Where the sound goes: the music engine's conductor (attached by the app; nil in harnesses).
    final class MusicSink: @unchecked Sendable {
        let post: @Sendable (ArchiveControl) -> Void
        let format: AVAudioFormat
        let takeGrid: @Sendable () -> LofiTakeGrid?
        /// The transport side channel (plan 3.6); nil until the transport is armed.
        let transport: @Sendable () -> LofiTransportInfo?
        init(format: AVAudioFormat, takeGrid: @escaping @Sendable () -> LofiTakeGrid?,
             transport: @escaping @Sendable () -> LofiTransportInfo?,
             post: @escaping @Sendable (ArchiveControl) -> Void) {
            self.format = format
            self.takeGrid = takeGrid
            self.transport = transport
            self.post = post
        }
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let store = ArchiveClipStore(directory: ArchiveClipStore.defaultDirectory())
    private let client = ArchiveClient(offline: DebugLaunchOptions.videoOffline || DebugLaunchOptions.videoFile != nil)
    /// Two decoders: the current piece and the next one, which is prepared ahead of its crossfade.
    private let sources: [VideoFrameSource]
    private let tasks = OSAllocatedUnfairLock<[Task<Void, Never>]>(initialState: [])
    /// -LiminalVideoFile: a local clip used instead of the cache (no network).
    private let localClip = OSAllocatedUnfairLock<(clip: ArchiveClip, url: URL)?>(initialState: nil)
    private let music = OSAllocatedUnfairLock<MusicSink?>(initialState: nil)
    private var audioTokenSeed = OSAllocatedUnfairLock(initialState: 0)
    /// Dialogue performance memory and bank cache across cues (plan 6.2).
    let dialogue = DialogueDirector()
    /// The running dialogue coordinator task and its cue token; cancelled with the cue.
    private let dialogueTask = OSAllocatedUnfairLock<(token: Int, task: Task<Void, Never>)?>(initialState: nil)

    /// -LiminalVideoOff removes the feature whatever the setting says.
    static var isAvailable: Bool { !DebugLaunchOptions.videoOff }
    private init() {
        let device = MTLCreateSystemDefaultDevice()
        let made = (0..<2).compactMap { _ in device.flatMap { VideoFrameSource(device: $0) } }
        sources = made.count == 2 ? made : []
        // Launch cleanup off the main actor (A31): the store's load deletes footage files its index does not
        // list; stale CFNetwork downloads and old fixtures go from tmp/. Nothing that can play is touched.
        Task.detached(priority: .utility) { [store] in
            await store.load()
            ArchiveDiskSweep.sweepTemporaryDirectory()
        }
    }

    static func uptime() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    var status: String { shared.withLock { $0.status } }

    // MARK: - Lifecycle

    /// The music engine that plays the pieces' sound (called once by each app on appear).
    func attachMusic(_ engine: GenerativeEngine) {
        let sink = MusicSink(format: engine.archiveFormat, takeGrid: { [weak engine] in
            engine?.musicState.read().lofiTakeGrid
        }, transport: { [weak engine] in
            engine?.musicState.transport()
        }) { [weak engine] c in engine?.post(c) }
        music.withLock { $0 = sink }
    }

    /// "Archive Footage" settings. Turning footage off fades picture and sound out over 2 s and stops
    /// prefetching (the cache stays); turning it on while playing starts it again (on again during the
    /// fade brings it back).
    func apply(enabled: Bool, audioLevel: Float) {
        let level = min(max(audioLevel, 0), 1)
        let (wasEnabled, running, levelChanged) = shared.withLock { s -> (Bool, Bool, Bool) in
            let was = s.enabled, changed = s.audioLevel != level
            s.enabled = enabled
            s.audioLevel = level
            if enabled {
                s.disabling = false
                s.disablingSince = nil
            } else if s.running {
                s.disabling = true
            }
            return (was, s.running, changed)
        }
        if enabled != wasEnabled {
            LMLog.visual.info("📼 setting: footage \(enabled ? "on" : "off", privacy: .public)")
        }
        if enabled && !running { launch() }
        if !enabled && !running { shared.withLock { $0.status = "Archive footage off" } }
        if levelChanged {
            if let g = ArchiveAudioCuePlan.gain(level: level) {
                let playing = shared.withLock { $0.audio.map { $0.begun && !$0.ended } ?? false }
                if playing { music.withLock { $0 }?.post(.gain(g)) }
            } else {
                shared.withLock { s in
                    s.pendingAudio = nil
                    s.attemptedAudioPiece = nil
                }
                endAudio(fade: 2)
            }
        }
        if !enabled && running { endAudio(fade: 2) }
    }

    /// Playback started (Play / the immersive space opening). Idempotent.
    func start() {
        shared.withLock { $0.wantsRun = true }
        launch()
    }

    /// Starts prefetching and the weaver when playback wants footage and the setting is on.
    private func launch() {
        guard Self.isAvailable, !sources.isEmpty else {
            if sources.isEmpty { LMLog.visual.error("📼 footage unavailable (no Metal pre-pass)") }
            return
        }
        let go = shared.withLock { s -> Bool in
            guard s.wantsRun, s.enabled, !s.running else { return false }
            s.running = true
            s.disabling = false
            s.disablingSince = nil
            s.master = 1
            s.startUptime = Self.uptime()
            s.pieces = []
            s.grid = nil
            s.audio = nil
            s.pendingAudio = nil
            s.attemptedAudioPiece = nil
            return true
        }
        guard go else { return }
        LMLog.visual.info("📼 footage start (quick fetch=\(DebugLaunchOptions.videoForce) offline=\(DebugLaunchOptions.videoOffline) file=\(DebugLaunchOptions.videoFile ?? "-", privacy: .public) look=\(DebugLaunchOptions.videoLook ?? "-", privacy: .public) mode=\(DebugLaunchOptions.videoMode ?? "-", privacy: .public) mix=\(DebugLaunchOptions.videoMix.map { String($0) } ?? "-", privacy: .public))")
        let prefetch = Task.detached(priority: .utility) { [weak self] () -> Void in await self?.prefetchLoop() }
        let weaver = Task.detached(priority: .userInitiated) { [weak self] () -> Void in await self?.weaverLoop() }
        tasks.withLock { $0 = [prefetch, weaver] }
    }

    func stop() {
        shared.withLock { $0.wantsRun = false }
        halt()
    }

    private func halt() {
        endAudio(fade: 2)
        // Take this run's tasks before clearing `running`: a launch that follows at once (footage turned
        // back on, Play again) then stores its own tasks, which this halt never cancels.
        let old = tasks.withLock { t -> [Task<Void, Never>] in defer { t = [] }; return t }
        let (wasRunning, pendingToken) = shared.withLock { s -> (Bool, Int?) in
            defer {
                s.running = false; s.pieces = []; s.disabling = false; s.disablingSince = nil; s.audio = nil
                s.pendingAudio = nil; s.attemptedAudioPiece = nil
            }
            return (s.running, s.pendingAudio?.token)
        }
        old.forEach { $0.cancel() }
        cancelDialogue()
        // A cue still waiting for its bed may already have a plan at the conductor: drop it now rather
        // than when its wait loop next wakes.
        if let pendingToken { music.withLock { $0 }?.post(.cancelChops(token: pendingToken)) }
        guard wasRunning else { return }
        sources.forEach { $0.stop() }
        shared.withLock { s in if !s.enabled { s.status = "Archive footage off" } }
        LMLog.visual.info("📼 footage stop")
    }

    // MARK: - Cache (settings section)

    /// Clips and bytes in the cache.
    func cacheSummary() async -> (count: Int, bytes: Int64) {
        await store.load()
        return (await store.clips.count, await store.totalBytes)
    }

    /// Deletes every cached clip except the ones on screen.
    func clearCache() async {
        let keep = shared.withLock { Set($0.pieces.map(\.clipID)) }
        await store.clear(keeping: keep)
        let n = await store.clips.count
        LMLog.visual.info("📼 cache cleared (kept \(n))")
        shared.withLock { s in if s.pieces.isEmpty && s.enabled { s.status = n == 0 ? "Fetching footage" : "\(n) clips ready" } }
    }

    // MARK: - Sound (plan 4, A27)

    /// Cancels the dialogue coordinator (all cues, or only the one with `token`).
    private func cancelDialogue(matching token: Int? = nil) {
        let task = dialogueTask.withLock { current -> Task<Void, Never>? in
            guard let c = current, token == nil || c.token == token else { return nil }
            current = nil
            return c.task
        }
        task?.cancel()
    }

    /// The cue `token` is still pending or playing.
    private func isCurrentAudio(_ token: Int) -> Bool {
        shared.withLock { s in
            guard s.running, s.wantsRun, !s.disabling else { return false }
            if s.pendingAudio?.token == token { return true }
            if let a = s.audio, a.token == token, !a.ended { return true }
            return false
        }
    }

    /// Starts the dialogue work for a decoded cue beside the bed (plan 6.2). It needs the
    /// take grid and the transport info. Utility priority, cancelled with the cue token.
    private func startDialogue(token: Int, piece: FootagePiece, cue: ArchiveAudioCuePlan, clip: ArchiveClip, url: URL,
                               bed: AVAudioPCMBuffer, due: Double, sink: MusicSink) {
        guard sink.takeGrid() != nil, let info = sink.transport() else { return }
        let window = DialogueCueCoordinator.window(due: due, span: cue.endAt - cue.beginAt, transport: info)
        guard !window.isEmpty else { return }
        let director = dialogue
        let contentID = clip.id
        let format = sink.format
        let seed = UInt64(piece.seed.bitPattern)
        let task = Task.detached(priority: .utility) { [weak self] in
            let source: DialogueSource
            do {
                source = try await ArchiveDialogueSource.make(cue: cue, bed: bed, url: url, contentID: contentID,
                                                              cueToken: token, format: format)
            } catch {
                LMLog.audio.warning("📼🔊 no dialogue: native decode failed (\(String(describing: error), privacy: .public))")
                return
            }
            guard !Task.isCancelled else { return }
            _ = await director.run(source: source, window: window, seed: seed, transport: sink.transport,
                                   isCurrent: { [weak self] in self?.isCurrentAudio(token) ?? false },
                                   post: { sink.post(.chops($0)) })
        }
        let previous = dialogueTask.withLock { current -> Task<Void, Never>? in
            defer { current = (token, task) }
            return current?.task
        }
        previous?.cancel()
    }

    /// Decodes a piece's sound off the main actor and posts it to the music at the cue's start.
    private func scheduleAudio(piece: FootagePiece, cue: ArchiveAudioCuePlan, clip: ArchiveClip, url: URL) {
        guard let sink = music.withLock({ $0 }) else { return }
        let token = audioTokenSeed.withLock { $0 += 1; return $0 }
        guard let (gain, start) = shared.withLock({ s -> (Float, Double)? in
            guard s.running, !s.disabling, s.attemptedAudioPiece != piece.index,
                  let gain = ArchiveAudioCuePlan.gain(level: s.audioLevel) else { return nil }
            s.attemptedAudioPiece = piece.index
            s.pendingAudio = AudioState(cue: cue, token: token, pieceIndex: piece.index)
            return (gain, s.startUptime)
        }) else { return }
        let title = clip.title
        LMLog.audio.info("📼🔊 sound cue piece #\(piece.index) at \(String(format: "%.1f", cue.beginAt), privacy: .public)s fade \(String(format: "%.1f", cue.fadeIn), privacy: .public)s, out at \(String(format: "%.1f", cue.fadeOutAt), privacy: .public)s over \(String(format: "%.1f", cue.fadeOut), privacy: .public)s, source \(String(format: "%.1f", cue.sourceStart), privacy: .public)s+\(String(format: "%.1f", cue.sourceLength), privacy: .public)s rate \(String(format: "%.2f", cue.rate), privacy: .public) gain \(String(format: "%.2f", gain), privacy: .public)")
        Task.detached(priority: .utility) { [weak self] in
            defer {
                self?.shared.withLock { s in if s.pendingAudio?.token == token { s.pendingAudio = nil } }
            }
            let t0 = Self.uptime()
            let buffer: AVAudioPCMBuffer
            do {
                buffer = try await ArchiveAudioDecoder.decode(url: url, sourceStart: cue.sourceStart,
                                                              sourceLength: cue.sourceLength, rate: cue.rate,
                                                              format: sink.format)
            } catch {
                LMLog.audio.warning("📼🔊 no sound: decode failed (\(String(describing: error), privacy: .public))")
                return
            }
            let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
            LMLog.audio.info("📼🔊 decoded \(String(format: "%.1f", seconds), privacy: .public)s in \(String(format: "%.0f", (Self.uptime() - t0) * 1000), privacy: .public) ms")
            let due = start + cue.beginAt
            guard let self else { return }
            // The bed never waits for dialogue analysis: the coordinator runs beside this loop and
            // posts its plan at a safe bar boundary (plan 6.2).
            var posted = false
            // An abandoned cue (too late, footage off or stopping, replaced by a newer cue) cancels its
            // analysis task and any plan it already posted: that plan's chops never begin (plan 6.3).
            defer {
                if !posted {
                    self.cancelDialogue(matching: token)
                    sink.post(.cancelChops(token: token))
                }
            }
            self.startDialogue(token: token, piece: piece, cue: cue, clip: clip, url: url, bed: buffer, due: due, sink: sink)
            // Prepare the speech envelope with the cue, before its start deadline. A buffer trimmed
            // during catch-up needs its own envelope so its activity stays on the playback clock.
            let preparedActivity = ArchiveAudioMath.activity(buffer)
            let deadline = start + cue.fadeOutAt
            while true {
                let time = Self.uptime()
                guard time < deadline, !Task.isCancelled else { return }
                let visibleAt = self.shared.withLock { s -> Double? in
                    guard s.running, s.wantsRun, !s.disabling, s.pendingAudio?.token == token,
                          let current = s.pieces.last, current.index == piece.index else { return nil }
                    return start + current.start
                }
                guard let visibleAt else { return }
                if time >= max(due, visibleAt), self.sources[piece.slot].latest() != nil { break }
                let wait = min(0.12, max(0.025, max(due, visibleAt) - time))
                try? await Task.sleep(for: .seconds(wait))
            }
            let late = Self.uptime() - due
            guard let ready = ArchiveAudioMath.catchUp(buffer, late: late) else { return }
            let activity = ready === buffer ? preparedActivity : ArchiveAudioMath.activity(ready)
            posted = self.shared.withLock { s -> Bool in
                guard s.pendingAudio?.token == token else { return false }
                s.pendingAudio = nil
                guard s.running, s.wantsRun, !s.disabling, late < cue.fadeOutAt - cue.beginAt,
                      let g = ArchiveAudioCuePlan.gain(level: s.audioLevel) else { return false }
                s.audio = AudioState(cue: cue, token: token, pieceIndex: piece.index, begun: true)
                sink.post(.begin(ArchiveVoice.Cue(buffer: ready, gain: g,
                    fadeIn: max(0.35, cue.fadeIn - max(late, 0)),
                    label: title, claritySeed: piece.seed, activity: activity, token: token,
                    transport: sink.transport())))
                return true
            }
            if posted && late > 0.1 {
                LMLog.audio.warning("📼🔊 sound started \(String(format: "%.2f", late), privacy: .public)s late")
            }
        }
    }

    /// Fades the current sound out (once).
    private func endAudio(fade: Double, matching token: Int? = nil) {
        let sink = music.withLock { $0 }
        shared.withLock { s in
            guard var a = s.audio, !a.ended, token == nil || a.token == token else { return }
            a.ended = true
            s.audio = a
            if a.begun { sink?.post(.end(fade: fade)) }
        }
    }

    // MARK: - Render loop API

    /// The footage for this frame, and the picture shown under it (for the tint). Cheap: one lock,
    /// no allocation; a new picture's tint is measured off the main actor.
    func frame(image: CGImage?) -> Frame { frame(key: image, image: { image }) }

    /// `key` identifies the picture (its tint is measured once per key); `image` is called only when it changes.
    func frame(key: AnyObject?, image: () -> CGImage?) -> Frame {
        let now = Self.uptime()
        let newKey = key.map(ObjectIdentifier.init)
        let snap = shared.withLock { s -> (pieces: [FootagePiece], elapsed: Double, aspects: [Float],
                                          tint: SIMD3<Float>, shade: SIMD3<Float>, polarity: Float, coverage: Float,
                                          gain: Float, measure: Bool) in
            var measure = false
            if let newKey, s.tintKey != newKey {
                s.tintKey = newKey
                measure = true
            }
            let dt = s.lastFrameUptime > 0 ? min(now - s.lastFrameUptime, 0.5) : 0
            s.lastFrameUptime = now
            let k = Float(1 - exp(-dt / 1.0))   // about 3 s to settle (plan 2.2)
            s.tint += (s.tintTarget - s.tint) * k
            s.shade += (s.shadeTarget - s.shade) * k
            s.polarity += (s.polarityTarget - s.polarity) * k
            s.coverage += (s.coverageTarget - s.coverage) * k
            // Loud music pulls the footage back to 70 % (eased over about 3 s); it never vanishes.
            let calmTarget = 1 - 0.3 * Self.smooth01((s.conditions.musicIntensity - 0.7) / 0.25)
            s.calm += (calmTarget - s.calm) * k
            // Turning footage off: a 2 s linear ramp (smoothstepped below); on again ramps back.
            let masterTarget: Float = s.disabling ? 0 : 1
            let step = Float(dt) / 2
            s.master = masterTarget < s.master ? max(s.master - step, 0) : min(s.master + step, 1)
            var gain = s.calm * Self.smooth01(s.master)
            if let grid = s.grid {
                gain *= 1 + 0.5 * grid.accent(at: now - s.startUptime)
            }
            return (s.running ? s.pieces : [], now - s.startUptime, s.aspects, s.tint, s.shade, s.polarity, s.coverage, gain, measure)
        }
        let measure = snap.measure ? image() : nil
        if let img = measure {
            let key = ObjectIdentifier(img)
            Task.detached(priority: .utility) { [weak self] in
                let t = VideoComposite.stats(of: img)
                self?.shared.withLock { s in
                    guard s.tintKey == key else { return }
                    s.tintTarget = t.tint
                    s.shadeTarget = t.shade
                    s.polarityTarget = t.polarity
                    s.coverageTarget = t.coverage
                }
            }
        }
        guard !snap.pieces.isEmpty, !sources.isEmpty else { return .off }
        var state = VideoCompositeState(a: nil, tint: snap.tint, shade: snap.shade)
        state.constantMix = DebugLaunchOptions.videoMix
        state.keyPolarity = snap.polarity
        state.keyCoverage = snap.coverage
        var texA: MTLTexture?, texB: MTLTexture?
        let awaitingFrame = snap.pieces.count == 2 && snap.pieces[1].fill != nil
            && sources[snap.pieces[1].slot].latest() == nil
        for p in snap.pieces {
            let time = awaitingFrame ? min(snap.elapsed, snap.pieces[1].start) : snap.elapsed
            let w = p.weight(at: time) * snap.gain
            guard w > 0, let tex = sources[p.slot].latest() else { continue }
            let layer = VideoLayer(weight: w, look: p.look, seed: p.seed, aspect: snap.aspects[p.slot], warp: p.warp,
                                   recipe: p.recipe, envelope: p.driveEnvelope(at: time) * snap.gain)
            if p.slot == 0 { state.a = layer; texA = tex } else { state.b = layer; texB = tex }
        }
        guard !state.isOff else { return .off }
        return Frame(texture: texA, textureB: texB, state: state)
    }

    /// The current stage texture of a slot (macOS binds them at draw time: 0 = texture 7, 1 = texture 8).
    func texture(slot: Int) -> MTLTexture? { slot < sources.count ? sources[slot].latest() : nil }

    /// The render loops report what the weaver listens to (transition, image age, music).
    func update(_ c: FootageWeaver.Conditions) {
        shared.withLock { $0.conditions = c }
    }

    static func smooth01(_ x: Float) -> Float { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }

    // MARK: - Pieces

    private func weaverLoop() async {
        let seed = DebugLaunchOptions.videoSeed.map { UInt64($0) } ?? UInt64.random(in: 0...UInt64.max)
        var weaver = FootageWeaver(seed: seed, timing: DebugLaunchOptions.videoMix != nil ? .stills : .standard,
                                   pinnedLook: DebugLaunchOptions.videoLook.flatMap(VideoLook.init(name:)),
                                   pinnedRecipe: DebugLaunchOptions.videoMode.flatMap(FootageRecipe.init(name:)))
        var rng = MusicRNG(seed: seed ^ 0xA5C1_17E5)
        var recordedPieceIndex = -1
        var lastLog = -10.0
        LMLog.visual.info("📼 weaver seed=\(seed)")
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { break }
            let now = Self.uptime()
            let (running, start, cond, disabling) = shared.withLock {
                ($0.running, $0.startUptime, $0.conditions, $0.disabling)
            }
            guard running else { break }
            let elapsed = now - start
            if let off = DebugLaunchOptions.videoOffAt, elapsed >= off, !disabling,
               shared.withLock({ $0.enabled }) {
                LMLog.visual.info("📼 DEBUG: footage setting off at \(String(format: "%.1f", elapsed), privacy: .public)s (-LiminalVideoOffAt)")
                let level = shared.withLock { $0.audioLevel }
                apply(enabled: false, audioLevel: level)
                continue
            }
            if disabling {
                // Footage turned off: frame() ramps the picture out over 2 s; then stop (the cache stays).
                let since = shared.withLock { s -> Double in
                    if s.disablingSince == nil { s.disablingSince = now }
                    return s.disablingSince ?? now
                }
                if now - since >= 2.3 { halt(); break }
                continue
            }
            let clips = await availableClips()
            let grid = music.withLock { $0 }?.takeGrid().map {
                LofiTakeGrid(origin: $0.origin - start, beatDuration: $0.beatDuration, takeIndex: $0.takeIndex,
                             nextBeatDuration: $0.nextBeatDuration)
            }
            // The sound fades out on its own schedule (A27).
            if let a = shared.withLock({ $0.audio }), !a.ended {
                // Finish the old direct sound before the incoming fill edit needs the
                // voice. Its echoes continue. Compensate for the 2 Hz polling interval.
                var end = a.cue.endAt
                if let edit = weaver.current, edit.fill != nil, edit.index > a.pieceIndex {
                    end = min(end, edit.start)
                }
                if elapsed >= end - a.cue.fadeOut {
                    endAudio(fade: max(0.035, end - elapsed), matching: a.token)
                }
            }
            // Nothing is scheduled until the transport publishes its drum grid.
            guard let grid else {
                shared.withLock { $0.grid = nil }
                continue
            }
            let decision = weaver.tick(elapsed: elapsed, conditions: cond, hasClip: !clips.isEmpty,
                                       grid: grid) { [sources] slot in
                sources[slot].latest() != nil
            }
            switch decision {
            case .none:
                break
            case .retire(let slot):
                sources[slot].stop()
                LMLog.visual.info("📼 piece retired slot=\(slot) at \(String(format: "%.1f", elapsed), privacy: .public)s")
            case .drop(let slot):
                sources[slot].stop()
                let dropped = weaver.pieceCount - 1
                let droppedToken = shared.withLock { s -> Int? in
                    if s.pendingAudio?.pieceIndex == dropped { s.pendingAudio = nil }
                    if s.attemptedAudioPiece == dropped { s.attemptedAudioPiece = nil }
                    return s.audio.flatMap { $0.pieceIndex == dropped ? $0.token : nil }
                }
                if let droppedToken { endAudio(fade: 2, matching: droppedToken) }
                LMLog.visual.warning("📼 piece dropped slot=\(slot) (no frame); the current piece holds")
            case .prepare(let r):
                _ = prepare(r, clips: clips, weaver: &weaver,
                            rng: &rng, elapsed: elapsed, startUptime: start)
            }
            let pieces = weaver.pieces
            shared.withLock { $0.pieces = pieces; $0.grid = grid }
            if let piece = weaver.current, piece.index > recordedPieceIndex,
               elapsed >= piece.start, sources[piece.slot].latest() != nil {
                recordedPieceIndex = piece.index
                if let clip = clips.first(where: { $0.id == piece.clipID }) {
                    shared.withLock { $0.status = "Showing: \(clip.title)\(clip.year.map { " (\($0))" } ?? "")" }
                }
                if piece.clipID.hasPrefix("local:") {
                    localClip.withLock { $0?.clip.shownStarts.append(piece.segmentStart) }
                } else {
                    await store.markUsed(piece.clipID, segmentStart: piece.segmentStart)
                }
            }
            // The next video can be ready before the outgoing audio starts fading.
            // Retry the handoff on the loop instead of discarding that incoming cue.
            if let next = weaver.current, next.sound,
               let clip = clips.first(where: { $0.id == next.clipID }),
               let cue = ArchiveAudioCuePlan(piece: next, clipDuration: clip.duration),
               elapsed < cue.fadeOutAt {
                scheduleAudio(piece: next, cue: cue, clip: clip, url: url(for: clip))
            }
            if elapsed - lastLog >= 10 {
                lastLog = elapsed
                let parts = pieces.map { p in
                    "#\(p.index)/s\(p.slot) \(p.recipe.name) env=\(String(format: "%.2f", p.envelope(at: elapsed))) lvl=\(String(format: "%.2f", p.level(at: elapsed)))"
                }
                LMLog.visual.info("📼 weave t=\(String(format: "%.1f", elapsed), privacy: .public)s presence=\(String(format: "%.3f", weaver.presence(at: elapsed)), privacy: .public) \(parts.joined(separator: " "), privacy: .public)")
            }
        }
    }

    /// Start the next decoder at the existing deadline.
    private func prepare(_ r: FootageWeaver.Request, clips: [ArchiveClip],
                         weaver: inout FootageWeaver, rng: inout MusicRNG,
                         elapsed: Double, startUptime: Double) -> FootagePiece? {
        let salience = DialogueSalienceIndex.active
        let ledger = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            && !DebugLaunchOptions.isAutomated ? DialogueLineLedger.shared : DialogueLineLedger()
        guard let selection = FootageSalience.prepare(r, clips: clips, weaver: &weaver, rng: &rng,
                                                       elapsed: elapsed, index: salience, ledger: ledger) else {
            weaver.prepareFailed()
            return nil
        }
        if let line = selection.salientLine {
            LMLog.visual.info("salient-pick id=\(selection.clip.id, privacy: .public) line=\(line.start)...\(line.end) interest=\(line.interest) peakWord=\(line.peakWord, privacy: .public) peakWeight=\(line.peakWeight)")
        }
        let clip = selection.clip
        let piece = selection.piece
        let segStart = piece.segmentStart
        let rate = Double(r.rate)
        let preroll = selection.preroll
        let readStart = selection.readStart
        let sourceLength = selection.sourceLength
        let length = piece.length
        let url = url(for: clip)
        weaver.didPrepare(piece)
        sources[r.slot].play(.init(url: url, start: readStart, length: sourceLength, rate: r.rate,
                                   black: clip.black, white: clip.white,
                                   anchorUptime: startUptime + r.start - preroll / rate))
        let aspect = Float(clip.width) / Float(max(clip.height, 1))
        shared.withLock { $0.aspects[r.slot] = aspect }
        LMLog.visual.info("📼 piece #\(r.index) slot=\(r.slot) recipe=\(r.recipe.name, privacy: .public) id=\(clip.id, privacy: .public) title=\"\(clip.title, privacy: .public)\" segment=\(String(format: "%.1f", segStart), privacy: .public)s rate=\(String(format: "%.2f", r.rate), privacy: .public) warp=\(String(format: "%.2f", r.warp), privacy: .public) level=\(String(format: "%.2f", r.level), privacy: .public)+\(String(format: "%.2f", r.swell), privacy: .public) length=\(String(format: "%.1f", length), privacy: .public)s fade=\(String(format: "%.1f", r.fadeIn), privacy: .public)s sound=\(piece.sound) (wanted \(r.sound), audio=\(clip.hasAudio)) starts \(String(format: "%.1f", r.start), privacy: .public)s at \(String(format: "%.1f", elapsed), privacy: .public)s")
        return piece
    }

    private func url(for clip: ArchiveClip) -> URL {
        if let l = localClip.withLock({ $0 }), l.clip.id == clip.id { return l.url }
        return store.fileURL(for: clip)
    }

    private func availableClips() async -> [ArchiveClip] {
        if let l = localClip.withLock({ $0 }) { return [l.clip] }
        if DebugLaunchOptions.videoFile != nil { return [] }   // still validating the local file
        return await store.clips
    }

    // MARK: - Prefetch

    private func prefetchLoop() async {
        await store.load()
        if let path = DebugLaunchOptions.videoFile {
            await registerLocal(path)
            return
        }
        let cached = await store.clips
        let cachedBytes = await store.totalBytes
        LMLog.visual.info("📼 cache: \(cached.count) clips, \(String(format: "%.1f", Double(cachedBytes) / 1e6), privacy: .public) MB at \(self.store.directory.path, privacy: .public)")
        for c in cached { LMLog.visual.info("📼 cached clip id=\(c.id, privacy: .public) \"\(c.title, privacy: .public)\" (\(c.year ?? 0)) \(String(format: "%.0f", c.duration), privacy: .public)s used \(c.useCount)x") }
        shared.withLock { $0.status = cached.isEmpty ? "Fetching footage" : "\(cached.count) clips ready" }
        if DebugLaunchOptions.videoOffline {
            LMLog.visual.info("📼 offline: playing from the cache only, no requests")
            return
        }
        // Footage is always on (A27): start fetching almost at once on an empty cache.
        try? await Task.sleep(nanoseconds: cached.isEmpty || DebugLaunchOptions.videoForce ? 1_000_000_000 : 5_000_000_000)
        var picker = CandidatePicker(seed: UInt64.random(in: 0...UInt64.max), startsEmpty: cached.isEmpty)
        var failures = 0
        var lastDownload = Date.distantPast
        while !Task.isCancelled, shared.withLock({ $0.running }) {
            let clips = await store.clips
            let cachedIDs = Set(clips.map(\.id))
            let pinned = ArchiveSeedList.pinned.first { !cachedIDs.contains($0.id) && !picker.skipped.contains($0.id) }
            let sinceLast = Date().timeIntervalSince(lastDownload)
            let protected = shared.withLock { Set($0.pieces.map(\.clipID)) }
            let discoveryCount = cachedIDs.subtracting(ArchiveSeedList.pinnedIDs).count
            let discoveryDue = discoveryCount < ArchiveCachePolicy.discoverySlots
                || ArchiveCachePolicy.replacement(clips, protected: protected) != nil
            let due = (pinned != nil || discoveryDue)
                && (clips.count < ArchiveCachePolicy.minReady || sinceLast >= 15)
            if !due || !Self.hasFreeSpace(store.directory) {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                continue
            }
            do {
                let downloaded = try await fetchOne(picker: &picker, preferSmallest: pinned != nil || clips.count < 2,
                                                    pinned: pinned)
                failures = 0
                // A skipped candidate (colour odds, excluded, no file) is not a download: try the next one
                // now (the client still paces requests 2 s apart).
                if downloaded { lastDownload = Date() }
                let n = await store.clips.count
                shared.withLock { s in if s.pieces.isEmpty { s.status = "\(n) clips ready" } }
            } catch is CancellationError {
                break
            } catch {
                failures += 1
                let wait = ArchiveCatalog.backoff(failures: failures)
                LMLog.visual.warning("📼 fetch failed (\(String(describing: error), privacy: .public)); retry in \(Int(wait))s")
                shared.withLock { s in if s.pieces.isEmpty { s.status = "Footage offline" } }
                try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            }
        }
    }

    private static func hasFreeSpace(_ dir: URL, downloadBytes: Int64 = 0) -> Bool {
        let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = v?.volumeAvailableCapacityForImportantUsage else { return true }
        return free > ArchiveCachePolicy.minFreeBytes && downloadBytes <= free - ArchiveCachePolicy.minFreeBytes
    }

    /// Search results per query (in memory) and the shuffle bag over them.
    private struct CandidatePicker {
        var rng: MusicRNG
        var docs: [String: [ArchiveSearchDoc]] = [:]
        var numFound: [String: Int] = [:]
        var bag = ShuffleBag<String>([])
        var byID: [String: (doc: ArchiveSearchDoc?, seed: ArchiveSeedList.Seed?, query: ArchiveCatalog.Query)] = [:]
        var skipped: Set<String> = []
        var usedSeeds = false
        let startsEmpty: Bool
        init(seed: UInt64, startsEmpty: Bool) {
            rng = MusicRNG(seed: seed)
            self.startsEmpty = startsEmpty
        }
    }

    private static let rows = 50
    /// One search (or the seed list), one metadata request, one download, validation, into the store.
    /// Returns true when a clip was added to the store.
    @discardableResult
    private func fetchOne(picker: inout CandidatePicker, preferSmallest: Bool,
                          pinned: ArchiveSeedList.Seed?) async throws -> Bool {
        let cachedIDs = Set(await store.clips.map(\.id))
        let id: String
        let entry: (doc: ArchiveSearchDoc?, seed: ArchiveSeedList.Seed?, query: ArchiveCatalog.Query)
        if let pinned, let query = ArchiveCatalog.queries.first(where: { $0.name == pinned.query }) {
            id = pinned.id
            entry = (nil, pinned, query)
        } else {
            let bad = await store.badIDs
            let recent = await store.recentDiscoveryIDs
            let exclude = cachedIDs.union(bad).union(picker.skipped)
                .union(ArchiveSeedList.pinnedIDs).union(ArchiveSeedList.retiredIDs).union(recent)
            if !picker.bag.hasAny(excluding: exclude) || picker.rng.chance(0.25) {
                try await refill(&picker)
            }
            let candidates = picker.byID
            guard let drawn = picker.bag.next(rng: &picker.rng, excluding: exclude, weight: {
                candidates[$0]?.query.candidateWeight ?? 1
            }), let candidate = candidates[drawn] else {
                throw ArchiveClientError.backend("no candidates")
            }
            id = drawn
            entry = candidate
            let tone = ArchiveCatalog.tone(entry.doc?.color?.value ?? (entry.seed?.color == true ? "color" : nil))
            if tone == .colour && !picker.rng.chance(ArchiveCatalog.colourOdds) {
                picker.skipped.insert(id)
                return false
            }
        }
        let title = entry.doc?.titleText ?? entry.seed?.title ?? id
        LMLog.visual.info("📼 candidate id=\(id, privacy: .public) \"\(title, privacy: .public)\" (\(entry.doc?.yearValue ?? entry.seed?.year ?? 0)) query=\(entry.query.name, privacy: .public)")
        let meta: ArchiveItemMetadata
        do { meta = try await client.metadata(id: id) } catch let e as ArchiveClientError where e.isContentFailure {
            picker.skipped.insert(id)
            await store.markBad(id); throw e
        }
        guard pinned != nil || ArchiveCatalog.accept(meta.metadata, query: entry.query) else {
            picker.skipped.insert(id)
            LMLog.visual.info("📼 excluded by metadata: \(id, privacy: .public)")
            return false
        }
        let files = if let preferredFile = pinned?.preferredFile,
                       let preferred = meta.files.first(where: { $0.name == preferredFile }) {
            [preferred]
        } else {
            meta.files
        }
        guard let file = ArchiveCatalog.pickFile(files, preferSmallest: preferSmallest) else {
            picker.skipped.insert(id)
            await store.markBad(id)
            LMLog.visual.info("📼 no playable file in \(id, privacy: .public)")
            return false
        }
        guard Self.hasFreeSpace(store.directory, downloadBytes: file.bytes ?? 0) else {
            picker.skipped.insert(id)
            LMLog.visual.info("📼 not enough temporary disk space for \(id, privacy: .public)")
            return false
        }
        let safe = id.replacingOccurrences(of: "/", with: "_")
        let tmp = await store.tmpDirectory.appendingPathComponent("\(safe).mp4")
        let fm = FileManager.default
        defer {
            try? fm.removeItem(at: tmp)
        }
        LMLog.visual.info("📼 download id=\(id, privacy: .public) file=\(file.name, privacy: .public) \(String(format: "%.1f", Double(file.bytes ?? 0) / 1e6), privacy: .public) MB")
        do { try await client.download(id: id, file: file.name, to: tmp) } catch let e as ArchiveClientError where e.isContentFailure {
            picker.skipped.insert(id)
            await store.markBad(id); throw e
        }
        let sourceBytes = ((try? fm.attributesOfItem(atPath: tmp.path)[.size]) as? NSNumber)?.int64Value
            ?? file.bytes ?? 0
        let v: ArchiveClipValidator.Result
        do {
            try Task.checkCancellation()
            v = try await ArchiveClipValidator.validate(tmp)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            picker.skipped.insert(id)
            await store.markBad(id)
            LMLog.visual.warning("📼 invalid clip \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
        try Task.checkCancellation()
        let year = meta.metadata?.year.flatMap { Int($0.value.prefix(4)) } ?? entry.doc?.yearValue ?? entry.seed?.year
        let attrs = try fm.attributesOfItem(atPath: tmp.path)
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? sourceBytes
        let clip = ArchiveClip(id: id, title: meta.metadata?.title?.value ?? title, year: year, fileName: "\(safe).mp4",
                               bytes: bytes,
                               duration: v.duration, width: v.width, height: v.height, hasAudio: v.hasAudio,
                               black: v.black, white: v.white,
                               isColour: ArchiveCatalog.tone(meta.metadata?.color?.value) == .colour,
                               licence: meta.metadata?.licenseurl?.value, added: Date(), lastUsed: nil, useCount: 0,
                               shownStarts: [])
        // The clips on screen now, not when the download started (pieces changed meanwhile).
        let protected = shared.withLock { Set($0.pieces.map(\.clipID)) }
        let evicted: [String]
        do {
            evicted = try await store.add(clip, from: tmp, protected: protected)
        } catch ArchiveClipStore.AddFailure.insufficientCacheSpace {
            picker.skipped.insert(id)
            LMLog.visual.info("📼 not enough cache space for \(id, privacy: .public)")
            return false
        }
        let pool = await store.clips.count
        LMLog.visual.info("📼 cached id=\(id, privacy: .public) \"\(clip.title, privacy: .public)\" (\(year ?? 0)) \(v.width)x\(v.height) \(String(format: "%.0f", v.duration), privacy: .public)s audio=\(v.hasAudio) levels=\(String(format: "%.2f", v.black), privacy: .public)-\(String(format: "%.2f", v.white), privacy: .public) evicted=\(evicted.joined(separator: ","), privacy: .public) pool=\(pool)")
        return true
    }

    /// New candidates: the bundled seeds on a first launch or when search fails, else one search of a
    /// weighted query on a random page.
    private func refill(_ p: inout CandidatePicker) async throws {
        func useSeeds() {
            let seeds = ArchiveSeedList.bundled()
            for s in seeds {
                let q = ArchiveCatalog.queries.first { $0.name == s.query } ?? ArchiveCatalog.queries[0]
                p.byID[s.id] = (nil, s, q)
            }
            p.bag = ShuffleBag(Array(p.byID.keys))
            p.usedSeeds = true
            LMLog.visual.info("📼 candidates: \(seeds.count) bundled seeds")
        }
        if p.startsEmpty && !p.usedSeeds { useSeeds(); return }
        let q = ArchiveCatalog.queries[p.rng.weighted(ArchiveCatalog.queries.map(\.weight))]
        let pages = ArchiveCatalog.pageCount(numFound: p.numFound[q.name] ?? Self.rows, rows: Self.rows)
        let page = p.rng.int(1...pages)
        do {
            let body = try await client.search(q, page: page, rows: Self.rows)
            p.numFound[q.name] = body.numFound
            let ok = body.docs.filter { ArchiveCatalog.accept($0, query: q) }
            for d in ok {
                // Keep a more specific discovery when the broad B&W search also finds the film.
                if let previous = p.byID[d.identifier]?.query, previous.candidateWeight > q.candidateWeight { continue }
                if p.byID[d.identifier]?.query.name == "drug-education", q.name != "drug-education" { continue }
                p.byID[d.identifier] = (d, nil, q)
            }
            p.bag = ShuffleBag(Array(p.byID.keys))
            LMLog.visual.info("📼 search query=\(q.name, privacy: .public) page=\(page)/\(pages) found=\(body.numFound) accepted=\(ok.count)/\(body.docs.count)")
        } catch let e as ArchiveClientError {
            if case .offline = e { throw e }
            LMLog.visual.warning("📼 search failed (\(e.description, privacy: .public)); using seeds")
            if !p.usedSeeds { useSeeds() }
        } catch {
            if error is CancellationError { throw error }
            LMLog.visual.warning("📼 search failed (\(error.localizedDescription, privacy: .public)); using seeds")
            if !p.usedSeeds { useSeeds() }
        }
    }

    private func registerLocal(_ path: String) async {
        let url = URL(fileURLWithPath: path)
        do {
            let v = try await ArchiveClipValidator.validate(url)
            let clip = ArchiveClip(id: "local:\(url.lastPathComponent)", title: url.deletingPathExtension().lastPathComponent,
                                   year: nil, fileName: url.lastPathComponent, bytes: 0, duration: v.duration,
                                   width: v.width, height: v.height, hasAudio: v.hasAudio, black: v.black, white: v.white,
                                   isColour: false, licence: nil, added: Date(), lastUsed: nil, useCount: 0, shownStarts: [])
            localClip.withLock { $0 = (clip, url) }
            LMLog.visual.info("📼 local clip \(url.lastPathComponent, privacy: .public) \(v.width)x\(v.height) \(String(format: "%.0f", v.duration), privacy: .public)s levels=\(String(format: "%.2f", v.black), privacy: .public)-\(String(format: "%.2f", v.white), privacy: .public)")
        } catch {
            LMLog.visual.error("📼 -LiminalVideoFile \(path, privacy: .public) unusable: \(String(describing: error), privacy: .public)")
        }
    }
}
