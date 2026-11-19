import Accelerate
import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// Drum landmarks, the sparse timing field and the bounded bass voices.
@Suite(.serialized)
struct LofiRhythmTests {
    // MARK: Synthetic takes

    private struct Random {
        var state: UInt64
        mutating func unit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        mutating func noise() -> Double { 2 * unit() - 1 }
    }

    private struct Hit {
        let kind: LofiDrumLandmark.Kind
        let frame: Int
        let gain: Double
    }

    private static func kick(_ rate: Double) -> [Float] {
        let n = Int(rate * 0.35)
        var phase = 0.0
        return (0..<n).map { i in
            let t = Double(i) / rate
            let frequency = 55 + 45 * exp(-t / 0.02)
            let body = sin(phase) * exp(-t / 0.10)
            phase += 2 * .pi * frequency / rate
            // A beater click: 2 ms of 2.5 kHz under a Hann window.
            let click = t < 0.002 ? 0.3 * (0.5 - 0.5 * cos(2 * .pi * t / 0.002)) * sin(2 * .pi * 2_500 * t) : 0
            return Float(0.8 * (body + click))
        }
    }

    private static func snare(_ rate: Double, seed: UInt64) -> [Float] {
        var random = Random(state: seed)
        let n = Int(rate * 0.25)
        let hp = exp(-2 * .pi * 200 / rate), lp = 1 - exp(-2 * .pi * 6_000 / rate)
        var low = 0.0, high = 0.0, previous = 0.0
        return (0..<n).map { i in
            let t = Double(i) / rate
            let x = random.noise()
            high = hp * (high + x - previous)
            previous = x
            low += (high - low) * lp
            let tone = 0.35 * sin(2 * .pi * 185 * t) * exp(-t / 0.05)
            return Float(0.6 * (tone + 0.9 * low * exp(-t / 0.07)))
        }
    }

    private static func hat(_ rate: Double, seed: UInt64) -> [Float] {
        var random = Random(state: seed)
        let n = Int(rate * 0.06)
        var a = 0.0, b = 0.0
        return (0..<n).map { i in
            let t = Double(i) / rate
            let x = random.noise()
            // Second difference of white noise: a steep high-pass with most energy above 8 kHz.
            let y = x - 2 * a + b
            b = a
            a = x
            return Float(0.3 * 0.5 * y * exp(-t / 0.015))
        }
    }

    /// Four bars per pattern at 90 BPM with deterministic jitter. Kicks on 1 and the "and" of 3,
    /// snares on 2 and 4, hats on the remaining eighths. Bar 2 adds a ghost snare 18 dB down;
    /// bar 3 starts with a kick double 60 ms apart.
    private static func synthetic(rate: Double, bars: Int = 8, seed: UInt64 = 7)
        -> (mono: [Float], hits: [Hit], ghost: Int, double: (Int, Int)) {
        let beat = rate * 60 / 90
        var random = Random(state: seed)
        var hits: [Hit] = []
        var ghost = 0, double = (0, 0)
        for bar in 0..<bars {
            func at(_ b: Double) -> Int {
                Int(((Double(bar) * 4 + b) * beat).rounded()) + Int((random.noise() * 0.008 * rate).rounded()) + Int(rate * 0.05)
            }
            if bar == 3 {
                let first = at(0)
                double = (first, first + Int(0.060 * rate))
                hits.append(Hit(kind: .kick, frame: double.0, gain: 1))
                hits.append(Hit(kind: .kick, frame: double.1, gain: 1))
            } else {
                hits.append(Hit(kind: .kick, frame: at(0), gain: 1))
            }
            hits.append(Hit(kind: .hat, frame: at(0.5), gain: 1))
            hits.append(Hit(kind: .snare, frame: at(1), gain: 1))
            hits.append(Hit(kind: .hat, frame: at(1.5), gain: 1))
            hits.append(Hit(kind: .hat, frame: at(2), gain: 1))
            hits.append(Hit(kind: .kick, frame: at(2.5), gain: 1))
            hits.append(Hit(kind: .snare, frame: at(3), gain: 1))
            hits.append(Hit(kind: .hat, frame: at(3.5), gain: 1))
            if bar == 2 {
                ghost = at(3.75)
                hits.append(Hit(kind: .snare, frame: ghost, gain: pow(10, -18.0 / 20)))
            }
        }
        let count = Int(Double(bars * 4) * beat) + Int(rate * 0.5)
        var mono = [Float](repeating: 0, count: count)
        for (index, hit) in hits.enumerated() {
            let sound: [Float] = switch hit.kind {
            case .kick: kick(rate)
            case .snare: snare(rate, seed: UInt64(index) + 11)
            default: hat(rate, seed: UInt64(index) + 101)
            }
            for (i, sample) in sound.enumerated() where hit.frame + i < count {
                mono[hit.frame + i] += sample * Float(hit.gain)
            }
        }
        return (mono, hits, ghost, double)
    }

