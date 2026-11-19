//
//  ImagePipelineTests.swift
//  LiminalTests
//
//  ModelRouter fallback/cooldown rules, ImageStore save/clear/epoch behavior,
//  and the border trimmer / color extractor.
//

import Foundation
import CoreGraphics
import Testing
@testable import Liminal

struct ArchiveReferenceRequestTests {
    @Test func filmReferenceUsesImageInputAndKeepsTheConfiguredOutputSize() throws {
        let spec = sampleSpec()
        let prompt = ImageQueue.generationPrompt(for: spec, usesArchiveFrame: true)
        let reference = Data([0xff, 0xd8, 0xff, 0xd9])
        let body = try GeminiClient.requestBody(prompt: prompt, aspectRatio: "3:2", imageSize: "2K",
                                                referenceJPEG: reference)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let contents = try #require(json["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])
        let inline = try #require(parts.last?["inlineData"] as? [String: String])
        let settings = try #require(json["generationConfig"] as? [String: Any])
        let image = try #require(settings["imageConfig"] as? [String: String])

        #expect(parts.first?["text"] as? String == prompt)
        #expect(prompt.hasPrefix(spec.text))
        #expect(prompt.contains("only as a source of small visual motifs"))
        #expect(prompt.contains("Invent a different setting and composition"))
        #expect(prompt.contains("No humans, faces, or facial features"))
        let fallback = ImageQueue.generationPrompt(for: spec, usesArchiveFrame: false)
        #expect(fallback.hasPrefix(spec.text))
        #expect(fallback.contains("No humans, faces, or facial features"))
        #expect(!fallback.contains("attached archive frame"))
        #expect(inline["mimeType"] == "image/jpeg")
        #expect(inline["data"].flatMap { Data(base64Encoded: $0) } == reference)
        #expect(image["aspectRatio"] == "3:2" && image["imageSize"] == "2K")
    }
}

// MARK: - Helpers

private func makeImage(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx)
    return ctx.makeImage()!
}

private func sampleSpec(strong: Bool = false) -> PromptSpec {
    var rng = SeededRNG(seed: 1)
    var history = PromptHistory()
    let builder = PromptBuilder()
    while true {
        let spec = builder.next(history: &history, using: &rng)
        if spec.needsStrongSurreal == strong { return spec }
    }
}

// MARK: - ModelRouter

struct ModelRouterTests {
    let config = ImageGenerationConfig.standard
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func primaryByDefault() {
        var router = ModelRouter(config: config)
        var rng = SeededRNG(seed: 1)
        #expect(router.model(for: sampleSpec(), now: t0, using: &rng) == config.primaryModel)
    }

    @Test func fallbackOrderOnQuotaErrors() {
        var router = ModelRouter(config: config)
        var rng = SeededRNG(seed: 1)
        let spec = sampleSpec()
        let codes: [GeminiError] = [.http(status: 429, message: "quota"), .http(status: 503, message: ""), .network("offline")]
        // Walk the whole chain, whatever its length: each failure moves to the next model.
        for (i, model) in config.chain.enumerated() {
            #expect(router.model(for: spec, now: t0, using: &rng) == model)
            router.recordFailure(model: model, error: codes[i % codes.count], now: t0)
        }
        #expect(router.model(for: spec, now: t0, using: &rng) == nil)
        #expect(router.allCoolingDown(now: t0))
        #expect(router.delayBeforeNextAttempt(now: t0) == ModelRouter.baseCooldown)
        // Primary comes back when its cooldown ends.
        let later = t0.addingTimeInterval(ModelRouter.baseCooldown + 1)
        #expect(router.model(for: spec, now: later, using: &rng) == config.primaryModel)
    }

    @Test func cooldownDoublesAndCaps() {
        var router = ModelRouter(config: config)
        let m = config.primaryModel
        var expected = ModelRouter.baseCooldown
        for _ in 0..<8 {
            router.recordFailure(model: m, error: .http(status: 500, message: ""), now: t0)
            #expect(router.cooldownRemaining(m, now: t0) == min(expected, ModelRouter.maxCooldown))
            expected *= 2
        }
        router.recordSuccess(model: m)
        #expect(!router.isCoolingDown(m, now: t0))
        router.recordFailure(model: m, error: .http(status: 500, message: ""), now: t0)
        #expect(router.cooldownRemaining(m, now: t0) == ModelRouter.baseCooldown)
    }

