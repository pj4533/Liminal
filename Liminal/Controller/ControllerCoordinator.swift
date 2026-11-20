#if os(macOS)
import Foundation
import Combine

/// Controls independently owned performance strips and onset-owned native manual voices.
/// Lo-Fi isolation remains unavailable until native qualification completes.
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
    private var windows: [ControllerChannel: (base: Int, request: String)] = [:]
    private var modeTransitions: [ControllerChannel: (previous: Bool, deadline: Double, request: String)] = [:]


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
            enabled = false; server.stop(); panic(); timer?.cancel(); timer = nil
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
                let now = ProcessInfo.processInfo.systemUptime
                if let engine {
                    for token in engine.controllerVoices.tick(now: now) { _ = onsets.release(token: token) }
                    engine.controllerVoices.refresh(engine.musicMode == .lofi ? engine.lofi.controllerInstruments : [])
                }
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
        release(onsets.releaseAll(session: session))
        guard self.session == session else { return }
        engine?.post(.controllerChopsStop); engine?.lofi.controllerDrums.stop()
        self.session = nil; connected = false
        engine?.controllerVoices.resetWindows(); windows.removeAll()
    }
    private func release(_ released: [ControllerOnsets.Onset], over duration: Double? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        for onset in released { engine?.controllerVoices.release(onset.voiceToken, over: duration, now: now) }
    }
    func panic() {
        release(onsets.releaseAll())
        engine?.post(.controllerChopsStop); engine?.lofi.controllerDrums.stop()
    }
    func reset() {
        panic()
        for channel in ControllerChannel.allCases { engine?.controllerReset(channel) }
        modeTransitions.removeAll(); windows.removeAll(); engine?.controllerVoices.resetWindows()
    }

    /// App stop/recovery calls this too. This must grow with native manual audio ownership, not transport.
    func transportDidStop() { panic(); engine?.controllerVoices.invalidate() }

    private func execute(_ command: ControllerWire.Command) -> ControllerServer.Fields {
        var reply: ControllerServer.Fields = ["type": .string("ack"), "seq": .integer(command.seq), "ok": .bool(true)]
        do {
            guard command.session == session else { throw ControllerWire.Failure.stale_session }
            try command.validate()
            guard let engine, let action = command.action else { throw ControllerWire.Failure.unavailable }
            let currentMusic = engine.musicState.read()
            let currentScale = ScaleType.allCases.indices.contains(Int(currentMusic.modeIndex)) ? ScaleType.allCases[Int(currentMusic.modeIndex)] : .major
            engine.controllerVoices.updateHarmony(tonic: Int(currentMusic.tonic), intervals: currentScale.intervals)
            // Channel identity is validated independently of whether its adapter is ready.
            if let value = command.fields["channel"] {
                guard let id = value.string.flatMap(ControllerChannel.init(rawValue:)) else { throw ControllerWire.Failure.invalid_channel }
                if ![ControllerWire.Action.reset, .all_notes_off, .note_off, .pad_off, .pressure].contains(action) && !isActive(id) { throw ControllerWire.Failure.inactive_channel }
            }
            switch action {
            case .transport:
                if try command.string("state") == "playing" { engine.start() } else { engine.stop(); panic() }
            case .snapshot: break
            case .all_notes_off:
                let channel = command.fields["channel"]?.string.flatMap(ControllerChannel.init(rawValue:))
                release(onsets.releaseAll(session: command.session, channel: channel))
                if channel == nil || channel == .chops { engine.post(.controllerChopsStop) }
                if channel == nil || channel == .drums { engine.lofi.controllerDrums.stop() }
            case .note_off, .pad_off:
                if let onset = onsets.release(session: command.session, noteID: try command.string("note_id")) { release([onset]) }
            case .pressure:
                if let onset = onsets.onset(session: command.session, noteID: try command.string("note_id")) {
                    engine.controllerVoices.pressure(onset.voiceToken, value: Float(try command.normalized()))
                }
            case .reset:
                if command.fields["scope"]?.string == "channel", let raw = command.fields["channel"]?.string,
                   let channel = ControllerChannel(rawValue: raw) {
                    release(onsets.releaseAll(channel: channel))
                    engine.controllerReset(channel)
                    modeTransitions.removeValue(forKey: channel)
                    windows.removeValue(forKey: channel); engine.controllerVoices.resetWindows(channel)
                } else { reset() }
            case .parameter:
                guard let channel = ControllerChannel(rawValue: try command.string("channel")) else { throw ControllerWire.Failure.invalid_channel }
                guard let parameter = ControllerParameter(rawValue: try command.string("parameter")) else { throw ControllerWire.Failure.invalid_parameter }
                guard let value = command.fields["value"]?.number,
                      engine.controllerSet(channel, parameter: parameter, value: value) else { throw ControllerWire.Failure.unavailable }
                reply["value"] = .number(value)
            case .mode:
                guard let channel = ControllerChannel(rawValue: try command.string("channel")) else { throw ControllerWire.Failure.invalid_channel }
                let previous = effectiveAutomatic(channel)
                let automatic = try command.string("mode") == "auto"
                guard engine.controllerSetAutomatic(channel, enabled: automatic) else { throw ControllerWire.Failure.unavailable }
                if automatic { release(onsets.releaseAll(channel: channel), over: 0.03) }
                let request = UUID().uuidString
                modeTransitions[channel] = (previous, ProcessInfo.processInfo.systemUptime + 0.03, request)
                reply["status"] = .string("pending"); reply["request_id"] = .string(request)

            case .pad_window:
                guard let channel = ControllerChannel(rawValue: try command.string("channel")) else { throw ControllerWire.Failure.invalid_channel }
                let music = engine.musicState.read()
                let scale = ScaleType.allCases.indices.contains(Int(music.modeIndex)) ? ScaleType.allCases[Int(music.modeIndex)] : .major
                try engine.controllerVoices.setWindow(channel, base: Int(try command.integer("base_midi", in: 0...127)),
                                                      tonic: Int(music.tonic), intervals: scale.intervals)
                let request = UUID().uuidString
                windows[channel] = (Int(try command.integer("base_midi", in: 0...127)), request)
                reply["status"] = .string(ControllerVoiceBank.ambient.contains(channel) ? "applied" : "pending")
                reply["request_id"] = .string(request)
            case .note_on:
                guard engine.isRunning && engine.isPlaybackReady else { throw ControllerWire.Failure.not_playing }
                guard let channel = ControllerChannel(rawValue: try command.string("channel")) else { throw ControllerWire.Failure.invalid_channel }
                if effectiveAutomatic(channel) || engine.controllerStrips(channel).first?.automatic != false { throw ControllerWire.Failure.wrong_mode }
                guard engine.controllerModeReady(channel) else { throw ControllerWire.Failure.not_ready }
                engine.controllerVoices.refresh(engine.musicMode == .lofi ? engine.lofi.controllerInstruments : [])
                let noteID = try command.string("note_id")
                guard onsets.onset(session: command.session, noteID: noteID) == nil else { throw ControllerWire.Failure.bad_message }
                let instrumentRevision = try command.integer("instrument_revision", in: 0...Int64.max)
                let voice = try engine.controllerVoices.noteOn(channel: channel,
                    midi: Int(try command.integer("midi", in: 0...127)),
                    velocity: Float(try command.integer("velocity", in: 1...127)) / 127,
                    revision: instrumentRevision, now: ProcessInfo.processInfo.systemUptime)
                for token in voice.stolen { _ = onsets.release(token: token) }
                do {
                    try onsets.insert(.init(session: command.session, noteID: noteID, channel: channel,
                        instrumentRevision: instrumentRevision, bankRevision: nil, voiceToken: voice.token))
                } catch {
                    engine.controllerVoices.release(voice.token, now: ProcessInfo.processInfo.systemUptime)
                    throw error
                }
            case .drum_select, .drum_next:
                guard engine.musicMode == .lofi else { throw ControllerWire.Failure.inactive_channel }
                guard engine.isRunning && engine.isPlaybackReady, let info = engine.lofi.stateBus.transport() else { throw ControllerWire.Failure.not_playing }
                let request = try engine.lofi.controllerDrums.select(action == .drum_select ? command.string("choice_id") : nil, info: info)
                reply["status"] = .string("pending"); reply["request_id"] = .string(request)
            case .pad_on:
                guard engine.isRunning && engine.isPlaybackReady else { throw ControllerWire.Failure.not_playing }
                guard let channel = ControllerChannel(rawValue: try command.string("channel")) else { throw ControllerWire.Failure.invalid_channel }
                guard !effectiveAutomatic(channel), engine.controllerStrips(channel).first?.automatic == false else { throw ControllerWire.Failure.wrong_mode }
                let pad = Int(try command.integer("pad", in: 0...63))
                let bankRevision = try command.integer("bank_revision", in: 0...Int64.max)
                let noteID = try command.string("note_id")
                guard onsets.onset(session: command.session, noteID: noteID) == nil else { throw ControllerWire.Failure.bad_message }
                guard onsets.held.count < 48 else { throw ControllerWire.Failure.overloaded }
                let velocity = Float(try command.integer("velocity", in: 1...127)) / 127
                guard let info = engine.lofi.stateBus.transport() else { throw ControllerWire.Failure.not_ready }
                if channel == .chops {
                    let state = engine.archive.controllerDialogue.read()
                    guard bankRevision == state.revision else { throw ControllerWire.Failure.stale_bank }
                    guard let bank = state.bank, bank.transportRevision == info.revision,
                          bank.pads.contains(where: { $0.index == pad }) else { throw ControllerWire.Failure.not_ready }
                    let now = ProcessInfo.processInfo.systemUptime
                    let beat = ceil((now + engine.lofi.controllerLaunchMargin - info.origin) / (info.beatDuration * 0.25)) * 0.25
                    let start = info.origin + beat * info.beatDuration
                    guard start < bank.end else { throw ControllerWire.Failure.not_ready }
                    let token = UUID()
                    try onsets.insert(.init(session: command.session, noteID: noteID, channel: channel,
                        instrumentRevision: 0, bankRevision: bankRevision, voiceToken: token))
                    engine.post(.controllerChop(bank: bankRevision, pad: pad,
                        velocity: velocity, start: start, token: token))
                    reply["status"] = .string("pending"); reply["effective_beat"] = .number(beat)
                } else if channel == .drums {
                    guard bankRevision == 1 else { throw ControllerWire.Failure.stale_bank }
                    let choices = engine.lofi.controllerDrums.choices
                    guard choices.indices.contains(pad), engine.lofi.controllerDrums.readyChoices.contains(choices[pad].id) else { throw ControllerWire.Failure.not_ready }
                    let request = try engine.lofi.controllerDrums.select(choices[pad].id, info: info, launch: true)
                    try onsets.insert(.init(session: command.session, noteID: noteID, channel: channel,
                        instrumentRevision: 0, bankRevision: bankRevision, voiceToken: UUID()))
                    reply["status"] = .string("pending"); reply["request_id"] = .string(request)
                } else { throw ControllerWire.Failure.unavailable }
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

    private func effectiveAutomatic(_ channel: ControllerChannel) -> Bool {
        if let transition = modeTransitions[channel], ProcessInfo.processInfo.systemUptime < transition.deadline { return transition.previous }
        return engine?.controllerStrips(channel).first?.automatic ?? true
    }

    private func modeTransition(_ channel: ControllerChannel) -> ControllerWire.Value {
        guard let transition = modeTransitions[channel] else { return .null }
        return .object(["request_id": .string(transition.request),
                        "status": .string(ProcessInfo.processInfo.systemUptime < transition.deadline ? "applying" : "applied"),
                        "mode": .string(engine?.controllerStrips(channel).first?.automatic == false ? "manual" : "auto")])
    }

    private func isActive(_ id: ControllerChannel) -> Bool {
        guard let engine else { return false }
        if id == .film { return engine.archive.controllerDialogue.read().film } // Film capability waits for actual cue publication, never inferred from a setting.
        return id.rawValue.hasPrefix(engine.musicMode == .lofi ? "lofi." : "ambient.")
    }

    private func bankState(_ channel: ControllerChannel) -> ControllerWire.Value? {
        guard let engine else { return nil }
        if channel == .chops {
            let state = engine.archive.controllerDialogue.read()
            guard let bank = state.bank, bank.transportRevision == engine.lofi.stateBus.transport()?.revision else { return nil }
            return .object(["revision": .integer(state.revision), "bank_id": .string(String(bank.bankID)),
                "cue_token": .string(String(bank.cueToken)), "plan_revision": .integer(Int64(bank.planRevision)),
                "transport_revision": .integer(Int64(bank.transportRevision)),
                "effective_beat": engine.lofi.stateBus.transport().map { .number((bank.activation - $0.origin) / $0.beatDuration) } ?? .null,
                "pads": .array(bank.pads.map { .object(["index": .integer(Int64($0.index)), "label": .string($0.index == 63 ? "Whole line" : $0.role.capitalized),
                    "kind": .string($0.role), "ready": .bool(true), "play_mode": .string("one_shot"), "beats": .number($0.beats)]) })])
        }
        if channel == .drums, !engine.lofi.controllerDrums.readyChoices.isEmpty {
            return .object(["revision": .integer(1), "bank_id": .string("drum-choices"), "cue_token": .null, "effective_beat": .null,
                "pads": .array(engine.lofi.controllerDrums.choices.enumerated().map { .object(["index": .integer(Int64($0.offset)),
                    "label": .string($0.element.label), "kind": .string("loop"), "ready": .bool(engine.lofi.controllerDrums.readyChoices.contains($0.element.id)), "play_mode": .string("latch"), "beats": .number(64)]) })])
        }
        return nil
    }

    private func snapshot() -> ControllerServer.Fields {
        revision += 1
        engine?.controllerVoices.refresh(engine?.musicMode == .lofi ? (engine?.lofi.controllerInstruments ?? []) : [])
        let music = engine?.musicState.read() ?? MusicState()
        let transport = engine?.musicState.transport()
        let scale = ScaleType.allCases.indices.contains(Int(music.modeIndex)) ? ScaleType.allCases[Int(music.modeIndex)] : .major
        engine?.controllerVoices.updateHarmony(tonic: Int(music.tonic), intervals: scale.intervals)
        let channels: [ControllerWire.Value] = ControllerChannel.allCases.map { id in
            let instrument = engine?.controllerVoices.instrument(id)
            let padBank = bankState(id)
            let hasPads = padBank.map { _ in true } ?? false
            let melodicReady = engine?.controllerModeReady(id) == true && instrument?.ready == true
            let ready = isActive(id) && (melodicReady || (engine?.controllerModeReady(id) == true && hasPads))
            let pendingWindow: ControllerWire.Value
            if let window = windows[id] {
                let status = instrument?.base == window.base && instrument?.ready == true ? "applied"
                    : (engine?.controllerVoices.preparationError == nil ? "preparing" : "failed")
                pendingWindow = .object(["request_id": .string(window.request), "base_midi": .integer(Int64(window.base)), "status": .string(status)])
            } else { pendingWindow = .null }
            let parameters: [ControllerWire.Value] = ControllerParameter.allCases.map { p in
                .object(["id": .string(p.rawValue), "label": .string(p.label), "value": .number(engine?.controllerStrips(id).first?.values[p] ?? p.defaultValue),
                         "default": .number(p.defaultValue), "display": .string(p.display(engine?.controllerStrips(id).first?.values[p] ?? p.defaultValue)), "enabled": .bool(isActive(id) && engine?.controllerMixReady(id) == true)])
            }
            return .object(["id": .string(id.rawValue), "label": .string(id.label), "kind": .string(id.kind),
                            "active": .bool(isActive(id)), "mode": .string(effectiveAutomatic(id) ? "auto" : "manual"), "pending_mode": modeTransition(id), "ready": .bool(ready),
                            "mix_ready": .bool(engine?.controllerMixReady(id) == true),
                            "mode_ready": .bool(engine?.controllerModeReady(id) == true),
                            "status": .string(ready ? "Ready" : (engine?.controllerVoices.preparationError ?? "Preparing or awaiting native qualification")),
                            "instrument": .string(instrument?.name ?? "Unavailable"),
                            "instrument_revision": .integer(instrument?.revision ?? 0),
                            "base_midi": .integer(Int64(instrument?.base ?? (id == .bass ? 24 : 36))),
                            "root_midi": .integer(60 + Int64(music.tonic)),
                            "octave_offset": .integer(Int64(((instrument?.base ?? (36 + Int(music.tonic))) - 36 - Int(music.tonic)) / 12)),
                            "pending_window": pendingWindow,
                            "parameters": .array(parameters), "pad_bank": padBank ?? .null])
        }
        let manualReady = ControllerVoiceBank.melodic.contains { id in
            isActive(id) && engine?.controllerModeReady(id) == true && engine?.controllerVoices.instrument(id).ready == true
        }
        let manualPadsReady = [ControllerChannel.chops, .drums].contains { isActive($0) && bankState($0).map { _ in true } == true }
        let playing = engine?.isRunning == true
        return ["type": .string("state"), "revision": .integer(revision),
                "capabilities": .object(["transport": .bool(true), "snapshot": .bool(true), "performance_audio": .bool(manualReady || manualPadsReady),
                                          "channel_mix": .bool(true), "channel_effects": .bool(true),
                                          "automatic_gates": .bool(true), "manual_notes": .bool(manualReady),
                                          "manual_pads": .bool(manualPadsReady), "drum_selection": .bool(engine?.musicMode == .lofi),
                                          "film_mix": .bool(engine?.archive.controllerDialogue.read().film == true),
                                          "isolated_lofi_wet": .bool(LofiBus.isolatedPreparationQualified)]),
                "transport": .object(["state": .string(playing ? "playing" : "stopped"),
                                      "ready": .bool(engine?.isPlaybackReady == true),
                                      "music_mode": .string(engine?.musicMode == .lofi ? "lofi" : "ambient"),
                                      "bpm": .number(transport.map { 60 / $0.beatDuration } ?? 0),
                                      "beat": .number(transport.map { max(0, (ProcessInfo.processInfo.systemUptime - $0.origin) / $0.beatDuration) } ?? 0),
                                      "take_index": .integer(Int64(transport?.takeIndex ?? 0)),
                                      "transport_revision": .integer(Int64(transport?.revision ?? 0))]),
                "harmony": .object(["root_midi": .integer(60 + Int64(music.tonic)), "tonic": .integer(Int64(music.tonic)), "scale_name": .string(scale.rawValue),
                                    "pitch_classes": .array((0..<12).filter { music.scaleMask & (1 << (($0 + Int(music.tonic)) % 12)) != 0 }.map { .integer(Int64($0)) })]),
                "channels": .array(channels), "drums": engine?.lofi.controllerDrums.wire ?? .null]
    }
}
#endif
