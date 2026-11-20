import Accelerate
import Foundation

/// Offline effect chains for the Lo-Fi music sections (plan 8.2 to 8.4): every setting a chain
/// uses is named here, and each `apply` runs one chain on buffers the renderer or the drum take
/// has already produced. Everything runs on preparation threads, never on the render thread.
///
/// The chains are zero-latency: filters are minimum-phase biquads (`LofiFilterChain`), the
/// dynamics are feed-forward without lookahead delay, and the oversampled saturation compensates
/// its linear-phase resampling filters. A landmark found on the unprocessed audio therefore
/// still points at the same frame afterwards.
///
/// Dynamics run per `blockFrames` block: the detector is the block's linked peak, the gain is
/// smoothed in dB at block rate with the stage's attack and release, and the per-sample gain
/// is a linear ramp between block values. That keeps a 64-beat take inside its preparation
/// budget even in an unoptimized Debug build.
nonisolated enum LofiStemChains {
    static let blockFrames = 32
    static let butterworthQ = 0.7071067811865476

    // MARK: Settings

    /// A compressor whose threshold follows the material: `reference - thresholdBelowReferenceDB`,
    /// where the reference is the 95th percentile of the signal's 10 ms peak levels.
    struct Dynamics: Sendable, Equatable {
        var ratio: Float
        var kneeDB: Float
        var attack: Double
        var release: Double
        var thresholdBelowReferenceDB: Float
        var makeupDB: Float = 0

        func settings(thresholdDB: Float) -> LofiCompressor.Settings {
            .init(thresholdDB: thresholdDB, ratio: ratio, kneeDB: kneeDB, attack: attack, release: release,
                  makeupDB: makeupDB)
        }
    }

    /// Drum bus, per take (plan 8.2).
    struct Drums: Sendable, Equatable {
        var monoBelowHz = 100.0
        var filters: [LofiBiquad.Kind] = [.highpass(hz: 32, q: butterworthQ), .peak(hz: 320, q: 1.0, gainDB: -2.5)]
        var bus = Dynamics(ratio: 3, kneeDB: 6, attack: 0.020, release: 0.120, thresholdBelowReferenceDB: 8)
        var parallel = Dynamics(ratio: 8, kneeDB: 2, attack: 0.002, release: 0.080, thresholdBelowReferenceDB: 10,
                                makeupDB: 10)
        var parallelMix: Float = 0.25
        /// Peak reduction of the tape stage at the take's typical hit level (the 95th percentile of
        /// its 10 ms peaks); rarer, louder hits are rounded a little more.
        var saturationPeakRoundingDB: Float = 1.5
        /// The rounding grows (up to `saturationMaxRoundingDB`) until the take's crest factor
        /// reaches this target: AJ Hall's takes differ by 7 dB in crest, one setting cannot fit all.
        var targetCrestDB: Float = 12.5
        var saturationMaxRoundingDB: Float = 4.5
        var oversampling = 2
        var air: [LofiBiquad.Kind] = [.highShelf(hz: 11_000, gainDB: -2)]
        /// The processed take is trimmed down (never up) to peak at or below this level.
        var peakCeilingDB: Float = -4
        /// Tests: turn off compressors, saturation and trim to measure the static filters alone.
        var dynamicsEnabled = true
        static let standard = Drums()
    }

    /// Dry lead, per phrase (plan 8.4). Complements the renderer's one gain per phrase.
    struct Lead: Sendable, Equatable {
        /// The 2.8 kHz presence bell (+1.5 dB) sits in the tucked chops' -4 dB cut at 2.8 kHz
        /// (`DialogueChopChain`); the chops in turn leave a narrow dip at the lead's body (`leadRoomHz`).
        /// User direction of 19 November 2026: the melody tucks in, so the lead gets no extra level or
        /// brighter presence against the chops, only this band separation.
        var filters: [LofiBiquad.Kind] = [
            .highpass(hz: 180, q: butterworthQ), .peak(hz: 350, q: 1.0, gainDB: -2),
            .peak(hz: 2_800, q: 0.8, gainDB: 1.5), .lowpass(hz: 9_000, q: butterworthQ),
        ]
        /// Kept at 2.5:1 from 4 dB (0.4 to 0.7 dB mean): 3:1 from 5 dB measured the lead 0.7 to 1 dB quieter
        /// on 19 November 2026, against the direction that the melody keeps its level.
        var compressor = Dynamics(ratio: 2.5, kneeDB: 4, attack: 0.015, release: 0.150, thresholdBelowReferenceDB: 4)
        var dynamicsEnabled = true
        static let standard = Lead()
    }

    /// Effect returns (`wet`), per phrase plus its tail (plan 8.4).
    struct Space: Sendable, Equatable {
        var filters: [LofiBiquad.Kind] = [
            .highpass(hz: 350, q: butterworthQ), .lowpass(hz: 4_500, q: butterworthQ),
            .peak(hz: 2_500, q: 1.0, gainDB: -2),
        ]
        /// Duck keyed by the dry lead so notes are heard dry first and the room blooms after them.
        var duckDepthDB: Float = 4
        /// Envelope follower of the lead's block peaks: fast attack, a short hold, then release.
        var duckAttack = 0.002
        var duckHold = 0.030
        var duckRelease = 0.100
        /// The level term: full when the lead envelope reaches its strong-note level (the phrase's
        /// reference), none `duckKneeDB` below it.
        var duckKneeDB: Float = 6
        /// Sustain share of the depth. A note onset (a block peak `duckOnsetJumpDB` over the envelope,
        /// above the knee) opens the rest of the depth for `duckOnsetHold`, which then decays with
        /// `duckOnsetDecay`. The pinned duck before 19 November 2026 (9 dB knee, 250 ms release) held 3.1
        /// to 3.6 dB of its 4 dB in every phrase, a static trim rather than a duck; this shape measured
        /// 1.5 to 1.6 dB mean (at most 2.0 in a phrase) on the same dry stems, with the full 4 dB on onsets.
        var duckSustainShare: Float = 0.25
        var duckOnsetHold = 0.030
        var duckOnsetDecay = 0.15
        var duckOnsetJumpDB: Float = 3
        /// Static level of the space after the duck, -1.5 dB (19 November 2026). The pinned duck held
        /// 3.1 to 3.6 dB all the time, so part of it was really a trim; with the duck released between
        /// notes this keeps the space under the lead (C-B7) and near its former overall level.
        var outputTrimDB: Float = -1.5
        var outputGain: Float { powf(10, outputTrimDB / 20) }
        static let standard = Space()
    }

    // MARK: Stats

    struct Stats: Sendable, Equatable {
        var inPeakDb: Float = -120
        var outPeakDb: Float = -120
        var inRmsDb: Float = -120
        var outRmsDb: Float = -120
        /// Mean over blocks with signal, and maximum, of the main compressor's reduction.
        var grMeanDb: Float = 0
        var grMaxDb: Float = 0
        /// Stage details (parallel reduction, trim, duck depth, threshold).
        var extra: [String: Float] = [:]

        /// `diagnostics.stemChains[]` element (plan 3.2).
        func entry(bus: String, phrase: Int? = nil, take: Int? = nil) -> [String: Any] {
            func round(_ v: Float) -> Double { (Double(v) * 100).rounded() / 100 }
            var row: [String: Any] = ["bus": bus, "inPeakDb": round(inPeakDb), "outPeakDb": round(outPeakDb),
                                      "inRmsDb": round(inRmsDb), "outRmsDb": round(outRmsDb),
                                      "grMeanDb": round(grMeanDb), "grMaxDb": round(grMaxDb)]
            if let phrase { row["phrase"] = phrase }
            if let take { row["take"] = take }
            for (key, value) in extra { row[key] = round(value) }
            return row
        }
    }

    /// Appends to the capture's `stemChains` report; a no-op in the app.
    static func report(_ stats: Stats, bus: String, phrase: Int? = nil, take: Int? = nil) {
        guard LofiCaptureHooks.isEnabled else { return }
        LofiCaptureHooks.appendReport("stemChains", stats.entry(bus: bus, phrase: phrase, take: take))
    }

    /// Next take index for the report: drum entries already recorded in this capture.
    static func nextReportedTake() -> Int {
        guard LofiCaptureHooks.isEnabled else { return 0 }
        let rows = LofiCaptureHooks.reports["stemChains"] as? [[String: Any]] ?? []
        return rows.filter { $0["bus"] as? String == "drums" }.count
    }

    // MARK: Chains

    /// Drum bus on a whole take, in place: mono lows, HPF, box cut, bus and parallel compression,
    /// tape rounding, air shelf, peak trim.
    @discardableResult
    static func applyDrums(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int,
                           sampleRate: Double, settings: Drums = .standard) -> Stats {
        var stats = Stats()
        guard count > 0 else { return stats }
        (stats.inPeakDb, stats.inRmsDb) = level(left, right, count)
        monoBelow(settings.monoBelowHz, left: left, right: right, count: count, sampleRate: sampleRate)
        var eq = LofiFilterChain(settings.filters, sampleRate: sampleRate)
        eq.process(left: left, right: right, count: count)
        if settings.dynamicsEnabled {
            let parallelL = UnsafeMutablePointer<Float>.allocate(capacity: count)
            let parallelR = UnsafeMutablePointer<Float>.allocate(capacity: count)
            defer { parallelL.deallocate(); parallelR.deallocate() }
            parallelL.update(from: left, count: count)
            parallelR.update(from: right, count: count)
            let reference = referenceDB(left, right, count, sampleRate: sampleRate)
            let bus = compress(left, right, count, settings: settings.bus.settings(
                thresholdDB: reference - settings.bus.thresholdBelowReferenceDB), sampleRate: sampleRate)
            let parallel = compress(parallelL, parallelR, count, settings: settings.parallel.settings(
                thresholdDB: reference - settings.parallel.thresholdBelowReferenceDB), sampleRate: sampleRate)
            blend(left, parallelL, count, mix: settings.parallelMix)
            blend(right, parallelR, count, mix: settings.parallelMix)
            // Rounding sized from the crest left after compression: the drive that brings the
            // take to `targetCrestDB`, bounded at its typical hits to the configured range.
            let hits = dbToGain(referenceDB(left, right, count, sampleRate: sampleRate))
            let rounding = crestRounding(left, right, count, hits: hits, targetCrestDB: settings.targetCrestDB,
                                         range: settings.saturationPeakRoundingDB...max(settings.saturationPeakRoundingDB,
                                                                                         settings.saturationMaxRoundingDB))
            saturate(left, right, count, peakRoundingDB: rounding, at: hits, oversampling: settings.oversampling)
            stats.grMeanDb = bus.meanDB
            stats.grMaxDb = bus.maxDB
            stats.extra = ["thresholdDb": reference - settings.bus.thresholdBelowReferenceDB,
                           "parallelGrMeanDb": parallel.meanDB, "parallelGrMaxDb": parallel.maxDB,
                           "saturationRoundingDb": rounding, "crestDb": crestDB(left, right, count)]
        }
        var air = LofiFilterChain(settings.air, sampleRate: sampleRate)
        air.process(left: left, right: right, count: count)
        if settings.dynamicsEnabled {
            let peak = max(peakLinear(left, count), peakLinear(right, count))
            let ceiling = dbToGain(settings.peakCeilingDB)
            var trim: Float = peak > ceiling ? ceiling / peak : 1
            vDSP_vsmul(left, 1, &trim, left, 1, vDSP_Length(count))
            vDSP_vsmul(right, 1, &trim, right, 1, vDSP_Length(count))
            stats.extra["trimDb"] = gainToDB(trim)
        }
        (stats.outPeakDb, stats.outRmsDb) = level(left, right, count)
        return stats
    }

    /// Dry lead of one phrase plus its tail, in place. `accent` (the revealed notes' extra level,
    /// kept apart until the phrase gain is measured) gets the same filters and the same gain
    /// trajectory, so compression never flattens a deliberate accent.
    @discardableResult
    static func applyLead(left: inout [Float], right: inout [Float],
                          accent: inout (left: [Float], right: [Float])?, sampleRate: Double,
                          settings: Lead = .standard) -> Stats {
        var stats = Stats()
        let count = min(left.count, right.count)
        guard count > 0 else { return stats }
        (stats.inPeakDb, stats.inRmsDb) = level(left, right)
        var eq = LofiFilterChain(settings.filters, sampleRate: sampleRate)
        eq.process(left: &left, right: &right)
        if var extra = accent {
            var accentEQ = LofiFilterChain(settings.filters, sampleRate: sampleRate)
            accentEQ.process(left: &extra.left, right: &extra.right)
            accent = extra
        }
        if settings.dynamicsEnabled {
            let reference = left.withUnsafeBufferPointer { l in
                right.withUnsafeBufferPointer { r in referenceDB(l.baseAddress!, r.baseAddress!, count, sampleRate: sampleRate) }
            }
            let curve = left.withUnsafeBufferPointer { l in
                right.withUnsafeBufferPointer { r in
                    gainCurve(l.baseAddress!, r.baseAddress!, count, settings: settings.compressor.settings(
                        thresholdDB: reference - settings.compressor.thresholdBelowReferenceDB), sampleRate: sampleRate)
                }
            }
            multiply(&left, curve.gain)
            multiply(&right, curve.gain)
            if var extra = accent {
                multiply(&extra.left, curve.gain)
                multiply(&extra.right, curve.gain)
                accent = extra
            }
            stats.grMeanDb = curve.meanDB
            stats.grMaxDb = curve.maxDB
        }
        (stats.outPeakDb, stats.outRmsDb) = level(left, right)
        return stats
    }

    /// Effect returns of one phrase plus its tail, in place: filters only. The tail carried into
    /// the next phrase is cut from this output and is never filtered again.
    @discardableResult
    static func applySpace(left: inout [Float], right: inout [Float], sampleRate: Double,
                           settings: Space = .standard) -> Stats {
        var stats = Stats()
        guard !left.isEmpty else { return stats }
        (stats.inPeakDb, stats.inRmsDb) = level(left, right)
        var eq = LofiFilterChain(settings.filters, sampleRate: sampleRate)
        eq.process(left: &left, right: &right)
        (stats.outPeakDb, stats.outRmsDb) = level(left, right)
        return stats
    }

    /// The space duck: a linear gain per frame keyed by the dry lead. The depth is the level term
    /// (the lead's envelope against its strong-note reference over `duckKneeDB`) times the onset
    /// term (`duckSustainShare` during a sustain, full just after a note onset). It reaches full
    /// depth only on strong onsets, eases during sustains and releases fully between lead phrases.
    /// Scale invariant, so the dry stem at any fader gives the same curve.
    ///
    /// `onsets` (frames of the scored lead notes) key the onset term. Without them a block peak
    /// `duckOnsetJumpDB` over the envelope counts as an onset; that detector misses the gradual attacks of
    /// the sampled leads (32-frame blocks), so the renderer always passes the score.
    static func spaceDuck(leadLeft: UnsafePointer<Float>, leadRight: UnsafePointer<Float>, count: Int,
                          sampleRate: Double, onsets: [Int]? = nil,
                          settings: Space = .standard) -> (gain: [Float], meanDB: Float, maxDB: Float) {
        guard count > 0 else { return ([], 0, 0) }
        let onsetBlocks = onsets.map { Set($0.filter { (0..<count).contains($0) }.map { $0 / blockFrames }) }
        let reference = referenceDB(leadLeft, leadRight, count, sampleRate: sampleRate)
        let detector = blockPeaks(leadLeft, leadRight, count)
        let attack = blockCoefficient(settings.duckAttack, sampleRate: sampleRate)
        let release = blockCoefficient(settings.duckRelease, sampleRate: sampleRate)
        let onsetDecay = blockCoefficient(settings.duckOnsetDecay, sampleRate: sampleRate)
        let holdBlocks = Int((settings.duckHold * sampleRate / Double(blockFrames)).rounded())
        let onsetHoldBlocks = Int((settings.duckOnsetHold * sampleRate / Double(blockFrames)).rounded())
        let jump = dbToGain(settings.duckOnsetJumpDB)
        let knee = max(0.1, settings.duckKneeDB)
        let floor = dbToGain(reference - knee)
        let share = min(1, max(0, settings.duckSustainShare))
        var envelope: Float = 0, onset: Float = 0, depth: Float = 0
        var held = 0, onsetHeld = 0
        var depths = [Float](repeating: 0, count: detector.count)
        guard reference > -100 else { return ramp(depths, count: count) }
        for (k, peak) in detector.enumerated() {
            let isOnset = onsetBlocks.map { $0.contains(k) } ?? (peak > envelope * jump && peak > floor)
            if isOnset {
                onset = 1
                onsetHeld = onsetHoldBlocks
            } else if onsetHeld > 0 {
                onsetHeld -= 1
            } else {
                onset *= onsetDecay
            }
            if peak > envelope {
                envelope = peak + attack * (envelope - peak)
                held = holdBlocks
            } else if held > 0 {
                held -= 1
            } else {
                envelope = peak + release * (envelope - peak)
            }
            let over = 20 * log10f(max(envelope, 1e-9)) - (reference - knee)
            let target = settings.duckDepthDB * min(1, max(0, over / knee)) * (share + (1 - share) * onset)
            // The onset opens the depth over the attack time rather than in one block.
            depth = target > depth ? target + attack * (depth - target) : target
            depths[k] = depth
        }
        return ramp(depths, count: count)
    }

    // MARK: Building blocks

    /// Peak and RMS of a stereo pair in dBFS.
    static func level(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, _ count: Int) -> (peak: Float, rms: Float) {
        guard count > 0 else { return (-120, -120) }
        let peak = max(peakLinear(left, count), peakLinear(right, count))
        var l: Float = 0, r: Float = 0
        vDSP_measqv(left, 1, &l, vDSP_Length(count))
        vDSP_measqv(right, 1, &r, vDSP_Length(count))
        return (gainToDB(peak), 10 * log10f(max(0.5 * (l + r), 1e-12)))
    }

    static func level(_ left: [Float], _ right: [Float]) -> (peak: Float, rms: Float) {
        let count = min(left.count, right.count)
        return left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in level(l.baseAddress!, r.baseAddress!, count) }
        }
    }

    /// Sample peak over RMS of a stereo pair, dB.
    static func crestDB(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, _ count: Int) -> Float {
        let (peak, rms) = level(left, right, count)
        return peak - rms
    }

    static func peakLinear(_ x: UnsafePointer<Float>, _ count: Int) -> Float {
        guard count > 0 else { return 0 }
        var peak: Float = 0
        vDSP_maxmgv(x, 1, &peak, vDSP_Length(count))
        return peak.isFinite ? peak : 0
    }

    /// 95th percentile of linked 10 ms peak levels over the windows with signal.
    static func referenceDB(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, _ count: Int,
                            sampleRate: Double, percentile: Double = 0.95) -> Float {
        let window = max(1, Int(sampleRate * 0.010))
        var peaks: [Float] = []
        peaks.reserveCapacity(count / window + 1)
        var start = 0
        while start < count {
            let n = min(window, count - start)
            peaks.append(max(peakLinear(left + start, n), peakLinear(right + start, n)))
            start += n
        }
        // The gate is relative (60 dB under the loudest window), so the reference scales exactly
        // with the signal and a stem at any fader gives the same thresholds.
        let gate = max(1e-9, (peaks.max() ?? 0) * 1e-3)
        var levels = peaks.filter { $0 > gate }.map { 20 * log10f($0) }
        guard !levels.isEmpty else { return -120 }
        levels.sort()
        return levels[min(levels.count - 1, Int(Double(levels.count - 1) * percentile))]
    }

    /// Linked peak per `blockFrames` block.
    static func blockPeaks(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>?, _ count: Int) -> [Float] {
        let blocks = (count + blockFrames - 1) / blockFrames
        var peaks = [Float](repeating: 0, count: blocks)
        for k in 0..<blocks {
            let start = k * blockFrames, n = min(blockFrames, count - start)
            var peak = peakLinear(left + start, n)
            if let right { peak = max(peak, peakLinear(right + start, n)) }
            peaks[k] = peak
        }
        return peaks
    }

    /// One-pole coefficient per block for a time constant.
    static func blockCoefficient(_ seconds: Double, sampleRate: Double) -> Float {
        seconds > 0 ? Float(exp(-Double(blockFrames) / (seconds * sampleRate))) : 0
    }

    /// Per-sample linear gain from per-block reductions in dB, ramping from each block's value to
    /// the next. Returns the gain and the reduction's mean (over non-zero blocks) and maximum.
    static func ramp(_ reductions: [Float], count: Int) -> (gain: [Float], meanDB: Float, maxDB: Float) {
        var gain = [Float](repeating: 1, count: count)
        var previous: Float = 1
        var sum: Double = 0, active = 0
        var peak: Float = 0
        gain.withUnsafeMutableBufferPointer { g in
            for (k, reduction) in reductions.enumerated() {
                let start = k * blockFrames, n = min(blockFrames, count - start)
                guard n > 0 else { break }
                let target = dbToGain(-reduction)
                var first = previous + (target - previous) / Float(n)
                var step = (target - previous) / Float(n)
                vDSP_vramp(&first, &step, g.baseAddress! + start, 1, vDSP_Length(n))
                previous = target
                if reduction > 0.01 { sum += Double(reduction); active += 1 }
                peak = max(peak, reduction)
            }
        }
        return (gain, active > 0 ? Float(sum / Double(active)) : 0, peak)
    }

    /// Block-rate feed-forward compressor gain (soft knee from `LofiCompressor`), linked over both
    /// channels, including makeup.
    static func gainCurve(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>?, _ count: Int,
                          settings: LofiCompressor.Settings, sampleRate: Double) -> (gain: [Float], meanDB: Float, maxDB: Float) {
        let peaks = blockPeaks(left, right, count)
        let attack = blockCoefficient(settings.attack, sampleRate: sampleRate)
        let release = blockCoefficient(settings.release, sampleRate: sampleRate)
        var reduction: Float = 0
        var reductions = [Float](repeating: 0, count: peaks.count)
        for (k, peak) in peaks.enumerated() {
            let target = LofiCompressor.staticReductionDB(levelDB: 20 * log10f(max(peak, 1e-10)),
                                                          thresholdDB: settings.thresholdDB,
                                                          ratio: settings.ratio, kneeDB: settings.kneeDB)
            reduction = target + (target > reduction ? attack : release) * (reduction - target)
            if reduction < 1e-6 { reduction = 0 }
            reductions[k] = reduction
        }
        var curve = ramp(reductions, count: count)
        if settings.makeupDB != 0 {
            var makeup = dbToGain(settings.makeupDB)
            vDSP_vsmul(curve.gain, 1, &makeup, &curve.gain, 1, vDSP_Length(count))
        }
        return curve
    }

    /// Compresses in place (`right` nil for mono) and returns the reduction statistics.
    @discardableResult
    static func compress(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>?, _ count: Int,
                         settings: LofiCompressor.Settings, sampleRate: Double) -> (meanDB: Float, maxDB: Float) {
        guard count > 0 else { return (0, 0) }
        let curve = gainCurve(left, right.map { UnsafePointer($0) }, count, settings: settings, sampleRate: sampleRate)
        curve.gain.withUnsafeBufferPointer { g in
            vDSP_vmul(left, 1, g.baseAddress!, 1, left, 1, vDSP_Length(count))
            if let right { vDSP_vmul(right, 1, g.baseAddress!, 1, right, 1, vDSP_Length(count)) }
        }
        return (curve.meanDB, curve.maxDB)
    }

    /// Mono below `hz` without touching the centre: the side signal (L - R) / 2 is high-passed
    /// (Linkwitz-Riley, 24 dB per octave) and the mid is left exactly as it was. A centred kick
    /// keeps its waveform and attack; only stereo low end is folded away.
    static func monoBelow(_ hz: Double, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                          count: Int, sampleRate: Double) {
        guard count > 0, hz > 0 else { return }
        let side = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let mid = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { side.deallocate(); mid.deallocate() }
        var half: Float = 0.5
        vDSP_vsub(right, 1, left, 1, side, 1, vDSP_Length(count))       // left - right
        vDSP_vsmul(side, 1, &half, side, 1, vDSP_Length(count))
        vDSP_vadd(left, 1, right, 1, mid, 1, vDSP_Length(count))
        vDSP_vsmul(mid, 1, &half, mid, 1, vDSP_Length(count))
        var highpass = LofiFilterChain([.highpass(hz: hz, q: butterworthQ), .highpass(hz: hz, q: butterworthQ)],
                                       sampleRate: sampleRate)
        highpass.process(side, count: count)
        vDSP_vadd(mid, 1, side, 1, left, 1, vDSP_Length(count))
        vDSP_vsub(side, 1, mid, 1, right, 1, vDSP_Length(count))         // mid - side
    }

    /// The tape rounding (dB at `hits`) whose drive brings the crest factor to `targetCrestDB`,
    /// found by bisection on a 1x, every-fourth-sample estimate (the oversampled pass follows).
    static func crestRounding(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, _ count: Int,
                              hits: Float, targetCrestDB: Float, range: ClosedRange<Float>) -> Float {
        let peak = max(peakLinear(left, count), peakLinear(right, count))
        guard peak > 1e-6, hits > 1e-6, count > 8 else { return range.lowerBound }
        let stride = 4, n = count / stride
        let probe = UnsafeMutablePointer<Float>.allocate(capacity: 2 * n)
        let shaped = UnsafeMutablePointer<Float>.allocate(capacity: 2 * n)
        defer { probe.deallocate(); shaped.deallocate() }
        cblas_scopy(Int32(n), left, Int32(stride), probe, 1)
        cblas_scopy(Int32(n), right, Int32(stride), probe + n, 1)
        func crest(_ rounding: Float) -> Float {
            let drive = driveFor(rounding: rounding, at: hits)
            var d = drive, length = Int32(2 * n), meanSquare: Float = 0
            vDSP_vsmul(probe, 1, &d, shaped, 1, vDSP_Length(2 * n))
            vvtanhf(shaped, shaped, &length)
            vDSP_measqv(shaped, 1, &meanSquare, vDSP_Length(2 * n))
            let shapedPeak = tanhf(drive * peak)
            return 20 * log10f(shapedPeak) - 10 * log10f(max(meanSquare, 1e-20))
        }
        if crest(range.lowerBound) <= targetCrestDB { return range.lowerBound }
        if crest(range.upperBound) >= targetCrestDB { return range.upperBound }
        var low = range.lowerBound, high = range.upperBound
        for _ in 0..<10 {
            let mid = 0.5 * (low + high)
            if crest(mid) > targetCrestDB { low = mid } else { high = mid }
        }
        return 0.5 * (low + high)
    }

    /// Drive of `tanh(drive x) / drive` that lowers a sample at `level` by `rounding` dB.
    static func driveFor(rounding: Float, at level: Float) -> Float {
        let target = dbToGain(-rounding)
        var low: Float = 1e-3, high: Float = 20
        for _ in 0..<40 {
            let mid = 0.5 * (low + high)
            if tanhf(mid) / mid > target { low = mid } else { high = mid }
        }
        return 0.5 * (low + high) / max(level, 1e-9)
    }

    /// Tape rounding sized so a sample at `level` (default: the loudest) loses `peakRoundingDB`;
    /// returns the drive used.
    @discardableResult
    static func saturate(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ count: Int,
                         peakRoundingDB: Float, at level: Float? = nil, oversampling: Int) -> Float {
        let peak = level ?? max(peakLinear(left, count), peakLinear(right, count))
        guard peak > 1e-6, peakRoundingDB > 0 else { return 0 }
        let drive = driveFor(rounding: peakRoundingDB, at: peak)
        for channel in [left, right] {
            LofiSaturation.oversampled(channel, count: count, factor: oversampling) { buffer, n in
                var d = drive, inverse = 1 / drive, length = Int32(n)
                vDSP_vsmul(buffer, 1, &d, buffer, 1, vDSP_Length(n))
                vvtanhf(buffer, buffer, &length)
                vDSP_vsmul(buffer, 1, &inverse, buffer, 1, vDSP_Length(n))
            }
        }
        return drive
    }

    /// dry = (1 - mix) dry + mix wet
    private static func blend(_ dry: UnsafeMutablePointer<Float>, _ wet: UnsafePointer<Float>, _ count: Int, mix: Float) {
        var keep = 1 - mix, add = mix
        vDSP_vsmsma(dry, 1, &keep, wet, 1, &add, dry, 1, vDSP_Length(count))
    }

    static func multiply(_ x: inout [Float], _ gain: [Float]) {
        let n = min(x.count, gain.count)
        guard n > 0 else { return }
        vDSP_vmul(x, 1, gain, 1, &x, 1, vDSP_Length(n))
    }

    static func gainToDB(_ gain: Float) -> Float { 20 * log10f(max(gain, 1e-6)) }
}
