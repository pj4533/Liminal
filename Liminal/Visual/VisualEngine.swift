import Foundation
import Combine
import OSLog

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
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        setupQueueObservation()
    }

    // MARK: - Setup

    private func setupQueueObservation() {
        // Mirror queue's current image
        imageQueue.$currentImage
            .receive(on: RunLoop.main)
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

    func start() {
        guard EnvironmentService.shared.hasValidCredentials else {
            LMLog.visual.warning("Cannot start VisualEngine: missing API key")
            return
        }

        imageQueue.start()
        startScheduledAdvances()
        LMLog.visual.info("VisualEngine started")
    }

    func stop() {
        scheduledTimer?.invalidate()
        scheduledTimer = nil
        imageQueue.stop()
        LMLog.visual.info("VisualEngine stopped")
    }

    /// The transition for the crossfade that starts now (call once per crossfade).
    /// - Parameters: energy = music energy when the visuals follow the music, else nil.
    func nextTransition(effectTime: Float, intensity: Float, energy: Float?, hasDepth: Bool) -> TransitionSpec {
        let spec = transitionDirector.next(time: effectTime, intensity: intensity, energy: energy, hasDepth: hasDepth,
                                           imageInterval: Float(scheduledInterval))
        LMLog.visual.info("🌀 TRANSITION style=\(spec.style.name, privacy: .public) seed=\(String(format: "%.3f", spec.seed), privacy: .public) duration=\(String(format: "%.2f", spec.duration), privacy: .public)s flip=\(spec.flip)")
        return spec
    }

    /// Manually request the next image
    func advance() {
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
        isClearing = true
        defer { isClearing = false }
        await imageQueue.clearAllImages()
    }

    // MARK: - Private

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
