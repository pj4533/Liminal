import Foundation
import Combine
import OSLog

/// A Lo-Fi image change timed to the drums (docs/plans/drop-transitions.md).
///
/// A drop (the default): the outgoing picture starts breaking up when the outgoing take's fill starts,
/// gets more broken up through the fill, and the new picture is cut in, clean, on the audible downbeat of
/// the next section. "Fade out, but no fade in." The renderers evaluate it at the time their frame reaches
/// the display (`displayLead`), so the first clean frame lands on the hit.
///
/// The bell (`-LiminalDropOff YES`, T43): the end of the style's swap window on the downbeat, then the settle.
nonisolated struct LofiImageReveal: Sendable {
    let downbeat: Double
    /// Uptime of the fill's start (a drop's progress 0); for a bell, its start.
    let fillStart: Double
    let spec: TransitionSpec
    /// Uptime of the fill's attacks, ascending (at most 32).
    var hits: [Double] = []
    var fill: LofiFill = .turnaround

    /// The image is picked up and uploaded this long before the build's first visible change (T39 hitch).
    static let preRoll = 0.15

    /// Seconds from a frame's draw to its presentation (docs/plans/drop-transitions.md 3.2): macOS 25 ms
    /// (a measured value replaces it once the presented handler has seen frames); visionOS 28 ms, an
    /// estimate (two 90 Hz frames plus half a frame) that only a device can check. `-LiminalDropLead`.
    static var displayLead: Double {
        if let l = DebugLaunchOptions.dropLead { return l }
        #if os(visionOS)
        return 0.028
        #else
        return 0.025
        #endif
    }

    /// The display lead without its half-frame early bias: when a frame evaluated now is actually shown
    /// (visionOS: two 90 Hz frames, 22 ms, an estimate). The recorder stamps visionOS frames with it.
    static var presentationLatency: Double {
        #if os(visionOS)
        return displayLead - 0.5 / 90
        #else
        return displayLead - 0.5 / 60
        #endif
    }

    var isDrop: Bool { spec.drop != nil }
    var duration: Double { isDrop ? downbeat - fillStart : Double(spec.duration) }
    /// When the image is shown (the crossfade machinery starts): the pre-roll before a drop's build.
    var start: Double { isDrop ? fillStart - Self.preRoll : fillStart }

    func progress(at uptime: Double) -> Double { min(1, max(0, rawProgress(uptime))) }

    private func rawProgress(_ t: Double) -> Double { (t - fillStart) / max(duration, 1e-3) }

    /// The drop frame presented at `t` (uptime): progress, cut, the hit transient and the step counter.
    func frame(presentedAt t: Double) -> DropFrame {
        var n = 0
        var last: Double?
        for h in hits where h <= t { n += 1; last = h }
        return DropFrame.make(progress: rawProgress(t), build: duration, hitsBefore: n, sinceLastHit: last.map { t - $0 })
    }

    /// The bell reveal of T43: the swap ends on the downbeat.
    static func bell(downbeat: Double, spec: TransitionSpec) -> Self {
        Self(downbeat: downbeat, fillStart: downbeat - Double(spec.style.shape.s1) * Double(spec.duration), spec: spec)
    }

    /// Shortest time between planning and the downbeat that still gets a drop; later boundaries are skipped
    /// (late is worse than missing).
    static let minimumPlanning = 0.6

    /// The next drum boundary after `uptime` and its reveal, or nil when it is too close to plan.
    /// - Parameters: fills = the audible take's fills (nil: the default builds); hasDrums = recorded drum
    ///   takes are playing; pickDrop(build, fill, strength) and pickBell(holdSeconds) ask the director.
    static func next(on grid: LofiTakeGrid, after uptime: Double, now: Double, fills: LofiTakeFills?, hasDrums: Bool,
                     drop: Bool = true,
                     pickDrop: (_ build: Double, _ fill: LofiFill, _ strength: Float) -> TransitionSpec,
                     pickBell: (_ holdSeconds: Double) -> TransitionSpec) -> (boundary: Double, reveal: Self?) {
        let boundary = grid.nextBoundary(after: uptime)
        // Boundaries after the turnaround run at the committed new tempo (`nextBoundary`).
        let inTake = boundary.time <= grid.origin + 64 * grid.beatDuration + 1e-9
        let beat = inTake ? grid.beatDuration : grid.nextBeatDuration ?? grid.beatDuration
        guard drop else {
            return (boundary.time, bell(downbeat: boundary.time, spec: beatAligned(pickBell(32 * beat), beat: beat)))
        }
        guard boundary.time - now >= minimumPlanning else { return (boundary.time, nil) }
        let b: Double = boundary.fill == .halfway ? 32 : 64
        // The fill belongs to the take that plays it; past this take the default build is used.
        let takeFills = inTake && hasDrums ? fills ?? .defaults : .defaults
        let startBeat = LofiFillDetector.clampedStartBeat(takeFills.startBeat(boundary.fill), boundary: b, beatDuration: beat)
        var fillStart = boundary.time - (b - startBeat) * beat
        fillStart = max(fillStart, now + preRoll)
        let hits = inTake && hasDrums
            ? takeFills.hits(boundary.fill).map { boundary.time - (b - $0) * beat }.filter { $0 >= fillStart }
            : []
        let strength: Float = boundary.fill == .turnaround && hasDrums ? 1 : DropPlan.halfwayStrength
        let spec = pickDrop(boundary.time - fillStart, boundary.fill, strength)
        return (boundary.time, Self(downbeat: boundary.time, fillStart: fillStart, spec: spec, hits: hits, fill: boundary.fill))
    }

    /// Snaps the lead-in (start to downbeat) to whole beats, at least two, so the surge begins on a beat of the fill.
    static func beatAligned(_ spec: TransitionSpec, beat: Double) -> TransitionSpec {
        var s = spec
        let end = Double(max(spec.style.shape.s1, 0.05))
        let beats = max(2, (Double(spec.duration) * end / beat).rounded())
        s.duration = Float(beats * beat / end)
        return s
    }
}

