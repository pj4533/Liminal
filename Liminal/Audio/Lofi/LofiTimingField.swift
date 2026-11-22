import Foundation

/// Sparse human timing of one full take, read from its drum landmarks. Other parts can lean
/// toward AJ Hall's kicks and backbeats without the take's audio ever being moved.
/// Beats are take beats (0 ..< 64) unless a method says phrase-local.
nonisolated struct LofiTimingField: Sendable {
    /// Landmarks below this confidence never shape the shared offset.
    static let anchorConfidence: Float = 0.5
    /// A landmark this close to a sixteenth position defines that position's offset exactly.
    static let snapRadius = 0.25
    /// Interpolated offsets fade to zero this far from the nearest anchor.
    static let fadeBeats = 1.0

    let landmarks: [LofiDrumLandmark]
    let framesPerBeat: Double
    let phraseFrames: Int
    /// Where the take's halfway and turnaround fills start (the drop transitions' build).
    let fills: LofiTakeFills
    private let anchors: [(beat: Double, offset: Double)]

    init(landmarks: [LofiDrumLandmark], clock: LofiClock) {
        self.landmarks = landmarks.sorted { $0.attackFrame < $1.attackFrame }
        framesPerBeat = clock.framesPerBeat
        phraseFrames = clock.frameCount
        fills = LofiFillDetector.detect(landmarks: self.landmarks, framesPerBeat: clock.framesPerBeat)
        let fpb = clock.framesPerBeat
        anchors = self.landmarks.compactMap { landmark in
            guard landmark.kind == .kick || landmark.kind == .snare,
                  landmark.confidence >= Self.anchorConfidence, fpb > 0 else { return nil }
            let beat = Double(landmark.attackFrame) / fpb
            return (beat, beat - (beat * 4).rounded() / 4)
        }
    }

    func beat(ofFrame frame: Int) -> Double { framesPerBeat > 0 ? Double(frame) / framesPerBeat : 0 }

    /// Phrase-local beats of kick attacks inside the phrase that starts at `phraseStartBeat`.
    func kicks(phraseStartBeat: Int, minConfidence: Float) -> [Double] {
        attacks(.kick, phraseStartBeat: phraseStartBeat, minConfidence: minConfidence)
    }

    func snares(phraseStartBeat: Int, minConfidence: Float) -> [Double] {
        attacks(.snare, phraseStartBeat: phraseStartBeat, minConfidence: minConfidence)
    }

    private func attacks(_ kind: LofiDrumLandmark.Kind, phraseStartBeat: Int, minConfidence: Float) -> [Double] {
        // The same frame arithmetic as `LofiDrumTake.bassAnchors`, so both agree on phrase edges.
        let start = Int((Double(phraseStartBeat) * framesPerBeat).rounded())
        let end = start + phraseFrames
        return landmarks.compactMap { landmark in
            guard landmark.kind == kind, landmark.confidence >= minConfidence,
                  (start..<end).contains(landmark.attackFrame) else { return nil }
            return Double(landmark.attackFrame - start) / framesPerBeat
        }
    }

    /// The closest attack of `kind` within `within` beats of a take beat.
    func nearestAttack(beat: Double, kind: LofiDrumLandmark.Kind, within: Double) -> (beat: Double, confidence: Float)? {
        var best: (beat: Double, confidence: Float)?
        for landmark in landmarks where landmark.kind == kind {
            let b = self.beat(ofFrame: landmark.attackFrame)
            let distance = abs(b - beat)
            guard distance <= within else { continue }
            if let current = best, abs(current.beat - beat) <= distance { continue }
            best = (b, landmark.confidence)
        }
        return best
    }

    /// Human offset in beats at a sixteenth-grid take beat: the offset of a confident kick or
    /// snare within a quarter beat, otherwise an inverse-distance blend of the neighbouring
    /// anchors' own grid offsets that fades to zero one beat away, otherwise zero.
    func offset(atBeat beat: Double) -> Double {
        guard !anchors.isEmpty else { return 0 }
        // First anchor at or after `beat`.
        var lo = 0, hi = anchors.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if anchors[mid].beat < beat { lo = mid + 1 } else { hi = mid }
        }
        let next = lo < anchors.count ? anchors[lo] : nil
        let previous = lo > 0 ? anchors[lo - 1] : nil
        let nearest = [previous, next].compactMap { $0 }.min { abs($0.beat - beat) < abs($1.beat - beat) }
        if let nearest, abs(nearest.beat - beat) <= Self.snapRadius { return nearest.beat - beat }
        var weighted = 0.0, total = 0.0, closest = Double.infinity
        for anchor in [previous, next].compactMap({ $0 }) {
            let distance = abs(anchor.beat - beat)
            guard distance < Self.fadeBeats else { continue }
            weighted += anchor.offset / distance
            total += 1 / distance
            closest = min(closest, distance)
        }
        guard total > 0 else { return 0 }
        let fade = min(1, max(0, (Self.fadeBeats - closest) / (Self.fadeBeats - Self.snapRadius)))
        return weighted / total * fade
    }

    /// Clamp of a sixteenth's offset in beats: straight-ish on 8th positions, swung later on the
    /// odd sixteenths ("e" and "a"), as AJ Hall plays them (D126).
    static let evenStepClamp: ClosedRange<Double> = -0.06...0.06
    static let oddStepClamp: ClosedRange<Double> = -0.04...0.19
    /// Neighbouring sixteenths keep at least this many beats between them.
    static let minimumStepSpacing = 0.02

    /// The drummer's offset in beats at each of the take's `count` sixteenths, for the dialogue
    /// chops' step grid (D126). Each confident kick or snare belongs to at most one step: the step
    /// it follows within a quarter of a sixteenth, an even step it precedes by at most a quarter,
    /// or, between, an odd step it follows (a swung "e" or "a"). A step without its own hit takes the
    /// take's median offset for its place in the beat; it never borrows a neighbour's hit, which
    /// put a step a whole swung sixteenth early (the D125 captures' step 8 on the pickup kick).
    func sixteenthOffsets(count: Int = 256) -> [Double] {
        guard count > 0 else { return [] }
        var assigned = [(offset: Double, confidence: Float)?](repeating: nil, count: count)
        if framesPerBeat > 0 {
            for landmark in landmarks where (landmark.kind == .kick || landmark.kind == .snare)
                && landmark.confidence >= Self.anchorConfidence {
                let x = Double(landmark.attackFrame) / framesPerBeat * 4
                let below = Int(x.rounded(.down))
                let q = x - Double(below)
                let step: Int?
                if q <= 0.24 {
                    step = below
                } else if q >= 0.76 {
                    step = (below + 1).isMultiple(of: 2) ? below + 1 : nil
                } else {
                    step = below.isMultiple(of: 2) ? nil : below
                }
                guard let step, step >= 0, step < count else { continue }
                let offset = (x - Double(step)) / 4
                if let current = assigned[step], current.confidence >= landmark.confidence { continue }
                assigned[step] = (offset, landmark.confidence)
            }
        }
        var classMedian = [Double](repeating: 0, count: 4)
        for c in 0..<4 {
            let values = stride(from: c, to: count, by: 4).compactMap { assigned[$0]?.offset }.sorted()
            guard !values.isEmpty else { continue }
            let mid = values.count / 2
            classMedian[c] = values.count.isMultiple(of: 2) ? (values[mid - 1] + values[mid]) / 2 : values[mid]
        }
        var out = (0..<count).map { s -> Double in
            let raw = assigned[s]?.offset ?? classMedian[s % 4]
            let clamp = s.isMultiple(of: 2) ? Self.evenStepClamp : Self.oddStepClamp
            return min(max(raw, clamp.lowerBound), clamp.upperBound)
        }
        // Strictly increasing step times: a step never sits closer than `minimumStepSpacing` to the one before.
        for s in 1..<count {
            let earliest = out[s - 1] - 0.25 + Self.minimumStepSpacing
            if out[s] < earliest { out[s] = earliest }
        }
        return out
    }

    // MARK: Diagnostics

    /// Median signed distance of confident kicks from their nearest sixteenth, in beats.
    var medianKickOffset: Double {
        let offsets = landmarks.filter { $0.kind == .kick && $0.confidence >= Self.anchorConfidence }.map { landmark in
            let b = beat(ofFrame: landmark.attackFrame)
            return b - (b * 4).rounded() / 4
        }.sorted()
        guard !offsets.isEmpty else { return 0 }
        let mid = offsets.count / 2
        return offsets.count.isMultiple(of: 2) ? (offsets[mid - 1] + offsets[mid]) / 2 : offsets[mid]
    }

    var counts: [LofiDrumLandmark.Kind: Int] {
        var result = Dictionary(uniqueKeysWithValues: LofiDrumLandmark.Kind.allCases.map { ($0, 0) })
        for landmark in landmarks { result[landmark.kind, default: 0] += 1 }
        return result
    }
}
