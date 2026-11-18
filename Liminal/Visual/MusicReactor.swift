//
//  MusicReactor.swift
//  Liminal
//
//  Per-render-loop smoothing state that turns MusicState snapshots into a MusicModulation
//  (docs/plans/av-coupling.md 1.2, decisions C2-C8 in docs/decisions/av-coupling.md).
//  Owned by exactly one render loop (macOS VisualDisplayView, visionOS ImmersiveDomeView), never shared.
//  Per call: about a dozen one-pole updates and a few `exp` calls, no allocation.
//

import Foundation

nonisolated struct MusicReactor {

    // MARK: Tuning (starting values from the plan; see docs/decisions/av-coupling.md)

    static let amountTau: Float = 1.5
    static let energyTau: Float = 2.0
    static let brightTau: Float = 2.0
    static let shimmerTau: Float = 1.0
    static let airTau: Float = 1.5
    static let pulseColorAttack: Float = 0.09, pulseColorRelease: Float = 0.45
    static let pulseMotionAttack: Float = 0.18, pulseMotionRelease: Float = 0.90
    static let chordHueTau: Float = 4, keyHueTau: Float = 12
    static let chordHueRange: Float = 0.06, keyHueRange: Float = 0.10
    static let reachAttack: Float = 0.8, reachRelease: Float = 6, reachHold: Float = 2
    /// `MusicState.shimmerLevel` is a linear gain that tops out near dbToGain(-8) = 0.4.
    static let shimmerFullScale: Float = 0.4
    /// Music snapshot older than this (conductor stopped) counts as not alive.
    static let staleAfter: Double = 0.5
    /// Longest step integrated at once (a hitch or a backgrounded app must not lurch the accumulators).
    static let maxStep: Float = 0.1

    // MARK: State

    /// DEBUG -LiminalSyncStrength: multiplies `amount` (caps in the computer still apply).
    var strength: Float = 1

    private var lastRhythmOnset = -1000.0
    private var lastRhythmTrail = -1000.0
    private var pendingRhythmTrail: Double?

    private(set) var modulation = MusicModulation.neutral
    /// Last aliveness verdict (for the sync log).
    private(set) var alive = false
    private(set) var bright: Float = 0.5
    private(set) var harmonyHue: Float = 0

    private var lastEffectTime: Float?
    private var amount: Float = 0
    private var energy: Float = 0.4
    private var shimmer: Float = 0
    private var air: Float = 0
    private var pulseColor: Float = 0
    private var pulseMotion: Float = 0
    private var chordHue: Float = 0
    private var keyHue: Float = 0
    private var chordHueTarget: Float = 0
    private var keyHueTarget: Float = 0
    private var huePhase: Float = 0
    private var motionLead: Float = 0
    private var ghostReach: Float = 0
    private var reachHoldLeft: Float = 0
    private var ghostSerial: UInt32 = 0
    private var lastScene: UInt32?

    init(strength: Float = 1) { self.strength = strength }

    /// Clear everything (effect clock restarted).
    mutating func reset() {
        let s = strength, serial = ghostSerial
        self = MusicReactor(strength: s)
        ghostSerial = serial  // keep the serial monotonic so a renderer never misses a burst
    }

    // MARK: Update

    /// - Parameters:
    ///   - state: latest bus snapshot (`music.musicState.read()`)
    ///   - now: conductor seconds on the bus clock (`music.musicState.now()`), for aliveness and the onset envelope
    ///   - effectTime: the visual effect clock; its delta drives every smoother and accumulator, so the
    ///     reactor runs exactly as fast as the visuals. A repeated call with the same time returns the
    ///     cached result; a time that goes backwards (clock restarted) resets the reactor.
    ///   - enabled: the "Sync visuals to music" setting
    ///   - baseHueRate: today's un-coupled hue drift (macOS 0.03 turns/s, visionOS 0)
    mutating func update(state: MusicState, now: Double, effectTime: Float,
                         enabled: Bool, baseHueRate: Float) -> MusicModulation {
        guard let last = lastEffectTime, effectTime >= last else {
            reset()
            lastEffectTime = effectTime
            huePhase = Self.wrap(effectTime * baseHueRate)
            modulation.hueBaseShift = huePhase
            return modulation
        }
        let dt = min(effectTime - last, Self.maxStep)
        guard dt > 0 else { return modulation }
        lastEffectTime = effectTime

        // 1. Aliveness and master amount.
        alive = now > 0 && now - state.time < Self.staleAfter
        let amountTarget: Float = (enabled && alive) ? 1 : 0
        amount = Self.ease(amount, amountTarget, dt, Self.amountTau)
        // Snap the last 0.5 % so "off" is exactly the un-coupled output (a step of at most 0.0006 in bloom).
        if abs(amount - amountTarget) < 0.005 { amount = amountTarget }
        let a = amount * strength

        // 2. Smoothed signals. While the music is not alive the levels relax to neutral; amount is
        //    fading them out anyway.
        if alive {
            energy = Self.ease(energy, Self.clamp01(state.intensity), dt, Self.energyTau)
            bright = Self.ease(bright, Self.clamp01(state.brightness), dt, Self.brightTau)
            shimmer = Self.ease(shimmer, Self.clamp01(state.shimmerLevel / Self.shimmerFullScale), dt, Self.shimmerTau)
            air = Self.ease(air, Self.clamp01(state.level(.air)), dt, Self.airTau)
            let p = Self.clamp01(state.pulse(at: now, decay: 0.35))
            pulseColor = Self.follow(pulseColor, p, dt, Self.pulseColorAttack, Self.pulseColorRelease)
            pulseMotion = Self.follow(pulseMotion, p, dt, Self.pulseMotionAttack, Self.pulseMotionRelease)
            // 3. Harmony -> hue: deterministic circle-of-fifths position of chord (relative to tonic) and key.
            let rel = (Int(state.chordRoot) - Int(state.tonic) + 24) % 12
            chordHueTarget = Self.chordHueRange * Float(Self.fifths(rel)) / 6
            keyHueTarget = Self.keyHueRange * Float(Self.fifths(Int(state.tonic) % 12)) / 6
            // 6. Scene change -> ghost burst + reach swell.
            if let ls = lastScene, ls != state.sceneIndex, a > 0.5 {
                ghostSerial &+= 1
                reachHoldLeft = Self.reachHold
            }
            lastScene = state.sceneIndex
            // Sample-timed kick candidates can seed an occasional trail in Lo-Fi. Use
            // the audible timestamp, as a rendered sample can still be in the output path.
            if state.recordedBeatDuration > 0, a > 0.5 {
                if state.lastOnsetTime != lastRhythmOnset {
                    lastRhythmOnset = state.lastOnsetTime
                    if state.lastOnsetVelocity > 0.29, pendingRhythmTrail == nil, now - lastRhythmTrail >= 6 {
                        pendingRhythmTrail = state.lastOnsetTime + 0.75 * state.recordedBeatDuration
                    }
                }
                if let due = pendingRhythmTrail, now >= due {
                    if now - due < 0.16 {
                        ghostSerial &+= 1
                        lastRhythmTrail = now
                    }
                    pendingRhythmTrail = nil
                }
            } else {
                pendingRhythmTrail = nil
            }
        } else {
            pendingRhythmTrail = nil
            pulseColor = Self.follow(pulseColor, 0, dt, Self.pulseColorAttack, Self.pulseColorRelease)
            pulseMotion = Self.follow(pulseMotion, 0, dt, Self.pulseMotionAttack, Self.pulseMotionRelease)
        }
        chordHue = Self.ease(chordHue, chordHueTarget, dt, Self.chordHueTau)
        keyHue = Self.ease(keyHue, keyHueTarget, dt, Self.keyHueTau)
        harmonyHue = chordHue + keyHue

        let reachTarget: Float = reachHoldLeft > 0 ? 1 : 0
        reachHoldLeft = max(0, reachHoldLeft - dt)
        ghostReach = Self.follow(ghostReach, reachTarget, dt, Self.reachAttack, Self.reachRelease)

        // 4. Brightness -> hue drift rate (phase accumulator, never a speed uniform). 0.018...0.042 turns/s.
        let syncedRate = 0.03 * (0.6 + 0.8 * bright)
        let wet = min(a, 1)
        huePhase = Self.wrap(huePhase + dt * (baseHueRate + (syncedRate - baseHueRate) * wet))

        // 5. Integrate the music-driven motion timing offset for coupling diagnostics.
        motionLead += dt * min(max(a * (0.5 * energy - 0.15), -0.15), 0.35)

        modulation = MusicModulation(
            amount: a,
            energy: energy,
            pulseColor: pulseColor,
            pulseMotion: pulseMotion,
            shimmer: shimmer,
            air: air,
            hueBaseShift: Self.wrap(huePhase + wet * harmonyHue),
            motionLead: motionLead,
            ghostBurstSerial: ghostSerial,
            ghostReach: ghostReach
        )
        return modulation
    }

    // MARK: Helpers

    /// Circle-of-fifths position of a pitch class, -5...6 (C = 0, G = 1, F = -1, ...).
    static func fifths(_ pc: Int) -> Int {
        let f = (pc * 7) % 12
        return f > 6 ? f - 12 : f
    }

    @inline(__always) static func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }

    @inline(__always) static func wrap(_ x: Float) -> Float {
        let w = x - x.rounded(.down)
        return w >= 1 ? 0 : w
    }

    @inline(__always) static func ease(_ x: Float, _ target: Float, _ dt: Float, _ tau: Float) -> Float {
        x + (target - x) * (1 - exp(-dt / tau))
    }

    /// Asymmetric one-pole: `attack` time constant while rising, `release` while falling.
    @inline(__always) static func follow(_ x: Float, _ target: Float, _ dt: Float, _ attack: Float, _ release: Float) -> Float {
        ease(x, target, dt, target > x ? attack : release)
    }
}

