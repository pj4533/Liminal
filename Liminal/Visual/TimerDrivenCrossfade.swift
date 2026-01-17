#if os(macOS)

import Foundation
import AppKit
import Combine
import OSLog

/// Timer-driven crossfade manager for macOS.
/// Uses @Published properties and Timer for transition progression.
/// This pattern works well at 60fps where MainActor has capacity.
///
/// The GPU shader handles the actual blending using transitionProgress and previousFrame.
/// This class just tracks images and progress timing.
@MainActor
final class TimerDrivenCrossfade: ObservableObject {

    // MARK: - Configuration

    private let targetFPS: Double = 30
    private let crossfadeDuration: Double = 1.5  // seconds for crossfade

    // MARK: - Published State

    /// The current target image (what we're transitioning TO, or current if not transitioning)
    @Published private(set) var currentFrame: PlatformImage?
    /// The previous image (what we're transitioning FROM) - for GPU shader blending
    @Published private(set) var previousFrame: PlatformImage?
    /// Saliency map for current target image
    @Published private(set) var currentSaliencyMap: PlatformImage?
    @Published private(set) var isMorphing = false
    /// Transition progress 0-1, passed to GPU shader for crossfade blending
    @Published private(set) var transitionProgress: Double = 0
    @Published private(set) var poolSize = 0

    // MARK: - Private State

    private var fromImage: PlatformImage?
    private var toImage: PlatformImage?
    private var crossfadeStartTime: Date?
    private var displayLink: Timer?

    private var imageHistory: [PlatformImage] = []
    private let maxHistorySize = 10

    // MARK: - Public API

    func start() {
        startDisplayLink()
        LMLog.visual.info("TimerDrivenCrossfade started")
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        LMLog.visual.info("TimerDrivenCrossfade stopped")
    }

    func setInitialImage(_ image: PlatformImage) {
        LMLog.visual.info("Setting initial image")
        currentFrame = image
        addToHistory(image)
        poolSize = imageHistory.count

        Task {
            await generateSaliencyMap(for: image)
        }
    }

    func transitionTo(_ newImage: PlatformImage) {
        guard let current = currentFrame else {
            currentFrame = newImage
            addToHistory(newImage)
            poolSize = imageHistory.count
            LMLog.visual.info("First image displayed (no transition needed)")

            Task {
                await generateSaliencyMap(for: newImage)
            }
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

        Task {
            await generateSaliencyMap(for: newImage)
        }
    }

    func addToPool(_ image: PlatformImage) {
        if currentFrame != nil {
            transitionTo(image)
        } else {
            setInitialImage(image)
        }
    }

    /// Reset all state - used when cache is cleared
    func reset() {
        currentFrame = nil
        previousFrame = nil
        currentSaliencyMap = nil
        isMorphing = false
        transitionProgress = 0
        poolSize = 0
        fromImage = nil
        toImage = nil
        crossfadeStartTime = nil
        imageHistory.removeAll()
        LMLog.visual.info("TimerDrivenCrossfade reset")
    }

    // MARK: - Private

    private func addToHistory(_ image: PlatformImage) {
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

        // Set previousFrame for GPU shader blending
        // Store the "from" image so shader can blend between previous and current
        previousFrame = fromImage

        // Set currentFrame to target immediately - shader handles the blend
        if let target = toImage {
            currentFrame = target
        }

        LMLog.visual.info("Starting crossfade transition...")
    }

    private func updateFrame() {
        guard isMorphing,
              let startTime = crossfadeStartTime else {
            return
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let progress = min(elapsed / crossfadeDuration, 1.0)

        // Update progress for GPU shader blending
        transitionProgress = progress

        // Log progress periodically
        if Int(elapsed * 10) % 5 == 0 && Int(elapsed * 10) > 0 {
            LMLog.visual.debug("CROSSFADE progress=\(String(format: "%.1f", progress * 100))%")
        }

        // Check if complete
        if progress >= 1.0 {
            LMLog.visual.info("CROSSFADE COMPLETE")
            isMorphing = false
            transitionProgress = 0
            previousFrame = nil  // Clear previousFrame when transition completes
            fromImage = nil
            toImage = nil
            crossfadeStartTime = nil
        }
    }

    // MARK: - Saliency Analysis

    private func generateSaliencyMap(for image: PlatformImage) async {
        let startTime = Date()

        if let saliencyMap = await DepthAnalyzer.shared.analyzeDepth(from: image) {
            await MainActor.run {
                self.currentSaliencyMap = saliencyMap
            }
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            LMLog.visual.info("Saliency map generated in \(String(format: "%.0f", elapsed))ms")
        } else {
            LMLog.visual.warning("Failed to generate saliency map")
        }
    }
}

#endif
