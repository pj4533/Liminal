import AVFoundation
import Foundation
import Testing
@testable import Liminal

/// The two policies start with identical observed speech, then learn only from their own played cues.
enum DialogueFootageSimulation {
    struct Counts {
        var picks = 0, salient = 0, random = 0, catalogSalient = 0
        var opportunities = 0, rescued = 0, decoded = 0, silent = 0, transcripts = 0, postedChops = 0
        var shares: [String: Int] = [:]
    }

    static func run(clips: [ArchiveClip], seedURL: URL, directory: URL, picks: Int = 500) async throws {
        try #require((1...500).contains(picks))
        let seed = try JSONDecoder().decode(DialogueSalienceIndex.Snapshot.self, from: Data(contentsOf: seedURL))
        try #require(seed.lexiconVersion == DialogueLineInterest.lexiconVersion && !seed.entries.isEmpty)
        for evolving in [false, true] {
            for indexed in [false, true] {
                try await arm(clips: clips, seedURL: seedURL, directory: directory, evolving: evolving, indexed: indexed, picks: picks)
            }
        }
    }

    private static func arm(clips: [ArchiveClip], seedURL: URL, directory: URL, evolving: Bool, indexed: Bool, picks: Int) async throws {
        let index = DialogueSalienceIndex(seedURL: seedURL), ledger = DialogueLineLedger()
        var settings = DialogueDirector.Settings()
        settings.ledger = ledger
        settings.salienceIndex = index
        settings.transcriptProvider = {
            if let provider = AppleSpeechTranscriptProvider.live() { return provider }
            return NullTranscriptProvider()
        }
        let director = DialogueDirector(settings)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        var history = clips, weaver = FootageWeaver(seed: 0x5A11_EACE, timing: .standard)
        var rng = MusicRNG(seed: 0x5A11_EACE), counts = Counts()
        let epoch = clips.map { $0.recency.timeIntervalSinceReferenceDate }.max() ?? 0
        func scanned() -> Double {
            clips.flatMap { index.entry(contentID: $0.id).spans }.reduce(0) { $0 + $1.end - $1.start }
        }
        let initialSeconds = scanned()
        for piece in 0..<picks {
            let request = FootageWeaver.Request(index: piece, slot: piece % 2, start: Double(piece) * 48,
                                                fadeIn: 2, length: 48, recipe: .plain(.window), seed: rng.unit(),
                                                rate: 0.75, warp: 0, level: 0.5, swell: 0, sound: true)
            guard let selection = FootageSalience.prepare(request, clips: history, weaver: &weaver,
                                                           rng: &rng, elapsed: request.start, index: index,
                                                           ledger: ledger, indexed: indexed, measureOpportunity: indexed),
                  let cue = ArchiveAudioCuePlan(piece: selection.piece, clipDuration: selection.clip.duration) else { continue }
            let clip = selection.clip
            let catalogPiece = request.piece(clipID: clip.id, segmentStart: selection.catalogStart, length: selection.piece.length)
            let catalogCue = try #require(ArchiveAudioCuePlan(piece: catalogPiece, clipDuration: clip.duration))
            let unplayed = index.unplayed(contentID: clip.id, ledger: ledger)
            func contains(_ cue: ArchiveAudioCuePlan) -> Bool {
                let end = cue.sourceStart + ArchiveDialogueSource.containedSeconds(cue)
                return unplayed.contains { $0.start >= cue.sourceStart && $0.end <= end }
            }
            let originalHit = contains(catalogCue), selectedHit = contains(cue)
            counts.picks += 1
            counts.shares[clip.id, default: 0] += 1
            if originalHit { counts.catalogSalient += 1 }
            if selectedHit { counts.salient += 1 }
            if !selection.targeted { counts.random += 1 }
            if !originalHit, selection.measuredFeasible == true { counts.opportunities += 1 }
            if !originalHit, selectedHit { counts.rescued += 1 }
            weaver.didPrepare(selection.piece)
            _ = weaver.tick(elapsed: request.start + request.fadeIn, conditions: .init(), hasClip: true,
                            grid: LofiTakeGrid(origin: 0, beatDuration: 60 / 72), ready: { _ in true })
            guard evolving else { continue }
            let i = try #require(history.firstIndex { $0.id == clip.id })
            history[i].shownStarts.append(selection.piece.segmentStart)
            history[i].lastUsed = Date(timeIntervalSinceReferenceDate: epoch + Double(piece + 1))
            history[i].useCount += 1
            do {
                let url = directory.appending(path: clip.fileName)
                let bed = try await ArchiveAudioDecoder.decode(url: url, sourceStart: cue.sourceStart,
                                                               sourceLength: cue.sourceLength, rate: cue.rate, format: format)
                let source = try await ArchiveDialogueSource.make(cue: cue, bed: bed, url: url, contentID: clip.id,
                                                                  cueToken: piece + 1, format: format)
                counts.decoded += 1
                let began = settings.now()
                let beat = 60.0 / 72, take = Int(request.start / (64 * beat))
                let info = LofiTransportInfo(revision: 1, takeIndex: take, phraseAtTakeStart: 4 * take,
                    origin: began - request.start + Double(take * 64) * beat, beatDuration: beat, nextBeatDuration: nil,
                    seed: 0x5A11_EACE, options: LofiOptions(tempo: 72), timing: nil)
                let due = began + (cue.beginAt - request.start)
                let window = DialogueCueCoordinator.window(due: due, span: cue.endAt - cue.beginAt, transport: info)
                let result = await director.run(source: source, window: window, seed: UInt64(selection.piece.seed.bitPattern),
                                                transport: { info }, isCurrent: { true }, post: { _ in })
                await director.finishSalienceLearning()
                if director.cachedTranscript(source) != nil { counts.transcripts += 1 }
                counts.postedChops += result.posted.last?.chops.count ?? 0
            } catch ArchiveAudioDecoder.Failure.silent {
                counts.silent += 1
            }
            if (piece + 1).isMultiple(of: 25) {
                print("SALIENCE-PLAYBACK progress indexed=\(indexed) picks=\(piece + 1) transcripts=\(counts.transcripts)")
            }
        }
        let row: [String: Any] = ["indexed": indexed, "policy": evolving ? "evolvingPlayback" : "freshIndex",
            "picks": counts.picks, "salient": counts.salient, "random": counts.random, "filmShares": counts.shares,
            "catalogSalient": counts.catalogSalient, "opportunities": counts.opportunities, "rescued": counts.rescued,
            "decoded": counts.decoded, "silent": counts.silent, "transcripts": counts.transcripts,
            "postedChops": counts.postedChops, "consumed": ledger.totalPlays, "newlyScannedSeconds": scanned() - initialSeconds]
        print("SALIENCE-FOOTAGE " + DialogueSalienceProbeTests.json(row))
    }
}