// MARK: - DEBUG sync log (-LiminalSyncLog YES)

enum MusicSyncLog {
    /// One `🎼 SYNC ...` line: reactor state | resulting uniforms (ratio to un-modulated) | last mood and activity sent.
    static func line(reactor: MusicReactor, state: MusicState, uniforms u: EffectsUniforms, neutral n: EffectsUniforms,
                     mood: VisualMood?, activity: Float) -> String {
        let m = reactor.modulation
        func f(_ x: Float, _ d: Int = 2) -> String { String(format: "%.\(d)f", x) }
        func ratio(_ x: Float, _ y: Float) -> String { y > 1e-6 ? String(format: "x%.2f", x / y) : "x-" }
        let scene = "\(state.sceneKind)#\(state.sceneIndex)"
        let react = "a=\(f(m.amount)) alive=\(reactor.alive ? 1 : 0) scene=\(scene) I=\(f(m.energy)) B=\(f(reactor.bright))"
            + " pulse=\(f(m.pulseColor))/\(f(m.pulseMotion)) shim=\(f(m.shimmer)) air=\(f(m.air))"
            + " hue=\(f(m.hueBaseShift, 3))(\(reactor.harmonyHue >= 0 ? "+" : "")\(f(reactor.harmonyHue, 3))) lead=\(f(m.motionLead, 1))s"
            + " chord=\(state.chordRoot)/\(state.tonic)"
        let unis = "dist=\(f(u.distortionAmplitude, 4))(\(ratio(u.distortionAmplitude, n.distortionAmplitude)))"
            + " bloom=\(f(u.bloomAmount, 3)) vib=\(f(u.vibranceAmount, 3))(\(ratio(u.vibranceAmount, n.vibranceAmount)))"
            + " fb=\(f(u.feedbackMix, 3)) warp=\(f(u.feedbackWarpAmount, 3)) chrom=\(f(u.chromaticAmount, 4))(\(ratio(u.chromaticAmount, n.chromaticAmount)))"
            + " reach=\(f(m.ghostReach)) gtd=\(f(u.ghostTapMaxDistance, 3)) burst=\(m.ghostBurstSerial)"
        var moodPart = "mood -"
        if let mood {
            moodPart = "mood b=\(f(mood.brightness)) w=\(f(mood.warmth)) s=\(f(mood.saturation)) e=\(f(mood.energy)) [\(mood.moodWords.joined(separator: ","))]"
        }
        return "🎼 SYNC \(react) | \(unis) | \(moodPart) act=\(f(activity))"
    }
}
