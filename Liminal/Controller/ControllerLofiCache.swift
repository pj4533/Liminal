import AVFoundation
import Foundation

/// Metadata from actual queued PCM, never the nominal next request (which can be a fallback).
nonisolated struct ControllerLofiInstrument: Sendable {
    let score: LofiScore
    let clock: LofiClock
    var key: String {
        "\(score.preset.name)|\(score.bassVoice.rawValue)|\(score.tonic)|\(score.scale.rawValue)|\(clock.sampleRate)|\(clock.beatDuration)"
    }
}

nonisolated enum ControllerPadWindow {
    static func pitches(base: Int, tonic: Int, intervals: [Int]) -> [Int]? {
        guard !intervals.isEmpty, (0...127).contains(base), (base - tonic) % 12 == 0 else { return nil }
        // Selected register with its bottom-left tonic; row advances three scale degrees.
        let root = base
        let pitches = (0..<64).map { pad in
            let degree = (pad / 8) * 3 + pad % 8
            return root + 12 * (degree / intervals.count) + intervals[degree % intervals.count]
        }
        return pitches.allSatisfy { (0...127).contains($0) } ? pitches : nil
    }
}

/// Includes buffers retained by held/retiring notes from old programs, not just cache dictionary size.
nonisolated final class ControllerPCMReservation: @unchecked Sendable {
    static let limit = 128 * 1024 * 1024
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bytes = 0
    let count: Int
    init(count: Int) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard count > 0, count <= Self.limit - Self.bytes else { throw ControllerWire.Failure.overloaded }
        self.count = count; Self.bytes += count
    }
    deinit { Self.lock.lock(); Self.bytes -= count; Self.lock.unlock() }
    static var liveBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
}

nonisolated final class ControllerNotePCM: @unchecked Sendable {
    let attack: AVAudioPCMBuffer
    let sustain: AVAudioPCMBuffer?
    let release: Double
    let preset: LofiPreset
    let beatDuration: Double
    let decayDBPerSecond: Double
    private let reservation: ControllerPCMReservation
    init(attack: AVAudioPCMBuffer, sustain: AVAudioPCMBuffer?, release: Double,
         preset: LofiPreset, beatDuration: Double, decayDBPerSecond: Double, reservation: ControllerPCMReservation) {
        self.attack = attack; self.sustain = sustain; self.release = release
        self.preset = preset; self.beatDuration = beatDuration
        self.decayDBPerSecond = decayDBPerSecond; self.reservation = reservation
    }
}

