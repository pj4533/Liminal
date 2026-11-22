//
//  ImagePipelineTests.swift
//  LiminalTests
//
//  The drum-timed picture reveals, ImageStore save/clear/epoch behaviour, and the border
//  trimmer / saturation meter.
//

import Foundation
import CoreGraphics
import Testing
@testable import Liminal

// MARK: - Helpers

private func makeImage(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx)
    return ctx.makeImage()!
}

// MARK: - Reveals

struct LofiImageRevealTests {

    /// docs/plans/drop-transitions.md 8.1: the drop builds from the fill and is done on the downbeat.
    @Test func lofiImageIsCleanOnTheFillDownbeat() throws {
        for tempo in [58.0, 69, 82] {
            let beat = LofiClock(tempo: tempo, sampleRate: 48_000).beatDuration
            let grid = LofiTakeGrid(origin: 91.37, beatDuration: beat)
            for count in [32, 64] {
                for style in TransitionStyle.dropFamily {
                    let downbeat = grid.origin + Double(count) * beat
                    let planned = LofiImageReveal.next(
                        on: grid, after: downbeat - 8, now: downbeat - 8, fills: nil, hasDrums: true,
                        pickDrop: { build, _, strength in .pinnedDrop(style, seed: count, duration: Float(build), strength: strength) },
                        pickBell: { _ in .classic })
                    let cue = try #require(planned.reveal)
                    #expect(cue.spec.style == style)
                    #expect(abs(cue.downbeat - grid.nextBoundary(after: downbeat - 8).time) < 1e-9)
                    // Default builds: 2 beats before the halfway change, 4 before the turnaround.
                    #expect(abs((downbeat - cue.fillStart) / beat - (count == 32 ? 2 : 4)) < 1e-6)
                    #expect(cue.frame(presentedAt: downbeat).done)
                    #expect(!cue.frame(presentedAt: downbeat - 1.0 / 60).done)
                    #expect(cue.spec.envelope(cue.frame(presentedAt: downbeat - 1.0 / 60).progress) >= 0.9 * cue.spec.drop!.strength)
                    #expect(cue.progress(at: cue.start) == 0)
                    #expect(cue.spec.drop!.strength == (count == 64 ? 1 : DropPlan.halfwayStrength))
                }
            }
        }
    }

    @Test func lofiRevealsVaryTheirTransitionStyle() throws {
        let beat = LofiClock(tempo: 72, sampleRate: 48_000).beatDuration
        let grid = LofiTakeGrid(origin: 10, beatDuration: beat)
        var director = TransitionDirector(seed: 7)
        var styles: [TransitionStyle] = []
        var after = grid.origin
        for _ in 0..<24 {
            let planned = LofiImageReveal.next(
                on: grid, after: after, now: after, fills: nil, hasDrums: true,
                pickDrop: { build, fill, strength in
                    director.nextDrop(time: 0, intensity: 0.6, build: Float(build), halfway: fill == .halfway, strength: strength)
                },
                pickBell: { _ in .classic })
            let cue = try #require(planned.reveal)
            styles.append(cue.spec.style)
            after = cue.downbeat + 0.01
        }
        #expect(!styles.contains(.classic))
        #expect(Set(styles).count >= 8)
        #expect(styles.allSatisfy { TransitionStyle.dropFamily.contains($0) })
        for (a, b) in zip(styles, styles.dropFirst()) { #expect(a != b) }
    }

    /// -LiminalDropOff: the bell reveal of T43 (the swap ends on the downbeat, on whole beats of the fill).
    @Test func lofiBellRevealStillEndsItsSwapOnTheDownbeat() throws {
        let beat = LofiClock(tempo: 69, sampleRate: 48_000).beatDuration
        let grid = LofiTakeGrid(origin: 91.37, beatDuration: beat)
        for style in TransitionStyle.family {
            let downbeat = grid.origin + 64 * beat
            let planned = LofiImageReveal.next(on: grid, after: downbeat - 6, now: downbeat - 6, fills: nil, hasDrums: true,
                                               drop: false, pickDrop: { _, _, _ in .classic },
                                               pickBell: { _ in .pinned(style, seed: 3) })
            let cue = try #require(planned.reveal)
            #expect(!cue.isDrop)
            #expect(cue.spec.swap(Float(cue.progress(at: downbeat))) > 0.9999)
            let leadBeats = (downbeat - cue.start) / beat
            #expect(leadBeats >= 2 - 1e-6 && abs(leadBeats - leadBeats.rounded()) < 1e-6)
        }
    }
}

// MARK: - ImageStore

struct ImageStoreTests {

