//
//  FrameRecorder.swift
//  Liminal
//
//  Records the app's own output, not the screen (docs/recording.md): every frame the effects
//  renderer draws is copied on the GPU, in the frame's own command buffer, into an IOSurface pixel
//  buffer and appended to an HEVC track when that command buffer completes; the final audio mix
//  (the engine's main mixer) is tapped into a lock-free ring and written as 24-bit 48 kHz LPCM.
//  Both tracks are stamped on the host clock, the audio at the time it is heard.
//
//  Threads: `capture` runs on the render thread (macOS draw, visionOS render worker) and only encodes
//  one small GPU pass. The audio tap only copies floats into the ring (no locks, no allocation).
//  Everything else (pixel buffer appends, audio sample buffers, finishing) is on `writerQueue`.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import Synchronization
import OSLog

nonisolated final class FrameRecorder: @unchecked Sendable {
    static let shared = FrameRecorder()

    struct Stats: Sendable, CustomStringConvertible {
        var frames = 0
        /// Frames that could not be appended (encoder never ready within the backlog). Expected 0.
        var droppedFrames = 0
        var firstTime: Double?
        var lastTime: Double?
        var maxInterval: Double = 0
        var longIntervals = 0   // intervals over 1.5x the nominal frame time
        var audioFrames = 0
        var audioOverruns = 0
        var audioRate = FrameRecorder.sampleRate
        var seconds: Double { (lastTime ?? 0) - (firstTime ?? 0) }
        var fps: Double { seconds > 0 ? Double(max(frames - 1, 0)) / seconds : 0 }
        var description: String {
            String(format: "%d frames over %.1f s (%.2f fps), max interval %.1f ms, %d long, %d dropped, audio %.1f s, %d audio overruns",
                   frames, seconds, fps, maxInterval * 1000, longIntervals, droppedFrames,
                   Double(audioFrames) / audioRate, audioOverruns)
        }
    }

    enum RecorderError: LocalizedError {
        case alreadyRecording, noDevice, writer(String)
        var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "Already recording"
            case .noDevice: return "No Metal device"
            case .writer(let s): return s
            }
        }
    }

    static let sampleRate = 48_000.0
    /// Nominal frame time of both renderers (60 Hz); intervals over 1.5x count as long.
    static let nominalFrame = 1.0 / 60

    /// Cheap check for the render threads.
    private let active = Atomic<Bool>(false)
    var isRecording: Bool { active.load(ordering: .relaxed) }

    private let writerQueue = DispatchQueue(label: "com.saygoodnight.Liminal.recorder", qos: .userInitiated)
    private let state = Mutex(State())
    private let audio = AudioRing(capacityFrames: Int(FrameRecorder.sampleRate) * 10)

    private struct State {
        var session: Session?
    }

    /// One recording. Touched under `state` (render thread) and on `writerQueue`.
    private final class Session: @unchecked Sendable {
        let url: URL
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let audioInput: AVAssetWriterInput
        let audioFormat: CMAudioFormatDescription
        let width: Int, height: Int
        let textureCache: CVMetalTextureCache
        let pool: CVPixelBufferPool
        let pipeline: MTLRenderPipelineState
        let sampler: MTLSamplerState
        /// Host seconds added to a tap buffer's host time: when it is heard.
        let audioLatency: Double
        let rate: Double
        var started = false
        var sessionStart: CMTime = .invalid
        var pending: [(CVPixelBuffer, CMTime)] = []
        var audioStart: Double?         // heard time of ring frame 0
        var audioWritten = 0            // frames written to the track
        var stats = Stats()
        var lastVideoTime: Double?
        var stopping = false
        var slotOrigin: Double?
        var lastSlot: Int?
        var audioTimer: DispatchSourceTimer?

        init(url: URL, writer: AVAssetWriter, video: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor,
             audioInput: AVAssetWriterInput, audioFormat: CMAudioFormatDescription, width: Int, height: Int,
             textureCache: CVMetalTextureCache, pool: CVPixelBufferPool, pipeline: MTLRenderPipelineState, sampler: MTLSamplerState, audioLatency: Double,
             rate: Double) {
            self.url = url; self.writer = writer; self.video = video; self.adaptor = adaptor
            self.audioInput = audioInput; self.audioFormat = audioFormat; self.width = width; self.height = height
            self.textureCache = textureCache; self.pool = pool; self.pipeline = pipeline; self.sampler = sampler; self.audioLatency = audioLatency
            self.rate = rate
        }
    }

    // MARK: Start / stop

    /// Starts a recording of `width` x `height` (even numbers) into `url`.
    /// `sampleRate` is the main mixer's output rate (the mix is written at its own rate, unresampled).
    func start(url: URL, width: Int, height: Int, device: MTLDevice, audioLatency: Double, sampleRate: Double) throws {
        guard state.withLock({ $0.session == nil }) else { throw RecorderError.alreadyRecording }
        let w = max(2, width & ~1), h = max(2, height & ~1)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Visually lossless HEVC: about 0.35 bit per pixel at 60 Hz, at least 40 Mbit/s.
        let bitrate = max(40_000_000, min(120_000_000, Int(Double(w * h) * 60 * 0.35)))
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoAllowFrameReorderingKey: false,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        // The mix as it leaves the engine, losslessly: 24-bit LPCM stereo at the engine's rate.
        let rate = sampleRate > 0 ? sampleRate : Self.sampleRate
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ])
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(video), writer.canAdd(audioInput) else { throw RecorderError.writer("cannot add tracks") }
        writer.add(video); writer.add(audioInput)

        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let format, let cache else { throw RecorderError.writer("format or texture cache") }
        let (pipeline, sampler) = try Self.makePipeline(device: device)
        // Our own pool (the adaptor's exists only after the writer session starts), with room for
        // every frame in flight plus the append backlog, so a frame never waits for a buffer.
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 16] as CFDictionary, [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ] as CFDictionary, &pool)
        guard let pool else { throw RecorderError.writer("pixel buffer pool") }
        guard writer.startWriting() else { throw RecorderError.writer(writer.error?.localizedDescription ?? "startWriting failed") }

        let session = Session(url: url, writer: writer, video: video, adaptor: adaptor, audioInput: audioInput,
                              audioFormat: format, width: w, height: h, textureCache: cache, pool: pool, pipeline: pipeline,
                              sampler: sampler, audioLatency: audioLatency, rate: rate)
        audio.reset()
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.02)
        timer.setEventHandler { [weak self, session] in self?.drainAudio(session, final: false) }
        session.audioTimer = timer
        state.withLock { $0.session = session }
        timer.resume()
        active.store(true, ordering: .relaxed)
        LMLog.visual.info("🔴 Recording started: \(w)x\(h) HEVC \(bitrate / 1_000_000) Mbit/s + 24-bit LPCM, \(url.lastPathComponent, privacy: .public)")
    }

    /// Stops and finishes the file. Calls back on the writer queue with the file URL and stats.
    func stop(completion: @escaping @Sendable (Result<(URL, Stats), Error>) -> Void) {
        active.store(false, ordering: .relaxed)
        guard let session = state.withLock({ s -> Session? in defer { s.session = nil }; return s.session }) else {
            completion(.failure(RecorderError.writer("not recording"))); return
        }
        writerQueue.async { [self] in
            session.stopping = true
            session.audioTimer?.cancel()
            flushPending(session, wait: true)
            drainAudio(session, final: true)
            session.video.markAsFinished()
            session.audioInput.markAsFinished()
            if let last = session.lastVideoTime { session.writer.endSession(atSourceTime: CMTime(seconds: last + Self.nominalFrame, preferredTimescale: 600_000)) }
            let stats = session.stats
            session.writer.finishWriting {
                if session.writer.status == .completed {
                    LMLog.visual.info("⏹️ Recording finished: \(stats.description, privacy: .public)")
                    completion(.success((session.url, stats)))
                } else {
                    completion(.failure(session.writer.error ?? RecorderError.writer("finishWriting failed")))
                }
            }
        }
    }

    // MARK: Video

    /// Copies `source` (the frame just rendered, bgra8Unorm holding sRGB-encoded values) into the next
    /// video frame, inside `commandBuffer` before it is committed. `hostTime` is when the frame is shown.
    func capture(_ source: MTLTexture, commandBuffer: MTLCommandBuffer, hostTime: Double) {
        guard active.load(ordering: .relaxed), let session = state.withLock({ $0.session }) else { return }
        let pool = session.pool
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else {
            writerQueue.async { session.stats.droppedFrames += 1 }
            return
        }
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, session.textureCache, pixelBuffer, nil, .bgra8Unorm,
                                                  session.width, session.height, 0, &cvTexture)
        guard let cvTexture, let target = CVMetalTextureGetTexture(cvTexture) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Recorder copy"
        encoder.setRenderPipelineState(session.pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(session.sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        let time = CMTime(seconds: hostTime, preferredTimescale: 600_000)
        commandBuffer.addCompletedHandler { [weak self] _ in
            // Keep the CVMetalTexture alive until the GPU wrote the pixel buffer.
            withExtendedLifetime(cvTexture) {}
            self?.writerQueue.async { self?.appendVideo(session, pixelBuffer, time) }
        }
    }

    private func appendVideo(_ session: Session, _ buffer: CVPixelBuffer, _ time: CMTime) {
        guard !session.stopping, session.writer.status == .writing else { return }
        // Even frame times: each frame goes to the 60 Hz slot nearest its presentation time, so render
        // timing jitter of a few ms does not make the movie judder. Two frames in one slot take
        // consecutive slots; a slot is only skipped when the renderer really skipped a frame.
        let raw = time.seconds
        let origin = session.slotOrigin ?? raw
        session.slotOrigin = origin
        var slot = Int(((raw - origin) * 60).rounded())
        if let last = session.lastSlot, slot <= last { slot = last + 1 }
        session.lastSlot = slot
        let stamped = CMTime(value: CMTimeValue(slot) * 10_000, timescale: 600_000) + CMTime(seconds: origin, preferredTimescale: 600_000)
        if !session.started {
            session.writer.startSession(atSourceTime: stamped)
            session.sessionStart = stamped
            session.started = true
        }
        let time = stamped
        let seconds = time.seconds
        if let last = session.lastVideoTime, seconds <= last { return }
        session.pending.append((buffer, time))
        flushPending(session, wait: false)
    }

    /// Appends queued frames while the encoder accepts them. The real-time HEVC encoder keeps up at
    /// 60 Hz; a short backlog (up to 2 s) absorbs a hiccup, so nothing is dropped.
    private func flushPending(_ session: Session, wait: Bool) {
        var waited = 0
        while let (buffer, time) = session.pending.first {
            guard session.video.isReadyForMoreMediaData else {
                if wait, waited < 200 { waited += 1; Thread.sleep(forTimeInterval: 0.005); continue }
                if session.pending.count > 120 {
                    session.pending.removeFirst()
                    session.stats.droppedFrames += 1
                    continue
                }
                return
            }
            session.pending.removeFirst()
            if session.adaptor.append(buffer, withPresentationTime: time) {
                let s = time.seconds
                if let last = session.lastVideoTime {
                    let interval = s - last
                    session.stats.maxInterval = max(session.stats.maxInterval, interval)
                    if interval > Self.nominalFrame * 1.5 { session.stats.longIntervals += 1 }
                }
                if session.stats.firstTime == nil { session.stats.firstTime = s }
                session.stats.lastTime = s
                session.lastVideoTime = s
                session.stats.frames += 1
            } else {
                session.stats.droppedFrames += 1
            }
        }
    }

    // MARK: Audio

    /// The main mixer's tap: copy into the ring and nothing else.
    func audioTap(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
        guard active.load(ordering: .relaxed), let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return }
        let left = data[0], right = channels > 1 ? data[1] : data[0]
        audio.write(left: left, right: right, frames: frames, hostTime: when.isHostTimeValid ? when.hostTime : 0)
    }

    private func drainAudio(_ session: Session, final: Bool) {
        guard session.writer.status == .writing else { return }
        if session.audioStart == nil {
            guard let host = audio.firstHostTime else { return }
            session.audioStart = AVAudioTime.seconds(forHostTime: host) + session.audioLatency
        }
        guard let audioStart = session.audioStart, session.started else { return }
        session.stats.audioOverruns = audio.overruns
        session.stats.audioRate = session.rate
        // On the last drain, stop at the end of the last video frame.
        var limit = Int.max
        if final, let last = session.lastVideoTime {
            limit = max(0, Int(((last + Self.nominalFrame) - audioStart) * session.rate) - session.audioWritten)
        }
        while session.audioInput.isReadyForMoreMediaData || final {
            let available = min(audio.available, Int(session.rate / 10), limit)
            guard available > 0 else { break }
            var interleaved = [Float](repeating: 0, count: available * 2)
            let read = interleaved.withUnsafeMutableBufferPointer { audio.read(into: $0.baseAddress!, frames: available) }
            guard read > 0 else { break }
            limit -= read
            let pts = CMTime(value: CMTimeValue(((audioStart * session.rate).rounded())) + CMTimeValue(session.audioWritten),
                             timescale: CMTimeScale(session.rate))
            session.audioWritten += read
            // Samples before the first video frame are trimmed by the writer's session start.
            guard let sample = Self.sampleBuffer(interleaved, frames: read, format: session.audioFormat, pts: pts) else { continue }
            if !session.audioInput.isReadyForMoreMediaData {
                var tries = 0
                while !session.audioInput.isReadyForMoreMediaData, tries < 200 { tries += 1; Thread.sleep(forTimeInterval: 0.005) }
            }
            if session.audioInput.append(sample) { session.stats.audioFrames += read }
            if final, limit <= 0 { break }
        }
    }

    private static func sampleBuffer(_ samples: [Float], frames: Int, format: CMAudioFormatDescription, pts: CMTime) -> CMSampleBuffer? {
        let bytes = frames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let status = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        guard status == noErr else { return nil }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                             sampleCount: frames, presentationTimeStamp: pts,
                                                             packetDescriptions: nil, sampleBufferOut: &sample)
        return sample
    }

    // MARK: GPU copy

    private static func makePipeline(device: MTLDevice) throws -> (MTLRenderPipelineState, MTLSamplerState) {
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "recorderCopyVertex"),
              let fragment = library.makeFunction(name: "recorderCopyFragment") else {
            throw RecorderError.writer("recorder shaders missing")
        }
        let d = MTLRenderPipelineDescriptor()
        d.label = "Recorder copy"
        d.vertexFunction = vertex
        d.fragmentFunction = fragment
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear; s.magFilter = .linear
        s.sAddressMode = .clampToEdge; s.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: s) else { throw RecorderError.writer("sampler") }
        return (try device.makeRenderPipelineState(descriptor: d), sampler)
    }
}

