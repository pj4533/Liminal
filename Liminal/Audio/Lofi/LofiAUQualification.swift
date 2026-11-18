#if DEBUG
import AudioToolbox
import AVFoundation
import CryptoKit
import Foundation
import Synchronization

nonisolated enum LofiAUQualification {
    enum Failure: LocalizedError, Equatable {
        case timeout, instantiate(String), graph(String), identityChanged, inProcess

        var errorDescription: String? {
            switch self {
            case .timeout: "timeout, quarantined for this launch"
            case .instantiate(let reason): "instantiation failed: \(reason)"
            case .graph(let reason): "fixture graph unavailable: \(reason)"
            case .identityChanged: "the loaded component identity or version changed after discovery"
            case .inProcess: "host loaded the external component in process despite the isolated request"
            }
        }
    }

    struct Report: Sendable {
        let passed: Bool
        let summary: String
        let parameters: [String]
    }

    private static let fixtureQueue = DispatchQueue(label: "liminal.lofi.au-qualification", qos: .utility)

    static func probe(_ candidate: LofiProviderProbe.Candidate, builtin: Bool, timeout: Double = 12) async -> Result<Report, Failure> {
        await withCandidate(candidate, builtin: builtin, timeout: timeout) { instance, startup in
            try fixture(node: instance.node, role: candidate.role, startup: startup)
        }
    }

    static func freshComparisonUnit(_ candidate: LofiProviderProbe.Candidate, builtin: Bool) async throws -> Instance {
        try await withCandidate(candidate, builtin: builtin, timeout: 12) { instance, _ in instance }.get()
    }

    private static func withCandidate<Value: Sendable>(
        _ candidate: LofiProviderProbe.Candidate, builtin: Bool, timeout: Double,
        operation: @escaping @Sendable (Instance, Double) throws -> Value
    ) async -> Result<Value, Failure> {
        await withCheckedContinuation { continuation in
            let pending = Pending(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                pending.complete(.failure(.timeout))
            }
            fixtureQueue.async {
                let started = ProcessInfo.processInfo.systemUptime
                AVAudioUnit.instantiate(with: candidate.description, options: builtin ? [] : .loadOutOfProcess) { node, error in
                    if let node {
                        let instance = Instance(node: node)
                        fixtureQueue.async {
                            guard pending.isWaiting else { return }
                            do {
                                let startup = ProcessInfo.processInfo.systemUptime - started
                                let au = instance.node.auAudioUnit
                                if !builtin {
                                    let id = au.componentDescription
                                    guard id.componentType == candidate.identity.type,
                                          id.componentSubType == candidate.identity.subtype,
                                          id.componentManufacturer == candidate.identity.manufacturer,
                                          au.componentVersion == candidate.identity.version else { throw Failure.identityChanged }
                                    #if os(macOS)
                                    guard !au.isLoadedInProcess else { throw Failure.inProcess }
                                    #endif
                                }
                                let result = try operation(instance, startup)
                                pending.complete(.success(result))
                            } catch let failure as Failure {
                                pending.complete(.failure(failure))
                            } catch {
                                let ns = error as NSError
                                pending.complete(.failure(.graph("\(ns.domain) \(ns.code)")))
                            }
                        }
                    } else {
                        let ns = error as NSError?
                        pending.complete(.failure(.instantiate(ns.map { "\($0.domain) \($0.code)" } ?? "no instance returned")))
                    }
                }
            }
        }
    }

    private final class Pending<Value: Sendable>: @unchecked Sendable {
        typealias Outcome = Result<Value, Failure>
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome, Never>?

        init(_ continuation: CheckedContinuation<Outcome, Never>) { self.continuation = continuation }
        var isWaiting: Bool { lock.withLock { continuation != nil } }

        func complete(_ outcome: Outcome) {
            let finished = lock.withLock {
                let result = continuation
                continuation = nil
                return result
            }
            finished?.resume(returning: outcome)
        }
    }

    /// The new instance is transferred once from Apple's completion to the serial diagnostic queue.
    final class Instance: @unchecked Sendable {
        let node: AVAudioUnit
        init(node: AVAudioUnit) { self.node = node }
    }

    private final class MusicalClock: Sendable {
        let sample = Atomic<Int64>(0)
        let midiEvents = Atomic<Int>(0)
        static let rate = 48_000.0
        static let bpm = 70.0

        func attach(to au: AUAudioUnit) {
            au.musicalContextBlock = { [self] tempo, numerator, denominator, beat, offset, downbeat in
                let frame = Double(sample.load(ordering: .relaxed))
                let framesPerBeat = Self.rate * 60 / Self.bpm
                let position = frame / framesPerBeat
                tempo?.pointee = Self.bpm
                numerator?.pointee = 4
                denominator?.pointee = 4
                beat?.pointee = position
                offset?.pointee = Int(((ceil(position) - position) * framesPerBeat).rounded())
                downbeat?.pointee = floor(position / 4) * 4
                return true
            }
            au.transportStateBlock = { [self] flags, frame, cycleStart, cycleEnd in
                flags?.pointee = .moving
                frame?.pointee = Double(sample.load(ordering: .relaxed))
                cycleStart?.pointee = 0
                cycleEnd?.pointee = 0
                return true
            }
            if !au.midiOutputNames.isEmpty {
                au.midiOutputEventBlock = { [self] _, _, _, _ in
                    midiEvents.wrappingAdd(1, ordering: .relaxed)
                    return noErr
                }
            }
        }
    }

    private static func fixture(node: AVAudioUnit, role: LofiProviderProbe.Role, startup: Double) throws -> Report {
        let au = node.auAudioUnit
        let inputs = au.inputBusses.count
        let outputs = au.outputBusses.count
        let synth = inputs == 0 && role == .instrument
        let rate = MusicalClock.rate
        let block = 512
        let frameCount = Int(rate * 3)
        let onsetFrame = Int(rate * 0.48)
        let noteOffFrame = Int(rate * 1.10)
        let loudStart = Int(rate * 0.73)
        let loudEnd = Int(rate * 1.20)
        let parameters = au.parameterTree?.allParameters ?? []
        let schema = parameters.prefix(128).map {
            "\($0.keyPath) address=\($0.address) unit=\($0.unit.rawValue) range=\($0.minValue)...\($0.maxValue) flags=\($0.flags.rawValue)"
        }
        let presets = au.factoryPresets?.count ?? 0
        let state = checkState(of: au, parameters: parameters)
        let clocks = MusicalClock()
        clocks.attach(to: au)
        let canReceiveMIDI = au.scheduleMIDIEventBlock != nil
        let midiOutputs = au.midiOutputNames.count
        guard outputs == 1, inputs <= 2, inputs > 0 || synth,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            return .init(passed: false, summary: "unsupported audio graph inputs=\(inputs) outputs=\(outputs) presets=\(presets) MIDIin=\(canReceiveMIDI) MIDIout=\(midiOutputs) state=\(state.label)", parameters: schema)
        }
        // Reject unsupported layouts before connecting. Connection failures can otherwise raise Objective-C exceptions.
        try au.outputBusses[0].setFormat(format)
        for bus in 0..<inputs { try au.inputBusses[bus].setFormat(format) }
        let engine = AVAudioEngine()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        let sources = (0..<inputs).map { _ in AVAudioPlayerNode() }
        for (bus, source) in sources.enumerated() {
            engine.attach(source)
            engine.connect(source, to: node, fromBus: 0, toBus: bus, format: format)
        }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: AVAudioFrameCount(block))
        try engine.start()
        defer { engine.stop() }
        guard let capture = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)) else {
            throw Failure.graph("capture allocation")
        }
        func stimulus(_ frame: Int, _ channel: Int) -> Float {
            if frame == onsetFrame && channel == 0 { return 0.85 }
            if frame == onsetFrame + Int(rate * 0.08) && channel == 1 { return -0.67 }
            let t = Double(frame) / rate
            if (loudStart..<loudEnd).contains(frame) {
                let frequency = channel == 0 ? 89.0 : 523.0
                let scale = t < 0.95 ? 0.21 : (channel == 0 ? 1.65 : 1.32)
                return Float(scale * sin(2 * .pi * frequency * t))
            }
            return 0
        }
        for (bus, source) in sources.enumerated() {
            guard let tone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
                  let channels = tone.floatChannelData else { throw Failure.graph("stimulus allocation") }
            tone.frameLength = AVAudioFrameCount(frameCount)
            for channel in 0..<2 {
                for i in 0..<frameCount {
                    let time = Double(i) / rate
                    let detector: Float = (0.78...0.94).contains(time) ? 0.85 * Float(sin(2 * .pi * 99 * time)) : 0
                    channels[channel][i] = bus == 0 ? stimulus(i, channel) : detector
                }
            }
            source.scheduleBuffer(tone)
            source.play()
        }
        var sentOn = false, sentOff = false
        func midi(_ frame: Int, _ status: UInt8, _ velocity: UInt8, at start: Int) {
            let event = [status, 57, velocity]
            event.withUnsafeBufferPointer { bytes in
                guard let address = bytes.baseAddress else { return }
                au.scheduleMIDIEventBlock?(AUEventSampleTimeImmediate + AUEventSampleTime(frame - start), 0, bytes.count, address)
            }
        }
        var firstL: Int?, firstR: Int?
        var silence: Float = 0, active: Float = 0, late: Float = 0, difference: Float = 0
        var maxBlock = 0.0
        let latencyFrames = au.latency.isFinite ? Int(min(rate, max(0, au.latency * rate)).rounded()) : 0
        var covered = 0
        while covered < frameCount {
            let next = min(block, frameCount - covered)
            clocks.sample.store(Int64(covered), ordering: .relaxed)
            if synth && !sentOn && (covered..<(covered + next)).contains(onsetFrame) {
                sentOn = true
                midi(onsetFrame, 0x90, 80, at: covered)
            }
            if synth && !sentOff && (covered..<(covered + next)).contains(noteOffFrame) {
                sentOff = true
                midi(noteOffFrame, 0x80, 0, at: covered)
            }
            let before = ProcessInfo.processInfo.systemUptime
            let status = try engine.renderOffline(AVAudioFrameCount(next), to: capture)
            maxBlock = max(maxBlock, ProcessInfo.processInfo.systemUptime - before)
            guard status == .success, Int(capture.frameLength) == next, let channels = capture.floatChannelData else {
                throw Failure.graph("render status \(status.rawValue), produced \(capture.frameLength)/\(next) frames")
            }
            for i in 0..<next {
                let frame = covered + i
                let l = channels[0][i], r = channels[1][i]
                guard l.isFinite, r.isFinite else { throw Failure.graph("nonfinite output") }
                let peak = max(abs(l), abs(r))
                if frame < onsetFrame { silence = max(silence, peak) }
                if frame > Int(rate * 2.7) { late = max(late, peak) }
                active = max(active, peak)
                if frame >= onsetFrame && firstL == nil && abs(l) > 0.0001 { firstL = frame }
                if frame >= onsetFrame && firstR == nil && abs(r) > 0.0001 { firstR = frame }
                let aligned = frame - latencyFrames
                if !synth && (loudStart..<loudEnd).contains(aligned) {
                    difference = max(difference, abs(l - stimulus(aligned, 0)), abs(r - stimulus(aligned, 1)))
                }
            }
            covered += next
        }
        let changed = synth ? canReceiveMIDI && sentOn && sentOff : difference > 0.02 && !au.shouldBypassEffect
        let peakOK = active > 0.0001 && active < (role == .limiter ? 1.02 : 4)
        let passed = role != .midi && silence < 0.003 && peakOK && changed && state.restored
            && firstL != nil && firstR != nil && (!synth || late < max(0.005, active * 0.3))
        let measured = firstL.map { $0 - onsetFrame } ?? -1
        let processMode: String
        #if os(macOS)
        processMode = au.isLoadedInProcess ? "in-process" : "remote"
        #else
        processMode = "remote requested, mode unreadable"
        #endif
        let outputEvents = clocks.midiEvents.load(ordering: .relaxed)
        let timing = String(format: "startup=%.3fs latency=%.6fs tail=%.3fs maxBlock=%.3fms", startup, au.latency, au.tailTime, maxBlock * 1000)
        let peaks = String(format: "silence=%.5f active=%.5f tailResidual=%.5f change=%.5f", silence, active, late, difference)
        let summary = "pass=\(passed) \(processMode) inputs=\(inputs) outputs=\(outputs) channels=2 rate=48000 "
            + "presets=\(presets) MIDIin=\(canReceiveMIDI) MIDIout=\(midiOutputs)/events=\(outputEvents) state=\(state.label) "
            + "\(timing) measuredFirstLeft=\(measured) \(peaks) auxiliaryFixture=\(inputs > 1) version=\(au.componentVersion)"
        return .init(passed: passed, summary: summary, parameters: schema)
    }

    private static func checkState(of au: AUAudioUnit, parameters: [AUParameter]) -> (restored: Bool, label: String) {
        guard let state = au.fullStateForDocument,
              let encoded = try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0),
              encoded.count <= 4 * 1024 * 1024 else { return (false, "unavailable") }
        let original = parameters.map(\.value)
        // Only change a known threshold in the diagnostic instance. Other states are exercised by readback.
        let threshold = parameters.first { $0.identifier.lowercased() == "threshold" && $0.maxValue > $0.minValue }
        var changed = false
        if let threshold {
            let midpoint = (threshold.maxValue + threshold.minValue) / 2
            let target = threshold.value > midpoint ? threshold.minValue : threshold.maxValue
            let initial = threshold.value
            threshold.value = target
            changed = abs(threshold.value - initial) > 0.001
        }
        au.fullStateForDocument = state
        let stable = zip(original, parameters).allSatisfy { abs($0 - $1.value) < 0.002 }
        let hash = SHA256.hash(data: encoded).prefix(6).map { String(format: "%02x", $0) }.joined()
        return (stable, "bytes=\(encoded.count)/digest=\(hash)/parameterChanged=\(changed)/restored=\(stable)")
    }
}
#endif
