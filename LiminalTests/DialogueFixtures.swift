import Accelerate
import AVFoundation
import Foundation
@testable import Liminal

/// Deterministic speech-like audio with ground truth, for the dialogue engine tests.
struct SpeechFixture: @unchecked Sendable {
    struct Word: Sendable { let text: String; let start: Double; let end: Double }
    let buffer: AVAudioPCMBuffer
    let sampleRate: Double
    /// Vowel nuclei, buffer seconds.
    let syllables: [Range<Double>]
    let words: [Word]
    let pauses: [Range<Double>]
    let sentences: [Range<Double>]

    func source(contentID: String = "fixture", cueToken: Int = 1, sourceStart: Double = 0, rate: Double = 1) -> DialogueSource {
        DialogueSource(contentID: contentID, cueToken: cueToken, buffer: buffer, sourceStart: sourceStart, rate: rate)
    }
}

enum DialogueFixtures {
    struct Options {
        var seconds = 30.0
        var sampleRate = 48_000.0
        var seed: UInt64 = 1
        var whisper = false
        /// Music bed amplitude relative to the voice (0 is none).
        var musicBed: Float = 0
        var secondSpeaker = false
        var breaths = true
        var sentences: [String]? = nil
        var commaPause: ClosedRange<Double> = 0.14...0.17
        var sentencePause: ClosedRange<Double> = 0.45...0.70
        var pitch = 1.0
    }

    static let corpus = [
        "when the lights go down, we keep moving.",
        "the old house stood empty for years.",
        "Johnny Carson walked in, the band played on.",
        "we did not stop, the night went on.",
        "listen to the rhythm of the city.",
        "nobody knows where the river goes.",
        "the night was cold, the band played on.",
        "I remember the summer of nineteen fifty.",
        "she runs to the station every morning.",
        "keep your eyes on the road ahead.",
    ]

    // MARK: Speech

    static func speech(_ o: Options = Options()) -> SpeechFixture {
        var voice = Voice(rate: o.sampleRate, seconds: o.seconds, seed: o.seed, whisper: o.whisper, pitch: o.pitch)
        voice.speak(o.sentences ?? corpus, options: o)
        var mix = voice.out
        if o.secondSpeaker {
            var other = Voice(rate: o.sampleRate, seconds: o.seconds, seed: o.seed &+ 99, whisper: false, pitch: 1.6)
            other.time = 0.8
            other.speak(Array((o.sentences ?? corpus).reversed()), options: o)
            for i in mix.indices { mix[i] += 0.6 * other.out[i] }
        }
        if o.musicBed > 0 { addBed(&mix, rate: o.sampleRate, level: o.musicBed * rms(voice.out)) }
        return SpeechFixture(buffer: buffer(normalized(mix), rate: o.sampleRate), sampleRate: o.sampleRate,
                             syllables: voice.syllables, words: voice.words, pauses: voice.pauses, sentences: voice.sentences)
    }

    /// Sustained choral vowels: long legato notes, three voices with vibrato, breath gaps.
    static func sung(seconds: Double = 30, sampleRate: Double = 48_000, seed: UInt64 = 5) -> SpeechFixture {
        let n = Int(seconds * sampleRate)
        var mix = [Float](repeating: 0, count: n)
        var rng = MusicRNG(seed: seed)
        for (v, base) in [220.0, 277.2, 329.6].enumerated() {
            var t = 0.2 + 0.05 * Double(v)
            var phase = 0.0
            var note = 0
            while t < seconds - 1.5 {
                let length = rng.range(1.1...1.6)
                let f0 = base * pow(2, Double(rng.int(-2...2)) / 12)
                let start = Int(t * sampleRate), end = min(n, Int((t + length + 0.1) * sampleRate))
                for i in start..<end {
                    let local = Double(i - start) / sampleRate
                    let vibrato = 1 + 0.015 * sin(2 * .pi * 5.5 * local)
                    phase += f0 * vibrato / sampleRate
                    let attack = min(1, local / 0.15), release = min(1, (Double(end - i) / sampleRate) / 0.15)
                    var s = 0.0
                    for h in 1...8 { s += sin(2 * .pi * phase * Double(h)) * formant(f0 * Double(h), vowel: (700, 1220, 2600)) / Double(h) }
                    mix[i] += Float(s * attack * release * 0.3)
                }
                t += length
                note += 1
                if note % 4 == 0 { t += 0.3 }
            }
        }
        return SpeechFixture(buffer: buffer(normalized(mix), rate: sampleRate), sampleRate: sampleRate,
                             syllables: [], words: [], pauses: [], sentences: [])
    }

