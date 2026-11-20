import Accelerate
import AVFoundation
import Foundation

/// One syllable nucleus (de Jong and Wempe): an intensity peak with a dip on each side, voiced.
nonisolated struct DialogueNucleus: Sendable, Equatable {
    /// Hop index of the intensity peak.
    let hop: Int
    /// Source frame of the syllable onset (the stress anchor of the syllable).
    let onsetFrame: Int
    let peakFrame: Int
    let intensityDB: Float
    let energy: Float
    let voiced: Bool
}

/// Signal features of the analysed span. Transport independent and free of PCM references.
nonisolated struct DialogueFeatures: Sendable {
    let sampleRate: Double
    let hop: Int
    let fineHop: Int
    /// Analysed frames: min(32 s, buffer) rounded down to whole hops.
    let frameCount: Int
    /// Mean square per hop in the three speech bands (corners 145, 820, 3900 Hz).
    let bands: [SIMD3<Float>]
    let floor: SIMD3<Float>
    /// Floor-subtracted speech energy, as `LofiDialogueSampler` computes it.
    let energy: [Float]
    let gate: Float
    /// 300 to 3000 Hz intensity contour in dBFS, lightly smoothed.
    let intensity: [Float]
    let noiseDB: Float
    let topDB: Float
    /// 1 ms RMS envelope of the full band.
    let fine: [Float]
    let nuclei: [DialogueNucleus]
    /// Hops above `noise + 6 dB`.
    let active: [Bool]
    /// Inactive runs of at least 80 ms, in hops.
    let pauses: [Range<Int>]
    let peak: Float

    var hops: Int { bands.count }
    func hop(frame: Int) -> Int { min(max(0, frame / hop), hops - 1) }
    func fineIndex(frame: Int) -> Int { min(max(0, frame / fineHop), fine.count - 1) }
    func seconds(hops n: Int) -> Double { Double(n * hop) / sampleRate }
    func hops(seconds: Double) -> Int { max(1, Int((seconds * sampleRate / Double(hop)).rounded())) }
    func frames(seconds: Double) -> Int { Int((seconds * sampleRate).rounded()) }
    func intensity(frame: Int) -> Float { intensity[hop(frame: frame)] }
}

/// Analysis of one cue: features plus the acoustic hierarchy. Cacheable by
/// (content id, source start, length, analysis version).
nonisolated struct DialogueAnalysis: Sendable {
    let version: Int
    let contentID: String
    let cueToken: Int
    let clock: DialogueClock
    let bufferFrames: Int
    let features: DialogueFeatures?
    let speech: [LofiSpeechFocus.Window]
    let units: [SpeechUnit]
    let rejections: [DialogueRejection]

    var sampleRate: Double { clock.sampleRate }
    func unit(_ id: Int) -> SpeechUnit? { units.indices.contains(id) && units[id].id == id ? units[id] : units.first { $0.id == id } }
    var rejected: [Int: DialogueRejection.Reason] {
        Dictionary(rejections.map { ($0.unit, $0.reason) }, uniquingKeysWith: { a, _ in a })
    }
}

