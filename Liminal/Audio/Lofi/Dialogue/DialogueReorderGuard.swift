import Foundation
import NaturalLanguage

/// Conservative arrangement of whole transcribed units (plan 7). Part-of-speech tags only
/// protect grammatical spans; they are not a claim of understanding. When no template is
/// proven safe the answer is the source order.
nonisolated enum DialogueReorderGuard {
    enum WordClass: Sendable, Equatable {
        case noun, verb, auxiliary, adjective, adverb, pronoun, determiner, preposition, number
        case conjunction, subordinator, negation, particle, other
    }

    struct TaggedWord: Sendable, Equatable {
        let text: String
        let normalized: String
        let wordClass: WordClass
        let isName: Bool
        let endsClause: Bool
    }

    static let negations: Set<String> = ["not", "no", "never", "nothing", "nobody", "none", "nor", "cannot",
                                         "neither", "nowhere", "without"]
    static let subordinators: Set<String> = ["if", "when", "because", "unless", "although", "though", "while",
                                             "since", "before", "after", "until", "whereas", "whether", "once"]
    static let coordinators: Set<String> = ["and", "but", "or", "so", "yet", "nor", "then"]
    static let anaphora: Set<String> = ["he", "she", "it", "they", "him", "her", "them", "his", "its", "their",
                                        "theirs", "hers", "this", "that", "these", "those", "there", "such"]
    static let auxiliaries: Set<String> = ["be", "am", "is", "are", "was", "were", "been", "being", "do", "does",
                                           "did", "have", "has", "had", "will", "would", "shall", "should", "can",
                                           "could", "may", "might", "must", "'s", "'re", "'ll", "'ve", "'d", "'m"]
    static let pronouns: Set<String> = ["i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us", "them"]
    static let determiners: Set<String> = ["the", "a", "an", "this", "that", "these", "those", "my", "your", "our",
                                           "his", "her", "their", "its", "every", "each", "some", "any", "no"]
    static let numberWords: Set<String> = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                                           "ten", "eleven", "twelve", "twenty", "thirty", "hundred", "thousand", "million"]

    // MARK: Motif pieces

    /// Whether the word pieces of one transcribed motif line may play out of order. Pieces of one
    /// line are rhythmic fragments, so the guard only refuses what changes meaning when moved: a
    /// negation, a number or a contraction with "not" anywhere in the line.
    static func allowsPieceReorder(_ words: [String]) -> Bool {
        let normalized = words.map { $0.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" } }
        return !normalized.contains { w in
            negations.contains(w) || numberWords.contains(w) || w.hasSuffix("n't") || w.allSatisfy(\.isNumber) && !w.isEmpty
        }
    }

    // MARK: Tagging

    static func tag(_ words: [DialogueWordSpan]) -> [TaggedWord] {
        guard !words.isEmpty else { return [] }
        var text = ""
        var ranges: [Range<String.Index>] = []
        for (i, word) in words.enumerated() {
            if i > 0 { text += " " }
            let start = text.endIndex
            text += word.text
            ranges.append(start..<text.endIndex)
        }
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = text
        return words.indices.map { i in
            let raw = words[i].text
            let normalized = raw.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
            let index = ranges[i].lowerBound
            let lexical = tagger.tag(at: index, unit: .word, scheme: .lexicalClass).0
            let name = tagger.tag(at: index, unit: .word, scheme: .nameType).0
            let isName = [NLTag.personalName, .placeName, .organizationName].contains(name)
            let endsClause = raw.last.map { ",.;:!?".contains($0) } ?? false
            return TaggedWord(text: raw, normalized: normalized,
                              wordClass: classify(normalized, lexical: lexical), isName: isName, endsClause: endsClause)
        }
    }

    private static func classify(_ w: String, lexical: NLTag?) -> WordClass {
        if negations.contains(w) || w.hasSuffix("n't") { return .negation }
        if subordinators.contains(w) { return .subordinator }
        if auxiliaries.contains(w) { return .auxiliary }
        if Double(w) != nil || numberWords.contains(w) { return .number }
        switch lexical {
        case .noun?: return .noun
        case .verb?: return .verb
        case .adjective?: return .adjective
        case .adverb?: return .adverb
        case .pronoun?: return .pronoun
        case .determiner?: return .determiner
        case .preposition?: return .preposition
        case .number?: return .number
        case .conjunction?: return coordinators.contains(w) ? .conjunction : .subordinator
        case .particle?: return .particle
        default: break
        }
        if pronouns.contains(w) { return .pronoun }
        if determiners.contains(w) { return .determiner }
        if coordinators.contains(w) { return .conjunction }
        return .other
    }

    // MARK: Spans and clauses

    /// Word-index spans that may never be cut: negation with its predicate, names with their
    /// phrase, determiner with noun, pronoun with verb, number with noun, and uncertain words.
    static func protectedSpans(_ words: [DialogueWordSpan]) -> [Range<Int>] {
        let tagged = tag(words)
        var spans: [Range<Int>] = []
        func through(_ i: Int, limit: Int, _ accept: (WordClass) -> Bool) -> Int? {
            var j = i + 1
            while j < tagged.count, j <= i + limit {
                if accept(tagged[j].wordClass) { return j }
                if tagged[j - 1].endsClause { return nil }
                j += 1
            }
            return nil
        }
        for (i, word) in tagged.enumerated() {
            switch word.wordClass {
            case .negation:
                let end = through(i, limit: 4) { $0 == .verb || $0 == .adjective || $0 == .noun } ?? min(i + 1, tagged.count - 1)
                spans.append(i..<(end + 1))
                if i > 0, tagged[i - 1].wordClass == .auxiliary { spans.append((i - 1)..<(end + 1)) }
            case .determiner:
                if let end = through(i, limit: 4, { $0 == .noun }) { spans.append(i..<(end + 1)) }
            case .pronoun:
                if let end = through(i, limit: 3, { $0 == .verb || $0 == .auxiliary }) { spans.append(i..<(end + 1)) }
            case .number:
                if let end = through(i, limit: 3, { $0 == .noun }) { spans.append(i..<(end + 1)) }
            default: break
            }
            if let c = words[i].confidence, c < DialogueTuning.transcribedConfidence {
                spans.append(max(0, i - 1)..<min(tagged.count, i + 2))
            }
        }
        // Names are protected with their whole clause.
        let clauseRanges = clauses(tagged: tagged, words: words, sampleRate: nil, protecting: [])
        for (i, word) in tagged.enumerated() where word.isName {
            if let clause = clauseRanges.first(where: { $0.contains(i) }) { spans.append(clause) }
        }
        return merge(spans)
    }

    /// Clause ranges (indices into `words`): a boundary needs punctuation or a conjunction,
    /// plus a pause of at least 120 ms, and never falls inside a protected span.
    static func clauses(_ words: [DialogueWordSpan], analysis: DialogueAnalysis) -> [Range<Int>] {
        clauses(tagged: tag(words), words: words, sampleRate: analysis.sampleRate, protecting: nil)
    }

    private static func clauses(tagged: [TaggedWord], words: [DialogueWordSpan], sampleRate: Double?,
                                protecting: [Range<Int>]?) -> [Range<Int>] {
        guard !words.isEmpty else { return [] }
        let spans = protecting ?? protectedSpans(words)
        var result: [Range<Int>] = []
        var start = 0
        for i in 0..<(words.count - 1) {
            let pause = sampleRate.map { Double(words[i + 1].frames.lowerBound - words[i].frames.upperBound) / $0 }
            // A sentence end needs no measured pause: recognised words are often contiguous, and a
            // line must not run on into the next sentence's first word (real-footage tuning).
            let sentenceEnd = tagged[i].text.last.map { ".?!".contains($0) } ?? false
            let paused = sentenceEnd || (pause.map { $0 >= DialogueTuning.clausePauseSeconds } ?? true)
            let marked = tagged[i].endsClause ||
                [.conjunction, .subordinator].contains(tagged[i + 1].wordClass)
            let inside = spans.contains { $0.contains(i) && $0.contains(i + 1) }
            if paused, marked, !inside {
                result.append(start..<(i + 1))
                start = i + 1
            }
        }
        result.append(start..<words.count)
        return result
    }

    private static func merge(_ spans: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for s in spans.filter({ !$0.isEmpty }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, s.lowerBound < last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, s.upperBound)
            } else {
                result.append(s)
            }
        }
        return result
    }

    // MARK: Templates

    static func arrange(transcript: DialogueTranscript?, units: [SpeechUnit], analysis: DialogueAnalysis) -> DialogueReorder {
        guard let transcript else { return .sourceOrder }
        let words = DialogueHierarchy.acceptedWords(transcript, analysis: analysis).words
        return arrange(words: words, units: units, analysis: analysis)
    }

    /// Returns an arrangement of whole transcribed units, or the source order.
    static func arrange(words: [DialogueWordSpan], units: [SpeechUnit], analysis: DialogueAnalysis,
                        excluded: Set<Int> = []) -> DialogueReorder {
        guard words.count >= 2 else { return .sourceOrder }
        let tagged = tag(words)
        let spans = protectedSpans(words)
        let clauseRanges = clauses(tagged: tagged, words: words, sampleRate: analysis.sampleRate, protecting: spans)
        // A clause is usable only as one whole transcribed unit with exactly its words.
        func unit(_ clause: Range<Int>) -> SpeechUnit? {
            units.filter { $0.text != nil && $0.tokenRange == clause && !excluded.contains($0.id) && $0.level != .texture }
                .min { $0.level.rawValue < $1.level.rawValue }
        }
        let clauseUnits = clauseRanges.map(unit)
        func slice(_ r: Range<Int>) -> ArraySlice<TaggedWord> { tagged[r] }
        func hasVerb(_ r: Range<Int>) -> Bool { slice(r).contains { $0.wordClass == .verb || $0.wordClass == .auxiliary } }
        func crossesNegation(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
            let join = a.upperBound
            if spans.contains(where: { $0.lowerBound < join && $0.upperBound > join }) { return true }
            let tail = tagged[max(a.lowerBound, a.upperBound - 2)..<a.upperBound]
            return tail.contains { $0.wordClass == .negation } || tagged[b.lowerBound].wordClass == .negation
        }

        // 1. Exchange two adjacent independent clauses.
        for k in 0..<max(0, clauseRanges.count - 1) {
            let a = clauseRanges[k], b = clauseRanges[k + 1]
            guard let ua = clauseUnits[k], let ub = clauseUnits[k + 1], ua.id != ub.id else { continue }
            let starts = [tagged[a.lowerBound], tagged[b.lowerBound]]
            guard !starts.contains(where: { [.subordinator, .conjunction].contains($0.wordClass) }),
                  !slice(a).contains(where: { anaphora.contains($0.normalized) }),
                  !slice(b).contains(where: { anaphora.contains($0.normalized) }),
                  hasVerb(a), hasVerb(b), !crossesNegation(a, b) else { continue }
            return .arrangement(units: [ub.id, ua.id], template: .exchangeClauses)
        }
        // 2. Move an intact leading or trailing adverbial.
        if clauseRanges.count >= 2 {
            let first = clauseRanges[0], last = clauseRanges[clauseRanges.count - 1]
            func adverbial(_ r: Range<Int>) -> Bool {
                r.count <= 4 && !hasVerb(r) && [.adverb, .preposition].contains(tagged[r.lowerBound].wordClass)
            }
            let rest = clauseUnits.compactMap { $0 }
            if rest.count == clauseRanges.count {
                if adverbial(first), let u = clauseUnits[0] {
                    return .arrangement(units: Array(rest.dropFirst()).map(\.id) + [u.id], template: .moveAdverbial)
                }
                if adverbial(last), let u = clauseUnits.last!, !crossesNegation(clauseRanges[clauseRanges.count - 2], last) {
                    return .arrangement(units: [u.id] + rest.dropLast().map(\.id), template: .moveAdverbial)
                }
            }
        }
        // 3. Omit a short parenthetical bounded by pauses on both sides.
        if clauseRanges.count >= 3, clauseUnits.allSatisfy({ $0 != nil }) {
            for k in 1..<(clauseRanges.count - 1) {
                let r = clauseRanges[k]
                guard r.count <= 4, tagged[r.upperBound - 1].endsClause, tagged[r.lowerBound - 1].endsClause,
                      !slice(r).contains(where: { $0.wordClass == .negation }) else { continue }
                let kept = clauseUnits.enumerated().filter { $0.offset != k }.compactMap { $0.element?.id }
                return .arrangement(units: kept, template: .omitParenthetical)
            }
        }
        // 4. Repeat a whole clause.
        if let u = clauseUnits.compactMap({ $0 }).max(by: { $0.score.sound < $1.score.sound }) {
            return .arrangement(units: [u.id, u.id], template: .repeatClause)
        }
        return .sourceOrder
    }
}
