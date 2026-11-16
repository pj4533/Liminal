//
//  ArchiveAudio.swift
//  Liminal
//
//  The film's sound for a footage moment (docs/plans/archive-video.md 4): when it enters and leaves
//  (`ArchiveAudioCuePlan`, pure), how loud the "Footage audio" setting makes it, and the decoder that turns
//  the segment's audio track into one slowed, normalised buffer off the main actor.
//

import AVFoundation
import Foundation

/// When a moment's sound plays, relative to the picture (plan 4, decision A15). Pure.
nonisolated struct ArchiveAudioCuePlan: Sendable, Equatable {
    /// Seconds after the picture starts to appear before the sound begins.
    static let delay: Double = 4
    static let fadeIn: Double = 12
    static let fadeOut: Double = 10
    /// A sound shorter than this (begin to fade-out start) is not worth starting.
    static let minimumAudible: Double = 6

    /// Elapsed seconds (the moment clock) at which the sound starts, already at level 0.
    let beginAt: Double
    let fadeIn: Double
    /// Elapsed seconds at which the fade out starts (the picture's own fade out start).
    let fadeOutAt: Double
    let fadeOut: Double
    /// Source seconds of the film where the sound starts (in step with the slowed picture).
    let sourceStart: Double
    /// Source seconds to decode (the slowed sound lasts `sourceLength / rate`).
    let sourceLength: Double
    let rate: Float

    init?(plan: MomentPlan, clipDuration: Double) {
        let begin = plan.start + Self.delay
        let fadeOutAt = plan.fadeOutStart
        guard fadeOutAt - begin >= Self.minimumAudible else { return nil }
        // The sound is gone before the picture: its fade is at most the picture's own.
        let fadeOut = min(Self.fadeOut, max(plan.end - fadeOutAt, 1))
        let rate = Double(plan.rate)
        let start = plan.segmentStart + Self.delay * rate
        // One spare second past the fade, so the buffer never ends while still audible.
        let length = min((fadeOutAt + fadeOut + 1 - begin) * rate, clipDuration - start)
        guard length > Self.minimumAudible * rate else { return nil }
        beginAt = begin
        fadeIn = min(Self.fadeIn, fadeOutAt - begin)
        self.fadeOutAt = fadeOutAt
        self.fadeOut = fadeOut
        sourceStart = start
        sourceLength = length
        self.rate = plan.rate
    }

    /// Linear gain for the "Footage audio" setting (0...1): 0 = silent (no cue at all), 0.5 = 1 (the
    /// tuned default, stem about -42 dBFS), 1 = 2 (+6 dB, about -36 dBFS). Proportional in amplitude.
    static func gain(level: Float) -> Float? {
        let l = min(max(level, 0), 1)
        guard l > 0.005 else { return nil }
        return 2 * l
    }
}