    static func silence(seconds: Double = 30, sampleRate: Double = 48_000) -> SpeechFixture {
        SpeechFixture(buffer: buffer([Float](repeating: 0, count: Int(seconds * sampleRate)), rate: sampleRate),
                      sampleRate: sampleRate, syllables: [], words: [], pauses: [], sentences: [])
    }

    static func tone(seconds: Double = 30, hz: Double = 440, sampleRate: Double = 48_000) -> SpeechFixture {
        let n = Int(seconds * sampleRate)
        let x = (0..<n).map { i -> Float in
            Float(sin(2 * .pi * hz * Double(i) / sampleRate) * min(1, Double(i) / (0.05 * sampleRate)))
        }
        return SpeechFixture(buffer: buffer(normalized(x), rate: sampleRate), sampleRate: sampleRate,
                             syllables: [], words: [], pauses: [], sentences: [])
    }

    // MARK: Transport and transcripts

    /// Boom-bap take: kicks on 1 and the "and" of 3, snares on 2 and 4, a few milliseconds of human offset.
    static func snapshot(bpm: Double, origin: Double = 0, phraseAtOrigin: Int = 0, takeIndex: Int = 0,
                         nextBPM: Double? = nil, seed: UInt64 = 3, revision: UInt32 = 1) -> DialogueTransportSnapshot {
        var rng = MusicRNG(seed: seed)
        var kicks: [DialogueLandmark] = [], snares: [DialogueLandmark] = []
        for bar in 0..<16 {
            let b = Double(bar * 4)
            kicks.append(DialogueLandmark(beat: b + rng.range(-0.02...0.02), confidence: 0.92))
            kicks.append(DialogueLandmark(beat: b + 2.5 + rng.range(-0.02...0.02), confidence: 0.85))
            if bar % 2 == 1 { kicks.append(DialogueLandmark(beat: b + 1.75, confidence: 0.3)) }
            snares.append(DialogueLandmark(beat: b + 1 + rng.range(-0.015...0.025), confidence: 0.9))
            snares.append(DialogueLandmark(beat: b + 3 + rng.range(-0.015...0.025), confidence: 0.9))
        }
        return DialogueTransportSnapshot(revision: revision, takeIndex: takeIndex, origin: origin, beatDuration: 60 / bpm,
                                         nextBeatDuration: nextBPM.map { 60 / $0 }, phraseAtOrigin: phraseAtOrigin,
                                         kicks: kicks, snares: snares)
    }

    static func transcript(_ fixture: SpeechFixture, confidence: Float? = 0.9, sourceStart: Double = 0,
                           rate: Double = 1) -> DialogueTranscript {
        DialogueTranscript(locale: "en_US", modelVersion: "fixture-1", words: fixture.words.map {
            DialogueTranscript.Word(text: $0.text, start: sourceStart + $0.start * rate, end: sourceStart + $0.end * rate,
                                    confidence: confidence)
        })
    }

    // MARK: Synthesis

    private struct Voice {
        let rate: Double
        let whisper: Bool
        let pitch: Double
        var rng: MusicRNG
        var out: [Float]
        var time = 0.35
        var syllables: [Range<Double>] = []
        var words: [SpeechFixture.Word] = []
        var pauses: [Range<Double>] = []
        var sentences: [Range<Double>] = []
        var glottal = 0.0

        init(rate: Double, seconds: Double, seed: UInt64, whisper: Bool, pitch: Double) {
            self.rate = rate
            self.whisper = whisper
            self.pitch = pitch
            rng = MusicRNG(seed: seed)
            out = [Float](repeating: 0, count: Int(seconds * rate))
        }

