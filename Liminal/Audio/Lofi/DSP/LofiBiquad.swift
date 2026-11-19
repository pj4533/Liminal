import Accelerate
import Foundation

/// RBJ cookbook biquad (bilinear transform of the analog prototype, prewarped at the corner).
/// Direct Form II transposed with Double state for per-sample use; block paths use Accelerate.
nonisolated struct LofiBiquad: Sendable {
    enum Kind: Sendable, Equatable {
        case highpass(hz: Double, q: Double), lowpass(hz: Double, q: Double)
        case peak(hz: Double, q: Double, gainDB: Double)
        /// Shelves use the cookbook slope S = 1 (the steepest monotonic shelf).
        case lowShelf(hz: Double, gainDB: Double), highShelf(hz: Double, gainDB: Double)
        /// Constant 0 dB peak gain band-pass.
        case bandpass(hz: Double, q: Double)
        case allpass(hz: Double, q: Double)
    }

    /// Normalized coefficients (a0 = 1) in the order vDSP expects: b0, b1, b2, a1, a2.
    struct Coefficients: Sendable, Equatable {
        var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        static let identity = Coefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
        var array: [Double] { [b0, b1, b2, a1, a2] }
    }

    let kind: Kind
    let sampleRate: Double
    let coefficients: Coefficients
    private var z1 = 0.0
    private var z2 = 0.0

    init(_ kind: Kind, sampleRate: Double) {
        self.kind = kind
        self.sampleRate = sampleRate
        coefficients = Self.coefficients(kind, sampleRate: sampleRate)
    }

    static func coefficients(_ kind: Kind, sampleRate: Double) -> Coefficients {
        func omega(_ hz: Double) -> (cos: Double, sin: Double) {
            let f = min(max(hz, 1e-4 * sampleRate), 0.49 * sampleRate)
            let w = 2 * Double.pi * f / sampleRate
            return (cos(w), sin(w))
        }
        func normalized(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> Coefficients {
            Coefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
        }
        switch kind {
        case let .lowpass(hz, q):
            let (c, s) = omega(hz), alpha = s / (2 * max(q, 1e-3))
            return normalized((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha)
        case let .highpass(hz, q):
            let (c, s) = omega(hz), alpha = s / (2 * max(q, 1e-3))
            return normalized((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha)
        case let .bandpass(hz, q):
            let (c, s) = omega(hz), alpha = s / (2 * max(q, 1e-3))
            return normalized(alpha, 0, -alpha, 1 + alpha, -2 * c, 1 - alpha)
        case let .allpass(hz, q):
            let (c, s) = omega(hz), alpha = s / (2 * max(q, 1e-3))
            return normalized(1 - alpha, -2 * c, 1 + alpha, 1 + alpha, -2 * c, 1 - alpha)
        case let .peak(hz, q, gainDB):
            let (c, s) = omega(hz), alpha = s / (2 * max(q, 1e-3)), a = pow(10, gainDB / 40)
            return normalized(1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a)
        case let .lowShelf(hz, gainDB):
            let (c, s) = omega(hz), a = pow(10, gainDB / 40), alpha = s / 2 * 2.0.squareRoot()
            let k = 2 * a.squareRoot() * alpha
            return normalized(a * ((a + 1) - (a - 1) * c + k), 2 * a * ((a - 1) - (a + 1) * c),
                              a * ((a + 1) - (a - 1) * c - k), (a + 1) + (a - 1) * c + k,
                              -2 * ((a - 1) + (a + 1) * c), (a + 1) + (a - 1) * c - k)
        case let .highShelf(hz, gainDB):
            let (c, s) = omega(hz), a = pow(10, gainDB / 40), alpha = s / 2 * 2.0.squareRoot()
            let k = 2 * a.squareRoot() * alpha
            return normalized(a * ((a + 1) + (a - 1) * c + k), -2 * a * ((a - 1) + (a + 1) * c),
                              a * ((a + 1) + (a - 1) * c - k), (a + 1) - (a - 1) * c + k,
                              2 * ((a - 1) - (a + 1) * c), (a + 1) - (a - 1) * c - k)
        }
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let input = Double(x)
        let c = coefficients
        let y = c.b0 * input + z1
        z1 = c.b1 * input - c.a1 * y + z2
        z2 = c.b2 * input - c.a2 * y
        if abs(z1) < 1e-30 { z1 = 0 }
        if abs(z2) < 1e-30 { z2 = 0 }
        return Float(y)
    }

    /// Per-sample loop over a mono buffer in place.
    mutating func process(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0..<count { buffer[i] = process(buffer[i]) }
    }

    mutating func reset() {
        z1 = 0
        z2 = 0
    }

    /// Magnitude of the digital transfer function at `hz`.
    func magnitudeDB(at hz: Double) -> Double {
        Self.magnitudeDB(coefficients, at: hz, sampleRate: sampleRate)
    }

    static func magnitudeDB(_ c: Coefficients, at hz: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * hz / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = c.b0 + c.b1 * c1 + c.b2 * c2, ni = -(c.b1 * s1 + c.b2 * s2)
        let dr = 1 + c.a1 * c1 + c.a2 * c2, di = -(c.a1 * s1 + c.a2 * s2)
        let power = (nr * nr + ni * ni) / max(dr * dr + di * di, 1e-300)
        return 10 * log10(max(power, 1e-300))
    }
}

/// Stereo cascade sharing one coefficient set, processed in blocks by `vDSP_biquad` (offline paths).
nonisolated struct LofiFilterChain: Sendable {
    let kinds: [LofiBiquad.Kind]
    let sampleRate: Double
    private var storage: Storage

    init(_ kinds: [LofiBiquad.Kind], sampleRate: Double) {
        self.kinds = kinds
        self.sampleRate = sampleRate
        storage = Storage(sections: kinds.map { LofiBiquad.coefficients($0, sampleRate: sampleRate) })
    }

    /// Combined magnitude of the cascade.
    func magnitudeDB(at hz: Double) -> Double {
        storage.sections.reduce(0) { $0 + LofiBiquad.magnitudeDB($1, at: hz, sampleRate: sampleRate) }
    }

    mutating func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        unique()
        storage.run(channel: 0, left, count: count)
        storage.run(channel: 1, right, count: count)
    }

    /// Mono use of the left channel state.
    mutating func process(_ mono: UnsafeMutablePointer<Float>, count: Int) {
        unique()
        storage.run(channel: 0, mono, count: count)
    }

    mutating func process(left: inout [Float], right: inout [Float]) {
        let count = min(left.count, right.count)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                guard let lb = l.baseAddress, let rb = r.baseAddress else { return }
                process(left: lb, right: rb, count: count)
            }
        }
    }

    mutating func reset() {
        unique()
        storage.clear()
    }

    private mutating func unique() {
        if !isKnownUniquelyReferenced(&storage) { storage = storage.copy() }
    }

    private final class Storage: @unchecked Sendable {
        let sections: [LofiBiquad.Coefficients]
        private let setup: vDSP_biquad_SetupD?
        private let delays: UnsafeMutablePointer<Double>
        private let delayCount: Int
        private static let chunk = 4096
        private let input: UnsafeMutablePointer<Double>
        private let output: UnsafeMutablePointer<Double>

        init(sections: [LofiBiquad.Coefficients]) {
            self.sections = sections
            let flat = sections.flatMap(\.array)
            setup = sections.isEmpty ? nil : flat.withUnsafeBufferPointer {
                vDSP_biquad_CreateSetupD($0.baseAddress!, vDSP_Length(sections.count))
            }
            delayCount = 2 * sections.count + 2
            delays = .allocate(capacity: 2 * delayCount)
            delays.initialize(repeating: 0, count: 2 * delayCount)
            input = .allocate(capacity: Self.chunk)
            output = .allocate(capacity: Self.chunk)
        }

        deinit {
            if let setup { vDSP_biquad_DestroySetupD(setup) }
            delays.deallocate()
            input.deallocate()
            output.deallocate()
        }

        func copy() -> Storage {
            let other = Storage(sections: sections)
            other.delays.update(from: delays, count: 2 * delayCount)
            return other
        }

        func clear() { delays.update(repeating: 0, count: 2 * delayCount) }

        /// Double-precision state and arithmetic; Float only at the buffer boundary.
        func run(channel: Int, _ buffer: UnsafeMutablePointer<Float>, count: Int) {
            guard let setup, count > 0 else { return }
            let delay = delays + channel * delayCount
            var offset = 0
            while offset < count {
                let n = min(Self.chunk, count - offset)
                vDSP_vspdp(buffer + offset, 1, input, 1, vDSP_Length(n))
                vDSP_biquadD(setup, delay, input, 1, output, 1, vDSP_Length(n))
                vDSP_vdpsp(output, 1, buffer + offset, 1, vDSP_Length(n))
                offset += n
            }
            for i in 0..<delayCount where abs(delay[i]) < 1e-30 { delay[i] = 0 }
        }
    }
}
