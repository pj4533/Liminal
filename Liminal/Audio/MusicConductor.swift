import AudioKit
import Foundation
import OSLog

/// Controls posted from any thread; drained at the start of every `advance`.
nonisolated enum MusicControl {
    case density(Float), space(Float), delayAmount(Float), style(MusicStyle.ID)
    case pinScale(ScaleType?)                       // nil = auto (evolving)
    case visualMood(VisualMood), imageDidChange(transition: Double), visualActivity(Float)
    case limiterBypass(Bool)
}

/// Owns time, randomness, harmony, scenes and layers (decisions D3-D6). Runs on its own serial queue in
/// realtime (20 ms `DispatchSourceTimer`); offline renders call `advance(to:)` directly from the render
/// loop. Never touches MainActor.
nonisolated final class MusicConductor: @unchecked Sendable {
    let stateBus = MusicStateBus()
    let queue = DispatchQueue(label: "liminal.music", qos: .userInitiated)

    private let scheduler = MusicScheduler()
    private let harmony: HarmonyEngine
    private let director: SceneDirector
    private let layers: [MusicLayer]
    private let mix: MixBus
    private let ctx: LayerContext
    private var rng: SeededRNG
    private var colorDrift: ParameterDrift.Channel

    // Form
    private var scenes: [MusicScene] = []          // current plus the next one during a handoff
    private var sceneCount = 0
    private var lastKeyMove = 0.0
    private var keyInterval = 300.0
    private var chordStart = 0.0
    private var chordToken = 0
    private var hysteresis: [LayerID: Bool] = [:]

    // Controls
    private var density: Float = 0.5
    private var space: Float = 0.5
    private var delayAmount: Float = 0.5
    private var moodTarget = VisualMood()
    private var mood = VisualMood()
    private var activityTarget: Float = 0.5
    private var lastImageChange = -1000.0
    private var styleID: MusicStyle.ID = .drift
    private let inboxLock = NSLock()
    private var inbox: [MusicControl] = []

    // State out
    private var state = MusicState()
    private var eventSeq: UInt32 = 0

    // Clock
    private var timer: DispatchSourceTimer?
    private var startUptime: UInt64 = 0
    private var timeOffset = 0.0
    private var runToken = 0
    private var lastModulate = -1.0
    private var sessionStart = 0.0
    private var modulateCount = 0
    private(set) var began = false
    private var realtime = false

    // Perf
    private var tickCount = 0
    private var tickTotalNs: UInt64 = 0
    private var tickMaxNs: UInt64 = 0

    /// Offline only: timeline of scenes, layers, chords, keys and events.
    var scoreLog: ScoreLog?
    /// Called for every note (conductor queue). The facade forwards drips notes to `shimmerNotePlayed`.
    var onNote: ((LayerID, Int) -> Void)?

    init(layers: [MusicLayer], mix: MixBus, seed: UInt64, pinned: ScaleType?) {
        let root = SeededRNG(seed: seed)
        rng = root.fork(1)
        let style = MusicStyle.drift
        harmony = HarmonyEngine(rng: root.fork(2), palette: style.palette, pinned: pinned)
        director = SceneDirector(rng: root.fork(3), style: style)
        self.layers = layers
        self.mix = mix
        ctx = LayerContext(scheduler: scheduler, harmony: harmony)
        var r = root.fork(4)
        colorDrift = ParameterDrift.Channel(period: r.range(80...120), phase: r.range(0...6))
        for (i, l) in layers.enumerated() { l.prepare(rng: root.fork(100 + UInt64(l.id.rawValue) * 7 + UInt64(i))) }
        ctx.setEmitter { [unowned self] kind, layer, midi, vel in self.emit(kind, layer: layer, midi: midi, velocity: vel) }
    }

    private var available: Set<LayerID> { Set(layers.map(\.id)) }

    /// Current harmonic field (conductor queue / offline thread only).
    var field: HarmonicField { harmony.field }

    // MARK: - Realtime

    func start() {
        queue.async { [self] in
            runToken += 1
            timer?.cancel(); timer = nil
            realtime = true
            timeOffset = scheduler.now
            startUptime = DispatchTime.now().uptimeNanoseconds &- UInt64(timeOffset * 1e9)
            stateBus.setStartUptime(startUptime)
            begin(at: timeOffset)
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

    func stop(fade: Double = 2.0) {
        queue.async { [self] in
            runToken += 1
            let token = runToken
            for l in layers { l.silence(fade: fade, ctx: ctx) }
            mix.setMaster(0, over: fade)
            queue.asyncAfter(deadline: .now() + fade + 0.5) { [self] in
                guard token == runToken else { return }
                timer?.cancel(); timer = nil
                scheduler.cancelAll()
                for l in layers { l.powerDown() }
                began = false
            }
        }
    }

    /// Any thread. Lock-protected inbox, drained in `advance`.
    func post(_ control: MusicControl) {
        inboxLock.lock(); inbox.append(control); inboxLock.unlock()
    }

    // MARK: - Offline

    /// Offline start at conductor time 0 on the calling thread (no timer, no queue).
    func beginOffline() {
        realtime = false
        begin(at: 0)
    }

    // MARK: - Core

    private func begin(at t: Double) {
        scheduler.reset(to: t)
        drainInbox()
        scenes.removeAll()
        hysteresis.removeAll()
        for l in layers { l.silence(fade: 0, ctx: ctx) }
        mix.setSpace(space, delayAmount: delayAmount, brightness: 0.5, over: 0.05)
        ctx.delayScale = mix.delaySendScale
        mix.setMaster(1, over: 3)
        lastKeyMove = t
        sessionStart = t
        keyInterval = rng.range(180...480)
        began = true
        startScene(at: t)
        scheduleChord(from: t)
        lastModulate = -1
        modulate(t)
    }

    func advance(to time: Double) {
        #if DEBUG
        if realtime { dispatchPrecondition(condition: .notOnQueue(.main)) }
        #endif
        let t0 = DispatchTime.now().uptimeNanoseconds
        drainInbox()
        guard began else { return }
        scheduler.advance(to: time)
        if time - lastModulate >= 0.0999 { modulate(time) }
        let dt = DispatchTime.now().uptimeNanoseconds &- t0
        tickCount += 1; tickTotalNs &+= dt; tickMaxNs = max(tickMaxNs, dt)
    }

    var tickStats: (count: Int, meanMs: Double, maxMs: Double) {
        (tickCount, tickCount > 0 ? Double(tickTotalNs) / Double(tickCount) / 1e6 : 0, Double(tickMaxNs) / 1e6)
    }

    private func drainInbox() {
        inboxLock.lock()
        guard !inbox.isEmpty else { inboxLock.unlock(); return }
        let items = inbox
        inbox.removeAll(keepingCapacity: true)
        inboxLock.unlock()
        for c in items { apply(c) }
    }

    private func apply(_ c: MusicControl) {
        switch c {
        case .density(let d): density = min(max(d, 0), 1)
        case .space(let s): space = min(max(s, 0), 1); spaceDirty = true
        case .delayAmount(let d): delayAmount = min(max(d, 0), 1); spaceDirty = true
        case .style(let id): styleID = id; director.style = MusicStyle.style(id)
        case .pinScale(let s):
            if let change = harmony.setPinned(s) { broadcast(change); logKey() }
            if s != nil { keyInterval = .infinity } else if keyInterval == .infinity { keyInterval = rng.range(180...480); lastKeyMove = scheduler.now }
        case .visualMood(let m): moodTarget = m
        case .imageDidChange(let d): imageDidChange(transition: d)
        case .visualActivity(let a): activityTarget = min(max(a, 0), 1)
        case .limiterBypass(let b): mix.limiterBypassed = b
        }
    }

    private var spaceDirty = false

    // MARK: Scenes

    private var newest: MusicScene? { scenes.last }

    private func startScene(at t: Double) {
        var s = director.next(after: newest, sessionTime: t, density: density, mood: mood, available: available)
        sceneCount += 1
        s.keyMoveAtEnd = harmony.pinned == nil && (s.handoffTime - lastKeyMove) >= keyInterval
        scenes.append(s)
        if scenes.count > 2 { scenes.removeFirst() }
        if harmony.setPedal(onFifth: s.pedalOnFifth) { scoreLog?.pedal(t, harmony.field.pedalMIDI) }
        ctx.scene = s
        for l in layers { l.sceneDidChange(s, ctx: ctx) }
        emit(.sceneChange, layer: .drone, midi: Int(s.kind.rawValue), velocity: s.peak)
        scoreLog?.scene(s)
        let idx = s.index
        scheduler.schedule(at: s.handoffTime) { [weak self] in self?.handoff(from: idx) }
        scheduler.schedule(at: s.endTime) { [weak self] in self?.scenes.removeAll { $0.index == idx } }
    }

    private func handoff(from index: Int) {
        guard let s = scenes.first(where: { $0.index == index }) else { return }
        if s.keyMoveAtEnd, let f = harmony.proposeKeyMove(brightnessBias: keyBias()) {
            broadcast(harmony.apply(field: f))
            lastKeyMove = scheduler.now
            keyInterval = rng.range(180...480)
            logKey()
            scheduleChord(from: scheduler.now)
        }
        startScene(at: scheduler.now)
    }

    private func keyBias() -> Float {
        min(max(0.6 * (newest?.brightness ?? 0) + 1.2 * (mood.brightness - 0.5) + rng.rangeF(-0.4...0.4), -1), 1)
    }

    // MARK: Harmony

    private func chordLength(_ i: Float) -> Double {
        let base = 42 + (16 - 42) * Double(min(max(i, 0), 1))
        return min(max(rng.jitter(base, 0.25), 14), 50)
    }

    private func scheduleChord(from t: Double) {
        chordToken += 1
        let token = chordToken
        chordStart = t
        scheduler.schedule(at: t + chordLength(ctx.intensity)) { [weak self] in
            guard let self, self.chordToken == token else { return }
            self.changeChord()
        }
    }

    private func changeChord() {
        let tension = min(max((newest?.tension ?? 0.4) + 0.25 * (ctx.intensity - 0.5), 0), 1)
        let c = harmony.nextChord(tension: tension)
        broadcast(harmony.apply(chord: c))
        scoreLog?.chord(scheduler.now, harmony.field)
        scheduleChord(from: scheduler.now)
    }

    private func broadcast(_ change: HarmonyChange) {
        for l in layers { l.harmonyDidChange(change, ctx: ctx) }
        switch change {
        case .chord:
            state.chordChangeCount &+= 1
            emit(.chordChange, layer: .pad, midi: harmony.field.chordRootPitchClass)
        case .key:
            state.keyChangeCount &+= 1
            emit(.keyChange, layer: .drone, midi: harmony.field.tonic)
        }
    }

    private func logKey() { scoreLog?.key(scheduler.now, harmony.field) }

    /// Image transitions pull the next chord change to the transition midpoint (section 8).
    private func imageDidChange(transition: Double) {
        let now = scheduler.now
        guard began, now - lastImageChange >= 10 else { return }
        lastImageChange = now
        scheduler.schedule(after: max(0, transition) / 2) { [weak self] in
            guard let self else { return }
            if self.scheduler.now - self.chordStart > 8 { self.changeChord() }
        }
    }

    // MARK: Modulation (10 Hz)

    private func modulate(_ t: Double) {
        let dt = lastModulate < 0 ? 0.1 : t - lastModulate
        lastModulate = t
        modulateCount += 1

        // Visual mood: 8 s low-pass on every scalar.
        let a = Float(1 - exp(-dt / 8))
        mood.brightness += (moodTarget.brightness - mood.brightness) * a
        mood.warmth += (moodTarget.warmth - mood.warmth) * a
        mood.saturation += (moodTarget.saturation - mood.saturation) * a
        mood.energy += (moodTarget.energy - mood.energy) * a
        if mood.moodWords != moodTarget.moodWords { mood.moodWords = moodTarget.moodWords }
        ctx.activity += (activityTarget - ctx.activity) * a

        var intensity = MusicScene.floor
        for s in scenes { intensity = max(intensity, s.intensity(at: t)) }
        let bias = newest?.brightness ?? 0
        let b = 0.5 + 0.3 * bias + 0.3 * (intensity - 0.4) + 0.2 * (mood.brightness - 0.5) + 0.12 * colorDrift.value(at: t)
        ctx.intensity = intensity
        ctx.brightness = min(max(b, 0), 1)
        ctx.density = density
        ctx.registerShift = newest?.registerShift ?? 0
        ctx.mood = mood
        ctx.space = space

        updateActivation(t)
        for l in layers { l.modulate(dt: dt, ctx: ctx) }

        if spaceDirty || modulateCount % 5 == 0 {
            mix.setSpace(space, delayAmount: delayAmount, brightness: ctx.brightness, over: spaceDirty ? 0.3 : 0.6)
            ctx.delayScale = mix.delaySendScale
            spaceDirty = false
        }

        publish(t)
        if modulateCount % 10 == 0 { scoreLog?.sample(t, intensity: intensity, brightness: ctx.brightness, layers: layers) }
    }

    private func updateActivation(_ t: Double) {
        var desired: [(MusicLayer, Float)] = []
        for l in layers {
            var want = false
            var thr: Float = 1
            for s in scenes where s.layers.contains(l.id) {
                let th = s.thresholds[l.id] ?? l.entryThreshold
                let i = s.intensity(at: t)
                let on = hysteresis[l.id] ?? false
                if i > th || (on && i > th - 0.05) { want = true; thr = min(thr, th) }
            }
            hysteresis[l.id] = want
            if want { desired.append((l, thr)) }
        }
        // Max active layers 3 + round(3 D); drop the highest thresholds first.
        let cap = 3 + Int((3 * density).rounded())
        let keep = Set(desired.sorted { $0.1 < $1.1 }.prefix(cap).map { $0.0.id })
        for l in layers {
            let on = keep.contains(l.id)
            guard on != l.isActive else { continue }
            var fade = on ? rng.range(8...30) : rng.range(10...40)
            // The opening drone comes in within seconds so the app never starts in near-silence.
            if on && l.id == .drone && t - sessionStart < 1 { fade = rng.range(4...6) }
            l.setActive(on, fade: fade, ctx: ctx)
            emit(on ? .layerEnter : .layerExit, layer: l.id)
            scoreLog?.layer(t, l.id, on)
        }
    }

    // MARK: State

    private func emit(_ kind: MusicEvent.Kind, layer: LayerID, midi: Int = 0, velocity: Float = 0) {
        eventSeq &+= 1
        let t = scheduler.now
        state.push(MusicEvent(sequence: eventSeq, kind: kind, layer: layer, midi: UInt8(clamping: midi),
                              velocity: velocity, time: t))
        if kind == .noteOn {
            state.lastOnsetTime = t
            state.lastOnsetVelocity = velocity
            scoreLog?.note(layer)
            if realtime { onNote?(layer, midi) }
        }
        if began { publish(t) }
    }

    private func publish(_ t: Double) {
        state.time = t
        state.startUptime = startUptime
        if let s = newest {
            state.sceneIndex = UInt32(s.index)
            state.sceneKind = s.kind
            state.scenePhase = s.phase(at: t)
            state.sceneProgress = s.progress(at: t)
        }
        state.intensity = ctx.intensity
        state.brightness = ctx.brightness
        state.density = ctx.density
        let f = harmony.field
        state.tonic = UInt8(f.tonic)
        state.modeIndex = UInt16(f.mode.index)
        state.scaleMask = f.scaleMask
        state.chordMask = f.chordMask
        state.chordRoot = UInt8(f.chordRootPitchClass)
        for l in layers { state.setLevel(l.id, l.strip.targetLevel) }
        stateBus.publish(state)
    }
}

/// Offline score log (decision D34): scenes, layer entries, chords, keys, per-second levels.
/// Everything except `perf` is deterministic for a given seed.
nonisolated final class ScoreLog {
    private var scenes: [[String: Any]] = []
    private var layerEvents: [[String: Any]] = []
    private var chords: [[String: Any]] = []
    private var keys: [[String: Any]] = []
    private var pedals: [[String: Any]] = []
    private var samples: [[String: Any]] = []
    private var notes: [String: Int] = [:]

    private static func r(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
    private static func r(_ x: Float) -> Double { r(Double(x)) }

    func scene(_ s: MusicScene) {
        scenes.append(["index": s.index, "kind": "\(s.kind)", "start": Self.r(s.startTime),
                       "duration": Self.r(s.duration), "peak": Self.r(s.peak),
                       "layers": s.layers.map { "\($0)" }.sorted(), "registerShift": s.registerShift,
                       "brightness": Self.r(s.brightness), "tension": Self.r(s.tension),
                       "keyMoveAtEnd": s.keyMoveAtEnd, "pedalOnFifth": s.pedalOnFifth])
    }
    func layer(_ t: Double, _ id: LayerID, _ on: Bool) {
        layerEvents.append(["t": Self.r(t), "layer": "\(id)", "on": on])
    }
    func chord(_ t: Double, _ f: HarmonicField) {
        chords.append(["t": Self.r(t), "rootDegree": f.chord.rootDegree, "shape": "\(f.chord.shape)",
                       "pcs": f.chordPitchClasses])
    }
    func key(_ t: Double, _ f: HarmonicField) {
        keys.append(["t": Self.r(t), "tonic": f.tonic, "mode": f.mode.rawValue, "pedal": f.pedalMIDI])
    }
    func pedal(_ t: Double, _ midi: Int) { pedals.append(["t": Self.r(t), "pedal": midi]) }
    func note(_ id: LayerID) { notes["\(id)", default: 0] += 1 }
    func sample(_ t: Double, intensity: Float, brightness: Float, layers: [MusicLayer]) {
        var lv: [String: Double] = [:]
        for l in layers { lv["\(l.id)"] = Self.r(l.strip.targetLevel) }
        samples.append(["t": Self.r(t), "intensity": Self.r(intensity), "brightness": Self.r(brightness), "levels": lv])
    }

    func write(to url: URL, seed: UInt64, initialKey: HarmonicField?, perf: [String: Any]) throws {
        var root: [String: Any] = ["seed": seed, "scenes": scenes, "layerEvents": layerEvents, "chords": chords,
                                   "keys": keys, "pedals": pedals, "samples": samples, "notes": notes, "perf": perf]
        if let k = initialKey { root["initialKey"] = ["tonic": k.tonic, "mode": k.mode.rawValue] }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }
}