/// Sample maths for the decoded segment (pure, tested).
nonisolated enum ArchiveAudioMath {
    /// Source RMS after normalisation (plan 4).
    static let targetRMSdB: Float = -26
    static let maxBoostdB: Float = 12
    /// Peaks are soft-clipped to this before the filters.
    static let ceilingdB: Float = -9
    /// Below this the segment counts as silent and is not played.
    static let silentdB: Float = -60
    static let edgeFade: Double = 0.08

    /// Linear interpolation at `rate` source samples per output sample (rate < 1 slows and pitches down).
    static func resample(_ x: [Float], rate: Float) -> [Float] {
        guard x.count > 1, rate > 0 else { return x }
        let r = Double(rate)
        let n = Int(Double(x.count - 1) / r)
        var y = [Float](repeating: 0, count: max(n, 0))
        x.withUnsafeBufferPointer { src in
            y.withUnsafeMutableBufferPointer { dst in
                for i in 0..<dst.count {
                    let p = Double(i) * r
                    let j = Int(p)
                    let f = Float(p - Double(j))
                    dst[i] = src[j] + (src[min(j + 1, src.count - 1)] - src[j]) * f
                }
            }
        }
        return y
    }

    static func rmsdB(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return -200 }
        var s: Double = 0
        for v in x { s += Double(v) * Double(v) }
        return Float(10 * log10(max(s / Double(x.count), 1e-20)))
    }

    /// Gain that brings `rmsdB` to the target, at most +12 dB; nil for a silent segment.
    static func normalisation(rmsdB: Float) -> Float? {
        guard rmsdB > silentdB else { return nil }
        return powf(10, min(targetRMSdB - rmsdB, maxBoostdB) / 20)
    }

    /// Linear below half the ceiling, then a tanh knee that never exceeds the ceiling.
    @inline(__always) static func softClip(_ v: Float, ceiling c: Float) -> Float {
        let k = 0.5 * c
        let a = abs(v)
        guard a > k else { return v }
        let y = k + k * tanhf((a - k) / k)
        return v < 0 ? -y : y
    }

    /// Resample, normalise, soft-clip and fade the edges. Returns nil for a silent segment.
    static func prepare(_ mono: [Float], sampleRate: Double, rate: Float) -> [Float]? {
        var y = resample(mono, rate: rate)
        guard let g = normalisation(rmsdB: rmsdB(y)) else { return nil }
        let c = powf(10, ceilingdB / 20)
        let fadeN = min(Int(edgeFade * sampleRate), y.count / 2)
        let n = y.count
        y.withUnsafeMutableBufferPointer { b in
            for i in 0..<n { b[i] = softClip(b[i] * g, ceiling: c) }
            for i in 0..<fadeN {
                let w = Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fadeN)))
                b[i] *= w
                b[n - 1 - i] *= w
            }
        }
        return y
    }
}

/// Reads a segment's audio track into one buffer in the engine's format (plan 4). Off the main actor.
nonisolated enum ArchiveAudioDecoder {
    enum Failure: Error { case noAudioTrack, readFailed(String), silent, noBuffer }

    /// - Returns: a buffer in `format` (the music engine's), slowed to `rate`, normalised to -26 dBFS RMS.
    static func decode(url: URL, sourceStart: Double, sourceLength: Double, rate: Float,
                       format: AVAudioFormat) async throws -> AVAudioPCMBuffer {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.noAudioTrack }
        let sr = format.sampleRate
        let mono = try read(asset: asset, track: track, start: sourceStart, length: sourceLength, sampleRate: sr)
        try Task.checkCancellation()
        guard let y = ArchiveAudioMath.prepare(mono, sampleRate: sr, rate: rate) else { throw Failure.silent }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(y.count)),
              let ch = buf.floatChannelData else { throw Failure.noBuffer }
        buf.frameLength = AVAudioFrameCount(y.count)
        let channels = Int(format.channelCount)
        y.withUnsafeBufferPointer { src in
            for c in 0..<channels { ch[c].update(from: src.baseAddress!, count: y.count) }
        }
        return buf
    }

    /// Mono float samples at `sampleRate` (AVAssetReader downmixes and resamples).
    static func read(asset: AVAsset, track: AVAssetTrack, start: Double, length: Double,
                     sampleRate: Double) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(start, 0), preferredTimescale: 600),
                                       duration: CMTime(seconds: max(length, 0.1), preferredTimescale: 600))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { throw Failure.readFailed("cannot add output") }
        reader.add(out)
        guard reader.startReading() else { throw Failure.readFailed(reader.error?.localizedDescription ?? "start") }
        var samples: [Float] = []
        samples.reserveCapacity(Int(length * sampleRate) + 4096)
        while let sb = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let count = bytes / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let old = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                               destination: raw.baseAddress! + old * MemoryLayout<Float>.size)
            }
        }
        if reader.status == .failed { throw Failure.readFailed(reader.error?.localizedDescription ?? "read") }
        return samples
    }
}
