import Foundation
import Testing
@testable import Liminal

struct ControllerProtocolTests {
    private func frame(_ json: String) throws -> ControllerWire.Frame { try ControllerWire.Frame(Data(json.utf8)) }
    private func command(_ extra: String) throws -> ControllerWire.Command {
        try ControllerWire.Command(frame("{\"v\":1,\"type\":\"command\",\"session\":\"s\",\"seq\":1," + extra + "}"))
    }

    @Test func fragmentedUTF8AndCoalescedFrames() throws {
        let data = Data("{\"v\":1,\"type\":\"hello\",\"client\":\"é\"}\n{\"v\":1,\"type\":\"ping\",\"nonce\":7}\n".utf8)
        for split in 0...data.count {
            var parser = ControllerWire.Framer()
            let a = try parser.append(data.prefix(split))
            let b = try parser.append(data.dropFirst(split))
            #expect((a + b).map(\.type) == ["hello", "ping"])
            #expect(!parser.hasPartialFrame)
        }
    }
    @Test func invalidEnvelopes() {
        for json in ["[]", "null", "1", "{}", "{\"v\":true,\"type\":\"hello\"}",
                     "{\"v\":1,\"type\":3}", "{\"v\":1,\"type\":\"ping\",\"x\":NaN}",
                     "{\"v\":1,\"type\":\"ping\",\"x\":1e999}"] {
            #expect(throws: (any Error).self) { try frame(json) }
        }
        #expect(throws: ControllerWire.Failure.unsupported_version) { try frame("{\"v\":2,\"type\":\"hello\"}") }
        #expect(throws: (any Error).self) { try ControllerWire.Frame(Data([0xFF])) }
    }
    @Test func nestingBoundIgnoresQuotedBrackets() throws {
        _ = try frame("{\"v\":1,\"type\":\"ping\",\"x\":\"[[[[[[[[[[[[[[[\\\"\"}")
        let nested = String(repeating: "[", count: 12) + "0" + String(repeating: "]", count: 12)
        #expect(throws: ControllerWire.Failure.bad_message) { try frame("{\"v\":1,\"type\":\"ping\",\"x\":" + nested + "}") }
    }
    @Test func frameByteLimitIncludesNewline() throws {
        let prefix = "{\"v\":1,\"type\":\"ping\",\"x\":\""
        let suffix = "\"}\n"
        let exact = Data((prefix + String(repeating: "a", count: 65_536 - prefix.utf8.count - suffix.utf8.count) + suffix).utf8)
        var parser = ControllerWire.Framer()
        #expect(try parser.append(exact).count == 1)
        parser = ControllerWire.Framer()
        #expect(throws: ControllerWire.Failure.bad_message) { try parser.append(Data(repeating: 97, count: 65_536)) }
    }
    @Test func boundedBatchAndOutput() {
        var parser = ControllerWire.Framer()
        let one = "{\"v\":1,\"type\":\"ping\"}\n"
        #expect(throws: ControllerWire.Failure.overloaded) { try parser.append(Data(String(repeating: one, count: 257).utf8)) }
        #expect(throws: ControllerWire.Failure.overloaded) { try ControllerWire.encode(["type": .string(String(repeating: "a", count: 65_536))]) }
        #expect(throws: ControllerWire.Failure.bad_message) { try ControllerWire.encode(["x": .number(.infinity)]) }
    }
    @Test func noteAndParameterValidation() throws {
        try command("\"action\":\"note_on\",\"channel\":\"lofi.bass\",\"note_id\":\"n\",\"midi\":60,\"velocity\":127,\"instrument_revision\":3").validate()
        for fields in ["\"action\":\"parameter\",\"channel\":\"lofi.bass\",\"parameter\":\"gain\",\"value\":1.01",
                       "\"action\":\"pressure\",\"note_id\":\"n\",\"value\":-0.1",
                       "\"action\":\"pad_window\",\"channel\":\"lofi.lead\",\"base_midi\":128",
                       "\"action\":\"pad_on\",\"channel\":\"lofi.chops\",\"note_id\":\"n\",\"pad\":64,\"velocity\":90,\"bank_revision\":1"] {
            #expect(throws: ControllerWire.Failure.out_of_range) { try command(fields).validate() }
        }
        #expect(throws: ControllerWire.Failure.bad_message) { try command("\"action\":\"note_off\",\"note_id\":\"\"").validate() }
        #expect(throws: ControllerWire.Failure.unavailable) { try command("\"action\":\"not_a_command\"").validate() }
    }
    @Test func publicGoldenMessagesDecode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("docs/controller/fixtures/messages.ndjson")
        var parser = ControllerWire.Framer()
        let frames = try parser.append(Data(contentsOf: fixture))
        #expect(frames.count == 12)
        for frame in frames where frame.type == "command" { try ControllerWire.Command(frame).validate() }
    }
    @Test func sequenceReplayAndEviction() throws {
        var lease = ControllerLease(session: "s")
        if case .reject(.stale_seq) = lease.accept(session: "s", seq: 2) {} else { Issue.record("First sequence must be 1") }
        if case .reject(.stale_session) = lease.accept(session: "old", seq: 1) {} else { Issue.record("Stale session accepted") }
        let bytes = Data("ack".utf8)
        for seq in 1...257 {
            if case .execute = lease.accept(session: "s", seq: Int64(seq)) {} else { Issue.record("New sequence rejected") }
            lease.complete(seq: Int64(seq), reply: bytes)
        }
        if case .replay(let cached) = lease.accept(session: "s", seq: 257) { #expect(cached == bytes) } else { Issue.record("Duplicate could replay audio") }
        if case .reject(.stale_seq) = lease.accept(session: "s", seq: 1) {} else { Issue.record("Evicted sequence accepted") }
        var reconnect = ControllerLease(session: "new")
        if case .reject(.stale_session) = reconnect.accept(session: "s", seq: 1) {} else { Issue.record("Reconnect accepted cached command") }
        #expect(reconnect.highest == 0)
    }
}

#if os(macOS)
struct ControllerAddressTests {
    @Test func onlyLiteralPrivateAddresses() {
        for address in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.1.2"] { #expect(ControllerAddress.isPrivate(address)) }
        for address in ["0.0.0.0", "8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.1.1", "localhost", "::", "::1", "10.01.2.3", "10.2.3.256", "10.2.3.4.example"] { #expect(!ControllerAddress.isPrivate(address)) }
    }
}
#endif
