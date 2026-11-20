import Foundation

/// Stable channel and parameter identities are independent of the eight hardware channel buttons.
nonisolated enum ControllerChannel: String, CaseIterable, Sendable {
    case drums = "lofi.drums", bass = "lofi.bass", lead = "lofi.lead", mids = "lofi.mids"
    case lofiSpace = "lofi.space", chops = "lofi.chops", film = "film.bed"
    case drone = "ambient.drone", pad = "ambient.pad", ambientLead = "ambient.lead"
    case keys = "ambient.keys", drips = "ambient.drips", air = "ambient.air"
    case grains = "ambient.grains", pluck = "ambient.pluck", ambientSpace = "ambient.space"

    var label: String {
        switch self {
        case .drums: return "Drums"
        case .bass: return "Bass"
        case .lead, .ambientLead: return "Lead"
        case .mids: return "Mids"
        case .lofiSpace, .ambientSpace: return "Space"
        case .chops: return "Chops"
        case .film: return "Film bed"
        case .drone: return "Drone"
        case .pad: return "Pad"
        case .keys: return "Keys"
        case .drips: return "Drips"
        case .air: return "Air"
        case .grains: return "Grains"
        case .pluck: return "Pluck"
        }
    }
    var kind: String {
        switch self {
        case .drums: return "drums"
        case .chops: return "chops"
        case .film: return "gate"
        case .lofiSpace, .ambientSpace: return "return"
        case .air: return "texture"
        default: return "melodic"
        }
    }
}

nonisolated enum ControllerParameter: String, CaseIterable, Sendable {
    case gain, low_cut, high_cut, tone, drive, echo, room, pan
    var defaultValue: Double {
        switch self { case .gain, .tone, .pan: return 0.5; case .high_cut: return 1; default: return 0 }
    }
    var label: String {
        switch self {
        case .gain: return "Level"
        case .low_cut: return "Low cut"
        case .high_cut: return "High cut"
        case .tone: return "Tone"
        case .drive: return "Drive"
        case .echo: return "Echo"
        case .room: return "Room"
        case .pan: return "Pan"
        }
    }
    func display(_ value: Double) -> String {
        if self == .gain { return value == 0 ? "Muted" : String(format: "%.1f dB", 20 * log10(Self.linearGain(value))) }
        return "\(Int(min(1, max(0, value)) * 100))%"
    }
    static func linearGain(_ value: Double) -> Double {
        guard value > 0 else { return 0 }
        return pow(10, (value <= 0.5 ? -60 + 120 * value : 12 * (value - 0.5)) / 20)
    }
}

/// Immutable onset ownership: later octave, program and channel selection changes cannot retarget release.
/// This registry stores control identity only. Native voice allocation/release remains an audio-adapter duty.
nonisolated struct ControllerOnsets: Sendable {
    struct Onset: Equatable, Sendable {
        let session: String
        let noteID: String
        let channel: ControllerChannel
        let instrumentRevision: Int64
        let bankRevision: Int64?
        let voiceToken: UUID
    }
    struct Key: Hashable, Sendable { let session: String; let noteID: String }
    private(set) var held: [Key: Onset] = [:]
    func onset(session: String, noteID: String) -> Onset? { held[Key(session: session, noteID: noteID)] }
    mutating func insert(_ onset: Onset) throws {
        let key = Key(session: onset.session, noteID: onset.noteID)
        guard held[key] == nil else { throw ControllerWire.Failure.bad_message }
        guard held.count < 48 else { throw ControllerWire.Failure.overloaded }
        held[key] = onset
    }
    mutating func release(session: String, noteID: String) -> Onset? {
        held.removeValue(forKey: Key(session: session, noteID: noteID))
    }
    mutating func release(token: UUID) -> Onset? {
        guard let key = held.first(where: { $0.value.voiceToken == token })?.key else { return nil }
        return held.removeValue(forKey: key)
    }
    mutating func releaseAll(session: String? = nil, channel: ControllerChannel? = nil) -> [Onset] {
        let removed = held.values.filter { (session == nil || $0.session == session) && (channel == nil || $0.channel == channel) }
        for onset in removed { held.removeValue(forKey: Key(session: onset.session, noteID: onset.noteID)) }
        return removed
    }
}

/// Prepared-next is not triggerable. Only an explicit audible-boundary commit activates the complete bank.
nonisolated struct ControllerBankEpoch: Equatable, Sendable {
    let cueToken: String
    let bankID: String
    let planRevision: Int64
    let transportRevision: UInt32
}
nonisolated struct ControllerBankActivation: Sendable {
    private(set) var active: ControllerBankEpoch?
    private(set) var revision: Int64 = 0
    private(set) var pending: ControllerBankEpoch?
    private var retired: [String] = []

    mutating func prepare(_ bank: ControllerBankEpoch, cueToken: String, transport: UInt32) -> Bool {
        guard bank.cueToken == cueToken, bank.transportRevision == transport, !retired.contains(bank.cueToken) else { return false }
        for previous in [active, pending].compactMap({ $0 }) where previous.cueToken == bank.cueToken {
            guard bank.planRevision > previous.planRevision else { return false }
        }
        pending = bank
        return true
    }
    mutating func activate(_ bank: ControllerBankEpoch, cueToken: String, transport: UInt32) -> Bool {
        guard pending == bank, bank.cueToken == cueToken, bank.transportRevision == transport, !retired.contains(bank.cueToken) else { return false }
        active = bank; pending = nil; revision += 1
        return true
    }
    mutating func retire(cueToken: String) {
        if active?.cueToken == cueToken { active = nil; revision += 1 }
        if pending?.cueToken == cueToken { pending = nil }
        retired.append(cueToken)
        if retired.count > 256 { retired.removeFirst() }
    }
    mutating func invalidateTransport() {
        active = nil; pending = nil; revision += 1
    }
    func accepts(revision: Int64) -> Bool { active != nil && revision == self.revision }
}
