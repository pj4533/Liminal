//
//  ArchiveFootageService.swift
//  Liminal
//
//  Owns the archive footage feature (docs/plans/archive-video.md 1-3): the Internet Archive client,
//  the clip cache and its prefetch, the moment director (ticked at 2 Hz off the main actor) and the
//  video frame source. The render loops call only `frame(image:)` and `update(_:)`, each a lock
//  access plus a little arithmetic: no scheduling, I/O or decoding on the main actor.
//  Phase 4-5: the moment's sound (decoded off the main actor, posted to the music conductor) and the
//  "Archive Footage" settings (on/off, amount, audio level).
//

import AVFoundation
import CoreGraphics
import Foundation
import Metal
import os

nonisolated final class ArchiveFootageService: @unchecked Sendable {
    static let shared = ArchiveFootageService()

    /// What a render loop draws this frame.
    struct Frame {
        let texture: MTLTexture?
        let state: VideoCompositeState
    }

    private struct Shared {
        var running = false
        var startUptime: Double = 0
        var plan: MomentPlan?
        var clipAspect: Float = 4.0 / 3.0
        var conditions = VideoMomentDirector.Conditions()
        // Tint eased toward the current picture's colours.
        var tint = SIMD3<Float>(0.9, 0.85, 0.75)
        var shade = SIMD3<Float>(0.06, 0.05, 0.05)
        var tintTarget = SIMD3<Float>(0.9, 0.85, 0.75)
        var shadeTarget = SIMD3<Float>(0.06, 0.05, 0.05)
        var tintKey: ObjectIdentifier?
        var lastTintUptime: Double = 0
        var replaceRequested = false
        var status = "Footage starts with playback"
        // Settings (phase 5) and lifecycle: footage runs while playback wants it AND the setting is on.
        var wantsRun = false
        var enabled = true
        var amount: VideoAmount = .normal
        var audioLevel: Float = 0.5
        /// The setting was turned off during a moment: fade it out, then stop.
        var disabling = false
        var audio: AudioState?
    }

    /// The current moment's sound (plan 4).
    private struct AudioState {
        let cue: ArchiveAudioCuePlan
        let token: Int
        var begun = false
        var ended = false
    }

    /// Where the sound goes: the music engine's conductor (attached by the app; nil in harnesses).
    final class MusicSink: @unchecked Sendable {
        let post: @Sendable (MusicControl) -> Void
        let format: AVAudioFormat
        init(format: AVAudioFormat, post: @escaping @Sendable (MusicControl) -> Void) {
            self.format = format
            self.post = post
        }
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let store = ArchiveClipStore(directory: ArchiveClipStore.defaultDirectory())
    private let client = ArchiveClient(offline: DebugLaunchOptions.videoOffline || DebugLaunchOptions.videoFile != nil)
    private let source: VideoFrameSource?
    private let tasks = OSAllocatedUnfairLock<[Task<Void, Never>]>(initialState: [])
    /// -LiminalVideoFile: a local clip used instead of the cache (no network).
    private let localClip = OSAllocatedUnfairLock<(clip: ArchiveClip, url: URL)?>(initialState: nil)
    private let music = OSAllocatedUnfairLock<MusicSink?>(initialState: nil)
    private var audioTokenSeed = OSAllocatedUnfairLock(initialState: 0)

    /// -LiminalVideoOff removes the feature whatever the setting says.
    static var isAvailable: Bool { !DebugLaunchOptions.videoOff }

    private init() {
        source = MTLCreateSystemDefaultDevice().flatMap { VideoFrameSource(device: $0) }
    }

    static func uptime() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    var status: String { shared.withLock { $0.status } }

    // MARK: - Lifecycle

    /// The music engine that plays the moments' sound (called once by each app on appear).
    func attachMusic(_ engine: GenerativeEngine) {
        let sink = MusicSink(format: engine.archiveFormat) { [weak engine] c in engine?.post(c) }
        music.withLock { $0 = sink }
    }

    /// "Archive Footage" settings. Turning footage off fades a running moment out over 2 s and stops
    /// prefetching (the cache stays); turning it on while playing starts it again.
    func apply(enabled: Bool, amount: VideoAmount, audioLevel: Float) {
        let level = min(max(audioLevel, 0), 1)
        let (wasEnabled, running, levelChanged) = shared.withLock { s -> (Bool, Bool, Bool) in
            let was = s.enabled, changed = s.audioLevel != level
            s.enabled = enabled
            s.amount = amount
            s.audioLevel = level
            if enabled { s.disabling = false } else if s.running { s.disabling = true }
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
                if playing { music.withLock { $0 }?.post(.archiveGain(g)) }
            } else {
                endAudio(fade: 2)
            }
        }
    }

    /// Playback started (Play / the immersive space opening). Idempotent.
    func start() {
        shared.withLock { $0.wantsRun = true }
        launch()
    }

    /// Starts prefetching and the moment clock when playback wants footage and the setting is on.
    private func launch() {
        guard Self.isAvailable, source != nil else {
            if source == nil { LMLog.visual.error("📼 footage unavailable (no Metal pre-pass)") }
            return
        }
        let go = shared.withLock { s -> Bool in
            guard s.wantsRun, s.enabled, !s.running else { return false }
            s.running = true
            s.disabling = false
            s.startUptime = Self.uptime()
            s.plan = nil
            s.audio = nil
            return true
        }
        guard go else { return }
        LMLog.visual.info("📼 footage start (force=\(DebugLaunchOptions.videoForce) offline=\(DebugLaunchOptions.videoOffline) file=\(DebugLaunchOptions.videoFile ?? "-", privacy: .public) look=\(DebugLaunchOptions.videoLook ?? "-", privacy: .public) mix=\(DebugLaunchOptions.videoMix.map { String($0) } ?? "-", privacy: .public))")
        let prefetch = Task.detached(priority: .utility) { [weak self] () -> Void in await self?.prefetchLoop() }
        let director = Task.detached(priority: .userInitiated) { [weak self] () -> Void in await self?.directorLoop() }
        tasks.withLock { $0 = [prefetch, director] }
    }

    func stop() {
        shared.withLock { $0.wantsRun = false }
        halt()
    }

    private func halt() {
        endAudio(fade: 2)
        let wasRunning = shared.withLock { s -> Bool in
            defer { s.running = false; s.plan = nil; s.disabling = false; s.audio = nil }
            return s.running
        }
        guard wasRunning else { return }
        tasks.withLock { t in t.forEach { $0.cancel() }; t = [] }
        source?.stop()
        shared.withLock { s in if !s.enabled { s.status = "Archive footage off" } }
        LMLog.visual.info("📼 footage stop")
    }

    // MARK: - Cache (settings section)

    /// Clips and bytes in the cache.
    func cacheSummary() async -> (count: Int, bytes: Int64) {
        await store.load()
        return (await store.clips.count, await store.totalBytes)
    }

    /// Deletes every cached clip except the one on screen.
    func clearCache() async {
        let keep = shared.withLock { $0.plan?.clipID }
        await store.clear(keeping: keep)
        let n = await store.clips.count
        LMLog.visual.info("📼 cache cleared (kept \(n))")
        shared.withLock { s in if s.plan == nil && s.enabled { s.status = n == 0 ? "Fetching footage" : "\(n) clips ready" } }
    }

    // MARK: - Sound (plan 4)

    /// Decodes the moment's sound off the main actor and posts it to the music at the cue's start.
    private func scheduleAudio(plan: MomentPlan, clip: ArchiveClip, url: URL) {
        let (level, start) = shared.withLock { ($0.audioLevel, $0.startUptime) }
        guard let sink = music.withLock({ $0 }) else { return }
        guard clip.hasAudio else {
            LMLog.audio.info("📼🔊 no sound: clip has no audio track")
            return
        }
        guard let gain = ArchiveAudioCuePlan.gain(level: level) else {
            LMLog.audio.info("📼🔊 no sound: Footage audio is 0")
            return
        }
        guard let cue = ArchiveAudioCuePlan(plan: plan, clipDuration: clip.duration) else {
            LMLog.audio.info("📼🔊 no sound: moment too short")
            return
        }
        let token = audioTokenSeed.withLock { $0 += 1; return $0 }
        shared.withLock { $0.audio = AudioState(cue: cue, token: token) }
        let title = clip.title
        LMLog.audio.info("📼🔊 sound cue at \(String(format: "%.1f", cue.beginAt), privacy: .public)s fade \(String(format: "%.1f", cue.fadeIn), privacy: .public)s, out at \(String(format: "%.1f", cue.fadeOutAt), privacy: .public)s over \(String(format: "%.1f", cue.fadeOut), privacy: .public)s, source \(String(format: "%.1f", cue.sourceStart), privacy: .public)s+\(String(format: "%.1f", cue.sourceLength), privacy: .public)s rate \(String(format: "%.2f", cue.rate), privacy: .public) gain \(String(format: "%.2f", gain), privacy: .public)")
        Task.detached(priority: .utility) { [weak self] in
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
            let wait = due - Self.uptime()
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            guard let self else { return }
            let late = Self.uptime() - due
            let g = self.shared.withLock { s -> Float? in
                guard s.running, !s.disabling, var a = s.audio, a.token == token, !a.ended,
                      let g = ArchiveAudioCuePlan.gain(level: s.audioLevel) else { return nil }
                a.begun = true
                s.audio = a
                return g
            }
            guard let g else { return }
            sink.post(.archiveBegin(ArchiveVoice.Cue(buffer: buffer, gain: g, fadeIn: max(1, cue.fadeIn - max(late, 0)),
                                                     label: title)))
            if late > 0.1 { LMLog.audio.warning("📼🔊 sound started \(String(format: "%.2f", late), privacy: .public)s late") }
        }
        _ = gain
    }

    /// Fades the current moment's sound out (once).
    private func endAudio(fade: Double) {
        let post = shared.withLock { s -> Bool in
            guard var a = s.audio, !a.ended else { return false }
            a.ended = true
            s.audio = a
            return a.begun
        }
        if post { music.withLock { $0 }?.post(.archiveEnd(fade: fade)) }
    }

    // MARK: - Render loop API

    /// The footage for this frame, and the picture shown under it (for the tint). Cheap: one lock,
    /// no allocation; a new picture's tint is measured off the main actor.
    func frame(image: CGImage?) -> Frame { frame(key: image, image: { image }) }

    /// `key` identifies the picture (its tint is measured once per key); `image` is called only when it changes.
    func frame(key: AnyObject?, image: () -> CGImage?) -> Frame {
        let now = Self.uptime()
        let newKey = key.map(ObjectIdentifier.init)
        let snap = shared.withLock { s -> (plan: MomentPlan?, elapsed: Double, aspect: Float,
                                          tint: SIMD3<Float>, shade: SIMD3<Float>, measure: Bool) in
            var measure = false
            if let newKey, s.tintKey != newKey {
                s.tintKey = newKey
                measure = true
            }
            let dt = s.lastTintUptime > 0 ? min(now - s.lastTintUptime, 0.5) : 0
            s.lastTintUptime = now
            let k = Float(1 - exp(-dt / 1.0))   // about 3 s to settle (plan 2.2)
            s.tint += (s.tintTarget - s.tint) * k
            s.shade += (s.shadeTarget - s.shade) * k
            return (s.running ? s.plan : nil, now - s.startUptime, s.clipAspect, s.tint, s.shade, measure)
        }
        let measure = snap.measure ? image() : nil
        if let img = measure {
            let key = ObjectIdentifier(img)
            Task.detached(priority: .utility) { [weak self] in
                let t = VideoComposite.tint(of: img)
                self?.shared.withLock { s in
                    guard s.tintKey == key else { return }
                    s.tintTarget = t.tint
                    s.shadeTarget = t.shade
                }
            }
        }
        guard let plan = snap.plan, let texture = source?.latest() else { return Frame(texture: nil, state: .off) }
        let env = plan.envelope(at: snap.elapsed)
        var state = VideoCompositeState(envelope: env, look: plan.look, seed: plan.seed, aspect: snap.aspect,
                                        tint: snap.tint, shade: snap.shade)
        state.constantMix = DebugLaunchOptions.videoMix
        guard !state.isOff else { return Frame(texture: nil, state: .off) }
        return Frame(texture: texture, state: state)
    }

    /// The current stage texture (macOS binds it at draw time).
    func latestTexture() -> MTLTexture? { source?.latest() }

    /// The render loops report what the director waits on (transition, image age, music).
    func update(_ c: VideoMomentDirector.Conditions) {
        shared.withLock { $0.conditions = c }
    }

    // MARK: - Moments

    private func directorLoop() async {
        let timing: VideoMomentDirector.Timing = {
            if DebugLaunchOptions.videoMix != nil {
                // Constant mix for stills: one long moment from the start.
                var t = VideoMomentDirector.Timing.forced
                t.first = 2...2; t.length = 3600...3600; t.fadeIn = 1...1; t.fadeOut = 2...2
                return t
            }
            return DebugLaunchOptions.videoForce ? .forced : .amount(shared.withLock { $0.amount })
        }()
        let timingFollowsSetting = DebugLaunchOptions.videoMix == nil && !DebugLaunchOptions.videoForce
        let seed = DebugLaunchOptions.videoSeed.map { UInt64($0) } ?? UInt64.random(in: 0...UInt64.max)
        var director = VideoMomentDirector(seed: seed, timing: timing,
                                           pinnedLook: DebugLaunchOptions.videoLook.flatMap(VideoLook.init(name:)))
        var rng = MusicRNG(seed: seed ^ 0xA5C1_17E5)
        var lastClipID: String?
        var momentsSinceReplace = 0
        LMLog.visual.info("📼 director seed=\(seed) first moment at \(String(format: "%.0f", director.nextDue), privacy: .public)s")
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { break }
            let (running, start, cond, amount, disabling) = shared.withLock {
                ($0.running, $0.startUptime, $0.conditions, $0.amount, $0.disabling)
            }
            guard running else { break }
            let elapsed = Self.uptime() - start
            if timingFollowsSetting, director.timing != .amount(amount) { director.timing = .amount(amount) }
            if let off = DebugLaunchOptions.videoOffAt, elapsed >= off, !disabling {
                LMLog.visual.info("📼 DEBUG: footage setting off at \(String(format: "%.1f", elapsed), privacy: .public)s (-LiminalVideoOffAt)")
                let level = shared.withLock { $0.audioLevel }
                apply(enabled: false, amount: amount, audioLevel: level)
                continue
            }
            if disabling {
                // Footage turned off: fade the moment out over 2 s, then stop (the cache stays).
                if let p = director.current, p.end > elapsed + 2.1 {
                    director.fadeOut(at: elapsed, duration: 2)
                    let np = director.current
                    shared.withLock { $0.plan = np }
                    endAudio(fade: 2)
                }
                if director.current == nil || elapsed >= (director.current?.end ?? 0) {
                    halt()
                    break
                }
                continue
            }
            let clips = await availableClips()
            if director.current != nil, source?.ended == true {
                director.fadeOut(at: elapsed, duration: 4)
                let p = director.current
                shared.withLock { $0.plan = p }
                endAudio(fade: 4)
            }
            // The sound fades out with the picture's fade out (plan 4).
            if let a = shared.withLock({ $0.audio }), !a.ended, elapsed >= a.cue.fadeOutAt {
                endAudio(fade: a.cue.fadeOut)
            }
            switch director.tick(elapsed: elapsed, conditions: cond, hasClip: !clips.isEmpty) {
            case .none:
                break
            case .end:
                endAudio(fade: 1)
                source?.stop()
                shared.withLock { $0.plan = nil; $0.status = "\(clips.count) clips ready" }
                LMLog.visual.info("📼 moment end at \(String(format: "%.1f", elapsed), privacy: .public)s; next at \(String(format: "%.0f", director.nextDue), privacy: .public)s")
            case .begin(let b):
                guard let clip = VideoMomentDirector.chooseClip(clips, lastID: lastClipID, rng: &rng) else { break }
                lastClipID = clip.id
                var fadeIn = b.fadeIn, hold = b.hold, fadeOut = b.fadeOut
                let maxMoment = clip.duration / Double(b.rate) - 1
                if b.total > maxMoment {
                    // A short clip plays whole: shorten the hold (and the fades if need be).
                    let scale = min(1, maxMoment / (fadeIn + fadeOut + 4))
                    fadeIn *= scale; fadeOut *= scale
                    hold = max(maxMoment - fadeIn - fadeOut, 0)
                }
                let sourceLength = (fadeIn + hold + fadeOut) * Double(b.rate)
                let segStart = ArchiveCatalog.segmentStart(duration: clip.duration, length: sourceLength,
                                                           avoid: clip.shownStarts, rng: &rng)
                let plan = MomentPlan(clipID: clip.id, segmentStart: segStart, rate: b.rate, look: b.look,
                                      seed: b.seed, start: elapsed, fadeIn: fadeIn, hold: hold, fadeOut: fadeOut)
                director.didBegin(plan)
                scheduleAudio(plan: plan, clip: clip, url: url(for: clip))
                source?.play(.init(url: url(for: clip), start: segStart, length: min(sourceLength + 2, clip.duration - segStart),
                                   rate: b.rate, black: clip.black, white: clip.white))
                let aspect = Float(clip.width) / Float(max(clip.height, 1))
                shared.withLock {
                    $0.plan = plan
                    $0.clipAspect = aspect
                    $0.status = "Showing: \(clip.title)\(clip.year.map { " (\($0))" } ?? "")"
                }
                if !clip.id.hasPrefix("local:") { await store.markUsed(clip.id, segmentStart: segStart) }
                momentsSinceReplace += 1
                if momentsSinceReplace >= 3 {
                    momentsSinceReplace = 0
                    shared.withLock { $0.replaceRequested = true }
                }
                LMLog.visual.info("📼 moment begin #\(director.momentCount) look=\(b.look.name, privacy: .public) id=\(clip.id, privacy: .public) title=\"\(clip.title, privacy: .public)\" year=\(clip.year ?? 0) segment=\(String(format: "%.1f", segStart), privacy: .public)s+\(String(format: "%.1f", sourceLength), privacy: .public)s rate=\(String(format: "%.2f", b.rate), privacy: .public) fade=\(String(format: "%.1f", fadeIn), privacy: .public)/\(String(format: "%.1f", hold), privacy: .public)/\(String(format: "%.1f", fadeOut), privacy: .public)s at \(String(format: "%.1f", elapsed), privacy: .public)s")
            }
        }
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
        try? await Task.sleep(nanoseconds: DebugLaunchOptions.videoForce ? 1_000_000_000 : 10_000_000_000)
        var picker = CandidatePicker(seed: UInt64.random(in: 0...UInt64.max))
        var failures = 0
        var lastDownload = Date.distantPast
        while !Task.isCancelled {
            let clips = await store.clips
            let replace = shared.withLock { $0.replaceRequested }
            let full = clips.count >= ArchiveCachePolicy.poolTarget
            let sinceLast = Date().timeIntervalSince(lastDownload)
            // Below the minimum: back to back. Below the pool target: one per 90 s. Full: only to replace
            // a clip (every third moment), at most one download per 3 minutes.
            let due = clips.count < ArchiveCachePolicy.minReady
                || (!full && sinceLast >= 90)
                || (full && replace && sinceLast >= 180)
            if !due || !Self.hasFreeSpace(store.directory) {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                continue
            }
            do {
                let protected = Set(shared.withLock { $0.plan.map { [$0.clipID] } ?? [] })
                if full, replace, let victim = ArchiveCachePolicy.replacement(clips, protected: protected) {
                    await store.remove(victim)
                    LMLog.visual.info("📼 replacing most-used clip \(victim, privacy: .public)")
                }
                shared.withLock { $0.replaceRequested = false }
                try await fetchOne(picker: &picker, preferSmallest: clips.count < 2, protected: protected)
                failures = 0
                lastDownload = Date()
                let n = await store.clips.count
                shared.withLock { s in if s.plan == nil { s.status = "\(n) clips ready" } }
            } catch is CancellationError {
                break
            } catch {
                failures += 1
                let wait = ArchiveCatalog.backoff(failures: failures)
                LMLog.visual.warning("📼 fetch failed (\(String(describing: error), privacy: .public)); retry in \(Int(wait))s")
                shared.withLock { s in if s.plan == nil { s.status = "Footage offline" } }
                try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            }
        }
    }

    private static func hasFreeSpace(_ dir: URL) -> Bool {
        let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = v?.volumeAvailableCapacityForImportantUsage else { return true }
        return free > ArchiveCachePolicy.minFreeBytes
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
        init(seed: UInt64) { rng = MusicRNG(seed: seed) }
    }

    private static let rows = 50

    /// One search (or the seed list), one metadata request, one download, validation, into the store.
    private func fetchOne(picker: inout CandidatePicker, preferSmallest: Bool, protected: Set<String>) async throws {
        let cachedIDs = Set(await store.clips.map(\.id))
        let bad = await store.badIDs
        let exclude = cachedIDs.union(bad).union(picker.skipped)
        if !picker.bag.hasAny(excluding: exclude) || picker.rng.chance(0.25) {
            try await refill(&picker, firstLaunch: cachedIDs.isEmpty)
        }
        guard let id = picker.bag.next(rng: &picker.rng, excluding: exclude), let entry = picker.byID[id] else {
            throw ArchiveClientError.backend("no candidates")
        }
        let tone = ArchiveCatalog.tone(entry.doc?.color?.value ?? (entry.seed?.color == true ? "color" : nil))
        if tone == .colour && !picker.rng.chance(ArchiveCatalog.colourOdds) {
            picker.skipped.insert(id)   // colour items only at low odds (plan 1.2)
            return
        }
        let title = entry.doc?.titleText ?? entry.seed?.title ?? id
        LMLog.visual.info("📼 candidate id=\(id, privacy: .public) \"\(title, privacy: .public)\" (\(entry.doc?.yearValue ?? entry.seed?.year ?? 0)) query=\(entry.query.name, privacy: .public)")
        let meta: ArchiveItemMetadata
        do { meta = try await client.metadata(id: id) } catch let e as ArchiveClientError where e.isContentFailure {
            await store.markBad(id); throw e
        }
        guard ArchiveCatalog.accept(meta.metadata) else {
            await store.markBad(id)
            LMLog.visual.info("📼 excluded by metadata: \(id, privacy: .public)")
            return
        }
        guard let file = ArchiveCatalog.pickFile(meta.files, preferSmallest: preferSmallest) else {
            await store.markBad(id)
            LMLog.visual.info("📼 no playable file in \(id, privacy: .public)")
            return
        }
        let safe = id.replacingOccurrences(of: "/", with: "_")
        let tmp = await store.tmpDirectory.appendingPathComponent("\(safe).mp4")
        LMLog.visual.info("📼 download id=\(id, privacy: .public) file=\(file.name, privacy: .public) \(String(format: "%.1f", Double(file.bytes ?? 0) / 1e6), privacy: .public) MB")
        do { try await client.download(id: id, file: file.name, to: tmp) } catch let e as ArchiveClientError where e.isContentFailure {
            await store.markBad(id); throw e
        }
        let v: ArchiveClipValidator.Result
        do { v = try await ArchiveClipValidator.validate(tmp) } catch {
            try? FileManager.default.removeItem(at: tmp)
            await store.markBad(id)
            LMLog.visual.warning("📼 invalid clip \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        let year = meta.metadata?.year.flatMap { Int($0.value.prefix(4)) } ?? entry.doc?.yearValue ?? entry.seed?.year
        let attrs = try? FileManager.default.attributesOfItem(atPath: tmp.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? file.bytes ?? 0
        let clip = ArchiveClip(id: id, title: meta.metadata?.title?.value ?? title, year: year, fileName: "\(safe).mp4",
                               bytes: bytes,
                               duration: v.duration, width: v.width, height: v.height, hasAudio: v.hasAudio,
                               black: v.black, white: v.white,
                               isColour: ArchiveCatalog.tone(meta.metadata?.color?.value) == .colour,
                               licence: meta.metadata?.licenseurl?.value, added: Date(), lastUsed: nil, useCount: 0,
                               shownStarts: [])
        let evicted = try await store.add(clip, from: tmp, protected: protected)
        let pool = await store.clips.count
        LMLog.visual.info("📼 cached id=\(id, privacy: .public) \"\(clip.title, privacy: .public)\" (\(year ?? 0)) \(v.width)x\(v.height) \(String(format: "%.0f", v.duration), privacy: .public)s audio=\(v.hasAudio) levels=\(String(format: "%.2f", v.black), privacy: .public)-\(String(format: "%.2f", v.white), privacy: .public) evicted=\(evicted.joined(separator: ","), privacy: .public) pool=\(pool)")
    }

    /// New candidates: the bundled seeds on a first launch or when search fails, else one search of a
    /// weighted query on a random page.
    private func refill(_ p: inout CandidatePicker, firstLaunch: Bool) async throws {
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
        if firstLaunch && !p.usedSeeds { useSeeds(); return }
        let q = ArchiveCatalog.queries[p.rng.weighted(ArchiveCatalog.queries.map(\.weight))]
        let pages = ArchiveCatalog.pageCount(numFound: p.numFound[q.name] ?? Self.rows, rows: Self.rows)
        let page = p.rng.int(1...pages)
        do {
            let body = try await client.search(q, page: page, rows: Self.rows)
            p.numFound[q.name] = body.numFound
            let ok = body.docs.filter { ArchiveCatalog.accept($0, query: q) }
            for d in ok { p.byID[d.identifier] = (d, nil, q) }
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