    @Test func billingErrorUsesCacheUntilAutomaticRetry() {
        var router = ModelRouter(config: config)
        var rng = SeededRNG(seed: 1)
        let model = config.primaryModel
        let error = GeminiError.http(status: 402, message: "Prepayment credits are depleted")
        router.recordFailure(model: model, error: error, now: t0)

        #expect(router.isBillingPaused(now: t0))
        #expect(router.allCoolingDown(now: t0))
        #expect(router.model(for: sampleSpec(), now: t0, using: &rng) == nil)
        let restart = ModelRouter(config: config)
        #expect(!restart.allCoolingDown(now: t0))

        let retry = t0.addingTimeInterval(ModelRouter.initialBillingCooldown)
        #expect(!router.allCoolingDown(now: retry))
        #expect(router.model(for: sampleSpec(), now: retry, using: &rng) == model)
        router.recordFailure(model: model, error: error, now: retry)
        #expect(router.delayBeforeNextAttempt(now: retry) == 2 * ModelRouter.initialBillingCooldown)

        let later = retry.addingTimeInterval(2 * ModelRouter.initialBillingCooldown)
        router.recordSuccess(model: model)
        router.recordFailure(model: model, error: error, now: later)
        #expect(router.delayBeforeNextAttempt(now: later) == ModelRouter.initialBillingCooldown)
    }

    @Test func safetyBlockKeepsModelAndPausesAfterThree() {
        var router = ModelRouter(config: config)
        var rng = SeededRNG(seed: 1)
        let spec = sampleSpec()
        for _ in 0..<2 {
            router.recordFailure(model: config.primaryModel, error: .noImage(finishReason: "SAFETY"), now: t0)
            #expect(router.model(for: spec, now: t0, using: &rng) == config.primaryModel)
            #expect(router.delayBeforeNextAttempt(now: t0) == 0)
        }
        router.recordFailure(model: config.primaryModel, error: .noImage(finishReason: "SAFETY"), now: t0)
        #expect(router.model(for: spec, now: t0, using: &rng) == config.primaryModel)
        #expect(router.delayBeforeNextAttempt(now: t0) == ModelRouter.safetyPause)
    }

    @Test func strongSurrealSometimesUsesSurrealModel() {
        // The split is off in the shipping config (D35); the mechanism is kept and tested here.
        var config = self.config
        config.surrealModel = "test-surreal-model"
        config.surrealModelShare = 0.5
        var router = ModelRouter(config: config)
        var rng = SeededRNG(seed: 9)
        let spec = sampleSpec(strong: true)
        let picks = (0..<200).compactMap { _ in router.model(for: spec, now: t0, using: &rng) }
        let surreal = picks.filter { $0 == config.surrealModel }.count
        #expect(surreal > 60 && surreal < 140)
        let plain = sampleSpec(strong: false)
        #expect((0..<50).allSatisfy { _ in router.model(for: plain, now: t0, using: &rng) == config.primaryModel })
    }

    @Test func errorClassification() {
        #expect(GeminiError.http(status: 429, message: "").isQuotaOrServer)
        #expect(GeminiError.http(status: 404, message: "").isQuotaOrServer)
        #expect(!GeminiError.http(status: 400, message: "").isQuotaOrServer)
        #expect(GeminiError.http(status: 400, message: "Invalid imageSize").isImageConfigRejection)
        #expect(!GeminiError.noImage(finishReason: nil).isQuotaOrServer)
    }
}

// MARK: - ImageStore

struct ImageStoreTests {

    private func makeStore() -> (ImageStore, URL, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiminalStoreTests-\(UUID().uuidString)")
        let suite = "LiminalStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (ImageStore(root: root, defaults: defaults), root, defaults)
    }

