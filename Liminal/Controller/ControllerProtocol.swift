import Foundation

/// Wire-only types. No audio work, paths, credentials, or native node references cross this boundary.
nonisolated enum ControllerWire {
    static let version = 1
    static let maxFrameBytes = 65_536
    static let maxDepth = 12
    static let maxCommands = 256
    static let maxOutputBytes = 262_144

    enum Failure: String, Error, Sendable {
        case bad_message, unsupported_version, busy, stale_session, stale_seq
        case invalid_channel, inactive_channel, invalid_parameter, out_of_range
        case wrong_mode, not_playing, stale_bank, stale_instrument, not_ready
        case unavailable, overloaded, preparation_failed
    }

    enum Value: Codable, Equatable, Sendable {
        case object([String: Value]), array([Value]), string(String), integer(Int64), number(Double), bool(Bool), null

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let i = try? c.decode(Int64.self) { self = .integer(i) }
            else if let d = try? c.decode(Double.self), d.isFinite { self = .number(d) }
            else if let s = try? c.decode(String.self) { self = .string(s) }
            else if let a = try? c.decode([Value].self) { self = .array(a) }
            else if let o = try? c.decode([String: Value].self) { self = .object(o) }
            else { throw Failure.bad_message }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .object(let o): try c.encode(o)
            case .array(let a): try c.encode(a)
            case .string(let s): try c.encode(s)
            case .integer(let i): try c.encode(i)
            case .number(let d): guard d.isFinite else { throw Failure.bad_message }; try c.encode(d)
            case .bool(let b): try c.encode(b)
            case .null: try c.encodeNil()
            }
        }

        var string: String? { if case .string(let s) = self { return s }; return nil }
        var integer: Int64? { if case .integer(let i) = self { return i }; return nil }
        var number: Double? {
            switch self { case .number(let d): return d; case .integer(let i): return Double(i); default: return nil }
        }
    }

    struct Frame: Sendable {
        let fields: [String: Value]
        let type: String

        init(_ bytes: Data) throws {
            guard bytes.count < maxFrameBytes, String(data: bytes, encoding: .utf8) != nil else { throw Failure.bad_message }
            // Bound nesting before JSONDecoder recursively allocates containers. Brackets inside strings
            // and escaped quotes are not structure. Decoder still checks all JSON grammar afterwards.
            var depth = 0, quoted = false, escaped = false
            for byte in bytes {
                if quoted {
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 { quoted = false }
                } else if byte == 34 { quoted = true }
                else if byte == 91 || byte == 123 {
                    depth += 1
                    guard depth <= maxDepth else { throw Failure.bad_message }
                } else if byte == 93 || byte == 125 { depth -= 1 }
            }
            guard case .object(let object) = try JSONDecoder().decode(Value.self, from: bytes),
                  let v = object["v"]?.integer, let type = object["type"]?.string else { throw Failure.bad_message }
            guard v == version else { throw Failure.unsupported_version }
            self.fields = object
            self.type = type
        }
    }

    /// Raw bytes remain raw until newline arrives, so a split multibyte UTF-8 character is safe.
    struct Framer: Sendable {
        private var pending = Data()
        mutating func append(_ bytes: Data) throws -> [Frame] {
            var frames: [Frame] = []
            for byte in bytes {
                if byte == 10 {
                    guard pending.count + 1 <= maxFrameBytes else { throw Failure.bad_message }
                    frames.append(try Frame(pending))
                    pending.removeAll(keepingCapacity: true)
                    guard frames.count <= maxCommands else { throw Failure.overloaded }
                } else {
                    pending.append(byte)
                    guard pending.count < maxFrameBytes else { throw Failure.bad_message }
                }
            }
            return frames
        }
        var hasPartialFrame: Bool { !pending.isEmpty }
    }

    enum Action: String, Sendable {
        case transport, mode, parameter, pad_window, note_on, note_off, pressure
        case pad_on, pad_off, all_notes_off, drum_select, drum_next, reset, snapshot
    }

    struct Command: Sendable {
        let session: String
        let seq: Int64
        let action: Action?
        let fields: [String: Value]

        init(_ frame: Frame) throws {
            guard frame.type == "command", let session = frame.fields["session"]?.string,
                  !session.isEmpty, session.utf8.count <= 64,
                  let seq = frame.fields["seq"]?.integer, seq > 0,
                  let name = frame.fields["action"]?.string else { throw Failure.bad_message }
            self.session = session; self.seq = seq; action = Action(rawValue: name); fields = frame.fields
        }

        func string(_ key: String, limit: Int = 64) throws -> String {
            guard let s = fields[key]?.string, !s.isEmpty, s.utf8.count <= limit else { throw Failure.bad_message }
            return s
        }
        func integer(_ key: String, in range: ClosedRange<Int64>) throws -> Int64 {
            guard let i = fields[key]?.integer else { throw Failure.bad_message }
            guard range.contains(i) else { throw Failure.out_of_range }; return i
        }
        func normalized(_ key: String = "value") throws -> Double {
            guard let d = fields[key]?.number, d.isFinite else { throw Failure.bad_message }
            guard (0...1).contains(d) else { throw Failure.out_of_range }; return d
        }

        /// Validate every known command even when the app has not advertised its audio capability.
        func validate() throws {
            guard let action else { throw Failure.unavailable }
            switch action {
            case .transport:
                guard ["playing", "stopped"].contains(try string("state")) else { throw Failure.out_of_range }
            case .mode:
                _ = try string("channel")
                guard ["auto", "manual"].contains(try string("mode")) else { throw Failure.out_of_range }
            case .parameter:
                _ = try string("channel"); _ = try string("parameter"); _ = try normalized()
            case .pad_window:
                _ = try string("channel"); _ = try integer("base_midi", in: 0...127)
            case .note_on, .pad_on:
                _ = try string("channel"); _ = try string("note_id"); _ = try integer("velocity", in: 1...127)
                if action == .note_on {
                    _ = try integer("midi", in: 0...127); _ = try integer("instrument_revision", in: 0...Int64.max)
                } else {
                    _ = try integer("pad", in: 0...63); _ = try integer("bank_revision", in: 0...Int64.max)
                }
            case .note_off, .pad_off: _ = try string("note_id")
            case .pressure: _ = try string("note_id"); _ = try normalized()
            case .all_notes_off: if fields["channel"] != nil { _ = try string("channel") }
            case .drum_select: _ = try string("choice_id")
            case .reset:
                let scope = try string("scope")
                guard ["all", "channel"].contains(scope) else { throw Failure.out_of_range }
                if scope == "channel" { _ = try string("channel") }
            case .snapshot, .drum_next: break
            }
        }
    }

    static func encode(_ fields: [String: Value]) throws -> Data {
        var fields = fields
        fields["v"] = .integer(1)
        var bytes = try JSONEncoder().encode(Value.object(fields))
        bytes.append(10)
        guard bytes.count <= maxFrameBytes else { throw Failure.overloaded }
        return bytes
    }
}

/// All sequence bookkeeping runs on the server queue. Acknowledgements replay without invoking audio.
nonisolated struct ControllerLease {
    let session: String
    private(set) var highest: Int64 = 0
    private var replies: [Int64: Data] = [:]
    private var order: [Int64] = []

    enum Decision { case execute, replay(Data), reject(ControllerWire.Failure) }
    mutating func accept(session: String, seq: Int64) -> Decision {
        guard session == self.session else { return .reject(.stale_session) }
        if let reply = replies[seq] { return .replay(reply) }
        guard seq > highest, highest != 0 || seq == 1 else { return .reject(.stale_seq) }
        highest = seq
        return .execute
    }
    mutating func complete(seq: Int64, reply: Data) {
        replies[seq] = reply; order.append(seq)
        if order.count > 256 { replies.removeValue(forKey: order.removeFirst()) }
    }
}
