//
//  ArchiveAudio.swift
//  Liminal
//
//  The film's sound for a footage piece (docs/plans/archive-video.md 4, decision A27): when it enters and leaves
//  (`ArchiveAudioCuePlan`, pure), how loud the "Footage audio" setting makes it, and the decoder that turns
//  the segment's audio track into one slowed, normalised buffer off the main actor.
//

import AVFoundation
import Foundation

/// When a piece's sound plays (decision A27): it comes in a little after the piece starts to fade in and
/// leaves around the piece's change, with slow smoothstep fades of up to 4 s each. Pure.
nonisolated struct ArchiveAudioCuePlan: Sendable, Equatable {
    static let maxFade: Double = 4
    /// Each fade takes this share of the sound's span (the rest is the hold).
    static let fadeShare: Double = 0.22
    /// A sound shorter than this (begin to end) is not worth starting.
    static let minimumAudible: Double = FootageWeaver.soundMinSpan

    /// Elapsed seconds (the footage clock) at which the sound starts, already at level 0.
    let beginAt: Double
    let fadeIn: Double
    /// Elapsed seconds at which the fade out starts.
    let fadeOutAt: Double
    let fadeOut: Double
    /// Source seconds of the film where the sound starts (anchored to the picture).
    let sourceStart: Double
    /// Source seconds to decode (the slowed sound lasts `sourceLength / rate`).
    let sourceLength: Double
    let rate: Float

    var endAt: Double { fadeOutAt + fadeOut }

    init?(piece: FootagePiece, clipDuration: Double) {
        let begin = piece.origin + FootageWeaver.soundDelay
        let end = piece.origin + piece.length + FootageWeaver.soundTail
        let span = end - begin
        guard span >= Self.minimumAudible else { return nil }
        let pictureRate = Double(piece.rate)
        let start = piece.segmentStart + (begin - piece.origin) * pictureRate
        // Reserve pronounced slowdowns for a small share of cues. Near a clip's end,
        // ease toward the picture rate only as much as needed to cover the cue and its fade.
        let available = clipDuration - start
        let rate: Double
        if piece.seed < 0.20 {
            rate = pictureRate
        } else if available >= span {
            rate = 1
        } else {
            rate = max(pictureRate, Double(Float(available / (span + 1))))
        }
        // One spare second past the fade, so the buffer never ends while still audible.
        let length = min((span + 1) * rate, clipDuration - start)
        // The buffer must last to the end of the fade out (a sound is never cut off).
        guard length >= span * rate else { return nil }
        let fade = min(Self.maxFade, span * Self.fadeShare)
        beginAt = begin
        fadeIn = fade
        fadeOutAt = end - fade
        fadeOut = fade
        sourceStart = start
        sourceLength = length
        self.rate = Float(rate)
    }

    /// Linear gain for the "Footage audio" setting (0...1): 0 = silent (no cue at all), 0.5 = 1 (the
    /// default), 1 = 2 (+6 dB). Proportional in amplitude.
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

    /// RMS from the speech band, read by the music mixer at 10 Hz.
    static let activityWindow = 0.08

    static func activity(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let mono = buffer.floatChannelData?[0] else { return [] }
        let rate = buffer.format.sampleRate
        let block = max(1, Int(activityWindow * rate))
        let slow = Float(1 - exp(-2 * .pi * 230 / rate))
        let fast = Float(1 - exp(-2 * .pi * 3_300 / rate))
        var lower: Float = 0
        var upper: Float = 0
        let frames = Int(buffer.frameLength)
        return stride(from: 0, to: frames, by: block).map { start in
            let end = min(start + block, frames)
            var energy: Float = 0
            for i in start..<end {
                lower += slow * (mono[i] - lower)
                upper += fast * (mono[i] - upper)
                let speech = upper - lower
                energy += speech * speech
            }
            let rms = sqrtf(energy / Float(end - start))
            return min(1, max(0, (rms - 0.007) * 30))
        }
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