    @Test func lofiImageIsFullyInOnTheFillDownbeat() {
        for tempo in [58.0, 69, 82] {
            let beat = LofiClock(tempo: tempo, sampleRate: 48_000).beatDuration
            let grid = LofiTakeGrid(origin: 91.37, beatDuration: beat)
            for count in [32, 64] {
                for style in TransitionStyle.family {
                    let downbeat = grid.origin + Double(count) * beat
                    let cue = LofiImageReveal.next(on: grid, after: downbeat - 6) { _ in .pinned(style, seed: count) }
                    let film = grid.nextBoundary(after: downbeat - 6)
                    #expect(cue.spec.style == style)
                    #expect(abs(cue.downbeat - film.time) < 1e-9)
                    // The warp carries the exchange through the fill; the new picture is fully in on the downbeat.
                    #expect(cue.spec.swap(Float(cue.progress(at: downbeat))) > 0.9999)
                    #expect(cue.spec.swap(Float(cue.progress(at: downbeat - 0.25 * beat))) < 1)
                    #expect(cue.spec.envelope(Float(cue.progress(at: downbeat - beat))) > 0.5)
                    // The surge starts on a whole beat of the fill, at least two beats out.
                    let leadBeats = (downbeat - cue.start) / beat
                    #expect(leadBeats >= 2 - 1e-6 && abs(leadBeats - leadBeats.rounded()) < 1e-6)
                    #expect(cue.progress(at: cue.start - 0.01) == 0)
                    #expect(cue.progress(at: cue.start + cue.duration + 0.01) == 1)
                }
            }
        }
    }

    /// Regression (6dc0999 pinned every Lo-Fi reveal to `.classic`): drum-timed reveals use the whole family.
    @Test func lofiRevealsVaryTheirTransitionStyle() {
        let beat = LofiClock(tempo: 72, sampleRate: 48_000).beatDuration
        let grid = LofiTakeGrid(origin: 10, beatDuration: beat)
        var director = TransitionDirector(seed: 7)
        var styles: [TransitionStyle] = []
        var after = grid.origin
        for _ in 0..<24 {
            let cue = LofiImageReveal.next(on: grid, after: after) {
                director.next(time: 0, intensity: 0.6, energy: 0.5, hasDepth: false, imageInterval: Float($0))
            }
            styles.append(cue.spec.style)
            after = cue.downbeat + 0.01
        }
        #expect(!styles.contains(.classic))
        #expect(Set(styles).count >= 8)
        for (a, b) in zip(styles, styles.dropFirst()) { #expect(a != b) }
    }

    @Test func emptyImageStoreHasTwoDistinctBundledPicturesForFills() async throws {
        let (store, root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = ImageQueue(store: store)
        #expect(await queue.reserveForFill(excluding: nil) == nil)
        let first = try #require(queue.standbyImage(index: 0))
        let second = try #require(queue.standbyImage(index: 1))
        #expect(first.cgImage.width != second.cgImage.width)
        #expect(store.imageFiles().isEmpty)
    }

    private func generated() -> GeneratedImageData {
        let image = makeImage(width: 60, height: 40) { ctx in
            ctx.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.4, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        }
        return GeneratedImageData(data: ImageStore.encodeJPEG(image)!, mimeType: "image/jpeg", cgImage: image,
                                  model: "test-model", latency: 1)
    }

    private func metadata() -> ImageMetadata {
        ImageMetadata(id: UUID(), createdAt: Date(), spec: sampleSpec(), model: "test-model", pixelWidth: 60,
                      pixelHeight: 40, mimeType: "image/jpeg", dominantColors: [], measuredBrightness: 0.5,
                      measuredSaturation: 0.5)
    }

    @Test func saveListAndLoad() throws {
        let (store, root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let md = metadata()
        try store.save(generated(), metadata: md, clearGeneration: store.clearGeneration)
        let entries = store.entries()
        #expect(entries.count == 1)
        #expect(entries[0].id == md.id)
        #expect(entries[0].metadata?.spec == md.spec)
        #expect(store.loadImage(entries[0])?.width == 60)
        #expect(store.usage().imageCount == 1)
        #expect(store.imageCount() == 1)
    }

    @Test func clearEverythingRemovesSidecarsDepthAndLegacy() throws {
        let (store, root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let md = metadata()
        try store.save(generated(), metadata: md, clearGeneration: store.clearGeneration)
        store.saveDepth(generated().cgImage, for: md.id)
        for legacy in ["RawImages", "UpscaledImages"] {
            let dir = root.appendingPathComponent(legacy)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: dir.appendingPathComponent("old.png"))
            try Data([1]).write(to: dir.appendingPathComponent("notes.txt"))
        }
        let before = store.clearGeneration
        let removed = store.clearEverything()
        #expect(removed.imageCount == 3)
        #expect(store.clearGeneration == before + 1)
        #expect(try fm.contentsOfDirectory(atPath: store.directory.path).isEmpty)
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("RawImages").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("UpscaledImages").path))
        #expect(store.usage() == ImageStore.Usage(imageCount: 0, bytes: 0))
    }

    @Test func staleClearGenerationIsRefused() throws {
        let (store, root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let captured = store.clearGeneration
        store.clearEverything()
        #expect(throws: ImageStore.StoreError.self) {
            try store.save(generated(), metadata: metadata(), clearGeneration: captured)
        }
        #expect(store.entries().isEmpty)
    }

    @Test func epochBumpPurges() throws {
        let (store, root, defaults) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("RawImages")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data([1]).write(to: legacy.appendingPathComponent("square.png"))
        try store.save(generated(), metadata: metadata(), clearGeneration: store.clearGeneration)

        // Missing epoch (an old install): everything goes.
        store.migrateIfNeeded()
        #expect(store.entries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(defaults.integer(forKey: ImageStore.epochDefaultsKey) == ImageStore.cacheEpoch)

        // Same epoch: nothing is touched.
        try store.save(generated(), metadata: metadata(), clearGeneration: store.clearGeneration)
        store.migrateIfNeeded()
        #expect(store.entries().count == 1)
    }

    @Test func promptDirectorResetClearsHistory() {
        let defaults = UserDefaults(suiteName: "LiminalDirectorTests-\(UUID().uuidString)")!
        let director = PromptDirector(defaults: defaults)
        _ = director.next()
        #expect(defaults.data(forKey: PromptDirector.historyKey) != nil)
        director.reset()
        #expect(defaults.data(forKey: PromptDirector.historyKey) == nil)
    }
}

// MARK: - Image analysis

struct ImageAnalysisTests {

