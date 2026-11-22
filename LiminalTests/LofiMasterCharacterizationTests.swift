import Accelerate
import AudioKit
import AudioToolbox
import AVFoundation
import Foundation
import Testing
@testable import Liminal

@MainActor
struct LofiMasterCharacterizationTests {
    #if DEBUG
    @Test func optionalLimiterUsesADisconnectedAppleControlAndRejectsUnknownIdentities() async throws {
        let id = LofiProviderProbe.Identity(type: kAudioUnitType_Effect, subtype: kAudioUnitSubType_PeakLimiter,
                                            manufacturer: kAudioUnitManufacturer_Apple, version: 0)
        let candidate = LofiProviderProbe.Candidate(identity: id, componentName: "Apple fixture",
                                                    manufacturerName: "Apple", role: .limiter, isV3: false)
        let report = try await LofiAUQualification.probe(candidate, builtin: true).get()
        #expect(report.summary.contains("inputs=1 outputs=1 channels=2 rate=48000"))
        #expect(!report.parameters.isEmpty)
        print("Apple limiter isolated qualification \(report.summary)")
        let source = ArchiveVoice.BufferSource()
        let reference = try await LofiProviderProbe.makeComparisonLimiter(identity: "apple-peak-limiter", input: source)
        #expect(reference.providerID == "apple-peak-limiter")
        await #expect(throws: LofiProviderProbe.ComparisonFailure.self) {
            _ = try await LofiProviderProbe.makeComparisonLimiter(identity: "unknown", input: source)
        }
    }
    #endif

    @Test func referenceReconstructsAKnownIntersamplePeak() {
        let count = 48_000
        let known = [Float(0.70), 0.70, -0.70, -0.70]
        let signal = (0..<count).map { i in
            known[i % 4] * min(1, Float(min(i, count - 1 - i)) / 4_800)
        }
        let peaks = Self.referencePeaks(signal)
        let exact = 0.70 * Float(2.0.squareRoot())
        #expect(abs((signal.max() ?? 0) - 0.70) < 0.00001)
        #expect(peaks.allSatisfy { abs($0 - exact) < 0.001 })
    }

    @Test func fallbackMasterLeavesHeadroomAndDoesNotBoostQuietMaterial() throws {
        let archive = ArchiveVoice.BufferSource()
        let lofi = ArchiveVoice.BufferSource()
        // The Apple glue and sample limiter that run when the finisher cannot be instantiated.
        let master = LofiMasterBus(archive: archive, lofi: lofi, forceFinisherFallback: true)
        #expect(master.chain == .fallback)
        let audio = AudioEngine()
        audio.output = master.output
        let av = audio.avEngine
        let format = AudioKit.Settings.audioFormat
        let rate = format.sampleRate
        try av.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try audio.start()
        defer { audio.stop() }
        let total = Int(rate * 4)
        var ideal = [[Float](repeating: 0, count: total), [Float](repeating: 0, count: total)]
        for (j, source) in [archive, lofi].enumerated() {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)))
            buffer.frameLength = AVAudioFrameCount(total)
            let channels = try #require(buffer.floatChannelData)
            for c in 0..<2 {
                for i in 0..<total {
                    let time = Double(i) / rate
                    let angle = 2 * .pi * (c == 0 ? 220.0 : 540) * time
                    let swing: Float = j == 0 ? 0.63 : 0.37
                    let x: Float
                    if (0.10...0.37).contains(time) {
                        x = 0.065 * Float(sin(angle))
                    } else if (0.45...1.10).contains(time) {
                        x = 0.72 * Float(sin(angle))
                    } else if (1.45...2.05).contains(time) {
                        let envelope = min(1, (time - 1.45) / 0.03, (2.05 - time) / 0.03)
                        let polarity = (i % 4 < 2) == (c == 0) ? 1.0 : -1
                        x = Float(envelope * polarity * 1.10)
                    } else if (Int(rate * 2.5)..<Int(rate * 2.5) + 36).contains(i) {
                        x = (i % 4 < 2 ? 1.48 : -1.48) * (c == 0 ? 1 : 0.73)
                    } else if (2.52...3.30).contains(time) {
                        let envelope = max(0, min(1, (time - 2.52) / 0.003, (3.30 - time) / 0.16))
                        x = Float(envelope * 0.85 * sin(2 * .pi * 57 * time))
                    } else {
                        x = 0
                    }
                    channels[c][i] = swing * x
                    ideal[c][i] += swing * x
                }
            }
            source.player.scheduleBuffer(buffer)
            source.player.play()
        }
        var captured = [[Float](), [Float]()]
        let block = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        while av.manualRenderingSampleTime < AVAudioFramePosition(total) {
            let count = min(1024, total - Int(av.manualRenderingSampleTime))
            let status = try av.renderOffline(AVAudioFrameCount(count), to: block)
            try #require(status == .success)
            let pcm = try #require(block.floatChannelData)
            for c in 0..<2 {
                captured[c].append(contentsOf: UnsafeBufferPointer(start: pcm[c], count: Int(block.frameLength)))
            }
        }
        try #require(captured[0].count == total && captured[1].count == total)
        let finite = captured.allSatisfy { channel in channel.allSatisfy { $0.isFinite } }
        #expect(finite)

        func rmsDelta(_ start: Double, _ end: Double) -> Float {
            let indices = Int(rate * start)..<Int(rate * end)
            let source = vDSP.rootMeanSquare(Array(ideal[0][indices]))
            let out = vDSP.rootMeanSquare(Array(captured[0][indices]))
            return 20 * log10f(out / source)
        }
        let quiet = rmsDelta(0.19, 0.34)
        let loud = rmsDelta(0.91, 1.07)
        #expect(quiet < -0.5 && quiet > -3)
        #expect(loud < quiet - 1.0)
        let windows = ["ordinary": 0.43...1.18, "phase": 1.41...2.14, "transient": 2.48...3.37]
        for name in windows.keys.sorted() {
            let time = try #require(windows[name])
            let frames = Int(rate * time.lowerBound)..<Int(rate * time.upperBound)
            let channels = captured.map { Array($0[frames]) }
            let sample = 20 * log10f(channels.map(vDSP.maximumMagnitude).max() ?? 0)
            let a = Self.referencePeaks(channels[0]), b = Self.referencePeaks(channels[1])
            let reconstructed = zip(a, b).map { 20 * log10f(max($0, $1)) }
            print("Master stress \(name) sample=\(sample) 4/8/16x=\(reconstructed) quietRMS=\(quiet)dB loudRMS=\(loud)dB")
            #expect(sample < LofiMasterBus.safetyTrimDB + 0.03)
            #expect(reconstructed[2] <= -1.5)
            #expect(abs(reconstructed[2] - reconstructed[1]) < 0.1)
        }
    }

    /// Independent 49-tap Blackman-windowed sinc. The 4x and 8x grids are subsets of the 16x grid.
    private static func referencePeaks(_ signal: [Float]) -> [Float] {
        let radius = 24
        let taps = 2 * radius + 1
        let edge = [Float](repeating: 0, count: radius)
        let padded = edge + signal + edge
        let peak = vDSP.maximumMagnitude(signal)
        var result = [peak, peak, peak]
        var filtered = [Float](repeating: 0, count: signal.count)
        for phase in 1..<16 {
            let fraction = Double(phase) / 16
            var kernel = (0..<taps).map { tap -> Float in
                let delta = Double(tap - radius) - fraction
                let cosine = .pi * delta / Double(radius + 1)
                let window = 0.42 + 0.5 * cos(cosine) + 0.08 * cos(2 * cosine)
                return Float(window * sin(.pi * delta) / (.pi * delta))
            }
            let total = kernel.reduce(0, +)
            kernel = kernel.map { $0 / total }
            vDSP_conv(padded, 1, kernel, 1, &filtered, 1, vDSP_Length(signal.count), vDSP_Length(taps))
            let processed = vDSP.maximumMagnitude(filtered)
            if phase.isMultiple(of: 4) { result[0] = max(result[0], processed) }
            if phase.isMultiple(of: 2) { result[1] = max(result[1], processed) }
            result[2] = max(result[2], processed)
        }
        return result
    }
}
