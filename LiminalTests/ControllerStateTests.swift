import Foundation
import Testing
@testable import Liminal

struct ControllerStateTests {
    @Test func stableChannelsAndUnityDefaults() {
        #expect(ControllerChannel.allCases.count == 16)
        #expect(ControllerChannel.allCases.first == .drums)
        #expect(ControllerChannel.allCases.last == .ambientSpace)
        #expect(ControllerParameter.allCases.map(\.defaultValue) == [0.5, 0, 1, 0.5, 0, 0, 0, 0.5])
        #expect(ControllerParameter.linearGain(0.5) == 1)
        #expect(ControllerParameter.linearGain(0) == 0)
        #expect(abs(ControllerParameter.linearGain(1) - pow(10, 0.3)) < 1e-12)
    }
    private func onset(_ id: String = "pad", session: String = "s", channel: ControllerChannel = .bass) -> ControllerOnsets.Onset {
        .init(session: session, noteID: id, channel: channel, instrumentRevision: 7, bankRevision: nil, voiceToken: UUID())
    }
    @Test func noteOffRetainsOriginalProgramAndVoice() throws {
        var onsets = ControllerOnsets()
        let captured = onset()
        try onsets.insert(captured)
        #expect(onsets.release(session: "old-session", noteID: "pad") == nil)
        #expect(onsets.release(session: "s", noteID: "pad") == captured)
        #expect(onsets.release(session: "s", noteID: "pad") == nil)
        let replacement = onset(channel: .lead)
        try onsets.insert(replacement)
        #expect(onsets.release(session: "s", noteID: "pad")?.voiceToken == replacement.voiceToken)
    }
    @Test func boundedOnsetsAndDuplicateIdentity() throws {
        var onsets = ControllerOnsets()
        try onsets.insert(onset())
        #expect(throws: ControllerWire.Failure.bad_message) { try onsets.insert(onset()) }
        for i in 1..<48 { try onsets.insert(onset(String(i))) }
        #expect(throws: ControllerWire.Failure.overloaded) { try onsets.insert(onset("overflow")) }
    }
    @Test func disconnectAndChannelPanicPreserveOtherOwnership() throws {
        var onsets = ControllerOnsets()
        try onsets.insert(onset("a"))
        try onsets.insert(onset("b", session: "new", channel: .lead))
        #expect(onsets.releaseAll(session: "s").count == 1)
        #expect(onsets.held.count == 1)
        #expect(onsets.releaseAll(channel: .bass).isEmpty)
        #expect(onsets.releaseAll().count == 1)
        #expect(onsets.held.isEmpty)
    }
    private func bank(_ cue: String = "cue", plan: Int64 = 0, transport: UInt32 = 1) -> ControllerBankEpoch {
        .init(cueToken: cue, bankID: "bank-\(plan)", planRevision: plan, transportRevision: transport)
    }
    @Test func preparedBankIsNotActiveUntilMatchingAudibleCommit() {
        var state = ControllerBankActivation()
        let first = bank()
        #expect(state.prepare(first, cueToken: "cue", transport: 1))
        #expect(!state.accepts(revision: 0))
        #expect(!state.activate(first, cueToken: "next", transport: 1))
        #expect(state.activate(first, cueToken: "cue", transport: 1))
        #expect(state.accepts(revision: 1))
        let refined = bank(plan: 1)
        #expect(state.prepare(refined, cueToken: "cue", transport: 1))
        #expect(state.active == first)
        #expect(state.activate(refined, cueToken: "cue", transport: 1))
        #expect(!state.accepts(revision: 1))
        #expect(state.accepts(revision: 2))
    }
    @Test func staleCuePlanAndTransportCannotActivate() {
        var state = ControllerBankActivation()
        #expect(!state.prepare(bank("old"), cueToken: "cue", transport: 1))
        #expect(!state.prepare(bank(transport: 0), cueToken: "cue", transport: 1))
        #expect(state.prepare(bank(plan: 2), cueToken: "cue", transport: 1))
        #expect(!state.prepare(bank(plan: 1), cueToken: "cue", transport: 1))
        state.retire(cueToken: "cue")
        #expect(!state.activate(bank(plan: 2), cueToken: "cue", transport: 1))
        #expect(!state.prepare(bank(plan: 3), cueToken: "cue", transport: 1))
        state.invalidateTransport()
        #expect(state.active == nil)
        #expect(!state.accepts(revision: state.revision))
    }
}
