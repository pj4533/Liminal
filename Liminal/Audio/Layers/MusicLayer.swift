import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation
import AudioToolbox

/// Every parameter write goes through here (decision D7): sample-accurate `scheduleParameterBlock`
/// ramps when the parameter can ramp (all AudioKit/Soundpipe DSP parameters), else a direct value.
nonisolated enum ParamRamp {
    static let minimum: Double = 0.02
    /// Minimum spacing between two writes to the same parameter when the second must not cancel the first
    /// (decision D85). The conductor runs every block due inside a 20 ms tick at the start of that tick, and
    /// an `Immediate` ramp replaces any ramp still running, so a decay scheduled 8-12 ms after an attack
    /// used to start in the same render quantum and override the attack: notes swelled in over 0.3-0.6 s
    /// instead of being struck. Anything at least this far apart lands in a later tick.
    static let nextTick: Double = 0.025

    static func set(_ p: NodeParameter, _ value: Float, over: Double) {
        guard let param = p.parameter else { return }
        let v = min(max(value, param.minValue), param.maxValue)
        if param.flags.contains(.flag_CanRamp) {
            p.ramp(to: v, duration: Float(max(minimum, over)))
        } else {
            param.value = v
        }
    }

    static func setGain(_ f: Fader, _ gain: Float, over: Double) {
        set(f.$leftGain, gain, over: over)
        set(f.$rightGain, gain, over: over)
    }
}

/// A software envelope advanced at the 10 Hz modulation rate and written to the audio graph as short
/// ramps. Used for fades that are longer than a ramp should be overridden by other writers.
nonisolated struct SoftEnv {
    private(set) var value: Float
    private var from: Float
    private var to: Float
    private var start: Double = 0
    private var duration: Double = 0

    init(_ v: Float = 0) { value = v; from = v; to = v }

    var target: Float { to }
    var isMoving: Bool { value != to }

    mutating func go(to v: Float, over: Double, now: Double) {
        from = value; to = v; start = now; duration = max(0, over)
        if duration == 0 { value = v }
    }

    /// Smoothstep-shaped progress so fades start and end gently.
    @discardableResult
    mutating func tick(_ now: Double) -> Float {
        guard value != to else { return value }
        let u = duration > 0 ? min(max((now - start) / duration, 0), 1) : 1
        let s = Float(u * u * (3 - 2 * u))
        value = u >= 1 ? to : from + (to - from) * s
        return value
    }
}