nonisolated enum DialogueAnalyzer {
    static func analyze(_ source: DialogueSource, speech: [LofiSpeechFocus.Window], version: Int) -> DialogueAnalysis {
        let clock = DialogueClock(sourceStart: source.sourceStart, rate: source.rate, sampleRate: source.sampleRate)
        let count = min(source.frameCount, Int(DialogueTuning.analysisSeconds * source.sampleRate))
        guard count > 0, let input = source.buffer.floatChannelData?[0],
              let features = features(input, count: count, sampleRate: source.sampleRate) else {
            return DialogueAnalysis(version: version, contentID: source.contentID, cueToken: source.cueToken, clock: clock,
                                    bufferFrames: source.frameCount, features: nil, speech: speech, units: [], rejections: [])
        }
        let built = DialogueHierarchy.build(features, samples: input, count: features.frameCount, speech: speech)
        return DialogueAnalysis(version: version, contentID: source.contentID, cueToken: source.cueToken, clock: clock,
                                bufferFrames: source.frameCount, features: features, speech: speech,
                                units: built.units, rejections: built.rejections)
    }

    // MARK: Features

    static func features(_ x: UnsafePointer<Float>, count: Int, sampleRate rate: Double) -> DialogueFeatures? {
        let hop = max(1, Int((rate * DialogueTuning.hopSeconds).rounded()))
        let hops = count / hop
        guard hops >= 40 else { return nil }
        let n = hops * hop
        let input = Array(UnsafeBufferPointer(start: x, count: n))
        let corners = DialogueTuning.bandCornersHz
        let low0 = onePole(input, hz: corners[0], rate: rate)
        let low1 = onePole(input, hz: corners[1], rate: rate)
        let low2 = onePole(input, hz: corners[2], rate: rate)
        let bandA = meanSquares(subtract(low1, low0), hop: hop)
        let bandB = meanSquares(subtract(low2, low1), hop: hop)
        let bandC = meanSquares(subtract(input, low2), hop: hop)
        var bands = [SIMD3<Float>](repeating: .zero, count: hops)
        for i in 0..<hops { bands[i] = SIMD3(bandA[i], bandB[i], bandC[i]) }
        let floorIndex = Int(Double(hops) * DialogueTuning.floorPercentile)
        let floor = SIMD3<Float>(bandA.sorted()[floorIndex], bandB.sorted()[floorIndex], bandC.sorted()[floorIndex])
        var energy = bands.map { band -> Float in
            sqrtf(max(0, band.x - floor.x) + 1.35 * max(0, band.y - floor.y))
        }
        smooth(&energy)
        let typical = energy.sorted()[hops * 4 / 5]
        let gate = max(DialogueTuning.gateMinimum, typical * DialogueTuning.gateFraction)

        let speechLow = onePole(input, hz: DialogueTuning.intensityLowHz, rate: rate)
        let speechHigh = onePole(input, hz: DialogueTuning.intensityHighHz, rate: rate)
        var intensity = meanSquares(subtract(speechHigh, speechLow), hop: hop).map { 10 * log10f(max($0, 1e-12)) }
        smooth(&intensity)
        let sortedIntensity = intensity.sorted()
        let noise = sortedIntensity[Int(Double(hops) * DialogueTuning.noisePercentile)]
        let top = sortedIntensity[min(hops - 1, Int(Double(hops) * 0.99))]

        let fineHop = max(1, Int((rate * DialogueTuning.fineHopSeconds).rounded()))
        let fine = meanSquares(input, hop: fineHop).map { sqrtf($0) }

        let threshold = noise + DialogueTuning.pauseMarginDB
        let active = intensity.map { $0 > threshold && top > -70 }
        var pauses: [Range<Int>] = []
        var runStart: Int?
        for i in 0...hops {
            let quiet = i < hops && !active[i]
            if quiet, runStart == nil { runStart = i }
            if !quiet, let s = runStart {
                if i - s >= Int((DialogueTuning.pauseGroupSeconds / DialogueTuning.hopSeconds).rounded()) { pauses.append(s..<i) }
                runStart = nil
            }
        }
        var peak: Float = 0
        vDSP_maxmgv(x, 1, &peak, vDSP_Length(n))
        let partial = DialogueFeatures(sampleRate: rate, hop: hop, fineHop: fineHop, frameCount: n, bands: bands,
                                       floor: floor, energy: energy, gate: gate, intensity: intensity, noiseDB: noise,
                                       topDB: top, fine: fine, nuclei: [], active: active, pauses: pauses, peak: peak)
        let nuclei = findNuclei(partial, samples: x, lowpassed: speechHigh)
        return DialogueFeatures(sampleRate: rate, hop: hop, fineHop: fineHop, frameCount: n, bands: bands,
                                floor: floor, energy: energy, gate: gate, intensity: intensity, noiseDB: noise,
                                topDB: top, fine: fine, nuclei: nuclei, active: active, pauses: pauses, peak: peak)
    }

    /// Peaks of the intensity contour above `p99 - 25 dB` with a 2 dB dip on both sides, voiced.
    private static func findNuclei(_ f: DialogueFeatures, samples x: UnsafePointer<Float>,
                                   lowpassed: [Float]) -> [DialogueNucleus] {
        let s = f.intensity
        let threshold = max(f.topDB - DialogueTuning.nucleusRangeDB, f.noiseDB + DialogueTuning.pauseMarginDB)
        var accepted: [Int] = []
        for i in 1..<(f.hops - 1) {
            guard s[i] >= s[i-1], s[i] > s[i+1], s[i] > threshold, f.energy[i] > f.gate else { continue }
            if let last = accepted.last {
                let dip = s[last...i].min() ?? s[i]
                if min(s[last], s[i]) - dip < DialogueTuning.nucleusDipDB {
                    if s[i] > s[last] { accepted[accepted.count - 1] = i }
                    continue
                }
            }
            accepted.append(i)
        }
        let rate = f.sampleRate
        let factor = max(1, Int(rate / DialogueTuning.voicingDecimatedRate))
        let decimatedRate = rate / Double(factor)
        let frameLength = Int(DialogueTuning.voicingFrameSeconds * decimatedRate)
        let minLag = max(1, Int(decimatedRate / DialogueTuning.voicingHighHz))
        let maxLag = min(frameLength - 2, Int(decimatedRate / DialogueTuning.voicingLowHz))
        let rawFrame = Int(DialogueTuning.voicingFrameSeconds * rate)
        var result: [DialogueNucleus] = []
        var previousPeak = -1
        for (index, i) in accepted.enumerated() {
            let center = i * f.hop + f.hop / 2
            // Normalised autocorrelation on the decimated low-passed signal.
            let start = max(0, center - rawFrame / 2)
            var frame = [Float](repeating: 0, count: frameLength)
            for k in 0..<frameLength {
                let j = start + k * factor
                frame[k] = j < lowpassed.count ? lowpassed[j] : 0
            }
            var best: Float = 0
            if maxLag > minLag {
                frame.withUnsafeBufferPointer { p in
                    guard let base = p.baseAddress else { return }
                    for lag in minLag...maxLag {
                        let len = vDSP_Length(frameLength - lag)
                        var xy: Float = 0, xx: Float = 0, yy: Float = 0
                        vDSP_dotpr(base, 1, base + lag, 1, &xy, len)
                        vDSP_svesq(base, 1, &xx, len)
                        vDSP_svesq(base + lag, 1, &yy, len)
                        let r = xy / max(1e-12, sqrtf(xx * yy))
                        best = max(best, r)
                    }
                }
            }
            var crossings = 0
            let rawEnd = min(f.frameCount, start + rawFrame)
            if rawEnd > start + 1 {
                for j in (start + 1)..<rawEnd where (x[j-1] < 0) != (x[j] < 0) { crossings += 1 }
            }
            let zcr = Double(crossings) / max(1e-9, Double(rawEnd - start) / rate)
            let voiced = best > DialogueTuning.voicingThreshold || zcr < DialogueTuning.voicedZeroCrossingsPerSecond
            guard voiced else { continue }
            // Onset: the first hop before the peak 6 dB under it, refined on the 1 ms envelope.
            let previous = index > 0 ? accepted[index - 1] : max(0, i - 15)
            var j = i
            while j > max(previous, i - 15), s[j-1] > s[i] - 6 { j -= 1 }
            let fineStart = f.fineIndex(frame: j * f.hop)
            let fineEnd = max(fineStart + 1, f.fineIndex(frame: (i + 1) * f.hop))
            let fineMax = f.fine[fineStart..<fineEnd].max() ?? 0
            var onset = fineStart
            while onset < fineEnd - 1, f.fine[onset] < 0.5 * fineMax { onset += 1 }
            let peakFine = (fineStart..<fineEnd).max { f.fine[$0] < f.fine[$1] } ?? onset
            let onsetFrame = max(onset * f.fineHop, previousPeak + 1)
            previousPeak = peakFine * f.fineHop
            result.append(DialogueNucleus(hop: i, onsetFrame: onsetFrame, peakFrame: max(onsetFrame, peakFine * f.fineHop),
                                          intensityDB: s[i], energy: f.energy[i], voiced: true))
        }
        return result
    }

    // MARK: Accelerate helpers

    /// `y += a (x - y)` with `a = 1 - exp(-2 pi hz / rate)`, the sampler's one-pole low-pass.
    static func onePole(_ x: [Float], hz: Double, rate: Double) -> [Float] {
        let a = Float(1 - exp(-2 * .pi * hz / rate))
        var padded = [Float](repeating: 0, count: x.count + 2)
        padded.withUnsafeMutableBufferPointer { p in
            x.withUnsafeBufferPointer { src in (p.baseAddress! + 2).update(from: src.baseAddress!, count: x.count) }
        }
        var output = [Float](repeating: 0, count: x.count + 2)
        var coefficients: [Float] = [a, 0, 0, -(1 - a), 0]
        vDSP_deq22(padded, 1, &coefficients, &output, 1, vDSP_Length(x.count))
        return Array(output[2...])
    }

    static func subtract(_ a: [Float], _ b: [Float]) -> [Float] {
        var result = [Float](repeating: 0, count: a.count)
        vDSP_vsub(b, 1, a, 1, &result, 1, vDSP_Length(a.count))   // a - b
        return result
    }

    /// Mean square per `hop` samples.
    static func meanSquares(_ x: [Float], hop: Int) -> [Float] {
        let count = x.count / hop
        guard count > 0 else { return [] }
        var squares = [Float](repeating: 0, count: count * hop)
        vDSP_vsq(x, 1, &squares, 1, vDSP_Length(count * hop))
        let filter = [Float](repeating: 1 / Float(hop), count: hop)
        var result = [Float](repeating: 0, count: count)
        vDSP_desamp(squares, vDSP_Stride(hop), filter, &result, vDSP_Length(count), vDSP_Length(hop))
        return result
    }

    /// `[1 2 1] / 4` smoothing, as the sampler applies to its energy.
    static func smooth(_ x: inout [Float]) {
        guard x.count > 2 else { return }
        let copy = x
        for i in 1..<(x.count - 1) { x[i] = (copy[i-1] + 2 * copy[i] + copy[i+1]) * 0.25 }
    }
}