        var seconds: Double { Double(out.count) / rate }

        mutating func speak(_ corpus: [String], options o: Options) {
            var index = 0
            while time < seconds - 3.5 {
                let sentence = corpus[index % corpus.count]
                index += 1
                let tokens = sentence.split(separator: " ").map(String.init)
                let start = time
                for (w, token) in tokens.enumerated() {
                    let wordStart = time
                    let letters = token.lowercased().filter(\.isLetter)
                    let parts = Voice.syllables(letters)
                    for (s, part) in parts.enumerated() {
                        let stressed = s == 0 && letters.count > 3
                        let f0 = pitch * (165 - 50 * Double(w) / Double(max(1, tokens.count - 1))) * (stressed ? 1.12 : 1)
                        syllable(part, f0: f0, stressed: stressed, last: s == parts.count - 1)
                    }
                    words.append(.init(text: token, start: wordStart, end: time))
                    if token.hasSuffix(",") {
                        let gap = rng.range(o.commaPause)
                        pauses.append(time..<(time + gap))
                        time += gap
                    } else if w < tokens.count - 1 {
                        time += rng.range(0.02...0.06)
                    }
                }
                sentences.append(start..<time)
                let gap = rng.range(o.sentencePause)
                if o.breaths, rng.chance(0.4) { noise(at: time + gap * 0.3, length: 0.2, level: 0.03, band: 300...2500) }
                pauses.append(time..<(time + gap))
                time += gap
            }
        }

        /// Vowel clusters as syllables, each with its leading consonants.
        static func syllables(_ word: String) -> [String] {
            let vowels = Set("aeiouy")
            var parts: [String] = []
            var current = ""
            var seenVowel = false
            for c in word {
                if vowels.contains(c) {
                    if seenVowel, let last = current.last, !vowels.contains(last) {
                        parts.append(current)
                        current = ""
                    }
                    seenVowel = true
                }
                current.append(c)
            }
            if !current.isEmpty { if parts.isEmpty || seenVowel { parts.append(current) } else { parts[parts.count - 1] += current } }
            return parts.isEmpty ? [word] : parts
        }

        mutating func syllable(_ part: String, f0: Double, stressed: Bool, last: Bool) {
            let first = part.first ?? "a"
            if "ptkbdgc".contains(first) {
                noise(at: time, length: 0.012, level: 0.35, band: 1500...6000)
                time += 0.03
            } else if "sfhzvjx".contains(first) {
                noise(at: time, length: 0.075, level: 0.12, band: first == "s" ? 4000...9000 : 1200...7000)
                time += 0.07
            }
            let vowel = part.first { "aeiouy".contains($0) } ?? "a"
            let length = stressed ? rng.range(0.17...0.23) : rng.range(0.11...0.17)
            voiced(at: time, length: length, f0: f0, formants: Voice.formants(vowel))
            syllables.append(time..<(time + length))
            time += length
            if last, let end = part.last, "tdsk".contains(end) {
                noise(at: time, length: end == "s" ? 0.06 : 0.015, level: end == "s" ? 0.1 : 0.25, band: 2500...8000)
                time += end == "s" ? 0.06 : 0.025
            }
        }

        static func formants(_ v: Character) -> (Double, Double, Double) {
            switch v {
            case "a": (730, 1090, 2440)
            case "e": (530, 1840, 2480)
            case "i", "y": (300, 2200, 2950)
            case "o": (570, 840, 2410)
            default: (440, 1020, 2240)
            }
        }

