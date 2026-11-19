import Accelerate
import Foundation
import Synchronization

/// Master finisher settings. `lookahead` is structural: it is read when the kernel is prepared and
/// later changes are ignored, so every profile has the same latency.
nonisolated struct LofiMasterSettings: Sendable, Equatable {
    var inputGainDB: Float, highpassHz: Double
    var glue: LofiCompressor.Settings?
    var clipThresholdDB: Float?, ceilingDBTP: Float, lookahead: Double, releaseFast: Double, releaseSlow: Double
    /// False leaves the limiter path at exact unity gain (it still delays by the same latency).
    var limiterEnabled: Bool = true
    /// The soft clip's tanh shoulder ends this many dB above its threshold.
    var clipKneeDB: Float = 3
    /// The soft clip never reduces a sample by more than this; the limiter takes the rest.
    var clipMaxReductionDB: Float = 2
    /// The limiter aims this far under `ceilingDBTP`; the guard clamp sits at `ceilingDBTP`.
    var ceilingMarginDB: Float = 0.15

    /// Unity gain with the same latency as `.lofi`.
    static let passthrough = LofiMasterSettings(inputGainDB: 0, highpassHz: 0, glue: nil, clipThresholdDB: nil,
                                                ceilingDBTP: -1, lookahead: 0.003, releaseFast: 0.08,
                                                releaseSlow: 0.35, limiterEnabled: false)
    /// Plan section 8.7 starting point.
    static let lofi = LofiMasterSettings(inputGainDB: 6, highpassHz: 25,
                                         glue: .init(thresholdDB: -14, ratio: 1.7, kneeDB: 6, attack: 0.030,
                                                     release: 0.180, sidechainHighpassHz: 100),
                                         clipThresholdDB: -3, ceilingDBTP: -1, lookahead: 0.003,
                                         releaseFast: 0.08, releaseSlow: 0.35)
}

nonisolated struct LofiMasterMeters: Sendable {
    var glueDB: (mean: Float, p95: Float, max: Float)
    var clipDB: (mean: Float, p95: Float, max: Float)
    var limiterDB: (mean: Float, p95: Float, max: Float)
    var limiterAbove3dBFraction: Float
    var clipEngagedFraction: Float
    var frames: Int
    /// Samples the final guard clamp had to touch. Zero in normal operation.
    var guardClampCount: Int = 0

    static let zero = LofiMasterMeters(glueDB: (0, 0, 0), clipDB: (0, 0, 0), limiterDB: (0, 0, 0),
                                       limiterAbove3dBFraction: 0, clipEngagedFraction: 0, frames: 0)
}

/// Largest reduction of each stage over one 64-frame hop. `frame` is the output frame of the hop start.
nonisolated struct LofiMasterTracePoint: Sendable, Equatable {
    let frame: Int
    let glueDB: Float
    let clipDB: Float
    let limiterDB: Float
}

