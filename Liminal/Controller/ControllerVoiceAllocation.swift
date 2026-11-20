import Foundation

/// Pure onset allocation. Tokens, rather than pool indices, own every delayed release.
/// Retiring native slots are reserved separately until their fade has finished.
nonisolated struct ControllerVoiceAllocation: Sendable {
    struct Voice: Equatable, Sendable {
        let token: UUID
        let channel: ControllerChannel
        let started: Double
        let deadline: Double
    }
    private(set) var voices: [Voice] = []
    static let maximum = 48
    static let holdLimit = 120.0

    mutating func take(channel: ControllerChannel, now: Double) -> (Voice, [Voice]) {
        var stolen: [Voice] = []
        let limit = channel == .bass ? 1 : 8
        if voices.filter({ $0.channel == channel }).count >= limit,
           let oldest = voices.first(where: { $0.channel == channel }) {
            stolen.append(oldest); voices.removeAll { $0.token == oldest.token }
        }
        if voices.count >= Self.maximum { stolen.append(voices.removeFirst()) }
        let voice = Voice(token: UUID(), channel: channel, started: now, deadline: now + Self.holdLimit)
        voices.append(voice)
        return (voice, stolen)
    }

    mutating func release(_ token: UUID) -> Voice? {
        guard let index = voices.firstIndex(where: { $0.token == token }) else { return nil }
        return voices.remove(at: index)
    }
    mutating func expire(now: Double) -> [Voice] {
        let expired = voices.filter { now >= $0.deadline }
        voices.removeAll { now >= $0.deadline }
        return expired
    }
}
