#if os(macOS)
import Foundation
import Combine

/// The initial native integration exposes transport and state only. Audio controls explicitly return
/// unavailable until the independent audio strips, instrument caches and audible bank adapters land.
/// No remote command may acknowledge a mode or mix change that did not reach the audio graph.
@MainActor
final class ControllerCoordinator: ObservableObject {
    @Published var address = "127.0.0.1"
    @Published var port = "20808"
    @Published private(set) var enabled = false
    @Published private(set) var status = "Disabled"
    @Published private(set) var connected = false
    private weak var engine: GenerativeEngine?
    private var session: String?
    private var revision: Int64 = 0
    private var timer: Task<Void, Never>?
    private var onsets = ControllerOnsets()

    private lazy var server = ControllerServer(
        connect: { [weak self] session in self?.connect(session) ?? [:] },
        execute: { [weak self] command in self?.execute(command) ?? ["type": .string("ack"), "seq": .integer(command.seq), "ok": .bool(false), "revision": .integer(0), "error": .string("unavailable")] },
        disconnect: { [weak self] session in self?.disconnect(session) },
        status: { [weak self] status in
            guard let self else { return }
            self.status = status
            if status.contains("failed") || status.hasPrefix("Cannot start") {
                enabled = false; timer?.cancel(); timer = nil
            }
        })

    init(engine: GenerativeEngine) { self.engine = engine }

    func setEnabled(_ value: Bool) {
        if !value {
            enabled = false; server.stop(); timer?.cancel(); timer = nil
            return
        }
        guard ControllerAddress.isPrivate(address), let portNumber = UInt16(port), portNumber > 0 else {
            status = "Enter a private or loopback IPv4 address and port 1–65535"
            return
        }
        enabled = true
        server.start(address: address, port: portNumber)
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self else { return }
                if connected { server.publish(snapshot()) }
            }
        }
    }

    private func connect(_ session: String) -> ControllerServer.Fields {
        self.session = session; connected = true
        return snapshot()
    }
    private func disconnect(_ session: String) {
        // A late callback from a replaced socket cannot release the new session's onsets.
        _ = onsets.releaseAll(session: session)
        guard self.session == session else { return }
        self.session = nil; connected = false
    }
    func panic() { _ = onsets.releaseAll() }
    func reset() { panic() }

    /// App stop/recovery calls this too. This must grow with native manual audio ownership, not transport.
    func transportDidStop() { panic() }

    private func execute(_ command: ControllerWire.Command) -> ControllerServer.Fields {
        var reply: ControllerServer.Fields = ["type": .string("ack"), "seq": .integer(command.seq), "ok": .bool(true)]
        do {
            guard command.session == session else { throw ControllerWire.Failure.stale_session }
            try command.validate()
            guard let engine, let action = command.action else { throw ControllerWire.Failure.unavailable }
            // Channel identity is validated independently of whether its adapter is ready.
            if let value = command.fields["channel"] {
                guard let id = value.string.flatMap(ControllerChannel.init(rawValue:)) else { throw ControllerWire.Failure.invalid_channel }
                if action != .reset && action != .all_notes_off && !isActive(id) { throw ControllerWire.Failure.inactive_channel }
            }
            switch action {
            case .transport:
                if try command.string("state") == "playing" { engine.start() } else { engine.stop(); panic() }
            case .snapshot: break
            case .all_notes_off:
                let channel = command.fields["channel"]?.string.flatMap(ControllerChannel.init(rawValue:))
                _ = onsets.releaseAll(session: command.session, channel: channel)
            case .note_off, .pad_off:
                _ = onsets.release(session: command.session, noteID: try command.string("note_id"))
            case .pressure:
                // No held onset is a harmless success. No audio-onset adapter is advertised yet.
                guard onsets.onset(session: command.session, noteID: try command.string("note_id")) == nil else { throw ControllerWire.Failure.unavailable }
            case .reset: reset()
            case .note_on, .pad_on:
                guard engine.isRunning && engine.isPlaybackReady else { throw ControllerWire.Failure.not_playing }
                throw ControllerWire.Failure.not_ready
            default: throw ControllerWire.Failure.unavailable
            }
        } catch let failure as ControllerWire.Failure {
            reply["ok"] = .bool(false); reply["error"] = .string(failure.rawValue)
        } catch {
            reply["ok"] = .bool(false); reply["error"] = .string("bad_message")
        }
        revision += 1
        reply["revision"] = .integer(revision)
        server.publish(snapshot())
        return reply
    }

    private func isActive(_ id: ControllerChannel) -> Bool {
        guard let engine else { return false }
        if id == .film { return false } // Film capability waits for actual cue publication, never inferred from a setting.
        return id.rawValue.hasPrefix(engine.musicMode == .lofi ? "lofi." : "ambient.")
    }

    private func snapshot() -> ControllerServer.Fields {
        revision += 1
        let music = engine?.musicState.read() ?? MusicState()
        let transport = engine?.musicState.transport()
        let scale = ScaleType.allCases.indices.contains(Int(music.modeIndex)) ? ScaleType.allCases[Int(music.modeIndex)] : .major
        let channels: [ControllerWire.Value] = ControllerChannel.allCases.map { id in
            let parameters: [ControllerWire.Value] = ControllerParameter.allCases.map { p in
                .object(["id": .string(p.rawValue), "label": .string(p.label), "value": .number(p.defaultValue),
                         "default": .number(p.defaultValue), "display": .string(p == .gain ? "0.0 dB" : "\(Int(p.defaultValue * 100))%"), "enabled": .bool(false)])
            }
            return .object(["id": .string(id.rawValue), "label": .string(id.label), "kind": .string(id.kind),
                            "active": .bool(isActive(id)), "mode": .string("auto"), "ready": .bool(false),
                            "status": .string("Native performance audio adapter not installed"),
                            "instrument": .string("Unavailable"), "instrument_revision": .integer(0), "base_midi": .integer(id == .bass ? 24 : 48),
                            "parameters": .array(parameters), "pad_bank": .null])
        }
        let playing = engine?.isRunning == true
        return ["type": .string("state"), "revision": .integer(revision),
                "capabilities": .object(["transport": .bool(true), "snapshot": .bool(true), "performance_audio": .bool(false)]),
                "transport": .object(["state": .string(playing ? "playing" : "stopped"),
                                      "ready": .bool(engine?.isPlaybackReady == true),
                                      "music_mode": .string(engine?.musicMode == .lofi ? "lofi" : "ambient"),
                                      "bpm": .number(transport.map { 60 / $0.beatDuration } ?? 0),
                                      "beat": .number(transport.map { max(0, (ProcessInfo.processInfo.systemUptime - $0.origin) / $0.beatDuration) } ?? 0),
                                      "take_index": .integer(Int64(transport?.takeIndex ?? 0)),
                                      "transport_revision": .integer(Int64(transport?.revision ?? 0))]),
                "harmony": .object(["tonic": .integer(Int64(music.tonic)), "scale_name": .string(scale.rawValue),
                                    "pitch_classes": .array((0..<12).filter { music.scaleMask & (1 << (($0 + Int(music.tonic)) % 12)) != 0 }.map { .integer(Int64($0)) })]),
                "channels": .array(channels), "drums": .object(["choices": .array([]), "current_id": .null, "pending": .null])]
    }
}
#endif