/// Per-layer output: level fader, panner, reverb and delay sends (decision D10).
/// The panner fans out to the dry bus and both send faders (fan-out verified by probe A).
/// Strips built with a `dry` gain get one more fader between the panner and the dry bus, so a layer can be
/// heard mostly through the reverb (decision D93: the struck layers are mostly wet).
nonisolated final class LayerStrip {
    let level: Fader
    let panner: Panner
    let reverbSend: Fader
    let delaySend: Fader
    /// Optional dry fader (nil = the panner feeds the dry bus at unity).
    let dryGain: Fader?
    /// Linear gain applied at full activation (gain staging, section 3).
    var trim: Float
    private var fade = SoftEnv(0)
    /// Multiplier for momentary swells and ducks (1 = none): hush, warmth tilt, sub pulses.
    private var swellEnv = SoftEnv(1)
    /// Additive level used when a layer is borrowed by a rare event or an image change while it is not
    /// part of the scene (0 = none). Level = trim * (fade * swell + boost).
    private var boostEnv = SoftEnv(0)
    /// Static multiplier set every modulation tick (visual warmth). 1 = none.
    var tilt: Float = 1
    /// Slow level motion inside a scene (BaseLayer breathing channel, decision D72). 1 = none.
    var motion: Float = 1
    private var lastWritten: Float = -1
    private(set) var pan: Float = 0

    var outputs: (dry: Node, reverbSend: Node, delaySend: Node) { (dryGain ?? panner, reverbSend, delaySend) }

    /// Fade position 0...1 (the conductor's target level, published in `MusicState.layerLevels`).
    var targetLevel: Float { min(1, fade.value * swellEnv.value + boostEnv.value) }
    var isSilent: Bool { fade.value == 0 && fade.target == 0 && boostEnv.value == 0 && boostEnv.target == 0 }
    var fadeValue: Float { fade.value }
    var fadeTarget: Float { fade.target }

    init(source: Node, filter: Node? = nil, trim: Float, reverb: Float, delay: Float, pan: Float = 0, dry: Float? = nil) {
        self.trim = trim
        level = Fader(filter ?? source, gain: 0)
        let p = Panner(level, pan: pan)
        panner = p
        self.pan = pan
        reverbSend = Fader(p, gain: reverb)
        delaySend = Fader(p, gain: delay)
        dryGain = dry.map { Fader(p, gain: $0) }
    }

    func fade(to v: Float, over: Double, now: Double) { fade.go(to: v, over: over, now: now) }
    func swell(to v: Float, over: Double, now: Double) { swellEnv.go(to: v, over: over, now: now) }
    func boost(to v: Float, over: Double, now: Double) { boostEnv.go(to: v, over: over, now: now) }

    /// 10 Hz: advance the envelopes and write the level.
    func tick(now: Double) {
        let g = trim * tilt * (fade.tick(now) * swellEnv.tick(now) * motion + boostEnv.tick(now))
        if abs(g - lastWritten) > 1e-5 {
            ParamRamp.setGain(level, g, over: 0.12)
            lastWritten = g
        }
    }

    func setLevel(_ linear: Float, over: Double) {
        ParamRamp.setGain(level, linear, over: over)
        lastWritten = linear
    }

    func setPan(_ p: Float, over: Double) {
        pan = min(max(p, -1), 1)
        ParamRamp.set(panner.$pan, pan, over: over)
    }

    func setSends(reverb: Float, delay: Float, over: Double) {
        ParamRamp.setGain(reverbSend, reverb, over: over)
        ParamRamp.setGain(delaySend, delay, over: over)
    }
}

/// Shared, mutable view of the conductor's state handed to layers on every call (conductor queue only).
/// A class rather than the plan's struct: layers hold it across scheduled blocks and it carries `emit`.
nonisolated final class LayerContext {
    let scheduler: MusicScheduler
    let harmony: HarmonyEngine
    var intensity: Float = MusicScene.floor
    var brightness: Float = 0.5
    /// Brightness for the beds (drone, pad), on the pre-calm curve (decision D94).
    var bedBrightness: Float = 0.5
    /// Layers active after the last activation pass; rare events that borrow a layer respect the cap (D102).
    var activeLayers = 0
    var layerCap = 4
    var density: Float = 0.5
    var registerShift: Int = 0
    var mood = VisualMood()
    var activity: Float = 0
    var space: Float = 0.5
    /// Multiplier for every layer's delay send (space x delay amount, from MixBus).
    var delayScale: Float = 1
    var scene: MusicScene?
    /// Smoothed image mood and its capped nudges (section 8).
    var coupling = VisualCoupling()
    /// Current style (palette, layer weights, timbre preferences).
    var style = MusicStyle.drift
    /// Extra brightness for the pad during a shimmer bloom (0...0.2).
    var padBrightnessBoost: Float = 0
    fileprivate(set) var emitter: ((MusicEvent.Kind, LayerID, Int, Float) -> Void)?

    init(scheduler: MusicScheduler, harmony: HarmonyEngine) {
        self.scheduler = scheduler
        self.harmony = harmony
    }

    var field: HarmonicField { harmony.field }
    var time: Double { scheduler.now }

    // MARK: Shared attack headroom (decision D89)

    /// Recent note attacks from every pointed layer (time, layer, weight), a fixed ring so nothing allocates.
    private var attackTimes = [Double](repeating: -10, count: 12)
    private var attackLayers = [LayerID](repeating: .drone, count: 12)
    private var attackWeights = [Float](repeating: 0, count: 12)
    private var attackNext = 0

    /// Call once per note about to be struck. Returns a gain of 1 when no other layer attacked in the last
    /// 0.2 s, falling as `1 / sqrt(1 + 0.6 * w)` with the summed weight `w` of other layers' attacks in that
    /// window (one coincident full-weight note: -2 dB; two: -3.4 dB). Each layer already shares headroom among
    /// its own notes (D84); this does the same across layers, where the bypassed-mix peaks came from
    /// (pluck + drips, keys + grain cloud). Then records this attack.
    func shareAttack(layer: LayerID, weight: Float = 1) -> Float {
        let now = time
        var w: Float = 0
        for i in 0..<attackTimes.count where attackLayers[i] != layer && now - attackTimes[i] < 0.2 && now >= attackTimes[i] {
            w += attackWeights[i]
        }
        attackTimes[attackNext] = now
        attackLayers[attackNext] = layer
        attackWeights[attackNext] = weight
        attackNext = (attackNext + 1) % attackTimes.count
        return 1 / (1 + 0.6 * w).squareRoot()
    }

    func setEmitter(_ e: @escaping (MusicEvent.Kind, LayerID, Int, Float) -> Void) { emitter = e }

    func emit(_ kind: MusicEvent.Kind, layer: LayerID, midi: Int = 0, velocity: Float = 0) {
        emitter?(kind, layer, midi, velocity)
    }
}

