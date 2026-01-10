import Foundation
import AppKit
import Combine
import OSLog

/// Manages a buffer of images for smooth visual transitions.
/// Pipeline: Gemini generates → RealESRGAN upscales → Persistent cache
/// On startup, shows one random cached image, then only new images (unless recycleImages is on).
@MainActor
final class ImageQueue: ObservableObject {

    // MARK: - State

    @Published private(set) var currentImage: NSImage?
    @Published private(set) var nextImage: NSImage?  // For preloading morphs
    @Published private(set) var isGenerating = false
    @Published private(set) var queuedCount = 0
    @Published private(set) var totalCachedCount = 0  // Total images in persistent cache

    private var imageBuffer: [NSImage] = []
    private var generationTask: Task<Void, Never>?
    private let gemini = GeminiClient()
    private let upscaler = ImageUpscaler()
    private let cache = ImageCache()

    // All cached images (for recycling mode)
    private var cachedImages: [NSImage] = []

    // MARK: - Init

    init() {
        Task {
            await loadCachedImages()
        }
    }

    // MARK: - Cache Loading

    private func loadCachedImages() async {
        cachedImages = await cache.loadAll()
        totalCachedCount = cachedImages.count

        if !cachedImages.isEmpty {
            // Pick ONE random cached image for initial display
            currentImage = cachedImages.randomElement()
            LMLog.visual.info("Loaded \(self.cachedImages.count) cached upscaled images, showing random one")
        } else {
            LMLog.visual.debug("No cached images found - will generate fresh")
        }
    }

    // MARK: - Prompt Builder

    var promptBuilder: (() -> String)?

    // MARK: - Public API

    /// Start the image generation pipeline
    func start() {
        let recycleMode = SettingsService.shared.recycleImages
        LMLog.visual.info("ImageQueue starting (recycle=\(recycleMode), cached=\(self.totalCachedCount))")

        // Clear buffer - we start fresh each session
        imageBuffer.removeAll()
        queuedCount = 0

        // If recycle mode is ON, populate buffer with cached images
        if recycleMode && !cachedImages.isEmpty {
            imageBuffer = cachedImages.shuffled()
            queuedCount = imageBuffer.count
            LMLog.visual.debug("Recycle mode: loaded \(self.imageBuffer.count) cached images into buffer")
        }

        // Start generating new images in background
        startContinuousGeneration()
    }

    /// Stop generation and clear queue
    func stop() {
        generationTask?.cancel()
        generationTask = nil
        imageBuffer.removeAll()
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

        // Expose next image for morph preloading
        nextImage = imageBuffer.first

        LMLog.visual.debug("Advanced to next image, \(self.queuedCount) remaining in queue")

        // If recycle mode and buffer is low, refill from cache
        if SettingsService.shared.recycleImages && imageBuffer.count < 2 && !cachedImages.isEmpty {
            refillFromCache()
        }

        return true
    }

    /// Request a new image be generated immediately (mood change trigger)
    func requestNewImage() {
        // Restart generation if not already running
        if generationTask == nil || generationTask?.isCancelled == true {
            startContinuousGeneration()
        }
    }

    // MARK: - Private

    private func refillFromCache() {
        // Only called in recycle mode
        let shuffled = cachedImages.shuffled()
        for image in shuffled {
            if !imageBuffer.contains(where: { $0 === image }) {
                imageBuffer.append(image)
            }
        }
        queuedCount = imageBuffer.count
        LMLog.visual.debug("Refilled buffer from cache, now \(self.imageBuffer.count) images")
    }

    private func startContinuousGeneration() {
        guard generationTask == nil || generationTask?.isCancelled == true else {
            return  // Already generating
        }

        generationTask = Task {
            // Keep generating indefinitely while running
            while !Task.isCancelled {
                await generateAndUpscaleOne()

                // Small delay between generations to not hammer the API
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            generationTask = nil
        }
    }

    private func generateAndUpscaleOne() async {
        isGenerating = true
        defer { isGenerating = false }

        let prompt = promptBuilder?() ?? defaultPrompt()

        do {
            // Step 1: Generate from Gemini
            LMLog.visual.debug("Generating image from Gemini...")
            let rawImage = try await gemini.generateImage(prompt: prompt)
            guard !Task.isCancelled else { return }

            // Step 2: Upscale with RealESRGAN
            LMLog.visual.debug("Upscaling with RealESRGAN...")
            let upscaledImage = try await upscaler.upscale(rawImage)
            guard !Task.isCancelled else { return }

            // Step 3: Save to persistent cache
            try await cache.save(upscaledImage)

            // Step 4: Add to buffer and update counts
            imageBuffer.append(upscaledImage)
            cachedImages.append(upscaledImage)
            queuedCount = imageBuffer.count
            totalCachedCount = cachedImages.count

            // Set as current if we don't have one yet
            if currentImage == nil {
                currentImage = upscaledImage
            }

            LMLog.visual.info("Generated + upscaled image, queue: \(self.imageBuffer.count), total cached: \(self.totalCachedCount)")
        } catch {
            LMLog.visual.error("Image pipeline failed: \(error.localizedDescription)")
            // Wait before retry
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func defaultPrompt() -> String {
        "Abstract ambient visual, ethereal, dreamlike atmosphere, soft colors, minimal, peaceful"
    }
}
