#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import Liminal

@Suite(.serialized)
struct ControllerServerTests {
    /// Blocking socket fixture lives on a worker thread, never MainActor or an audio queue.
    private nonisolated final class Peer {
        let fd: Int32
        init(port: UInt16) throws {
            fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw ControllerWire.Failure.unavailable }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
            let result = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else { Darwin.close(fd); throw ControllerWire.Failure.unavailable }
        }
        deinit { Darwin.close(fd) }
        func send(_ line: String) throws {
            let bytes = Array((line + "\n").utf8)
            var offset = 0
            try bytes.withUnsafeBytes { raw in
                while offset < raw.count {
                    let n = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                    guard n > 0 else { throw ControllerWire.Failure.unavailable }
                    offset += n
                }
            }
        }
        func read() throws -> ControllerWire.Frame {
            var bytes = Data(), byte: UInt8 = 0
            while bytes.count < ControllerWire.maxFrameBytes {
                guard Darwin.recv(fd, &byte, 1, 0) == 1 else { throw ControllerWire.Failure.unavailable }
                if byte == 10 { return try ControllerWire.Frame(bytes) }
                bytes.append(byte)
            }
            throw ControllerWire.Failure.bad_message
        }
        func hello() throws -> String {
            try send("{\"v\":1,\"type\":\"hello\",\"client\":\"liminal-controller\",\"client_version\":\"test\"}")
            let welcome = try read()
            #expect(welcome.type == "welcome")
            let state = try read()
            #expect(state.type == "state")
            return try #require(welcome.fields["session"]?.string)
        }
    }

    @Test @MainActor func leaseBusyReplayReconnectAndEOFRelease() async throws {
        var executions = 0, disconnects = 0, listening = false
        let server = ControllerServer(connect: { _ in ["type": .string("state"), "revision": .integer(1)] },
                                      execute: { command in
            executions += 1
            return ["type": .string("ack"), "seq": .integer(command.seq), "ok": .bool(true), "revision": .integer(2)]
        }, disconnect: { _ in disconnects += 1 }, status: { listening = $0.hasPrefix("Listening on") })
        let port = UInt16.random(in: 40_000...50_000)
        server.start(address: "127.0.0.1", port: port)
        defer { server.stop() }
        for _ in 0..<200 {
            if listening { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(listening)
        let oldSession = try await Task.detached {
            let first = try Peer(port: port)
            let session = try first.hello()
            let second = try Peer(port: port)
            try second.send("{\"v\":1,\"type\":\"hello\",\"client\":\"liminal-controller\",\"client_version\":\"test\"}")
            #expect(try second.read().fields["error"] == .string("busy"))
            let line = "{\"v\":1,\"type\":\"command\",\"session\":\"\(session)\",\"seq\":1,\"action\":\"snapshot\"}"
            try first.send(line)
            let a = try first.read()
            try first.send(line)
            let b = try first.read()
            #expect(a.fields == b.fields)
            try first.send("{\"v\":1,\"type\":\"ping\",\"nonce\":71}")
            #expect(try first.read().fields["nonce"] == .integer(71))
            return session
        }.value
        for _ in 0..<200 {
            if disconnects == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(executions == 1)
        #expect(disconnects == 1)
        try await Task.detached {
            let peer = try Peer(port: port)
            let session = try peer.hello()
            #expect(session != oldSession)
            try peer.send("{\"v\":1,\"type\":\"command\",\"session\":\"\(oldSession)\",\"seq\":1,\"action\":\"snapshot\"}")
            #expect(try peer.read().fields["error"] == .string("stale_session"))
        }.value
        #expect(executions == 1)
    }
}
#endif