nonisolated protocol MusicLayer: AnyObject {
    var id: LayerID { get }
    var strip: LayerStrip { get }
    /// Every strip this layer feeds into the mix bus (the main strip first).
    var allStrips: [LayerStrip] { get }
    var entryThreshold: Float { get }
    var isActive: Bool { get }
    func prepare(rng: MusicRNG)
    func setActive(_ active: Bool, fade: Double, ctx: LayerContext)
    func sceneDidChange(_ scene: MusicScene, ctx: LayerContext)
    func harmonyDidChange(_ change: HarmonyChange, ctx: LayerContext)
    func modulate(dt: Double, ctx: LayerContext)
    func silence(fade: Double, ctx: LayerContext)
    /// Stop generators (zero CPU) after a completed stop fade.
    func powerDown()
}

/// Shared layer behaviour: activation fades, generator power management, cancellation of
/// scheduled blocks. Subclasses override the `did*`/`update` hooks.
nonisolated class BaseLayer: MusicLayer {
    let id: LayerID
    let strip: LayerStrip
    let entryThreshold: Float
    var rng = MusicRNG(seed: 0)
    private(set) var isActive = false
    /// Bumped on silence/deactivation-complete; scheduled blocks compare and bail if stale.
    private(set) var generation = 0
    /// Generator nodes stopped (bypassed, zero CPU) while the layer is silent for more than 5 s.
    var generators: [Node] = []
    private(set) var generatorsRunning = false
    private var silentSince: Double?
    /// Slow level motion: each layer leans forward and back by up to +-`motionDepth` dB on its own
    /// 45-110 s channel, so the balance keeps shifting inside a scene.
    private var motionLFO = ParameterDrift.Channel(period: 70, phase: 0)
    var motionDepth: Float = 4
    /// Additional strips that follow the main strip's fades (e.g. the Lead's answer voice).
    var extraStrips: [LayerStrip] = []
    var allStrips: [LayerStrip] { [strip] + extraStrips }

    init(id: LayerID, strip: LayerStrip, entryThreshold: Float) {
        self.id = id
        self.strip = strip
        self.entryThreshold = entryThreshold
    }

    func prepare(rng: MusicRNG) {
        self.rng = rng
        var r = rng.fork(0x4D4F)
        motionLFO = ParameterDrift.Channel(period: r.range(45...110), phase: r.range(0...6.28))
        stopGenerators()
    }

    final func startGenerators() {
        guard !generatorsRunning else { return }
        generators.forEach { $0.start() }
        generatorsRunning = true
    }

    final func stopGenerators() {
        generators.forEach { $0.stop() }
        generatorsRunning = false
    }

    func setActive(_ active: Bool, fade: Double, ctx: LayerContext) {
        guard active != isActive else { return }
        isActive = active
        for st in allStrips { st.fade(to: active ? 1 : 0, over: fade, now: ctx.time) }
        if active {
            silentSince = nil
            startGenerators()
            didActivate(ctx: ctx)
        } else {
            didDeactivate(ctx: ctx)
        }
    }

    func silence(fade: Double, ctx: LayerContext) {
        generation += 1
        isActive = false
        for st in allStrips {
            st.fade(to: 0, over: fade, now: ctx.time)
            st.boost(to: 0, over: fade, now: ctx.time)
        }
        didSilence(fade: fade, ctx: ctx)
    }

    func powerDown() {
        generation += 1
        stopGenerators()
    }

    func modulate(dt: Double, ctx: LayerContext) {
        let m = dbToGain(motionDepth * motionLFO.value(at: ctx.time))
        for st in allStrips { st.motion = m; st.tick(now: ctx.time) }
        if !isActive && allStrips.allSatisfy(\.isSilent) {
            if silentSince == nil { silentSince = ctx.time }
            if generatorsRunning, let s = silentSince, ctx.time - s > 5 {
                generation += 1
                stopGenerators()
            }
        } else {
            silentSince = nil
        }
        if generatorsRunning { update(dt: dt, ctx: ctx) }
    }

    /// Borrow the layer for a one-shot gesture while it may be outside the scene (rare events, image
    /// changes): wakes its generators and raises the additive boost level; `release` lowers it again.
    /// Returns false if the layer is already sounding at full level (no boost needed).
    @discardableResult
    final func borrow(level: Float, attack: Double, ctx: LayerContext) -> Bool {
        silentSince = nil
        startGenerators()
        let need = max(0, level - strip.fadeValue)
        guard need > 0.01 else { return false }
        strip.boost(to: need, over: attack, now: ctx.time)
        return true
    }

    final func releaseBorrow(over: Double, ctx: LayerContext) {
        strip.boost(to: 0, over: over, now: ctx.time)
    }

    /// Schedule a block that is dropped if the layer was silenced or powered down in the meantime.
    final func after(_ delay: Double, ctx: LayerContext, _ block: @escaping () -> Void) {
        let g = generation
        ctx.scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.generation == g else { return }
            block()
        }
    }

    private var loopGeneration = -1

    /// Start the layer's self-rescheduling loop unless one is already running in this generation.
    final func ensureLoop(_ start: () -> Void) {
        guard loopGeneration != generation else { return }
        loopGeneration = generation
        start()
    }

    // MARK: hooks
    func didActivate(ctx: LayerContext) {}
    func didDeactivate(ctx: LayerContext) {}
    func didSilence(fade: Double, ctx: LayerContext) {}
    func sceneDidChange(_ scene: MusicScene, ctx: LayerContext) {}
    func harmonyDidChange(_ change: HarmonyChange, ctx: LayerContext) {}
    /// 10 Hz while generators run.
    func update(dt: Double, ctx: LayerContext) {}
}