        mutating func voiced(at start: Double, length: Double, f0: Double, formants: (Double, Double, Double)) {
            let a = Int(start * rate), count = Int(length * rate), tail = Int(0.03 * rate)
            guard a + count + tail < out.count else { return }
            var excitation = [Float](repeating: 0, count: count + tail)
            for i in 0..<count {
                let t = Double(i) / rate
                let attack = min(1, t / 0.02), release = min(1, (length - t) / 0.04)
                let envelope = Float(max(0, attack * release))
                if whisper {
                    excitation[i] = envelope * (rng.unit() * 2 - 1) * 0.5
                } else {
                    glottal += f0 * (1 + 0.04 * sin(2 * .pi * 3 * t)) / rate
                    glottal -= glottal.rounded(.down)
                    let pulse = glottal < 0.4 ? sin(.pi * glottal / 0.4) : 0
                    excitation[i] = envelope * Float(pulse - 0.25)
                }
            }
            var y = [Float](repeating: 0, count: count + tail)
            for (k, (f, gain)) in [(formants.0, 1.0), (formants.1, 0.55), (formants.2, 0.3)].enumerated() {
                let band = DialogueFixtures.bandpass(excitation, hz: f, q: f / [90.0, 110, 160][k], rate: rate)
                vDSP_vsma(band, 1, [Float(gain)], y, 1, &y, 1, vDSP_Length(y.count))
            }
            for i in 0..<y.count { out[a + i] += 0.9 * y[i] }
        }

        mutating func noise(at start: Double, length: Double, level: Float, band: ClosedRange<Double>) {
            let a = Int(start * rate), count = Int(length * rate)
            guard count > 4, a + count < out.count else { return }
            var x = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let t = Float(i) / Float(count)
                x[i] = (rng.unit() * 2 - 1) * min(1, t * 8) * min(1, (1 - t) * 3)
            }
            let center = sqrt(band.lowerBound * band.upperBound)
            let filtered = DialogueFixtures.bandpass(x, hz: center, q: center / (band.upperBound - band.lowerBound), rate: rate)
            for i in 0..<count { out[a + i] += level * 2 * filtered[i] }
        }
    }

    /// Syllables the synthetic voice speaks for a word (its vowel clusters).
    static func syllablesCount(_ word: String) -> Int { Voice.syllables(word).count }

    static func bandpass(_ x: [Float], hz: Double, q: Double, rate: Double) -> [Float] {
        let w0 = 2 * .pi * min(hz, rate * 0.45) / rate, alpha = sin(w0) / (2 * max(q, 0.3))
        let a0 = 1 + alpha
        var coefficients: [Float] = [Float(alpha / a0), 0, Float(-alpha / a0), Float(-2 * cos(w0) / a0), Float((1 - alpha) / a0)]
        var padded = [Float](repeating: 0, count: x.count + 2)
        for i in x.indices { padded[i + 2] = x[i] }
        var output = [Float](repeating: 0, count: x.count + 2)
        vDSP_deq22(padded, 1, &coefficients, &output, 1, vDSP_Length(x.count))
        return Array(output[2...])
    }

    private static func formant(_ hz: Double, vowel: (Double, Double, Double)) -> Double {
        func peak(_ f: Double, _ bw: Double) -> Double { 1 / (1 + pow((hz - f) / bw, 2)) }
        return peak(vowel.0, 90) + 0.5 * peak(vowel.1, 110) + 0.25 * peak(vowel.2, 160)
    }

    private static func addBed(_ x: inout [Float], rate: Double, level: Float) {
        for i in x.indices {
            let t = Double(i) / rate
            var s = 0.0
            for f in [110.0, 164.8, 220.0, 277.2, 329.6] { s += sin(2 * .pi * f * t) }
            x[i] += level * Float(s / 2.2 * (0.8 + 0.2 * sin(2 * .pi * 0.25 * t)))
        }
    }

    static func rms(_ x: [Float]) -> Float {
        var v: Float = 0
        vDSP_rmsqv(x, 1, &v, vDSP_Length(x.count))
        return v
    }

    /// -26 dBFS RMS, as the archive decoder normalises a cue.
    static func normalized(_ x: [Float]) -> [Float] {
        let level = rms(x)
        guard level > 0 else { return x }
        var gain = powf(10, -26 / 20) / level
        var y = [Float](repeating: 0, count: x.count)
        vDSP_vsmul(x, 1, &gain, &y, 1, vDSP_Length(x.count))
        return y
    }

    static func buffer(_ x: [Float], rate: Double, channels: AVAudioChannelCount = 2) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, x.count)))!
        buffer.frameLength = AVAudioFrameCount(x.count)
        for c in 0..<Int(channels) { x.withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: x.count) } }
        return buffer
    }
}
