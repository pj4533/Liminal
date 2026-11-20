import AudioKit
import AudioKitEX
import AVFoundation
import Foundation

/// Small immutable timbre messages cross the conductor/main boundary, never its mutable RNG/context.
nonisolated final class ControllerAmbientTimbres: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ControllerChannel: ControllerAmbientTimbre] = [:]
    func publish(_ values: [ControllerChannel: ControllerAmbientTimbre]) {
        lock.lock(); self.values = values; lock.unlock()
    }
    func read(_ channel: ControllerChannel) -> ControllerAmbientTimbre? {
        lock.lock(); defer { lock.unlock() }; return values[channel]
    }
    static func channel(_ id: LayerID) -> ControllerChannel? {
        switch id {
        case .drone: return .drone
        case .pad: return .pad
        case .lead: return .ambientLead
        case .keys: return .keys
        case .drips: return .drips
        case .air: return .air
        case .grains: return .grains
        case .pluck: return .pluck
        default: return nil
        }
    }
}

/// MainActor owns allocation, scheduling and release. PCM and all native graph nodes already exist
/// before onset. Retiring slots retain the original PCM until their release ends.
@MainActor
final class ControllerVoiceBank {
    static let ambient: [ControllerChannel] = [.drone, .pad, .ambientLead, .keys, .drips, .air, .grains, .pluck]
    static let melodic = ambient + [.bass, .lead, .mids]
    @MainActor private final class Slot {
        let channel: ControllerChannel
        let ambient: ControllerAmbientVoice?
        let player: ArchiveVoice.BufferSource?
        let envelope: Fader?
        let pressure: Fader?
        let returns: ControllerLofiReturns?
        var token: UUID?
        var pcm: ControllerNotePCM?
        var timbre: ControllerAmbientTimbre?
        var midi = 60
        var velocity: Float = 0
        var started = 0.0
        var startAt: Double?
        var freeAt: Double?
        var decayStage = 0
        var pressureValue: Float = 1
        init(channel: ControllerChannel) {
            self.channel = channel
            if ControllerVoiceBank.ambient.contains(channel) {
                ambient = ControllerAmbientVoice(channel: channel)
                player = nil; envelope = nil; pressure = nil; returns = nil
            } else {
                ambient = nil
                let player = ArchiveVoice.BufferSource()
                self.player = player
                let envelope = Fader(player, gain: 0)
                self.envelope = envelope
                let pressure = Fader(envelope, gain: 1)
                self.pressure = pressure; returns = ControllerLofiReturns(pressure)
            }
        }
        var output: Node { ambient?.output ?? pressure! }
        func fade(_ duration: Double) {
            ambient?.release(over: duration); returns?.release(over: duration)
            if let envelope { ParamRamp.setGain(envelope, 0, over: duration) }
        }
        func stop() { ambient?.stop(); player?.player.stop(); returns?.stop(); pcm = nil; timbre = nil; token = nil; freeAt = nil; startAt = nil }
    }
    private let timbres: ControllerAmbientTimbres
    private var slots: [Slot] = []
    private var owned: [UUID: Slot] = [:]
    private var allocation = ControllerVoiceAllocation()
    private let cache = ControllerLofiCache()
    private var preparation: Task<Void, Never>?
    private var preparingKey: String?
    private var prepared: [ControllerLofiCache.Bank] = []
    private var requestedBases: [ControllerChannel: Int] = [.bass: 24, .lead: 36, .mids: 36]
    private var bases: [ControllerChannel: Int] = [:]
    private var tonic = 0
    private var scaleIntervals = ScaleType.major.intervals
    private var lofiTonic = 0
    private var revisions: [ControllerChannel: Int64] = [:]
    private var ambientPrograms: [ControllerChannel: String] = [:]
    private var failedKey: String?
    private var maintenance: Task<Void, Never>?
    private var activeKey: String?
    private var activeBank: ControllerLofiCache.Bank?
    private(set) var preparationError: String?
    private var epoch = 0

    init(inputs: [ControllerChannel: Mixer], wetInputs: [ControllerChannel: Mixer] = [:], timbres: ControllerAmbientTimbres) {
        self.timbres = timbres
        for channel in Self.melodic {
            guard let input = inputs[channel] else { continue }
            // Eight sounding + two retiring slots per melodic channel, monophonic bass + two tails.
            for _ in 0..<(channel == .bass ? 3 : 10) {
                let slot = Slot(channel: channel)
                slots.append(slot); input.addInput(slot.output)
                if let returns = slot.returns { wetInputs[channel]?.addInput(returns.output) }
            }
            bases[channel] = channel == .bass ? 24 : 36
            revisions[channel] = 1
        }
    }

