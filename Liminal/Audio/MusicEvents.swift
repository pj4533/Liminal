import Foundation

/// Rare, memorable gestures (plan section 7, decisions D66, D102): one every 240-600 s, the first after
/// 150-300 s, each kind with an 8-minute cooldown and an intensity window. All of them are slow and soft:
/// the cascade is a 4-6 note fall, the toll three low warm notes, the bloom a dark halo. Events borrow layers that may not be in the current
/// scene (see `BaseLayer.borrow`), so they can happen in any scene.
nonisolated enum RareEventKind: UInt8, CaseIterable {
    case arpeggioCascade = 1, shimmerBloom, airSwell, subPulse, bellToll, hush

    var name: String { "\(self)" }

    /// Allowed intensity window (plan table).
    func allowed(intensity i: Float) -> Bool {
        switch self {
        case .arpeggioCascade: return i > 0.5
        case .shimmerBloom: return i > 0.4
        case .airSwell: return true
        case .subPulse: return i < 0.6
        case .bellToll: return i < 0.5
        case .hush: return i > 0.6
        }
    }
}

nonisolated final class RareEventDirector {
    private var rng: MusicRNG
    private var lastFired: [RareEventKind: Double] = [:]
    private(set) var nextTime: Double = 0
    static let cooldown = 480.0
    static let interval = 240.0...600.0

    weak var keys: KeysLayer?
    weak var air: AirLayer?
    weak var drone: DroneLayer?
    let mix: MixBus
    /// All strips except drone and air (ducked by `hush`).
    var duckable: [LayerStrip] = []

    init(rng: MusicRNG, mix: MixBus) {
        self.rng = rng
        self.mix = mix
    }

    func reset(at t: Double) {
        lastFired.removeAll()
        // The first event comes a little earlier than the steady-state interval so short sessions hear one.
        nextTime = t + rng.range(150...300)
    }

    /// Called at 10 Hz. Returns the event that fired, if any.
    func poll(t: Double, ctx: LayerContext) -> RareEventKind? {
        guard t >= nextTime else { return nil }
        nextTime = t + rng.range(RareEventDirector.interval)
        let candidates = RareEventKind.allCases.filter { k in
            k.allowed(intensity: ctx.intensity) && t - (lastFired[k] ?? -1e9) >= RareEventDirector.cooldown && available(k)
                && fits(k, ctx: ctx)
        }
        guard !candidates.isEmpty else {
            nextTime = t + rng.range(20...45)     // try again soon
            return nil
        }
        // Kinds that have not been heard for a long time (or ever) are more likely: weight grows with the
        // time since they last fired, up to 3x.
        let k = candidates[rng.weighted(candidates.map { Float(min(3, (t - (lastFired[$0] ?? -1e9)) / RareEventDirector.cooldown)) })]
        lastFired[k] = t
        fire(k, ctx: ctx)
        return k
    }

    /// An event that borrows a layer from outside the scene must not make more layers sound than the cap (D102).
    private func fits(_ k: RareEventKind, ctx: LayerContext) -> Bool {
        let borrowed: BaseLayer? = {
            switch k {
            case .arpeggioCascade, .bellToll: return keys
            case .airSwell: return air
            default: return nil
            }
        }()
        guard let l = borrowed, !l.isActive else { return true }
        return ctx.activeLayers < ctx.layerCap
    }

    private func available(_ k: RareEventKind) -> Bool {
        switch k {
        case .arpeggioCascade, .bellToll: return keys != nil
        case .airSwell: return air != nil
        case .subPulse: return drone != nil
        case .shimmerBloom, .hush: return true
        }
    }

    func fire(_ k: RareEventKind, ctx: LayerContext) {
        let t = ctx.time
        switch k {
        case .arpeggioCascade:
            keys?.cascade(ctx: ctx)
        case .shimmerBloom:
            mix.bloomShimmer(duration: 20, now: t)
            ctx.scheduler.schedule(after: 0) { [weak self] in self?.padBoost(ctx: ctx, up: true) }
            ctx.scheduler.schedule(after: 11) { [weak self] in self?.padBoost(ctx: ctx, up: false) }
        case .airSwell:
            air?.swell(rise: rng.range(10...14), decay: 6, cut: true, ctx: ctx)
        case .subPulse:
            drone?.subPulse(ctx: ctx)
        case .bellToll:
            keys?.toll(ctx: ctx)
        case .hush:
            let hold = rng.range(20...40)
            for s in duckable { s.swell(to: dbToGain(-12), over: 4, now: t) }
            ctx.scheduler.schedule(after: 4 + hold) { [weak self] in
                guard let self else { return }
                for s in self.duckable { s.swell(to: 1, over: 8, now: ctx.time) }
            }
        }
    }

    /// Pad brightness +0.2 during a shimmer bloom, ramped by the conductor's 10 Hz smoothing.
    private var padTarget: Float = 0
    private func padBoost(ctx: LayerContext, up: Bool) { padTarget = up ? 0.2 : 0 }

    /// 10 Hz: glide the pad brightness boost toward its target (about 3 s).
    func modulate(dt: Double, ctx: LayerContext) {
        let a = Float(1 - exp(-dt / 3))
        ctx.padBrightnessBoost += (padTarget - ctx.padBrightnessBoost) * a
    }
}
