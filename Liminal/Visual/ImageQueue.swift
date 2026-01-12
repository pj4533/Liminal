import Foundation
import Combine
import OSLog
import CoreGraphics

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Manages a buffer of images for smooth visual transitions.
/// Pipeline: Gemini generates → RealESRGAN upscales → Persistent cache
/// On startup, shows one random cached image, then only new images (unless recycleImages is on).
///
/// Architecture: This class uses a dual-path approach for visionOS compatibility:
///
/// 1. AtomicImageBuffer - Lock-free, thread-safe buffer for the 90fps render loop
///    The render loop reads directly from this without MainActor involvement.
///    This prevents continuation starvation from the high-frequency TimelineView.
///
/// 2. @Published properties - For UI bindings (queue count, generating state, etc.)
///    These are updated on MainActor but are NOT used by the render loop.
///
/// The key insight: The render loop doesn't need Combine/SwiftUI observation.
/// It just needs to read the latest image. AtomicImageBuffer provides this.
final class ImageQueue: ObservableObject {

    // MARK: - Atomic Image Buffer (for render loop - bypasses MainActor)

    /// Thread-safe buffer for the 90fps render loop.
    /// Call `imageBuffer.loadCurrent()` from the render loop - no MainActor needed.
    let imageBuffer = AtomicImageBuffer()

    // MARK: - State (MainActor for @Published - UI only, NOT render loop)

    @MainActor @Published private(set) var currentImage: PlatformImage?
    @MainActor @Published private(set) var nextImage: PlatformImage?  // For preloading morphs
    @MainActor @Published private(set) var isGenerating = false
    @MainActor @Published private(set) var queuedCount = 0
    @MainActor @Published private(set) var totalCachedCount = 0  // Total images in persistent cache

    // MARK: - Internal State (protected by dedicated actor)

    /// Actor to protect mutable state without blocking MainActor
    private actor StateManager {
        var imageBuffer: [PlatformImage] = []
        var cachedImages: [PlatformImage] = []

        func appendToBuffer(_ image: PlatformImage) {
            imageBuffer.append(image)
        }

        func appendToCached(_ image: PlatformImage) {
            cachedImages.append(image)
        }

        func removeFirstFromBuffer() -> PlatformImage? {
            guard !imageBuffer.isEmpty else { return nil }
            return imageBuffer.removeFirst()
        }

        func getFirstFromBuffer() -> PlatformImage? {
            imageBuffer.first
        }

        func bufferCount() -> Int {
            imageBuffer.count
        }

        func cachedCount() -> Int {
            cachedImages.count
        }

        func setCachedImages(_ images: [PlatformImage]) {
            cachedImages = images
        }

        func getCachedImages() -> [PlatformImage] {
            cachedImages
        }

        func setImageBuffer(_ images: [PlatformImage]) {
            imageBuffer = images
        }

        func clearBuffer() {
            imageBuffer.removeAll()
        }

        func refillBufferFromCache() {
            let shuffled = cachedImages.shuffled()
            for image in shuffled {
                if !imageBuffer.contains(where: { $0 === image }) {
                    imageBuffer.append(image)
                }
            }
        }
    }

    private let state = StateManager()
    private var generationTask: Task<Void, Never>?
    private let gemini = GeminiClient()
    private let upscaler = ImageUpscaler()
    private let cache = ImageCache()

    // MARK: - Init

    init() {
        Task {
            await loadCachedImages()
        }
    }

    // MARK: - Cache Loading