    private func detect(_ mono: [Float], rate: Double) throws -> [LofiDrumLandmark] {
        try mono.withUnsafeBufferPointer { try LofiDrumLandmarks.detect(left: $0.baseAddress!, right: $0.baseAddress!,
                                                                        count: $0.count, sampleRate: rate) }
    }

    @Test(arguments: [44_100.0, 48_000.0])
    func syntheticHitsAreFoundWithTheirAttacksAndClasses(rate: Double) throws {
        let take = Self.synthetic(rate: rate)
        let landmarks = try detect(take.mono, rate: rate)
        let tolerance = Int(0.002 * rate)
        var correct = 0, errors: [Double] = []
        for hit in take.hits {
            let nearest = try #require(landmarks.min { abs($0.attackFrame - hit.frame) < abs($1.attackFrame - hit.frame) })
            let error = nearest.attackFrame - hit.frame
            errors.append(Double(abs(error)) * 1000 / rate)
            #expect(abs(error) <= tolerance, "\(hit.kind) at \(hit.frame): attack error \(Double(error) * 1000 / rate) ms")
            if nearest.kind == hit.kind { correct += 1 }
        }
        let accuracy = Double(correct) / Double(take.hits.count)
        print(String(format: "SYNTHETIC %.0f Hz: %d hits, %d landmarks, class accuracy %.3f, max attack error %.3f ms",
                     rate, take.hits.count, landmarks.count, accuracy, errors.max() ?? 0))
        #expect(accuracy >= 0.95)
        #expect(landmarks.count <= take.hits.count + take.hits.count / 20, "spurious landmarks")

        // The ghost note 18 dB down and both kicks of a 60 ms double survive.
        #expect(landmarks.contains { abs($0.attackFrame - take.ghost) <= tolerance && $0.kind == .snare })
        let doubles = landmarks.filter { $0.kind == .kick && (abs($0.attackFrame - take.double.0) <= tolerance
            || abs($0.attackFrame - take.double.1) <= tolerance) }
        #expect(doubles.count == 2)
        #expect(landmarks.allSatisfy { (0...1).contains($0.strength) && (0...1).contains($0.confidence) })
        #expect(landmarks.allSatisfy { $0.peakFrame >= $0.attackFrame })
    }

    /// Single-sample clicks at known positions: the stored attack has no window or filter delay.
    @Test(arguments: [44_100.0, 48_000.0])
    func aClickTrackVerifiesLatencyCompensation(rate: Double) throws {
        let positions = (0..<24).map { Int(Double($0) * 0.31 * rate) + Int(rate * 0.1) + $0 * 7 }
        var mono = [Float](repeating: 0, count: positions.last! + Int(rate * 0.5))
        for p in positions {
            mono[p] = 0.9
            mono[p + 1] = -0.45
        }
        let landmarks = try detect(mono, rate: rate)
        var worst = 0.0
        for p in positions {
            let nearest = try #require(landmarks.min { abs($0.attackFrame - p) < abs($1.attackFrame - p) })
            let error = Double(nearest.attackFrame - p) * 1000 / rate
            worst = max(worst, abs(error))
            #expect(abs(error) <= 0.5, "click at \(p): \(error) ms")
        }
        print(String(format: "CLICKS %.0f Hz: worst attack error %.3f ms", rate, worst))
    }

    @Test func silenceAndTinyRatesProduceNoLandmarksOrCrashes() throws {
        #expect(try detect([Float](repeating: 0, count: 48_000), rate: 48_000).isEmpty)
        #expect(try detect([], rate: 48_000).isEmpty)
        let take = Self.synthetic(rate: 8_000, bars: 2)
        _ = try detect(take.mono, rate: 8_000)
        let empty = try LofiDrumTake(recording: nil, clock: LofiClock(tempo: 70, sampleRate: 8_000))
        #expect(empty.landmarks.isEmpty && empty.timing.landmarks.isEmpty && empty.kicks.isEmpty)
        #expect(empty.timing.offset(atBeat: 3) == 0)
    }