    func instrument(_ channel: ControllerChannel) -> (name: String, revision: Int64, base: Int, ready: Bool) {
        if Self.ambient.contains(channel) {
            let name = timbres.read(channel)?.name
            if let name, ambientPrograms[channel] != name {
                ambientPrograms[channel] = name; revisions[channel, default: 1] += 1
            }
            return (name ?? "Preparing", revisions[channel] ?? 1, bases[channel] ?? 36,
                    timbres.read(channel) != nil && ControllerPadWindow.pitches(
                        base: bases[channel] ?? 36, tonic: tonic, intervals: scaleIntervals) != nil)
        }
        guard Self.melodic.contains(channel) else { return ("Unavailable", 0, 36, false) }
        let score = activeBank?.instrument.score
        let name = channel == .bass ? score.map { "\($0.bassVoice)" } : score?.preset.name
        return (name ?? "Preparing", revisions[channel] ?? 1, bases[channel] ?? 36,
                activeBank?.notes[channel] != nil && activeBank?.instrument.key == activeKey)
    }

    func updateHarmony(tonic: Int, intervals: [Int]) {
        guard tonic != self.tonic || intervals != scaleIntervals else { return }
        for channel in Self.ambient {
            bases[channel, default: 36] += tonic - self.tonic
            revisions[channel, default: 1] += 1
        }
        self.tonic = tonic; scaleIntervals = intervals
    }

    func setWindow(_ channel: ControllerChannel, base: Int, tonic: Int, intervals: [Int]) throws {
        guard Self.melodic.contains(channel) else { throw ControllerWire.Failure.unavailable }
        guard ControllerPadWindow.pitches(base: base, tonic: tonic, intervals: intervals) != nil else {
            throw ControllerWire.Failure.out_of_range
        }
        if Self.ambient.contains(channel) { bases[channel] = base; revisions[channel, default: 1] += 1 }
        else { requestedBases[channel] = base }
    }

    /// Called with actual current/queued phrase metadata. Never use advancing nominal phrase numbers.
    func refresh(_ instruments: [ControllerLofiInstrument]) {
        guard let current = instruments.first else { activeBank = nil; activeKey = nil; return }
        if current.score.tonic != lofiTonic {
            for channel in [ControllerChannel.bass, .lead, .mids] {
                requestedBases[channel, default: channel == .bass ? 24 : 36] += current.score.tonic - lofiTonic
            }
            lofiTonic = current.score.tonic
        }
        if current.key != activeKey {
            activeKey = current.key; activeBank = nil
            for channel in [ControllerChannel.bass, .lead, .mids] {
                bases[channel] = requestedBases[channel]; revisions[channel, default: 1] += 1
            }
        }
        let key = current.key + ControllerLofiCache.windowKey(requestedBases)
        if let bank = prepared.first(where: { $0.key == key }), activeBank?.key != key {
            activeBank = bank
            for channel in [ControllerChannel.bass, .lead, .mids] {
                bases[channel] = bank.bases[channel]; revisions[channel, default: 1] += 1
            }
        }
        let targets = instruments.prefix(2).map { instrument in
            var bases = requestedBases
            for channel in [ControllerChannel.bass, .lead, .mids] {
                bases[channel, default: channel == .bass ? 24 : 36] += instrument.score.tonic - lofiTonic
            }
            return (instrument, instrument.key + ControllerLofiCache.windowKey(bases), bases)
        }
        guard preparation == nil, let target = targets.first(where: { item in
            item.1 != failedKey && !prepared.contains { $0.key == item.1 }
        }) else { return }
        let token = epoch, bases = target.2
        preparingKey = target.1
        preparation = Task(priority: .utility) { [weak self, cache] in
            do {
                let bank = try await cache.prepare(target.0, bases: bases)
                guard let self, !Task.isCancelled, epoch == token else { return }
                prepared.removeAll { $0.key == bank.key }
                prepared.append(bank)
                if prepared.count > 2 { prepared.removeFirst() }
                preparationError = nil; failedKey = nil
            } catch {
                guard let self, !Task.isCancelled, epoch == token else { return }
                preparationError = "Manual instrument preparation failed"; failedKey = target.1
            }
            guard let self, epoch == token else { return }
            preparation = nil; preparingKey = nil
        }
    }

    func noteOn(channel: ControllerChannel, midi: Int, velocity: Float, revision: Int64,
                now: Double) throws -> (token: UUID, stolen: [UUID]) {
        guard (0...127).contains(midi), velocity.isFinite, velocity > 0, velocity <= 1 else {
            throw ControllerWire.Failure.out_of_range
        }
        let info = instrument(channel)
        guard info.ready else { throw ControllerWire.Failure.not_ready }
        guard revision == info.revision else { throw ControllerWire.Failure.stale_instrument }
        let timbre = timbres.read(channel)
        let pcm = activeBank?.notes[channel]?[midi]
        if !Self.ambient.contains(channel), pcm == nil { throw ControllerWire.Failure.not_ready }
        let candidates = slots.filter { $0.channel == channel }
        guard let slot = candidates.first(where: { $0.token == nil }) ?? candidates.min(by: { $0.started < $1.started }) else {
            throw ControllerWire.Failure.overloaded
        }
        let (voice, removed) = allocation.take(channel: channel, now: now)
        var stolen = removed.map(\.token)
        for token in stolen { release(token, over: 0.02, now: now) }
        let replacing = slot.token
        if let replacing {
            if !stolen.contains(replacing) { stolen.append(replacing) }
            release(replacing, over: 0.02, now: now)
        }
        let wait = slot.freeAt != nil || replacing != nil
        if wait { slot.fade(0.02) }
        slot.token = voice.token; slot.midi = midi; slot.velocity = velocity
        // Preserve outgoing PCM until its fade finishes, then swap references at the reserved onset.
        // Pending ownership captures immutable assets in the slot's onset closure below.
        slot.started = now; slot.decayStage = 0; slot.freeAt = nil; slot.pressureValue = 1
        owned[voice.token] = slot
        if wait {
            slot.startAt = now + 0.025
            pending[voice.token] = (pcm, timbre)
        } else {
            slot.pcm = pcm; slot.timbre = timbre
            start(slot, now: now)
        }
        ensureMaintenance()
        return (voice.token, stolen)
    }
    private var pending: [UUID: (ControllerNotePCM?, ControllerAmbientTimbre?)] = [:]