    private func loadCachedImages() async {
        LMLog.visual.info("📂 [ImageQueue] Loading cached images...")
        let loaded = cache.loadAll()
        await state.setCachedImages(loaded)
        let count = await state.cachedCount()
        LMLog.visual.info("📂 [ImageQueue] Cache returned \(loaded.count) images")

        // Update MainActor state
        await MainActor.run {
            totalCachedCount = count
        }

        if !loaded.isEmpty {
            // Pick ONE random cached image for initial display
            let randomImage = loaded.randomElement()
            LMLog.visual.debug("📂 [ImageQueue] Selected random image from cache")

            // Store CGImage in atomic buffer FIRST (for render loop - no MainActor needed)
            // CGImage extraction is thread-safe on both macOS and iOS/visionOS
            if let image = randomImage {
                LMLog.visual.debug("📂 [ImageQueue] Extracting CGImage from cached image...")
                if let cgImage = image.cgImageRepresentation {
                    LMLog.visual.info("📂 [ImageQueue] ✅ Storing cached CGImage in atomic buffer: \(cgImage.width)x\(cgImage.height)")
                    imageBuffer.storeCurrent(cgImage)
                } else {
                    LMLog.visual.error("📂 [ImageQueue] ❌ Failed to extract CGImage from cached image!")
                }
            }

            // Also update @Published for UI (may be delayed, that's OK)
            await MainActor.run {
                currentImage = randomImage
            }
            LMLog.visual.info("📂 [ImageQueue] Loaded \(count) cached upscaled images, showing random one")
        } else {
            LMLog.visual.debug("📂 [ImageQueue] No cached images found - will generate fresh")
        }
    }

    // MARK: - Prompt Builder

    var promptBuilder: (() -> String)?

    // MARK: - Public API

    /// Start the image generation pipeline
    @MainActor
    func start() {
        let cacheOnly = SettingsService.shared.cacheOnly
        LMLog.visual.info("ImageQueue starting (cacheOnly=\(cacheOnly), cached=\(self.totalCachedCount))")

        Task {
            await startAsync(cacheOnly: cacheOnly)
        }
    }

    private func startAsync(cacheOnly: Bool) async {
        // Clear buffer - we start fresh each session
        await state.clearBuffer()

        // Load cached images into buffer
        let cachedImages = await state.getCachedImages()
        if !cachedImages.isEmpty {
            await state.setImageBuffer(cachedImages.shuffled())
            let count = await state.bufferCount()
            await MainActor.run {
                queuedCount = count
            }
            LMLog.visual.debug("Loaded \(count) cached images into buffer")
        } else {
            await MainActor.run {
                queuedCount = 0
            }
        }

        // Only generate new images if NOT in cache-only mode
        if !cacheOnly {
            startContinuousGeneration()
        } else {
            LMLog.visual.info("Cache-only mode: skipping image generation")
        }
    }

    /// Stop generation and clear queue
    @MainActor
    func stop() {
        generationTask?.cancel()
        generationTask = nil
        Task {
            await state.clearBuffer()
        }
        queuedCount = 0
        isGenerating = false
        LMLog.visual.info("ImageQueue stopped")
    }

    /// Advance to the next image in queue
    /// Returns true if an image was available
    @MainActor
    @discardableResult
    func advance() -> Bool {
        // We need to do this synchronously for the return value, so use a detached check
        // But the actual work is async
        Task {
            await advanceAsync()
        }
        // Return true optimistically if we have queued items
        return queuedCount > 0
    }

    private func advanceAsync() async {
        guard let nextPlatformImage = await state.removeFirstFromBuffer() else {
            LMLog.visual.warning("No images in queue to advance")
            return
        }

        let bufferCount = await state.bufferCount()
        let firstInBuffer = await state.getFirstFromBuffer()

        // Store CGImage in atomic buffer FIRST (for render loop - no MainActor wait!)
        // CGImage extraction is thread-safe on all platforms
        if let nextCGImage = nextPlatformImage.cgImageRepresentation {
            let nextInBufferCGImage = firstInBuffer?.cgImageRepresentation
            imageBuffer.store(current: nextCGImage, next: nextInBufferCGImage)
        }

        // Also update @Published for UI (may be delayed under load, that's OK)
        await MainActor.run {
            currentImage = nextPlatformImage
            queuedCount = bufferCount
            self.nextImage = firstInBuffer
        }

        LMLog.visual.debug("Advanced to next image, \(bufferCount) remaining in queue")

        // If buffer is low, refill from cache
        let cachedCount = await state.cachedCount()
        if bufferCount < 2 && cachedCount > 0 {
            await refillFromCache()
        }
    }

