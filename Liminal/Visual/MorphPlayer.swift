import Foundation
import AppKit
import Combine
import OSLog

/// Manages continuous morphing between queued images.
/// Always morphing, always psychedelic. Images flow through like a dream.
@MainActor
final class MorphPlayer: ObservableObject {

    // MARK: - Configuration

    private let targetFPS: Double = 30
    private let frameCount = 60  // frames per morph transition (~2 seconds at 30fps)
    private let maxPoolSize = 20  // Keep last N images

    // MARK: - State

    @Published private(set) var currentFrame: NSImage?
    @Published private(set) var isMorphing = false
    @Published private(set) var isPreloading = false
    @Published private(set) var poolSize = 0

    private var morphFrames: [NSImage] = []
    private var frameIndex = 0
    private var displayLink: Timer?
    private let morpher = NativeMorpher()
    private var lastImage: NSImage?
    private var morphTask: Task<Void, Never>?

    // Pool of images to morph between (grows over time, cycles through)
    private var imagePool: [NSImage] = []
    private var currentPoolIndex = 0

    // Pre-cached morph sequences: [nextImage hash -> frames]
    private var preloadedMorphs: [Int: [NSImage]] = [:]
    private var preloadTask: Task<Void, Never>?

    // MARK: - Public API

    /// Start playing morph animations
    func start() {
        startDisplayLink()
        LMLog.visual.info("MorphPlayer started - continuous morphing enabled")
    }