/// Realtime master: input gain, 25 Hz high-pass, glue compressor, 4x oversampled soft clip and a
/// lookahead true-peak limiter. All memory is allocated in `init` or `prepare`; `process` performs no
/// allocation, locking or logging and uses Accelerate for the heavy loops.
nonisolated final class LofiMasterKernel: @unchecked Sendable {
    static let traceHopFrames = 64
    static let clipFactor = 4
    static let clipTapsPerPhase = 32
    static let peakFactor = 4
    static let peakTapsPerPhase = 48
    static let slowReleaseCharge = 0.15
    static let histogramBins = 256
    static let histogramBinDB: Float = 0.25

    private var engineRef: Unmanaged<Engine>
    private let settingsSequence = Atomic<Int>(0)
    private let settingsSlot: UnsafeMutablePointer<LofiMasterSettings>
    private let rampSlot: UnsafeMutablePointer<Double>
    private let resetMetersRequest = Atomic<Bool>(false)
    private let meterSequence = Atomic<Int>(0)
    private let inBlock = Atomic<Int>(0)
    private let tracePointer = Atomic<Int>(0)
    private var structuralLookahead: Double

    private(set) var sampleRate: Double
    private(set) var maximumFrames: Int
    var latencyFrames: Int { engineRef._withUnsafeGuaranteedRef { $0.latency } }

    init(sampleRate: Double, maximumFrames: Int, settings: LofiMasterSettings = .passthrough) {
        self.sampleRate = sampleRate
        self.maximumFrames = max(1, maximumFrames)
        structuralLookahead = settings.lookahead
        settingsSlot = .allocate(capacity: 1)
        settingsSlot.initialize(to: settings)
        rampSlot = .allocate(capacity: 1)
        rampSlot.initialize(to: 0)
        let engine = Engine(sampleRate: sampleRate, maximumFrames: self.maximumFrames, lookahead: settings.lookahead)
        engine.configure(settings, ramp: 0)
        engineRef = .passRetained(engine)
    }

    deinit {
        engineRef.release()
        settingsSlot.deinitialize(count: 1)
        settingsSlot.deallocate()
        rampSlot.deallocate()
        let trace = tracePointer.exchange(0, ordering: .sequentiallyConsistent)
        if trace != 0 { UnsafeMutableRawPointer(bitPattern: trace)?.deallocate() }
    }

    /// Rebuilds the processing state for a new format. Not realtime; never call while `process` runs.
    func prepare(sampleRate: Double, maximumFrames: Int) {
        let frames = max(1, maximumFrames)
        let current = engineRef._withUnsafeGuaranteedRef { $0 }
        guard sampleRate != self.sampleRate || frames != self.maximumFrames else {
            current.resetState()
            return
        }
        self.sampleRate = sampleRate
        self.maximumFrames = frames
        let engine = Engine(sampleRate: sampleRate, maximumFrames: frames, lookahead: structuralLookahead)
        engine.configure(current.state.pointee.applied, ramp: 0)
        engine.state.pointee.lastSequence = current.state.pointee.lastSequence
        engineRef.release()
        engineRef = .passRetained(engine)
    }

    /// Clears filters, envelopes, delay lines and meters, keeping the current settings.
    func reset() { engineRef._withUnsafeGuaranteedRef { $0.resetState() } }

    /// Lock-free hand-off picked up at the next block boundary. Call from one thread at a time.
    func apply(_ settings: LofiMasterSettings, ramp: Double) {
        let start = settingsSequence.load(ordering: .relaxed)
        settingsSequence.store(start | 1, ordering: .sequentiallyConsistent)
        settingsSlot.pointee = settings
        rampSlot.pointee = max(0, ramp)
        settingsSequence.store((start | 1) + 1, ordering: .sequentiallyConsistent)
    }

    // MARK: Render

    /// Processes `count` frames. Buffers may alias (in place). Realtime safe.
    func process(inL: UnsafePointer<Float>, inR: UnsafePointer<Float>,
                 outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        inBlock.store(1, ordering: .sequentiallyConsistent)
        let traceBits = tracePointer.load(ordering: .sequentiallyConsistent)
        engineRef._withUnsafeGuaranteedRef { engine in
            pollSettings(engine)
            if resetMetersRequest.exchange(false, ordering: .acquiring) { engine.clearMeters() }
            var offset = 0
            while offset < count {
                let n = min(engine.maximumFrames, count - offset)
                meterSequence.add(1, ordering: .acquiringAndReleasing)
                engine.block(inL + offset, inR + offset, outL + offset, outR + offset, n,
                             trace: UnsafeMutableRawPointer(bitPattern: traceBits))
                meterSequence.add(1, ordering: .releasing)
                offset += n
            }
        }
        inBlock.store(0, ordering: .sequentiallyConsistent)
    }

    private func pollSettings(_ engine: Engine) {
        let first = settingsSequence.load(ordering: .acquiring)
        guard first & 1 == 0, first != engine.state.pointee.lastSequence else { return }
        let candidate = settingsSlot.pointee
        let ramp = rampSlot.pointee
        atomicMemoryFence(ordering: .acquiring)
        guard settingsSequence.load(ordering: .acquiring) == first else { return }
        engine.state.pointee.lastSequence = first
        engine.configure(candidate, ramp: ramp)
    }

    // MARK: Meters and trace (any thread)

    var meters: LofiMasterMeters {
        engineRef._withUnsafeGuaranteedRef { engine in
            for _ in 0..<10_000 {
                let first = meterSequence.load(ordering: .acquiring)
                if first & 1 == 1 { continue }
                let snapshot = engine.meterSnapshot()
                atomicMemoryFence(ordering: .acquiring)
                if meterSequence.load(ordering: .acquiring) == first { return snapshot }
            }
            return engine.meterSnapshot()
        }
    }

    /// Takes effect at the start of the next processed block.
    func resetMeters() { resetMetersRequest.store(true, ordering: .releasing) }

    private static let traceHeaderBytes = 16

    /// Allocates trace storage for `capacity` points (not realtime) and starts recording.
    func startTrace(capacity: Int) {
        let capacity = max(1, capacity)
        let bytes = Self.traceHeaderBytes + capacity * MemoryLayout<LofiMasterTracePoint>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        let header = raw.bindMemory(to: Int.self, capacity: 2)
        header[0] = capacity
        header[1] = 0
        _ = (raw + Self.traceHeaderBytes).bindMemory(to: LofiMasterTracePoint.self, capacity: capacity)
        let old = tracePointer.exchange(Int(bitPattern: raw), ordering: .sequentiallyConsistent)
        retire(old)
    }

    /// Stops recording and returns the points written since `startTrace`.
    func takeTrace() -> [LofiMasterTracePoint] {
        let old = tracePointer.exchange(0, ordering: .sequentiallyConsistent)
        guard old != 0, let raw = UnsafeMutableRawPointer(bitPattern: old) else { return [] }
        guard waitForBlockEnd() else { return [] }   // leaks only if a render block never finishes
        let header = raw.assumingMemoryBound(to: Int.self)
        let points = (raw + Self.traceHeaderBytes).assumingMemoryBound(to: LofiMasterTracePoint.self)
        let result = Array(UnsafeBufferPointer(start: points, count: min(header[0], header[1])))
        raw.deallocate()
        return result
    }

    private func retire(_ bits: Int) {
        guard bits != 0, let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
        if waitForBlockEnd() { raw.deallocate() }
    }

    /// After the trace pointer is swapped out, a render block that may still hold it must finish.
    private func waitForBlockEnd() -> Bool {
        for _ in 0..<20_000 {
            if inBlock.load(ordering: .sequentiallyConsistent) == 0 { return true }
            usleep(10)
        }
        return false
    }

    // MARK: Offline

    /// Runs the kernel over whole arrays. Output has the input's length and includes the latency.
    static func processOffline(left: [Float], right: [Float], settings: LofiMasterSettings, sampleRate: Double,
                               blockSize: Int)
        -> (left: [Float], right: [Float], meters: LofiMasterMeters, trace: [LofiMasterTracePoint]) {
        let count = min(left.count, right.count)
        let block = max(1, blockSize)
        let kernel = LofiMasterKernel(sampleRate: sampleRate, maximumFrames: block, settings: settings)
        kernel.startTrace(capacity: count / traceHopFrames + 2)
        var outL = [Float](repeating: 0, count: count), outR = [Float](repeating: 0, count: count)
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                outL.withUnsafeMutableBufferPointer { ol in
                    outR.withUnsafeMutableBufferPointer { or in
                        var offset = 0
                        while offset < count {
                            let n = min(block, count - offset)
                            kernel.process(inL: l.baseAddress! + offset, inR: r.baseAddress! + offset,
                                           outL: ol.baseAddress! + offset, outR: or.baseAddress! + offset, count: n)
                            offset += n
                        }
                    }
                }
            }
        }
        return (outL, outR, kernel.meters, kernel.takeTrace())
    }
}

// MARK: - Engine

nonisolated private struct LofiRamp {
    var value: Float
    var target: Float
    var step: Float = 0
    var remaining = 0

    init(_ value: Float) {
        self.value = value
        target = value
    }

    var steady: Bool { remaining == 0 }

    mutating func set(_ newTarget: Float, frames: Int) {
        target = newTarget
        if frames <= 0 || newTarget == value {
            value = newTarget
            remaining = 0
            step = 0
        } else {
            remaining = frames
            step = (newTarget - value) / Float(frames)
        }
    }

    /// Writes the next `n` values (first value is one step past the current one).
    mutating func fill(_ destination: UnsafeMutablePointer<Float>, _ n: Int) {
        var constant = value
        guard remaining > 0 else {
            vDSP_vfill(&constant, destination, 1, vDSP_Length(n))
            return
        }
        let ramped = min(n, remaining)
        var start = value + step
        var increment = step
        vDSP_vramp(&start, &increment, destination, 1, vDSP_Length(ramped))
        remaining -= ramped
        value = remaining == 0 ? target : value + step * Float(ramped)
        if ramped < n {
            constant = value
            vDSP_vfill(&constant, destination + ramped, 1, vDSP_Length(n - ramped))
        }
    }

    @inline(__always)
    mutating func next() -> Float {
        if remaining > 0 {
            remaining -= 1
            value = remaining == 0 ? target : value + step
        }
        return value
    }
}