/// Coordinates the pictures: reveals a curated picture from ImageQueue on each drum boundary.
///
/// ARCHITECTURE NOTE for visionOS:
/// The 90fps TimelineView render loop should NOT read from @Published properties.
/// Those require MainActor scheduling, which is starved by the render loop itself.
///
/// Instead, the render loop should read from `imageBuffer` directly:
///   let image = visualEngine.imageBuffer.loadCurrent()
///
/// This bypasses MainActor entirely and uses a lock-free atomic read.
@MainActor
final class VisualEngine: ObservableObject {

    // MARK: - Atomic Image Buffer (for render loop - bypasses MainActor)

    /// Thread-safe buffer for the 90fps render loop.
    /// Call `imageBuffer.loadCurrent()` directly from render loop.
    /// This does NOT require MainActor and will not cause starvation.
    var imageBuffer: AtomicImageBuffer { imageQueue.imageBuffer }

    // MARK: - State (@Published for UI only - NOT for render loop)

    @Published private(set) var currentImage: PlatformImage?
    /// Pictures saved in the pool.
    @Published private(set) var poolCount: Int = 0
    @Published private(set) var queuedCount: Int = 0
    /// Credit and measurements of the picture on screen. Best effort on
    /// visionOS; the reliable read is `imageBuffer.loadCurrentMetadata()`.
    @Published private(set) var currentMetadata: ImageMetadata?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isClearing = false
    /// The collections status line (nil until the feed has run).
    @Published private(set) var sourceStatus: (text: String, ok: Bool)?

