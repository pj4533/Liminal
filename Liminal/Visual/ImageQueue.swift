import Foundation
import Combine
import OSLog
import CoreGraphics

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Generates, caches and queues images for display.
///
/// Pipeline: PromptDirector -> ModelRouter -> Gemini -> BorderTrimmer -> metadata
///           -> ImageStore (original bytes + sidecar) -> upscale (skipped at 2K) -> display queue
///
/// Architecture (unchanged in spirit, see docs/DUAL_PIPELINE_ARCHITECTURE.md):
/// 1. AtomicImageBuffer: lock-protected buffer the 90fps render loop reads without MainActor.
/// 2. @Published properties: UI only, updated on MainActor, never read by the render loop.
///
/// Pacing (docs/decisions/images.md D16): generation runs only while fewer than
/// `config.targetPendingCount` images wait for display, so the generation rate matches
/// the display rate instead of running continuously.
///
/// Cache recycling: used in Cache Only mode, and in live mode while every model is
/// cooling down after quota/server errors, so the display never stalls.
nonisolated final class ImageQueue: ObservableObject, @unchecked Sendable {

    // MARK: - Atomic Image Buffer (for render loop - bypasses MainActor)

    let imageBuffer = AtomicImageBuffer()

    // MARK: - State (MainActor for @Published - UI only, NOT render loop)

    @MainActor @Published private(set) var currentImage: PlatformImage?
    @MainActor @Published private(set) var nextImage: PlatformImage?
    @MainActor @Published private(set) var currentMetadata: ImageMetadata?
    @MainActor @Published private(set) var isGenerating = false
    @MainActor @Published private(set) var queuedCount = 0
    @MainActor @Published private(set) var totalCachedCount = 0
    /// Short explanation for the UI when nothing new is coming (Cache Only with an empty cache, all models cooling down).
    @MainActor @Published private(set) var statusMessage: String?

    // MARK: - Dependencies

    let config: ImageGenerationConfig
    let store: ImageStore
    let director: PromptDirector
    private let gemini: GeminiClient
    private let upscaler = ImageUpscaler()

    /// Optional override for where prompts come from (defaults to the PromptDirector).
    var promptSource: (() -> PromptSpec)?

    // MARK: - Internal state

    /// One image ready to show (macOS keeps PlatformImages for the SwiftUI crossfade).
    private struct DisplayItem: @unchecked Sendable {
        let id: UUID?
        let cgImage: CGImage
        let image: PlatformImage?      // nil on visionOS: no UIImage in the pipeline (MainActor starvation)
        let metadata: ImageMetadata?
    }

    private static func platformImage(_ cgImage: CGImage) -> PlatformImage? {
        #if os(macOS)
        return PlatformImage(cgImage: cgImage)
        #else
        return nil
        #endif
    }

    /// Protects mutable queue state without touching MainActor.
    private actor StateManager {
        var buffer: [DisplayItem] = []        // macOS display queue
        var recentIDs: [UUID] = []            // newest last; recycler avoids these

        func append(_ item: DisplayItem) { buffer.append(item) }
        func removeFirst() -> DisplayItem? { buffer.isEmpty ? nil : buffer.removeFirst() }
        func first() -> DisplayItem? { buffer.first }
        func count() -> Int { buffer.count }
        func clearBuffer() { buffer.removeAll() }

        func noteShown(_ id: UUID?) {
            guard let id else { return }
            recentIDs.removeAll { $0 == id }
            recentIDs.append(id)
            if recentIDs.count > 50 { recentIDs.removeFirst(recentIDs.count - 50) }
        }
        func recent() -> [UUID] { recentIDs }
        func reset() {
            buffer.removeAll()
            recentIDs.removeAll()
        }
    }

    private let state = StateManager()
    private let taskLock = NSLock()
    nonisolated(unsafe) private var _generationTask: Task<Void, Never>?
    nonisolated(unsafe) private var _isRunning = false

    private var generationTask: Task<Void, Never>? {
        get { taskLock.withLock { _generationTask } }
        set { taskLock.withLock { _generationTask = newValue } }
    }
    private var isRunning: Bool {
        get { taskLock.withLock { _isRunning } }
        set { taskLock.withLock { _isRunning = newValue } }
    }

    // MARK: - Init

    init(config: ImageGenerationConfig = .standard, store: ImageStore = .shared,
         director: PromptDirector = PromptDirector()) {
        self.config = config
        self.store = store
        self.director = director
        self.gemini = GeminiClient(timeout: config.requestTimeout)

        // Purge old caches (cache epoch) before anything is listed or decoded.
        store.migrateIfNeeded()

        Task.detached { [weak self] in
            await self?.loadInitialImage()
        }
    }

    // MARK: - Startup

    /// Lists the store (sidecars only), decodes ONE random image and shows it.
    private func loadInitialImage() async {
        #if DEBUG
        if DebugLaunchOptions.testPattern {
            // -LiminalTestPattern: show only the orientation/colour test card.
            let card = TestPatternGenerator.image
            imageBuffer.storeCurrent(card, metadata: nil)
            await MainActor.run { self.currentImage = Self.platformImage(card) }
            LMLog.visual.info("🧪 [ImageQueue] Test pattern shown (\(card.width)x\(card.height)); generation disabled")
            return
        }
        #endif
        let files = store.imageFiles()
        await publishCachedCount(files.count)
        LMLog.visual.info("📂 [ImageQueue] \(files.count) cached images")
        guard !imageBuffer.hasCurrent(), let pick = files.randomElement() else { return }
        let entry = store.entry(id: pick.id, url: pick.url)
        guard let item = await makeDisplayItem(entry) else { return }
        guard !imageBuffer.hasCurrent() else { return }
        imageBuffer.storeCurrent(item.cgImage, metadata: item.metadata)
        await state.noteShown(item.id)
        await MainActor.run {
            self.currentImage = item.image
            self.currentMetadata = item.metadata
        }
    }

    // MARK: - Public API

    @MainActor
    func start() {
        let cacheOnly = SettingsService.shared.cacheOnly
        isRunning = true
        #if DEBUG
        if DebugLaunchOptions.testPattern { return }  // test card only, no generation/recycling
        #endif
        LMLog.visual.info("ImageQueue starting (cacheOnly=\(cacheOnly), cached=\(self.totalCachedCount))")
        statusMessage = nil
        if cacheOnly {
            startCacheRecycler()
        } else {
            startContinuousGeneration()
        }
    }

    @MainActor
    func stop() {
        isRunning = false
        generationTask?.cancel()
        generationTask = nil
        Task { await state.clearBuffer() }
        queuedCount = 0
        isGenerating = false
        LMLog.visual.info("ImageQueue stopped")
    }

    /// Advance to the next queued image. Returns true optimistically if something was queued.
    @MainActor
    @discardableResult
    func advance() -> Bool {
        Task.detached { [weak self] in
            await self?.advanceAsync()
        }
        return queuedCount > 0
    }

    /// Request a new image (mood change trigger).
    @MainActor
    func requestNewImage() {
        guard !SettingsService.shared.cacheOnly else { return }
        if generationTask == nil || generationTask?.isCancelled == true {
            startContinuousGeneration()
        }
    }

    /// Removes every cached image and resets all in-memory state, in order
    /// (docs/decisions/images.md D15). Restarts generation if the queue was running
    /// and Cache Only is off.
    func clearAllImages() async {
        // 1. Files first, so nothing can be reloaded; bumps clearGeneration.
        let removed = store.clearEverything()

        // 2. Stop the generator or recycler and wait for it to finish.
        let task = generationTask
        generationTask = nil
        task?.cancel()
        await task?.value

        // 3-5. Buffers, internal state, UI mirrors, prompt history.
        imageBuffer.clear()
        await state.reset()
        director.reset()
        let cacheOnly = await MainActor.run { SettingsService.shared.cacheOnly }
        await MainActor.run {
            self.currentImage = nil
            self.nextImage = nil
            self.currentMetadata = nil
            self.queuedCount = 0
            self.totalCachedCount = 0
            self.isGenerating = false
            self.statusMessage = cacheOnly ? "No cached images. Turn off Cache Only to generate new ones." : nil
        }

        // 6. One notification for UI refreshes.
        await MainActor.run {
            NotificationCenter.default.post(name: .imageCacheCleared, object: nil)
        }
        LMLog.visual.info("🗑️ [ImageQueue] Clear All Images: removed \(removed.imageCount) images")

        // 7. Restart.
        if isRunning && !cacheOnly {
            startContinuousGeneration()
        }
    }

    // MARK: - Advance

    private func advanceAsync() async {
        #if os(visionOS)
        let advanced = imageBuffer.advanceFromQueue()
        let metadata = imageBuffer.loadCurrentMetadata()
        if advanced { await state.noteShown(metadata?.id) }
        let pending = imageBuffer.pendingCount()
        await MainActor.run {
            self.queuedCount = pending
            if advanced { self.currentMetadata = metadata }
        }
        #else
        guard let item = await state.removeFirst() else {
            LMLog.visual.debug("No images in queue to advance")
            return
        }
        await state.noteShown(item.id)
        let following = await state.first()
        let remaining = await state.count()
        imageBuffer.store(current: item.cgImage, next: following?.cgImage, metadata: item.metadata)
        await MainActor.run {
            self.currentImage = item.image
            self.nextImage = following?.image
            self.currentMetadata = item.metadata
            self.queuedCount = remaining
        }
        #endif
    }

    // MARK: - Queueing helpers

    private func pendingCount() async -> Int {
        #if os(visionOS)
        return imageBuffer.pendingCount()
        #else
        return await state.count()
        #endif
    }

    /// Shows the item now if nothing is on screen, otherwise queues it for the next advance.
    private func enqueue(_ item: DisplayItem) async {
        #if os(visionOS)
        if imageBuffer.hasCurrent() {
            imageBuffer.queuePending(item.cgImage, metadata: item.metadata)
        } else {
            imageBuffer.storeCurrent(item.cgImage, metadata: item.metadata)
            await state.noteShown(item.id)
            await MainActor.run { self.currentMetadata = item.metadata }
        }
        let pending = imageBuffer.pendingCount()
        await MainActor.run { self.queuedCount = pending }
        #else
        if imageBuffer.loadCurrent() == nil {
            imageBuffer.storeCurrent(item.cgImage, metadata: item.metadata)
            await state.noteShown(item.id)
            await MainActor.run {
                self.currentImage = item.image
                self.currentMetadata = item.metadata
            }
        } else {
            await state.append(item)
        }
        let queued = await state.count()
        await MainActor.run { self.queuedCount = queued }
        #endif
    }

    private func publishCachedCount(_ count: Int) async {
        await MainActor.run { self.totalCachedCount = count }
    }

    /// Decodes one stored image (lazily, one at a time) and upscales it if it is small.
    private func makeDisplayItem(_ entry: ImageStore.Entry) async -> DisplayItem? {
        guard let raw = store.loadImage(entry) else { return nil }
        let display = await upscaleIfNeeded(raw)
        return DisplayItem(id: entry.id, cgImage: display, image: Self.platformImage(display), metadata: entry.metadata)
    }

    private func upscaleIfNeeded(_ image: CGImage) async -> CGImage {
        if ImageUpscaler.shouldSkipUpscale(image) { return image }
        do {
            return try await upscaler.upscale(image)
        } catch {
            LMLog.visual.warning("🔬 upscale failed, showing original: \(error.localizedDescription)")
            return image
        }
    }

    // MARK: - Cache recycling

    /// Queues one random cached image the viewer has not seen recently. Returns false if the cache is empty.
    @discardableResult
    private func recycleOneFromCache() async -> Bool {
        let files = store.imageFiles()
        guard !files.isEmpty else { return false }
        let recent = await state.recent()
        // Avoid the most recent ones, but never exclude everything.
        let avoid = Set(recent.suffix(max(0, min(recent.count, files.count - 1))))
        let candidates = files.filter { !avoid.contains($0.id) }
        guard let pick = (candidates.isEmpty ? files : candidates).randomElement() else { return false }
        guard let item = await makeDisplayItem(store.entry(id: pick.id, url: pick.url)) else { return false }
        await state.noteShown(item.id)   // count as seen once queued
        await enqueue(item)
        LMLog.visual.info("♻️ [Recycler] queued cached image \(pick.id.uuidString.prefix(8))")
        return true
    }

    private func startCacheRecycler() {
        guard generationTask == nil || generationTask?.isCancelled == true else { return }
        LMLog.visual.info("♻️ [Recycler] starting")
        generationTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.pendingCount() < self.config.targetPendingCount {
                    let ok = await self.recycleOneFromCache()
                    if !ok {
                        await MainActor.run {
                            self.statusMessage = "No cached images. Turn off Cache Only to generate new ones."
                        }
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        continue
                    }
                    await MainActor.run { self.statusMessage = nil }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            LMLog.visual.info("♻️ [Recycler] stopped")
        }
    }

    // MARK: - Generation

    private func startContinuousGeneration() {
        guard generationTask == nil || generationTask?.isCancelled == true else {
            LMLog.visual.debug("🔄 [ImageQueue] generation already running")
            return
        }
        LMLog.visual.info("🔄 [ImageQueue] starting paced generation loop")

        // Detached: must not inherit MainActor (continuation starvation on visionOS).
        generationTask = Task.detached { [weak self] in
            var router = ModelRouter(config: self?.config ?? .standard)
            var rng = SystemRandomNumberGenerator()

            while !Task.isCancelled {
                guard let self else { return }

                // Backpressure: generation rate follows display rate.
                if self.imageBuffer.hasCurrent(), await self.pendingCount() >= self.config.targetPendingCount {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }

                let now = Date()
                if router.allCoolingDown(now: now) {
                    // Keep the display moving from the cache until a model is back.
                    await MainActor.run { self.statusMessage = "Image models busy, showing cached images" }
                    await self.recycleOneFromCache()
                    let wait = min(5, max(1, router.delayBeforeNextAttempt(now: now)))
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
                }
                let delay = router.delayBeforeNextAttempt(now: now)
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }

                let spec = self.promptSource?() ?? self.director.next()
                guard let model = router.model(for: spec, now: now, using: &rng) else { continue }
                let clearGeneration = self.store.clearGeneration

                await MainActor.run { self.isGenerating = true }
                do {
                    let generated = try await self.requestImage(spec: spec, model: model)
                    router.recordSuccess(model: model)
                    await MainActor.run { self.isGenerating = false; self.statusMessage = nil }
                    guard !Task.isCancelled else { break }
                    await self.handleGenerated(generated, spec: spec, clearGeneration: clearGeneration)
                } catch let error as GeminiError {
                    await MainActor.run { self.isGenerating = false }
                    router.recordFailure(model: model, error: error, now: Date())
                    LMLog.visual.error("🔄 [Pipeline] \(model) failed: \(error.localizedDescription)")
                    if case .missingAPIKey = error { break }
                } catch {
                    await MainActor.run { self.isGenerating = false }
                    if Task.isCancelled { break }
                    LMLog.visual.error("🔄 [Pipeline] failed: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
            LMLog.visual.info("🔄 [ImageQueue] generation loop exited")
        }
    }

    /// Calls Gemini; a fallback model that rejects imageSize is retried once without it.
    private func requestImage(spec: PromptSpec, model: String) async throws -> GeneratedImageData {
        let size = config.imageSize(for: model)
        do {
            return try await gemini.generate(prompt: spec.text, model: model, aspectRatio: config.aspectRatio, imageSize: size)
        } catch let error as GeminiError where error.isImageConfigRejection && model != config.primaryModel {
            LMLog.visual.warning("🔄 [Pipeline] \(model) rejected imageSize, retrying without it")
            return try await gemini.generate(prompt: spec.text, model: model, aspectRatio: config.aspectRatio, imageSize: nil)
        }
    }

    /// Trim, measure, store, upscale if needed, queue. Drops the image if a clear happened meanwhile.
    private func handleGenerated(_ generated: GeneratedImageData, spec: PromptSpec, clearGeneration: UInt64) async {
        guard clearGeneration == store.clearGeneration else {
            LMLog.visual.info("🗑️ [Pipeline] dropping image generated before Clear All Images")
            return
        }

        let trimmed = BorderTrimmer.trimmedIfBordered(generated.cgImage)
        let wasTrimmed = trimmed.width != generated.cgImage.width || trimmed.height != generated.cgImage.height
        if wasTrimmed {
            LMLog.visual.info("✂️ [Pipeline] trimmed border: \(generated.cgImage.width)x\(generated.cgImage.height) -> \(trimmed.width)x\(trimmed.height)")
        }
        let analysis = DominantColorExtractor.analyze(trimmed)
        let metadata = ImageMetadata(
            id: UUID(),
            createdAt: Date(),
            spec: spec,
            model: generated.model,
            pixelWidth: trimmed.width,
            pixelHeight: trimmed.height,
            mimeType: wasTrimmed ? "image/jpeg" : generated.mimeType,
            dominantColors: analysis.colors,
            measuredBrightness: analysis.brightness,
            measuredSaturation: analysis.saturation
        )

        do {
            try store.save(generated, metadata: metadata, trimmed: wasTrimmed ? trimmed : nil,
                           clearGeneration: clearGeneration)
        } catch ImageStore.StoreError.staleClearGeneration {
            LMLog.visual.info("🗑️ [Pipeline] dropping image: cleared while saving")
            return
        } catch {
            LMLog.visual.warning("🔄 [Pipeline] cache save failed: \(error.localizedDescription)")
        }
        await publishCachedCount(store.imageCount())

        let display = await upscaleIfNeeded(trimmed)
        guard clearGeneration == store.clearGeneration, !Task.isCancelled else { return }
        await enqueue(DisplayItem(id: metadata.id, cgImage: display, image: Self.platformImage(display), metadata: metadata))
        LMLog.visual.info("🔄 [Pipeline] ✅ \(spec.styleID)/\(spec.paletteID) \(display.width)x\(display.height) via \(generated.model)")
    }
}
