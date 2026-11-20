import Foundation

/// Where a take's two fills start (docs/plans/drop-transitions.md 3.1), in take beats, with the fill's
/// own attacks. Detected from the landmarks each take already has; no audio is read and nothing moves.
nonisolated struct LofiTakeFills: Sendable, Equatable {
    /// In take beats, before beat 32.
    var halfwayStartBeat: Double
    /// In take beats, before beat 64.
    var turnaroundStartBeat: Double
    var halfwayDetected: Bool
    var turnaroundDetected: Bool
    /// Attack beats inside each fill, the strongest 32 at most, ascending.
    var halfwayHits: [Double]
    var turnaroundHits: [Double]

    /// No landmarks (no private drum takes): the build lengths the audio fill accent already uses.
    static let defaults = LofiTakeFills(
        halfwayStartBeat: 32 - LofiFillDetector.defaultBuild(.halfway),
        turnaroundStartBeat: 64 - LofiFillDetector.defaultBuild(.turnaround),
        halfwayDetected: false, turnaroundDetected: false, halfwayHits: [], turnaroundHits: [])

    func startBeat(_ fill: LofiFill) -> Double { fill == .halfway ? halfwayStartBeat : turnaroundStartBeat }
    func hits(_ fill: LofiFill) -> [Double] { fill == .halfway ? halfwayHits : turnaroundHits }
    func detected(_ fill: LofiFill) -> Bool { fill == .halfway ? halfwayDetected : turnaroundDetected }
}

/// Finds the start of the fill before beat 32 and beat 64 of a 64-beat take.
///
/// Activity per beat is the weighted landmark count. The take's own groove (its backbeat pattern) is
/// removed with a per-position-in-the-bar median over the groove beats (0-23 and 32-55), and the fill is
/// the suffix ending at the boundary with the largest summed excess, searched over 1 to 8 beats.
nonisolated enum LofiFillDetector {
    static let beats = 64
    /// Search range in beats before the boundary.
    static let maxBeats = 8
    /// Hits kept per fill (the strongest, then sorted by time).
    static let maxHits = 32

    static func defaultBuild(_ fill: LofiFill) -> Double { fill.buildBeats }

    static func weight(_ kind: LofiDrumLandmark.Kind) -> Double { kind == .hat ? 0.5 : 1 }

    static func detect(landmarks: [LofiDrumLandmark], framesPerBeat: Double) -> LofiTakeFills {
        guard framesPerBeat > 0, !landmarks.isEmpty else { return .defaults }
        var d = [Double](repeating: 0, count: beats)
        var beatsOf: [(beat: Double, w: Double)] = []
        beatsOf.reserveCapacity(landmarks.count)
        for l in landmarks {
            let b = Double(l.attackFrame) / framesPerBeat
            guard b >= 0, b < Double(beats) else { continue }
            let w = weight(l.kind) * (0.5 + 0.5 * Double(min(max(l.strength, 0), 1)))
            d[Int(b)] += w
            beatsOf.append((b, w))
        }
        beatsOf.sort { $0.beat < $1.beat }
        guard !beatsOf.isEmpty else { return .defaults }
        let groove = Array(0..<24) + Array(32..<56)
        let m: [Double] = (0..<4).map { j in median(groove.filter { $0 % 4 == j }.map { d[$0] }) }
        let tau = max(1.0, 0.3 * median(d))
        let x = (0..<beats).map { d[$0] - m[$0 % 4] - tau }

        func boundary(_ b: Int, _ fill: LofiFill) -> (start: Double, detected: Bool, hits: [Double]) {
            var best = -Double.infinity, bestStart = b - 1
            var sum = 0.0
            for s in stride(from: b - 1, through: b - maxBeats, by: -1) {
                sum += x[s]
                if sum > best { best = sum; bestStart = s }
            }
            let detected = best > 0
            var start: Double
            if detected {
                start = beatsOf.first { $0.beat >= Double(bestStart) && $0.beat < Double(bestStart + 1) }?.beat ?? Double(bestStart)
            } else {
                start = Double(b) - defaultBuild(fill)
            }
            start = min(max(start, Double(b - maxBeats)), Double(b - 1))
            let inside = beatsOf.filter { $0.beat >= start - 1e-9 && $0.beat < Double(b) }
            let hits = inside.sorted { $0.w > $1.w }.prefix(maxHits).map(\.beat).sorted()
            return (start, detected, hits)
        }
        let h = boundary(32, .halfway), t = boundary(64, .turnaround)
        return LofiTakeFills(halfwayStartBeat: h.start, turnaroundStartBeat: t.start,
                             halfwayDetected: h.detected, turnaroundDetected: t.detected,
                             halfwayHits: h.hits, turnaroundHits: t.hits)
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// The build in seconds for a fill start: at least one beat, at most eight beats and six seconds
    /// (then the largest whole number of beats that fits).
    static func clampedStartBeat(_ start: Double, boundary b: Double, beatDuration: Double) -> Double {
        guard beatDuration > 0 else { return b - 1 }
        var beatsBack = min(max(b - start, 1), Double(maxBeats))
        if beatsBack * beatDuration > 6 { beatsBack = max(1, floor(6 / beatDuration)) }
        return b - beatsBack
    }
}
