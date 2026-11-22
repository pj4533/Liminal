import Foundation
import Combine
import OSLog
import CoreGraphics
import ImageIO

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
    /// API mode: "Curated collections: 5 of 5 sources online" and whether that is all well (APIStatusRow).
    @MainActor @Published private(set) var sourceStatus: (text: String, ok: Bool)?
    /// The source the queue is running (AI or API); changed by `switchSource`.
    @MainActor @Published private(set) var imageSource: ImageSource

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
    struct DisplayItem: @unchecked Sendable {
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
    nonisolated(unsafe) private var _activeSource: ImageSource
    /// Bumped by every source switch: results of the previous source's loop are dropped.
    nonisolated(unsafe) private var _sourceGeneration: UInt64 = 0
    private let feedLock = NSLock()
    nonisolated(unsafe) private var _feed: CuratedImageFeed?
    private let feedFactory: @Sendable () -> CuratedImageFeed

    /// The source the loops serve; read off the main actor.
    var activeSource: ImageSource {
        taskLock.withLock { _activeSource }
    }
    private var sourceGeneration: UInt64 {
        taskLock.withLock { _sourceGeneration }
    }

    /// API mode's ingest and display rotation, created on first use (AI-only sessions never build it).
    var feed: CuratedImageFeed {
        feedLock.withLock {
            if let f = _feed { return f }
            let f = feedFactory()
            _feed = f
            return f
        }
    }

    /// The store the active source shows from: the AI cache or the API pool.
    var activeStore: ImageStore {
        activeSource == .api ? feed.pool.store : store
    }

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
         director: PromptDirector = PromptDirector(), source: ImageSource = .current,
         feed: @escaping @Sendable () -> CuratedImageFeed = { CuratedImageFeed() }) {
        self.config = config
        self.store = store
        self.director = director
        self.gemini = GeminiClient(timeout: config.requestTimeout)
        self._activeSource = source
        self._imageSource = Published(initialValue: source)
        self.feedFactory = feed

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
        if let files = DebugLaunchOptions.testImageDirectoryFiles {
            // -LiminalTestImage <directory>: show the first image; start() cycles the rest.
            guard let item = Self.testDirectoryItem(files[0]) else { return }
            imageBuffer.storeCurrent(item.cgImage, metadata: nil)
            await MainActor.run { self.currentImage = item.image }
            LMLog.visual.info("🧪 [ImageQueue] Test directory: \(files.count) images to cycle; generation disabled")
            return
        }
        if let path = DebugLaunchOptions.testImagePath,
           let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            // -LiminalTestImage: show only this image (deterministic before/after captures).
            imageBuffer.storeCurrent(img, metadata: nil)
            await MainActor.run { self.currentImage = Self.platformImage(img) }
            LMLog.visual.info("🧪 [ImageQueue] Test image shown (\(img.width)x\(img.height)); generation disabled")
            return
        }
        if DebugLaunchOptions.testPattern {
            // -LiminalTestPattern: show only the orientation/colour test card.
            let card = TestPatternGenerator.image
            imageBuffer.storeCurrent(card, metadata: nil)
            await MainActor.run { self.currentImage = Self.platformImage(card) }
            LMLog.visual.info("🧪 [ImageQueue] Test pattern shown (\(card.width)x\(card.height)); generation disabled")
            return
        }
        #endif
        if activeSource == .api {
            await loadInitialAPIImage()
            return
        }
        let files = store.imageFiles()
        await publishCachedCount(files.count)
        LMLog.visual.info("📂 [ImageQueue] \(files.count) cached images")
        #if DEBUG
        if files.isEmpty, DebugLaunchOptions.blocksImageGeneration {
            // Automation launch with an empty cache: show the test card rather than call Gemini.
            let card = TestPatternGenerator.image
            imageBuffer.storeCurrent(card, metadata: nil)
            await MainActor.run { self.currentImage = Self.platformImage(card) }
            LMLog.visual.info("🧪 [ImageQueue] empty cache on an automation launch: test card shown, no generation")
            return
        }
        #endif
        guard !imageBuffer.hasCurrent(), let pick = files.randomElement() else { return }
        let entry = store.entry(id: pick.id, url: pick.url)
        guard let item = await makeDisplayItem(entry) else { return }
        guard !imageBuffer.hasCurrent() else { return }
        imageBuffer.storeCurrent(item.cgImage, metadata: item.metadata, id: item.id)
        await state.noteShown(item.id)
        await MainActor.run {
            self.currentImage = item.image
            self.currentMetadata = item.metadata
        }
    }

    /// API mode: one random picture from the pool, else nothing (Lo-Fi shows the standby art, and in
    /// Ambient the first fetched picture shows itself). The AI cache and the test card are not used.
    private func loadInitialAPIImage() async {
        let feed = self.feed
        feed.pool.loadIfNeeded()
        await publishCachedCount(feed.pool.count)
        LMLog.visual.info("📂 [ImageQueue] API pool: \(feed.pool.count) pictures")
        guard !imageBuffer.hasCurrent(), let entry = feed.anyPicture() else { return }
        // The pick is reserved; a launch frame that is not shown after all goes back to the rotation.
        guard let item = await makeDisplayItem(entry, from: feed.pool.store),
              !imageBuffer.hasCurrent(), activeSource == .api else {
            feed.release(entry.id)
            return
        }
        imageBuffer.storeCurrent(item.cgImage, metadata: item.metadata, id: item.id)
        await state.noteShown(item.id)
        didShow(item.metadata)
        await MainActor.run {
            self.currentImage = item.image
            self.currentMetadata = item.metadata
        }
    }

    /// Bookkeeping when a picture becomes the one on screen (API: rotation history and the credit log line).
    /// The ledger write and log line run on a detached task: `showReserved` is called on the main actor
    /// at the Lo-Fi reveal, where the visionOS render loop must not wait on file I/O.
    private func didShow(_ metadata: ImageMetadata?) {
        guard let metadata, metadata.source != nil else { return }
        let feed = self.feed
        Task.detached(priority: .utility) { feed.markShown(metadata) }
    }

    // MARK: - Public API

    /// Shown when generation is off and the cache is empty.
    static var noCachedImagesMessage: String {
        DebugLaunchOptions.blocksImageGeneration
            ? "Test launch: image generation is off, so only cached images (or the test card) are shown."
            : "No cached images. Turn off Cache Only to generate new ones."
    }

    /// Cache Only setting, or a DEBUG automation launch (which must never spend API budget).
    @MainActor
    private var generationDisabled: Bool {
        SettingsService.shared.cacheOnly || DebugLaunchOptions.blocksImageGeneration || !EnvironmentService.shared.hasValidCredentials
    }

    @MainActor
    func start() {
        let cacheOnly = generationDisabled
        isRunning = true
        #if DEBUG
        if DebugLaunchOptions.testImageDirectoryFiles != nil { startTestDirectoryCycler(); return }
        if DebugLaunchOptions.testPattern || DebugLaunchOptions.testImagePath != nil { return }  // fixed image only
        #endif
        statusMessage = nil
        if activeSource == .api {
            // API mode has its own gate: automation flags block Gemini, never the free public APIs.
            LMLog.visual.info("ImageQueue starting (source=api)")
            startAPIFeed()
            return
        }
        LMLog.visual.info("ImageQueue starting (source=ai, cacheOnly=\(cacheOnly), cached=\(self.totalCachedCount))")
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
        feedLock.withLock { _feed }?.stopIngest()
        feedLock.withLock { _feed }?.releaseReserved()
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
        guard !generationDisabled, activeSource == .ai else { return }
        if generationTask == nil || generationTask?.isCancelled == true {
            startContinuousGeneration()
        }
    }

    /// Switches between AI and API. The picture on screen stays; pending pictures of the old source are
    /// dropped and the next image change (timer or drum boundary) shows the new source.
    func switchSource(_ source: ImageSource) async {
        let changed = taskLock.withLock { () -> Bool in
            guard _activeSource != source else { return false }
            _activeSource = source
            _sourceGeneration &+= 1
            return true
        }
        guard changed else { return }
        let task = generationTask
        generationTask = nil
        task?.cancel()
        await task?.value
        if source == .ai { feedLock.withLock { _feed }?.stopIngest() }
        feedLock.withLock { _feed }?.releaseReserved()
        await state.clearBuffer()
        #if os(visionOS)
        while imageBuffer.takePending() != nil {}
        #endif
        ArchiveFootageService.shared.queuedImage(nil)
        let count = source == .api ? { feed.pool.loadIfNeeded(); return feed.pool.count }() : store.imageCount()
        await MainActor.run {
            self.imageSource = source
            self.queuedCount = 0
            self.isGenerating = false
            self.statusMessage = nil
            self.sourceStatus = nil
            self.totalCachedCount = count
        }
        LMLog.visual.info("🖼️ [ImageQueue] image source -> \(source.rawValue, privacy: .public)")
        if isRunning {
            await MainActor.run { self.start() }
        }
    }

    /// Removes every cached image and resets all in-memory state, in order
    /// (docs/decisions/images.md D15). Restarts generation if the queue was running
    /// and Cache Only is off.
    func clearAllImages() async {
        if activeSource == .api {
            await clearAPIPool()
            return
        }
        // 1. Files first, so nothing can be reloaded; bumps clearGeneration.
        let removed = store.clearEverything()

        // 2. Stop the generator or recycler and wait for it to finish.
        let task = generationTask
        generationTask = nil
        task?.cancel()
        await task?.value

        // 3-5. Buffers, internal state, UI mirrors, prompt history.
        ArchiveFootageService.shared.queuedImage(nil)
        ArchiveFootageService.shared.displayedImage(nil)
        imageBuffer.clear()
        await state.reset()
        director.reset()
        let cacheOnly = await MainActor.run { self.generationDisabled }
        await MainActor.run {
            self.currentImage = nil
            self.nextImage = nil
            self.currentMetadata = nil
            self.queuedCount = 0
            self.totalCachedCount = 0
            self.isGenerating = false
            self.statusMessage = cacheOnly ? Self.noCachedImagesMessage : nil
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

    /// API mode's "Clear images": the pool and its ledger, never the AI cache. Fetching restarts.
    private func clearAPIPool() async {
        let task = generationTask
        generationTask = nil
        task?.cancel()
        await task?.value
        let feed = self.feed
        feed.stopIngest()
        let removed = feed.clear()
        ArchiveFootageService.shared.queuedImage(nil)
        ArchiveFootageService.shared.displayedImage(nil)
        imageBuffer.clear()
        await state.reset()
        await MainActor.run {
            self.currentImage = nil
            self.nextImage = nil
            self.currentMetadata = nil
            self.queuedCount = 0
            self.totalCachedCount = 0
            NotificationCenter.default.post(name: .imageCacheCleared, object: nil)
        }
        LMLog.visual.info("🗑️ [ImageQueue] Clear images (API pool): removed \(removed.imageCount) pictures")
        if isRunning {
            await MainActor.run { self.start() }
        }
    }

    // MARK: - Advance

    /// Reserve a distinct picture well ahead of the audio deadline. A slow generator
    /// can finish normally while the local cache or bundled art covers this edit.
    @concurrent func reserveForFill(excluding currentID: UUID?) async -> DisplayItem? {
        #if DEBUG
        if DebugLaunchOptions.testPattern || (DebugLaunchOptions.testImagePath != nil && DebugLaunchOptions.testImageDirectoryFiles == nil) { return nil }
        #endif
        #if os(visionOS)
        while let item = imageBuffer.takePending() {
            if currentID == nil || item.id != currentID {
                return DisplayItem(id: item.id, cgImage: item.image, image: nil, metadata: item.metadata)
            }
        }
        #else
        while let item = await state.removeFirst() {
            if currentID == nil || item.id != currentID { return item }
        }
        #endif
        if activeSource == .api {
            let feed = self.feed
            for _ in 0..<3 {
                guard let entry = feed.nextDisplay(current: currentID) else { break }
                if let item = await makeDisplayItem(entry, from: feed.pool.store) { return item }
            }
            return nil
        }
        let recent = await state.recent()
        let files = store.imageFiles().filter { $0.id != currentID }
        let fresh = files.filter { !recent.suffix(4).contains($0.id) }
        for file in (fresh.isEmpty ? files : fresh).shuffled().prefix(3) {
            if let item = await makeDisplayItem(store.entry(id: file.id, url: file.url)) { return item }
        }
        return nil
    }

    func standbyImage(index: Int) -> DisplayItem? {
        #if DEBUG
        if DebugLaunchOptions.testPattern || DebugLaunchOptions.testImagePath != nil { return nil }
        #endif
        let name = index.isMultiple(of: 2) ? "LiminalLightning" : "LiminalMushrooms"
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return DisplayItem(id: nil, cgImage: cg, image: Self.platformImage(cg), metadata: nil)
    }

    @MainActor
    func showReserved(_ item: DisplayItem) {
        imageBuffer.storeCurrent(item.cgImage, metadata: item.metadata, id: item.id)
        currentMetadata = item.metadata
        currentImage = item.image
        didShow(item.metadata)
        Task {
            await state.noteShown(item.id)
            queuedCount = await pendingCount()
        }
    }

    private func advanceAsync() async {
        #if os(visionOS)
        let advanced = imageBuffer.advanceFromQueue()
        let metadata = imageBuffer.loadCurrentMetadata()
        if advanced {
            await state.noteShown(metadata?.id)
            didShow(metadata)
        }
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
        didShow(item.metadata)
        let following = await state.first()
        let remaining = await state.count()
        imageBuffer.store(current: item.cgImage, next: following?.cgImage, metadata: item.metadata, id: item.id)
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
            imageBuffer.queuePending(item.cgImage, metadata: item.metadata, id: item.id)
        } else {
            imageBuffer.storeCurrent(item.cgImage, metadata: item.metadata, id: item.id)
            await state.noteShown(item.id)
            didShow(item.metadata)
            await MainActor.run { self.currentMetadata = item.metadata }
        }
        let pending = imageBuffer.pendingCount()
        if pending == 1 { ArchiveFootageService.shared.queuedImage(item.metadata) }
        await MainActor.run { self.queuedCount = pending }
        #else
        if imageBuffer.loadCurrent() == nil {
            imageBuffer.storeCurrent(item.cgImage, metadata: item.metadata, id: item.id)
            await state.noteShown(item.id)
            didShow(item.metadata)
            await MainActor.run {
                self.currentImage = item.image
                self.currentMetadata = item.metadata
            }
        } else {
            await state.append(item)
        }
        let queued = await state.count()
        if queued == 1 { ArchiveFootageService.shared.queuedImage(item.metadata) }
        await MainActor.run { self.queuedCount = queued }
        #endif
    }

    private func publishCachedCount(_ count: Int) async {
        await MainActor.run { self.totalCachedCount = count }
    }

    /// Decodes one stored image (lazily, one at a time) and upscales it if it is small.
    /// API pool pictures are never upscaled: the ingest gate already keeps their 3:2 crop at 2000 x 1333
    /// or more, and on a visionOS device the MetalFX path (long side under 2048) would make a 2000-2047 px
    /// picture four times larger for no visible gain.
    private func makeDisplayItem(_ entry: ImageStore.Entry, from source: ImageStore? = nil) async -> DisplayItem? {
        let fromPool = source.map { $0 !== store } ?? false
        guard let raw = (source ?? store).loadImage(entry) else { return nil }
        let display = fromPool ? raw : await upscaleIfNeeded(raw)
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

    // MARK: - API feed (docs/plans/image-api-mode.md 4.3)

    /// Display loop of API mode: keeps `targetPendingCount` pool pictures queued (disk only, never the
    /// network) and starts the ingest loop beside it. No Gemini, no budget, no prompt history.
    private func startAPIFeed() {
        guard generationTask == nil || generationTask?.isCancelled == true else { return }
        let feed = self.feed
        let generation = sourceGeneration
        feed.startIngest()
        LMLog.visual.info("🖼️ [ImageQueue] API feed starting")
        generationTask = Task.detached { [weak self] in
            feed.pool.loadIfNeeded()
            var lastStatus: String?? = .none
            var lastLine: (String, Bool)?
            while !Task.isCancelled {
                guard let self, self.sourceGeneration == generation else { return }
                if await self.pendingCount() < self.config.targetPendingCount {
                    let current = self.imageBuffer.loadCurrentMetadata()?.id
                    if let entry = feed.nextDisplay(current: current),
                       let item = await self.makeDisplayItem(entry, from: feed.pool.store) {
                        guard !Task.isCancelled, self.sourceGeneration == generation else { return }
                        await self.enqueue(item)
                    }
                }
                let message = feed.statusMessage()
                let line = feed.statusLine()
                let count = feed.pool.count
                if lastStatus != .some(message) || lastLine?.0 != line.text || lastLine?.1 != line.ok {
                    lastStatus = .some(message)
                    lastLine = (line.text, line.ok)
                    await MainActor.run {
                        self.statusMessage = message
                        self.sourceStatus = line
                    }
                }
                await MainActor.run { if self.totalCachedCount != count { self.totalCachedCount = count } }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            LMLog.visual.info("🖼️ [ImageQueue] API feed stopped")
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
                            self.statusMessage = Self.noCachedImagesMessage
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

    #if DEBUG
    // MARK: - Test directory (-LiminalTestImage <directory>)

    private static func testDirectoryItem(_ url: URL) -> DisplayItem? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return DisplayItem(id: nil, cgImage: img, image: platformImage(img), metadata: nil)
    }

    /// Keeps the queue topped up with the directory's images in order (wrapping), like the recycler.
    private func startTestDirectoryCycler() {
        guard let files = DebugLaunchOptions.testImageDirectoryFiles,
              generationTask == nil || generationTask?.isCancelled == true else { return }
        generationTask = Task.detached { [weak self] in
            var index = 1
            while !Task.isCancelled {
                guard let self else { return }
                if await self.pendingCount() < self.config.targetPendingCount,
                   let item = Self.testDirectoryItem(files[index % files.count]) {
                    await self.enqueue(item)
                    LMLog.visual.info("🧪 [ImageQueue] queued test image \(files[index % files.count].lastPathComponent, privacy: .public)")
                    index += 1
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
    #endif

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

                // Keep only the next image ready during footage playback so a reference
                // reaches the screen sooner. Elsewhere keep the usual generation cushion.
                let footage = ArchiveFootageService.shared
                let target = footage.isPlayingForImageGeneration ? 1 : self.config.targetPendingCount
                if self.imageBuffer.hasCurrent(), await self.pendingCount() >= target {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }

                let now = Date()
                if router.allCoolingDown(now: now) {
                    // Keep the display moving from the cache until a model is back.
                    let billingPaused = router.isBillingPaused(now: now)
                    let recycled = await self.recycleOneFromCache()
                    let reason = billingPaused ? "Gemini billing paused generation" : "Image models busy"
                    let status = recycled ? "\(reason), showing cached images" : "\(reason), no cached images available"
                    await MainActor.run { self.statusMessage = status }
                    let wait = min(5, max(1, router.delayBeforeNextAttempt(now: now)))
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
                }
                let delay = router.delayBeforeNextAttempt(now: now)
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }

                // Spending cap (D34): past the hourly/daily limit, show cached images until it rolls.
                if case .limited(let resumeAt, let perHour) = GenerationBudget.shared.check(now: now) {
                    let mins = max(1, Int(ceil(resumeAt.timeIntervalSince(now) / 60)))
                    let msg = perHour
                        ? "Hourly image limit reached, showing cached images (new ones in about \(mins) min)"
                        : "Daily image limit reached, showing cached images (new ones in about \(mins < 120 ? "\(mins) min" : "\(mins / 60) h"))"
                    await MainActor.run { self.statusMessage = msg }
                    LMLog.visual.info("💰 [Budget] \(msg, privacy: .public)")
                    await self.recycleOneFromCache()
                    // Recheck during the cache-recycling pause so resetting the counts can
                    // resume normal generation immediately when the queue has room.
                    for _ in 0..<30 {
                        guard !Task.isCancelled, GenerationBudget.shared.check() != .allowed else { break }
                        try? await Task.sleep(for: .seconds(1))
                    }
                    continue
                }

                let spec = self.promptSource?() ?? self.director.next()
                guard let model = router.model(for: spec, now: now, using: &rng) else { continue }
                let clearGeneration = self.store.clearGeneration

                await MainActor.run { self.isGenerating = true }
                do {
                    let reference = await footage.imageReference()
                    try Task.checkCancellation()
                    let (generated, provenance) = try await self.requestImage(spec: spec, model: model, reference: reference)
                    GenerationBudget.shared.record()
                    router.recordSuccess(model: model)
                    await MainActor.run { self.isGenerating = false; self.statusMessage = nil }
                    guard !Task.isCancelled else { break }
                    await self.handleGenerated(generated, spec: spec, archiveReference: provenance,
                                               clearGeneration: clearGeneration)
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

    /// Keep Liminal's subject, transformation and palette, with optional details borrowed from a film.
    static func generationPrompt(for spec: PromptSpec, usesArchiveFrame: Bool) -> String {
        let frameDirection = usesArchiveFrame ? """


        Use the attached archive frame only as a source of small visual motifs. Pick one or two
        recognizable inanimate objects, materials, or shapes and weave them into the psychedelic
        transformation described above. Invent a different setting and composition. Ignore the
        source scene, camera angle, grayscale, colors, grain, blur, borders, captions, and logos.
        Keep the vivid palette and crisp detail of the original art direction. If the frame has
        no useful objects, use a surface pattern or abstract shape.
        """ : ""
        return spec.text + frameDirection + """


        Hard constraint for the finished image: No humans, faces, or facial features. Exclude
        portraits, human bodies, hands, human silhouettes, mannequins, and face-like patterns,
        including in reflections or in the background. Use objects, environments, natural forms,
        or abstract shapes. When a prompt or reference suggests a person or face, omit it entirely.
        """
    }

    /// Keep size and aspect independent of the reference dimensions. A fallback
    /// model that rejects imageSize is retried once without it.
    private func requestImage(spec: PromptSpec, model: String, reference: ArchiveFootageService.ImageReference?)
        async throws -> (GeneratedImageData, ImageMetadata.ArchiveReference?) {
        // Second lock on the Gemini path: API mode never generates.
        guard activeSource == .ai else { throw CancellationError() }
        func generate(_ prompt: String, jpeg: Data?) async throws -> GeneratedImageData {
            let size = config.imageSize(for: model)
            do {
                return try await gemini.generate(prompt: prompt, model: model, aspectRatio: config.aspectRatio,
                                                 imageSize: size, referenceJPEG: jpeg)
            } catch let error as GeminiError where error.isImageConfigRejection && model != config.primaryModel {
                try Task.checkCancellation()
                LMLog.visual.warning("🔄 [Pipeline] \(model) rejected imageSize, retrying without it")
                return try await gemini.generate(prompt: prompt, model: model, aspectRatio: config.aspectRatio,
                                                 imageSize: nil, referenceJPEG: jpeg)
            }
        }

        if let reference {
            let prompt = Self.generationPrompt(for: spec, usesArchiveFrame: true)
            LMLog.visual.info("📼🖼️ Generating from \(reference.clipID, privacy: .public) at \(reference.sourceTime, format: .fixed(precision: 2), privacy: .public)s, \(reference.width)x\(reference.height)")
            do {
                let generated = try await generate(prompt, jpeg: reference.jpeg)
                return (generated, .init(clipID: reference.clipID, sourceTime: reference.sourceTime,
                                         width: reference.width, height: reference.height, prompt: prompt,
                                         plannedStart: reference.plannedStart, cachedSince: reference.cachedSince))
            } catch let error as GeminiError where error.isReferenceRejection {
                try Task.checkCancellation()
                LMLog.visual.warning("📼🖼️ Reference request declined; falling back to the standard image prompt")
            }
        }
        return (try await generate(Self.generationPrompt(for: spec, usesArchiveFrame: false), jpeg: nil), nil)
    }

    /// Trim, measure, store, upscale if needed, queue. Drops the image if a clear happened meanwhile.
    private func handleGenerated(_ generated: GeneratedImageData, spec: PromptSpec,
                                 archiveReference: ImageMetadata.ArchiveReference?, clearGeneration: UInt64) async {
        guard clearGeneration == store.clearGeneration else {
            LMLog.visual.info("🗑️ [Pipeline] dropping image generated before Clear All Images")
            return
        }
        guard activeSource == .ai else {
            LMLog.visual.info("🖼️ [Pipeline] dropping a Gemini image that finished after switching to API")
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
            measuredSaturation: analysis.saturation,
            archiveReference: archiveReference
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
        LMLog.visual.info("🔄 [Pipeline] ✅ \(spec.styleID, privacy: .public)/\(spec.paletteID, privacy: .public) \(display.width)x\(display.height) via \(generated.model)")
    }
}
