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
        var displayedImageHashes: Set<Int> = []  // Track which images have been shown

        // Helper to get short ID for an image (last 4 chars of hash)
        private func shortId(_ image: PlatformImage) -> String {
            String(format: "%04X", abs(image.hash) % 0xFFFF)
        }

        func markAsDisplayed(_ image: PlatformImage) {
            self.displayedImageHashes.insert(image.hash)
            let imgId = self.shortId(image)
            let count = self.displayedImageHashes.count
            LMLog.visual.debug("👁️ DISPLAYED: \(imgId) (total displayed: \(count))")
        }

        func resetDisplayHistory() {
            self.displayedImageHashes.removeAll()
            LMLog.visual.info("👁️ DISPLAY HISTORY RESET")
        }

        func getDisplayedHashes() -> Set<Int> {
            return self.displayedImageHashes
        }

        func appendToBuffer(_ image: PlatformImage) {
            self.imageBuffer.append(image)
            let imgId = self.shortId(image)
            let count = self.imageBuffer.count
            let ids = self.imageBuffer.map { self.shortId($0) }.joined(separator: ",")
            LMLog.visual.info("📥 QUEUE ADD: \(imgId) → buffer=[\(ids)] count=\(count)")
        }

        func appendToCached(_ image: PlatformImage) {
            self.cachedImages.append(image)
            let imgId = self.shortId(image)
            let count = self.cachedImages.count
            LMLog.visual.debug("💾 CACHED ADD: \(imgId) → total cached=\(count)")
        }

        func removeFirstFromBuffer() -> PlatformImage? {
            guard !self.imageBuffer.isEmpty else {
                LMLog.visual.warning("📤 QUEUE REMOVE: buffer empty!")
                return nil
            }
            let removed = self.imageBuffer.removeFirst()
            let imgId = self.shortId(removed)
            let count = self.imageBuffer.count
            let ids = self.imageBuffer.map { self.shortId($0) }.joined(separator: ",")
            LMLog.visual.info("📤 QUEUE REMOVE: \(imgId) → buffer=[\(ids)] count=\(count)")
            return removed
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
            self.cachedImages = images
            let count = images.count
            LMLog.visual.debug("💾 CACHED SET: \(count) images")
        }

        func getCachedImages() -> [PlatformImage] {
            cachedImages
        }

        func setImageBuffer(_ images: [PlatformImage]) {
            self.imageBuffer = images
            let count = images.count
            let ids = images.map { self.shortId($0) }.joined(separator: ",")
            LMLog.visual.info("📥 QUEUE SET: [\(ids)] count=\(count)")
        }

        func clearBuffer() {
            self.imageBuffer.removeAll()
            LMLog.visual.info("📥 QUEUE CLEARED")
        }

        func refillBufferFromCache(excluding currentlyDisplayed: PlatformImage?, cacheOnlyMode: Bool) {
            let excludeId = currentlyDisplayed != nil ? self.shortId(currentlyDisplayed!) : "none"
            let cachedCount = self.cachedImages.count
            let bufferCount = self.imageBuffer.count
            let displayedCount = self.displayedImageHashes.count
            LMLog.visual.info("🔄 REFILL START: cached=\(cachedCount), buffer=\(bufferCount), displayed=\(displayedCount), excluding=\(excludeId), cacheOnly=\(cacheOnlyMode)")

            let shuffled = self.cachedImages.shuffled()
            var added = 0
            for image in shuffled {
                // Don't add if already in buffer or currently displayed
                // In cache-only mode, allow previously displayed images (that's all we have)
                let isInBuffer = self.imageBuffer.contains(where: { $0 === image })
                let isCurrentlyDisplayed = currentlyDisplayed != nil && image === currentlyDisplayed
                let wasDisplayed = cacheOnlyMode ? false : self.displayedImageHashes.contains(image.hash)
                if !isInBuffer && !isCurrentlyDisplayed && !wasDisplayed {
                    self.imageBuffer.append(image)
                    added += 1
                    let imgId = self.shortId(image)
                    LMLog.visual.debug("🔄 REFILL: added \(imgId)")
                } else {
                    let imgId = self.shortId(image)
                    LMLog.visual.debug("🔄 REFILL: skipped \(imgId) (inBuffer=\(isInBuffer), current=\(isCurrentlyDisplayed), wasDisplayed=\(wasDisplayed))")
                }
            }

            // If we couldn't add ANY images (all have been displayed), reset and try again
            // This only applies in normal mode - cache-only mode already ignores displayed history
            if added == 0 && cachedCount > 0 && !cacheOnlyMode {
                LMLog.visual.info("🔄 REFILL: All cached images displayed, resetting history...")
                self.displayedImageHashes.removeAll()
                // Keep the currently displayed one in history so we don't immediately repeat it
                if let current = currentlyDisplayed {
                    self.displayedImageHashes.insert(current.hash)
                }
                // Recurse to try again with fresh history
                for image in shuffled {
                    let isInBuffer = self.imageBuffer.contains(where: { $0 === image })
                    let isCurrentlyDisplayed = currentlyDisplayed != nil && image === currentlyDisplayed
                    if !isInBuffer && !isCurrentlyDisplayed {
                        self.imageBuffer.append(image)
                        added += 1
                        let imgId = self.shortId(image)
                        LMLog.visual.debug("🔄 REFILL (after reset): added \(imgId)")
                    }
                }
            }

            let finalCount = self.imageBuffer.count
            let ids = self.imageBuffer.map { self.shortId($0) }.joined(separator: ",")
            LMLog.visual.info("🔄 REFILL DONE: added=\(added), buffer=[\(ids)] count=\(finalCount)")
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

        // Listen for cache clear events to update UI
        NotificationCenter.default.addObserver(
            forName: .imageCacheCleared,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // Clear the atomic image buffer (for render loop)
            self.imageBuffer.clear()

            Task { @MainActor in
                // Clear @Published properties (for UI)
                self.totalCachedCount = 0
                self.currentImage = nil
                self.nextImage = nil
                self.queuedCount = 0
            }
            Task {
                // Clear internal state
                await self.state.setCachedImages([])
                await self.state.clearBuffer()
                await self.state.resetDisplayHistory()
                LMLog.visual.info("Cache cleared - all images reset")
            }
        }
    }

    // MARK: - Cache Loading

    private func loadCachedImages() async {
        LMLog.visual.info("📂 [ImageQueue] Loading cached images...")

        #if os(visionOS)
        // visionOS: Load raw CGImages and upscale on demand (no UIImage!)
        let rawImages = cache.loadAllRawAsCGImages()
        let count = rawImages.count
        LMLog.visual.info("📂 [ImageQueue] Raw cache returned \(count) CGImages")

        await MainActor.run {
            totalCachedCount = count
        }

        if let randomRawImage = rawImages.randomElement() {
            LMLog.visual.info("📂 [ImageQueue] Upscaling random cached image \(randomRawImage.width)x\(randomRawImage.height)...")
            do {
                let upscaled = try await upscaler.upscale(randomRawImage)
                LMLog.visual.info("📂 [ImageQueue] ✅ Upscaled to \(upscaled.width)x\(upscaled.height), storing in buffer")
                imageBuffer.storeCurrent(upscaled)
            } catch {
                LMLog.visual.error("📂 [ImageQueue] ❌ Failed to upscale cached image: \(error.localizedDescription)")
            }
        } else {
            LMLog.visual.debug("📂 [ImageQueue] No raw cached images found - will generate fresh")
        }

        #else
        // macOS: Load PlatformImages from legacy cache
        let loaded = cache.loadAll()
        await state.setCachedImages(loaded)
        let count = await state.cachedCount()
        LMLog.visual.info("📂 [ImageQueue] Cache returned \(loaded.count) images")

        await MainActor.run {
            totalCachedCount = count
        }

        if !loaded.isEmpty {
            let randomImage = loaded.randomElement()
            LMLog.visual.debug("📂 [ImageQueue] Selected random image from cache")

            if let image = randomImage {
                // Mark this initial image as displayed so we don't cycle back to it
                await state.markAsDisplayed(image)

                LMLog.visual.debug("📂 [ImageQueue] Extracting CGImage from cached image...")
                if let cgImage = image.cgImageRepresentation {
                    LMLog.visual.info("📂 [ImageQueue] ✅ Storing cached CGImage in atomic buffer: \(cgImage.width)x\(cgImage.height)")
                    imageBuffer.storeCurrent(cgImage)
                } else {
                    LMLog.visual.error("📂 [ImageQueue] ❌ Failed to extract CGImage from cached image!")
                }
            }

            await MainActor.run {
                currentImage = randomImage
            }
            LMLog.visual.info("📂 [ImageQueue] Loaded \(count) cached upscaled images, showing random one")
        } else {
            LMLog.visual.debug("📂 [ImageQueue] No cached images found - will generate fresh")
        }
        #endif
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
        #if os(visionOS)
        // visionOS: Use atomic pending queue
        // In cache-only mode, start a background task to populate queue from cache
        if cacheOnly {
            LMLog.visual.info("Cache-only mode (visionOS): starting cache recycler")
            startCacheRecycler()
        } else {
            startContinuousGeneration()
        }
        #else
        // macOS: Use PlatformImage buffer via StateManager
        // Clear buffer - we start fresh each session
        await state.clearBuffer()

        // Load cached images into buffer, excluding already-displayed images
        let cachedImages = await state.getCachedImages()
        if !cachedImages.isEmpty {
            // Filter out images that have already been displayed (including the initial random one)
            let displayedHashes = await state.getDisplayedHashes()
            let filteredImages = cachedImages.filter { !displayedHashes.contains($0.hash) }
            await state.setImageBuffer(filteredImages.shuffled())
            let count = await state.bufferCount()
            await MainActor.run {
                queuedCount = count
            }
            LMLog.visual.debug("Loaded \(count) cached images into buffer (excluded \(cachedImages.count - filteredImages.count) already displayed)")
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
        #endif
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
        #if os(visionOS)
        // visionOS: Advance from the atomic pending queue (CGImage-only, MainActor-free)
        let advanced = imageBuffer.advanceFromQueue()
        if !advanced {
            LMLog.visual.debug("No pending images to advance (visionOS)")
        }
        #else
        // macOS: Advance from the PlatformImage queue
        guard let nextPlatformImage = await state.removeFirstFromBuffer() else {
            LMLog.visual.warning("No images in queue to advance")
            return
        }

        // Mark this image as displayed so we don't cycle back to it
        // Only track in normal mode - cache-only mode allows repeats since that's all we have
        let cacheOnly = await MainActor.run { SettingsService.shared.cacheOnly }
        if !cacheOnly {
            await state.markAsDisplayed(nextPlatformImage)
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

        // If buffer is low, refill from cache (excluding currently displayed image)
        // BUT: Don't refill if we're actively generating - let generation add to queue naturally
        // This prevents the "all displayed, reset history" from adding old images back
        // when a new image is about to finish generating
        let cachedCount = await state.cachedCount()
        let currentlyGenerating = await MainActor.run { self.isGenerating }
        let generationTaskActive = generationTask != nil && generationTask?.isCancelled == false
        LMLog.visual.info("📊 ADVANCE STATE: buffer=\(bufferCount), cached=\(cachedCount), isGenerating=\(currentlyGenerating), taskActive=\(generationTaskActive)")

        if bufferCount < 2 && cachedCount > 0 && (cacheOnly || !generationTaskActive) {
            await refillFromCache(excluding: nextPlatformImage, cacheOnlyMode: cacheOnly)
        } else if bufferCount < 2 && generationTaskActive {
            LMLog.visual.info("⏳ Skipping refill - generation task active, will add to queue soon")
        }
        #endif
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

    private func refillFromCache(excluding currentlyDisplayed: PlatformImage?, cacheOnlyMode: Bool) async {
        await state.refillBufferFromCache(excluding: currentlyDisplayed, cacheOnlyMode: cacheOnlyMode)
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

    #if os(visionOS)
    /// visionOS cache recycler - upscales random cached images and queues them for display.
    /// This runs in cache-only mode to maintain the advance() timing while pulling from cache.
    private func startCacheRecycler() {
        guard generationTask == nil || generationTask?.isCancelled == true else {
            LMLog.visual.debug("🔄 [CacheRecycler] Already running, skipping")
            return
        }

        LMLog.visual.info("🔄 [CacheRecycler] Starting cache recycler loop...")

        generationTask = Task.detached { [weak self] in
            guard let self = self else { return }

            // Load all raw cached images
            let rawImages = self.cache.loadAllRawAsCGImages()
            guard !rawImages.isEmpty else {
                LMLog.visual.warning("🔄 [CacheRecycler] No cached images found!")
                return
            }

            LMLog.visual.info("🔄 [CacheRecycler] Loaded \(rawImages.count) raw images from cache")

            var loopCount = 0
            while !Task.isCancelled {
                loopCount += 1

                // Pick a random image from cache
                guard let rawImage = rawImages.randomElement() else { continue }

                LMLog.visual.info("🔄 [CacheRecycler] Iteration \(loopCount): upscaling \(rawImage.width)x\(rawImage.height)")

                do {
                    // Upscale it (MetalFX is fast ~0.02s on visionOS)
                    let upscaled = try await self.upscaler.upscale(rawImage)

                    // Queue it for the advance timer
                    if self.imageBuffer.hasCurrent() {
                        self.imageBuffer.queuePending(upscaled)
                    } else {
                        // First image - display immediately
                        self.imageBuffer.storeCurrent(upscaled)
                    }

                    LMLog.visual.info("🔄 [CacheRecycler] ✅ Queued \(upscaled.width)x\(upscaled.height), pending=\(self.imageBuffer.pendingCount())")
                } catch {
                    LMLog.visual.error("🔄 [CacheRecycler] ❌ Upscale failed: \(error.localizedDescription)")
                }

                // Wait before next - keep queue topped up but don't overload
                // Only queue more if pending count is low
                let pendingCount = self.imageBuffer.pendingCount()
                if pendingCount >= 3 {
                    // Queue is full enough, wait longer
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                } else {
                    // Queue is low, upscale another quickly
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }

            LMLog.visual.warning("🔄 [CacheRecycler] Loop exited (cancelled)")
        }
    }
    #endif

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
            #if os(visionOS)
            // visionOS: 100% MainActor-free pipeline using CGImage throughout
            // No UIImage/PlatformImage touches to avoid MainActor starvation

            // Step 1: Generate from Gemini (returns raw PNG data + CGImage)
            LMLog.visual.info("🔄 [Pipeline] Step 1: Calling Gemini (raw mode)...")
            let rawResult = try await gemini.generateImageRaw(prompt: prompt)
            LMLog.visual.info("🔄 [Pipeline] Step 1 COMPLETE: Raw image \(rawResult.cgImage.width)x\(rawResult.cgImage.height)")

            guard !Task.isCancelled else { return }

            // Step 2: Upscale the CGImage directly (no PlatformImage!)
            LMLog.visual.info("🔄 [Pipeline] Step 2: Upscaling CGImage...")
            let upscaledCGImage = try await upscaler.upscale(rawResult.cgImage)
            LMLog.visual.info("🔄 [Pipeline] Step 2 COMPLETE: Upscaled to \(upscaledCGImage.width)x\(upscaledCGImage.height)")

            guard !Task.isCancelled else { return }

            // Step 3: Queue upscaled CGImage for display (respects advance timer)
            // If no current image yet, store directly for immediate display
            // Otherwise queue for the next advance() call
            LMLog.visual.info("🔄 [Pipeline] Step 3: Queueing CGImage...")
            if imageBuffer.hasCurrent() {
                imageBuffer.queuePending(upscaledCGImage)
            } else {
                // First image - display immediately
                imageBuffer.storeCurrent(upscaledCGImage)
            }

            // Step 4: Cache the RAW PNG data (not upscaled!) - just write bytes, no UIImage
            LMLog.visual.info("🔄 [Pipeline] Step 4: Caching raw PNG data (\(rawResult.pngData.count) bytes)...")
            do {
                try cache.saveRawData(rawResult.pngData)
                let cachedCount = cache.rawCount
                await MainActor.run {
                    totalCachedCount = cachedCount
                }
                LMLog.visual.info("🔄 Pipeline ✅ COMPLETE (visionOS) - cached=\(cachedCount)")
            } catch {
                LMLog.visual.warning("🔄 [Pipeline] Cache save failed: \(error.localizedDescription)")
            }

            #else
            // macOS: Standard pipeline with PlatformImage

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
            // CRITICAL: Only add to queue if NOT already displaying this image!
            // If needsCurrentImage was true, we already set currentImage to this image,
            // so adding to buffer would cause it to show again on first advance().
            let imageId = String(format: "%04X", abs(upscaledPlatformImage.hash) % 0xFFFF)
            LMLog.visual.info("🔄 Pipeline Step 6: img=\(imageId) needsCurrentImage=\(needsCurrentImage)")
            if !needsCurrentImage {
                await state.appendToBuffer(upscaledPlatformImage)
                LMLog.visual.info("🔄 Pipeline Step 6: ✅ ADDED \(imageId) to queue")
            } else {
                // First image stored directly - mark as displayed so refill doesn't add it back!
                let cacheOnly = await MainActor.run { SettingsService.shared.cacheOnly }
                if !cacheOnly {
                    await state.markAsDisplayed(upscaledPlatformImage)
                }
                LMLog.visual.info("🔄 Pipeline Step 6: ⏭️ SKIPPED \(imageId) (already displaying, marked)")
            }
            await state.appendToCached(upscaledPlatformImage)
            let bufferCount = await state.bufferCount()
            let cachedCount = await state.cachedCount()
            LMLog.visual.info("🔄 Pipeline Step 6 COMPLETE: img=\(imageId) buffer=\(bufferCount), cached=\(cachedCount)")

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
