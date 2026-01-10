import Foundation
import AppKit
import Combine
import OSLog

/// Manages crossfade transitions between images when new content arrives.
@MainActor
final class MorphPlayer: ObservableObject {

    // MARK: - Configuration

    private let targetFPS: Double = 30
    private let crossfadeDuration: Double = 1.5  // seconds for crossfade

    // MARK: - State

    @Published private(set) var currentFrame: NSImage?
    @Published private(set) var isMorphing = false
    @Published private(set) var transitionProgress: Double = 0  // 0-1, for effects to use
    @Published private(set) var poolSize = 0

    private var fromImage: NSImage?
    private var toImage: NSImage?
    private var crossfadeStartTime: Date?
    private var displayLink: Timer?

    private var imageHistory: [NSImage] = []
    private let maxHistorySize = 10

    // MARK: - Public API

    func start() {
        startDisplayLink()
        LMLog.visual.info("MorphPlayer started (crossfade mode)")
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        LMLog.visual.info("MorphPlayer stopped")
    }

    func setInitialImage(_ image: NSImage) {
        currentFrame = image
        addToHistory(image)
        poolSize = imageHistory.count
        LMLog.visual.info("Initial image set")
    }

    func transitionTo(_ newImage: NSImage) {
        guard let current = currentFrame else {
            currentFrame = newImage
            addToHistory(newImage)
            poolSize = imageHistory.count
            LMLog.visual.info("First image displayed (no transition needed)")
            return
        }

        if current.hash == newImage.hash {
            LMLog.visual.debug("Same image, skipping transition")
            return
        }

        if isMorphing {
            LMLog.visual.info("New image arrived during transition - redirecting")
            if let oldTarget = toImage {
                fromImage = oldTarget
            }
        } else {
            fromImage = current
        }

        toImage = newImage
        addToHistory(newImage)
        poolSize = imageHistory.count
        startCrossfade()
    }

    func addToPool(_ image: NSImage) {
        if currentFrame != nil {
            transitionTo(image)
        } else {
            setInitialImage(image)
        }
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
                self?.updateFrame()
            }
        }
    }

    private func startCrossfade() {
        isMorphing = true
        transitionProgress = 0
        crossfadeStartTime = Date()
        LMLog.visual.info("🎨 Starting crossfade transition...")
    }

    private func updateFrame() {
        guard isMorphing,
              let from = fromImage,
              let to = toImage,
              let startTime = crossfadeStartTime else {
            return
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let progress = min(elapsed / crossfadeDuration, 1.0)
        transitionProgress = progress

        // Generate blended frame (always use 'from' dimensions for consistency)
        if let blended = blendImages(from: from, to: to, progress: progress) {
            currentFrame = blended
        }

        // Log progress periodically
        if Int(elapsed * 10) % 5 == 0 && Int(elapsed * 10) > 0 {
            LMLog.visual.debug("🔄 CROSSFADE progress=\(String(format: "%.1f", progress * 100))%")
        }

        // Check if complete - DON'T snap to raw 'to' image, keep using blended frame
        if progress >= 1.0 {
            LMLog.visual.info("🔄 CROSSFADE COMPLETE")
            // Final frame is already the fully blended image (at from's dimensions)
            isMorphing = false
            transitionProgress = 0
            fromImage = nil
            toImage = nil
            crossfadeStartTime = nil
        }
    }

    private func blendImages(from: NSImage, to: NSImage, progress: Double) -> NSImage? {
        let easedProgress = easeInOutCubic(progress)
        let size = from.size
        let newImage = NSImage(size: size)

        newImage.lockFocus()

        // Draw 'from' image
        from.draw(in: NSRect(origin: .zero, size: size),
                  from: NSRect(origin: .zero, size: from.size),
                  operation: .copy,
                  fraction: 1.0)

        // Draw 'to' image scaled to match 'from' dimensions
        to.draw(in: NSRect(origin: .zero, size: size),
                from: NSRect(origin: .zero, size: to.size),
                operation: .sourceOver,
                fraction: CGFloat(easedProgress))

        newImage.unlockFocus()

        return newImage
    }

    private func easeInOutCubic(_ t: Double) -> Double {
        if t < 0.5 {
            return 4 * t * t * t
        } else {
            return 1 - pow(-2 * t + 2, 3) / 2
        }
    }
}
