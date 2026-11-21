//
//  FrameRecorder.swift
//  Liminal
//
//  Records the app's own output, not the screen (docs/recording.md): every frame the effects
//  renderer draws is copied on the GPU, in the frame's own command buffer, into an IOSurface pixel
//  buffer and appended to an HEVC track when that command buffer completes; the final audio mix
//  (the engine's main mixer) is tapped into a lock-free ring and written as 24-bit 48 kHz LPCM.
//  Both tracks share one movie clock (RecordingTiming.swift): t = 0 is the first frame's presentation
//  time; each 60 Hz video slot holds the frame presented nearest its time, and each audio buffer is
//  placed by when it is heard, with silence for anything lost, so the tracks cannot drift or shift.
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
        /// Frames written to the movie (one per 60 Hz slot, repeats included).
        var frames = 0
        /// Rendered frames offered by the renderer.
        var rendered = 0
        /// Rendered frames not used (two for one slot, or late), expected above 60 Hz.
        var surplus = 0
        /// Empty slots filled with the previous frame (the renderer skipped a frame).
        var repeatedSlots = 0
        /// Frames that could not be appended (encoder never ready within the backlog). Expected 0.
        var droppedFrames = 0
        /// Frames the renderer offered but the recorder could not copy (no pixel buffer). Expected 0.
        var captureFailures = 0
        var firstPresent: Double?
        var lastPresent: Double?
        /// Largest |frame time - slot time| of a written frame, seconds.
        var maxSlotError = 0.0
        /// Seconds from `start` to the first rendered frame reaching the recorder.
        var firstFrameDelay: Double?
        var audioFrames = 0
        var silenceFrames = 0
        var skippedAudioFrames = 0
        var audioDiscontinuities = 0
        var audioOverruns = 0
        var rateMismatches = 0
        var audioAppendFailures = 0
        var driftSeconds = 0.0
        var audioLatency = 0.0
        var audioRate = FrameRecorder.sampleRate
        /// Uptime seconds of movie time 0 (the first frame's presentation).
        var t0: Double?
        var seconds: Double { Double(frames) / FrameRecorder.slotRate }
        var renderFPS: Double {
            guard let a = firstPresent, let b = lastPresent, b > a else { return 0 }
            return Double(rendered - 1) / (b - a)
        }
        var fps: Double { FrameRecorder.slotRate }
        /// Movie time of an uptime instant (a frame presented, a sample heard).
        func movieTime(uptime: Double) -> Double? { t0.map { uptime - $0 - driftSeconds } }
        var description: String {
            String(format: "%d frames (%.2f s at 60 fps) from %d rendered at %.2f fps, %d surplus, %d repeated, max slot error %.1f ms, %d dropped, %d capture failures, first frame after %.2f s; audio %.3f s, %d silence frames, %d skipped before start, %d discontinuities, %d overruns, %d rate mismatches, %d append failures, drift %.2f ms, latency %.1f ms",
                   frames, seconds, rendered, renderFPS, surplus, repeatedSlots, maxSlotError * 1000, droppedFrames,
                   captureFailures, firstFrameDelay ?? -1, Double(audioFrames + silenceFrames) / audioRate, silenceFrames,
                   skippedAudioFrames, audioDiscontinuities, audioOverruns, rateMismatches, audioAppendFailures, driftSeconds * 1000,
                   audioLatency * 1000)
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
    /// The movie's frame rate: every slot is 1/60 s.
    static let slotRate = 60.0
    /// Audio kept before the first frame arrives (only audio heard after it is used).
    static let preRollSeconds = 2.0

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
        let rate: Double
        let startedAt: Double
        /// Uptime of movie time 0: the first frame's presentation.
        var t0: Double?
        var slotter = FrameSlotter<CVPixelBuffer>(rate: FrameRecorder.slotRate)
        var timeline: AudioTimeline
        var pending: [(CVPixelBuffer, CMTime)] = []
        var pendingAudio: [CMSampleBuffer] = []
        /// Tap buffers read before the first frame (at most `preRollSeconds`).
        var preRoll: [(AudioRing.Mark, [Float])] = []
        var stats = Stats()
        var stopping = false
        var preRollDropped = 0
        var checkedClock = false
        var lastMarkHost: Double?
        var lastMarkSeconds = 0.0
        var lastMarkStart: Int64?
        var lastMarkEnd: Int64?
        var audioTimer: DispatchSourceTimer?

        init(url: URL, writer: AVAssetWriter, video: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor,
             audioInput: AVAssetWriterInput, audioFormat: CMAudioFormatDescription, width: Int, height: Int,
             textureCache: CVMetalTextureCache, pool: CVPixelBufferPool, pipeline: MTLRenderPipelineState, sampler: MTLSamplerState, audioLatency: Double,
             rate: Double) {
            self.url = url; self.writer = writer; self.video = video; self.adaptor = adaptor
            self.audioInput = audioInput; self.audioFormat = audioFormat; self.width = width; self.height = height
            self.textureCache = textureCache; self.pool = pool; self.pipeline = pipeline; self.sampler = sampler
            self.rate = rate
            self.startedAt = ArchiveFootageService.uptime()
            self.timeline = AudioTimeline(rate: rate, latency: audioLatency)
            self.stats.audioLatency = audioLatency
            self.stats.audioRate = rate
        }
    }

    // MARK: Start / stop

    /// Starts a recording of `width` x `height` (even numbers) into `url`.
    /// `sampleRate` is the tapped mixer's output rate (the mix is written at its own rate, unresampled).
    /// `audioLatency` is the tapped node's output presentation latency: tap host time to heard.
    func start(url: URL, width: Int, height: Int, device: MTLDevice, audioLatency: Double, sampleRate: Double) throws {
        guard state.withLock({ $0.session == nil }) else { throw RecorderError.alreadyRecording }
        let w = max(2, width & ~1), h = max(2, height & ~1)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Visually lossless HEVC: about 0.35 bit per pixel at 60 Hz, at least 40 Mbit/s.
        let bitrate = max(40_000_000, min(120_000_000, Int(Double(w * h) * 60 * 0.35)))
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: DebugLaunchOptions.recordH264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
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
        audio.reset(rate: rate)
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.02)
        timer.setEventHandler { [weak self, session] in self?.drainAudio(session, final: false) }
        session.audioTimer = timer
        state.withLock { $0.session = session }
        timer.resume()
        active.store(true, ordering: .relaxed)
        LMLog.visual.info("🔴 Recording started: \(w)x\(h) \(DebugLaunchOptions.recordH264 ? "H.264" : "HEVC", privacy: .public) \(bitrate / 1_000_000) Mbit/s + 24-bit LPCM, \(url.lastPathComponent, privacy: .public)")
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
            for out in session.slotter.finish() { enqueue(session, out) }
            updateVideoStats(session)
            flushPending(session, wait: true)
            drainAudio(session, final: true)
            // Both tracks end at the end of the last slot: trim the audio there, or pad it with silence.
            if session.t0 != nil, let last = session.slotter.lastSlot {
                let end = Double(last + 1) / Self.slotRate
                let endFrame = Int((end * session.rate).rounded())
                let before = session.timeline.written
                appendSilence(session, frames: session.timeline.pad(to: endFrame), at: before)
                flushAudio(session, wait: true)
                session.writer.endSession(atSourceTime: CMTime(value: CMTimeValue(last + 1) * 10, timescale: 600))
            }
            flushAudio(session, wait: true)
            session.video.markAsFinished()
            session.audioInput.markAsFinished()
            updateAudioStats(session)
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

    /// The route was rebuilt (GenerativeEngine.recoverStoppedGraph): the output latency may differ.
    func updateAudioLatency(_ latency: Double) {
        guard let session = state.withLock({ $0.session }) else { return }
        writerQueue.async {
            session.timeline.latency = latency
            session.stats.audioLatency = latency
        }
    }

    // MARK: Video

    /// Copies `source` (the frame just rendered, bgra8Unorm holding sRGB-encoded values) into the next
    /// video frame, inside `commandBuffer` before it is committed. `presentationTime` is when the frame
    /// reaches the display, in uptime seconds (`ArchiveFootageService.uptime()`, the clock the Lo-Fi
    /// transport and the drop cuts use).
    func capture(_ source: MTLTexture, commandBuffer: MTLCommandBuffer, presentationTime: Double) {
        guard active.load(ordering: .relaxed), let session = state.withLock({ $0.session }) else { return }
        let pool = session.pool
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else {
            writerQueue.async { session.stats.captureFailures += 1 }
            return
        }
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, session.textureCache, pixelBuffer, nil, .bgra8Unorm,
                                                  session.width, session.height, 0, &cvTexture)
        guard let cvTexture, let target = CVMetalTextureGetTexture(cvTexture) else {
            writerQueue.async { session.stats.captureFailures += 1 }
            return
        }
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
        commandBuffer.addCompletedHandler { [weak self] _ in
            // Keep the CVMetalTexture alive until the GPU wrote the pixel buffer.
            withExtendedLifetime(cvTexture) {}
            self?.writerQueue.async { self?.appendVideo(session, pixelBuffer, presentationTime) }
        }
    }

    private func appendVideo(_ session: Session, _ buffer: CVPixelBuffer, _ presented: Double) {
        guard !session.stopping, session.writer.status == .writing else { return }
        if session.t0 == nil {
            // Movie time 0. Audio heard before it is skipped, so both tracks start at 0 (no edit list).
            session.t0 = presented
            session.stats.t0 = presented
            session.stats.firstFrameDelay = ArchiveFootageService.uptime() - session.startedAt
            session.writer.startSession(atSourceTime: .zero)
        }
        guard let t0 = session.t0 else { return }
        session.stats.rendered += 1
        if session.stats.firstPresent == nil { session.stats.firstPresent = presented }
        session.stats.lastPresent = presented
        // Nearest frame per 60 Hz slot, on the audio's clock (driftSeconds follows the audio device).
        for out in session.slotter.offer(buffer, at: presented - t0 - session.timeline.driftSeconds) {
            enqueue(session, out)
        }
        updateVideoStats(session)
        flushPending(session, wait: false)
    }

    private func enqueue(_ session: Session, _ out: FrameSlotter<CVPixelBuffer>.Output) {
        session.pending.append((out.frame, CMTime(value: CMTimeValue(out.slot) * 10, timescale: 600)))
    }

    private func updateVideoStats(_ session: Session) {
        session.stats.surplus = session.slotter.dropped
        session.stats.repeatedSlots = session.slotter.repeats
        session.stats.maxSlotError = session.slotter.maxError
    }

    /// Appends queued frames while the encoder accepts them. The real-time HEVC encoder keeps up at
    /// 60 Hz; a short backlog (up to 2 s) absorbs a hiccup. A frame dropped here leaves its slot to the
    /// previous frame (its time is explicit), so it cannot shift anything.
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
                session.stats.frames += 1
            } else {
                session.stats.droppedFrames += 1
            }
        }
    }

    // MARK: Audio

    /// The final mix's tap: copy into the ring and nothing else.
    func audioTap(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
        guard active.load(ordering: .relaxed), let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return }
        let left = data[0], right = channels > 1 ? data[1] : data[0]
        audio.write(left: left, right: right, frames: frames, rate: buffer.format.sampleRate,
                    hostTime: when.isHostTimeValid ? when.hostTime : 0,
                    sampleTime: when.isSampleTimeValid ? when.sampleTime : AudioTimeline.invalidSampleTime)
    }

    /// Every 20 ms, before and after the first frame: the ring never fills while the movie waits for
    /// video, and every tap buffer is placed by its own time stamp.
    private func drainAudio(_ session: Session, final: Bool) {
        guard session.writer.status == .writing else { return }
        if let t0 = session.t0, !session.preRoll.isEmpty {
            let held = session.preRoll
            session.preRoll.removeAll()
            for (mark, samples) in held { place(session, mark, samples, t0: t0) }
        }
        while let mark = audio.readMark() {
            if !session.checkedClock, mark.hostTime != 0 {
                // Tap host time and uptime are both mach_absolute_time; a large gap means they are not.
                session.checkedClock = true
                let age = ArchiveFootageService.uptime() - AVAudioTime.seconds(forHostTime: mark.hostTime)
                if abs(age) > 1 {
                    LMLog.visual.error("🔴 Recording: tap host time is \(age, format: .fixed(precision: 3)) s from uptime")
                }
            }
            var samples = [Float](repeating: 0, count: mark.frames * 2)
            let read = samples.withUnsafeMutableBufferPointer { audio.read(into: $0.baseAddress!, frames: mark.frames) }
            guard read == mark.frames else { continue }
            if let t0 = session.t0 {
                place(session, mark, samples, t0: t0)
            } else {
                session.preRoll.append((mark, samples))
                var held = session.preRoll.reduce(0) { $0 + $1.0.frames }
                while held > Int(Self.preRollSeconds * session.rate), !session.preRoll.isEmpty {
                    let old = session.preRoll.removeFirst().0.frames
                    held -= old
                    session.preRollDropped += old
                }
            }
        }
        updateAudioStats(session)
        flushAudio(session, wait: final)
    }

    private func place(_ session: Session, _ mark: AudioRing.Mark, _ samples: [Float], t0: Double) {
        let now = ArchiveFootageService.uptime()
        let host = mark.hostTime == 0 ? now - Double(mark.frames) / session.rate
                                      : AVAudioTime.seconds(forHostTime: mark.hostTime)
        var end = Int.max
        if session.stopping, let last = session.slotter.lastSlot {
            end = Int((Double(last + 1) / Self.slotRate * session.rate).rounded())
        }
        let wasStarted = session.timeline.started
        let p = session.timeline.place(hostSeconds: host, sampleTime: mark.sampleTime, frames: mark.frames, t0: t0)
        if wasStarted, p.silence > 0 || p.skip > 0 || abs(host - (session.lastMarkHost ?? host) - session.lastMarkSeconds) > 0.002
            || mark.sampleTime != (session.lastMarkEnd ?? mark.sampleTime) {
            // Anything but a contiguous buffer: what the tap reported and where it went.
            LMLog.visual.info("🔴 Recording audio: buffer at track \(p.position) after a host step of \((host - (session.lastMarkHost ?? host)) * 1000, format: .fixed(precision: 2)) ms and a sample step of \(mark.sampleTime - (session.lastMarkStart ?? mark.sampleTime)) (\(mark.frames) frames): \(p.silence) silence, \(p.skip) skipped")
        }
        session.lastMarkHost = host
        session.lastMarkSeconds = Double(mark.frames) / session.rate
        session.lastMarkStart = mark.sampleTime
        session.lastMarkEnd = mark.sampleTime == AudioTimeline.invalidSampleTime ? nil : mark.sampleTime + Int64(mark.frames)
        #if DEBUG
        if DebugLaunchOptions.recordTrace { traceMark(session, mark, samples, p, host: host) }
        #endif
        guard p.take > 0 else { return }
        if p.silence > 0 { appendSilence(session, frames: min(p.silence, max(0, end - (p.position - p.silence))), at: p.position - p.silence) }
        let take = min(p.take, max(0, end - p.position))
        guard take > 0 else { return }
        let slice = p.skip == 0 && take == mark.frames ? samples : Array(samples[(p.skip * 2)..<((p.skip + take) * 2)])
        let pts = CMTime(value: CMTimeValue(p.position), timescale: CMTimeScale(session.rate))
        if let sample = Self.sampleBuffer(slice, frames: take, format: session.audioFormat, pts: pts) {
            session.pendingAudio.append(sample)
            session.stats.audioFrames += take
        }
    }

    /// Silence on the track from `position` (frames), in 0.1 s buffers.
    private func appendSilence(_ session: Session, frames: Int, at position: Int) {
        guard frames > 0 else { return }
        let chunk = Int(session.rate / 10)
        let zeros = [Float](repeating: 0, count: chunk * 2)
        var done = 0
        while done < frames {
            let n = min(chunk, frames - done)
            let pts = CMTime(value: CMTimeValue(position + done), timescale: CMTimeScale(session.rate))
            let data = n == chunk ? zeros : Array(zeros[0..<(n * 2)])
            if let sample = Self.sampleBuffer(data, frames: n, format: session.audioFormat, pts: pts) {
                session.pendingAudio.append(sample)
            }
            done += n
        }
    }

    private func flushAudio(_ session: Session, wait: Bool) {
        var waited = 0
        while let sample = session.pendingAudio.first {
            guard session.audioInput.isReadyForMoreMediaData else {
                if wait, waited < 400 { waited += 1; Thread.sleep(forTimeInterval: 0.005); continue }
                return
            }
            session.pendingAudio.removeFirst()
            if !session.audioInput.append(sample) { session.stats.audioAppendFailures += 1 }
        }
    }

    #if DEBUG
    /// -LiminalRecordTrace: every tap buffer's stamp and placement, and any exact-zero run inside it
    /// (zeros the tap delivered, as opposed to silence the recorder inserted).
    private func traceMark(_ session: Session, _ mark: AudioRing.Mark, _ samples: [Float], _ p: AudioTimeline.Placement, host: Double) {
        var run = 0, longest = 0, at = 0
        for i in 0..<mark.frames {
            if samples[2 * i] == 0, samples[2 * i + 1] == 0 { run += 1; if run > longest { longest = run; at = i - run + 1 } } else { run = 0 }
        }
        let zeros = longest >= 32 ? " zeros=\(longest)@\(at)" : ""
        LMLog.visual.info("🔴 REC mark host=\(host, format: .fixed(precision: 6)) sample=\(mark.sampleTime) frames=\(mark.frames) pos=\(p.position) silence=\(p.silence) skip=\(p.skip)\(zeros, privacy: .public)")
    }
    #endif

    private func updateAudioStats(_ session: Session) {
        session.stats.audioOverruns = audio.overruns
        session.stats.rateMismatches = audio.rateMismatches
        session.stats.silenceFrames = session.timeline.silenceFrames
        session.stats.skippedAudioFrames = session.preRollDropped + session.timeline.skippedFrames
        session.stats.audioDiscontinuities = session.timeline.discontinuities
        session.stats.driftSeconds = session.timeline.driftSeconds
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
/// floats, with one time stamp (`Mark`) per tap buffer. The tap side never locks or allocates.
/// A buffer that does not fit is dropped whole, audio and mark together, so the reader sees the
/// jump in sample time and places silence of exactly the lost length.
nonisolated final class AudioRing: @unchecked Sendable {
    struct Mark: Equatable, Sendable {
        var hostTime: UInt64
        var sampleTime: Int64
        var frames: Int
    }

    private let capacity: Int
    private let markCapacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let marks: UnsafeMutablePointer<Mark>
    private let writeIndex = Atomic<Int>(0)   // frames written, total
    private let readIndex = Atomic<Int>(0)    // frames read, total
    private let markWrite = Atomic<Int>(0)
    private let markRead = Atomic<Int>(0)
    private let overrunCount = Atomic<Int>(0)
    private let mismatchCount = Atomic<Int>(0)
    private let expectedRate = Atomic<Int>(0)

    init(capacityFrames: Int, markCapacity: Int = 1024) {
        capacity = capacityFrames
        self.markCapacity = markCapacity
        storage = .allocate(capacity: capacityFrames * 2)
        storage.initialize(repeating: 0, count: capacityFrames * 2)
        marks = .allocate(capacity: markCapacity)
        marks.initialize(repeating: Mark(hostTime: 0, sampleTime: 0, frames: 0), count: markCapacity)
    }

    deinit { storage.deallocate(); marks.deallocate() }

    /// Writer side only, before the tap is active. `rate` is the track's rate: buffers at another rate
    /// (a route change to a new device rate) are counted and dropped.
    func reset(rate: Double = 0) {
        writeIndex.store(0, ordering: .releasing)
        readIndex.store(0, ordering: .releasing)
        markWrite.store(0, ordering: .releasing)
        markRead.store(0, ordering: .releasing)
        overrunCount.store(0, ordering: .relaxed)
        mismatchCount.store(0, ordering: .relaxed)
        expectedRate.store(Int(rate.rounded()), ordering: .releasing)
    }

    var available: Int { writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring) }
    var overruns: Int { overrunCount.load(ordering: .relaxed) }
    var rateMismatches: Int { mismatchCount.load(ordering: .relaxed) }

    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, rate: Double = 0,
               hostTime: UInt64, sampleTime: Int64) {
        let expected = expectedRate.load(ordering: .relaxed)
        if expected > 0, rate > 0, Int(rate.rounded()) != expected { mismatchCount.add(1, ordering: .relaxed); return }
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let mw = markWrite.load(ordering: .relaxed)
        let mr = markRead.load(ordering: .acquiring)
        guard w - r + frames <= capacity, mw - mr < markCapacity else { overrunCount.add(1, ordering: .relaxed); return }
        for i in 0..<frames {
            let slot = ((w + i) % capacity) * 2
            storage[slot] = left[i]
            storage[slot + 1] = right[i]
        }
        writeIndex.store(w + frames, ordering: .releasing)
        marks[mw % markCapacity] = Mark(hostTime: hostTime, sampleTime: sampleTime, frames: frames)
        markWrite.store(mw + 1, ordering: .releasing)
    }

    /// The next buffer's stamp; its `frames` frames are then readable with `read`.
    func readMark() -> Mark? {
        let mr = markRead.load(ordering: .relaxed)
        guard markWrite.load(ordering: .acquiring) > mr else { return nil }
        let mark = marks[mr % markCapacity]
        markRead.store(mr + 1, ordering: .releasing)
        return mark
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
