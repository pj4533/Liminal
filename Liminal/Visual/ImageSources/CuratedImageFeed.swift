//
//  CuratedImageFeed.swift
//  Liminal
//
//  API mode's two halves (docs/plans/image-api-mode.md 4.3):
//  - ingest: one picture at a time from the next source in the rotation -> rights and size gates ->
//    download -> bounded decode -> border trim -> 3:2 window -> openness, document and face gates ->
//    colour analysis -> JPEG into the pool. Runs while fewer than `unseenAhead` never-shown pictures
//    wait, so the network only ever adds to the disk pool.
//  - display: picks the next stored picture (ImageRotation.nextDisplay). Reads only from disk, so
//    Lo-Fi's reserve deadline and offline use behave exactly as with the AI cache.
//  Never calls Gemini, never touches GenerationBudget or the prompt history.
//

import Foundation
import CoreGraphics
import ImageIO
import Synchronization
import Vision
import OSLog

nonisolated final class CuratedImageFeed: Sendable {

    enum Status: Sendable, Equatable {
        case starting
        /// Ingest is on and providers answer; `online` of `total` providers are not in backoff.
        case online(online: Int, total: Int)
        /// -LiminalImageAPIOffline, or every provider failed with no network.
        case offline
        /// Every provider is backing off (bot walls, server errors).
        case unavailable
    }

    let collections: ImageCollections
    let pool: CuratedImagePool
    let sources: [CuratedSource]
    private let providers: [String: any ImageProvider]
    private let http: ImageHTTP
    let offline: Bool

    private struct Backoff: Sendable {
        var step = 0
        var until = Date.distantPast
    }

    private struct State: Sendable {
        var bag = ImageRotation.SourceBag()
        var ingestRNG: SeededRNG
        var displayRNG: SeededRNG
        var backoff: [String: Backoff] = [:]
        /// Sources with nothing left to try, until this date.
        var dry: [String: Date] = [:]
        /// Picked for display but not yet shown (queued), with when. A pick that is dropped without being
        /// shown (a Lo-Fi stage that missed its reveal) expires after `reservationLifetime`.
        var reserved: [UUID: Date] = [:]
        var networkDown = false
        var ingested = 0
        var rejected = 0
        var ingestTask: Task<Void, Never>?
    }
    private let state: Mutex<State>

    static let backoffLadder: [TimeInterval] = [60, 120, 300, 900, 1800]
    static let perPage = 20
    /// Longer than any queue wait (two pending pictures at the longest image interval, or a Lo-Fi phrase).
    static let reservationLifetime: TimeInterval = 600
    /// Decoded pixels above this are refused before decoding: a small PNG can declare a huge canvas.
    static let maxSourcePixels = 150_000_000

    init(collections: ImageCollections = .bundled, pool: CuratedImagePool = .makeDefault(),
         providers: [String: any ImageProvider] = ImageProviders.all(),
         offline: Bool = DebugLaunchOptions.imageAPIOffline, filter: [String]? = DebugLaunchOptions.imageProviders,
         seed: UInt64? = DebugLaunchOptions.imageAPISeed) {
        self.collections = collections
        self.pool = pool
        self.providers = providers
        self.offline = offline
        sources = collections.activeSources(providers: Set(providers.keys), filter: filter)
        let d = collections.defaults
        http = ImageHTTP(userAgent: d.userAgent, offline: offline, hostGaps: d.hostGaps, defaultGap: d.defaultHostGap)
        let base = seed ?? UInt64.random(in: 0...UInt64.max)
        state = Mutex(State(ingestRNG: SeededRNG(seed: base), displayRNG: SeededRNG(seed: base &+ 0x5EED)))
        LMLog.visual.info("🖼️ [API] feed: \(self.sources.count) sources (\(self.sources.map(\.id).joined(separator: ","), privacy: .public)), offline=\(offline)")
    }

    private var sourceWeights: [String: Double] {
        Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.weight) })
    }

    // MARK: - Status

    var status: Status {
        let s = state.withLock { ($0.backoff, $0.networkDown) }
        if offline || s.1 { return .offline }
        let providerIDs = Set(sources.map(\.provider))
        guard !providerIDs.isEmpty else { return .unavailable }
        let now = Date()
        let online = providerIDs.filter { (s.0[$0]?.until ?? .distantPast) <= now }.count
        return online == 0 ? .unavailable : .online(online: online, total: providerIDs.count)
    }

    /// Short line for the UI, nil when there is nothing to say beyond the status row.
    func statusMessage() -> String? {
        let empty = pool.count == 0
        switch status {
        case .offline:
            return empty ? "Offline and no saved pictures yet." : nil
        case .unavailable:
            return empty ? "The image collections are not answering right now." : "Collections busy, showing saved pictures"
        case .starting, .online:
            return empty ? "Fetching the first pictures…" : nil
        }
    }

    /// "Curated collections: 5 sources online" and so on (APIStatusRow).
    func statusLine() -> (text: String, ok: Bool) {
        switch status {
        case .offline: return ("Offline, showing saved pictures", false)
        case .unavailable: return ("Collections not answering, showing saved pictures", false)
        case .starting: return ("Curated collections starting", true)
        case .online(let online, let total):
            return ("Curated collections: \(online) of \(total) sources online", online == total)
        }
    }

    // MARK: - Display

    /// The next stored picture to queue, never `current` or one already queued.
    func nextDisplay(current: UUID?) -> ImageStore.Entry? {
        pool.loadIfNeeded()
        let (items, history) = pool.displayItems(sourceWeights: sourceWeights)
        let now = Date()
        expireReservations(olderThan: Self.reservationLifetime, now: now)
        let reserved = state.withLock { Set($0.reserved.keys) }
        let open = items.filter { !reserved.contains($0.id) && $0.id != current }
        guard !open.isEmpty else { return nil }
        let rules = ImageRotation.DisplayRules(recencyWindow: collections.defaults.recencyWindow,
                                               monochromeEvery: collections.defaults.monochromeEvery)
        let pick = state.withLock { s in
            ImageRotation.nextDisplay(pool: open, history: history, current: current, rules: rules, using: &s.displayRNG)
        }
        guard let pick, let item = pool.item(pick.id) else { return nil }
        state.withLock { $0.reserved[pick.id] = now }
        return pool.store.entry(id: item.id, url: item.url)
    }

    /// The first frame at launch: the rotation's pick (a never-shown picture when there is one, else the
    /// least recently shown), not a random stored one (D48).
    func anyPicture() -> ImageStore.Entry? {
        nextDisplay(current: nil)
    }

    /// A picture became the one on screen.
    func markShown(_ metadata: ImageMetadata) {
        guard let credit = metadata.source else { return }
        // Recorded as shown before it is unreserved (a pick in between must not see it as new and free),
        // and unreserved before the ledger file is written.
        pool.markShown(metadata.id) { self.release(metadata.id) }
        LMLog.visual.info("🖼️ API image shown: source=\(credit.sourceID, privacy: .public) item=\(credit.itemID, privacy: .public) title=\(credit.title, privacy: .public) creator=\(credit.creator ?? "-", privacy: .public) license=\(credit.license, privacy: .public) url=\(credit.sourceURL, privacy: .public)")
    }

    /// Frees picks that were never shown (dropped stages), so they can be picked again.
    func expireReservations(olderThan lifetime: TimeInterval, now: Date = Date()) {
        state.withLock { s in s.reserved = s.reserved.filter { now.timeIntervalSince($0.value) < lifetime } }
    }

    /// A pick that will not be shown (the launch frame lost to another picture).
    func release(_ id: UUID) {
        state.withLock { _ = $0.reserved.removeValue(forKey: id) }
    }

    /// The display queue was drained (source switch, clear, stop).
    func releaseReserved() {
        state.withLock { $0.reserved.removeAll() }
    }

    func clear() -> ImageStore.Usage {
        releaseReserved()
        return pool.clear()
    }

    // MARK: - Ingest loop

    func startIngest() {
        state.withLock { s in
            guard s.ingestTask == nil else { return }
            s.ingestTask = Task.detached(priority: .background) { [weak self] in
                await self?.ingestLoop()
            }
        }
    }

    func stopIngest() {
        let task = state.withLock { s -> Task<Void, Never>? in
            defer { s.ingestTask = nil }
            return s.ingestTask
        }
        task?.cancel()
    }

    private func ingestLoop() async {
        pool.loadIfNeeded()
        // Pictures stored before fingerprints existed get one, and copies found twice are removed (D48).
        pool.backfillFingerprints()
        LMLog.visual.info("🖼️ [API] ingest starting: \(self.pool.count) pictures, \(self.pool.unseenCount) never shown")
        let d = collections.defaults
        while !Task.isCancelled {
            if offline {
                LMLog.visual.info("🖼️ [API] ingest off (-LiminalImageAPIOffline)")
                return
            }
            if pool.unseenCount >= d.unseenAhead {
                try? await Task.sleep(for: .seconds(5))
                continue
            }
            if let free = pool.freeBytes(), free < d.minFreeBytes {
                LMLog.visual.warning("🖼️ [API] ingest paused: \(free) bytes free")
                try? await Task.sleep(for: .seconds(60))
                continue
            }
            let now = Date()
            let available = state.withLock { s -> Set<String> in
                Set(sources.filter { src in
                    (s.backoff[src.provider]?.until ?? .distantPast) <= now && (s.dry[src.id] ?? .distantPast) <= now
                }.map(\.id))
            }
            let next = state.withLock { s in
                ImageRotation.nextSource(sources: sources, bag: &s.bag, available: available, using: &s.ingestRNG)
            }
            guard let source = next else {
                try? await Task.sleep(for: .seconds(10))
                continue
            }
            await ingestOne(from: source)
            try? await Task.sleep(for: .seconds(d.ingestInterval))
        }
        LMLog.visual.info("🖼️ [API] ingest stopped")
    }

    private func backOff(_ provider: String, _ error: Error) {
        let blocked = (error as? ImageFetchError) == .blocked
        let wait = state.withLock { s -> TimeInterval in
            var b = s.backoff[provider] ?? Backoff()
            let wait = blocked ? Self.backoffLadder.last! : Self.backoffLadder[min(b.step, Self.backoffLadder.count - 1)]
            b.step += 1
            b.until = Date().addingTimeInterval(wait)
            s.backoff[provider] = b
            s.networkDown = (error as? ImageFetchError) == .offline
            return wait
        }
        LMLog.visual.warning("🖼️ [API] \(provider, privacy: .public) backing off \(Int(wait / 60)) min: \(String(describing: error), privacy: .public)")
    }

    private func succeeded(_ provider: String) {
        state.withLock { s in
            s.backoff[provider] = nil
            s.networkDown = false
        }
    }

    /// One candidate from `source`, start to finish. Never throws: every outcome is logged and recorded.
    private func ingestOne(from source: CuratedSource) async {
        guard let provider = providers[source.provider] else { return }
        let candidate: ImageCandidate
        do {
            guard let c = try await nextCandidate(source: source, provider: provider) else {
                state.withLock { _ = $0.dry[source.id] = Date().addingTimeInterval(1800) }
                LMLog.visual.info("🖼️ [API] \(source.id, privacy: .public): nothing new to try for now")
                return
            }
            candidate = c
            succeeded(source.provider)
        } catch {
            // Stopping ingest (source switch, Stop, Clear) is not a provider failure.
            if Self.isCancellation(error) { return }
            backOff(source.provider, error)
            return
        }
        // The pool's clear generation now: a picture in flight during Clear is refused when saved.
        let clearGeneration = pool.store.clearGeneration

        let d = collections.defaults
        // Scans lose their film rebate after decode, so fetch them larger and scale back after the trim.
        let fetchTarget = (source.trimScanEdges ?? false) ? Self.scanFetchTarget(d.targetLongSide) : d.targetLongSide
        let context = ResolveContext(targetLongSide: fetchTarget, maxBytes: d.maxBytes,
                                     institution: collections.institution(provider: source.provider),
                                     allowlist: collections.licenseAllowlist)
        do {
            let resolved = try await provider.resolve(candidate, source: source, context: context, http: http)
            try Self.preDownloadGate(resolved, defaults: d)
            let tmp = pool.tmpDirectory.appendingPathComponent(UUID().uuidString + ".download")
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                try await http.download(resolved.url, to: tmp, maxBytes: d.maxBytes)
            } catch ImageFetchError.http(let code) where code >= 500 && resolved.fallbackURL != nil {
                try await http.download(resolved.fallbackURL!, to: tmp, maxBytes: d.maxBytes)
            }
            succeeded(source.provider)
            try Task.checkCancellation()
            let metadata = try store(file: tmp, resolved: resolved, source: source, clearGeneration: clearGeneration)
            state.withLock { $0.ingested += 1 }
            let o = metadata.openness
            LMLog.visual.info("🖼️ API image stored: source=\(source.id, privacy: .public) item=\(candidate.itemID, privacy: .public) size=\(metadata.pixelWidth)x\(metadata.pixelHeight) openness=\(o?.openness ?? 0, format: .fixed(precision: 2)) key=\(o?.keyShare ?? 0, format: .fixed(precision: 2)) license=\(resolved.credit.license, privacy: .public) url=\(resolved.url.absoluteString, privacy: .public)")
        } catch let rejection as CandidateRejected {
            reject(candidate, source: source, reason: rejection.reason)
        } catch let error as ImageFetchError where error.isItemFailure {
            reject(candidate, source: source, reason: error.description)
        } catch let error where Self.isCancellation(error) {
            return
        } catch ImageStore.StoreError.staleClearGeneration {
            LMLog.visual.info("🖼️ [API] dropped \(candidate.itemID, privacy: .public): the pool was cleared while it was fetched")
        } catch {
            backOff(source.provider, error)
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let u = error as? URLError, u.code == .cancelled { return true }
        return false
    }

    private func reject(_ c: ImageCandidate, source: CuratedSource, reason: String) {
        pool.recordRejected(c.key, reason: reason)
        state.withLock { $0.rejected += 1 }
        LMLog.visual.info("🖼️ API image rejected: source=\(source.id, privacy: .public) item=\(c.itemID, privacy: .public) reason=\(reason, privacy: .public)")
    }

    /// Pinned ids first, then each query's cached page, then the next page of a query.
    private func nextCandidate(source: CuratedSource, provider: any ImageProvider) async throws -> ImageCandidate? {
        // Candidate keys plus the catalogue aliases of stored pictures (D48).
        let seen = pool.knownIdentities
        if !source.pinnedIDs.isEmpty {
            let key = "\(source.id)|pinned"
            var list = pool.list(key)?.candidates
            if list == nil {
                let fetched = try await provider.pinned(source: source, ids: source.pinnedIDs, http: http)
                pool.setList(key, fetched)
                list = fetched
            }
            let pick = state.withLock { s in
                ImageRotation.nextCandidate(pinned: list ?? [], searched: [], seen: seen, using: &s.ingestRNG)
            }
            if let pick { return pick }
        }
        let queries = state.withLock { s in source.allQueries.shuffled(using: &s.ingestRNG) }
        var oldestFetch = Date()
        for query in queries {
            let key = "\(source.id)|\(query.key)"
            if let cached = pool.list(key) {
                oldestFetch = min(oldestFetch, cached.fetched)
                if let c = cached.candidates.first(where: { !ImageIdentity.isKnown($0, in: seen) }) { return c }
            }
            let cursor = pool.cursor(key)
            if cursor == .some("") { continue }   // no more pages
            let page = try await provider.search(source: source, query: query, cursor: cursor ?? nil,
                                                 perPage: Self.perPage, http: http)
            let fresh = page.candidates.filter { !ImageIdentity.isKnown($0, in: seen) }
            pool.setList(key, fresh)
            pool.setCursor(key, page.next)
            LMLog.visual.info("🖼️ [API] \(source.id, privacy: .public) \(query.key, privacy: .public): \(page.candidates.count) results, \(fresh.count) new")
            if let c = fresh.first { return c }
        }
        // Everything tried: after the refresh period, start the searches over (new uploads appear).
        if Date().timeIntervalSince(oldestFetch) > collections.defaults.candidateRefreshDays * 86_400 {
            pool.resetSearches(sourceID: source.id)
        }
        return nil
    }

    // MARK: - Gates and storing

    /// Size and type gates on what the provider declared, before spending a download.
    static func preDownloadGate(_ r: ResolvedImage, defaults d: ImageCollections.Defaults) throws {
        if let mime = r.mime, !d.allowedMime.contains(mime) { throw CandidateRejected(reason: "mime \(mime)") }
        if let bytes = r.bytes, bytes > d.maxBytes { throw CandidateRejected(reason: "\(bytes) bytes over maxBytes") }
        if let w = r.width, let h = r.height, !coverCropFits(width: w, height: h, defaults: d) {
            throw CandidateRejected(reason: "declared \(w)x\(h) too small for a 2K 3:2 crop")
        }
    }

    /// The 3:2 cover crop of w x h is at least minLongSide x minShortSide.
    static func coverCropFits(width w: Int, height h: Int, defaults d: ImageCollections.Defaults) -> Bool {
        let r = ImageFraming.coverCropRect(width: w, height: h)
        let cw = Double(w) * r.width, ch = Double(h) * r.height
        return cw >= Double(d.minLongSide) - 1 && ch >= Double(d.minShortSide) - 1
    }

    /// Long side to decode so the 3:2 crop is about `target` wide, capped at 2x target.
    static func decodeLongSide(width w: Int, height h: Int, target: Int) -> Int {
        guard w > 0, h > 0 else { return target }
        let aspect = Double(w) / Double(h)
        let factor: Double
        if aspect > 1.5 { factor = aspect / 1.5 }        // wide: crop width = 1.5 x height
        else if aspect < 1 { factor = 1 / aspect }       // portrait: crop width = width = long side x aspect
        else { factor = 1 }
        return min(max(w, h), Int((Double(target) * factor).rounded()), target * 2)
    }

    static func decode(_ url: URL, target: Int) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw CandidateRejected(reason: "not an image")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        var w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        var h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        guard w > 0, h > 0 else { throw CandidateRejected(reason: "no pixel size") }
        if w * h > maxSourcePixels { throw CandidateRejected(reason: "\(w)x\(h) is too many pixels to decode") }
        let maxPixel = decodeLongSide(width: w, height: h, target: target)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw CandidateRejected(reason: "decode failed")
        }
        return image
    }

    /// Decode, frame, gate, analyse and save. Returns the stored metadata.
    private func store(file: URL, resolved: ResolvedImage, source: CuratedSource, clearGeneration: UInt64) throws -> ImageMetadata {
        let d = collections.defaults
        var decoded: CGImage
        if source.trimScanEdges ?? false {
            var trimmed = ScanEdgeTrimmer.trimmed(try Self.decode(file, target: Self.scanFetchTarget(d.targetLongSide)))
            if let inset = source.edgeInset, inset > 0, inset < 0.25 {
                let dx = Double(trimmed.width) * inset, dy = Double(trimmed.height) * inset
                let rect = CGRect(x: dx, y: dy, width: Double(trimmed.width) - 2 * dx, height: Double(trimmed.height) - 2 * dy).integral
                trimmed = trimmed.cropping(to: rect) ?? trimmed
            }
            let limit = Self.decodeLongSide(width: trimmed.width, height: trimmed.height, target: d.targetLongSide)
            decoded = Self.scaled(trimmed, maxLongSide: limit) ?? trimmed
        } else {
            decoded = try Self.decode(file, target: d.targetLongSide)
        }
        var image = BorderTrimmer.trimmedIfBordered(decoded)
        if let window = ImageOpenness.bestWindow(image) {
            image = Self.copy(ImageFraming.crop(image, normalized: window)) ?? image
        }
        guard Self.coverCropFits(width: image.width, height: image.height, defaults: d) else {
            throw CandidateRejected(reason: "\(image.width)x\(image.height) too small for a 2K 3:2 crop")
        }
        let score = ImageOpenness.score(image)
        if let reason = ImageOpenness.rejection(score, allowMonochrome: source.allowMonochrome ?? false,
                                                thresholds: d.openness) {
            throw CandidateRejected(reason: reason)
        }
        if let reason = Self.visionRejection(image, paperShare: score.paperShare, thresholds: d.openness) { throw CandidateRejected(reason: reason) }

        // The same picture already in the pool under another id or source (D48).
        let fingerprint = ImageFingerprint.of(image)
        if let fingerprint, let copy = pool.duplicate(of: fingerprint) {
            throw CandidateRejected(reason: "duplicate of \(copy.candidateKey)")
        }
        let analysis = DominantColorExtractor.analyze(image)
        let metadata = ImageMetadata(
            id: UUID(), createdAt: Date(), spec: source.promptSpec, model: "api.\(source.provider)",
            pixelWidth: image.width, pixelHeight: image.height, mimeType: "image/jpeg",
            dominantColors: analysis.colors, measuredBrightness: analysis.brightness,
            measuredSaturation: analysis.saturation, archiveReference: nil, source: resolved.credit, openness: score)
        guard let jpeg = ImageStore.encodeJPEG(image, quality: 0.9) else { throw CandidateRejected(reason: "encode failed") }
        try pool.add(jpeg: jpeg, metadata: metadata, budget: d.storeBudgetBytes, clearGeneration: clearGeneration,
                     fingerprint: fingerprint, aliases: ImageIdentity.aliases(providerID: resolved.credit.providerID,
                                                                             itemID: resolved.credit.itemID))
        return metadata
    }

    /// A standalone copy of a cropped image (so the JPEG encoder and later readers do not keep the whole decode).
    /// Fetch and decode size for `trimScanEdges` sources: room for up to 15% rebate per side.
    static func scanFetchTarget(_ target: Int) -> Int { Int((Double(target) * 1.35).rounded()) }

    /// A copy no larger than `maxLongSide` on its long side (also a plain copy, so crops drop their parent).
    static func scaled(_ image: CGImage, maxLongSide: Int) -> CGImage? {
        let long = max(image.width, image.height)
        let scale = long > maxLongSide ? Double(maxLongSide) / Double(long) : 1
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func copy(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// Text (documents, captions) and prominent faces, on the 3:2 window that will be shown. If Vision
    /// fails (possible in the simulator) the check passes and the failure is logged.
    static func visionRejection(_ image: CGImage, paperShare: Double, thresholds t: OpennessThresholds) -> String? {
        #if targetEnvironment(simulator)
        // Vision cannot create its inference context in the visionOS Simulator: every attempt failed
        // (2026-11-21), and the failed setups during live ingest coincided with 100-320 ms render stalls
        // that an offline (no ingest) run did not have. The checks run on Macs and devices only.
        return nil
        #else
        let framed = ImageFraming.coverCrop(image)
        let text = VNDetectTextRectanglesRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: framed, options: [:])
        do {
            try handler.perform([text, faces])
        } catch {
            LMLog.visual.warning("🖼️ [API] Vision checks skipped: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // Signs are part of the brief (neon, diners, drive-ins), so text alone rejects only a page:
        // text on a paper-like picture, or text over a quarter of the frame.
        let textArea = (text.results ?? []).reduce(0.0) { $0 + Double($1.boundingBox.width * $1.boundingBox.height) }
        if textArea > 0.25 || (textArea > t.maxTextCoverage && paperShare > 0.3) {
            return String(format: "text covers %.0f%% of the frame", textArea * 100)
        }
        let faceBoxes = faces.results ?? []
        if faceBoxes.count > t.maxFaces { return "\(faceBoxes.count) faces" }
        if let biggest = faceBoxes.map({ Double($0.boundingBox.width * $0.boundingBox.height) }).max(), biggest > t.maxFaceArea {
            return String(format: "a face covers %.1f%% of the frame", biggest * 100)
        }
        return nil
        #endif
    }
}