    /// Stop playback
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        morphTask?.cancel()
        morphTask = nil
        preloadTask?.cancel()
        preloadTask = nil
        preloadedMorphs.removeAll()
        // Keep the image pool for next session!
        LMLog.visual.info("MorphPlayer stopped (pool retained: \(self.imagePool.count) images)")
    }

    /// Add an image to the pool. Starts morphing automatically when we have 2+ images.
    func addToPool(_ image: NSImage) {
        // Don't add duplicates
        if imagePool.contains(where: { $0.hash == image.hash }) {
            LMLog.visual.debug("Image already in pool, skipping")
            return
        }

        imagePool.append(image)
        poolSize = imagePool.count
        LMLog.visual.info("Image added to pool. Pool size: \(self.imagePool.count)")

        // Trim pool if too large
        while imagePool.count > maxPoolSize {
            imagePool.removeFirst()
            poolSize = imagePool.count
            LMLog.visual.debug("Pool trimmed to \(self.maxPoolSize)")
        }

        // If this is the first image, display it
        if currentFrame == nil {
            currentFrame = image
            lastImage = image
            currentPoolIndex = imagePool.count - 1
            LMLog.visual.info("First image displayed from pool")
        }

        // If we have 2+ images and not morphing, start the continuous morph
        if imagePool.count >= 2 && morphFrames.isEmpty && !isMorphing {
            startNextMorph()
        }

        // Preload if we're idle
        if morphFrames.isEmpty && !isPreloading {
            preloadNextMorph()
        }
    }

    /// Notify of upcoming image - adds to pool
    func preloadMorphTo(_ upcomingImage: NSImage) {
        addToPool(upcomingImage)
    }

    /// Transition to a new image - adds to pool
    func transitionTo(_ newImage: NSImage) {
        addToPool(newImage)
    }

    /// Set initial image without morphing
    func setInitialImage(_ image: NSImage) {
        currentFrame = image
        lastImage = image
        LMLog.visual.debug("Initial image set")
    }

    // MARK: - Private

    private func startDisplayLink() {
        displayLink?.invalidate()
        displayLink = Timer.scheduledTimer(withTimeInterval: 1.0 / targetFPS, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advanceFrame()
            }
        }
    }

    private func advanceFrame() {
        guard !morphFrames.isEmpty else { return }

        // Advance to next frame
        if frameIndex < morphFrames.count - 1 {
            frameIndex += 1
            currentFrame = morphFrames[frameIndex]

            // Log progress every 20 frames
            if frameIndex % 20 == 0 {
                LMLog.visual.debug("Morph progress: \(self.frameIndex)/\(self.morphFrames.count - 1)")
            }
        } else {
            // Morph complete!
            LMLog.visual.info("Morph complete - pool[\(self.currentPoolIndex)]")
            currentFrame = morphFrames[frameIndex]
            lastImage = currentFrame
            morphFrames = []
            frameIndex = 0

            // CONTINUOUS MORPHING: Immediately start next morph if we have 2+ images in pool
            if imagePool.count >= 2 {
                startNextMorph()
            } else {
                LMLog.visual.info("Waiting for more images in pool...")
            }
        }
    }

    private func getNextPoolIndex() -> Int {
        // Cycle through the pool
        return (currentPoolIndex + 1) % imagePool.count
    }

    private func startNextMorph() {
        guard imagePool.count >= 2 else { return }
        guard let fromImage = lastImage ?? currentFrame else { return }

        // Get next image from pool (cycling)
        let nextIndex = getNextPoolIndex()
        let nextImage = imagePool[nextIndex]
        let key = nextImage.hash

        LMLog.visual.info("Starting morph: pool[\(self.currentPoolIndex)] → pool[\(nextIndex)]")

        // Check if we have preloaded frames for this image
        if let preloadedFrames = preloadedMorphs[key] {
            LMLog.visual.info("Using preloaded morph! \(preloadedFrames.count) frames")
            morphFrames = preloadedFrames
            frameIndex = 0
            currentFrame = preloadedFrames.first
            lastImage = nextImage
            currentPoolIndex = nextIndex
            preloadedMorphs.removeValue(forKey: key)

            // Start preloading the NEXT morph
            preloadNextMorph()
            return
        }

        // No preload - generate now
        isMorphing = true
        LMLog.visual.info("Generating morph on-demand...")

        morphTask = Task {
            do {
                let frames = try await morpher.generateMorphFrames(from: fromImage, to: nextImage, frameCount: frameCount)

                guard !Task.isCancelled else { return }

                morphFrames = frames
                frameIndex = 0
                currentFrame = frames.first
                lastImage = nextImage
                currentPoolIndex = nextIndex

                LMLog.visual.info("Morph ready: \(frames.count) frames - starting playback")

                // Preload next
                preloadNextMorph()
            } catch {
                LMLog.visual.error("Morph failed: \(error.localizedDescription)")
                // Fallback: just show the new image
                currentFrame = nextImage
                lastImage = nextImage
                currentPoolIndex = nextIndex
            }

            isMorphing = false
        }
    }

    private func preloadNextMorph() {
        guard imagePool.count >= 2 else { return }
        guard let fromImage = lastImage ?? currentFrame else { return }

        // Get the image AFTER the current morph target
        let targetIndex = getNextPoolIndex()
        let preloadIndex = (targetIndex + 1) % imagePool.count
        let nextImage = imagePool[preloadIndex]
        let key = nextImage.hash

        // Already preloaded?
        if preloadedMorphs[key] != nil {
            LMLog.visual.debug("Next morph already preloaded")
            return
        }

        // Already preloading?
        if isPreloading {
            return
        }

        isPreloading = true
        LMLog.visual.info("Preloading morph to pool[\(preloadIndex)] in background...")

        preloadTask?.cancel()
        preloadTask = Task {
            // The "from" image for preload should be the target of the current morph
            let preloadFrom = self.imagePool[targetIndex]

            do {
                let frames = try await morpher.generateMorphFrames(from: preloadFrom, to: nextImage, frameCount: frameCount)

                guard !Task.isCancelled else { return }

                preloadedMorphs[key] = frames
                LMLog.visual.info("Morph preloaded: \(frames.count) frames ready for instant use")
            } catch {
                LMLog.visual.error("Preload failed: \(error.localizedDescription)")
            }
            isPreloading = false
        }
    }
}
