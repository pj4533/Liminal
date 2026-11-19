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
    /// Seconds of the running crossfade: the transition spec's duration (docs/plans/transitions.md 7.2).
    private var crossfadeDuration: Double = VisualMoodBuilder.crossfadeDuration

    // MARK: - Published State

    /// The current target image (what we're transitioning TO, or current if not transitioning)
    @Published private(set) var currentFrame: PlatformImage?
    /// The previous image (what we're transitioning FROM) - for GPU shader blending
    @Published private(set) var previousFrame: PlatformImage?
    /// Saliency map for current target image
    @Published private(set) var currentSaliencyMap: CGImage?
    @Published private(set) var isMorphing = false
    /// Transition progress 0-1, passed to GPU shader for crossfade blending
    @Published private(set) var transitionProgress: Double = 0

    // MARK: - Private State

    private var fromImage: PlatformImage?
    private var toImage: PlatformImage?
    private var crossfadeStartTime: Date?
    private(set) var beatReveal: LofiImageReveal?
    private var displayLink: Timer?
    private var saliencyTarget: PlatformImage?
    private var preparedSaliency: CGImage?
    private var saliencyTask: Task<Void, Never>?

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

        applySaliency(for: image)
    }

    /// - Returns: true when a crossfade started (false for the first image and for the same image).
    @discardableResult
    /// - Parameter duration: asked only when a crossfade actually starts (the caller picks the transition there).
    func transitionTo(_ newImage: PlatformImage, reveal: LofiImageReveal? = nil, duration: () -> Double = { VisualMoodBuilder.crossfadeDuration }) -> Bool {
        guard let current = currentFrame else {
            currentFrame = newImage
            LMLog.visual.info("First image displayed (no transition needed)")

            applySaliency(for: newImage)
            return false
        }

        if current.hash == newImage.hash {
            LMLog.visual.debug("Same image, skipping transition")
            return false
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
        crossfadeDuration = max(duration(), 0.1)
        beatReveal = reveal
        startCrossfade()

        applySaliency(for: newImage)
        return true
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
        fromImage = nil
        toImage = nil
        crossfadeStartTime = nil
        beatReveal = nil
        saliencyTask?.cancel()
        saliencyTask = nil
        saliencyTarget = nil
        preparedSaliency = nil
        LMLog.visual.info("TimerDrivenCrossfade reset")
    }

    // MARK: - Private

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
        transitionProgress = beatReveal.map { max(0.000001, $0.progress(at: ArchiveFootageService.uptime())) } ?? 0
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
        let progress = beatReveal?.progress(at: ArchiveFootageService.uptime()) ?? min(elapsed / crossfadeDuration, 1.0)

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

    func prepareSaliency(for image: PlatformImage, pixels: CGImage) {
        guard saliencyTarget !== image else { return }
        saliencyTask?.cancel()
        saliencyTarget = image
        preparedSaliency = nil
        saliencyTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let map = await DepthAnalyzer.shared.analyzeDepth(from: pixels)
            guard !Task.isCancelled, let self, saliencyTarget === image else { return }
            preparedSaliency = map
            if currentFrame === image { currentSaliencyMap = map }
        }
    }

    private func applySaliency(for image: PlatformImage) {
        if saliencyTarget === image {
            currentSaliencyMap = preparedSaliency
        } else {
            currentSaliencyMap = nil
            if let pixels = image.cgImageRepresentation { prepareSaliency(for: image, pixels: pixels) }
        }
    }
}

#endif