    // MARK: Timing field

    private func field(_ items: [(LofiDrumLandmark.Kind, Double, Float)], clock: LofiClock) -> LofiTimingField {
        LofiTimingField(landmarks: items.map { kind, beat, confidence in
            let frame = clock.frame(at: beat)
            return LofiDrumLandmark(kind: kind, attackFrame: frame, peakFrame: frame + 40, strength: 1, confidence: confidence)
        }, clock: clock)
    }

    @Test func theTimingFieldReturnsExactOffsetsAndBoundedInterpolation() throws {
        let clock = LofiClock(tempo: 72, sampleRate: 48_000)
        let timing = field([(.kick, 0.02, 0.9), (.snare, 1.04, 0.9), (.kick, 2.47, 0.8), (.hat, 3.1, 1),
                            (.kick, 6.0, 0.3), (.snare, 17.03, 0.95)], clock: clock)
        func beat(_ b: Double) -> Double { Double(clock.frame(at: b)) / clock.framesPerBeat }
        #expect(abs(timing.offset(atBeat: 0) - beat(0.02)) < 1e-12)
        #expect(abs(timing.offset(atBeat: 1) - (beat(1.04) - 1)) < 1e-12)
        #expect(abs(timing.offset(atBeat: 2.5) - (beat(2.47) - 2.5)) < 1e-12)
        // Between anchors the offset stays within the neighbours' own offsets and fades out.
        for b in stride(from: 0.3125, through: 0.75, by: 0.0625) {
            let value = timing.offset(atBeat: b)
            #expect(value > 0 && value <= 0.04 + 1e-9, "beat \(b): \(value)")
        }
        for b in stride(from: 1.3125, through: 2.1875, by: 0.0625) {
            let value = timing.offset(atBeat: b)
            #expect(value >= -0.03 - 1e-9 && value <= 0.04 + 1e-9, "beat \(b): \(value)")
        }
        // Inside the snap radius the field returns the distance to the landmark itself.
        #expect(abs(timing.offset(atBeat: 0.8125) - (beat(1.04) - 0.8125)) < 1e-12)
        // Hats and unconfident hits never shape the field; far from anchors it is zero.
        #expect(timing.offset(atBeat: 4) == 0)
        #expect(timing.offset(atBeat: 6) == 0)
        #expect(timing.offset(atBeat: 12) == 0)
        let halfway = timing.offset(atBeat: 3.0)
        #expect(abs(halfway) < abs(beat(2.47) - 2.5))

        #expect(timing.kicks(phraseStartBeat: 0, minConfidence: 0.5).map { ($0 * 1000).rounded() } == [20, 2_470])
        #expect(timing.kicks(phraseStartBeat: 0, minConfidence: 0.2).count == 3)
        let snares = timing.snares(phraseStartBeat: 16, minConfidence: 0.5)
        #expect(snares.count == 1 && abs(snares[0] - (beat(17.03) - 16)) < 1e-9)
        let near = try #require(timing.nearestAttack(beat: 2.5, kind: .kick, within: 0.1))
        #expect(abs(near.beat - beat(2.47)) < 1e-12 && near.confidence == 0.8)
        #expect(timing.nearestAttack(beat: 2.5, kind: .snare, within: 0.5) == nil)
        #expect(abs(timing.medianKickOffset - (beat(0.02) + beat(2.47) - 2.5) / 2) < 1e-9)
        #expect(timing.counts[.kick] == 3 && timing.counts[.snare] == 2 && timing.counts[.hat] == 1)
    }

    // MARK: The existing kick detector is unchanged

