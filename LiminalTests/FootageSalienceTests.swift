import Foundation
import Testing
@testable import Liminal

struct FootageSalienceTests {
    static func line(_ start: Double = 120, interest: Float = 0.9) -> DialogueSalienceIndex.Line {
        .init(start: start, end: start + 2, interest: interest, peakWord: "DMT", peakWeight: 0.95)
    }

    static func pick(seed: UInt64, lines: [DialogueSalienceIndex.Line], ledger: DialogueLineLedger = DialogueLineLedger(),
                     shown: [Double] = [], duration: Double = 600, sound: Bool = true,
                     preroll: Double = 2, rate: Double = 0.7, delay: Double = 0.75,
                     dialogueLength: Double = 32) -> FootageSalience.Pick? {
        var rng = MusicRNG(seed: seed)
        return FootageSalience.pick(lines: lines, contentID: "film", ledger: ledger, shownStarts: shown,
                                   duration: duration, sourceLength: 48, preroll: preroll, rate: rate,
                                   soundDelay: delay, dialogueLength: dialogueLength, sound: sound, rng: &rng)
    }

    @Test func emptyIndexPreservesTheOriginalClipAndCatalogStream() throws {
        let clips = (0..<5).map { ArchiveCachePolicyTests.clip("film-\($0)", mb: 1, used: Double($0)) }
        for seed: UInt64 in 0..<100 {
            var original = MusicRNG(seed: seed), indexed = MusicRNG(seed: seed)
            let a = try #require(FootageWeaver.chooseClip(clips, avoiding: [], rng: &original))
            let b = try #require(FootageWeaver.chooseClip(clips, avoiding: [], boost: [:], rng: &indexed))
            #expect(a.id == b.id)
            let before = ArchiveCatalog.segmentStart(duration: a.duration, length: 48, avoid: [], rng: &original)
            let after = ArchiveCatalog.segmentStart(duration: b.duration, length: 48, avoid: [], rng: &indexed)
            #expect(Self.pick(seed: seed, lines: []) == nil)
            #expect(before == after && original.next() == indexed.next())
        }
    }

    @Test func soundPicksKeepTheRandomShareAndContainTheCompleteLine() throws {
        var count = 0
        for seed: UInt64 in 0..<1000 {
            guard let picked = Self.pick(seed: seed, lines: [Self.line()]) else { continue }
            count += 1
            let cueStart = picked.segmentStart + 0.75 * 0.7
            #expect((3...10).contains(picked.line.start - cueStart))
            #expect(picked.line.end <= cueStart + 32)
            #expect(picked.segmentStart >= 2 && picked.segmentStart - 2 + 48 <= 600)
        }
        #expect((550...750).contains(count), "salient picks: \(count)/1000")
        for seed: UInt64 in 0..<100 {
            #expect(Self.pick(seed: seed, lines: [Self.line()], sound: false) == nil)
        }
    }

    @Test func ledgerShownStartsAndEdgeClampingCannotLeakAForbiddenLine() {
        let ledger = DialogueLineLedger()
        ledger.record(contentID: "film", seconds: 120..<122)
        for seed: UInt64 in 0..<100 {
            #expect(Self.pick(seed: seed, lines: [Self.line()], ledger: ledger) == nil)
            #expect(Self.pick(seed: seed, lines: [Self.line()], shown: [115]) == nil)
            #expect(Self.pick(seed: seed, lines: [Self.line(1)]) == nil)
            #expect(Self.pick(seed: seed, lines: [Self.line(598)]) == nil)
            // The end, not merely the onset, must fit the dialogue analysis window.
            #expect(Self.pick(seed: seed, lines: [Self.line()], dialogueLength: 4) == nil)
        }
    }

