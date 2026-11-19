import Accelerate
import Foundation

/// Feed-forward, stereo-linked compressor with a soft knee (offline chains and tests).
/// Gain reduction is smoothed in dB with separate attack and release one-pole coefficients.
nonisolated struct LofiCompressor: Sendable {
    struct Settings: Sendable, Equatable {
        var thresholdDB: Float, ratio: Float, kneeDB: Float, attack: Double, release: Double
        var makeupDB: Float = 0, sidechainHighpassHz: Double? = nil, rmsWindow: Double = 0
    }

    struct Stats: Sendable { var meanDB: Float; var maxDB: Float }

    let settings: Settings
    let sampleRate: Double
    private(set) var reductionDB: Float = 0
    private let attackCoefficient: Float
    private let releaseCoefficient: Float
    private let rmsCoefficient: Float
    private var meanSquare: Float = 0
    private var sidechainLeft: LofiBiquad?
    private var sidechainRight: LofiBiquad?
    private let makeupGain: Float

    init(_ settings: Settings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = sampleRate
        attackCoefficient = Self.coefficient(settings.attack, sampleRate: sampleRate)
        releaseCoefficient = Self.coefficient(settings.release, sampleRate: sampleRate)
        rmsCoefficient = Self.coefficient(settings.rmsWindow, sampleRate: sampleRate)
        if let hz = settings.sidechainHighpassHz, hz > 0 {
            sidechainLeft = LofiBiquad(.highpass(hz: hz, q: 0.7071067811865476), sampleRate: sampleRate)
            sidechainRight = sidechainLeft
        }
        makeupGain = dbToGain(settings.makeupDB)
    }

    /// One-pole coefficient reaching 1 - 1/e of a step after `seconds`.
    static func coefficient(_ seconds: Double, sampleRate: Double) -> Float {
        seconds > 0 ? Float(exp(-1 / (seconds * sampleRate))) : 0
    }

    /// Static soft-knee curve (Giannoulis, Massberg and Reiss): reduction in dB, never negative.
    @inline(__always)
    static func staticReductionDB(levelDB x: Float, thresholdDB t: Float, ratio: Float, kneeDB w: Float) -> Float {
        let slope = 1 - 1 / max(ratio, 1)
        let over = x - t
        if w > 0, 2 * abs(over) <= w {
            let k = over + w / 2
            return slope * k * k / (2 * w)
        }
        return over > 0 ? slope * over : 0
    }

    /// Linked linear gain including makeup for one stereo detector sample.
    mutating func gain(detectorLeft: Float, detectorRight: Float) -> Float {
        var l = detectorLeft.isFinite ? detectorLeft : 0
        var r = detectorRight.isFinite ? detectorRight : 0
        if sidechainLeft != nil {
            l = sidechainLeft!.process(l)
            r = sidechainRight!.process(r)
        }
        var level = max(abs(l), abs(r))
        if settings.rmsWindow > 0 {
            meanSquare = rmsCoefficient * meanSquare + (1 - rmsCoefficient) * level * level
            if meanSquare < 1e-30 { meanSquare = 0 }
            level = meanSquare.squareRoot()
        }
        let levelDB = 20 * log10f(max(level, 1e-10))
        let target = Self.staticReductionDB(levelDB: levelDB, thresholdDB: settings.thresholdDB,
                                            ratio: settings.ratio, kneeDB: settings.kneeDB)
        let coefficient = target > reductionDB ? attackCoefficient : releaseCoefficient
        reductionDB = target + coefficient * (reductionDB - target)
        if reductionDB < 1e-9 { reductionDB = 0 }
        return dbToGain(-reductionDB) * makeupGain
    }

    /// Compresses a stereo block in place (the signal is its own detector).
    mutating func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) -> Stats {
        var sum: Double = 0
        var peak: Float = 0
        for i in 0..<count {
            let g = gain(detectorLeft: left[i], detectorRight: right[i])
            left[i] *= g
            right[i] *= g
            sum += Double(reductionDB)
            peak = max(peak, reductionDB)
        }
        return Stats(meanDB: count > 0 ? Float(sum / Double(count)) : 0, maxDB: peak)
    }

    mutating func process(left: inout [Float], right: inout [Float]) -> Stats {
        let count = min(left.count, right.count)
        return left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                process(left: l.baseAddress!, right: r.baseAddress!, count: count)
            }
        }
    }

    mutating func reset() {
        reductionDB = 0
        meanSquare = 0
        sidechainLeft?.reset()
        sidechainRight?.reset()
    }
}

/// Split-band de-esser: the band is extracted with a constant-gain band-pass and attenuated in place.
/// With no reduction the output equals the input exactly, so the rest of the spectrum is untouched.
nonisolated struct LofiDeEsser: Sendable {
    let band: ClosedRange<Double>
    let maxReductionDB: Float
    /// Reduction starts when the band envelope is within this many dB of the full-band envelope.
    var relativeThresholdDB: Float = -12
    /// Below this absolute band level nothing is reduced.
    var floorDB: Float = -50
    private var filter: LofiBiquad
    private var bandEnvelope: Float = 0
    private var fullEnvelope: Float = 0
    private var reduction: Float = 0
    private let envelopeAttack: Float
    private let envelopeRelease: Float
    private let gainAttack: Float
    private let gainRelease: Float
    private(set) var reductionDB: Float = 0

    init(band: ClosedRange<Double> = 5_000...8_000, maxReductionDB: Float, sampleRate: Double) {
        self.band = band
        self.maxReductionDB = max(0, maxReductionDB)
        let center = (band.lowerBound * band.upperBound).squareRoot()
        let q = center / max(band.upperBound - band.lowerBound, 1)
        filter = LofiBiquad(.bandpass(hz: center, q: q), sampleRate: sampleRate)
        envelopeAttack = LofiCompressor.coefficient(0.0005, sampleRate: sampleRate)
        envelopeRelease = LofiCompressor.coefficient(0.030, sampleRate: sampleRate)
        gainAttack = LofiCompressor.coefficient(0.002, sampleRate: sampleRate)
        gainRelease = LofiCompressor.coefficient(0.060, sampleRate: sampleRate)
    }

    mutating func process(_ x: Float) -> Float {
        let input = x.isFinite ? x : 0
        let b = filter.process(input)
        func follow(_ env: inout Float, _ value: Float) {
            let c = value > env ? envelopeAttack : envelopeRelease
            env = value + c * (env - value)
            if env < 1e-20 { env = 0 }
        }
        follow(&bandEnvelope, abs(b))
        follow(&fullEnvelope, abs(input))
        let bandDB = 20 * log10f(max(bandEnvelope, 1e-10))
        let fullDB = 20 * log10f(max(fullEnvelope, 1e-10))
        var target: Float = 0
        if bandDB > floorDB {
            target = min(maxReductionDB, max(0, bandDB - fullDB - relativeThresholdDB))
        }
        let c = target > reduction ? gainAttack : gainRelease
        reduction = target + c * (reduction - target)
        if reduction < 1e-6 { reduction = 0 }
        reductionDB = reduction
        guard reduction > 0 else { return input }
        return input + (dbToGain(-reduction) - 1) * b
    }

    mutating func process(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0..<count { buffer[i] = process(buffer[i]) }
    }
}