    /// Copy of `LofiDrumTake.detectKicks` before landmarks were added.
    private static func legacyKicks(_ left: [Float], _ right: [Float], sampleRate: Double) -> [LofiDrumTake.Kick] {
        let count = left.count
        let hop = max(1, Int(sampleRate * 0.005))
        let low = Float(1 - exp(-2 * .pi * 105 / sampleRate))
        let dc = Float(1 - exp(-2 * .pi * 32 / sampleRate))
        var lp = SIMD2<Float>.zero
        var hp = SIMD2<Float>.zero
        var previous: Float = 0
        var bins: [(frame: Int, novelty: Float)] = []
        for start in stride(from: 0, to: count, by: hop) {
            var body: Float = 0, total: Float = 0
            for i in start..<min(start + hop, count) {
                let x = SIMD2(left[i], right[i])
                lp += (x - lp) * low
                hp += (lp - hp) * dc
                let kick = lp - hp
                body += kick.x * kick.x + kick.y * kick.y
                total += x.x * x.x + x.y * x.y
            }
            let energy = sqrtf(body / Float(hop))
            let novelty = energy - previous
            bins.append((start, total > 1e-8 && body / total > 0.19 ? max(0, novelty) : 0))
            previous += (energy - previous) * 0.60
        }
        guard bins.count > 2, let peak = bins.map(\.novelty).max(), peak > 0.008 else { return [] }
        let separation = Int(sampleRate * 0.11)
        var hits: [LofiDrumTake.Kick] = []
        for i in bins.indices {
            let bin = bins[i]
            guard bin.novelty >= max(0.006, peak * 0.185),
                  (i == 0 || bin.novelty > bins[i - 1].novelty),
                  (i == bins.count - 1 || bin.novelty >= bins[i + 1].novelty) else { continue }
            let kick = LofiDrumTake.Kick(frame: max(0, bin.frame - hop), strength: min(1, bin.novelty / (peak * 0.58)))
            if let last = hits.last, kick.frame - last.frame < separation {
                if kick.strength > last.strength { hits[hits.count - 1] = kick }
            } else {
                hits.append(kick)
            }
        }
        return hits
    }

    private static func legacyAnchors(_ kicks: [LofiDrumTake.Kick], clock: LofiClock, startBeat: Int) -> [Double] {
        let start = clock.frame(at: Double(startBeat))
        let end = start + clock.frameCount
        return kicks.compactMap { hit in
            guard hit.strength >= 0.55, (start..<end).contains(hit.frame) else { return nil }
            return Double(hit.frame - start) / clock.framesPerBeat
        }
    }

    @Test func kicksAndBassAnchorsMatchTheOldAlgorithm() throws {
        let clock = LofiClock(tempo: 90, sampleRate: 48_000)
        let frames = clock.frameCount * LofiDrumTake.phraseCount
        let source = Self.synthetic(rate: 48_000, bars: 16).mono
        var left = [Float](repeating: 0, count: frames)
        for i in 0..<min(frames, source.count) { left[i] = source[i] }
        let right = left.map { $0 * 0.8 }
        let entry = LofiDrumLibrary.Entry(name: "rhythm fixture", sha256: "", bpm: 90, beats: 64, sampleRate: 48_000,
                                          channels: 2, frameCount: frames, framesPerBeat: clock.framesPerBeat,
                                          onsetPhaseMilliseconds: 0, beatSupport: 1)
        let gain: Float = 0.9
        let take = try LofiDrumTake(recording: .init(entry: entry, left: left, right: right, gain: gain), clock: clock)
        let legacy = Self.legacyKicks(left.map { $0 * gain }, right.map { $0 * gain }, sampleRate: 48_000)
        #expect(!legacy.isEmpty)
        #expect(take.kicks == legacy)
        for phrase in 0..<LofiDrumTake.phraseCount {
            #expect(take.bassAnchors(startBeat: phrase * 16) == Self.legacyAnchors(legacy, clock: clock, startBeat: phrase * 16))
        }
        #expect(!take.landmarks.isEmpty)
        #expect(take.timing.landmarks == take.landmarks)
        #expect(zip(take.landmarks, take.landmarks.dropFirst()).allSatisfy { $0.attackFrame <= $1.attackFrame })
    }

    // MARK: Private AJ Hall takes

    private struct Row: Encodable {
        let name: String
        let sampleRate: Double
        let frames: Int
        let framesPerBeat: Double
        let kicks: [[Double]]
        let snares: [[Double]]
        /// Frame and strength of the unchanged full-take kick detector, for comparison plots.
        let legacyKicks: [[Double]]
    }

