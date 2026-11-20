#if os(macOS)
import Foundation
import Network

/// A literal IPv4 address is deliberate: no DNS resolution, wildcard bind, or accidental public listener.
nonisolated enum ControllerAddress {
    static func isPrivate(_ address: String) -> Bool {
        let pieces = address.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { return false }
        let octets = pieces.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = Int(part), (0...255).contains(n), String(n) == part else { return nil }
            return n
        }
        guard octets.count == 4 else { return false }
        return octets[0] == 127 || octets[0] == 10 ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168)
    }
}

/// Queue-confined Network.framework transport. The app callbacks are always MainActor; at most one
/// command crosses that boundary at a time. The audio render thread never sees JSON or sockets.
nonisolated final class ControllerServer: @unchecked Sendable {
    typealias Fields = [String: ControllerWire.Value]
    typealias Connect = @MainActor @Sendable (String) -> Fields
    typealias Execute = @MainActor @Sendable (ControllerWire.Command) -> Fields
    typealias Disconnect = @MainActor @Sendable (String) -> Void
    typealias Status = @MainActor @Sendable (String) -> Void

    private let queue = DispatchQueue(label: "Liminal.controller.network", qos: .userInitiated)
    private let serverID = UUID().uuidString
    private var listener: NWListener?
    private var timer: DispatchSourceTimer?
    private var clients: [UUID: Client] = [:]
    private var owner: UUID?
    private var generation = UUID()
    private let connect: Connect
    private let execute: Execute
    private let disconnect: Disconnect
    private let status: Status

    private final class Client {
        let id = UUID()
        let connection: NWConnection
        let created = ProcessInfo.processInfo.systemUptime
        var received = ProcessInfo.processInfo.systemUptime
        var framer = ControllerWire.Framer()
        var lease: ControllerLease?
        var commands: [ControllerWire.Command] = []
        var executing = false
        var ready = false
        var closed = false
        var output: [Data] = []
        var outputBytes = 0
        var sending = false
        var pendingState: Data?
        var revision: Int64 = 0
        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(connect: @escaping Connect, execute: @escaping Execute,
         disconnect: @escaping Disconnect, status: @escaping Status) {
        self.connect = connect; self.execute = execute; self.disconnect = disconnect; self.status = status
    }

    deinit {
        listener?.cancel()
        timer?.cancel()
        for client in clients.values { client.connection.cancel() }
    }

    /// Binding is off by default. Changing configuration first releases the old lease.
    func start(address: String, port: UInt16) {
        queue.async { [self] in
            stopOnQueue()
            guard ControllerAddress.isPrivate(address), port > 0 else { report("Use a private or loopback IPv4 address and port 1–65535"); return }
            do {
                let tcp = NWProtocolTCP.Options()
                tcp.noDelay = true
                let parameters = NWParameters(tls: nil, tcp: tcp)
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                let token = generation
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self, token == generation else { return }
                    switch state {
                    case .ready: report("Listening on \(address):\(port)")
                    case .failed: stopOnQueue(); report("Listener failed; disabled")
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, token == generation else { connection.cancel(); return }
                    accept(connection)
                }
                listener.start(queue: queue)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
                timer.setEventHandler { [weak self] in self?.expire() }
                self.timer = timer; timer.resume()
            } catch { report("Cannot start controller listener") }
        }
    }

    func stop() { queue.async { [self] in stopOnQueue(); report("Disabled") } }

    /// Full state replaces stale unsent state. No growing stream of intermediate snapshots.
    func publish(_ fields: Fields) {
        queue.async { [self] in
            guard let id = owner, let client = clients[id], let session = client.lease?.session, client.ready else { return }
            var state = fields; state["session"] = .string(session)
            enqueueState(state, client)
        }
    }

    private func stopOnQueue() {
        generation = UUID()
        listener?.cancel(); listener = nil
        timer?.cancel(); timer = nil
        for client in Array(clients.values) { close(client) }
    }

    private func report(_ message: String) { Task { @MainActor [status] in status(message) } }

    private func accept(_ connection: NWConnection) {
        guard clients.count < 4, case .hostPort(let host, _) = connection.endpoint,
              ControllerAddress.isPrivate(String(describing: host)) else { connection.cancel(); return }
        let client = Client(connection)
        clients[client.id] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state { case .failed, .cancelled: close(client); default: break }
        }
        connection.start(queue: queue)
        receive(client)
    }

    private func receive(_ client: Client) {
        guard !client.closed else { return }
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak client] data, _, ended, error in
            guard let self, let client, !client.closed else { return }
            do {
                if let data {
                    for frame in try client.framer.append(data) { try handle(frame, client) }
                }
            } catch let failure as ControllerWire.Failure {
                fail(failure, client); return
            } catch { fail(.bad_message, client); return }
            if ended || error != nil { close(client) } else { receive(client) }
        }
    }

    private func handle(_ frame: ControllerWire.Frame, _ client: Client) throws {
        guard !client.closed else { return }
        if client.lease == nil {
            guard frame.type == "hello", frame.fields["client"]?.string == "liminal-controller",
                  let version = frame.fields["client_version"]?.string, !version.isEmpty, version.utf8.count <= 64 else { throw ControllerWire.Failure.bad_message }
            guard owner == nil else { fail(.busy, client); return }
            let session = UUID().uuidString
            client.lease = ControllerLease(session: session); owner = client.id
            client.received = ProcessInfo.processInfo.systemUptime
            send(["type": .string("welcome"), "session": .string(session), "server_id": .string(serverID),
                  "heartbeat_ms": .integer(1000), "max_frame_bytes": .integer(65_536)], client)
            report("Controller connected")
            Task { @MainActor [weak self, connect] in
                let snapshot = connect(session)
                self?.queue.async { [weak self] in
                    guard let self, !client.closed else { return }
                    var state = snapshot; state["session"] = .string(session)
                    enqueueState(state, client)
                    client.ready = true
                    pump(client)
                }
            }
        } else if frame.type == "ping" {
            guard let nonce = frame.fields["nonce"]?.integer else { throw ControllerWire.Failure.bad_message }
            client.received = ProcessInfo.processInfo.systemUptime
            send(["type": .string("pong"), "nonce": .integer(nonce)], client)
        } else if frame.type == "command" {
            let command = try ControllerWire.Command(frame)
            client.received = ProcessInfo.processInfo.systemUptime
            guard client.commands.count < ControllerWire.maxCommands else { throw ControllerWire.Failure.overloaded }
            client.commands.append(command)
            pump(client)
        } else { throw ControllerWire.Failure.bad_message }
    }

    private func pump(_ client: Client) {
        guard !client.closed, client.ready, !client.executing, !client.commands.isEmpty else { return }
        let command = client.commands.removeFirst()
        guard let decision = client.lease?.accept(session: command.session, seq: command.seq) else { return }
        switch decision {
        case .replay(let reply): enqueue(reply, client)
        case .reject(let error): send(ack(command.seq, revision: client.revision, failure: error), client)
        case .execute:
            client.executing = true
            Task { @MainActor [weak self, execute] in
                let reply = execute(command)
                self?.queue.async { [weak self] in
                    guard let self, !client.closed else { return }
                    do {
                        let bytes = try ControllerWire.encode(reply)
                        client.revision = reply["revision"]?.integer ?? client.revision
                        client.lease?.complete(seq: command.seq, reply: bytes)
                        enqueue(bytes, client)
                        client.executing = false
                        pump(client)
                    } catch { fail(.overloaded, client) }
                }
            }
            return
        }
        // Avoid recursive stack growth when a single read contains many duplicate sequences.
        queue.async { [weak self] in self?.pump(client) }
    }

    private func ack(_ seq: Int64, revision: Int64, failure: ControllerWire.Failure) -> Fields {
        ["type": .string("ack"), "seq": .integer(seq), "ok": .bool(false),
         "revision": .integer(revision), "error": .string(failure.rawValue)]
    }

    private func enqueueState(_ state: Fields, _ client: Client) {
        do {
            client.revision = state["revision"]?.integer ?? client.revision
            let data = try ControllerWire.encode(state)
            guard client.outputBytes + data.count <= ControllerWire.maxOutputBytes else { fail(.overloaded, client); return }
            client.pendingState = data
            flush(client)
        } catch { fail(.overloaded, client) }
    }

    private func send(_ fields: Fields, _ client: Client) {
        do { enqueue(try ControllerWire.encode(fields), client) } catch { close(client) }
    }
    private func enqueue(_ data: Data, _ client: Client) {
        guard !client.closed else { return }
        guard client.outputBytes + (client.pendingState?.count ?? 0) + data.count <= ControllerWire.maxOutputBytes else { close(client); return }
        client.output.append(data); client.outputBytes += data.count
        flush(client)
    }
    private func flush(_ client: Client) {
        guard !client.closed, !client.sending else { return }
        let next: Data
        if !client.output.isEmpty { next = client.output.removeFirst() }
        else if let state = client.pendingState { next = state; client.pendingState = nil; client.outputBytes += state.count }
        else { return }
        client.sending = true
        client.connection.send(content: next, completion: .contentProcessed { [weak self, weak client] error in
            guard let self, let client, !client.closed else { return }
            client.outputBytes -= next.count; client.sending = false
            if error != nil { close(client) } else { flush(client) }
        })
    }

    private func fail(_ error: ControllerWire.Failure, _ client: Client) {
        guard !client.closed else { return }
        // Release ownership now; allow a bounded terminal reply to drain before cancellation.
        let connection = client.connection
        close(client, cancel: false)
        if let bytes = try? ControllerWire.encode(["type": .string("error"), "error": .string(error.rawValue)]) {
            connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
            queue.asyncAfter(deadline: .now() + .milliseconds(100)) { connection.cancel() }
        } else { connection.cancel() }
    }
    private func expire() {
        let now = ProcessInfo.processInfo.systemUptime
        for client in Array(clients.values) {
            let last = client.lease == nil ? client.created : client.received
            if now - last >= 3 { close(client) }
        }
    }
    private func close(_ client: Client, cancel: Bool = true) {
        guard !client.closed else { return }
        client.closed = true
        client.commands.removeAll(); client.output.removeAll(); client.pendingState = nil
        if cancel { client.connection.cancel() }
        clients.removeValue(forKey: client.id)
        if owner == client.id { owner = nil; report("Listening; controller disconnected") }
        if let session = client.lease?.session { Task { @MainActor [disconnect] in disconnect(session) } }
    }
}
#endif
