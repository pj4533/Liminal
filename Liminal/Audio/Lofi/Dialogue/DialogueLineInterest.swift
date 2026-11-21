import Foundation

// How interesting a transcribed line is to chop (D124; user direction of 21 November 2026: "the
// cool words ... something that is just interesting rather than just connective words"). Pure,
// on-device and deterministic: the NaturalLanguage tags `DialogueReorderGuard.tag` already computes,
// a stop list and a small lexicon of evocative stems. No network and no model calls. The lexicon is
// taste, a first guess to tune by ear.

/// Word weights and line interest, both in 0...1.
nonisolated enum DialogueLineInterest {
    // MARK: Word lists

    /// Function and connective words weigh nothing (extends `DialogueTuning.functionWords`).
    static let functionWords: Set<String> = DialogueTuning.functionWords.union([
        "am", "being", "these", "those", "here", "us", "me", "his", "its", "when", "where", "why", "how", "not", "no",
        "yes", "can", "could", "would", "should", "will", "shall", "may", "might", "must", "just", "also", "too",
        "about", "up", "out", "over", "some", "any", "all", "one", "ones", "other", "another", "such", "because",
        "while", "whereas", "thus", "however", "therefore", "going", "go", "goes", "went", "gone", "get", "gets",
        "got", "way", "thing", "things", "kind", "sort", "lot", "really", "quite", "i'm", "you're", "we're",
        "they're", "that's", "there's", "here's", "what's", "it'll", "don't", "didn't", "doesn't", "isn't",
        "wasn't", "aren't", "weren't", "can't", "won't", "wouldn't", "couldn't", "shouldn't", "i've", "we've",
        "they've", "you've", "i'd", "you'd", "he'd", "she'd", "we'd", "they'd", "i'll", "you'll", "we'll",
        "they'll", "he's", "she's", "let", "let's", "more", "most", "much", "many", "now", "like", "know",
        "think", "want", "say", "said", "says", "make", "made", "take", "put", "come", "came", "see", "saw",
        "even", "only", "still", "yet", "then", "there", "back", "down", "off", "again", "ever", "each",
        "every", "both", "own", "same", "few", "whom", "whose", "since", "until", "upon", "onto", "through",
        "around", "before", "after", "under", "between", "against", "during", "without", "within", "along",
        "okay", "ok", "yeah", "right", "sure", "maybe", "perhaps", "certainly", "actually", "basically",
        "generally", "usually", "often", "sometimes", "something", "anything", "someone", "anyone", "everyone",
        "people", "person", "part", "case", "fact", "number", "place", "point", "use", "used", "using",
        "well", "far", "very", "rather", "enough", "almost", "least", "less", "able", "being", "become", "became",
        "seem", "seems", "seemed", "mean", "means", "meant", "look", "looks", "looked", "need", "needs",
        "find", "found", "give", "gave", "given", "tell", "told", "ask", "asked", "try", "tried", "keep",
        "kept", "call", "called", "else", "which", "whatever", "whichever", "whoever", "therein", "hereby",
    ])

    /// Sentence-initial words with a comma that are discourse markers, not names or vocatives.
    static let discourseMarkers: Set<String> = [
        "yes", "no", "well", "now", "thus", "later", "so", "oh", "and", "but", "then", "however", "okay", "ok",
        "here", "there", "first", "next", "today", "finally", "meanwhile", "also", "still", "hello", "hi",
        "hey", "why", "look", "listen", "sure", "right", "yeah", "indeed", "instead", "besides", "anyway",
        "again", "otherwise", "naturally", "of", "please", "this", "that", "the", "it", "i", "we", "you", "he",
        "she", "they", "say", "remember", "tonight", "tomorrow", "yesterday", "soon", "once", "since",
    ]

    /// Lexicon categories. An entry ending in `*` matches by prefix; any other matches the whole word
    /// or its plain inflections (`inflections`), unless the category is `exact`.
    struct Category: Sendable {
        let name: String
        let weight: Float
        let exact: Bool
        let entries: [String]
    }

    static let categories: [Category] = [
        Category(name: "drugs", weight: 1.0, exact: false, entries: [
            "lsd", "acid", "drug", "dope", "narcotic*", "marijuana", "reefer", "heroin", "opium", "cocaine",
            "morphine", "mescalin*", "peyote", "psilocyb*", "mushroom", "psychedel*", "hallucin*", "trip",
            "stoned", "addict*", "overdose", "dose", "pill", "needle", "intoxica*", "hypno*", "trance",
            "junkie", "dealer", "smoke", "smoking", "drunk", "whiskey", "liquor", "gin",
        ]),
        Category(name: "mind", weight: 0.9, exact: false, entries: [
            "dream", "dreamt", "nightmare*", "mind", "minds", "brain", "conscious*", "subconscious*", "insan*",
            "madness", "mad", "crazy", "psychic*", "psychiatr*", "psychos*", "schizo*", "delusion*", "vision",
            "memor*", "imagin*", "fantas*", "illusion*", "sleep", "slept", "awake", "soul", "spirit", "ghost",
            "haunt*", "phantom*", "demon", "devil", "angel", "god", "heaven", "hell", "witch", "magic*", "spell",
            "curse", "miracle", "myster*", "secret", "strange*", "weird*", "unknown", "invisib*", "eternal*",
            "eternity", "infinit*", "forever", "nowhere", "void", "shadow", "darkness", "dark", "telepath*",
            "hypnot*", "levitat*", "occult*", "seance", "prophe*", "paradise", "purgatory", "trance",
        ]),
        Category(name: "death", weight: 0.9, exact: false, entries: [
            "death", "dead", "deadly", "die", "died", "dies", "dying", "kill", "murder*", "blood*", "corpse", "grave",
            "funeral", "poison*", "suicid*", "doom*", "terror*", "horror*", "horrib*", "fear", "afraid",
            "scream*", "danger*", "panic*", "monster*", "victim*", "pain", "burn", "burnt", "fire", "flame",
            "explosi*", "explode*", "bomb", "atom", "atomic", "nuclear", "radiat*", "fallout", "hydrogen",
            "destroy*", "destruct*", "disaster*", "catastroph*", "apocalyp*", "war", "enemy", "enemies",
            "weapon", "gun", "bullet", "skull", "coffin", "cemetery", "hang", "hanged", "drown", "strangl*",
        ]),
        Category(name: "space", weight: 0.85, exact: false, entries: [
            "space", "spaceship", "planet", "star", "moon", "sun", "mars", "venus", "saturn", "jupiter",
            "galax*", "universe", "universal", "cosmic", "cosmos", "orbit", "rocket", "satellit*", "astronaut*",
            "saucer", "alien", "martian", "ufo", "gravit*", "comet", "meteor*", "earth", "sky", "skies",
            "future", "tomorrow", "robot*", "machine", "computer*", "electron*", "electric*", "laser", "radar",
            "signal", "transmi*", "frequenc*", "vibrat*", "wave", "energy", "molecul*", "chemical*",
            "experiment*", "laborator*", "scientist*", "science", "formula", "theory", "dimension*", "atomic",
            "television", "radio", "brainwash*", "mutant*", "mutation*", "infinity", "telescope", "microscope",
        ]),
        Category(name: "love", weight: 0.75, exact: false, entries: [
            "love", "lover", "kiss", "heart", "desire", "passion*", "sex", "sexy", "naked", "body", "bodies",
            "flesh", "skin", "beaut*", "darling", "honey", "baby", "mother", "father", "daddy", "mama", "mommy",
            "sister", "brother", "child", "children", "boy", "girl", "woman", "women", "doctor", "professor",
            "captain", "mister", "sir", "lord", "king", "queen", "stranger", "nobody", "everybody", "somebody",
            "sweetheart", "husband", "wife", "bride", "lady", "ladies", "gentlemen", "madam", "kid",
        ]),
        Category(name: "vivid", weight: 0.7, exact: false, entries: [
            "never", "always", "nothing", "everything", "alone", "lost", "free", "freedom", "truth", "lie",
            "lies", "reality", "alive", "life", "world", "money", "gold", "diamond", "crystal", "glass",
            "mirror", "ocean", "sea", "river", "storm", "thunder", "lightning", "rain", "snow", "ice", "desert",
            "jungle", "mountain", "midnight", "night", "morning", "summer", "winter", "music", "rhythm", "song",
            "dance", "color", "colour", "light", "sound", "silence", "voice", "whisper", "city", "illegal",
            "crime", "criminal", "police", "prison", "jail", "guilty", "wild", "savage", "electric", "neon",
            "jazz", "rock", "beat", "groove", "cool", "hot", "speed", "fast", "faster", "flying", "fly",
            "falling", "fall", "fly", "wings", "bird", "animal", "beast", "machine", "power", "revolution",
            "rebel", "danger", "hollywood", "america", "paris", "london", "tokyo", "moscow", "atlantis",
        ]),
        // Imperatives match the exact word only ("listen", not "listens": the user's "Wake up, Tommy!").
        Category(name: "imperative", weight: 0.7, exact: true, entries: [
            "listen", "remember", "forget", "wake", "stop", "run", "hide", "believe", "imagine", "wait",
            "help", "goodbye", "please", "watch", "dance", "relax", "breathe", "jump", "shoot", "move",
            "hurry", "quiet", "silence", "freeze", "behold", "beware", "obey", "surrender",
        ]),
    ]

    /// Inflections a whole-word entry also matches.
    static let inflections = ["s", "es", "'s", "ed", "d", "ing", "er", "ers", "y"]
    /// Inflected forms that are not the stem's sense.
    static let falseFriends: Set<String> = ["minded", "minder", "stared", "staring", "stary", "moony", "ward",
                                            "wary", "warer", "spelling", "spelled", "hanger", "doser", "spacer",
                                            "spacing", "beater", "fired", "sires", "dier", "machiner"]

    static let openStarts: Set<String> = ["and", "but", "or", "so", "whereas", "because", "which", "that", "than",
                                          "of", "to"]
    /// Last words that close a line well even though they are function words.
    static let closingFunctionWords: Set<String> = ["all", "one", "now", "me", "you", "us", "him", "her", "them",
                                                    "it", "there", "here", "not", "no", "yes", "again", "back",
                                                    "down", "off", "out", "up", "too", "ever", "else"]

    static func normalize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{2019}", with: "'").lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
    }

    /// The lexicon weight of a normalized word (0 when it is not in the lexicon).
    static func lexiconWeight(_ w: String) -> Float {
        guard !w.isEmpty, !falseFriends.contains(w) else { return 0 }
        var best: Float = 0
        for category in categories where category.weight > best {
            for entry in category.entries {
                let hit: Bool
                if entry.hasSuffix("*") {
                    hit = w.hasPrefix(entry.dropLast())
                } else if category.exact {
                    hit = w == entry
                } else {
                    hit = w == entry || (w.hasPrefix(entry) && inflections.contains(String(w.dropFirst(entry.count))))
                        || (entry.hasSuffix("e") && w.hasPrefix(entry.dropLast())
                            && ["ing", "ed", "er", "ers"].contains(String(w.dropFirst(entry.count - 1))))
                }
                if hit { best = category.weight; break }
            }
        }
        return best
    }

    // MARK: Word weights

    /// One weight in 0...1 per word: function words 0, other content words 0.25 (0.4 for a long noun,
    /// verb or adjective), numbers 0.5, names and vocatives 0.8, lexicon words their category weight.
    static func wordWeights(_ words: [DialogueWordSpan]) -> [Float] {
        let tagged = DialogueReorderGuard.tag(words)
        return tagged.indices.map { i in weight(tagged, at: i) }
    }

    private static func weight(_ tagged: [DialogueReorderGuard.TaggedWord], at i: Int) -> Float {
        let raw = tagged[i].text
        let t = normalize(raw)
        guard !t.isEmpty else { return 0 }
        let lexicon = lexiconWeight(t)
        if lexicon == 0, functionWords.contains(t) { return 0 }
        var v: Float = max(0.25, lexicon)
        let initial = i == 0 || (tagged[i - 1].text.last.map { ".?!".contains($0) } ?? false)
        let capital = raw.first?.isUppercase == true
        let marker = discourseMarkers.contains(t) || functionWords.contains(t)
        let vocative = initial && capital && raw.hasSuffix(",") && !marker
        if !marker, tagged[i].isName || (capital && !initial && t != "i") || vocative { v = max(v, 0.8) }
        if tagged[i].wordClass == .number || t.allSatisfy(\.isNumber) { v = max(v, 0.5) }
        if t.count >= 8, [.noun, .verb, .adjective].contains(tagged[i].wordClass) { v = max(v, 0.4) }
        return v
    }

    // MARK: Line interest

    /// Interest of one line in 0...1: the best word carries it, the second best and the share of
    /// content words add to it; exclamations, vocative and imperative starts and short phrases score
    /// higher, lines that open on a connective or dangle on a function word lower.
    static func interest(words: ArraySlice<DialogueWordSpan>, weights: ArraySlice<Float>, text: String? = nil) -> Float {
        let w = Array(weights)
        let tokens = words.map { normalize($0.text) }
        let present = tokens.indices.filter { !tokens[$0].isEmpty }
        guard !present.isEmpty, w.count == tokens.count else { return 0 }
        let n = present.count
        let sorted = present.map { w[$0] }.sorted(by: >)
        let peak = sorted[0], second = sorted.count > 1 ? sorted[1] : 0
        let share = Float(present.filter { w[$0] > 0 }.count) / Float(n)
        var s = 0.50 * peak + 0.20 * second + 0.30 * min(1, share / 0.6)
        let firstIndex = present[0], lastIndex = present[present.count - 1]
        let first = tokens[firstIndex], last = tokens[lastIndex]
        let firstRaw = words[words.startIndex + firstIndex].text
        let lastRaw = text ?? words[words.startIndex + lastIndex].text
        if let c = lastRaw.trimmingCharacters(in: .whitespaces).last, "!?".contains(c) { s += 0.08 }
        if firstRaw.hasSuffix(","), w[firstIndex] >= 0.75 { s += 0.10 }
        // An imperative start ("Listen to...", "Wake up,"): a verb that is no function word.
        if n > 1, !functionWords.contains(first),
           DialogueReorderGuard.tag(Array(words[(words.startIndex + firstIndex)...].prefix(3))).first?.wordClass == .verb {
            s += 0.06
        }
        if (2...7).contains(n) { s += 0.05 }
        var shape: Float = 1
        if openStarts.contains(first) { shape *= 0.8 }
        if functionWords.contains(last), !closingFunctionWords.contains(last) { shape *= 0.75 }
        if n > 10 { shape *= 0.9 }
        return min(1, max(0, s * shape))
    }

    /// Interest of a plain text line (tests and tools): words split at spaces.
    static func interest(_ text: String) -> Float {
        let spans = spans(text)
        return interest(words: spans[...], weights: wordWeights(spans)[...], text: text)
    }

    /// Word weights of a plain text line, one per space-separated word.
    static func wordWeights(_ text: String) -> [Float] { wordWeights(spans(text)) }

    private static func spans(_ text: String) -> [DialogueWordSpan] {
        text.split(separator: " ").enumerated().map { i, w in
            DialogueWordSpan(index: i, text: String(w), frames: (i * 100)..<(i * 100 + 90), confidence: nil)
        }
    }
}