    @Test func trimsWhiteBorder() {
        let image = makeImage(width: 600, height: 400) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            // Busy interior: stripes.
            for i in 0..<20 {
                ctx.setFillColor(CGColor(red: Double(i % 2), green: 0.3, blue: Double(i % 3) / 2, alpha: 1))
                ctx.fill(CGRect(x: 30 + i * 27, y: 30, width: 27, height: 340))
            }
        }
        let trimmed = BorderTrimmer.trimmedIfBordered(image)
        #expect(trimmed.width < 600 && trimmed.width > 500)
        #expect(trimmed.height < 400 && trimmed.height > 300)
    }

    @Test func leavesFullBleedImagesAlone() {
        let image = makeImage(width: 600, height: 400) { ctx in
            for i in 0..<20 {
                ctx.setFillColor(CGColor(red: Double(i % 2), green: 0.5, blue: 0.2, alpha: 1))
                ctx.fill(CGRect(x: i * 30, y: 0, width: 30, height: 400))
            }
        }
        #expect(BorderTrimmer.trimmedIfBordered(image).width == 600)
        // A dark studio photo with a dark surround must not be cropped either.
        let dark = makeImage(width: 600, height: 400) { ctx in
            ctx.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            ctx.setFillColor(CGColor(red: 0.9, green: 0.6, blue: 0.1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 200, y: 100, width: 200, height: 200))
        }
        #expect(BorderTrimmer.trimmedIfBordered(dark).width == 600)
    }

    @Test func dominantColors() {
        let image = makeImage(width: 90, height: 60) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 60, y: 0, width: 30, height: 60))
        }
        let result = DominantColorExtractor.analyze(image)
        #expect(result.colors.count >= 2)
        #expect(result.colors[0].r > 0.9 && result.colors[0].b < 0.1)
        #expect(result.saturation > 0.9)
    }

    @Test func upscaleSkipRule() {
        let big = makeImage(width: 2528, height: 1696) { _ in }
        let small = makeImage(width: 1264, height: 848) { _ in }
        #expect(ImageUpscaler.shouldSkipUpscale(big))
        #expect(!ImageUpscaler.shouldSkipUpscale(small))
    }
}