/// Exponential map of brightness 0...1 into a frequency range.
@inline(__always) nonisolated func expMap(_ b: Float, _ lo: Float, _ hi: Float) -> Float {
    lo * powf(hi / lo, min(max(b, 0), 1))
}

@inline(__always) nonisolated func dbToGain(_ db: Float) -> Float { powf(10, db / 20) }

/// Round-robin voice bookkeeping for one-shot pools (decision D68). Envelopes are amplitude ramps on
/// the generator itself (no `AmplitudeEnvelope` nodes), so each note bumps the voice's token and any
/// still-scheduled envelope segment of the previous note on that voice checks it and drops out.
nonisolated struct VoicePool {
    private(set) var lastUsed: [Double]
    private(set) var token: [Int]

    init(_ count: Int) {
        lastUsed = [Double](repeating: -1e9, count: count)
        token = [Int](repeating: 0, count: count)
    }

    /// The least recently used voice among `preferred` if it has rested `minAge` seconds, else the least
    /// recently used voice overall. Marks it used and returns (voice, token).
    mutating func take(preferring preferred: [Int]? = nil, now: Double, minAge: Double = 0) -> (Int, Int) {
        let used = lastUsed
        let all = Array(used.indices)
        func lru(_ vs: [Int]) -> Int { vs.min { used[$0] < used[$1] } ?? 0 }
        var v = lru(preferred ?? all)
        if now - used[v] < minAge { v = lru(all) }
        lastUsed[v] = now
        token[v] &+= 1
        return (v, token[v])
    }

    func isCurrent(_ v: Int, _ t: Int) -> Bool { token[v] == t }
}
