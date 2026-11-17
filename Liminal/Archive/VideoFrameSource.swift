//
//  VideoFrameSource.swift
//  Liminal
//
//  Decodes a segment of a cached clip into the footage stage texture (docs/plans/archive-video.md 2.1).
//  Everything runs on its own serial queue: AVAssetReader (no player, no clock, no audio session, no
//  sound to the output) -> BGRA pixel buffer -> Metal texture (CVMetalTextureCache, byte-copy fallback)
//  -> videoPrepass into the next of three stage textures. The render loops only call `latest()`, one
//  lock read; a decode stall just holds the last frame.
//
//  Stage textures rotate through three, and `latest` changes only when a pre-pass has completed on the
//  GPU, so a texture is rewritten at the earliest two video frames (> 80 ms) after it was published,
//  longer than any render that samples it stays in flight (3 x 11 ms).
//

import AVFoundation
import CoreVideo
import Foundation
@preconcurrency import Metal
import os

nonisolated final class VideoFrameSource: @unchecked Sendable {
    static let stageWidth = 960
    static let stageHeight = 720

    struct Segment: Sendable {
        let url: URL
        let start: Double
        let length: Double
        let rate: Float
        let black: Float
        let white: Float
        /// Host uptime at which the picture is at `start` (nil: when decoding begins). A piece is prepared
        /// ahead of its crossfade with an anchor in the near future or past, so picture and sound stay in step.
        var anchorUptime: Double? = nil
        var pieceIndex: Int? = nil
    }

    let device: MTLDevice
    private let queue = DispatchQueue(label: "com.saygoodnight.Liminal.videoFrames", qos: .userInitiated)
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?
    private var stages: [MTLTexture] = []
    private var fallbackTexture: MTLTexture?
    private var loggedFallback = false

    // Queue-confined state
    private var segment: Segment?
    private var reader: AVAssetReader?
    private var track: AVAssetTrack?
    private var asset: AVURLAsset?
    private var output: AVAssetReaderTrackOutput?
    private var timer: DispatchSourceTimer?
    private var playStart: Double = 0
    private var lastFrameTime: Double = 0
    private var writeIndex = 0
    private var hasHistory = false
    private var pending: CMSampleBuffer?
    private var framesDecoded = 0
    private var loops = 0
    private var generation: UInt64 = 0

    struct Reference: Sendable {
        let url: URL
        let mediaTime: Double
        let pieceIndex: Int
    }

    private struct Published {
        var texture: MTLTexture?
        var reference: Reference?
        var ended = false
    }
    private let published = OSAllocatedUnfairLock(initialState: Published())

    init?(device: MTLDevice) {
        guard let cq = device.makeCommandQueue() else { return nil }
        self.device = device
        commandQueue = cq
        commandQueue.label = "Liminal archive footage pre-pass"
        if let lib = device.makeDefaultLibrary(), let fn = lib.makeFunction(name: "videoPrepass") {
            pipeline = try? device.makeComputePipelineState(function: fn)
        } else {
            pipeline = nil
        }
        if pipeline == nil { LMLog.visual.error("📼 videoPrepass pipeline unavailable: footage disabled") }
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: Self.stageWidth,
                                                         height: Self.stageHeight, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        stages = (0..<3).compactMap { _ in device.makeTexture(descriptor: d) }
        if stages.count != 3 || pipeline == nil { return nil }
    }

    /// The newest finished stage texture (nil when nothing is playing). Lock read only.
    func latest() -> MTLTexture? { published.withLock { $0.texture } }

    /// The raw source location of the latest frame that finished its video pass.
    func reference(for pieceIndex: Int) -> Reference? {
        published.withLock { frame in
            guard !frame.ended, frame.reference?.pieceIndex == pieceIndex else { return nil }
            return frame.reference
        }
    }

    /// True once the segment has played to its end (the service fades out early).
    var ended: Bool { published.withLock { $0.ended } }

    /// Latest play/stop request: a play whose track load finishes after a later stop is dropped.
    private let request = OSAllocatedUnfairLock(initialState: UInt64(0))

    func play(_ s: Segment) {
        let token = request.withLock { $0 &+= 1; return $0 }
        Task.detached(priority: .userInitiated) { [weak self] in
            let asset = AVURLAsset(url: s.url)
            let track = try? await asset.loadTracks(withMediaType: .video).first
            self?.queue.async {
                guard let self, self.request.withLock({ $0 }) == token else { return }
                self.startOnQueue(s, asset: asset, track: track)
            }
        }
    }

    func stop() {
        request.withLock { $0 &+= 1 }
        queue.async {
            self.teardown()
            self.published.withLock { $0 = Published() }
        }
    }

    // MARK: - Queue

    private func startOnQueue(_ s: Segment, asset: AVURLAsset, track: AVAssetTrack?) {
        teardown()
        guard let track else {
            LMLog.visual.error("📼 no video track in \(s.url.lastPathComponent, privacy: .public)")
            return
        }
        self.asset = asset
        self.track = track
        generation &+= 1
        segment = s
        hasHistory = false
        framesDecoded = 0
        loops = 0
        published.withLock { $0 = Published() }
        guard openReader(s) else { return }
        playStart = s.anchorUptime ?? Self.now()
        lastFrameTime = playStart
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(4))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
        LMLog.visual.info("📼 footage decode start \(s.url.lastPathComponent, privacy: .public) at \(String(format: "%.1f", s.start), privacy: .public)s for \(String(format: "%.1f", s.length), privacy: .public)s rate \(String(format: "%.2f", s.rate), privacy: .public)")
    }

    private func openReader(_ s: Segment) -> Bool {
        guard let asset, let track, let r = try? AVAssetReader(asset: asset) else {
            LMLog.visual.error("📼 cannot open \(s.url.lastPathComponent, privacy: .public)")
            return false
        }
        r.timeRange = CMTimeRange(start: CMTime(seconds: s.start, preferredTimescale: 600),
                                  duration: CMTime(seconds: s.length, preferredTimescale: 600))
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        o.alwaysCopiesSampleData = false
        guard r.canAdd(o) else { return false }
        r.add(o)
        guard r.startReading() else {
            LMLog.visual.error("📼 startReading failed: \(r.error?.localizedDescription ?? "?", privacy: .public)")
            return false
        }
        reader = r
        output = o
        pending = nil
        return true
    }

    private func teardown() {
        timer?.cancel()
        timer = nil
        reader?.cancelReading()
        reader = nil
        output = nil
        pending = nil
        segment = nil
        // Release the cache's hold on the segment's pixel buffers (in-flight pre-passes keep theirs).
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
    }

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    private func tick() {
        guard let s = segment, let output else { return }
        let now = Self.now()
        // Media time the picture should be at: the segment start plus slowed wall time.
        let target = s.start + (now - playStart) * Double(s.rate) - Double(loops) * s.length
        var newest: CMSampleBuffer?
        while true {
            if pending == nil { pending = output.copyNextSampleBuffer() }
            guard let sb = pending else {
                // End of the segment: loop it (the director fades out well before this normally).
                if reader?.status == .completed || reader?.status == .failed {
                    published.withLock { $0.ended = true }
                    loops += 1
                    if !openReader(s) { teardown(); return }
                }
                break
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            // Before the anchor the first frame is shown (held) so a prepared piece has a picture at once.
            if pts > target && (framesDecoded > 0 || newest != nil) { break }
            newest = sb
            pending = nil
        }
        guard let frame = newest, let pb = CMSampleBufferGetImageBuffer(frame) else { return }
        framesDecoded += 1
        // CVMetalTextureCache keeps recycled IOSurface-backed textures until flushed; flush every
        // second or so so a long piece does not grow the cache.
        if framesDecoded % 30 == 0, let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
        let dt = max(now - lastFrameTime, 1.0 / 60)
        lastFrameTime = now
        encodePrepass(pb, segment: s, dt: dt, mediaTime: CMSampleBufferGetPresentationTimeStamp(frame).seconds)
        if framesDecoded == 1 || framesDecoded % 300 == 0 {
            LMLog.visual.info("📼 footage frame \(self.framesDecoded) media=\(String(format: "%.2f", CMSampleBufferGetPresentationTimeStamp(frame).seconds), privacy: .public)s \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))")
        }
    }

    private func sourceTexture(_ pb: CVPixelBuffer) -> (MTLTexture, AnyObject?)? {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if let cache = textureCache {
            var cvTex: CVMetalTexture?
            let r = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex)
            if r == kCVReturnSuccess, let cvTex, let t = CVMetalTextureGetTexture(cvTex) { return (t, cvTex) }
        }
        // Fallback (plan risk: the visionOS simulator): copy the bytes into a shared texture.
        if !loggedFallback {
            loggedFallback = true
            LMLog.visual.warning("📼 CVMetalTextureCache unavailable; byte-copy fallback")
        }
        if fallbackTexture?.width != w || fallbackTexture?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            fallbackTexture = device.makeTexture(descriptor: d)
        }
        guard let t = fallbackTexture else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: base,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
        return (t, nil)
    }

    private struct Params {
        var black: Float, white: Float, blend: Float, slowK: Float, motionK: Float, crop: Float, hasPrev: Float, pad: Float
    }

    private func encodePrepass(_ pb: CVPixelBuffer, segment s: Segment, dt: Double, mediaTime: Double) {
        guard let pipeline, let (src, keepAlive) = sourceTexture(pb),
              let cb = commandQueue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return }
        let prevIndex = (writeIndex + 2) % 3
        let out = stages[writeIndex]
        var p = Params(black: s.black, white: max(s.white, s.black + 0.05), blend: 0.4,
                       slowK: Float(1 - exp(-dt / 0.5)), motionK: Float(1 - exp(-dt / 0.25)),
                       crop: 0.06, hasPrev: hasHistory ? 1 : 0, pad: 0)
        enc.setComputePipelineState(pipeline)
        enc.setTexture(src, index: 0)
        enc.setTexture(stages[prevIndex], index: 1)
        enc.setTexture(out, index: 2)
        enc.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (Self.stageWidth + 15) / 16, height: (Self.stageHeight + 15) / 16, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
        let gen = generation
        let reference = s.pieceIndex.map { Reference(url: s.url, mediaTime: mediaTime, pieceIndex: $0) }
        cb.addCompletedHandler { [weak self] _ in
            _ = keepAlive   // the CVMetalTexture (and its pixel buffer) live until the GPU is done
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation, self.segment != nil else { return }
                self.published.withLock { $0.texture = out; $0.reference = reference }
            }
        }
        cb.commit()
        hasHistory = true
        writeIndex = (writeIndex + 1) % 3
    }
}
