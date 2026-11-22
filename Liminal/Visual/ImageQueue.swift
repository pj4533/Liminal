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

/// Queues curated pictures for display.
///
/// Pipeline: CuratedImageFeed (ingest from the public collections into the pool, display rotation)
///           -> decode from the pool -> pending queue -> `reserveForFill` at each drum-timed reveal.
///
/// 1. AtomicImageBuffer: lock-protected buffer the 90fps render loop reads without MainActor.
/// 2. @Published properties: UI only, updated on MainActor, never read by the render loop.
///
/// The feed loop keeps `pendingTarget` pictures decoded ahead and reads only the disk pool, so a
/// reveal never waits on the network.
nonisolated final class ImageQueue: ObservableObject, @unchecked Sendable {

    // MARK: - Atomic Image Buffer (for render loop - bypasses MainActor)

    let imageBuffer = AtomicImageBuffer()

    // MARK: - State (MainActor for @Published - UI only, NOT render loop)

    @MainActor @Published private(set) var currentImage: PlatformImage?
    @MainActor @Published private(set) var currentMetadata: ImageMetadata?
    @MainActor @Published private(set) var queuedCount = 0
    /// Pictures saved in the pool.
    @MainActor @Published private(set) var poolCount = 0
    /// Short explanation for the UI when nothing new is coming (offline with an empty pool, collections busy).
    @MainActor @Published private(set) var statusMessage: String?
    /// "Curated collections: 5 of 5 sources online" and whether that is all well (CollectionsStatusRow).
    @MainActor @Published private(set) var sourceStatus: (text: String, ok: Bool)?

    // MARK: - Dependencies

    /// Ingest and display rotation over the pool.
    let feed: CuratedImageFeed

    /// Pictures decoded ahead of the next reveal.
    static let pendingTarget = 2

    // MARK: - Internal state

    /// One picture ready to show (macOS keeps PlatformImages for the SwiftUI crossfade).
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

    /// The decoded pictures waiting for a reveal, without touching MainActor.
    private actor Pending {
        var buffer: [DisplayItem] = []

        func append(_ item: DisplayItem) { buffer.append(item) }
        func removeFirst() -> DisplayItem? { buffer.isEmpty ? nil : buffer.removeFirst() }
        func count() -> Int { buffer.count }
        func clear() { buffer.removeAll() }
    }

    private let pending = Pending()
    private let taskLock = NSLock()
    nonisolated(unsafe) private var _feedTask: Task<Void, Never>?
    nonisolated(unsafe) private var _isRunning = false

    private var feedTask: Task<Void, Never>? {
        get { taskLock.withLock { _feedTask } }
        set { taskLock.withLock { _feedTask = newValue } }
    }
    private var isRunning: Bool {
        get { taskLock.withLock { _isRunning } }
        set { taskLock.withLock { _isRunning = newValue } }
    }

    // MARK: - Init

    init(feed: CuratedImageFeed = CuratedImageFeed()) {
        self.feed = feed
        Task.detached { [weak self] in
            await self?.loadInitialImage()
        }
    }

    // MARK: - Startup

    /// One random picture from the pool, else nothing (the first reveal shows the standby art).
    private func loadInitialImage() async {
        #if DEBUG
        if let files = DebugLaunchOptions.testImageDirectoryFiles {
            // -LiminalTestImage <directory>: show the first image; start() cycles the rest.
            guard let item = Self.testDirectoryItem(files[0]) else { return }
            imageBuffer.storeCurrent(item.cgImage, metadata: nil)
            await MainActor.run { self.currentImage = item.image }
            LMLog.visual.info("🧪 [ImageQueue] Test directory: \(files.count) images to cycle")
            return
        }
        if let path = DebugLaunchOptions.testImagePath,
           let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            // -LiminalTestImage: show only this image (deterministic before/after captures).
            imageBuffer.storeCurrent(img, metadata: nil)
            await MainActor.run { self.currentImage = Self.platformImage(img) }
            LMLog.visual.info("🧪 [ImageQueue] Test image shown (\(img.width)x\(img.height))")
            return
        }
        if DebugLaunchOptions.testPattern {
            // -LiminalTestPattern: show only the orientation/colour test card.
            let card = TestPatternGenerator.image
            imageBuffer.storeCurrent(card, metadata: nil)
            await MainActor.run { self.currentImage = Self.platformImage(card) }
            LMLog.visual.info("🧪 [ImageQueue] Test pattern shown (\(card.width)x\(card.height))")
            return
        }
        #endif
        let feed = self.feed
        feed.pool.loadIfNeeded()
        let count = feed.pool.count
        await MainActor.run { self.poolCount = count }
        LMLog.visual.info("📂 [ImageQueue] pool: \(count) pictures")
        guard !imageBuffer.hasCurrent(), let entry = feed.anyPicture() else { return }
        // The pick is reserved; a launch frame that is not shown after all goes back to the rotation.
        guard let item = makeDisplayItem(entry), !imageBuffer.hasCurrent() else {
            feed.release(entry.id)
            return
        }
        imageBuffer.storeCurrent(item.cgImage, metadata: item.metadata, id: item.id)
        didShow(item.metadata)
        await MainActor.run {
            self.currentImage = item.image
            self.currentMetadata = item.metadata
        }
    }

    /// Bookkeeping when a picture becomes the one on screen (rotation history and the credit log line).
    /// The ledger write and log line run on a detached task: `showReserved` is called on the main actor
    /// at the reveal, where the visionOS render loop must not wait on file I/O.
    private func didShow(_ metadata: ImageMetadata?) {
        guard let metadata, metadata.source != nil else { return }
        let feed = self.feed
        Task.detached(priority: .utility) { feed.markShown(metadata) }
    }

    // MARK: - Public API

    @MainActor
    func start() {
        isRunning = true
        #if DEBUG
        if DebugLaunchOptions.testImageDirectoryFiles != nil { startTestDirectoryCycler(); return }
        if DebugLaunchOptions.testPattern || DebugLaunchOptions.testImagePath != nil { return }  // fixed image only
        #endif
        statusMessage = nil
        LMLog.visual.info("ImageQueue starting")
        startFeed()
    }

    @MainActor
    func stop() {
        isRunning = false
        feedTask?.cancel()
        feedTask = nil
        feed.stopIngest()
        feed.releaseReserved()
        Task { await pending.clear() }
        queuedCount = 0
        LMLog.visual.info("ImageQueue stopped")
    }

    /// "Clear Curated Pictures": the pool and its ledger, the buffers and the UI mirrors.
    /// Fetching restarts if the queue was running.
    func clearAllImages() async {
        let task = feedTask
        feedTask = nil
        task?.cancel()
        await task?.value
        feed.stopIngest()
        let removed = feed.clear()
        imageBuffer.clear()
        await pending.clear()
        await MainActor.run {
            self.currentImage = nil
            self.currentMetadata = nil
            self.queuedCount = 0
            self.poolCount = 0
            NotificationCenter.default.post(name: .imageCacheCleared, object: nil)
        }
        LMLog.visual.info("🗑️ [ImageQueue] Clear Curated Pictures: removed \(removed.imageCount) pictures")
        if isRunning {
            await MainActor.run { self.start() }
        }
    }

    // MARK: - Reveals

    /// Reserve a distinct picture well ahead of the audio deadline: a queued one, else the next
    /// one from the pool. Nil when none can be decoded (the reveal then shows the standby art).
    @concurrent func reserveForFill(excluding currentID: UUID?) async -> DisplayItem? {
        #if DEBUG
        if DebugLaunchOptions.testPattern || (DebugLaunchOptions.testImagePath != nil && DebugLaunchOptions.testImageDirectoryFiles == nil) { return nil }
        #endif
        while let item = await pending.removeFirst() {
            if currentID == nil || item.id != currentID { return item }
        }
        for _ in 0..<3 {
            guard let entry = feed.nextDisplay(current: currentID) else { break }
            if let item = makeDisplayItem(entry) { return item }
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
        Task { queuedCount = await pending.count() }
    }

    // MARK: - Queueing helpers

    /// Shows the item now if nothing is on screen, otherwise queues it for the next reveal.
    private func enqueue(_ item: DisplayItem) async {
        if imageBuffer.hasCurrent() {
            await pending.append(item)
        } else {
            imageBuffer.storeCurrent(item.cgImage, metadata: item.metadata, id: item.id)
            didShow(item.metadata)
            await MainActor.run {
                self.currentImage = item.image
                self.currentMetadata = item.metadata
            }
        }
        let queued = await pending.count()
        await MainActor.run { self.queuedCount = queued }
    }

    /// Decodes one pool picture (lazily, one at a time). Never enlarged: the ingest gate already keeps
    /// the 3:2 crop at 2000 x 1333 or more.
    private func makeDisplayItem(_ entry: ImageStore.Entry) -> DisplayItem? {
        guard let image = feed.pool.store.loadImage(entry) else { return nil }
        return DisplayItem(id: entry.id, cgImage: image, image: Self.platformImage(image), metadata: entry.metadata)
    }

    // MARK: - Feed (docs/plans/image-api-mode.md 4.3)

    /// Keeps `pendingTarget` pool pictures queued (disk only, never the network), starts the ingest
    /// loop beside it and mirrors the feed's status for the UI.
    private func startFeed() {
        guard feedTask == nil || feedTask?.isCancelled == true else { return }
        let feed = self.feed
        feed.startIngest()
        LMLog.visual.info("🖼️ [ImageQueue] feed starting")
        feedTask = Task.detached { [weak self] in
            feed.pool.loadIfNeeded()
            var lastStatus: String?? = .none
            var lastLine: (String, Bool)?
            while !Task.isCancelled {
                guard let self else { return }
                if await self.pending.count() < Self.pendingTarget {
                    let current = self.imageBuffer.loadCurrentMetadata()?.id
                    if let entry = feed.nextDisplay(current: current), let item = self.makeDisplayItem(entry) {
                        guard !Task.isCancelled else { return }
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
                await MainActor.run { if self.poolCount != count { self.poolCount = count } }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            LMLog.visual.info("🖼️ [ImageQueue] feed stopped")
        }
    }

    #if DEBUG
    // MARK: - Test directory (-LiminalTestImage <directory>)

    private static func testDirectoryItem(_ url: URL) -> DisplayItem? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return DisplayItem(id: nil, cgImage: img, image: platformImage(img), metadata: nil)
    }

    /// Keeps the queue topped up with the directory's images in order (wrapping).
    private func startTestDirectoryCycler() {
        guard let files = DebugLaunchOptions.testImageDirectoryFiles,
              feedTask == nil || feedTask?.isCancelled == true else { return }
        feedTask = Task.detached { [weak self] in
            var index = 1
            while !Task.isCancelled {
                guard let self else { return }
                if await self.pending.count() < Self.pendingTarget,
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
}