    @Test func feasibleSliverBetweenShownStartsRemainsTargetable() throws {
        // Lead 3...10 gives starts 110...117. Only 114...115 clears both previous starts.
        let lines = [Self.line(120)]
        for seed: UInt64 in 0..<100 {
            var draw = MusicRNG(seed: seed)
            let expected = draw.chance(0.65)
            let pick = Self.pick(seed: seed, lines: lines, shown: [94, 135], preroll: 0, delay: 0)
            #expect((pick != nil) == expected)
            if let pick { #expect((114...115).contains(pick.segmentStart)) }
        }
    }

    @Test func slowedBedAndNativeDialogueUseTheirOwnTimeBases() throws {
        let request = FootageWeaver.Request(index: 0, slot: 0, start: 0, fadeIn: 2, length: 48,
                                            recipe: .plain(.window), seed: 0.1, rate: 0.75,
                                            warp: 0, level: 0.5, swell: 0, sound: true)
        let cue = try #require(ArchiveAudioCuePlan(piece: request.piece(clipID: "film", segmentStart: 60),
                                                   clipDuration: 600))
        #expect(cue.rate == 0.75)
        #expect(ArchiveDialogueSource.containedSeconds(cue) == 32)
        let short = try #require(ArchiveAudioCuePlan(piece: request.piece(clipID: "film", segmentStart: 60, length: 12),
                                                     clipDuration: 600))
        let heard = (short.endAt - short.beginAt) * Double(short.rate)
        #expect(short.sourceLength > heard)
        #expect(ArchiveDialogueSource.containedSeconds(short) == heard)
    }

    @Test func measuringMissedOpportunitiesPreservesTheSelectedPieceAndCatalogStream() throws {
        let clip = ArchiveCachePolicyTests.clip("film", mb: 1, used: nil)
        let index = DialogueSalienceIndex(), ledger = DialogueLineLedger()
        index.record(contentID: clip.id, scanned: 100..<150, lines: [Self.line()])
        var targeted = Set<Bool>()
        for piece in 0..<100 {
            let request = FootageWeaver.Request(index: piece, slot: 0, start: 0, fadeIn: 2, length: 48,
                                                recipe: .plain(.window), seed: 0.1, rate: 0.75,
                                                warp: 0, level: 0.5, swell: 0, sound: true)
            var liveRNG = MusicRNG(seed: UInt64(piece)), measuredRNG = liveRNG
            var liveWeaver = FootageWeaver(seed: 1, timing: .standard), measuredWeaver = liveWeaver
            let live = try #require(FootageSalience.prepare(request, clips: [clip], weaver: &liveWeaver,
                rng: &liveRNG, elapsed: 0, index: index, ledger: ledger))
            let measured = try #require(FootageSalience.prepare(request, clips: [clip], weaver: &measuredWeaver,
                rng: &measuredRNG, elapsed: 0, index: index, ledger: ledger, measureOpportunity: true))
            targeted.insert(live.targeted)
            #expect(measured.measuredFeasible == true)
            #expect(measured.targeted == live.targeted)
            #expect(measured.catalogStart == live.catalogStart)
            #expect(measured.piece == live.piece)
            let nextLive = liveRNG.next(), nextMeasured = measuredRNG.next()
            #expect(nextLive == nextMeasured)
        }
        #expect(targeted == [true, false])
    }

    @Test func sourceDelayUsesThePictureRateAndFillHasNoDelay() {
        for rate in [0.6, 0.85, 1.0] {
            for delay in [0.0, 0.75] {
                for seed: UInt64 in 0..<50 {
                    guard let pick = Self.pick(seed: seed, lines: [Self.line()], preroll: 5, rate: rate, delay: delay) else { continue }
                    let cue = pick.segmentStart + delay * rate
                    #expect((3...10).contains(pick.line.start - cue))
                    #expect(pick.line.end <= cue + 32)
                }
            }
        }
    }

    @Test func topFiveAreWeightedAndBoostNeverExcludesAClip() {
        let lines = (0..<8).map { Self.line(80 + Double($0) * 45, interest: 0.95 - Float($0) * 0.03) }
        var selected = Set<Double>()
        let clips = (0..<8).map { ArchiveCachePolicyTests.clip("film-\($0)", mb: 1, used: Double($0)) }
        var selectedClips = Set<String>()
        var rng = MusicRNG(seed: 11)
        for seed: UInt64 in 0..<3000 {
            if let pick = Self.pick(seed: seed, lines: lines) { selected.insert(pick.line.start) }
            if let clip = FootageWeaver.chooseClip(clips, avoiding: [], boost: ["film-0": 2], rng: &rng) { selectedClips.insert(clip.id) }
        }
        #expect(selected == Set(lines.prefix(5).map(\.start)))
        #expect(selectedClips == Set(clips.map(\.id)))
    }

    @Test func indexLimitsMergesAndPersistsWithLexiconInvalidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("salience-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("DialogueSalience.json")
        let index = DialogueSalienceIndex(url: url)
        index.record(contentID: "film", scanned: 0..<30, lines: (0..<10).map { Self.line(Double($0) * 2.5, interest: 0.5 + Float($0) * 0.04) })
        index.record(contentID: "film", scanned: 25..<55, lines: [Self.line(40, interest: 0.4)])
        #expect(index.entry(contentID: "film").spans == [.init(start: 0, end: 55)])
        #expect(index.entry(contentID: "film").lines.count == 6)
        try index.save()
        let reloaded = DialogueSalienceIndex(url: url)
        #expect(reloaded.entry(contentID: "film") == index.entry(contentID: "film"))
        // A separate URL avoids a queued save racing this deliberately obsolete file.
        let oldURL = directory.appendingPathComponent("Old.json")
        let old = DialogueSalienceIndex.Snapshot(lexiconVersion: DialogueLineInterest.lexiconVersion - 1,
                                                 entries: ["film": index.entry(contentID: "film")])
        try JSONEncoder().encode(old).write(to: oldURL)
        #expect(DialogueSalienceIndex(url: oldURL).entry(contentID: "film").lines.isEmpty)
        #expect(DialogueSalienceIndex(url: oldURL).entry(contentID: "film").spans.isEmpty)
        #expect(!DialogueSalienceIndex.scannerEnabled)
    }

    @Test func cueTranscriptStorageFeedsTheInjectedIndex() async throws {
        let fixture = DialogueSalienceTests.spelled
        let source = fixture.source(contentID: "stored")
        let analysis = DialogueEngine.analyze(source, speech: [])
        let index = DialogueSalienceIndex()
        var settings = DialogueDirector.Settings()
        settings.salienceIndex = index
        let director = DialogueDirector(settings)
        director.store(source, analysis: analysis, bank: nil)
        director.store(source, transcript: DialogueSalienceTests.transcript(fixture), refined: nil)
        director.learnCachedTranscript(source)
        await director.finishSalienceLearning()
        #expect(!index.entry(contentID: "stored").spans.isEmpty)
        #expect(!index.entry(contentID: "stored").lines.isEmpty)
        #expect(index.entry(contentID: "stored").lines.allSatisfy { $0.interest >= 0.45 })
    }
    @Test func scannedSpanUsesAnalyzedFramesAndSourceRate() {
        var options = DialogueFixtures.Options()
        options.seconds = 40
        let fixture = DialogueFixtures.speech(options)
        let source = fixture.source(contentID: "long", sourceStart: 100, rate: 0.7)
        let analysis = DialogueEngine.analyze(source, speech: [])
        let index = DialogueSalienceIndex()
        index.record(source: source, analysis: analysis, transcript: DialogueFixtures.transcript(fixture))
        #expect(index.entry(contentID: "long").spans == [.init(start: 100, end: source.sourceSeconds(frame: analysis.features!.frameCount))])
        #expect(index.entry(contentID: "long").spans[0].end <= 100 + 32 * 0.7)
        let empty = DialogueFixtures.silence(seconds: 0.001).source(contentID: "empty")
        index.record(source: empty, analysis: DialogueEngine.analyze(empty, speech: []), transcript: DialogueFixtures.transcript(fixture))
        #expect(index.entry(contentID: "empty").spans.isEmpty)
    }

    @Test func playedLinesStopContributingToBothBoostAndCueSelection() {
        let index = DialogueSalienceIndex(), ledger = DialogueLineLedger()
        index.record(contentID: "film", scanned: 100..<150, lines: [Self.line()])
        #expect(index.unplayed(contentID: "film", ledger: ledger).count == 1)
        ledger.record(contentID: "film", seconds: 120..<122)
        #expect(index.unplayed(contentID: "film", ledger: ledger).isEmpty)
        for seed: UInt64 in 0..<100 {
            #expect(Self.pick(seed: seed, lines: index.entry(contentID: "film").lines, ledger: ledger) == nil)
        }
    }

}
