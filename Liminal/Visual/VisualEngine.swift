import Foundation
import Combine
import OSLog

/// On both screens the midpoint of the image exchange belongs to the audible fill.
nonisolated struct LofiImageReveal: Sendable {
    let downbeat: Double
    let duration: Double
    var start: Double { downbeat - duration / 2 }
    var spec: TransitionSpec {
        TransitionSpec(style: .classic, seed: 0, duration: Float(duration), flip: false)
    }
    func progress(at uptime: Double) -> Double { min(1, max(0, (uptime - start) / duration)) }

    static func next(on grid: LofiTakeGrid, after uptime: Double) -> Self {
        let boundary = grid.nextBoundary(after: uptime)
        return Self(downbeat: boundary.time, duration: boundary.fill.dissolveBeats * grid.beatDuration)
    }
}

/// Coordinates visual generation.
/// Advances images on a schedule; prompts come from PromptDirector inside ImageQueue.
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

    // MARK: - Configuration

    private var scheduledInterval: TimeInterval { SettingsService.shared.imageInterval }

    // MARK: - Atomic Image Buffer (for render loop - bypasses MainActor)

    /// Thread-safe buffer for the 90fps render loop.
    /// Call `imageBuffer.loadCurrent()` directly from render loop.
    /// This does NOT require MainActor and will not cause starvation.
    var imageBuffer: AtomicImageBuffer { imageQueue.imageBuffer }

    // MARK: - State (@Published for UI only - NOT for render loop)

    @Published private(set) var currentImage: PlatformImage?
    @Published private(set) var nextImage: PlatformImage?  // For morph preloading
    @Published private(set) var isGenerating: Bool = false
    @Published private(set) var totalCachedCount: Int = 0
    @Published private(set) var queuedCount: Int = 0
    /// Style, palette, moods and measured colors of the image on screen. Best effort on
    /// visionOS; the reliable read is `imageBuffer.loadCurrentMetadata()`.
    @Published private(set) var currentMetadata: ImageMetadata?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isClearing = false

    private let imageQueue = ImageQueue()
    /// One per session, shared by both platforms' crossfades (docs/plans/transitions.md 7).
    private var transitionDirector: TransitionDirector = {
        var d = TransitionDirector(seed: UInt64.random(in: 0...UInt64.max))
        if let name = DebugLaunchOptions.transitionStyle {
            if let style = TransitionStyle(name: name) { d.pinnedStyle = style }
            else { LMLog.visual.warning("Unknown -LiminalTransitionStyle \(name, privacy: .public)") }
        }
        d.pinnedSeed = DebugLaunchOptions.transitionSeed
        return d
    }()
    private var scheduledTimer: Timer?
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

        // Mirror next image for morph preloading
        imageQueue.$nextImage
            .receive(on: RunLoop.main)
            .sink { [weak self] image in
                self?.nextImage = image
            }
            .store(in: &cancellables)

        imageQueue.$isGenerating
            .receive(on: RunLoop.main)
            .sink { [weak self] generating in
                self?.isGenerating = generating
            }
            .store(in: &cancellables)

        imageQueue.$totalCachedCount
            .receive(on: RunLoop.main)
            .sink { [weak self] count in
                self?.totalCachedCount = count
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
    }

    // MARK: - Control

    func start(music: GenerativeEngine) {
        stopScheduling()
        imageQueue.start()
        if music.musicMode == .lofi {
            if !imageBuffer.hasCurrent(), let initial = imageQueue.standbyImage(index: standbyIndex) {
                imageQueue.showReserved(initial)
                standbyIndex += 1
            }
            fillTask = Task { [weak self, weak music] in
                guard let self, let music else { return }
                await scheduleFills(on: music.musicState)
            }
        } else {
            startScheduledAdvances()
        }
        LMLog.visual.info("VisualEngine started")
    }

    private func stopScheduling() {
        fillTask?.cancel()
        fillTask = nil
        stagedImage = nil
        reveal = nil
        scheduledTimer?.invalidate()
        scheduledTimer = nil
    }

    func stop() {
        stopScheduling()
        imageQueue.stop()
        LMLog.visual.info("VisualEngine stopped")
    }

    /// The transition for the crossfade that starts now (call once per crossfade).
    /// - Parameters: energy = music energy when the visuals follow the music, else nil.
    func nextTransition(effectTime: Float, intensity: Float, energy: Float?, hasDepth: Bool) -> TransitionSpec {
        if let reveal { return reveal.spec }
        let spec = transitionDirector.next(time: effectTime, intensity: intensity, energy: energy, hasDepth: hasDepth,
                                           imageInterval: Float(scheduledInterval))
        LMLog.visual.info("🌀 TRANSITION style=\(spec.style.name, privacy: .public) seed=\(String(format: "%.3f", spec.seed), privacy: .public) duration=\(String(format: "%.2f", spec.duration), privacy: .public)s flip=\(spec.flip)")
        return spec
    }

    /// Manually request the next image
    func advance() {
        guard fillTask == nil else { return }
        ArchiveFootageService.shared.queuedImage(nil)
        imageQueue.advance()
    }

    // MARK: - Cache

    /// Count and size of every cached image on disk (reads directory listings only).
    func cacheUsage() async -> ImageStore.Usage {
        let store = imageQueue.store
        return await Task.detached { store.usage() }.value
    }

    /// Deletes every cached image (files, sidecars, depth maps, legacy folders), clears the
    /// display buffers and prompt history, and restarts generation if it was running.
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
            let cue = LofiImageReveal.next(on: grid, after: max(now(), lastDownbeat + 0.01))
            ArchiveFootageService.shared.expectNextImage(after: max(0, cue.downbeat - now()))
            // Give live generation most of the phrase, with six seconds left for
            // a local decode, crop, colour analysis and both platforms' GPU upload.
            do { try await Task.sleep(for: .seconds(max(0, cue.start - now() - 6))) } catch { return }
            let cacheEpoch = imageQueue.store.clearGeneration
            let currentID = imageBuffer.displayedID()
            let prefetch = Task {
                guard !isClearing, let item = await imageQueue.reserveForFill(excluding: currentID),
                      !Task.isCancelled, imageQueue.store.clearGeneration == cacheEpoch,
                      now() < cue.start - 2 else { return }
                stagedImage = item
                ArchiveFootageService.shared.queuedImage(item.metadata)
            }
            defer { prefetch.cancel() }
            do { try await Task.sleep(for: .seconds(max(0, cue.start - now() - 2))) } catch { return }
            // A slow cache read or image generation never owns the deadline.
            if stagedImage == nil, !isClearing {
                stagedImage = imageQueue.standbyImage(index: standbyIndex)
            }
            do { try await Task.sleep(for: .seconds(max(0, cue.start - now()))) } catch { return }
            if let item = stagedImage, !isClearing, imageQueue.store.clearGeneration == cacheEpoch {
                reveal = cue
                imageQueue.showReserved(item)
                standbyIndex += 1
                LMLog.visual.info("Lo-Fi image reveal at downbeat \(cue.downbeat, format: .fixed(precision: 3)); start error \((now() - cue.start) * 1000, format: .fixed(precision: 1)) ms")
            }
            stagedImage = nil
            lastDownbeat = cue.downbeat
            // The outgoing grid may still be published in the output latency window
            // at a take switch. Read the committed new grid after its first tick.
            do { try await Task.sleep(for: .seconds(max(0, cue.downbeat + 0.25 - now()))) } catch { return }
        }
    }

    private func startScheduledAdvances() {
        let interval = scheduledInterval
        ArchiveFootageService.shared.expectNextImage(after: interval)
        scheduledTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.scheduledTimer != nil else { return }
                ArchiveFootageService.shared.expectNextImage(after: interval)
                self.imageQueue.advance()
            }
        }
    }
}