/// Single-producer (the audio tap), single-consumer (the writer queue) ring of interleaved stereo
/// floats. The tap side never locks or allocates.
nonisolated final class AudioRing: @unchecked Sendable {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)   // frames written, total
    private let readIndex = Atomic<Int>(0)    // frames read, total
    private let firstHost = Atomic<UInt64>(0)
    private let overrunCount = Atomic<Int>(0)

    init(capacityFrames: Int) {
        capacity = capacityFrames
        storage = .allocate(capacity: capacityFrames * 2)
        storage.initialize(repeating: 0, count: capacityFrames * 2)
    }

    deinit { storage.deallocate() }

    /// Writer side only, before the tap is active.
    func reset() {
        writeIndex.store(0, ordering: .releasing)
        readIndex.store(0, ordering: .releasing)
        firstHost.store(0, ordering: .releasing)
        overrunCount.store(0, ordering: .relaxed)
    }

    var firstHostTime: UInt64? { let h = firstHost.load(ordering: .acquiring); return h == 0 ? nil : h }
    var available: Int { writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring) }
    var overruns: Int { overrunCount.load(ordering: .relaxed) }

    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, hostTime: UInt64) {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        if w == 0, firstHost.load(ordering: .relaxed) == 0 { firstHost.store(hostTime, ordering: .releasing) }
        guard w - r + frames <= capacity else { overrunCount.add(1, ordering: .relaxed); return }
        for i in 0..<frames {
            let slot = ((w + i) % capacity) * 2
            storage[slot] = left[i]
            storage[slot + 1] = right[i]
        }
        writeIndex.store(w + frames, ordering: .releasing)
    }

    func read(into out: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let r = readIndex.load(ordering: .relaxed)
        let n = min(frames, writeIndex.load(ordering: .acquiring) - r)
        guard n > 0 else { return 0 }
        for i in 0..<n {
            let slot = ((r + i) % capacity) * 2
            out[2 * i] = storage[slot]
            out[2 * i + 1] = storage[slot + 1]
        }
        readIndex.store(r + n, ordering: .releasing)
        return n
    }
}
