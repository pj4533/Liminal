import Foundation
import AppKit
import Combine
import OSLog

/// Manages a buffer of pre-generated images for smooth visual transitions.
/// Always keeps 2-3 images ready, generating new ones in the background.
@MainActor
final class ImageQueue: ObservableObject {

    // MARK: - Configuration

    private let targetQueueSize = 3
    private let minimumQueueSize = 2

    // MARK: - State

    @Published private(set) var currentImage: NSImage?
    @Published private(set) var isGenerating = false
    @Published private(set) var queuedCount = 0

    private var imageBuffer: [NSImage] = []
    private var generationTask: Task<Void, Never>?
    private let gemini = GeminiClient()

    // MARK: - Prompt Builder

    var promptBuilder: (() -> String)?

    // MARK: - Public API

    /// Start the image generation pipeline
    func start() {
        LMLog.visual.info("ImageQueue starting")
        fillQueue()
    }

    /// Stop generation and clear queue
    func stop() {
        generationTask?.cancel()
        generationTask = nil
        imageBuffer.removeAll()
        currentImage = nil
        queuedCount = 0
        isGenerating = false
        LMLog.visual.info("ImageQueue stopped")
    }

    /// Advance to the next image in queue
    /// Returns true if an image was available
    @discardableResult
    func advance() -> Bool {
        guard !imageBuffer.isEmpty else {
            LMLog.visual.warning("No images in queue to advance")
            return false
        }

        currentImage = imageBuffer.removeFirst()
        queuedCount = imageBuffer.count
        LMLog.visual.debug("Advanced to next image, \(self.queuedCount) remaining in queue")

        // Refill if needed
        if imageBuffer.count < minimumQueueSize {
            fillQueue()
        }

        return true
    }

    /// Request a new image be generated immediately (mood change trigger)
    func requestNewImage() {
        fillQueue()
    }

    // MARK: - Private

    private func fillQueue() {
        guard generationTask == nil || generationTask?.isCancelled == true else {
            return  // Already generating
        }

        generationTask = Task {
            while imageBuffer.count < targetQueueSize && !Task.isCancelled {
                await generateOne()
            }
            generationTask = nil
        }
    }

    private func generateOne() async {
        isGenerating = true
        defer { isGenerating = false }

        let prompt = promptBuilder?() ?? defaultPrompt()

        do {
            let image = try await gemini.generateImage(prompt: prompt)
            guard !Task.isCancelled else { return }

            imageBuffer.append(image)
            queuedCount = imageBuffer.count

            // Set as current if we don't have one yet
            if currentImage == nil {
                currentImage = image
            }

            LMLog.visual.info("Generated image, queue size: \(self.imageBuffer.count)")
        } catch {
            LMLog.visual.error("Image generation failed: \(error.localizedDescription)")
            // Wait before retry
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func defaultPrompt() -> String {
        "Abstract ambient visual, ethereal, dreamlike atmosphere, soft colors, minimal, peaceful"
    }
}
