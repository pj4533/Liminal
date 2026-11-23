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
            // D130 stage 2 (user direction of 22 November 2026: "psilocybin" and "DMT" are the chops to want).
            "dmt", "thc", "pcp", "mdma", "lysergic", "ergot", "cannabis", "hashish", "amphetamin*", "barbitur*",
            "ketamine", "ayahuasca", "psychoactive", "tranquiliz*", "tranquilis*", "sedative", "stimulant",
            "methedrine", "benzedrine", "speedball", "psychotomimetic", "entheogen*", "cocaine", "codeine", "nicotine",
        ]),
        // Acronyms a transcript may write in lower case (D130 stage 2); capitalised ones are initialisms anyway.
        Category(name: "acronyms", weight: 0.95, exact: true, entries: [
            "nasa", "cia", "fbi", "ussr", "dna", "esp", "ufo", "ufos", "ibm", "fda", "kgb", "nato",
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
                                            "spacing", "beater", "fired", "sires", "dier", "machiner",
                                            // D130 stage 2 review.
                                            "wares", "stares", "starer", "tripy", "ginned", "ginning", "madder", "sunned",
                                            "gunner", "hanging", "heller", "devilry", "seaing", "acidy", "doping"]

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
    static func lexiconWeight(_ w: String, only: Category? = nil) -> Float {
        guard !w.isEmpty, !falseFriends.contains(w) else { return 0 }
        var best: Float = 0
        for category in categories where category.weight > best && (only == nil || only!.name == category.name) {
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

    // MARK: Word salience (D130 stage 2)

    /// Bumped whenever the lexicon or the weights change, so a stored index of line interests (the
    /// footage salience index) re-scores or drops entries scored by an older version.
    static let lexiconVersion = 2

    /// Initialisms and drug or space acronyms that transcripts may write in lower case.
    static let acronyms: Set<String> = ["lsd", "dmt", "thc", "pcp", "mdma", "ufo", "ufos", "nasa", "cia", "fbi", "ussr", "dna",
                                        "esp", "ibm", "tv", "fda", "kgb", "usa", "nato", "mit", "ucla"]
    /// Capitalised two-letter tokens that are words, not initialisms.
    static let notInitialisms: Set<String> = ["OK", "AM", "PM", "IS", "IT", "IN", "ON", "OF", "TO", "NO", "SO", "GO", "WE", "HE",
                                              "ME", "MY", "BE", "DO", "AN", "AT", "AS", "BY", "IF", "OR", "UP", "US", "OH"]
    static let largeCounts: Set<String> = ["hundred", "hundreds", "thousand", "thousands", "million", "millions", "billion",
                                           "billions", "trillion", "zero", "percent"]

    /// One word's salience: its weight, what makes it salient, its syllables by a text count and, for an
    /// initialism, its letters.
    struct WordSalience: Sendable, Equatable {
        enum Kind: String, Sendable { case function, plain, noun, number, name, lexicon, initialism }
        let weight: Float
        let kind: Kind
        let syllables: Int
        /// The letters an initialism is spelled with ("LSD", "U.F.O." "UFO"; one letter for a token of a
        /// spelled-out run such as "D M T").
        let letters: String?
        /// The lexicon category of a lexicon word ("drugs").
        let category: String?
        /// The tagger's class of the word in its sentence.
        var wordClass: DialogueReorderGuard.WordClass = .other
    }

    /// The letters of an initialism token: 2 to 5 capitals, plain or dotted ("LSD", "U.F.O."), never "I",
    /// "A" or a capitalised short word ("OK").
    static func initialismLetters(_ raw: String) -> String? {
        let letters = raw.filter(\.isLetter)
        guard (2...5).contains(letters.count), letters.allSatisfy({ $0.isUppercase && $0.isASCII }),
              !notInitialisms.contains(String(letters)) || raw.contains("."),
              raw.allSatisfy({ $0.isLetter || ".,!?;:'\u{2019}-".contains($0) }) else { return nil }
        return String(letters)
    }

    /// Token indices that belong to a spelled run of single capital letters ("D M T", "D. M. T."), never a
    /// lone "I" or "A".
    static func spelledRuns(_ raws: [String]) -> Set<Int> {
        func single(_ raw: String) -> Bool {
            let letters = raw.filter(\.isLetter)
            return letters.count == 1 && letters.allSatisfy({ $0.isUppercase && $0.isASCII })
                && raw.allSatisfy({ $0.isLetter || ".,!?;:-".contains($0) })
        }
        var out = Set<Int>()
        var i = 0
        while i < raws.count {
            guard single(raws[i]) else { i += 1; continue }
            var j = i
            // A run stops after a token that ends a sentence or clause with a comma ("I. A man").
            while j < raws.count, single(raws[j]) {
                j += 1
                if let last = raws[j - 1].last, ",;:!?".contains(last) { break }
            }
            let run = raws[i..<j].map { $0.filter(\.isLetter) }
            if run.count >= 2, !run.allSatisfy({ $0 == "I" || $0 == "A" }) { out.formUnion(i..<j) }
            i = j
        }
        return out
    }

    /// A year (1000 to 2099), a large count, zero or a percentage.
    static func isStrikingNumber(_ raw: String, normalized t: String) -> Bool {
        if raw.contains("%") || largeCounts.contains(t) { return true }
        let digits = t.filter(\.isNumber)
        if digits.count == t.count, let n = Int(digits) {
            return (1000...2099).contains(n) || n >= 100 || n == 0
        }
        // "1960s", "50,000"
        if let n = Int(raw.filter(\.isNumber)), raw.contains(where: \.isNumber) { return n >= 1000 || raw.hasSuffix("s") && n >= 10 }
        return false
    }

    /// The salience of each word (D130 stage 2): function words 0, plain words 0.25 (0.4 for a long verb
    /// or adjective), nouns 0.35 (0.45 long), plain numbers 0.5, years, large counts, zero and
    /// percentages 0.65, names and vocatives 0.8 (sentence-initial too when the tagger says name),
    /// lexicon words their category weight, initialisms ("LSD", "U.F.O.", "D M T") 0.95 or their
    /// lexicon weight when higher.
    static func wordSalience(_ words: [DialogueWordSpan]) -> [WordSalience] {
        let tagged = DialogueReorderGuard.tag(words)
        let runs = spelledRuns(tagged.map(\.text))
        return tagged.indices.map { i in
            var x = salience(tagged, at: i, spelled: runs.contains(i))
            x.wordClass = tagged[i].wordClass
            return x
        }
    }

    /// One weight in 0...1 per word: `wordSalience`'s weights.
    static func wordWeights(_ words: [DialogueWordSpan]) -> [Float] { wordSalience(words).map(\.weight) }

    /// The lexicon category of a normalized word, if any.
    static func lexiconCategory(_ w: String) -> Category? {
        let weight = lexiconWeight(w)
        guard weight > 0 else { return nil }
        return categories.first { c in c.weight == weight && lexiconWeight(w, only: c) > 0 }
    }

    private static func salience(_ tagged: [DialogueReorderGuard.TaggedWord], at i: Int, spelled: Bool) -> WordSalience {
        let raw = tagged[i].text
        let t = normalize(raw)
        let syllables = DialogueMotifCutter.textSyllables(raw)
        guard !t.isEmpty else { return WordSalience(weight: 0, kind: .function, syllables: 0, letters: nil, category: nil) }
        let category = lexiconCategory(t)
        let lexicon = category?.weight ?? 0
        let letters = spelled ? String(raw.filter(\.isLetter)) : (initialismLetters(raw) ?? (acronyms.contains(t) ? t.uppercased() : nil))
        if let letters {
            let weight = max(0.95, lexicon)
            return WordSalience(weight: weight, kind: .initialism, syllables: letters.count, letters: letters, category: category?.name)
        }
        if lexicon == 0, functionWords.contains(t) {
            return WordSalience(weight: 0, kind: .function, syllables: syllables, letters: nil, category: nil)
        }
        var v: Float = max(0.25, lexicon)
        var kind: WordSalience.Kind = lexicon > 0 ? .lexicon : .plain
        let initial = i == 0 || (tagged[i - 1].text.last.map { ".?!".contains($0) } ?? false)
        let capital = raw.first?.isUppercase == true
        let marker = discourseMarkers.contains(t) || functionWords.contains(t)
        let vocative = initial && capital && raw.hasSuffix(",") && !marker
        if !marker, tagged[i].isName || (capital && !initial && t != "i") || vocative, v < 0.8 { v = 0.8; kind = .name }
        let number = tagged[i].wordClass == .number || t.allSatisfy(\.isNumber) || largeCounts.contains(t)
        if number {
            let n: Float = isStrikingNumber(raw, normalized: t) ? 0.65 : 0.5
            if v < n { v = n; kind = .number }
        }
        let long = t.count >= 8
        if tagged[i].wordClass == .noun, v < (long ? 0.45 : 0.35) { v = long ? 0.45 : 0.35; kind = .noun }
        if long, [.verb, .adjective].contains(tagged[i].wordClass), v < 0.4 { v = 0.4; kind = .plain }
        return WordSalience(weight: v, kind: kind, syllables: syllables, letters: nil, category: category?.name)
    }

    // MARK: Line interest

    /// Interest of one line in 0...1: the best word carries it, the second best and the share of
    /// content words add to it; exclamations, vocative and imperative starts and short phrases score
    /// higher, lines that open on a connective or dangle on a function word lower.
    static func interest(words: ArraySlice<DialogueWordSpan>, weights: ArraySlice<Float>, text: String? = nil,
                         salience: ArraySlice<WordSalience>? = nil) -> Float {
        let w = Array(weights)
        let tokens = words.map { normalize($0.text) }
        let present = tokens.indices.filter { !tokens[$0].isEmpty }
        guard !present.isEmpty, w.count == tokens.count else { return 0 }
        let n = present.count
        let sorted = present.map { w[$0] }.sorted(by: >)
        let peak = sorted[0], second = sorted.count > 1 ? sorted[1] : 0
        let share = Float(present.filter { w[$0] > 0 }.count) / Float(n)
        // D130 stage 2: the peak word dominates (before 0.50 peak, 0.30 share), so one striking word makes
        // the line striking; an initialism or a drugs word adds a little.
        var s = 0.60 * peak + 0.20 * second + 0.20 * min(1, share / 0.6)
        let raws = words.map(\.text)
        let spelled = spelledRuns(raws)
        func bonus(_ k: Int) -> Bool {
            if let salience, salience.count == w.count {
                let x = salience[salience.startIndex + k]
                return x.kind == .initialism || x.category == "drugs"
            }
            return w[k] > 0 && (spelled.contains(k) || initialismLetters(raws[k]) != nil || acronyms.contains(tokens[k])
                                || lexiconCategory(tokens[k])?.name == "drugs")
        }
        if present.contains(where: bonus) { s += 0.05 }
        let firstIndex = present[0], lastIndex = present[present.count - 1]
        let first = tokens[firstIndex], last = tokens[lastIndex]
        let firstRaw = words[words.startIndex + firstIndex].text
        let lastRaw = text ?? words[words.startIndex + lastIndex].text
        if let c = lastRaw.trimmingCharacters(in: .whitespaces).last, "!?".contains(c) { s += 0.08 }
        if firstRaw.hasSuffix(","), w[firstIndex] >= 0.75 { s += 0.10 }
        // An imperative start ("Listen to...", "Wake up,"): a verb that is no function word (its class tagged
        // in the line's first words, as before D130 stage 2's salience, which is not reused here so a line
        // scores the same in any context).
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
        let salience = wordSalience(spans)
        return interest(words: spans[...], weights: salience.map(\.weight)[...], text: text, salience: salience[...])
    }

    /// Word weights of a plain text line, one per space-separated word.
    static func wordWeights(_ text: String) -> [Float] { wordWeights(spans(text)) }

    /// Word salience of a plain text line, one per space-separated word.
    static func wordSalience(_ text: String) -> [WordSalience] { wordSalience(spans(text)) }

    private static func spans(_ text: String) -> [DialogueWordSpan] {
        text.split(separator: " ").enumerated().map { i, w in
            DialogueWordSpan(index: i, text: String(w), frames: (i * 100)..<(i * 100 + 90), confidence: nil)
        }
    }
}
