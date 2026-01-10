import Foundation
import AppKit
import Combine
import OSLog

/// Manages morphing between images when new content arrives.
/// Morphs are meaningful transitions to fresh content, not busy cycling.
@MainActor
final class MorphPlayer: ObservableObject {

    // MARK: - Configuration

    private let targetFPS: Double = 30
    private let frameCount = 120  // frames per morph transition (~4 seconds at 30fps - slow dreamy)

    // MARK: - State

    @Published private(set) var currentFrame: NSImage?
    @Published private(set) var isMorphing = false
    @Published private(set) var poolSize = 0

    private var morphFrames: [NSImage] = []
    private var frameIndex = 0
    private var displayLink: Timer?
    private let morpher = NativeMorpher()
    private var morphTask: Task<Void, Never>?

    // Track images we've shown (for potential future features)
    private var imageHistory: [NSImage] = []
    private let maxHistorySize = 10

    // MARK: - Public API

    /// Start the display link for frame playback
    func start() {
        startDisplayLink()
        LMLog.visual.info("MorphPlayer started")
    }

    /// Stop playback
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        morphTask?.cancel()
        morphTask = nil
        LMLog.visual.info("MorphPlayer stopped")
    }

    /// Set initial image without morphing
    func setInitialImage(_ image: NSImage) {
        currentFrame = image
        addToHistory(image)
        poolSize = imageHistory.count
        LMLog.visual.info("Initial image set")
    }

    /// Transition to a new image with a morph
    func transitionTo(_ newImage: NSImage) {
        // If we don't have a current image, just display the new one
        guard let fromImage = currentFrame else {
            currentFrame = newImage
            addToHistory(newImage)
            poolSize = imageHistory.count
            LMLog.visual.info("First image displayed (no morph needed)")
            return
        }

        // Don't morph to the same image
        if fromImage.hash == newImage.hash {
            LMLog.visual.debug("Same image, skipping morph")
            return
        }

        // If already morphing, queue this as the target (cancel current morph)
        if isMorphing {
            LMLog.visual.info("New image arrived during morph - redirecting to new target")
            morphTask?.cancel()
            morphFrames = []
            frameIndex = 0
        }

        addToHistory(newImage)
        poolSize = imageHistory.count
        startMorph(from: fromImage, to: newImage)
    }

    /// Legacy method - now just calls transitionTo
    func addToPool(_ image: NSImage) {
        // Only start morphing if we already have an image displayed
        if currentFrame != nil {
            transitionTo(image)
        } else {
            setInitialImage(image)
        }
    }

    /// Legacy method - now just calls transitionTo
    func preloadMorphTo(_ upcomingImage: NSImage) {
        // With the new architecture, preloading is less useful since we morph immediately
        // Just treat it as a transition
        transitionTo(upcomingImage)
    }

    // MARK: - Private

    private func addToHistory(_ image: NSImage) {
        imageHistory.append(image)
        while imageHistory.count > maxHistorySize {
            imageHistory.removeFirst()
        }
    }

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

            // Log progress every 30 frames
            if frameIndex % 30 == 0 {
                LMLog.visual.debug("Morph progress: \(self.frameIndex)/\(self.morphFrames.count - 1)")
            }
        } else {
            // Morph complete!
            LMLog.visual.info("✨ Morph complete")
            currentFrame = morphFrames[frameIndex]
            morphFrames = []
            frameIndex = 0
            isMorphing = false
            // Stay on this image until new content arrives
        }
    }

    private func startMorph(from fromImage: NSImage, to toImage: NSImage) {
        isMorphing = true
        LMLog.visual.info("🎨 Starting morph to new image...")

        morphTask = Task {
            do {
                let frames = try await morpher.generateMorphFrames(from: fromImage, to: toImage, frameCount: frameCount)

                guard !Task.isCancelled else { return }

                morphFrames = frames
                frameIndex = 0
                if let firstFrame = frames.first {
                    currentFrame = firstFrame
                }

                LMLog.visual.info("Morph ready: \(frames.count) frames - starting playback")
            } catch {
                LMLog.visual.error("Morph failed: \(error.localizedDescription)")
                // Fallback: just show the new image
                currentFrame = toImage
                isMorphing = false
            }
        }
    }
}
