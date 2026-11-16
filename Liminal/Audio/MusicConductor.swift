import AudioKit
import Foundation
import OSLog

/// Controls posted from any thread; drained at the start of every `advance`.
nonisolated enum MusicControl {
    case density(Float), space(Float), delayAmount(Float), style(MusicStyle.ID)
    case pinScale(ScaleType?)                       // nil = auto (evolving)
    case visualMood(VisualMood), imageDidChange(transition: Double), visualActivity(Float)
    case limiterBypass(Bool)
    /// Debug / harness: layers kept active regardless of scene (solo gain-staging renders).
    case forceLayers(Set<LayerID>)
    /// Archive footage sound (docs/plans/archive-video.md 4): start a decoded segment, fade it out, or
    /// change its level ("Footage audio").
    case archiveBegin(ArchiveVoice.Cue), archiveEnd(fade: Double), archiveGain(Float)
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
    private var rng: MusicRNG
    private var colorDrift: ParameterDrift.Channel
    private let rare: RareEventDirector
    /// The archive film's sound (nil in harnesses that build a conductor without it).
    private let archive: ArchiveVoice?

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
    private var activityTarget: Float = 0.5
    private var lastImageChange = -1000.0
    private var styleID: MusicStyle.ID = .drift
    private var pendingStyleKeyMove = false
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
    private var tickMaxAt = 0.0
    private var slowTicks = 0

    /// Offline only: timeline of scenes, layers, chords, keys and events.
    var scoreLog: ScoreLog?
    /// Called for every note (conductor queue). The facade forwards drips notes to `shimmerNotePlayed`.
    var onNote: ((LayerID, Int) -> Void)?

    init(layers: [MusicLayer], mix: MixBus, seed: UInt64, pinned: ScaleType?, archive: ArchiveVoice? = nil) {
        self.archive = archive
        let root = MusicRNG(seed: seed)
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
        rare = RareEventDirector(rng: root.fork(5), mix: mix)
        rare.keys = layers.first { $0.id == .keys } as? KeysLayer
        rare.air = layers.first { $0.id == .air } as? AirLayer
        rare.drone = layers.first { $0.id == .drone } as? DroneLayer
        rare.duckable = layers.filter { $0.id != .drone && $0.id != .air }.flatMap(\.allStrips)
        ctx.setEmitter { [unowned self] kind, layer, midi, vel in self.emit(kind, layer: layer, midi: midi, velocity: vel) }
    }

    private var available: Set<LayerID> { Set(layers.map(\.id)) }

    /// Current harmonic field (conductor queue / offline thread only).
    var field: HarmonicField { harmony.field }

    #if DEBUG
    /// Test hook (AVCouplingTests, offline thread only): the smoothed image -> music nudges.
    var couplingProbe: (brightnessNudge: Float, warmthDb: Float) { (ctx.coupling.brightnessNudge, ctx.coupling.warmthDb) }
    #endif

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
            archive?.end(fade: fade, now: scheduler.now)
            mix.setMaster(0, over: fade)
            queue.asyncAfter(deadline: .now() + fade + 0.5) { [self] in
                guard token == runToken else { return }
                timer?.cancel(); timer = nil
                scheduler.cancelAll()
                for l in layers { l.powerDown() }
                archive?.reset(now: scheduler.now)
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
        for l in layers {
            l.silence(fade: 0, ctx: ctx)
            for st in l.allStrips { st.swell(to: 1, over: 0, now: t) }
        }
        rare.reset(at: t)
        archive?.reset(now: t)
        mix.setSpace(space, delayAmount: delayAmount, brightness: 0.5, shimmerScale: shimmerScale, over: 0.05)
        ctx.delayScale = mix.delaySendScale
        mix.setMaster(MusicConductor.masterGain, over: 3)
        lastKeyMove = t
        sessionStart = t
        keyInterval = rng.range(180...360)
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
        tickCount += 1; tickTotalNs &+= dt
        if dt > tickMaxNs { tickMaxNs = dt; tickMaxAt = time }
        if dt > 2_000_000 { slowTicks += 1 }
    }

    var tickStats: (count: Int, meanMs: Double, maxMs: Double, maxAt: Double, slow: Int) {
        (tickCount, tickCount > 0 ? Double(tickTotalNs) / Double(tickCount) / 1e6 : 0, Double(tickMaxNs) / 1e6,
         tickMaxAt, slowTicks)
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
        case .style(let id):
            guard id != styleID else { break }
            styleID = id
            let st = MusicStyle.style(id)
            director.style = st
            ctx.style = st
            spaceDirty = true
            // Off-palette mode: move key at the next scene boundary (one-note move if possible).
            if harmony.setPalette(st.palette) {
                if !scenes.isEmpty { scenes[scenes.count - 1].keyMoveAtEnd = true } else { pendingStyleKeyMove = true }
            }
        case .pinScale(let s):
            if let change = harmony.setPinned(s) { broadcast(change); logKey() }
            if s != nil { keyInterval = .infinity } else if keyInterval == .infinity { keyInterval = rng.range(180...360); lastKeyMove = scheduler.now }
        case .visualMood(let m): ctx.coupling.setTarget(m)
        case .imageDidChange(let d): imageDidChange(transition: d)
        case .visualActivity(let a): activityTarget = min(max(a, 0), 1)
        case .limiterBypass(let b): mix.limiterBypassed = b
        case .forceLayers(let ids): forced = ids
        case .archiveBegin(let cue): if began { archive?.begin(cue, now: scheduler.now) }
        case .archiveEnd(let fade): archive?.end(fade: fade, now: scheduler.now)
        case .archiveGain(let g): archive?.setGain(g)
        }
    }

    private var spaceDirty = false
    private var forced: Set<LayerID> = []

    // MARK: Scenes

    private var newest: MusicScene? { scenes.last }

    private func startScene(at t: Double) {
        var s = director.next(after: newest, sessionTime: t, density: ctx.density, mood: ctx.coupling.mood,
                              available: available, sceneWeights: ctx.coupling.sceneWeights)
        sceneCount += 1
        s.keyMoveAtEnd = harmony.pinned == nil && ((s.handoffTime - lastKeyMove) >= keyInterval || pendingStyleKeyMove)
        pendingStyleKeyMove = false
        scenes.append(s)
        if scenes.count > 2 { scenes.removeFirst() }
        if harmony.setPedal(onFifth: s.pedalOnFifth) { pedalSince = t; scoreLog?.pedal(t, harmony.field.pedalMIDI) }
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
            keyInterval = rng.range(180...360)
            logKey()
            scheduleChord(from: scheduler.now)
        }
        startScene(at: scheduler.now)
    }

    private func keyBias() -> Float {
        min(max(0.6 * (newest?.brightness ?? 0) + ctx.coupling.keyBias + rng.rangeF(-0.4...0.4), -1), 1)
    }

    // MARK: Harmony

    /// Master trim at full: +4.5 dB over PASS 1 (decisions D72, D86), +1.5 dB for the calm mix (D105), whose
    /// struck layers are quieter and mostly wet, so the mean stays near -25 dBFS RMS.
    static let masterGain: Float = dbToGain(6)

    /// Harmonic rhythm lerp(40, 22, intensity) +-25 %, clamped 18-55 s (D43, retuned in D72, D86 and D101).
    private func chordLength(_ i: Float) -> Double {
        let base = 40 + (22 - 40) * Double(min(max(i, 0), 1))
        return min(max(rng.jitter(base, 0.25), 18), 55)
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

    private var pedalSince = 0.0

    private func changeChord() {
        // Cool images favour open, suspended and quartal shapes (lower tension); styles bias it too.
        let tension = min(max((newest?.tension ?? 0.4) + 0.25 * (ctx.intensity - 0.5)
                              - 0.2 * ctx.coupling.coolness + ctx.style.tensionBias, 0), 1)
        let c = harmony.nextChord(tension: tension)
        broadcast(harmony.apply(chord: c))
        scoreLog?.chord(scheduler.now, harmony.field)
        movePedalWithChord()
        scheduleChord(from: scheduler.now)
    }

    /// The pedal holds at least 60 s (D101); then, in moving scenes, it may step to the new chord's root (45 %)
    /// or back to the tonic (60 % when away), so the bass outlines the harmony slowly (decision D73).
    private func movePedalWithChord() {
        let now = scheduler.now
        guard now - pedalSince >= 60, let kind = newest?.kind, kind != .stillness else { return }
        let f = harmony.field
        let tonicPedal = HarmonyEngine.pedal(for: f.tonic)
        var changed = false
        if f.pedalMIDI != tonicPedal && rng.chance(0.6) {
            changed = harmony.setPedal(pitchClass: f.tonic)
        } else if f.chord.rootDegree != 0 && rng.chance(0.45) {
            changed = harmony.setPedal(pitchClass: f.chordRootPitchClass)
        }
        if changed { pedalSince = now; scoreLog?.pedal(now, harmony.field.pedalMIDI) }
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
        let d = min(max(transition, 0.5), 20)
        // Air swell rises over the transition and decays after.
        (layer(.air) as? AirLayer)?.swell(rise: d, decay: max(4, d), cut: false, ctx: ctx)
        scheduler.schedule(after: d / 2) { [weak self] in
            guard let self else { return }
            if self.scheduler.now - self.chordStart > 8 { self.changeChord() }
            (self.layer(.pad) as? PadLayer)?.rebloom(ctx: self.ctx)
            if self.rng.chance(0.2) {   // D102 (was 0.35)
                if self.rng.chance(0.5), let k = self.layer(.keys) as? KeysLayer { k.accent(ctx: self.ctx) }
                else { (self.layer(.drips) as? DripsLayer)?.accent(ctx: self.ctx) }
            }
        }
    }

    private func layer(_ id: LayerID) -> MusicLayer? { layers.first { $0.id == id } }

    private var shimmerScale: Float { ctx.style.shimmer * ctx.coupling.shimmerScale }

    // MARK: Modulation (10 Hz)

    private func modulate(_ t: Double) {
        let dt = lastModulate < 0 ? 0.1 : t - lastModulate
        lastModulate = t
        modulateCount += 1

        // Visual mood: 8 s low-pass on every scalar (VisualCoupling).
        let a = Float(1 - exp(-dt / 8))
        ctx.coupling.smooth(dt: dt)
        ctx.activity += (activityTarget - ctx.activity) * a
        let cpl = ctx.coupling

        var intensity = MusicScene.floor
        for s in scenes { intensity = max(intensity, s.intensity(at: t)) }
        let bias = newest?.brightness ?? 0
        // Calm brightness macro (decision D94): lower centre, half the scene and intensity weight, ceiling 0.70.
        let drift = colorDrift.value(at: t)
        let b = 0.42 + 0.4 * bias + 0.2 * (intensity - 0.4) + cpl.brightnessNudge + 0.1 * drift
        ctx.intensity = intensity
        ctx.brightness = MusicConductor.shapeBrightness(b)
        // The beds (drone, pad) keep the previous macro and scene biases, which the user liked, with only the
        // top of the curve trimmed.
        let bed = 0.5 + 0.6 * (newest?.bedBrightness ?? 0) + 0.35 * (intensity - 0.4) + cpl.brightnessNudge + 0.12 * drift
        ctx.bedBrightness = MusicConductor.shapeBedBrightness(bed)
        ctx.density = min(max(density * cpl.energyScale, 0), 1)
        ctx.registerShift = min(max((newest?.registerShift ?? 0) + cpl.registerNudge, -5), 7)
        ctx.mood = cpl.mood
        ctx.space = space

        updateActivation(t)
        // Warm images: drone up to +3 dB and air down; cool images the reverse.
        layer(.drone)?.strip.tilt = dbToGain(cpl.warmthDb)
        layer(.air)?.strip.tilt = dbToGain(-cpl.warmthDb)
        rare.modulate(dt: dt, ctx: ctx)
        if let k = rare.poll(t: t, ctx: ctx) {
            emit(.rareEvent, layer: .drone, midi: Int(k.rawValue), velocity: 1)
            scoreLog?.rare(t, k)
        }
        for l in layers { l.modulate(dt: dt, ctx: ctx) }
        archive?.modulate(t: t)

        if spaceDirty || modulateCount % 5 == 0 {
            mix.setSpace(space, delayAmount: delayAmount, brightness: ctx.brightness, shimmerScale: shimmerScale,
                         over: spaceDirty ? 0.3 : 0.6)
            // Visual activity nudges every delay send +-15 %.
            ctx.delayScale = mix.delaySendScale * (1 + 0.3 * (ctx.activity - 0.5))
            spaceDirty = false
        }
        mix.modulate(t: t, dt: dt)
        state.shimmerLevel = mix.shimmerOut

        publish(t)
        if modulateCount % 10 == 0 { scoreLog?.sample(t, intensity: intensity, brightness: ctx.brightness, layers: layers) }
    }

    /// Brightness macro shaping (decisions D89, D94): linear up to 0.5, then a soft knee that approaches 0.70
    /// (the pointed layers' filters and the reverb damping never open fully; was knee 0.6, ceiling 0.92).
    static func shapeBrightness(_ raw: Float) -> Float {
        let knee: Float = 0.5, span: Float = 0.2
        if raw <= knee { return max(raw, 0) }
        return knee + span * tanhf((raw - knee) / span)
    }

    /// Bed brightness (drone, pad; D94): the D89 curve with its ceiling lowered from 0.92 to 0.80, so the pad's
    /// ladder tops out at 3.6 kHz instead of 6 kHz and is otherwise unchanged.
    static func shapeBedBrightness(_ raw: Float) -> Float {
        let knee: Float = 0.6, span: Float = 0.2
        if raw <= knee { return max(raw, 0) }
        return knee + span * tanhf((raw - knee) / span)
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
            // Continuity across a handoff: a sounding layer that the next scene also uses stays on while
            // that scene emerges, instead of dipping out and back in (decision D71).
            if !want, l.isActive, let n = newest, scenes.count > 1, n.layers.contains(l.id), n.phase(at: t) == .emerge {
                want = true; thr = n.thresholds[l.id] ?? l.entryThreshold
            }
            hysteresis[l.id] = want
            if forced.contains(l.id) { want = true; thr = 0 }
            if want { desired.append((l, thr)) }
        }
        // Never thinner than two layers: if the arcs leave only one, keep the newest scene's lowest-threshold
        // other layer (or the most recently sounding one) on (decision D71).
        if desired.count < 2, let n = newest {
            let have = Set(desired.map { $0.0.id })
            let cands = layers.filter { n.layers.contains($0.id) && !have.contains($0.id) && $0.id != .drone }
            if let pick = cands.first(where: { $0.isActive }) ?? cands.min(by: { (n.thresholds[$0.id] ?? 1) < (n.thresholds[$1.id] ?? 1) }) {
                desired.append((pick, 0.99))
            }
        }
        // Max active layers 3 + round(2 D) (4 at default density, D101); drop the highest thresholds first.
        let cap = 3 + Int((2 * density).rounded())
        var keep = Set(desired.sorted { $0.1 < $1.1 }.prefix(cap).map { $0.0.id })
        // A layer still fading out above 20 % counts against the cap, so a newcomer waits for it instead of
        // briefly making five audible layers (D101; the fades are 20-50 s long now).
        let fadingOut = layers.filter { !keep.contains($0.id) && $0.strip.fadeValue > 0.2 }.count
        let staying = layers.filter { keep.contains($0.id) && $0.isActive }.count
        var budget = cap - staying - fadingOut
        for (l, _) in desired.sorted(by: { $0.1 < $1.1 }) where keep.contains(l.id) && !l.isActive {
            if budget > 0 { budget -= 1 } else { keep.remove(l.id) }
        }
        ctx.activeLayers = keep.count + fadingOut
        ctx.layerCap = cap
        for l in layers {
            let on = keep.contains(l.id)
            guard on != l.isActive else { continue }
            var fade = on ? rng.range(15...40) : rng.range(20...50)   // slow entries and exits (D101)
            // The opening drone comes in within seconds so the app never starts in near-silence.
            if on && l.id == .drone && t - sessionStart < 1 { fade = rng.range(4...6) }
            if on && l.id == .pad && t - sessionStart < 20 { fade = rng.range(6...10) }
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
            scoreLog?.note(layer, t: t, velocity: velocity)
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
        for l in layers { state.setLevel(l.id, l.allStrips.map(\.targetLevel).max() ?? 0) }
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
    private var rareEvents: [[String: Any]] = []

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
    /// Every note onset (layer, time, velocity): lets the analysis check which notes the onset detector finds.
    private var onsets: [[Any]] = []
    func note(_ id: LayerID, t: Double, velocity: Float) {
        notes["\(id)", default: 0] += 1
        onsets.append([Self.r(t), "\(id)", Self.r(velocity)])
    }
    func rare(_ t: Double, _ k: RareEventKind) { rareEvents.append(["t": Self.r(t), "kind": k.name]) }
    func sample(_ t: Double, intensity: Float, brightness: Float, layers: [MusicLayer]) {
        var lv: [String: Double] = [:]
        for l in layers { lv["\(l.id)"] = Self.r(l.allStrips.map(\.targetLevel).max() ?? 0) }
        samples.append(["t": Self.r(t), "intensity": Self.r(intensity), "brightness": Self.r(brightness), "levels": lv])
    }

    func write(to url: URL, seed: UInt64, initialKey: HarmonicField?, perf: [String: Any]) throws {
        var root: [String: Any] = ["seed": seed, "scenes": scenes, "layerEvents": layerEvents, "chords": chords,
                                   "keys": keys, "pedals": pedals, "samples": samples, "notes": notes, "onsets": onsets, "rareEvents": rareEvents, "perf": perf]
        if let k = initialKey { root["initialKey"] = ["tonic": k.tonic, "mode": k.mode.rawValue] }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        // Atomic: a plain overwrite of an existing, longer log left its old tail behind (invalid JSON, D89).
        try data.write(to: url, options: .atomic)
    }
}
