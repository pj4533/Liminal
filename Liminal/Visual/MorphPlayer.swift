import Foundation
import AppKit
import Combine
import OSLog

/// Manages morph frame generation and playback between images.
/// Provides continuous visual movement by morphing between AI-generated images.
@MainActor
final class MorphPlayer: ObservableObject {

    // MARK: - Configuration

    private let targetFPS: Double = 30
    private let frameCount = 60  // frames per morph transition (~2 seconds at 30fps)

    // MARK: - State

    @Published private(set) var currentFrame: NSImage?
    @Published private(set) var isMorphing = false

    private var morphFrames: [NSImage] = []
    private var frameIndex = 0
    private var displayLink: Timer?
    private let morpher = RIFEMorpher()
    private var lastImage: NSImage?
    private var morphTask: Task<Void, Never>?

    // MARK: - Public API

    /// Start playing morph animations
    func start() {
        startDisplayLink()
    }

    /// Stop playback
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        morphTask?.cancel()
        morphTask = nil
    }

    /// Transition to a new image with morphing
    func transitionTo(_ newImage: NSImage) {
        guard let fromImage = lastImage ?? currentFrame else {
            // First image - just display it
            currentFrame = newImage
            lastImage = newImage
            return
        }

        // Don't start new morph if one is in progress
        guard !isMorphing else {
            // Queue this image for after current morph
            lastImage = newImage
            return
        }

        lastImage = newImage
        startMorph(from: fromImage, to: newImage)
    }

    /// Set initial image without morphing
    func setInitialImage(_ image: NSImage) {
        currentFrame = image
        lastImage = image
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

        frameIndex = (frameIndex + 1) % morphFrames.count
        currentFrame = morphFrames[frameIndex]

        // If we've completed a full cycle and there's a pending image, start new morph
        if frameIndex == 0 && !isMorphing {
            // Keep showing last frame of this cycle
            morphFrames = []
        }
    }

    private func startMorph(from: NSImage, to: NSImage) {
        isMorphing = true

        morphTask = Task {
            do {
                let frames = try await morpher.generateMorphFrames(from: from, to: to, frameCount: frameCount)

                guard !Task.isCancelled else { return }

                // Set up for playback
                morphFrames = frames
                frameIndex = 0
                currentFrame = frames.first

                LMLog.visual.info("Morph ready: \(frames.count) frames")
            } catch {
                LMLog.visual.error("Morph failed: \(error.localizedDescription)")
                // Fallback: just show the new image
                currentFrame = to
                morphFrames = []
            }

            isMorphing = false
        }
    }
}