    /// Request a new image be generated immediately (mood change trigger)
    func requestNewImage() {
        // Skip if in cache-only mode
        guard !SettingsService.shared.cacheOnly else { return }

        // Restart generation if not already running
        if generationTask == nil || generationTask?.isCancelled == true {
            startContinuousGeneration()
        }
    }

    // MARK: - Private

    private func refillFromCache() async {
        await state.refillBufferFromCache()
        let count = await state.bufferCount()
        await MainActor.run {
            queuedCount = count
        }
        LMLog.visual.debug("Refilled buffer from cache, now \(count) images")
    }

    private func startContinuousGeneration() {
        guard generationTask == nil || generationTask?.isCancelled == true else {
            LMLog.visual.debug("🔄 [ImageQueue] startContinuousGeneration: already running, skipping")
            return  // Already generating
        }

        LMLog.visual.info("🔄 [ImageQueue] Starting continuous generation loop (detached task)...")

        // Use detached task to avoid inheriting MainActor context
        // This is KEY to avoiding continuation starvation!
        generationTask = Task.detached { [weak self] in
            LMLog.visual.info("🔄 [ImageQueue] Detached task started!")
            guard let self = self else {
                LMLog.visual.error("🔄 [ImageQueue] ❌ self is nil in detached task!")
                return
            }

            var loopCount = 0
            // Keep generating indefinitely while running
            while !Task.isCancelled {
                loopCount += 1
                LMLog.visual.info("🔄 [ImageQueue] === Generation loop iteration \(loopCount) ===")
                await self.generateAndUpscaleOne()

                // Small delay between generations to not hammer the API
                LMLog.visual.debug("🔄 [ImageQueue] Sleeping 2s before next generation...")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            LMLog.visual.warning("🔄 [ImageQueue] Generation loop exited (cancelled)")
        }
    }

    /// Runs entirely off MainActor. Only touches MainActor briefly for @Published updates.
    /// CRITICAL: Uses CGImage throughout the pipeline to avoid MainActor starvation on visionOS.
    private func generateAndUpscaleOne() async {
        LMLog.visual.info("🔄 [Pipeline] === Starting image generation pipeline ===")

        // Update isGenerating on MainActor
        await MainActor.run {
            isGenerating = true
        }
        LMLog.visual.debug("🔄 [Pipeline] isGenerating set to true")

        defer {
            Task { @MainActor in
                isGenerating = false
            }
            LMLog.visual.debug("🔄 [Pipeline] isGenerating will be set to false")
        }

        let prompt = promptBuilder?() ?? defaultPrompt()
        LMLog.visual.debug("🔄 [Pipeline] Prompt ready: \(prompt.prefix(60))...")

        do {
            // Step 1: Generate from Gemini (runs on its own queue)
            LMLog.visual.info("🔄 [Pipeline] Step 1: Calling Gemini API...")
            let rawImage = try await gemini.generateImage(prompt: prompt)
            LMLog.visual.info("🔄 [Pipeline] Step 1 COMPLETE: Got raw image \(Int(rawImage.pixelSize.width))x\(Int(rawImage.pixelSize.height))")

            guard !Task.isCancelled else {
                LMLog.visual.warning("🔄 [Pipeline] ⚠️ Task cancelled after Gemini!")
                return
            }
            LMLog.visual.debug("🔄 [Pipeline] Task not cancelled, continuing...")

            // Step 2: Upscale with RealESRGAN - returns CGImage directly!
            // THIS IS THE CRITICAL PATH - 100% MainActor-free!
            LMLog.visual.info("🔄 [Pipeline] Step 2: Calling upscaler...")
            guard let upscaledCGImage = await upscaler.upscaleToCGImage(rawImage) else {
                LMLog.visual.error("🔄 [Pipeline] ❌ Step 2 FAILED: Upscaler returned nil CGImage")
                return
            }
            LMLog.visual.info("🔄 [Pipeline] Step 2 COMPLETE: Upscaled to \(upscaledCGImage.width)x\(upscaledCGImage.height)")

            guard !Task.isCancelled else {
                LMLog.visual.warning("🔄 [Pipeline] ⚠️ Task cancelled after upscaling!")
                return
            }

            // Step 3: Store CGImage in atomic buffer IMMEDIATELY
            // This is the CRITICAL path - render loop reads from here, no MainActor!
            let bufferId = String(describing: ObjectIdentifier(imageBuffer))
            LMLog.visual.info("🔄 Pipeline Step 3: Checking atomic buffer id=\(bufferId)")

            #if os(visionOS)
            // visionOS: ALWAYS store new images directly to atomic buffer
            // No cycling queue needed - the render loop reads directly from buffer
            // Each new image replaces the previous one immediately
            LMLog.visual.info("🔄 Pipeline (visionOS): 🎯 STORING CGImage (always replace)")
            imageBuffer.storeCurrent(upscaledCGImage)
            LMLog.visual.info("🔄 Pipeline ✅ COMPLETE (visionOS) - CGImage \(upscaledCGImage.width)x\(upscaledCGImage.height) stored")
            #else
            let currentInBuffer = imageBuffer.loadCurrent()
            let needsCurrentImage = currentInBuffer == nil
            LMLog.visual.info("🔄 Pipeline: Atomic buffer \(currentInBuffer != nil ? "has image" : "EMPTY")")

            if needsCurrentImage {
                LMLog.visual.info("🔄 Pipeline: 🎯 STORING CGImage (was empty)")
                imageBuffer.storeCurrent(upscaledCGImage)
                LMLog.visual.info("🔄 Pipeline: ✅ CGImage stored!")
            } else {
                LMLog.visual.debug("🔄 Pipeline: Buffer has image, not replacing")
            }
            // Steps 4-7 only needed for macOS (cache, @Published, etc.)
            LMLog.visual.info("🔄 Pipeline Step 4: Creating PlatformImage...")
            let upscaledPlatformImage = PlatformImage(cgImage: upscaledCGImage)
            LMLog.visual.info("🔄 Pipeline Step 4 COMPLETE: \(Int(upscaledPlatformImage.size.width))x\(Int(upscaledPlatformImage.size.height))")

            // Step 5: Save to persistent cache (don't let this block display)
            LMLog.visual.info("🔄 Pipeline Step 5: Saving to cache...")
            do {
                try cache.save(upscaledPlatformImage)
                LMLog.visual.info("🔄 Pipeline Step 5 COMPLETE: Saved to cache")
            } catch {
                LMLog.visual.warning("🔄 Pipeline Step 5 FAILED: \(error.localizedDescription)")
            }

            // Step 6: Add to buffer via our actor (NOT MainActor)
            LMLog.visual.info("🔄 Pipeline Step 6: Adding to state buffers...")
            await state.appendToBuffer(upscaledPlatformImage)
            await state.appendToCached(upscaledPlatformImage)
            let bufferCount = await state.bufferCount()
            let cachedCount = await state.cachedCount()
            LMLog.visual.info("🔄 Pipeline Step 6 COMPLETE: buffer=\(bufferCount), cached=\(cachedCount)")

            // Step 7: Update @Published for UI (may be delayed, that's OK now)
            LMLog.visual.info("🔄 Pipeline Step 7: Updating @Published...")
            await MainActor.run {
                queuedCount = bufferCount
                totalCachedCount = cachedCount

                // Mirror to @Published for UI consistency
                if needsCurrentImage {
                    currentImage = upscaledPlatformImage
                }
            }
            LMLog.visual.info("🔄 Pipeline Step 7 COMPLETE")

            LMLog.visual.info("🔄 Pipeline ✅ COMPLETE - queue: \(bufferCount), cached: \(cachedCount)")
            #endif
        } catch {
            LMLog.visual.error("🔄 Pipeline FAILED: \(error.localizedDescription)")
            LMLog.visual.debug("🔄 Pipeline: Waiting 5s before retry...")
            // Wait before retry
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func defaultPrompt() -> String {
        "Abstract ambient visual, ethereal, dreamlike atmosphere, soft colors, minimal, peaceful"
    }
}
