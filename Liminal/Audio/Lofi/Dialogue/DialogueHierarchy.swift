import Accelerate
import Foundation

/// A recognised word mapped to source frames and accepted by the hallucination guards.
nonisolated struct DialogueWordSpan: Sendable, Equatable {
    /// Index into `DialogueTranscript.words`.
    let index: Int
    let text: String
    let frames: Range<Int>
    let confidence: Float?
}

/// Utterance, phrase, word group, stab and texture units with refined boundaries (plan 4.3, 7).
nonisolated enum DialogueHierarchy {
    struct Build: Sendable {
        var units: [SpeechUnit]
        var rejections: [DialogueRejection]
    }

    struct Refinement: Sendable {
        let units: [SpeechUnit]
        let words: [DialogueWordSpan]
        let rejections: [DialogueRejection]
        /// Transcript word index and the reason it was dropped.
        let dropped: [Int: String]
        var transcribedUnits: [Int] { units.filter { $0.text != nil }.map(\.id) }
    }

    static func build(_ f: DialogueFeatures, samples: UnsafePointer<Float>, count: Int,
                      speech: [LofiSpeechFocus.Window]) -> Build {
        var builder = Builder(f: f, samples: samples, count: min(count, f.frameCount), speech: speech)
        builder.run()
        return Build(units: builder.units, rejections: builder.rejections)
    }

    /// Adds transcript text, protected spans and word groups to an acoustic hierarchy.
    static func refine(_ analysis: DialogueAnalysis, transcript: DialogueTranscript) -> Refinement {
        guard let f = analysis.features else {
            return Refinement(units: analysis.units, words: [], rejections: analysis.rejections, dropped: [:])
        }
        let (words, dropped) = acceptedWords(transcript, analysis: analysis)
        var units = analysis.units
        var rejections = analysis.rejections
        guard !words.isEmpty else {
            return Refinement(units: units, words: [], rejections: rejections, dropped: dropped)
        }
        // Text and coverage per unit.
        for i in units.indices where units[i].level != .texture {
            apply(words, to: &units[i], f: f)
        }
        // A transcript that transcribes nothing (low confidence, poor coverage) changes nothing.
        guard units.contains(where: { $0.text != nil }) else {
            return Refinement(units: analysis.units, words: words, rejections: rejections, dropped: dropped)
        }
        // Protected spans from the tagger. A unit whose edge falls inside one cannot be played.
        let spans = DialogueReorderGuard.protectedSpans(words).map { r in
            words[r.lowerBound].frames.lowerBound..<words[r.upperBound - 1].frames.upperBound
        }
        var rejected = Set(rejections.map(\.unit))
        for i in units.indices {
            let frames = units[i].frames
            let overlapping = spans.filter { $0.overlaps(frames) }
            units[i].protectedSpans += overlapping.map { max($0.lowerBound, frames.lowerBound)..<min($0.upperBound, frames.upperBound) }
            let cuts = overlapping.contains { cutsInside($0, frames, f: f) }
            if cuts, !rejected.contains(units[i].id) {
                rejections.append(DialogueRejection(unit: units[i].id, reason: .protectedCut))
                rejected.insert(units[i].id)
            }
        }
        var builder = Builder(f: f, samples: nil, count: f.frameCount, speech: analysis.speech)
        builder.units = units
        builder.rejections = rejections
        // Line edges on word boundaries (D130). A transcribed line-level unit whose edge sits inside a
        // word's core is added again on whole words (the words it holds, edges refined around them as
        // word groups are), and a `protectedCut` unit is added again covering the protected span it cut
        // ("the UFO phenomena,", "that marijuana will"), instead of being lost. Before, 65 of 159 salient
        // words on the cached films sat only in rejected units, and line edges cut words.
        let tolerance = f.frames(seconds: DialogueTuning.lineWordEdgeSeconds)
        func inside(_ x: Int) -> Int? {
            words.indices.first { words[$0].frames.lowerBound + tolerance < x && x < words[$0].frames.upperBound - tolerance }
        }
        let reasons = Dictionary(rejections.map { ($0.unit, $0.reason) }, uniquingKeysWith: { a, _ in a })
        for unit in units where [.utterance, .phrase, .wordGroup].contains(unit.level) && unit.text != nil {
            guard var tokens = unit.tokenRange, !tokens.isEmpty, tokens.upperBound <= words.count else { continue }
            let reason = reasons[unit.id]
            let protectedCut = reason == .protectedCut
            guard reason == nil || protectedCut || reason == .uncertainBoundaries else { continue }
            let startIn = inside(unit.frames.lowerBound), endIn = inside(unit.frames.upperBound)
            guard protectedCut || startIn != nil || endIn != nil else { continue }
            if protectedCut {
                for span in spans where span.overlaps(unit.frames) && cutsInside(span, unit.frames, f: f) {
                    let covered = words.indices.filter { words[$0].frames.overlaps(span) }
                    if let a = covered.first, let b = covered.last { tokens = min(a, tokens.lowerBound)..<max(b + 1, tokens.upperBound) }
                }
            }
            var added = builder.addAligned(unit.level, parent: unit.parentID, words: words, tokens: tokens, spans: spans)
            // Too long or too short with the cut words: without them (pulled back to the word boundary).
            if let id = added, let r = builder.rejection(id), r == .tooLong || r == .tooShort {
                var shrunk = tokens
                if let k = startIn, k == shrunk.lowerBound, shrunk.count > 1 { shrunk = (k + 1)..<shrunk.upperBound }
                if let k = endIn, k == shrunk.upperBound - 1, shrunk.count > 1 { shrunk = shrunk.lowerBound..<k }
                if shrunk != tokens { added = builder.addAligned(unit.level, parent: unit.parentID, words: words, tokens: shrunk, spans: spans) }
            }
            // The word-aligned unit replaces the one that cut a word when it can be played.
            if let id = added, builder.rejection(id) == nil, reason == nil {
                builder.rejections.append(DialogueRejection(unit: unit.id, reason: .protectedCut))
            }
        }
        rejected = Set(builder.rejections.map(\.unit))
        // Word groups: clauses inside transcribed phrases whose edges pass acoustic refinement.
        let phrases = builder.units.filter { $0.level == .phrase && $0.text != nil && !rejected.contains($0.id) }
        for phrase in phrases {
            guard let tokens = phrase.tokenRange else { continue }
            let clauses = DialogueReorderGuard.clauses(Array(words[tokens]), analysis: analysis)
                .map { ($0.lowerBound + tokens.lowerBound)..<($0.upperBound + tokens.lowerBound) }
            guard clauses.count > 1 else { continue }
            for clause in clauses where clause.count >= 2 {
                builder.addWordGroup(parent: phrase, words: words, tokens: clause, spans: spans)
            }
        }
        addSalientLines(&builder, words: words, spans: spans, analysis: analysis)
        builder.linkNeighbours()
        return Refinement(units: builder.units, words: words, rejections: builder.rejections, dropped: dropped)
    }

    /// Salient words become candidate lines (D130 stage 2). A word of weight `salientLineWeight` or more
    /// that no playable line holds (its line was a protected cut, too long, too short or never a unit:
    /// 101 of 159 salient words on the cached films) gets a word-aligned group of its clause: 2 to
    /// `salientLineWords` words around it, at most `salientLineSeconds`, widened over any protected span
    /// it would cut. A one-word clause that spells ("LSD.", "psilocybin") may stand alone.
    private static let negations = DialogueReorderGuard.negations

    private static func addSalientLines(_ builder: inout Builder, words: [DialogueWordSpan], spans: [Range<Int>],
                                        analysis: DialogueAnalysis) {
        let salience = DialogueLineInterest.wordSalience(words)
        let rate = analysis.sampleRate
        let limit = DialogueTuning.salientLineSeconds
        func seconds(_ t: Range<Int>) -> Double { Double(words[t.upperBound - 1].frames.upperBound - words[t.lowerBound].frames.lowerBound) / rate }
        let protected = DialogueReorderGuard.protectedSpans(words)
        let clauses = DialogueReorderGuard.clauses(words, analysis: analysis)
        var added = Set<Range<Int>>()
        for k in words.indices where salience[k].weight >= DialogueTuning.salientLineWeight {
            let mid = (words[k].frames.lowerBound + words[k].frames.upperBound) / 2
            let rejected = Set(builder.rejections.map(\.unit))
            let held = builder.units.contains { u in
                [.utterance, .phrase, .wordGroup].contains(u.level) && !rejected.contains(u.id) && u.frames.contains(mid)
                    && u.score.sound >= DialogueTuning.minimumPadSound && u.seconds(rate) <= DialogueMotifTuning.lineSeconds.upperBound
                    && u.seconds(rate) >= DialogueMotifTuning.relaxedLineSeconds.lowerBound && u.nuclei >= DialogueMotifTuning.lineMinimumNuclei
            }
            guard !held, let clause = clauses.first(where: { $0.contains(k) }) else { continue }
            // Up to `salientLineWords` words, the salient word last when the clause allows it (the stress
            // falls late: "a large dose of LSD"), then the following words.
            var lo = max(clause.lowerBound, k - (DialogueTuning.salientLineWords - 1)), hi = k + 1
            while hi < clause.upperBound, hi - lo < DialogueTuning.salientLineWords, seconds(lo..<(hi + 1)) <= limit { hi += 1 }
            while lo < k, seconds(lo..<hi) > limit { lo += 1 }
            while hi > k + 1, seconds(lo..<hi) > limit { hi -= 1 }
            // Never cut a protected span ("the Food and Drug Administration"): widen over it, within the limits.
            for p in protected where p.overlaps(lo..<hi) && (p.lowerBound < lo || p.upperBound > hi) {
                let w = min(lo, p.lowerBound)..<max(hi, p.upperBound)
                if seconds(w) <= limit, w.count <= DialogueTuning.salientLineWords + 2 { lo = w.lowerBound; hi = w.upperBound }
            }
            var tokens = lo..<hi
            if tokens.count == 1 {
                let x = salience[k]
                // It spells when its nuclei match: one per letter, or two or more syllables.
                let nuclei = builder.f.nuclei.filter { words[k].frames.contains($0.peakFrame) }.count
                let spells = x.kind == .initialism ? (x.letters?.count ?? 0) >= 2 && nuclei == x.letters!.count
                    : x.syllables >= 2 && nuclei >= 2
                if !spells {
                    // A one-syllable word takes its neighbour in the clause ("the trip").
                    if k + 1 < clause.upperBound { tokens = k..<(k + 2) } else if k > clause.lowerBound { tokens = (k - 1)..<(k + 1) } else { continue }
                }
            }
            guard seconds(tokens) <= limit, added.insert(tokens).inserted else { continue }
            guard let id = builder.addAligned(.wordGroup, parent: nil, words: words, tokens: tokens, spans: spans, salient: true) else { continue }
            // Its edges are word boundaries, so a protected span it cuts ("about UFO." out of a name's
            // clause, "the mind" of "Then, the mind explodes.") only starts or ends it mid-phrase; that
            // stays a rejection only when the span holds a negation, whose meaning a cut would change.
            if builder.rejection(id) == .protectedCut {
                let cut = protected.filter { $0.overlaps(tokens) && ($0.lowerBound < tokens.lowerBound || $0.upperBound > tokens.upperBound) }
                let negated = cut.contains { span in span.contains { negations.contains(DialogueLineInterest.normalize(words[$0].text))
                    || DialogueLineInterest.normalize(words[$0].text).hasSuffix("n't") } }
                if !negated { builder.rejections.removeAll { $0.unit == id } }
            }
        }
    }

    /// Maps words through the source clock, snaps edges to energy minima and applies the
    /// rejection rules: duration, zero speech weight, speech rate and repeated 3-grams.
    static func acceptedWords(_ transcript: DialogueTranscript, analysis: DialogueAnalysis)
        -> (words: [DialogueWordSpan], dropped: [Int: String]) {
        guard let f = analysis.features else { return ([], [:]) }
        let rate = analysis.sampleRate
        var dropped: [Int: String] = [:]
        var spans: [DialogueWordSpan] = []
        let normalized = transcript.words.map { $0.text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" } }
        // Hallucination guard: any 3-gram that occurs three times removes every occurrence.
        let n = DialogueTuning.hallucinationGram
        if normalized.count >= n {
            var counts: [String: [Int]] = [:]
            for i in 0...(normalized.count - n) {
                counts[normalized[i..<(i + n)].joined(separator: " "), default: []].append(i)
            }
            for starts in counts.values where starts.count >= DialogueTuning.hallucinationRepeats {
                for s in starts { for i in s..<(s + n) { dropped[i] = "repeatedGram" } }
            }
        }
        for (i, word) in transcript.words.enumerated() where dropped[i] == nil {
            let seconds = (word.end - word.start) / analysis.clock.rate
            guard DialogueTuning.wordSeconds.contains(seconds), word.end > word.start else { dropped[i] = "duration"; continue }
            var start = analysis.clock.frame(sourceSeconds: word.start)
            var end = analysis.clock.frame(sourceSeconds: word.end)
            guard start >= 0, end <= f.frameCount, end > start else { dropped[i] = "outside"; continue }
            guard LofiSpeechFocus.weight(start..<end, rate: rate, windows: analysis.speech) > 0 else {
                dropped[i] = "notSpeech"; continue
            }
            start = snap(start, f: f)
            end = max(start + 1, snap(end, f: f))
            // Recognised words absorb the silence around them (on real footage a word before a
            // pause often runs 0.2 to 0.5 s into it), so each word keeps only its voiced core:
            // otherwise every unit that ends in the pause looks as if it cut the word.
            (start, end) = core(start..<end, f: f)
            spans.append(DialogueWordSpan(index: i, text: word.text, frames: start..<end, confidence: word.confidence))
        }
        // Speech rate above 7 words per second inside an utterance, or overall, is not credible.
        func tooFast(_ group: [DialogueWordSpan]) -> Bool {
            guard group.count >= 3, let first = group.first, let last = group.last else { return false }
            let seconds = Double(last.frames.upperBound - first.frames.lowerBound) / rate
            return Double(group.count) / max(seconds, 1e-3) > DialogueTuning.maximumWordsPerSecond
        }
        var fast = Set<Int>()
        if tooFast(spans) { fast = Set(spans.map(\.index)) }
        for unit in analysis.units where unit.level == .utterance {
            let inside = spans.filter { unit.frames.contains(($0.frames.lowerBound + $0.frames.upperBound) / 2) }
            if tooFast(inside) { fast.formUnion(inside.map(\.index)) }
        }
        for i in fast { dropped[i] = "speechRate" }
        spans.removeAll { fast.contains($0.index) }
        spans.sort { $0.frames.lowerBound < $1.frames.lowerBound }
        // Snapping may make neighbours touch; never overlap.
        for i in spans.indices.dropFirst() where spans[i].frames.lowerBound < spans[i-1].frames.upperBound {
            let cut = spans[i].frames.lowerBound
            let previous = spans[i-1]
            spans[i-1] = DialogueWordSpan(index: previous.index, text: previous.text,
                                          frames: previous.frames.lowerBound..<max(previous.frames.lowerBound + 1, cut),
                                          confidence: previous.confidence)
        }
        return (spans, dropped)
    }

    /// A unit edge lies inside a protected span by more than the tolerance at both span ends.
    static func cutsInside(_ span: Range<Int>, _ frames: Range<Int>, f: DialogueFeatures) -> Bool {
        let tolerance = f.frames(seconds: DialogueTuning.protectedCutToleranceSeconds)
        func inside(_ x: Int) -> Bool { span.lowerBound + tolerance < x && x < span.upperBound - tolerance }
        return inside(frames.lowerBound) || inside(frames.upperBound)
    }

    /// The word without its leading and trailing inactive hops, with a release margin kept at
    /// the end. Unchanged when the word has no active hop.
    private static func core(_ frames: Range<Int>, f: DialogueFeatures) -> (Int, Int) {
        var lo = f.hop(frame: frames.lowerBound), hi = f.hop(frame: max(frames.lowerBound, frames.upperBound - 1))
        while lo < hi, !f.active[lo] { lo += 1 }
        while hi > lo, !f.active[hi] { hi -= 1 }
        guard f.active[lo] else { return (frames.lowerBound, frames.upperBound) }
        let start = max(frames.lowerBound, lo * f.hop)
        let release = f.frames(seconds: DialogueTuning.releaseSeconds)
        let end = min(frames.upperBound, (hi + 1) * f.hop + release)
        return end > start ? (start, end) : (frames.lowerBound, frames.upperBound)
    }

    private static func snap(_ frame: Int, f: DialogueFeatures) -> Int {
        let radius = max(1, Int(DialogueTuning.wordSnapSeconds / DialogueTuning.fineHopSeconds))
        let center = f.fineIndex(frame: frame)
        let lo = max(0, center - radius), hi = min(f.fine.count - 1, center + radius)
        guard hi > lo else { return frame }
        let best = (lo...hi).min { a, b in
            f.fine[a] < f.fine[b] || (f.fine[a] == f.fine[b] && abs(a - center) < abs(b - center))
        } ?? center
        return min(f.frameCount, best * f.fineHop)
    }

    private static func apply(_ words: [DialogueWordSpan], to unit: inout SpeechUnit, f: DialogueFeatures) {
        let inside = words.indices.filter { unit.frames.contains((words[$0].frames.lowerBound + words[$0].frames.upperBound) / 2) }
        guard let first = inside.first, let last = inside.last else { return }
        let lo = f.hop(frame: unit.frames.lowerBound), hi = f.hop(frame: max(unit.frames.lowerBound, unit.frames.upperBound - 1))
        var activeCount = 0, covered = 0
        var w = first
        for h in lo...hi where f.active[h] {
            activeCount += 1
            let center = h * f.hop + f.hop / 2
            while w <= last, words[w].frames.upperBound <= center { w += 1 }
            if w <= last, words[w].frames.contains(center) { covered += 1 }
        }
        let coverage = activeCount > 0 ? Double(covered) / Double(activeCount) : 0
        let confidences = words[first...last].compactMap(\.confidence)
        let confidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Float(confidences.count)
        guard coverage >= DialogueTuning.transcribedCoverage,
              (confidence ?? 1) >= DialogueTuning.transcribedConfidence else { return }
        unit.text = words[first...last].map(\.text).joined(separator: " ")
        unit.tokenRange = first..<(last + 1)
        unit.recognitionConfidence = confidence
    }

    // MARK: - Builder

    private struct Edge {
        var frame: Int
        var fade: Int
        var depth: Float
        var burst: Bool
    }

    private struct Builder {
        let f: DialogueFeatures
        let samples: UnsafePointer<Float>?
        let count: Int
        let speech: [LofiSpeechFocus.Window]
        var units: [SpeechUnit] = []
        var rejections: [DialogueRejection] = []

        /// Flat-top samples before each 1 ms hop (prefix sums), for the clipping share.
        let flatPrefix: [Int]

        init(f: DialogueFeatures, samples: UnsafePointer<Float>?, count: Int, speech: [LofiSpeechFocus.Window]) {
            self.f = f
            self.samples = samples
            self.count = count
            self.speech = speech
            var prefix = [Int](repeating: 0, count: f.fine.count + 1)
            if let x = samples, f.peak >= DialogueTuning.clipMinimumPeak {
                let level = f.peak * DialogueTuning.clipFlatness
                for k in 0..<f.fine.count {
                    var flat = 0
                    let lo = k * f.fineHop, hi = min(count, lo + f.fineHop)
                    var top: Float = 0
                    if hi > lo { vDSP_maxmgv(x + lo, 1, &top, vDSP_Length(hi - lo)) }
                    if top >= level {
                        var run = 0
                        for i in lo..<hi {
                            if abs(x[i]) >= level { run += 1 } else {
                                if run >= DialogueTuning.clipRunSamples { flat += run }
                                run = 0
                            }
                        }
                        if run >= DialogueTuning.clipRunSamples { flat += run }
                    }
                    prefix[k + 1] = prefix[k] + flat
                }
            }
            flatPrefix = prefix
        }

        var rate: Double { f.sampleRate }
        func seconds(_ hops: Range<Int>) -> Double { f.seconds(hops: hops.count) }
        func frames(_ seconds: Double) -> Int { f.frames(seconds: seconds) }

        mutating func run() {
            let regions = self.regions()
            var cores: [Range<Int>] = []
            for region in regions { cores += splitUtterance(region) }
            cores.sort { $0.lowerBound < $1.lowerBound }
            var previousEnd = 0
            for (i, core) in cores.enumerated() {
                let peak = peakDB(core)
                let sharedStart = i > 0 && cores[i-1].upperBound == core.lowerBound
                let sharedEnd = i + 1 < cores.count && cores[i+1].lowerBound == core.upperBound
                let nextLimit = i + 1 < cores.count ? cores[i+1].lowerBound * f.hop : count
                let start: Edge = sharedStart
                    ? Edge(frame: previousEnd, fade: frames(DialogueTuning.gradualFadeInSeconds), depth: valleyDepth(core.lowerBound, peak), burst: false)
                    : refineStart(core: core.lowerBound * f.hop, lower: previousEnd, upper: core.upperBound * f.hop, peak: peak)
                let end: Edge = sharedEnd
                    ? refineCut(core: core.upperBound * f.hop, lower: start.frame + 1, upper: cores[i+1].upperBound * f.hop, peak: peak)
                    : refineEnd(core: core.upperBound * f.hop, lower: max(start.frame + 1, core.upperBound * f.hop), upper: nextLimit, peak: peak)
                guard end.frame > start.frame + 1 else { continue }
                previousEnd = end.frame
                let utterance = add(.utterance, parent: nil, core: core, start: start, end: end, inherited: nil)
                buildPhrases(utterance, core: core)
            }
            linkNeighbours()
        }

        // MARK: Segmentation

        /// Active spans separated by at least 180 ms below `noise + 6 dB`.
        func regions() -> [Range<Int>] {
            let longPause = f.hops(seconds: DialogueTuning.utterancePauseSeconds)
            var result: [Range<Int>] = []
            var start: Int?
            var lastActive = -1
            var quiet = 0
            for h in 0..<f.hops {
                if f.active[h] {
                    if start == nil { start = h }
                    lastActive = h
                    quiet = 0
                } else if let s = start {
                    quiet += 1
                    if quiet >= longPause {
                        result.append(s..<(lastActive + 1))
                        start = nil
                    }
                }
            }
            if let s = start { result.append(s..<(lastActive + 1)) }
            return result.filter { $0.count >= 3 }
        }

        func innerPauses(_ r: Range<Int>) -> [Range<Int>] {
            f.pauses.filter { $0.lowerBound > r.lowerBound && $0.upperBound < r.upperBound }
        }

        func nuclei(_ r: Range<Int>) -> [DialogueNucleus] { f.nuclei.filter { r.contains($0.hop) } }

        /// The lowest intensity valley between two nuclei, preferring the middle 60 percent.
        func valleySplit(_ r: Range<Int>) -> Int? {
            let n = nuclei(r)
            guard n.count >= 2 else { return nil }
            var candidates: [Int] = []
            for (a, b) in zip(n, n.dropFirst()) where b.hop - a.hop >= 2 {
                if let v = ((a.hop + 1)..<b.hop).min(by: { f.intensity[$0] < f.intensity[$1] }) { candidates.append(v) }
            }
            let lo = r.lowerBound + r.count / 5, hi = r.upperBound - r.count / 5
            let middle = candidates.filter { $0 > lo && $0 < hi }
            let pool = middle.isEmpty ? candidates : middle
            // A single deep hop is often a stop closure inside a word ("an|kle"); a valley that stays
            // low for a word gap is a likelier word boundary, so it wins when one exists.
            let gap = f.hops(seconds: DialogueTuning.wordGapSeconds)
            func lowRun(_ v: Int) -> Int {
                let level = f.intensity[v] + DialogueTuning.valleyRunDB
                var a = v, b = v
                while a > r.lowerBound, f.intensity[a - 1] <= level { a -= 1 }
                while b + 1 < r.upperBound, f.intensity[b + 1] <= level { b += 1 }
                return b - a + 1
            }
            let gaps = pool.filter { lowRun($0) >= gap }
            return (gaps.isEmpty ? pool : gaps).min { f.intensity[$0] < f.intensity[$1] }
        }

        func splitUtterance(_ r: Range<Int>) -> [Range<Int>] {
            guard seconds(r) > DialogueTuning.utteranceSeconds.upperBound else { return [r] }
            let pauses = innerPauses(r)
            if let pause = pauses.max(by: { a, b in
                a.count != b.count ? a.count < b.count : (f.intensity[a].min() ?? 0) > (f.intensity[b].min() ?? 0)
            }) {
                return splitUtterance(trim(r.lowerBound..<pause.lowerBound)) + splitUtterance(trim(pause.upperBound..<r.upperBound))
            }
            guard let v = valleySplit(r), v > r.lowerBound, v < r.upperBound else { return [r] }
            return splitUtterance(r.lowerBound..<v) + splitUtterance(v..<r.upperBound)
        }

        func trim(_ r: Range<Int>) -> Range<Int> {
            var lo = r.lowerBound, hi = r.upperBound
            while lo < hi, !f.active[lo] { lo += 1 }
            while hi > lo, !f.active[hi - 1] { hi -= 1 }
            return lo < hi ? lo..<hi : r
        }

        func phraseCores(_ u: Range<Int>) -> [Range<Int>] {
            var segments: [Range<Int>] = []
            var start = u.lowerBound
            for pause in innerPauses(u).sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if pause.lowerBound > start { segments.append(start..<pause.lowerBound) }
                start = pause.upperBound
            }
            if u.upperBound > start { segments.append(start..<u.upperBound) }
            if segments.isEmpty { segments = [u] }
            // Merge short segments with a neighbour. A short fragment after a pause usually opens
            // the next phrase ("Yes,", "In", "and"), so it joins forward unless the following pause
            // is clearly longer. A short last fragment joins backward only across a brief pause;
            // otherwise it stays on its own (too short to play as a phrase, still a stab), so a
            // phrase never ends on the first word of the next sentence (real-footage tuning).
            var kept = Set<Int>()
            while segments.count > 1,
                  let k = segments.indices.filter({
                      seconds(segments[$0]) < DialogueTuning.phraseSeconds.lowerBound && !kept.contains(segments[$0].lowerBound)
                  }).min(by: { segments[$0].count < segments[$1].count }) {
                let left = k > 0 ? seconds(segments[k-1].upperBound..<segments[k].lowerBound) : .infinity
                let right = k + 1 < segments.count ? seconds(segments[k].upperBound..<segments[k+1].lowerBound) : .infinity
                let other: Int
                if right.isFinite, right <= left * DialogueTuning.forwardMergeBias { other = k + 1 }
                else if left.isFinite, right.isFinite || left <= DialogueTuning.trailingMergePauseSeconds { other = k - 1 }
                else if right.isFinite { other = k + 1 }
                else {
                    kept.insert(segments[k].lowerBound)
                    continue
                }
                let merged = min(segments[k].lowerBound, segments[other].lowerBound)..<max(segments[k].upperBound, segments[other].upperBound)
                segments[min(k, other)] = merged
                segments.remove(at: max(k, other))
            }
            func split(_ r: Range<Int>) -> [Range<Int>] {
                guard seconds(r) > DialogueTuning.phraseSeconds.upperBound, let v = valleySplit(r) else { return [r] }
                return split(r.lowerBound..<v) + split(v..<r.upperBound)
            }
            return segments.flatMap(split)
        }

        // MARK: Units

        mutating func buildPhrases(_ utteranceID: Int, core: Range<Int>) {
            let utterance = units[utteranceID]
            let inherited: DialogueRejection.Reason? = rejection(utteranceID).flatMap { reason in
                switch reason {
                case .notSpeech, .tooLong: .notSpeech
                case .tooQuiet, .clipped: reason
                default: nil
                }
            }
            let cores = phraseCores(core)
            var starts: [Edge] = [], ends: [Edge] = []
            let peakAll = peakDB(core)
            for (i, c) in cores.enumerated() {
                if i == 0 {
                    starts.append(Edge(frame: utterance.frames.lowerBound, fade: utterance.fadeIn,
                                       depth: valleyDepth(c.lowerBound, peakAll), burst: utterance.onset == .burst))
                }
                if i + 1 < cores.count {
                    let next = cores[i+1]
                    let peak = max(peakDB(c), peakDB(next))
                    let gapStart = c.upperBound * f.hop, gapEnd = next.lowerBound * f.hop
                    if gapEnd > gapStart {
                        var e = refineEnd(core: gapStart, lower: max(starts[i].frame + 1, gapStart), upper: gapEnd, peak: peak)
                        e.frame = min(max(e.frame, gapStart), gapEnd)
                        var s = refineStart(core: gapEnd, lower: e.frame, upper: min(next.upperBound * f.hop, utterance.frames.upperBound), peak: peak)
                        s.frame = min(max(s.frame, e.frame), gapEnd)
                        ends.append(e)
                        starts.append(s)
                    } else {
                        let cut = refineCut(core: gapStart, lower: starts[i].frame + 1,
                                            upper: min(next.upperBound * f.hop, utterance.frames.upperBound) - 1, peak: peak)
                        ends.append(cut)
                        starts.append(cut)
                    }
                } else {
                    ends.append(Edge(frame: utterance.frames.upperBound, fade: utterance.fadeOut,
                                     depth: valleyDepth(c.upperBound, peakAll), burst: false))
                }
            }
            for (i, c) in cores.enumerated() where ends[i].frame > starts[i].frame + 1 {
                let phrase = add(.phrase, parent: utteranceID, core: c, start: starts[i], end: ends[i], inherited: inherited)
                buildStabs(phrase, core: c, inherited: inherited)
            }
        }

        mutating func buildStabs(_ phraseID: Int, core: Range<Int>, inherited: DialogueRejection.Reason?) {
            let phrase = units[phraseID]
            let n = nuclei(core)
            guard !n.isEmpty else { return }
            func startHop(_ q: Int) -> Int {
                q == 0 ? core.lowerBound : (((n[q-1].hop + 1)...n[q].hop).min { f.intensity[$0] < f.intensity[$1] } ?? n[q].hop)
            }
            func endHop(_ q: Int) -> Int {
                q == n.count - 1 ? core.upperBound : ((n[q].hop..<n[q+1].hop).min { f.intensity[$0] < f.intensity[$1] } ?? n[q].hop + 1)
            }
            let limit = phrase.frames
            for q in n.indices {
                for width in 1...DialogueTuning.stabMaximumNuclei where q + width <= n.count {
                    let last = q + width - 1
                    if width == 2, f.seconds(hops: n[last].hop - n[q].hop) > DialogueTuning.stabPairSeconds { continue }
                    let a = startHop(q), b = endHop(last)
                    guard b > a else { continue }
                    let peak = peakDB(a..<b)
                    let start = q == 0
                        ? Edge(frame: limit.lowerBound, fade: phrase.fadeIn, depth: valleyDepth(a, peak), burst: phrase.onset == .burst)
                        : refineStart(core: a * f.hop, lower: limit.lowerBound, upper: limit.upperBound, peak: peak)
                    let end = last == n.count - 1
                        ? Edge(frame: limit.upperBound, fade: phrase.fadeOut, depth: valleyDepth(b, peak), burst: false)
                        : refineEnd(core: b * f.hop, lower: start.frame + 1, upper: limit.upperBound, peak: peak)
                    guard end.frame > start.frame + 1 else { continue }
                    let stab = add(.stab, parent: phraseID, core: a..<b, start: start, end: end, inherited: inherited)
                    if width == 1 { addTexture(parent: stab, nucleus: n[q], inherited: inherited) }
                }
            }
        }

        mutating func addTexture(parent: Int, nucleus: DialogueNucleus, inherited: DialogueRejection.Reason?) {
            let stab = units[parent]
            let peakIndex = f.fineIndex(frame: nucleus.peakFrame)
            let level = f.fine[peakIndex] * powf(10, -DialogueTuning.textureCoreDB / 20)
            let lo = f.fineIndex(frame: stab.frames.lowerBound), hi = f.fineIndex(frame: stab.frames.upperBound - 1)
            var a = peakIndex, b = peakIndex
            while a > lo, f.fine[a - 1] >= level { a -= 1 }
            while b < hi, f.fine[b + 1] >= level { b += 1 }
            var start = a * f.fineHop, end = (b + 1) * f.fineHop
            let minimum = frames(DialogueTuning.textureSeconds.lowerBound), maximum = frames(DialogueTuning.textureSeconds.upperBound)
            if end - start < minimum {
                let grow = (minimum - (end - start) + 1) / 2
                start -= grow
                end += grow
            }
            if end - start > maximum {
                let center = nucleus.peakFrame
                start = center - maximum / 2
                end = start + maximum
            }
            start = max(start, stab.frames.lowerBound)
            end = min(end, stab.frames.upperBound)
            guard end - start >= frames(0.03) else { return }
            let fade = frames(0.005)
            let hops = f.hop(frame: start)..<max(f.hop(frame: start) + 1, f.hop(frame: end))
            _ = add(.texture, parent: parent, core: hops,
                    start: Edge(frame: start, fade: fade, depth: DialogueTuning.boundaryHighDepthDB, burst: false),
                    end: Edge(frame: end, fade: fade, depth: DialogueTuning.boundaryHighDepthDB, burst: false),
                    inherited: inherited)
        }

        /// A unit of `level` on the whole words `tokens` (D130): its edges refined around the first word's
        /// start and the last word's end, never past the neighbouring words. Nil when nothing is left.
        @discardableResult
        mutating func addAligned(_ level: SpeechUnit.Level, parent: Int?, words: [DialogueWordSpan], tokens: Range<Int>,
                                 spans: [Range<Int>], salient: Bool = false) -> Int? {
            guard !tokens.isEmpty, tokens.lowerBound >= 0, tokens.upperBound <= words.count else { return nil }
            let first = words[tokens.lowerBound].frames.lowerBound, last = words[tokens.upperBound - 1].frames.upperBound
            let lower = tokens.lowerBound > 0 ? min(first, words[tokens.lowerBound - 1].frames.upperBound) : 0
            let upper = tokens.upperBound < words.count ? max(last + 1, words[tokens.upperBound].frames.lowerBound) : count
            let core = f.hop(frame: first)..<max(f.hop(frame: first) + 1, f.hop(frame: last))
            let peak = peakDB(core)
            let start = refineStart(core: first, lower: lower, upper: last, peak: peak)
            let end = refineEnd(core: last, lower: max(start.frame + 1, last - 1), upper: upper, peak: peak)
            guard end.frame > start.frame + 1 else { return nil }
            let id = add(level, parent: parent, core: core, start: start, end: end, inherited: nil)
            // A salient word's group sits on whole words, so its edges are word boundaries even where the
            // envelope dips little (co-articulated speech): an uncertain-boundary rejection does not apply.
            if salient, rejection(id) == .uncertainBoundaries { rejections.removeAll { $0.unit == id } }
            // A short salient line ("LSD.") is not too short for a line.
            if salient, rejection(id) == .tooShort, Double(units[id].frames.count) / rate >= DialogueMotifTuning.shortLineSeconds.lowerBound {
                rejections.removeAll { $0.unit == id }
            }
            var unit = units[id]
            unit.text = words[tokens].map(\.text).joined(separator: " ")
            unit.tokenRange = tokens
            let confidences = words[tokens].compactMap(\.confidence)
            unit.recognitionConfidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Float(confidences.count)
            let frames = unit.frames
            let overlapping = spans.filter { $0.overlaps(frames) }
            unit.protectedSpans += overlapping.map { max($0.lowerBound, frames.lowerBound)..<min($0.upperBound, frames.upperBound) }
            units[id] = unit
            let cuts = overlapping.contains { DialogueHierarchy.cutsInside($0, frames, f: f) }
            if cuts, rejection(id) == nil { rejections.append(DialogueRejection(unit: id, reason: .protectedCut)) }
            return id
        }

        mutating func addWordGroup(parent: SpeechUnit, words: [DialogueWordSpan], tokens: Range<Int>, spans: [Range<Int>]) {
            let first = words[tokens.lowerBound].frames.lowerBound, last = words[tokens.upperBound - 1].frames.upperBound
            let core = f.hop(frame: first)..<max(f.hop(frame: first) + 1, f.hop(frame: last))
            let peak = peakDB(core)
            let start = refineStart(core: first, lower: parent.frames.lowerBound, upper: parent.frames.upperBound, peak: peak)
            let end = refineEnd(core: last, lower: start.frame + 1, upper: parent.frames.upperBound, peak: peak)
            guard end.frame > start.frame + 1 else { return }
            let id = add(.wordGroup, parent: parent.id, core: core, start: start, end: end, inherited: nil)
            var unit = units[id]
            unit.text = words[tokens].map(\.text).joined(separator: " ")
            unit.tokenRange = tokens
            let confidences = words[tokens].compactMap(\.confidence)
            unit.recognitionConfidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Float(confidences.count)
            let frames = unit.frames
            let overlapping = spans.filter { $0.overlaps(frames) }
            unit.protectedSpans += overlapping.map { max($0.lowerBound, frames.lowerBound)..<min($0.upperBound, frames.upperBound) }
            units[id] = unit
            let cuts = overlapping.contains { DialogueHierarchy.cutsInside($0, frames, f: f) }
            if cuts, rejection(id) == nil { rejections.append(DialogueRejection(unit: id, reason: .protectedCut)) }
        }

        func rejection(_ id: Int) -> DialogueRejection.Reason? { rejections.last { $0.unit == id }?.reason }

        // MARK: Scoring

        @discardableResult
        mutating func add(_ level: SpeechUnit.Level, parent: Int?, core: Range<Int>, start: Edge, end: Edge,
                          inherited: DialogueRejection.Reason?) -> Int {
            let id = units.count
            let frames = max(0, start.frame)..<min(count, max(start.frame + 2, end.frame))
            let inside = f.nuclei.filter { frames.contains($0.peakFrame) }
            let strongest = inside.sorted { $0.intensityDB > $1.intensityDB }.prefix(DialogueTuning.stressAnchorCount)
            let anchors = strongest.map { min(max($0.onsetFrame, frames.lowerBound), frames.upperBound - 1) }.sorted()
            let duration = Double(frames.count) / rate
            // Band SNR and energy over the core hops.
            let hops = f.hop(frame: frames.lowerBound)...f.hop(frame: frames.upperBound - 1)
            var mean = SIMD3<Float>.zero
            var peakEnergy: Float = 0
            for h in hops {
                mean += f.bands[h]
                peakEnergy = max(peakEnergy, f.energy[h])
            }
            mean /= Float(hops.count)
            let floor = SIMD3<Float>(max(f.floor.x, 1e-10), max(f.floor.y, 1e-10), max(f.floor.z, 1e-10))
            let snr = SIMD3<Float>((0..<3).map { min(60, 10 * log10f(max(mean[$0], 1e-12) / floor[$0])) })
            let speechBand = max(0, mean.x - f.floor.x) + max(0, mean.y - f.floor.y)
            let hiss = mean.z
            let hissFactor = min(1, speechBand / max(1e-12, hiss * 0.65))
            var score = DialogueScore()
            let weight = LofiSpeechFocus.weight(frames, rate: rate, windows: speech)
            score.speech = speech.isEmpty ? 1 : min(1, weight / DialogueTuning.speechWeightScale)
            score.interference = interference(frames)
            score.clarity = min(1, max(0, (max(snr.x, snr.y) - DialogueTuning.tooQuietSNRDB) / 15)) * hissFactor
            let startConfidence = confidence(start.depth), endConfidence = confidence(end.depth)
            let boundary = min(startConfidence, endConfidence)
            let peakFine = f.fine[f.fineIndex(frame: frames.lowerBound)...f.fineIndex(frame: frames.upperBound - 1)].max() ?? 0
            let quietLevel = peakFine * 0.22
            var before = quietShare(before: frames.lowerBound, level: quietLevel)
            var after = quietShare(after: frames.upperBound, level: quietLevel)
            if [.utterance, .phrase, .wordGroup].contains(level) {
                // A line that ends into a real pause usually ends a thought; one followed by speech
                // within a breath usually stops on "and" or "from" (real-footage tuning).
                let context = DialogueTuning.linePauseContextSeconds
                before = 0.5 * before + 0.5 * Float(min(1, quietRun(before: frames.lowerBound, level: quietLevel) / context))
                after = 0.5 * after + 0.5 * Float(min(1, quietRun(after: frames.upperBound, level: quietLevel) / context))
            }
            score.entrance = startConfidence * (0.5 + 0.5 * before)
            score.exit = endConfidence * (0.5 + 0.5 * after)
            if let top = strongest.first {
                let average = inside.map(\.intensityDB).reduce(0, +) / Float(max(1, inside.count))
                score.stress = inside.count > 1 ? min(1, max(0, (top.intensityDB - average) / 6)) : 0.5
            }
            if inside.count >= 3 {
                let intervals = zip(inside, inside.dropFirst()).map { Double($1.onsetFrame - $0.onsetFrame) / rate }
                let m = intervals.reduce(0, +) / Double(intervals.count)
                let sd = sqrt(intervals.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(intervals.count))
                score.accentRegularity = Float(max(0, 1 - sd / max(m, 1e-3)))
            }
            score.roleFit = roleFit(level, duration: duration)
            let clipShare = clipping(frames)
            score.clipping = min(1, clipShare / DialogueTuning.clippedShare)
            score.boundaryUncertainty = 1 - boundary
            let lastPeak = inside.last?.peakFrame ?? frames.lowerBound
            var tailStart = min(max(lastPeak, frames.lowerBound), frames.upperBound - 1)
            let tailLevel = f.fine[f.fineIndex(frame: lastPeak)] * 0.5
            while tailStart < frames.upperBound - 1, f.fine[f.fineIndex(frame: tailStart)] > tailLevel { tailStart += f.fineHop }
            tailStart = min(tailStart, frames.upperBound - 1)
            var protected: [Range<Int>] = []
            if level == .utterance || level == .phrase, let lastOnset = inside.last?.onsetFrame {
                let s = min(max(lastOnset, frames.lowerBound), frames.upperBound - 1)
                protected = [s..<frames.upperBound]
            }
            let unit = SpeechUnit(id: id, parentID: parent, level: level, frames: frames, previousID: nil, nextID: nil,
                                  text: nil, tokenRange: nil, recognitionConfidence: nil, boundaryConfidence: boundary,
                                  speechScore: score.speech, interferenceScore: score.interference, stressAnchors: anchors,
                                  protectedSpans: protected, tail: tailStart..<frames.upperBound, score: score,
                                  fadeIn: min(start.fade, frames.count / 3), fadeOut: min(end.fade, frames.count / 3),
                                  onset: start.burst ? .burst : .gradual, nuclei: inside.count, bandSNR: snr,
                                  peakEnergy: peakEnergy)
            units.append(unit)
            // At most one rejection per unit, in a fixed order.
            let reason: DialogueRejection.Reason? = {
                if let inherited { return inherited }
                if weight <= 0 { return .notSpeech }
                if inside.isEmpty, level != .wordGroup { return .notSpeech }
                if level == .utterance {
                    let rate = Double(inside.count) / max(duration, 1e-3)
                    if duration > DialogueTuning.utteranceSeconds.upperBound { return .tooLong }
                    if duration < DialogueTuning.utteranceSeconds.lowerBound { return .tooShort }
                    if inside.count < DialogueTuning.utteranceMinimumNuclei || !DialogueTuning.utteranceSyllableRate.contains(rate) {
                        return .notSpeech
                    }
                    // Speech dips deeply between syllables; sustained or choral voices do not.
                    if syllableDip(inside) < DialogueTuning.syllableDipDB { return .notSpeech }
                }
                let range: ClosedRange<Double>? = switch level {
                case .utterance: DialogueTuning.utteranceSeconds
                case .phrase: DialogueTuning.phraseSeconds
                case .stab: DialogueTuning.stabSeconds
                case .texture: 0.03...DialogueTuning.textureSeconds.upperBound + 0.01
                case .wordGroup: 0.2...DialogueTuning.phraseSeconds.upperBound
                }
                if let range {
                    if duration < range.lowerBound { return .tooShort }
                    if duration > range.upperBound { return .tooLong }
                }
                if peakEnergy < DialogueTuning.tooQuietEnergy || max(snr.x, snr.y) < DialogueTuning.tooQuietSNRDB { return .tooQuiet }
                if clipShare > DialogueTuning.clippedShare { return .clipped }
                if level != .texture, boundary < DialogueTuning.uncertainBoundary { return .uncertainBoundaries }
                return nil
            }()
            if let reason { rejections.append(DialogueRejection(unit: id, reason: reason)) }
            return id
        }

        mutating func linkNeighbours() {
            for level in SpeechUnit.Level.allCases {
                let ids = units.filter { $0.level == level }
                    .sorted { ($0.frames.lowerBound, $0.frames.upperBound) < ($1.frames.lowerBound, $1.frames.upperBound) }.map(\.id)
                for (k, id) in ids.enumerated() {
                    units[id].previousID = k > 0 ? ids[k - 1] : nil
                    units[id].nextID = k + 1 < ids.count ? ids[k + 1] : nil
                }
            }
        }

        /// Median intensity dip between consecutive nuclei, in dB below the lower peak.
        func syllableDip(_ nuclei: [DialogueNucleus]) -> Float {
            let dips = zip(nuclei, nuclei.dropFirst()).compactMap { a, b -> Float? in
                guard b.hop > a.hop + 1 else { return nil }
                let valley = f.intensity[(a.hop + 1)..<b.hop].min() ?? min(a.intensityDB, b.intensityDB)
                return min(a.intensityDB, b.intensityDB) - valley
            }.sorted()
            return dips.isEmpty ? 0 : dips[dips.count / 2]
        }

        func roleFit(_ level: SpeechUnit.Level, duration: Double) -> Float {
            let (ideal, width): (Double, Double) = switch level {
            case .utterance: (2.6, 1.6)
            case .phrase: (1.4, 0.8)
            case .wordGroup: (1.0, 0.6)
            case .stab: (0.32, 0.15)
            case .texture: (0.10, 0.04)
            }
            let z = (duration - ideal) / width
            return Float(exp(-0.5 * z * z))
        }

        func interference(_ frames: Range<Int>) -> Float {
            let start = Double(frames.lowerBound) / rate, end = Double(frames.upperBound) / rate
            var total = 0.0, value = 0.0
            for w in speech {
                let overlap = min(end, w.range.upperBound) - max(start, w.range.lowerBound)
                guard overlap > 0 else { continue }
                total += overlap
                value += max(w.singing, w.music * 0.82) * overlap
            }
            return total > 0 ? Float(value / total) : 0
        }

        func confidence(_ depth: Float) -> Float {
            let low = DialogueTuning.boundaryLowDepthDB, high = DialogueTuning.boundaryHighDepthDB
            let c = DialogueTuning.boundaryLowConfidence
            if depth <= low { return max(0, c * depth / low) }
            return min(1, c + (1 - c) * (depth - low) / (high - low))
        }

        func quietShare(before frame: Int, level: Float) -> Float {
            let hi = f.fineIndex(frame: frame), lo = max(0, hi - 120)
            guard hi > lo else { return 1 }
            return Float(f.fine[lo..<hi].filter { $0 <= level }.count) / Float(hi - lo)
        }

        func quietShare(after frame: Int, level: Float) -> Float {
            let lo = f.fineIndex(frame: frame), hi = min(f.fine.count, lo + 120)
            guard hi > lo else { return 1 }
            return Float(f.fine[lo..<hi].filter { $0 <= level }.count) / Float(hi - lo)
        }

        /// Seconds the 1 ms envelope stays at or under `level` before `frame`, up to the line context.
        func quietRun(before frame: Int, level: Float) -> Double {
            let limit = Int(DialogueTuning.linePauseContextSeconds / DialogueTuning.fineHopSeconds)
            var k = f.fineIndex(frame: frame) - 1, n = 0
            while k >= 0, n < limit, f.fine[k] <= level { k -= 1; n += 1 }
            // The start of the analysed span counts as silence before it.
            if k < 0 { n = limit }
            return Double(n) * DialogueTuning.fineHopSeconds
        }

        /// Seconds the 1 ms envelope stays at or under `level` after `frame`, up to the line context.
        func quietRun(after frame: Int, level: Float) -> Double {
            let limit = Int(DialogueTuning.linePauseContextSeconds / DialogueTuning.fineHopSeconds)
            var k = f.fineIndex(frame: frame), n = 0
            while k < f.fine.count, n < limit, f.fine[k] <= level { k += 1; n += 1 }
            if k >= f.fine.count { n = limit }
            return Double(n) * DialogueTuning.fineHopSeconds
        }

        /// Share of samples on flat tops near the cue peak, counted only for a hot cue.
        func clipping(_ frames: Range<Int>) -> Float {
            guard frames.count > 0 else { return 0 }
            let lo = min(flatPrefix.count - 1, frames.lowerBound / f.fineHop)
            let hi = min(flatPrefix.count - 1, (frames.upperBound + f.fineHop - 1) / f.fineHop)
            return min(1, Float(flatPrefix[hi] - flatPrefix[lo]) / Float(frames.count))
        }

        func peakDB(_ hops: Range<Int>) -> Float {
            let lo = max(0, min(hops.lowerBound, f.hops - 1)), hi = max(lo + 1, min(hops.upperBound, f.hops))
            return f.intensity[lo..<hi].max() ?? f.noiseDB
        }

        func valleyDepth(_ hop: Int, _ peak: Float) -> Float {
            peak - f.intensity[min(max(0, hop), f.hops - 1)]
        }

        // MARK: Boundary refinement

        func fineMinimum(around frame: Int, lower: Int, upper: Int) -> Int {
            let radius = max(1, Int(DialogueTuning.refineSearchSeconds / DialogueTuning.fineHopSeconds))
            let center = f.fineIndex(frame: frame)
            let lo = max(f.fineIndex(frame: lower), center - radius)
            let hi = min(f.fineIndex(frame: max(lower, upper - 1)), center + radius)
            guard hi >= lo else { return min(max(frame, lower), max(lower, upper - 1)) }
            let best = (lo...hi).min { a, b in
                f.fine[a] < f.fine[b] || (f.fine[a] == f.fine[b] && abs(a - center) < abs(b - center))
            } ?? center
            return min(max(best * f.fineHop, lower), max(lower, upper - 1))
        }

        func zeroCrossing(_ frame: Int, lower: Int, upper: Int) -> Int {
            guard let x = samples else { return frame }
            let radius = frames(DialogueTuning.zeroCrossingSearchSeconds)
            for d in 0...radius {
                for i in [frame - d, frame + d] where i >= max(1, lower) && i < min(count, upper) {
                    if (x[i-1] <= 0) != (x[i] <= 0) || x[i] == 0 { return i }
                }
            }
            return frame
        }

        /// Pre-roll before the onset after the nearest energy minimum (5 to 20 ms before a burst,
        /// 10 to 30 ms before a gradual onset), snapped to a zero crossing.
        func refineStart(core: Int, lower: Int, upper: Int, peak: Float) -> Edge {
            let upper = max(upper, lower + 2)
            let m = fineMinimum(around: core, lower: lower, upper: upper)
            let a = f.fineIndex(frame: m)
            let b = min(f.fine.count - 1, f.fineIndex(frame: upper - 1), a + 80)
            let top = b > a ? (f.fine[a...b].max() ?? 0) : 0
            var t10 = a, t90 = a
            if top > 0 {
                while t10 < b, f.fine[t10] < 0.1 * top { t10 += 1 }
                t90 = t10
                while t90 < b, f.fine[t90] < 0.9 * top { t90 += 1 }
            }
            let burst = Double((t90 - t10) * f.fineHop) / rate < DialogueTuning.burstRiseSeconds
            let pre = frames(burst ? DialogueTuning.burstPrerollSeconds : DialogueTuning.gradualPrerollSeconds)
            var start = max(lower, t10 * f.fineHop - pre)
            start = min(start, upper - 2)
            start = zeroCrossing(start, lower: lower, upper: upper - 1)
            return Edge(frame: start, fade: frames(burst ? DialogueTuning.burstFadeInSeconds : DialogueTuning.gradualFadeInSeconds),
                        depth: peak - f.intensity(frame: m), burst: burst)
        }

        /// The nearest energy minimum plus a 15 ms release, snapped to a zero crossing.
        func refineEnd(core: Int, lower: Int, upper: Int, peak: Float) -> Edge {
            let upper = max(upper, lower + 1)
            let m = fineMinimum(around: core, lower: lower, upper: upper)
            let release = frames(DialogueTuning.releaseSeconds)
            var end = min(upper, max(lower + 1, m + release))
            end = zeroCrossing(end, lower: lower + 1, upper: upper + 1)
            end = min(max(end, lower + 1), upper)
            return Edge(frame: end, fade: release, depth: peak - f.intensity(frame: m), burst: false)
        }

        /// A shared cut between adjacent units with no pause: the energy minimum itself.
        func refineCut(core: Int, lower: Int, upper: Int, peak: Float) -> Edge {
            let upper = max(upper, lower + 1)
            var m = fineMinimum(around: core, lower: lower, upper: upper)
            m = zeroCrossing(m, lower: lower, upper: upper)
            return Edge(frame: min(max(m, lower), upper), fade: frames(DialogueTuning.gradualFadeInSeconds),
                        depth: peak - f.intensity(frame: m), burst: false)
        }
    }
}