    private func start(_ slot: Slot, now: Double) {
        slot.startAt = nil; slot.started = now
        if let ambient = slot.ambient, let timbre = slot.timbre {
            ambient.start(midi: slot.midi, velocity: slot.velocity, timbre: timbre)
            ambient.pressure(slot.pressureValue)
        }
        if let player = slot.player, let pcm = slot.pcm, let envelope = slot.envelope {
            player.player.stop()
            slot.returns?.start(preset: pcm.preset, beat: pcm.beatDuration, bass: slot.channel == .bass)
            player.player.scheduleBuffer(pcm.attack)
            if let sustain = pcm.sustain { player.player.scheduleBuffer(sustain, options: .loops) }
            ParamRamp.setGain(slot.pressure!, slot.pressureValue, over: 0.025)
            ParamRamp.setGain(envelope, slot.velocity, over: 0.004)
            player.player.play()
        }
    }

    func pressure(_ token: UUID, value: Float) {
        guard let slot = owned[token], slot.token == token else { return }
        slot.pressureValue = value
        guard slot.startAt == nil else { return }
        // Independent of the amplitude envelope: pressure cannot resurrect a decayed/released note.
        slot.ambient?.pressure(value)
        if let pressure = slot.pressure { ParamRamp.setGain(pressure, value, over: 0.03) }
    }
    func release(_ token: UUID, over duration: Double? = nil, now: Double) {
        guard let slot = owned.removeValue(forKey: token), slot.token == token else { return }
        _ = allocation.release(token)
        pending.removeValue(forKey: token)
        let release = duration ?? slot.pcm?.release ?? slot.timbre?.release ?? 0.07
        slot.startAt = nil; slot.fade(release)
        slot.freeAt = now + release + 0.025
        ensureMaintenance()
    }
    func tick(now: Double) -> [UUID] {
        let expired = allocation.expire(now: now).map(\.token)
        for token in expired { release(token, now: now) }
        maintain(now: now)
        return expired
    }
    private func ensureMaintenance() {
        guard maintenance == nil else { return }
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
                guard let self else { return }
                maintain(now: ProcessInfo.processInfo.systemUptime)
                if slots.allSatisfy({ $0.token == nil }) { maintenance = nil; return }
            }
        }
    }
    private func maintain(now: Double) {
        for slot in slots {
            if let token = slot.token, let start = slot.startAt, now >= start, let assets = pending.removeValue(forKey: token) {
                slot.ambient?.stop(); slot.player?.player.stop()
                slot.pcm = assets.0; slot.timbre = assets.1
                self.start(slot, now: now)
            }
            if let free = slot.freeAt, now >= free { slot.stop() }
            guard let token = slot.token, owned[token] != nil, slot.startAt == nil else { continue }
            let age = now - slot.started
            if let timbre = slot.timbre, let decay = timbre.decay, age >= timbre.attack {
                if slot.decayStage == 0 {
                    slot.ambient?.decay(timbre: timbre, over: decay); slot.decayStage = 1
                }
            }
            if let pcm = slot.pcm, pcm.decayDBPerSecond > 0, let envelope = slot.envelope {
                let gain = slot.velocity * Float(pow(10, -pcm.decayDBPerSecond * age / 20))
                ParamRamp.setGain(envelope, gain, over: 0.12)
            }
        }
    }
    func resetWindows(_ channel: ControllerChannel? = nil) {
        for id in Self.melodic where channel == nil || channel == id {
            let base = (id == .bass ? 24 : 36) + (Self.ambient.contains(id) ? tonic : lofiTonic)
            if Self.ambient.contains(id) { bases[id] = base; revisions[id, default: 1] += 1 }
            else { requestedBases[id] = base }
        }
    }
    func invalidate() {
        epoch += 1; preparation?.cancel(); preparation = nil; preparingKey = nil
        prepared.removeAll(); activeBank = nil; activeKey = nil; failedKey = nil; preparationError = nil
        for token in Array(owned.keys) { release(token, over: 0.03, now: ProcessInfo.processInfo.systemUptime) }
    }
}
