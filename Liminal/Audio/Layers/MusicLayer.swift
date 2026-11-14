import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import Foundation
import AudioToolbox

/// Every parameter write goes through here (decision D7): sample-accurate `scheduleParameterBlock`
/// ramps when the parameter can ramp (all AudioKit/Soundpipe DSP parameters), else a direct value.
nonisolated enum ParamRamp {
    static let minimum: Double = 0.02

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
nonisolated final class LayerStrip {
    let level: Fader
    let panner: Panner
    let reverbSend: Fader
    let delaySend: Fader
    /// Linear gain applied at full activation (gain staging, section 3).
    var trim: Float
    private var fade = SoftEnv(0)
    private var lastWritten: Float = -1
    private(set) var pan: Float = 0
    /// Extra multiplier for momentary swells/ducks (1 = none).
    var swell: Float = 1

    var outputs: (dry: Node, reverbSend: Node, delaySend: Node) { (panner, reverbSend, delaySend) }

    /// Fade position 0...1 (the conductor's target level, published in `MusicState.layerLevels`).
    var targetLevel: Float { fade.value }
    var isSilent: Bool { fade.value == 0 && fade.target == 0 }

    init(source: Node, filter: Node? = nil, trim: Float, reverb: Float, delay: Float, pan: Float = 0) {
        self.trim = trim
        level = Fader(filter ?? source, gain: 0)
        panner = Panner(level, pan: pan)
        self.pan = pan
        reverbSend = Fader(panner, gain: reverb)
        delaySend = Fader(panner, gain: delay)
    }

    func fade(to v: Float, over: Double, now: Double) { fade.go(to: v, over: over, now: now) }

    /// 10 Hz: advance the fade and write the level.
    func tick(now: Double) {
        let g = trim * fade.tick(now) * swell
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
    var density: Float = 0.5
    var registerShift: Int = 0
    var mood = VisualMood()
    var activity: Float = 0
    var space: Float = 0.5
    /// Multiplier for every layer's delay send (space x delay amount, from MixBus).
    var delayScale: Float = 1
    var scene: MusicScene?
    fileprivate(set) var emitter: ((MusicEvent.Kind, LayerID, Int, Float) -> Void)?

    init(scheduler: MusicScheduler, harmony: HarmonyEngine) {
        self.scheduler = scheduler
        self.harmony = harmony
    }

    var field: HarmonicField { harmony.field }
    var time: Double { scheduler.now }

    func setEmitter(_ e: @escaping (MusicEvent.Kind, LayerID, Int, Float) -> Void) { emitter = e }

    func emit(_ kind: MusicEvent.Kind, layer: LayerID, midi: Int = 0, velocity: Float = 0) {
        emitter?(kind, layer, midi, velocity)
    }
}

nonisolated protocol MusicLayer: AnyObject {
    var id: LayerID { get }
    var strip: LayerStrip { get }
    var entryThreshold: Float { get }
    var isActive: Bool { get }
    func prepare(rng: SeededRNG)
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
    var rng = SeededRNG(seed: 0)
    private(set) var isActive = false
    /// Bumped on silence/deactivation-complete; scheduled blocks compare and bail if stale.
    private(set) var generation = 0
    /// Generator nodes stopped (bypassed, zero CPU) while the layer is silent for more than 5 s.
    var generators: [Node] = []
    private var generatorsRunning = false
    private var silentSince: Double?

    init(id: LayerID, strip: LayerStrip, entryThreshold: Float) {
        self.id = id
        self.strip = strip
        self.entryThreshold = entryThreshold
    }

    func prepare(rng: SeededRNG) {
        self.rng = rng
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
        strip.fade(to: active ? 1 : 0, over: fade, now: ctx.time)
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
        strip.fade(to: 0, over: fade, now: ctx.time)
        didSilence(fade: fade, ctx: ctx)
    }

    func powerDown() {
        generation += 1
        stopGenerators()
    }

    func modulate(dt: Double, ctx: LayerContext) {
        strip.tick(now: ctx.time)
        if !isActive && strip.isSilent {
            if silentSince == nil { silentSince = ctx.time }
            if generatorsRunning, let s = silentSince, ctx.time - s > 5 {
                generation += 1
                stopGenerators()
            }
        }
        if generatorsRunning { update(dt: dt, ctx: ctx) }
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