    private static let epochKey = "test.epoch"

    private func makeStore() -> (ImageStore, URL, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiminalStoreTests-\(UUID().uuidString)")
        let suite = "LiminalStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (ImageStore(root: root, defaults: defaults, directoryName: "TestStore", epochKey: Self.epochKey, epoch: 2),
                root, defaults)
    }

    private func jpeg() -> Data {
        let image = makeImage(width: 60, height: 40) { ctx in
            ctx.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.4, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        }
        return ImageStore.encodeJPEG(image)!
    }

    private func metadata() -> ImageMetadata {
        ImageMetadata(id: UUID(), createdAt: Date(), pixelWidth: 60, pixelHeight: 40, mimeType: "image/jpeg",
                      measuredSaturation: 0.5)
    }

    @Test func saveListAndLoad() throws {
        let (store, root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let md = metadata()
        try store.save(jpeg: jpeg(), metadata: md, clearGeneration: store.clearGeneration)
        let entries = store.entries()
        #expect(entries.count == 1)
        #expect(entries[0].id == md.id)
        // The sidecar stores dates as ISO 8601 (whole seconds), so compare the other fields.
        #expect(entries[0].metadata?.id == md.id && entries[0].metadata?.measuredSaturation == md.measuredSaturation)
        #expect(store.entry(id: md.id, url: entries[0].imageURL).metadata?.pixelWidth == 60)
        #expect(store.loadImage(entries[0])?.width == 60)
        #expect(store.usage().imageCount == 1)
    }

    @Test func clearEverythingRemovesPicturesAndSidecars() throws {
        let (store, root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try store.save(jpeg: jpeg(), metadata: metadata(), clearGeneration: store.clearGeneration)
        try store.save(jpeg: jpeg(), metadata: metadata(), clearGeneration: store.clearGeneration)
        let before = store.clearGeneration
        let removed = store.clearEverything()
        #expect(removed.imageCount == 2)
        #expect(store.clearGeneration == before + 1)
        #expect(try fm.contentsOfDirectory(atPath: store.directory.path).isEmpty)
        #expect(store.usage() == ImageStore.Usage(imageCount: 0, bytes: 0))
    }

    @Test func staleClearGenerationIsRefused() throws {
        let (store, root, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let captured = store.clearGeneration
        store.clearEverything()
        #expect(throws: ImageStore.StoreError.self) {
            try store.save(jpeg: jpeg(), metadata: metadata(), clearGeneration: captured)
        }
        #expect(store.entries().isEmpty)
    }

    @Test func epochBumpPurges() throws {
        let (store, root, defaults) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(jpeg: jpeg(), metadata: metadata(), clearGeneration: store.clearGeneration)

        // Missing epoch (an old install): everything goes.
        store.migrateIfNeeded()
        #expect(store.entries().isEmpty)
        #expect(defaults.integer(forKey: Self.epochKey) == 2)

        // Same epoch: nothing is touched.
        try store.save(jpeg: jpeg(), metadata: metadata(), clearGeneration: store.clearGeneration)
        store.migrateIfNeeded()
        #expect(store.entries().count == 1)
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

    @Test func meanSaturation() {
        let image = makeImage(width: 90, height: 60) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 60, y: 0, width: 30, height: 60))
        }
        #expect(SaturationMeter.meanSaturation(image) > 0.9)
        let grey = makeImage(width: 90, height: 60) { ctx in
            ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 90, height: 60))
        }
        #expect(SaturationMeter.meanSaturation(grey) < 0.01)
    }
}