/// Exactly one utility worker. At most current/next complete generations; partial results never publish.
actor ControllerLofiCache {
    struct Bank: Sendable {
        let key: String
        let instrument: ControllerLofiInstrument
        let bases: [ControllerChannel: Int]
        let notes: [ControllerChannel: [Int: ControllerNotePCM]]
    }
    private var cached: [Bank] = []

    func prepare(_ instrument: ControllerLofiInstrument, bases: [ControllerChannel: Int]) throws -> Bank {
        let key = instrument.key + Self.windowKey(bases)
        if let bank = cached.first(where: { $0.key == key }) { return bank }
        // Leave room for one new generation; notes still held retain their independent reservations.
        if cached.count >= 2 { cached.removeFirst() }
        var notes: [ControllerChannel: [Int: ControllerNotePCM]] = [:]
        for channel in [ControllerChannel.bass, .lead, .mids] {
            guard let base = bases[channel], let pitches = ControllerPadWindow.pitches(
                base: base, tonic: instrument.score.tonic, intervals: instrument.score.scale.intervals) else {
                throw ControllerWire.Failure.out_of_range
            }
            var channelNotes: [Int: ControllerNotePCM] = [:]
            for midi in Set(pitches).sorted() {
                try Task.checkCancellation()
                channelNotes[midi] = try Self.render(channel, midi: midi, instrument: instrument)
            }
            notes[channel] = channelNotes
        }
        let bank = Bank(key: key, instrument: instrument, bases: bases, notes: notes)
        cached.append(bank)
        return bank
    }
    nonisolated static func windowKey(_ bases: [ControllerChannel: Int]) -> String {
        [ControllerChannel.bass, .lead, .mids].map { "|\($0.rawValue):\(bases[$0] ?? -1)" }.joined()
    }

    nonisolated static func render(_ channel: ControllerChannel, midi: Int,
                                   instrument: ControllerLofiInstrument) throws -> ControllerNotePCM {
        let score = instrument.score, clock = instrument.clock, rate = clock.sampleRate
        let duration = channel == .lead ? 2.8 : (channel == .mids ? 3.0 : 2.1)
        let count = Int(duration * rate)
        var note = LofiScore.Note(part: channel == .bass ? .bass : (channel == .lead ? .lead : .texture),
                                 midi: midi, beat: 0, length: 1.7 / clock.beatDuration, velocity: 0.7)
        var left: [Float], right: [Float]
        let release: Double, decay: Double
        switch channel {
        case .bass:
            note.stroke = .hold; note.strike = 0.7
            if let kit = score.bassVoice.kit, !LofiBassSamples.bundled.has(kit: kit, stroke: .long) {
                throw ControllerWire.Failure.preparation_failed
            }
            if score.bassVoice == .classic {
                var l = [Float](repeating: 0, count: count), r = l
                l.withUnsafeMutableBufferPointer { left in
                    r.withUnsafeMutableBufferPointer { right in
                        LofiBassVoice.add(note, voice: .classic, clock: clock, left: left, right: right)
                    }
                }
                left = l
            } else {
                left = LofiBassVoice.render(note, voice: score.bassVoice, clock: clock, limit: count)
            }
            // Remove the voice's built-in held decay before looping. Reapply outside the loop so it
            // cannot restart at full level each cycle. Keep the actual onset/strike and body kit.
            decay = LofiBassVoice.shape(.hold).decayDBPerSecond
            for i in left.indices { left[i] *= Float(pow(10, decay * Double(i) / rate / 20)) }
            left.withUnsafeMutableBufferPointer { samples in
                if let base = samples.baseAddress { _ = LofiStemChains.applyBass(base, count: samples.count, sampleRate: rate) }
            }
            right = left; release = score.bassVoice.release(.hold)
        case .lead:
            guard let sample = LofiSampleBank.bundled.sample(for: score.preset, midi: midi, velocity: note.velocity) else {
                throw ControllerWire.Failure.preparation_failed
            }
            var stereo = (left: [Float](repeating: 0, count: count), right: [Float](repeating: 0, count: count))
            LofiRenderer.addInstrument(note, sample: sample, score: score, clock: clock, into: &stereo)
            var accent: (left: [Float], right: [Float])? = nil
            _ = LofiStemChains.applyLead(left: &stereo.left, right: &stereo.right, accent: &accent, sampleRate: rate)
            left = stereo.left; right = stereo.right
            release = 0.07; decay = 0
        case .mids:
            guard let sample = LofiRenderer.padSample(.bundled, preset: score.preset, midi: midi),
                  let tone = LofiPadVoice.render(note, sample: sample, preset: score.preset, clock: clock,
                      attack: LofiPadVoice.Settings.standard.attack, voice: 1,
                      seed: UInt64(midi + score.tonic * 97), limit: count) else {
                throw ControllerWire.Failure.preparation_failed
            }
            left = tone.left; right = tone.right
            _ = LofiStemChains.applyPad(left: &left, right: &right, sampleRate: rate)
            release = LofiPadVoice.Settings.standard.release; decay = 0
        default: throw ControllerWire.Failure.unavailable
        }
        let trim = channel == .bass ? Float(1) : powf(10, score.preset.levelDB / 20)
        for i in left.indices { left[i] *= trim; right[i] *= trim }
        // Sustain loops end on an integer number of periods. Long pad crossfades are prepared here.
        let attackFrames: Int, loopFrames: Int, crossfade: Int
        if channel == .lead { attackFrames = left.count; loopFrames = 0; crossfade = 0 }
        else {
            attackFrames = Int(0.7 * rate)
            let period = rate / Double(Scale.midiToFrequency(midi))
            loopFrames = Int((0.55 * rate / period).rounded() * period)
            crossfade = channel == .mids ? Int(0.2 * rate) : max(8, Int(period * 2))
        }
        let loopCount = max(0, loopFrames - crossfade)
        guard attackFrames + loopFrames < left.count || channel == .lead else { throw ControllerWire.Failure.preparation_failed }
        let reservation = try ControllerPCMReservation(count: (attackFrames + loopCount) * 2 * MemoryLayout<Float>.stride)
        func buffer(_ l: [Float], _ r: [Float]) throws -> AVAudioPCMBuffer {
            let b = try LofiRenderer.stereoBuffer(clock: clock, frames: l.count)
            b.floatChannelData![0].update(from: l, count: l.count)
            b.floatChannelData![1].update(from: r, count: r.count)
            return b
        }
        guard channel != .lead else {
            return try .init(attack: buffer(left, right), sustain: nil, release: release,
                             preset: score.preset, beatDuration: clock.beatDuration, decayDBPerSecond: decay, reservation: reservation)
        }
        func regions(_ input: [Float]) -> (attack: [Float], loop: [Float]) {
            var loop = Array(input[attackFrames..<(attackFrames + loopCount)])
            // Circular overlap: the tail is blended into the beginning. The loop end then joins the
            // continuation of the head. The attack ends at the same blended start (no second attack).
            for i in 0..<crossfade {
                let u = Float(i) / Float(crossfade)
                let w = 0.5 - 0.5 * cosf(.pi * u)
                loop[i] = input[attackFrames + loopCount + i] * (1 - w) + loop[i] * w
            }
            var attack = Array(input.prefix(attackFrames))
            // Approach loop[0] through a matched-period blend rather than a hard level step.
            let fade = min(crossfade, attackFrames)
            for i in 0..<fade {
                let u = Float(i) / Float(fade)
                let w = 0.5 - 0.5 * cosf(.pi * u)
                attack[attackFrames - fade + i] = attack[attackFrames - fade + i] * (1 - w) + loop[loopCount - fade + i] * w
            }
            return (attack, loop)
        }
        let l = regions(left), r = regions(right)
        return try .init(attack: buffer(l.attack, r.attack), sustain: buffer(l.loop, r.loop),
                         release: release, preset: score.preset, beatDuration: clock.beatDuration, decayDBPerSecond: decay, reservation: reservation)
    }
}