    private let imageQueue = ImageQueue()
    /// One per session, shared by both platforms' crossfades (docs/plans/transitions.md 7).
    private var transitionDirector: TransitionDirector = {
        var d = TransitionDirector(seed: UInt64.random(in: 0...UInt64.max))
        if let name = DebugLaunchOptions.transitionStyle {
            if let style = TransitionStyle(name: name) { d.pinnedStyle = style }
            else { LMLog.visual.warning("Unknown -LiminalTransitionStyle \(name, privacy: .public)") }
        }
        d.pinnedSeed = DebugLaunchOptions.transitionSeed
        if let name = DebugLaunchOptions.dropColour {
            if let c = DropColour(name: name) { d.pinnedColour = c }
            else { LMLog.visual.warning("Unknown -LiminalDropColour \(name, privacy: .public)") }
        }
        if let name = DebugLaunchOptions.dropFinisher {
            if let f = DropFinisher(name: name) { d.pinnedFinisher = f }
            else { LMLog.visual.warning("Unknown -LiminalDropFinisher \(name, privacy: .public)") }
        }
        return d
    }()
    private var fillTask: Task<Void, Never>?
    @Published private(set) var stagedImage: ImageQueue.DisplayItem?
    private(set) var reveal: LofiImageReveal?
    private var standbyIndex = 0

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        setupQueueObservation()
    }

    // MARK: - Setup

    private func setupQueueObservation() {
        // Mirror queue's current image
        imageQueue.$currentImage
            .sink { [weak self] image in
                self?.currentImage = image
            }
            .store(in: &cancellables)

        imageQueue.$poolCount
            .receive(on: RunLoop.main)
            .sink { [weak self] count in
                self?.poolCount = count
            }
            .store(in: &cancellables)

        imageQueue.$queuedCount
            .receive(on: RunLoop.main)
            .sink { [weak self] count in
                self?.queuedCount = count
            }
            .store(in: &cancellables)

        imageQueue.$currentMetadata
            .receive(on: RunLoop.main)
            .sink { [weak self] metadata in
                self?.currentMetadata = metadata
            }
            .store(in: &cancellables)

        imageQueue.$statusMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                self?.statusMessage = message
            }
            .store(in: &cancellables)

        imageQueue.$sourceStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.sourceStatus = status
            }
            .store(in: &cancellables)
    }

    // MARK: - Control

    func start(music: GenerativeEngine) {
        stopScheduling()
        imageQueue.start()
        if !imageBuffer.hasCurrent(), let initial = imageQueue.standbyImage(index: standbyIndex) {
            imageQueue.showReserved(initial)
            standbyIndex += 1
        }
        fillTask = Task { [weak self, weak music] in
            guard let self, let music else { return }
            await scheduleFills(on: music.musicState)
        }
        LMLog.visual.info("VisualEngine started")
    }

    private func stopScheduling() {
        fillTask?.cancel()
        fillTask = nil
        stagedImage = nil
        reveal = nil
    }

    func stop() {
        stopScheduling()
        imageQueue.stop()
        LMLog.visual.info("VisualEngine stopped")
    }

    /// The transition for the crossfade that starts now (call once per crossfade).
    /// - Parameters: energy = music energy when the visuals follow the music, else nil.
    func nextTransition(effectTime: Float, intensity: Float, energy: Float?, hasDepth: Bool) -> TransitionSpec {
        pickContext = (effectTime, intensity, energy, hasDepth)
        if let reveal { return reveal.spec }
        return pickTransition()
    }

    /// The renderers' latest inputs to `nextTransition`; a Lo-Fi reveal is chosen ahead of its crossfade with these.
    private var pickContext: (effectTime: Float, intensity: Float, energy: Float?, hasDepth: Bool) =
        (0, DebugLaunchOptions.effectIntensity(setting: SettingsService.shared.effectIntensity), nil, false)

    /// - Parameter holdSeconds: seconds the picture stays (a bell reveal passes its 32 beats).
    private func pickTransition(holdSeconds: Double = 30) -> TransitionSpec {
        let c = pickContext
        let spec = transitionDirector.next(time: c.effectTime, intensity: c.intensity, energy: c.energy,
                                           hasDepth: c.hasDepth, holdSeconds: Float(holdSeconds))
        LMLog.visual.info("🌀 TRANSITION style=\(spec.style.name, privacy: .public) seed=\(String(format: "%.3f", spec.seed), privacy: .public) duration=\(String(format: "%.2f", spec.duration), privacy: .public)s flip=\(spec.flip)")
        return spec
    }

    private func pickDrop(build: Double, fill: LofiFill, strength: Float) -> TransitionSpec {
        let c = pickContext
        let spec = transitionDirector.nextDrop(time: c.effectTime, intensity: c.intensity, build: Float(build),
                                               halfway: fill == .halfway, strength: strength)
        let plan = spec.drop
        LMLog.visual.info("🌀 TRANSITION drop style=\(spec.style.name, privacy: .public) colour=\(plan?.colour.name ?? "-", privacy: .public) finisher=\(plan?.finisher.name ?? "-", privacy: .public) build=\(String(format: "%.2f", build), privacy: .public)s strength=\(String(format: "%.2f", strength), privacy: .public) seed=\(String(format: "%.3f", spec.seed), privacy: .public)")
        return spec
    }

    // MARK: - Cache

    /// Count and size of the pool's pictures on disk.
    func cacheUsage() async -> ImageStore.Usage {
        let pool = imageQueue.feed.pool
        return await Task.detached {
            pool.loadIfNeeded()
            return pool.usage()
        }.value
    }

    /// Deletes every pool picture and the ledger, clears the display buffers, and restarts
    /// fetching if it was running.
    func clearAllImages() async {
        guard !isClearing else { return }
        stagedImage = nil
        isClearing = true
        defer { isClearing = false }
        await imageQueue.clearAllImages()
    }

    // MARK: - Private

    private func scheduleFills(on bus: MusicStateBus) async {
        let now = ArchiveFootageService.uptime
        var lastDownbeat = -Double.infinity
        while !Task.isCancelled {
            guard let grid = bus.read().lofiTakeGrid else {
                try? await Task.sleep(for: .milliseconds(15))
                continue
            }
            // The audible take's fills, when the side channel describes the same take as the grid.
            let transport = bus.transport()
            let sameTake = transport.map { abs($0.origin - grid.origin) < 0.001 } ?? false
            let timing = sameTake ? transport?.timing : nil
            let hasDrums = timing.map { !$0.landmarks.isEmpty } ?? false
            let planned = LofiImageReveal.next(
                on: grid, after: max(now(), lastDownbeat + 0.01), now: now(), fills: timing?.fills, hasDrums: hasDrums,
                drop: !DebugLaunchOptions.dropOff,
                pickDrop: { pickDrop(build: $0, fill: $1, strength: $2) },
                pickBell: { pickTransition(holdSeconds: $0) })
            guard let cue = planned.reveal else {
                // Too close to plan a build: the picture stays for this boundary.
                LMLog.visual.info("Lo-Fi image reveal skipped: downbeat \(planned.boundary, format: .fixed(precision: 3)) is \((planned.boundary - now()) * 1000, format: .fixed(precision: 0)) ms away")
                lastDownbeat = planned.boundary
                do { try await Task.sleep(for: .seconds(max(0, planned.boundary + 0.25 - now()))) } catch { return }
                continue
            }
            // The renderers build this drop's specialized pipelines in the background, well before the fill.
            DropPipelines.announce(cue.spec)
            // Reserve six seconds ahead, for a local decode, crop, colour analysis and both
            // platforms' GPU upload.
            do { try await Task.sleep(for: .seconds(max(0, cue.start - now() - 6))) } catch { return }
            // The pool's clear generation: a clear while the picture is staged keeps it off screen.
            let store = imageQueue.feed.pool.store
            let cacheEpoch = store.clearGeneration
            let sameEpoch = { store.clearGeneration == cacheEpoch }
            let currentID = imageBuffer.displayedID()
            let prefetch = Task {
                guard !isClearing, let item = await imageQueue.reserveForFill(excluding: currentID),
                      !Task.isCancelled, sameEpoch(),
                      now() < cue.start - 2 else { return }
                stagedImage = item
            }
            defer { prefetch.cancel() }
            do { try await Task.sleep(for: .seconds(max(0, cue.start - now() - 2))) } catch { return }
            // A slow pool read never owns the deadline.
            if stagedImage == nil, !isClearing {
                stagedImage = imageQueue.standbyImage(index: standbyIndex)
            }
            do { try await Task.sleep(for: .seconds(max(0, cue.start - now()))) } catch { return }
            // Route recovery re-arms the transport on a new origin: a cue planned on the old grid is re-planned.
            if let fresh = bus.read().lofiTakeGrid, abs(fresh.nextBoundary(after: now()).time - cue.downbeat) > 0.001 {
                LMLog.visual.info("Lo-Fi image reveal re-planned: the take grid moved")
                continue
            }
            if let item = stagedImage, !isClearing, sameEpoch() {
                reveal = cue
                imageQueue.showReserved(item)
                standbyIndex += 1
                LMLog.visual.info("Lo-Fi image reveal at downbeat \(cue.downbeat, format: .fixed(precision: 3)); start error \((now() - cue.start) * 1000, format: .fixed(precision: 1)) ms; \(cue.isDrop ? "drop" : "bell", privacy: .public) build \(cue.duration, format: .fixed(precision: 2)) s, \(cue.hits.count) hits")
            }
            stagedImage = nil
            lastDownbeat = cue.downbeat
            // The outgoing grid may still be published in the output latency window
            // at a take switch. Read the committed new grid after its first tick.
            do { try await Task.sleep(for: .seconds(max(0, cue.downbeat + 0.25 - now()))) } catch { return }
        }
    }
}