nonisolated private struct LofiDelayLine {
    let delay: Int
    let buffer: UnsafeMutablePointer<Float>
    let capacity: Int

    init(delay: Int, maximumFrames: Int) {
        self.delay = delay
        capacity = delay + maximumFrames
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    func process(_ source: UnsafePointer<Float>, _ destination: UnsafeMutablePointer<Float>, _ n: Int) {
        guard delay > 0 else {
            if UnsafePointer(destination) != source { destination.update(from: source, count: n) }
            return
        }
        (buffer + delay).update(from: source, count: n)
        destination.update(from: buffer, count: n)
        memmove(buffer, buffer + n, delay * MemoryLayout<Float>.stride)
    }

    func clear() { buffer.update(repeating: 0, count: capacity) }
    func free() { buffer.deallocate() }
}

nonisolated private struct LofiMeterAccumulator {
    var sum: (Double, Double, Double) = (0, 0, 0)
    var peak: (Float, Float, Float) = (0, 0, 0)
    var limiterAbove3 = 0
    var clipEngaged = 0
    var frames = 0
    var guardClamps = 0
}

nonisolated private struct LofiKernelState {
    var applied: LofiMasterSettings
    var lastSequence = 0
    var inputGain = LofiRamp(1)
    var highpass = LofiBiquad.Coefficients.identity
    var glueAmount = LofiRamp(0)
    var glueThreshold = LofiRamp(0)
    var glueMakeup = LofiRamp(0)
    var glueRatio: Float = 1
    var glueKnee: Float = 0
    var glueAttack: Float = 0
    var glueRelease: Float = 0
    var glueRMS: Float = 0
    var glueUsesRMS = false
    var glueReduction: Float = 0
    var glueMeanSquare: Float = 0
    var sidechain = LofiBiquad.Coefficients.identity
    var sidechainActive = false
    var clipAmount = LofiRamp(0)
    var clipMix = LofiRamp(0)
    var clipThresholdDB: Float = 0
    var clipThresholdTarget: Float = 0
    var clipThresholdStep: Float = 0
    var clipKneeDB: Float = 3
    var clipMaxReductionDB: Float = 2
    var ceiling = LofiRamp(1)
    var nominalCeiling: Float = 1
    var limiterEnabled = false
    var releaseFast: Float = 0
    var releaseSlow: Float = 0
    var slowCharge: Float = 0
    var fastEnvelope: Float = 0
    var slowEnvelope: Float = 0
    var unityRun = 1 << 40
    var dequeHead = 0
    var dequeCount = 0
    var holdIndex = 0
    var frame = 0
    var hopGlue: Float = 0
    var hopClip: Float = 0
    var hopLimiter: Float = 0
}

nonisolated private final class Engine {
    let sampleRate: Double
    let maximumFrames: Int
    let lookaheadFrames: Int
    let holdFrames: Int
    let clipDelay: Int
    let peakDelay: Int
    let latency: Int
    let state: UnsafeMutablePointer<LofiKernelState>
    let meter: UnsafeMutablePointer<LofiMeterAccumulator>
    let histogram: UnsafeMutablePointer<Int>   // 3 * bins: glue, clip, limiter

    // Filters
    let clipUp: UnsafeMutablePointer<Float>      // clipFactor phases of (k + 1) taps, correlation order
    let clipDown: UnsafeMutablePointer<Float>    // clipFactor * k + 1 taps
    let peakUp: UnsafeMutablePointer<Float>      // peakFactor phases of (k + 1) taps
    let hann: UnsafeMutablePointer<Float>        // lookahead taps
    // Base-rate work buffers
    let workL, workR, scratch1, scratch2, scratch3, sidechainL, sidechainR: UnsafeMutablePointer<Float>
    let glueReduction, clipReduction, limiterReduction, gain, amount: UnsafeMutablePointer<Float>
    let firL, firR, delayedL, delayedR: UnsafeMutablePointer<Float>
    let peak, required, smooth: UnsafeMutablePointer<Float>
    let doubleIn, doubleOut: UnsafeMutablePointer<Double>
    let highpassHistory, sidechainHistory: UnsafeMutablePointer<Double>   // 8 each: per channel x2, x1, y2, y1
    // Histories
    let clipUpHistoryL, clipUpHistoryR: UnsafeMutablePointer<Float>       // k + max
    let clipDownL, clipDownR: UnsafeMutablePointer<Float>                 // factor * k + factor * max
    let peakHistoryL, peakHistoryR: UnsafeMutablePointer<Float>           // k + max
    let oversampled, overA, overB, overC, overAmount: UnsafeMutablePointer<Float>  // factor * max
    let smoothHistory: UnsafeMutablePointer<Float>                         // lookahead - 1 + max
    let dequeValues: UnsafeMutablePointer<Float>
    let dequeIndices: UnsafeMutablePointer<Int>
    let dequeCapacity: Int
    let clipPathL, clipPathR, limiterDelayL, limiterDelayR, glueMeterDelay, clipMeterDelay: LofiDelayLine
    private var allocations: [UnsafeMutableRawPointer] = []

    init(sampleRate: Double, maximumFrames: Int, lookahead: Double) {
        self.sampleRate = sampleRate
        self.maximumFrames = maximumFrames
        lookaheadFrames = max(2, Int((max(0.0005, lookahead) * sampleRate).rounded()))
        holdFrames = lookaheadFrames + 2
        clipDelay = LofiMasterKernel.clipTapsPerPhase
        peakDelay = LofiMasterKernel.peakTapsPerPhase / 2
        latency = clipDelay + peakDelay + lookaheadFrames
        let n = maximumFrames
        var list: [UnsafeMutableRawPointer] = []
        func floats(_ count: Int, _ value: Float = 0) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, count))
            p.initialize(repeating: value, count: max(1, count))
            list.append(UnsafeMutableRawPointer(p))
            return p
        }
        func doubles(_ count: Int) -> UnsafeMutablePointer<Double> {
            let p = UnsafeMutablePointer<Double>.allocate(capacity: count)
            p.initialize(repeating: 0, count: count)
            list.append(UnsafeMutableRawPointer(p))
            return p
        }
        let cf = LofiMasterKernel.clipFactor, ck = LofiMasterKernel.clipTapsPerPhase
        let pf = LofiMasterKernel.peakFactor, pk = LofiMasterKernel.peakTapsPerPhase

        let clipDesign = LofiFIRDesign.oversamplingLowpass(factor: cf, tapsPerPhase: ck,
                                                           cutoff: LofiSaturation.cutoff, beta: LofiSaturation.beta)
        clipUp = floats(cf * (ck + 1))
        Self.polyphase(clipDesign, factor: cf, k: ck, into: clipUp)
        clipDown = floats(clipDesign.count)
        for (i, h) in clipDesign.enumerated() { clipDown[i] = Float(h) }
        let peakDesign = LofiFIRDesign.oversamplingLowpass(factor: pf, tapsPerPhase: pk, cutoff: 1, beta: 8)
        peakUp = floats(pf * (pk + 1))
        Self.polyphase(peakDesign, factor: pf, k: pk, into: peakUp)
        let taps = lookaheadFrames
        hann = floats(taps)
        let raw = (0..<taps).map { k -> Double in
            0.5 - 0.5 * cos(2 * Double.pi * Double(k + 1) / Double(taps + 1))
        }
        let total = raw.reduce(0, +)
        for (k, w) in raw.enumerated() { hann[k] = Float(w / total) }

        workL = floats(n); workR = floats(n); scratch1 = floats(n); scratch2 = floats(n); scratch3 = floats(n)
        sidechainL = floats(n); sidechainR = floats(n)
        glueReduction = floats(n); clipReduction = floats(n); limiterReduction = floats(n)
        gain = floats(n); amount = floats(n)
        firL = floats(n); firR = floats(n); delayedL = floats(n); delayedR = floats(n)
        peak = floats(n); required = floats(n); smooth = floats(n)
        doubleIn = doubles(n + 2); doubleOut = doubles(n + 2)
        highpassHistory = doubles(8); sidechainHistory = doubles(8)
        clipUpHistoryL = floats(ck + n); clipUpHistoryR = floats(ck + n)
        clipDownL = floats(cf * ck + cf * n); clipDownR = floats(cf * ck + cf * n)
        peakHistoryL = floats(pk + n); peakHistoryR = floats(pk + n)
        let overCount = max(cf, pf) * n
        oversampled = floats(overCount); overA = floats(overCount); overB = floats(overCount)
        overC = floats(overCount); overAmount = floats(overCount)
        smoothHistory = floats(lookaheadFrames - 1 + n, 1)
        dequeCapacity = holdFrames + 1
        dequeValues = floats(dequeCapacity)
        let indices = UnsafeMutablePointer<Int>.allocate(capacity: dequeCapacity)
        indices.initialize(repeating: 0, count: dequeCapacity)
        list.append(UnsafeMutableRawPointer(indices))
        dequeIndices = indices
        clipPathL = LofiDelayLine(delay: clipDelay, maximumFrames: n)
        clipPathR = LofiDelayLine(delay: clipDelay, maximumFrames: n)
        limiterDelayL = LofiDelayLine(delay: peakDelay + lookaheadFrames, maximumFrames: n)
        limiterDelayR = LofiDelayLine(delay: peakDelay + lookaheadFrames, maximumFrames: n)
        glueMeterDelay = LofiDelayLine(delay: latency, maximumFrames: n)
        clipMeterDelay = LofiDelayLine(delay: latency, maximumFrames: n)
        let bins = LofiMasterKernel.histogramBins
        let hist = UnsafeMutablePointer<Int>.allocate(capacity: 3 * bins)
        hist.initialize(repeating: 0, count: 3 * bins)
        list.append(UnsafeMutableRawPointer(hist))
        histogram = hist
        meter = .allocate(capacity: 1)
        meter.initialize(to: LofiMeterAccumulator())
        state = .allocate(capacity: 1)
        state.initialize(to: LofiKernelState(applied: .passthrough))
        allocations = list
    }

    deinit {
        for p in allocations { p.deallocate() }
        for line in [clipPathL, clipPathR, limiterDelayL, limiterDelayR, glueMeterDelay, clipMeterDelay] { line.free() }
        meter.deallocate()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    /// Phase p, tap q holds h[p + factor * (k - q)] so correlation against [k history | input] gives
    /// the upsampled value at index factor * i + p.
    private static func polyphase(_ h: [Double], factor: Int, k: Int, into destination: UnsafeMutablePointer<Float>) {
        for p in 0..<factor {
            for q in 0...k {
                let index = p + factor * (k - q)
                destination[p * (k + 1) + q] = index < h.count ? Float(h[index] * Double(factor)) : 0
            }
        }
    }

    func resetState() {
        let applied = state.pointee.applied
        let sequence = state.pointee.lastSequence
        state.pointee = LofiKernelState(applied: applied)
        state.pointee.lastSequence = sequence
        configure(applied, ramp: 0)
        let n = maximumFrames, cf = LofiMasterKernel.clipFactor, ck = LofiMasterKernel.clipTapsPerPhase
        let pk = LofiMasterKernel.peakTapsPerPhase
        highpassHistory.update(repeating: 0, count: 8)
        sidechainHistory.update(repeating: 0, count: 8)
        clipUpHistoryL.update(repeating: 0, count: ck + n); clipUpHistoryR.update(repeating: 0, count: ck + n)
        clipDownL.update(repeating: 0, count: cf * ck + cf * n); clipDownR.update(repeating: 0, count: cf * ck + cf * n)
        peakHistoryL.update(repeating: 0, count: pk + n); peakHistoryR.update(repeating: 0, count: pk + n)
        smoothHistory.update(repeating: 1, count: lookaheadFrames - 1 + n)
        for line in [clipPathL, clipPathR, limiterDelayL, limiterDelayR, glueMeterDelay, clipMeterDelay] { line.clear() }
        clearMeters()
    }

    func clearMeters() {
        meter.pointee = LofiMeterAccumulator()
        histogram.update(repeating: 0, count: 3 * LofiMasterKernel.histogramBins)
    }

    // MARK: Settings

    func configure(_ s: LofiMasterSettings, ramp: Double) {
        let frames = Int((ramp * sampleRate).rounded())
        let st = state
        st.pointee.applied = s
        st.pointee.inputGain.set(dbToGain(s.inputGainDB), frames: frames)
        st.pointee.highpass = s.highpassHz > 0
            ? LofiBiquad.coefficients(.highpass(hz: s.highpassHz, q: 0.7071067811865476), sampleRate: sampleRate)
            : .identity
        if let glue = s.glue {
            st.pointee.glueAmount.set(1, frames: frames)
            if st.pointee.glueAmount.value == 0 && frames > 0 {
                st.pointee.glueThreshold.set(glue.thresholdDB, frames: 0)
                st.pointee.glueMakeup.set(glue.makeupDB, frames: 0)
            } else {
                st.pointee.glueThreshold.set(glue.thresholdDB, frames: frames)
                st.pointee.glueMakeup.set(glue.makeupDB, frames: frames)
            }
            st.pointee.glueRatio = max(1, glue.ratio)
            st.pointee.glueKnee = max(0, glue.kneeDB)
            st.pointee.glueAttack = LofiCompressor.coefficient(glue.attack, sampleRate: sampleRate)
            st.pointee.glueRelease = LofiCompressor.coefficient(glue.release, sampleRate: sampleRate)
            st.pointee.glueUsesRMS = glue.rmsWindow > 0
            st.pointee.glueRMS = LofiCompressor.coefficient(glue.rmsWindow, sampleRate: sampleRate)
            if let hz = glue.sidechainHighpassHz, hz > 0 {
                st.pointee.sidechain = LofiBiquad.coefficients(.highpass(hz: hz, q: 0.7071067811865476),
                                                               sampleRate: sampleRate)
                st.pointee.sidechainActive = true
            } else {
                st.pointee.sidechainActive = false
            }
        } else {
            st.pointee.glueAmount.set(0, frames: frames)
            st.pointee.glueMakeup.set(0, frames: frames)
        }
        if let threshold = s.clipThresholdDB {
            if st.pointee.clipAmount.value == 0 && st.pointee.clipMix.value == 0 {
                st.pointee.clipThresholdDB = threshold
            }
            st.pointee.clipAmount.set(1, frames: frames)
            st.pointee.clipMix.set(1, frames: frames)
            st.pointee.clipThresholdTarget = threshold
            st.pointee.clipThresholdStep = frames > 0 ? (threshold - st.pointee.clipThresholdDB) / Float(frames) : 0
            if frames == 0 { st.pointee.clipThresholdDB = threshold }
        } else {
            st.pointee.clipAmount.set(0, frames: frames)
            st.pointee.clipMix.set(0, frames: frames)
            st.pointee.clipThresholdStep = 0
        }
        st.pointee.clipKneeDB = max(0.1, s.clipKneeDB)
        st.pointee.clipMaxReductionDB = max(0, s.clipMaxReductionDB)
        st.pointee.ceiling.set(dbToGain(s.ceilingDBTP - max(0, s.ceilingMarginDB)), frames: frames)
        st.pointee.nominalCeiling = dbToGain(s.ceilingDBTP)
        st.pointee.limiterEnabled = s.limiterEnabled
        st.pointee.releaseFast = LofiCompressor.coefficient(max(0.001, s.releaseFast), sampleRate: sampleRate)
        st.pointee.releaseSlow = LofiCompressor.coefficient(max(0.001, s.releaseSlow), sampleRate: sampleRate)
        st.pointee.slowCharge = LofiCompressor.coefficient(LofiMasterKernel.slowReleaseCharge, sampleRate: sampleRate)
    }

    // MARK: Block

    /// Double-precision biquad through `vDSP_deq22D`. `history` holds x[-2], x[-1], y[-2], y[-1].
    private func biquad(_ source: UnsafePointer<Float>, _ destination: UnsafeMutablePointer<Float>, _ n: Int,
                        _ c: LofiBiquad.Coefficients, history: UnsafeMutablePointer<Double>) {
        doubleIn[0] = history[0]; doubleIn[1] = history[1]
        doubleOut[0] = history[2]; doubleOut[1] = history[3]
        vDSP_vspdp(source, 1, doubleIn + 2, 1, vDSP_Length(n))
        var coefficients = (c.b0, c.b1, c.b2, c.a1, c.a2)
        withUnsafePointer(to: &coefficients) { tuple in
            tuple.withMemoryRebound(to: Double.self, capacity: 5) { b in
                vDSP_deq22D(doubleIn, 1, b, doubleOut, 1, vDSP_Length(n))
            }
        }
        vDSP_vdpsp(doubleOut + 2, 1, destination, 1, vDSP_Length(n))
        history[0] = doubleIn[n]; history[1] = doubleIn[n + 1]
        history[2] = doubleOut[n]; history[3] = doubleOut[n + 1]
        for i in 0..<4 where abs(history[i]) < 1e-30 { history[i] = 0 }
    }

    /// Writes the soft-clip gain ratio (shaped magnitude over magnitude, at most 1) for `n` samples.
    private func clipRatio(_ source: UnsafePointer<Float>, _ destination: UnsafeMutablePointer<Float>, _ n: Int,
                           a: UnsafeMutablePointer<Float>, b: UnsafeMutablePointer<Float>) {
        let st = state
        var threshold = dbToGain(st.pointee.clipThresholdDB)
        var span = threshold * (dbToGain(st.pointee.clipKneeDB) - 1)
        var floorGain = dbToGain(-st.pointee.clipMaxReductionDB)
        var negativeThreshold = -threshold
        var zero: Float = 0
        var inverseSpan = 1 / span
        var count = Int32(n)
        let length = vDSP_Length(n)
        vDSP_vabs(source, 1, a, 1, length)
        vDSP_vsadd(a, 1, &negativeThreshold, b, 1, length)
        vDSP_vthr(b, 1, &zero, b, 1, length)
        vDSP_vsmul(b, 1, &inverseSpan, b, 1, length)
        vvtanhf(b, b, &count)
        vDSP_vsmsa(b, 1, &span, &threshold, b, 1, length)
        vDSP_vmin(a, 1, b, 1, b, 1, length)
        vDSP_vsmul(a, 1, &floorGain, destination, 1, length)
        vDSP_vmax(b, 1, destination, 1, b, 1, length)
        // (b + tiny) / (a + tiny): exactly 1 below the threshold and for silence.
        var tiny: Float = 1e-20
        vDSP_vsadd(a, 1, &tiny, a, 1, length)
        vDSP_vsadd(b, 1, &tiny, b, 1, length)
        vDSP_vdiv(a, 1, b, 1, destination, 1, length)   // destination = b / a
        var unity: Float = 1
        vDSP_vclip(destination, 1, &zero, &unity, destination, 1, length)
    }

    private func upsample(_ source: UnsafePointer<Float>, history: UnsafeMutablePointer<Float>, k: Int,
                          phases: UnsafePointer<Float>, factor: Int, into destination: UnsafeMutablePointer<Float>,
                          _ n: Int) {
        (history + k).update(from: source, count: n)
        for p in 0..<factor {
            vDSP_conv(history, 1, phases + p * (k + 1), 1, destination + p, vDSP_Stride(factor),
                      vDSP_Length(n), vDSP_Length(k + 1))
        }
        memmove(history, history + n, k * MemoryLayout<Float>.stride)
    }

    func block(_ inL: UnsafePointer<Float>, _ inR: UnsafePointer<Float>,
               _ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>, _ n: Int,
               trace: UnsafeMutableRawPointer?) {
        let st = state
        let length = vDSP_Length(n)
        let xL = workL, xR = workR

        // 1. Sanitize: non-finite input becomes zero, extreme values are bounded.
        xL.update(from: inL, count: n)
        xR.update(from: inR, count: n)
        var sumL: Float = 0, sumR: Float = 0, maxL: Float = 0, maxR: Float = 0
        vDSP_sve(xL, 1, &sumL, length); vDSP_sve(xR, 1, &sumR, length)
        vDSP_maxmgv(xL, 1, &maxL, length); vDSP_maxmgv(xR, 1, &maxR, length)
        if !(sumL.isFinite && sumR.isFinite && maxL <= 1e4 && maxR <= 1e4) {
            for i in 0..<n {
                let a = xL[i], b = xR[i]
                xL[i] = a.isFinite ? min(1e4, max(-1e4, a)) : 0
                xR[i] = b.isFinite ? min(1e4, max(-1e4, b)) : 0
            }
        }

        // 2. Input gain.
        if st.pointee.inputGain.steady {
            var g = st.pointee.inputGain.value
            if g != 1 {
                vDSP_vsmul(xL, 1, &g, xL, 1, length)
                vDSP_vsmul(xR, 1, &g, xR, 1, length)
            }
        } else {
            st.pointee.inputGain.fill(gain, n)
            vDSP_vmul(xL, 1, gain, 1, xL, 1, length)
            vDSP_vmul(xR, 1, gain, 1, xR, 1, length)
        }

        // 3. High-pass.
        // Identity coefficients pass the signal exactly, so the filter always runs and its history stays warm.
        let hp = st.pointee.highpass
        biquad(xL, xL, n, hp, history: highpassHistory)
        biquad(xR, xR, n, hp, history: highpassHistory + 4)

        // 4. Glue compressor (stereo linked, optional sidechain high-pass).
        runGlue(xL, xR, n)

        // 5. Soft clip, 4x oversampled, with an equal-delay bypass path.
        runClip(xL, xR, n)

        // 6. True-peak limiter on the clip output (now in firL/firR).
        runLimiter(firL, firR, outL, outR, n)

        // 7. Meters and trace, aligned to the output.
        glueMeterDelay.process(glueReduction, glueReduction, n)
        clipMeterDelay.process(clipReduction, clipReduction, n)
        updateMeters(n, trace: trace)
        st.pointee.frame += n
    }

    private func runGlue(_ xL: UnsafeMutablePointer<Float>, _ xR: UnsafeMutablePointer<Float>, _ n: Int) {
        let st = state
        let length = vDSP_Length(n)
        var scL = UnsafePointer(xL), scR = UnsafePointer(xR)
        if st.pointee.sidechainActive {
            biquad(xL, sidechainL, n, st.pointee.sidechain, history: sidechainHistory)
            biquad(xR, sidechainR, n, st.pointee.sidechain, history: sidechainHistory + 4)
            scL = UnsafePointer(sidechainL); scR = UnsafePointer(sidechainR)
        }
        let level = scratch1
        vDSP_vmaxmg(scL, 1, scR, 1, level, 1, length)
        let useRMS = st.pointee.glueUsesRMS
        if !useRMS {
            var floor: Float = 1e-10
            var one: Float = 1
            vDSP_vthr(level, 1, &floor, level, 1, length)
            vDSP_vdbcon(level, 1, &one, level, 1, length, 1)
        }
        var amountRamp = st.pointee.glueAmount
        var threshold = st.pointee.glueThreshold
        var makeup = st.pointee.glueMakeup
        let ratio = st.pointee.glueRatio, knee = st.pointee.glueKnee
        let attack = st.pointee.glueAttack, release = st.pointee.glueRelease, rms = st.pointee.glueRMS
        var reduction = st.pointee.glueReduction
        var meanSquare = st.pointee.glueMeanSquare
        let red = glueReduction, gainDB = gain
        var anyGain = false
        for i in 0..<n {
            var levelDB = level[i]
            if useRMS {
                meanSquare = rms * meanSquare + (1 - rms) * levelDB * levelDB
                if meanSquare < 1e-30 { meanSquare = 0 }
                levelDB = 20 * log10f(max(meanSquare.squareRoot(), 1e-10))
            }
            let target = LofiCompressor.staticReductionDB(levelDB: levelDB, thresholdDB: threshold.next(),
                                                          ratio: ratio, kneeDB: knee)
            let c = target > reduction ? attack : release
            reduction = target + c * (reduction - target)
            if reduction < 1e-9 { reduction = 0 }
            let a = amountRamp.next()
            let r = reduction * a
            red[i] = r
            let g = makeup.next() * a - r
            gainDB[i] = g
            if g != 0 { anyGain = true }
        }
        st.pointee.glueAmount = amountRamp
        st.pointee.glueThreshold = threshold
        st.pointee.glueMakeup = makeup
        st.pointee.glueReduction = reduction
        st.pointee.glueMeanSquare = meanSquare
        guard anyGain else { return }
        var scale = Float(log(10.0) / 20)
        var count = Int32(n)
        vDSP_vsmul(gainDB, 1, &scale, gainDB, 1, length)
        vvexpf(gainDB, gainDB, &count)
        vDSP_vmul(xL, 1, gainDB, 1, xL, 1, length)
        vDSP_vmul(xR, 1, gainDB, 1, xR, 1, length)
    }

    private func runClip(_ xL: UnsafeMutablePointer<Float>, _ xR: UnsafeMutablePointer<Float>, _ n: Int) {
        let st = state
        let length = vDSP_Length(n)
        let factor = LofiMasterKernel.clipFactor, k = LofiMasterKernel.clipTapsPerPhase
        let history = factor * k
        // Per-block threshold movement during a ramp.
        if st.pointee.clipThresholdStep != 0 {
            let moved = st.pointee.clipThresholdDB + st.pointee.clipThresholdStep * Float(n)
            let target = st.pointee.clipThresholdTarget
            let done = st.pointee.clipThresholdStep > 0 ? moved >= target : moved <= target
            st.pointee.clipThresholdDB = done ? target : moved
            if done { st.pointee.clipThresholdStep = 0 }
        }
        let amountSteady = st.pointee.clipAmount.steady
        let amountValue = st.pointee.clipAmount.value
        st.pointee.clipAmount.fill(amount, n)
        let active = !(amountSteady && amountValue == 0)

        // Meter: static reduction of the linked base-rate magnitude.
        if active {
            vDSP_vmaxmg(xL, 1, xR, 1, scratch2, 1, length)
            clipRatio(scratch2, scratch3, n, a: scratch1, b: clipReduction)
            var one: Float = 1
            vDSP_vdbcon(scratch3, 1, &one, clipReduction, 1, length, 1)
            vDSP_vneg(clipReduction, 1, clipReduction, 1, length)
            vDSP_vmul(clipReduction, 1, amount, 1, clipReduction, 1, length)
        } else {
            vDSP_vclr(clipReduction, 1, length)
        }
        if active && !amountSteady || active && amountValue != 1 {
            var zero: Float = 0
            for p in 0..<factor {
                vDSP_vsadd(amount, 1, &zero, overAmount + p, vDSP_Stride(factor), length)
            }
        }

        for channel in 0..<2 {
            let x = channel == 0 ? xL : xR
            let upHistory = channel == 0 ? clipUpHistoryL : clipUpHistoryR
            let down = channel == 0 ? clipDownL : clipDownR
            let fir = channel == 0 ? firL : firR
            let os = down + history
            upsample(x, history: upHistory, k: k, phases: clipUp, factor: factor, into: os, n)
            if active {
                let m = factor * n
                clipRatio(os, overC, m, a: overA, b: overB)
                if amountSteady && amountValue == 1 {
                    vDSP_vmul(os, 1, overC, 1, os, 1, vDSP_Length(m))
                } else {
                    // os += amount * (os * ratio - os)
                    vDSP_vmul(os, 1, overC, 1, overB, 1, vDSP_Length(m))
                    vDSP_vsub(os, 1, overB, 1, overB, 1, vDSP_Length(m))
                    vDSP_vma(overB, 1, overAmount, 1, os, 1, os, 1, vDSP_Length(m))
                }
            }
            vDSP_desamp(down, vDSP_Stride(factor), clipDown, fir, length, vDSP_Length(history + 1))
            memmove(down, down + factor * n, history * MemoryLayout<Float>.stride)
            (channel == 0 ? clipPathL : clipPathR).process(x, channel == 0 ? delayedL : delayedR, n)
        }

        // Crossfade between the delay path and the oversampled path.
        let mixSteady = st.pointee.clipMix.steady
        let mixValue = st.pointee.clipMix.value
        if mixSteady && mixValue == 0 {
            firL.update(from: delayedL, count: n)
            firR.update(from: delayedR, count: n)
        } else if !(mixSteady && mixValue == 1) {
            st.pointee.clipMix.fill(scratch1, n)
            for channel in 0..<2 {
                let fir = channel == 0 ? firL : firR, dly = channel == 0 ? delayedL : delayedR
                vDSP_vsub(dly, 1, fir, 1, fir, 1, length)                  // fir - dly
                vDSP_vma(fir, 1, scratch1, 1, dly, 1, fir, 1, length)      // dly + mix * (fir - dly)
            }
        }
    }

    private func runLimiter(_ cL: UnsafeMutablePointer<Float>, _ cR: UnsafeMutablePointer<Float>,
                            _ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>, _ n: Int) {
        let st = state
        let length = vDSP_Length(n)
        let factor = LofiMasterKernel.peakFactor, k = LofiMasterKernel.peakTapsPerPhase
        let L = lookaheadFrames, H = holdFrames
        let enabled = st.pointee.limiterEnabled

        // Linked inter-sample peak per input sample from the 4x copy.
        upsample(cL, history: peakHistoryL, k: k, phases: peakUp, factor: factor, into: oversampled, n)
        vDSP_vabs(oversampled, vDSP_Stride(factor), peak, 1, length)
        for p in 1..<factor {
            vDSP_vmaxmg(oversampled + p, vDSP_Stride(factor), peak, 1, peak, 1, length)
        }
        upsample(cR, history: peakHistoryR, k: k, phases: peakUp, factor: factor, into: oversampled, n)
        for p in 0..<factor {
            vDSP_vmaxmg(oversampled + p, vDSP_Stride(factor), peak, 1, peak, 1, length)
        }

        // Required gain, as reduction in dB (non-negative).
        let reductionDB = required
        if enabled {
            st.pointee.ceiling.fill(scratch1, n)
            var tiny: Float = 1e-20
            vDSP_vsadd(peak, 1, &tiny, peak, 1, length)
            vDSP_vdiv(peak, 1, scratch1, 1, scratch2, 1, length)    // ceiling / peak
            var low: Float = 1e-6, high: Float = 1
            vDSP_vclip(scratch2, 1, &low, &high, scratch2, 1, length)
            var one: Float = 1
            vDSP_vdbcon(scratch2, 1, &one, reductionDB, 1, length, 1)
            vDSP_vneg(reductionDB, 1, reductionDB, 1, length)
        } else {
            vDSP_vclr(reductionDB, 1, length)
        }

        // Dual release before the hold: the fast envelope follows each peak, the slow one charges
        // under sustained reduction and then holds the gain down for longer.
        var fast = st.pointee.fastEnvelope, slow = st.pointee.slowEnvelope
        let af = st.pointee.releaseFast, aSlow = st.pointee.releaseSlow, charge = st.pointee.slowCharge
        var unity = st.pointee.unityRun
        let envelope = scratch3
        for i in 0..<n {
            let r = max(0, reductionDB[i])
            fast = max(r, fast * af)
            if r > slow { slow = r + (slow - r) * charge } else { slow *= aSlow }
            if fast < 1e-6 { fast = 0 }
            if slow < 1e-6 { slow = 0 }
            let c = max(fast, slow)
            envelope[i] = c
            unity = c == 0 ? unity + 1 : 0
        }
        st.pointee.fastEnvelope = fast
        st.pointee.slowEnvelope = slow
        st.pointee.unityRun = unity

        let settled = unity >= n + H + L
        let s = smooth
        if settled {
            var one: Float = 1
            vDSP_vfill(&one, s, 1, length)
            (smoothHistory + (L - 1)).update(repeating: 1, count: n)
            // Hold queue contents are all unity; collapse to keep the window bounded.
            st.pointee.dequeCount = 0
            st.pointee.holdIndex += n
        } else {
            var scale = -Float(log(10.0) / 20)
            var count = Int32(n)
            vDSP_vsmul(envelope, 1, &scale, envelope, 1, length)
            vvexpf(envelope, envelope, &count)

            // Sliding minimum over the hold window (monotonic queue in a preallocated ring).
            let values = dequeValues, indices = dequeIndices, capacity = dequeCapacity
            var head = st.pointee.dequeHead, queued = st.pointee.dequeCount, t = st.pointee.holdIndex
            let held = smoothHistory + (L - 1)
            for i in 0..<n {
                let g = envelope[i]
                while queued > 0 {
                    var back = head + queued - 1
                    if back >= capacity { back -= capacity }
                    if values[back] >= g { queued -= 1 } else { break }
                }
                var position = head + queued
                if position >= capacity { position -= capacity }
                values[position] = g
                indices[position] = t
                queued += 1
                while indices[head] <= t - H {
                    head += 1
                    if head == capacity { head = 0 }
                    queued -= 1
                }
                held[i] = values[head]
                t += 1
            }
            st.pointee.dequeHead = head
            st.pointee.dequeCount = queued
            st.pointee.holdIndex = t

            // Attack smoothing: Hann FIR over the lookahead, so the gain is fully down on arrival.
            vDSP_conv(smoothHistory, 1, hann, 1, s, 1, length, vDSP_Length(L))
        }
        memmove(smoothHistory, smoothHistory + n, (L - 1) * MemoryLayout<Float>.stride)

        // Delay the audio by the detector delay plus the lookahead and apply the gain.
        limiterDelayL.process(cL, outL, n)
        limiterDelayR.process(cR, outR, n)
        if settled {
            vDSP_vclr(limiterReduction, 1, length)
        } else {
            vDSP_vmul(outL, 1, s, 1, outL, 1, length)
            vDSP_vmul(outR, 1, s, 1, outR, 1, length)
            var one: Float = 1
            vDSP_vdbcon(s, 1, &one, limiterReduction, 1, length, 1)
            vDSP_vneg(limiterReduction, 1, limiterReduction, 1, length)
        }

        // Guard clamp at the nominal ceiling. Counted; should never engage.
        guard enabled else { return }
        var nominal = st.pointee.nominalCeiling
        var peakL: Float = 0, peakR: Float = 0
        vDSP_maxmgv(outL, 1, &peakL, length)
        vDSP_maxmgv(outR, 1, &peakR, length)
        if max(peakL, peakR) > nominal {
            var clamps = 0
            let tolerance = nominal * (1 + 1e-5)
            for i in 0..<n {
                if abs(outL[i]) > tolerance { clamps += 1 }
                if abs(outR[i]) > tolerance { clamps += 1 }
            }
            meter.pointee.guardClamps += clamps
            var negative = -nominal
            vDSP_vclip(outL, 1, &negative, &nominal, outL, 1, length)
            vDSP_vclip(outR, 1, &negative, &nominal, outR, 1, length)
        }
    }

    private func updateMeters(_ n: Int, trace: UnsafeMutableRawPointer?) {
        let st = state
        let bins = LofiMasterKernel.histogramBins
        let scale = 1 / LofiMasterKernel.histogramBinDB
        let hist = histogram
        let g = glueReduction, c = clipReduction, l = limiterReduction
        var acc = meter.pointee
        var hopGlue = st.pointee.hopGlue, hopClip = st.pointee.hopClip, hopLimiter = st.pointee.hopLimiter
        var frame = st.pointee.frame
        let hop = LofiMasterKernel.traceHopFrames
        var header: UnsafeMutablePointer<Int>?
        var points: UnsafeMutablePointer<LofiMasterTracePoint>?
        if let trace {
            header = trace.assumingMemoryBound(to: Int.self)
            points = (trace + 16).assumingMemoryBound(to: LofiMasterTracePoint.self)
        }
        for i in 0..<n {
            // Bounded and NaN-free before the histogram index conversion.
            let gv: Float = g[i] > 0 ? min(g[i], 200) : 0
            let cv: Float = c[i] > 0 ? min(c[i], 200) : 0
            let lv: Float = l[i] > 0 ? min(l[i], 200) : 0
            acc.sum.0 += Double(gv); acc.sum.1 += Double(cv); acc.sum.2 += Double(lv)
            if gv > acc.peak.0 { acc.peak.0 = gv }
            if cv > acc.peak.1 { acc.peak.1 = cv }
            if lv > acc.peak.2 { acc.peak.2 = lv }
            hist[min(bins - 1, Int(gv * scale))] += 1
            hist[bins + min(bins - 1, Int(cv * scale))] += 1
            hist[2 * bins + min(bins - 1, Int(lv * scale))] += 1
            if lv > 3 { acc.limiterAbove3 += 1 }
            if cv > 0 { acc.clipEngaged += 1 }
            if gv > hopGlue { hopGlue = gv }
            if cv > hopClip { hopClip = cv }
            if lv > hopLimiter { hopLimiter = lv }
            if (frame + 1) % hop == 0 {
                if let header, let points, header[1] < header[0] {
                    (points + header[1]).initialize(to: LofiMasterTracePoint(frame: frame + 1 - hop, glueDB: hopGlue,
                                                                             clipDB: hopClip, limiterDB: hopLimiter))
                    header[1] += 1
                }
                hopGlue = 0; hopClip = 0; hopLimiter = 0
            }
            frame += 1
        }
        acc.frames += n
        meter.pointee = acc
        st.pointee.hopGlue = hopGlue; st.pointee.hopClip = hopClip; st.pointee.hopLimiter = hopLimiter
    }

    func meterSnapshot() -> LofiMasterMeters {
        let acc = meter.pointee
        let bins = LofiMasterKernel.histogramBins
        let frames = acc.frames
        func p95(_ stage: Int) -> Float {
            guard frames > 0 else { return 0 }
            let goal = Int((0.95 * Double(frames)).rounded(.up))
            var cumulative = 0
            for b in 0..<bins {
                cumulative += histogram[stage * bins + b]
                if cumulative >= goal {
                    return b == 0 ? 0 : (Float(b) + 0.5) * LofiMasterKernel.histogramBinDB
                }
            }
            return Float(bins) * LofiMasterKernel.histogramBinDB
        }
        func mean(_ sum: Double) -> Float { frames > 0 ? Float(sum / Double(frames)) : 0 }
        let fraction = { (count: Int) -> Float in frames > 0 ? Float(count) / Float(frames) : 0 }
        return LofiMasterMeters(glueDB: (mean(acc.sum.0), min(p95(0), acc.peak.0), acc.peak.0),
                                clipDB: (mean(acc.sum.1), min(p95(1), acc.peak.1), acc.peak.1),
                                limiterDB: (mean(acc.sum.2), min(p95(2), acc.peak.2), acc.peak.2),
                                limiterAbove3dBFraction: fraction(acc.limiterAbove3),
                                clipEngagedFraction: fraction(acc.clipEngaged),
                                frames: frames, guardClampCount: acc.guardClamps)
    }
}