    @Test(.enabled(if: !LofiDrumLibrary.assets().isEmpty))
    func installedTakesHaveSaneLandmarks() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var worstDetection = 0.0
        for asset in LofiDrumLibrary.assets() {
            let recording = try LofiDrumLibrary.load(asset)
            let clock = LofiClock(tempo: asset.entry.bpm, sampleRate: asset.entry.sampleRate)
            let started = Date()
            let take = try LofiDrumTake(recording: recording, clock: clock)
            let preparation = Date().timeIntervalSince(started)
            // Time the landmark pass alone on the prepared take (the taper does not matter here).
            let channels = try #require(take.buffer.floatChannelData)
            let count = Int(take.buffer.frameLength)
            let detectStart = Date()
            _ = try LofiDrumLandmarks.detect(left: channels[0], right: channels[1], count: count, sampleRate: clock.sampleRate)
            let detection = Date().timeIntervalSince(detectStart)
            worstDetection = max(worstDetection, detection)

            let name = asset.entry.name
            let kicks = take.landmarks.filter { $0.kind == .kick }
            let snares = take.landmarks.filter { $0.kind == .snare && $0.confidence >= 0.5 }
            #expect((16...200).contains(kicks.count), "\(name): \(kicks.count) kicks")
            let fpb = clock.framesPerBeat
            let bars = 16
            let backbeats = (0..<bars).filter { bar in
                [1.0, 3.0].allSatisfy { beat in
                    let target = Double(bar * 4) + beat
                    return snares.contains { abs(Double($0.attackFrame) / fpb - target) <= 0.15 }
                }
            }.count
            #expect(Double(backbeats) >= 0.7 * Double(bars), "\(name): backbeats in \(backbeats) of \(bars) bars")
            // The legacy detector marks the steepest growth of the low body. On these takes that
            // lands 0 to 85 ms after the beater click where the new attack sits, and its 110 ms
            // suppression merges doubles. A kick both detectors find is a confident new kick with a
            // legacy frame from 15 ms before to 100 ms after its attack.
            let rate = clock.sampleRate
            let confident = kicks.filter { $0.confidence >= 0.5 }
            let lags = confident.compactMap { kick -> Double? in
                take.kicks.first { $0.frame >= kick.attackFrame - Int(0.015 * rate)
                    && $0.frame <= kick.attackFrame + Int(0.100 * rate) }
                    .map { Double($0.frame - kick.attackFrame) * 1000 / rate }
            }.sorted()
            let coverage = confident.isEmpty ? 0 : Double(lags.count) / Double(confident.count)
            let lag = lags.isEmpty ? 0 : lags[lags.count / 2]
            let close = lags.filter { abs($0) < 15 }.count
            #expect(coverage >= 0.5, "\(name): legacy found \(lags.count) of \(confident.count) kicks")
            // The new attack is never systematically later than the old frame (a latency error).
            #expect(lag >= -15, "\(name): median legacy minus attack \(lag) ms")
            print(String(format: "PREP %@ take %.3f s, landmarks %.3f s, kicks %d, snares %d, backbeat bars %d, legacy pairs %d of %d, median legacy-attack %.1f ms, within 15 ms %d",
                         name, preparation, detection, kicks.count, snares.count, backbeats, lags.count,
                         confident.count, lag, close))
            func rows(_ list: [LofiDrumLandmark]) -> [[Double]] {
                list.map { [Double($0.attackFrame), (Double($0.strength) * 1000).rounded() / 1000,
                            (Double($0.confidence) * 1000).rounded() / 1000] }
            }
            let row = Row(name: name, sampleRate: clock.sampleRate, frames: count, framesPerBeat: fpb,
                          kicks: rows(kicks), snares: rows(take.landmarks.filter { $0.kind == .snare }),
                          legacyKicks: take.kicks.map { [Double($0.frame), Double($0.strength)] })
            print("LANDMARKS " + String(decoding: try encoder.encode(row), as: UTF8.self))
        }
        print(String(format: "PREP worst landmark pass %.3f s", worstDetection))
        #expect(worstDetection <= 0.6)
    }

    // MARK: Bass voices

    private static let voiceClock = LofiClock(tempo: 70, sampleRate: 48_000)

    private static func render(_ voice: LofiBassVoice, midi: Int = 33, length: Double = 1.2,
                               velocity: Float = 0.8) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: 0, count: voiceClock.frameCount), right = left
        let note = LofiScore.Note(part: .bass, midi: midi, beat: 0, length: length, velocity: velocity)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                LofiBassVoice.add(note, voice: voice, clock: voiceClock, left: l, right: r)
            }
        }
        return (left, right)
    }

    /// The bass formula of `LofiSynth.add` before voices existed.
    private static func legacyBass(_ note: LofiScore.Note, clock: LofiClock,
                                   left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>) {
        let start = clock.frame(at: note.beat)
        let span = clock.frame(at: note.length)
        let frequency = 440 * pow(2, Double(note.midi - 69) / 12)
        let rate = clock.sampleRate
        let omega = 2 * Double.pi * frequency / rate
        let attack: Double, release: Double, gain: Float, pan: Float
        (attack, release, gain, pan) = (0.018, 0.31, 0.337, 0)
        let tail = max(1, Int(rate * release))
        let count = min(left.count - start, span + tail)
        guard count > 0 else { return }
        let a = sqrtf(0.5 * (1 - pan)), b = sqrtf(0.5 * (1 + pan))
        let fade = min(count, max(1, Int(rate * 0.06)))
        for i in 0..<count {
            let t = Double(i) / rate
            let phase = Double(i) * omega
            let rise = min(1, t / attack)
            let fall = i < span ? 1 : max(0, 1 - Double(i - span) / Double(tail))
            let edge = min(1, Double(count - 1 - i) / Double(fade))
            let body = sin(phase) + (0.12 + 0.13 * exp(-t * 4)) * sin(2 * phase) + 0.04 * sin(3 * phase)
            let wave = tanh(1.15 * body)
            let value = Float(wave * rise * rise * fall * fall * edge) * gain * note.velocity
            left[start + i] += value * a
            right[start + i] += value * b
        }
    }

    @Test func classicBassIsTheOldFormulaSampleForSample() {
        for (tempo, rate) in [(70.0, 48_000.0), (63.0, 44_100.0)] {
            let clock = LofiClock(tempo: tempo, sampleRate: rate)
            for note in [LofiScore.Note(part: .bass, midi: 33, beat: 0, length: 1.2, velocity: 0.8),
                         LofiScore.Note(part: .bass, midi: 40, beat: 3.37, length: 0.6, velocity: 0.55),
                         LofiScore.Note(part: .bass, midi: 28, beat: 15.5, length: 2, velocity: 1)] {
                var old = ([Float](repeating: 0.01, count: clock.frameCount), [Float](repeating: -0.01, count: clock.frameCount))
                var voice = old, synth = old
                old.0.withUnsafeMutableBufferPointer { l in old.1.withUnsafeMutableBufferPointer { r in
                    Self.legacyBass(note, clock: clock, left: l, right: r) } }
                voice.0.withUnsafeMutableBufferPointer { l in voice.1.withUnsafeMutableBufferPointer { r in
                    LofiBassVoice.add(note, voice: .classic, clock: clock, left: l, right: r) } }
                synth.0.withUnsafeMutableBufferPointer { l in synth.1.withUnsafeMutableBufferPointer { r in
                    LofiSynth.add(note, clock: clock, left: l, right: r) } }
                #expect(voice.0 == old.0 && voice.1 == old.1)
                #expect(synth.0 == old.0 && synth.1 == old.1)
            }
        }
    }

    private static func rms(_ x: ArraySlice<Float>) -> Double {
        var value: Float = 0
        x.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &value, vDSP_Length($0.count)) }
        return Double(value)
    }

    /// Hann-windowed power spectrum of the whole buffer, zero-padded to a power of two.
    private static func spectrum(_ x: [Float]) -> (power: [Float], resolution: Double) {
        let n = 1 << Int(ceil(log2(Double(x.count))))
        var frame = [Float](repeating: 0, count: n)
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: x.count, isHalfWindow: false)
        for i in x.indices { frame[i] = x[i] * window[i] }
        let log2n = vDSP_Length(log2(Double(n)))
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        var real = [Float](repeating: 0, count: n / 2), imag = real, power = real
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                frame.withUnsafeBufferPointer { f in
                    f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        power[0] = 0
        return (power, voiceClock.sampleRate / Double(n))
    }

    private static func band(_ s: (power: [Float], resolution: Double), _ low: Double, _ high: Double) -> Double {
        let lo = Int(low / s.resolution), hi = min(s.power.count - 1, Int(high / s.resolution))
        return s.power[lo...hi].reduce(0) { $0 + Double($1) }
    }

    /// Time until a trailing one-period maximum of |x| first reaches 20 percent of the peak.
    private static func measuredAttackLead(_ voice: LofiBassVoice) -> Double {
        let x = render(voice, midi: 69).left
        let period = Int(voiceClock.sampleRate / 440) + 1
        let peak = x.map(abs).max() ?? 0
        var held: Float = 0
        for i in x.indices {
            held = x[max(0, i - period + 1)...i].map(abs).max() ?? 0
            if held >= 0.2 * peak { return Double(i) / voiceClock.sampleRate }
        }
        return .infinity
    }

    @Test func bassVoicesAreTunedClickFreeMonoAndLoudnessMatched() {
        let span = Self.voiceClock.frame(at: 1.2)
        let classic = Self.render(.classic)
        let reference = Self.rms(classic.left[0..<span])
        let classicMids = Self.band(Self.spectrum(Array(classic.left[0..<(span + Int(0.5 * 48_000))])), 150, 800)
        let classicSteps = zip(classic.left, classic.left.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        let measuredClassic = Self.measuredAttackLead(.classic)
        print(String(format: "BASS classic attack lead %.2f ms (stored %.2f)", measuredClassic * 1000,
                     LofiBassVoice.classic.attackLead * 1000))
        #expect(abs(measuredClassic - LofiBassVoice.classic.attackLead) <= 0.0002)
        for voice in LofiBassVoice.allCases where voice != .classic {
            let note = Self.render(voice)
            let x = note.left
            #expect(note.left == note.right, "\(voice) is mono")
            let level = 20 * log10(Self.rms(x[0..<span]) / reference)
            #expect(abs(level) <= 0.5, "\(voice) RMS \(level) dB against classic")

            // Click-free edges.
            #expect(abs(x[0]) < 1e-4)
            let steps = zip(x, x.dropFirst()).map { abs($1 - $0) }
            let maxStep = steps.max() ?? 0
            #expect(maxStep <= 2 * classicSteps, "\(voice) step \(maxStep)")
            let end = span + Int(voice.recipe.release * 48_000)
            #expect(abs(x[min(x.count - 1, end - 1)]) < 1e-4 && x[end...].allSatisfy { $0 == 0 })

            // Stable tuned sustain after 40 ms: every upward zero crossing period within 5 cents.
            let f0 = 440 * pow(2, (33.0 - 69) / 12)
            var crossings: [Double] = []
            for i in Int(0.040 * 48_000)..<(span - 960) where x[i - 1] < 0 && x[i] >= 0 {
                crossings.append(Double(i - 1) + Double(-x[i - 1] / (x[i] - x[i - 1])))
            }
            let cents = zip(crossings, crossings.dropFirst()).map { 1200 * log2(48_000 / ($1 - $0) / f0) }
            #expect(!cents.isEmpty && cents.allSatisfy { abs($0) <= 5 }, "\(voice) worst \(cents.map(abs).max() ?? 0) cents")

            // Spectrum: nothing above 5 kHz within 60 dB of the fundamental.
            let spectrum = Self.spectrum(Array(x[0..<(span + Int(0.5 * 48_000))]))
            let fundamental = spectrum.power.max() ?? 0
            let highBin = Int(5_000 / spectrum.resolution)
            let high = spectrum.power[highBin...].max() ?? 0
            let highDB = 10 * log10(Double(high) / Double(fundamental))
            #expect(highDB <= -60, "\(voice) \(highDB) dB above 5 kHz")
            let mids = 10 * log10(Self.band(spectrum, 150, 800) / classicMids)
            if voice == .pluck { #expect(mids > 0, "pluck 150-800 Hz \(mids) dB against classic") }

            let lead = Self.measuredAttackLead(voice)
            #expect(abs(lead - voice.attackLead) <= 0.0002, "\(voice) attack lead \(lead)")
            print(String(format: "BASS %@ RMS %+.3f dB, 150-800 Hz %+.2f dB, >5 kHz %.1f dB, worst %.2f cents, max step %.4f, attack lead %.2f ms (stored %.2f)",
                         "\(voice)", level, mids, highDB, cents.map(abs).max() ?? 0, maxStep, lead * 1000, voice.attackLead * 1000))
        }
    }

    @Test func bassVoicesAreLoudnessMatchedAcrossTheRegister() {
        // Within 1 dB elsewhere in the bass register: the voices share a fundamental-dominated body.
        for midi in [28, 38, 45] {
            let span = Self.voiceClock.frame(at: 1.2)
            let reference = Self.rms(Self.render(.classic, midi: midi).left[0..<span])
            for voice in LofiBassVoice.allCases where voice != .classic {
                let level = 20 * log10(Self.rms(Self.render(voice, midi: midi).left[0..<span]) / reference)
                #expect(abs(level) <= 1, "\(voice) at MIDI \(midi): \(level) dB")
            }
        }
    }
}
