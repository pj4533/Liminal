import Foundation
import Synchronization

/// Controls for the film's sound, posted from any thread and drained at the start of every `advance`.
nonisolated enum ArchiveControl {
    /// Start a decoded segment, fade it out, or change its level ("Footage audio").
    case begin(ArchiveVoice.Cue), end(fade: Double), gain(Float)
    /// A dialogue performance for a cue: stored, then queued incrementally on the chop timeline.
    case chops(ArchiveVoice.ChopPlan)
    /// The footage service abandoned cue `token` after its dialogue work started (the bed never began,
    /// or footage stopped): its stored chops are dropped and later plans for it ignored.
    case cancelChops(token: Int)
}

/// The clock of the film's sound: modulates the archive voice and its mix bus at 10 Hz and updates the
/// chop ducks on every 20 ms step. Runs on its own serial queue in realtime (`DispatchSourceTimer`);
/// offline renders call `advance(to:)` directly from the render loop. Never touches MainActor.
nonisolated final class ArchiveConductor: @unchecked Sendable {
    let queue = DispatchQueue(label: "liminal.music", qos: .userInitiated)

    private let mix: ArchiveMixBus
    private let voice: ArchiveVoice
    private let archiveActivityBits = Atomic<UInt32>(0)
    /// Speech activity of the playing cue, 0...1 (any thread).
    var archiveActivity: Float { Float(bitPattern: archiveActivityBits.load(ordering: .relaxed)) }
    private let inboxLock = NSLock()
    private var inbox: [ArchiveControl] = []

    /// Bed master gain once the conductor begins (faded in over 3 s).
    static let masterGain: Float = dbToGain(6)

    // Clock
    private var now = 0.0
    private var timer: DispatchSourceTimer?
    private var startUptime: UInt64 = 0
    private var runToken = 0
    private var lastModulate = -1.0
    private(set) var began = false
    private var realtime = false
    private var stopping = false

    init(mix: ArchiveMixBus, voice: ArchiveVoice) {
        self.mix = mix
        self.voice = voice
    }

    // MARK: - Realtime

    func start(beatDuration: Double, pattern: ArchiveMixBus.EchoPattern = .straight) {
        queue.async { [self] in
            runToken += 1
            voice.setBeatLocked(true)
            voice.setEchoTempo(beatDuration)
            mix.syncEcho(beatDuration: beatDuration, pattern: pattern, now: now)
            if began, !stopping { return }
            stopping = false
            timer?.cancel(); timer = nil
            realtime = true
            startUptime = DispatchTime.now().uptimeNanoseconds &- UInt64(now * 1e9)
            begin(at: now)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                let now = Double(DispatchTime.now().uptimeNanoseconds &- self.startUptime) / 1e9
                self.advance(to: now)
            }
            timer = t
            t.resume()
        }
    }

    /// Each phrase of the transport: the echoes follow its tempo and the phrase's echo pattern.
    func updateTempo(beatDuration: Double, phrase: Int, seed: UInt64) {
        queue.async { [self] in
            guard began, !stopping else { return }
            voice.setEchoTempo(beatDuration)
            voice.notePhrase(phrase, beatDuration: beatDuration, now: now)
            mix.syncEcho(beatDuration: beatDuration, pattern: .choose(seed: seed, phrase: phrase), now: now)
        }
    }

    /// Fades the bed out; the clock stops and the voice resets half a second after the fade unless the
    /// conductor was started again in the meantime.
    func stop(fade: Double = 2.0) {
        queue.async { [self] in
            runToken += 1
            let token = runToken
            stopping = true
            voice.end(fade: fade, now: now)
            archiveActivityBits.store(0, ordering: .relaxed)
            mix.setMaster(0, over: fade)
            queue.asyncAfter(deadline: .now() + fade + 0.5) { [self] in
                guard token == runToken else { return }
                timer?.cancel(); timer = nil
                voice.reset(now: now)
                began = false
            }
        }
    }

    /// Any thread. Lock-protected inbox, drained in `advance`.
    func post(_ control: ArchiveControl) {
        inboxLock.lock(); inbox.append(control); inboxLock.unlock()
    }

    // MARK: - Offline

    /// Offline start at conductor time 0 on the calling thread (no timer, no queue).
    func beginOffline(beatDuration: Double, pattern: ArchiveMixBus.EchoPattern = .straight) {
        realtime = false
        voice.setBeatLocked(true)
        voice.setEchoTempo(beatDuration)
        mix.syncEcho(beatDuration: beatDuration, pattern: pattern)
        begin(at: 0)
    }

    // MARK: - Core

    private func begin(at t: Double) {
        now = t
        voice.reset(now: t)
        began = true
        drainInbox()
        mix.applyRoom(over: 0.05)
        mix.setMaster(Self.masterGain, over: 3)
        lastModulate = -1
    }

    func advance(to time: Double) {
        #if DEBUG
        if realtime { dispatchPrecondition(condition: .notOnQueue(.main)) }
        #endif
        drainInbox()
        guard began else { return }
        now = max(now, time)
        if time - lastModulate >= 0.0999 {
            lastModulate = time
            voice.modulate(t: time)
            archiveActivityBits.store(voice.speechActivity.bitPattern, ordering: .relaxed)
            mix.modulate(t: time)
        }
        // The music and bed ducks under featured chops follow every step.
        voice.updateDucks(at: time)
    }

    private func drainInbox() {
        inboxLock.lock()
        guard !inbox.isEmpty else { inboxLock.unlock(); return }
        let items = inbox
        inbox.removeAll(keepingCapacity: true)
        inboxLock.unlock()
        for c in items { apply(c) }
    }

    private func apply(_ c: ArchiveControl) {
        switch c {
        case .begin(let cue): if began && !stopping { voice.begin(cue, now: now) }
        case .end(let fade): voice.end(fade: fade, now: now)
        case .gain(let g): voice.setGain(g)
        case .chops(let plan): if began && !stopping { voice.perform(plan, now: now) }
        case .cancelChops(let token): voice.cancelChops(token: token)
        }
    }
}
