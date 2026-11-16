//
//  EffectsUniformsComputer.swift
//  Liminal
//
//  Single source of truth for computing effect uniforms.
//  Used by both macOS (EffectsMetalView) and visionOS (OffscreenEffectsRenderer).
//

import Foundation

/// Computes effect uniforms from time and settings.
/// Centralizes all animation and slider-driven values to prevent platform drift.
enum EffectsUniformsComputer {

    // MARK: - Full Uniforms

    /// Compute complete uniforms for rendering.
    /// - Parameters:
    ///   - time: Current animation time in seconds
    ///   - transitionProgress: Optional crossfade transition progress (0-1) for distortion boost
    ///   - hasSaliencyMap: Whether a saliency texture is available
    ///   - ghostTapCount: Number of active ghost taps (0-8) for optimized shader loop
    ///   - vibrance: Per-image vibrance factors (ImageColorStats), blended across crossfades
    ///   - music: Music -> visuals coupling from MusicReactor (docs/plans/av-coupling.md 1.3).
    ///     `.neutral` gives the un-coupled output. This is the only place music becomes uniforms;
    ///     every modulated value is hard-clamped to the caps below whatever the inputs.
    ///   - look: Effect intensity setting and the current image's age (docs/plans/effects-balance.md).
    ///     Every amount is mixed between a clear and a wild value by `look.drive(time:)`, and the three
    ///     warps are fitted into the recognisability budget after the music factors.
    ///   - transition: The style of the running crossfade (docs/plans/transitions.md). Its boosts are
    ///     added after the budget, times the style's envelope; `.classic` is the pre-family crossfade.
    ///     With `transitionProgress` 0 every style gives the same uniforms as no transition at all.
    ///   - video: Archive footage of this frame (docs/plans/archive-video.md 2.2). `.off` = no footage.
    /// - Returns: Complete EffectsUniforms ready for the shader
    static func compute(
        time: Float,
        transitionProgress: Float = 0,
        hasSaliencyMap: Bool = false,
        ghostTapCount: Int = 0,
        vibrance: VibranceFactors = .neutral,
        music: MusicModulation = .neutral,
        look: EffectLook = EffectLook(),
        transition: TransitionSpec = .classic,
        video: VideoCompositeState = .off
    ) -> EffectsUniforms {
        typealias T = EffectLook.Tuning
        let a = music.amount
        let e = music.energy
        let i = min(max(look.intensity, 0), 1)
        let d = look.drive(time: time)
        func tri(_ t: (Float, Float, Float)) -> Float { EffectLook.tri(i, t) }
        func mix(_ cw: (clear: (Float, Float, Float), wild: (Float, Float, Float))) -> Float {
            let c = tri(cw.clear)
            return c + (tri(cw.wild) - c) * d
        }
        let tp = min(max(transitionProgress, 0), 1)
        let inTransition = transitionProgress > 0
        let env = inTransition ? transition.envelope(tp) : 0
        // The slow onset follower may swell a style's envelope by up to 12 % (plan 7.3); the swap never moves.
        let swell = transition.style == .classic ? 1 : 1 + 0.12 * min(max(a * music.pulseMotion, 0), 1)
        let tb = inTransition ? TransitionBoost.make(transition, intensity: i, envelope: env * swell, tp: tp) : TransitionBoost()

        // Ken Burns: smooth continuous motion (music runs its clock 0.85x...1.35x via motionLead)
        // In wild stretches the zoom eases back so the whole silhouette stays in view (E27).
        let kb = computeKenBurns(time: time + music.motionLead)
        let relief = tri(T.kenBurnsRelief) * EffectLook.macroDrive(time: time, intensity: i)
        let kenBurns = KenBurnsParams(scale: (1 + (kb.scale - 1) * (1 - relief)) * tb.kenBurnsMul,
                                      offsetX: kb.offsetX, offsetY: kb.offsetY)

        // Warps (plan 4.3 and 5): water always present; radial and noise only in the wilder part of the cycle.
        let waterClear = tri(T.waterClear)
        var water = waterClear + (tri(T.waterWild) - waterClear) * d * (0.55 + 0.45 * distortionWave01(time: time))
        water = max(water * (1 + a * (0.35 * e - 0.15)) + a * 0.004 * music.pulseMotion, 0)
        let warpMusic = 1 + a * (0.30 * e - 0.15)
        var logSphere = max(tri(T.logSphereMax) * EffectLook.smoothstep(T.logSphereWindow.0, T.logSphereWindow.1, d)
            * (0.35 + 0.65 * logSphereWave01(time: time)) * warpMusic, 0)
        var noise = max(tri(T.noiseMax) * EffectLook.smoothstep(T.noiseWindow.0, T.noiseWindow.1, d)
            * (0.35 + 0.65 * fractalNoiseWave01(time: time)) * warpMusic, 0)
        fitStrainBudget(water: &water, logSphere: &logSphere, noise: &noise, budget: EffectLook.strainBudget(i))
        water = min(water, Caps.distortionBase) + tb.water
        logSphere = min(logSphere, Caps.logSphereBase) + tb.logSphere
        noise = min(noise, Caps.fractalNoiseBase) + tb.noise

        // Autonomous color cycling - smooth oscillator produces organic, non-repeating patterns.
        // Few hue bands in clear stretches, more in wild ones; the blend never drops to a plain photo,
        // and stacked spatial rainbows are capped (E25).
        let colorCycle = SmoothOscillator.value(at: time)
        var hueBlend = (T.hueBlendFloor + (1 - T.hueBlendFloor) * colorCycle) * mix(T.hueBlend)
        var hueWave = min(colorCycle * mix(T.hueWave), T.hueWaveCap, T.rainbowCap / max(hueBlend, 1e-3))
        if inTransition {
            // Rainbow front pulls the hue stage above the usual rainbow cap, during its plateau only.
            hueWave += max(tb.hueWaveTarget - hueWave, 0) * tb.huePull
            hueBlend += max(tb.hueBlendTarget - hueBlend, 0) * tb.huePull
            hueBlend = min(hueBlend + tb.hueBlendAdd, 1)
        }

        let chromaticBase = min(max(chromaticRaw(time: time) * mix(T.chromatic) * (1 + a * (0.30 * e - 0.10))
            + a * 0.002 * music.pulseMotion, 0), Caps.chromaticBase)
        let fbBase = mix(T.feedbackMix)
        let bloomBase = tri(T.bloom)
        var feedback = min(max(fbBase + a * (0.08 * e - 0.04), fbBase - Caps.feedbackMixRange),
                           min(fbBase + Caps.feedbackMixRange, Caps.feedbackMixHigh))
        if inTransition {
            feedback = min(feedback + tb.feedbackAdd, Caps.feedbackMixTransition)
            feedback += max(tb.feedbackTarget - feedback, 0) * tb.feedbackPull
        }

        var uniforms = EffectsUniforms(
            time: time,
            kenBurnsScale: kenBurns.scale,
            kenBurnsOffsetX: kenBurns.offsetX,
            kenBurnsOffsetY: kenBurns.offsetY,
            distortionAmplitude: water,
            distortionSpeed: 0.08,
            hueBaseShift: music.hueBaseShift + tb.hueBase,
            hueWaveIntensity: hueWave,
            hueBlendAmount: hueBlend,
            contrastBoost: 1.4 + tb.contrastAdd,
            saturationBoost: 1.3,
            // Ghost taps travel 6% of image size - slow drift; swells to 8% after a music scene change
            ghostTapMaxDistance: min(max(0.06 + a * 0.02 * music.ghostReach, 0.06), Caps.ghostTapMaxDistance) * tb.ghostReachMul,
            saliencyInfluence: hasSaliencyMap ? 0.6 : 0,
            hasSaliencyMap: hasSaliencyMap ? 1.0 : 0.0,
            transitionProgress: transitionProgress,
            ghostTapCount: Float(ghostTapCount),
            chromaticAmount: chromaticBase * tb.chromaticMul + tb.chromaticAdd,
            feedbackWarpAmount: min(max(0.03 + a * 0.01 * music.air, 0.03), Caps.feedbackWarp) * tb.feedbackWarpMul,
            feedbackMix: feedback,
            bloomRadius: 0.04 * tb.bloomRadiusMul,
            bloomAmount: min(max(bloomBase + a * (0.12 * music.pulseColor + 0.10 * music.shimmer), bloomBase),
                             Caps.bloom * bloomBase / 0.5) + tb.bloomAdd,
            stereoOffset: 0,
            logSphereAmount: logSphere,
            fractalNoiseAmount: noise,
            fractalHueAmount: fractalHueRaw(time: time) * mix(T.fractalHue) + tb.fractalHueAdd
        )
        let vib = computeVibrance(time: time, imageFactor: vibrance.amount)
            + a * 0.06 * music.pulseColor * vibrance.amount
        uniforms.vibranceAmount = min(max(vib, 0), Caps.vibrance * vibrance.amount)
        uniforms.blackPoint = baseBlackPoint * vibrance.dark
        if inTransition {
            uniforms.txStyle = Float(transition.style.rawValue)
            uniforms.txMix = transition.swap(tp)
            uniforms.txEnv = env
            uniforms.txSeed = transition.seed
            uniforms.txSoft = transition.shaderSoft
            uniforms.txAmount = tb.shaderAmount
        }
        // Archive footage (docs/plans/archive-video.md 2.2): with `.off` the video uniforms stay 0 and
        // nothing above changes.
        if !video.isOff {
            let settled = VideoComposite.settled(imageAge: look.imageAge, transitionDuration: look.transitionDuration,
                                                 inTransition: inTransition, progress: tp)
            VideoComposite.apply(video, to: &uniforms, intensity: i, drive: d, settled: settled, fresh: look.fresh())
        }
        return uniforms
    }

    /// Recognisability budget (plan 4.3): the combined warp strain may not exceed `budget`.
    /// The radial and the crystalline noise give way first; the water is clamped only if it alone exceeds it.
    static func fitStrainBudget(water: inout Float, logSphere: inout Float, noise: inout Float, budget: Float) {
        typealias T = EffectLook.Tuning
        let st = T.kTurb * water
        if st > budget {
            water = budget / T.kTurb
            logSphere = 0
            noise = 0
            return
        }
        let l = T.kLog * logSphere, n = T.kNoise * noise
        let rest = (l * l + n * n).squareRoot()
        let room = max(budget * budget - st * st, 0).squareRoot()
        if rest > room {
            logSphere *= room / rest
            noise *= room / rest
        }
    }

    /// Hard limits (plan 1.3 cap column of av-coupling, tightened by effects-balance section 5).
    /// Warp and chromatic caps apply before the transition boost.
    enum Caps {
        static let distortionBase: Float = 0.10
        static let chromaticBase: Float = 0.02
        static let logSphereBase: Float = 0.020
        static let fractalNoiseBase: Float = 0.036
        static let bloom: Float = 0.72               // at bloom base 0.5; scales with the base
        static let vibrance: Float = 0.50            // times the image factor
        static let feedbackMixRange: Float = 0.04    // music moves feedback mix at most this far from its base
        static let feedbackMixHigh: Float = 0.34
        static let feedbackMixTransition: Float = 0.72  // additive transition trails stop here (Afterimage pulls past it)
        static let feedbackWarp: Float = 0.04
        static let ghostTapMaxDistance: Float = 0.08
    }

    // MARK: - Visual activity (visuals -> music)

    /// How busy the picture is, 0...1, sent to `GenerativeEngine.setVisualActivity` (plan 2.3).
    /// Computed without music on purpose (C12) so music cannot feed back into itself; follows the
    /// clarity drive so the music calms with the picture (effects-balance plan 5).
    static func visualActivity(time: Float, transitionProgress: Float, look: EffectLook = EffectLook(),
                               transition: TransitionSpec = .classic) -> Float {
        let d = look.drive(time: time)
        let v = 0.15 + 0.6 * d * (0.55 + 0.45 * distortionWave01(time: time))
            + 0.5 * (transitionProgress > 0 ? transition.envelope(transitionProgress) : 0)
        return min(max(v, 0), 1)
    }

    // MARK: - Vibrance (final shader stage)

    /// Black-point pull-down at darkFactor 1. 0.03 crushed 4.3% of pixels in the prototype;
    /// 0.015 stays within +0.5 points of the input's crushed blacks.
    static let baseBlackPoint: Float = 0.015

    /// Chroma gain of the final vibrance stage: a slow, non-repeating swell (golden-ratio
    /// frequencies decorrelated from the other oscillators) so colour intensity breathes.
    /// 0.18...0.42 at imageFactor 1. See docs/decisions/vibrance.md (V6).
    static func computeVibrance(time: Float, imageFactor: Float = 1) -> Float {
        let phi: Float = 1.618034
        let wave = (sin(time * 0.023 * phi) + sin(time * 0.041 / phi) * 0.6) / 1.6  // -1..1
        return (0.30 + 0.12 * wave) * imageFactor
    }

    // MARK: - Ken Burns

    struct KenBurnsParams {
        let scale: Float
        let offsetX: Float
        let offsetY: Float
    }

    /// Compute Ken Burns pan/zoom from time.
    /// Uses multiple sine waves for organic, non-repetitive motion.
    static func computeKenBurns(time: Float) -> KenBurnsParams {
        // Scale: gentle breathing between 1.04 and 1.32 (shows at least 57% of the picture)
        let scale: Float = 1.18 + 0.10 * sin(time * 0.05) + 0.04 * sin(time * 0.03)

        // Offset: wandering pan (normalized to -0.8...0.8 range)
        let maxOffset: Float = 60
        let rawOffsetX = maxOffset * sin(time * 0.04) + 20 * sin(time * 0.025)
        let rawOffsetY = maxOffset * cos(time * 0.035) + 20 * cos(time * 0.02)

        // Normalize offsets (shader expects small values)
        let offsetX = rawOffsetX / 100.0
        let offsetY = rawOffsetY / 100.0

        return KenBurnsParams(scale: scale, offsetX: offsetX, offsetY: offsetY)
    }


    // MARK: - Oscillators (0...1 or raw ranges; the look mixes and scales them)

    /// Chromatic aberration oscillation, 0.003...0.015 (golden-ratio offset from the colour cycle).
    static func chromaticRaw(time: Float) -> Float {
        let phi: Float = 1.618034
        let wave = (sin(time * 0.07 * phi) + sin(time * 0.03) * 0.6) / 1.6  // -1..1
        return 0.003 + 0.012 * (wave + 1) / 2
    }

    /// Log-spherical (radial) amount oscillation, 0...1, decorrelated from the other oscillators.
    static func logSphereWave01(time: Float) -> Float {
        let phi: Float = 1.618034
        let wave = (sin(time * 0.035 * phi * phi) + sin(time * 0.022 / phi) * 0.7) / 1.7  // -1..1
        return (wave + 1) / 2
    }

    /// Sinusoidal interference (crystalline) noise amount oscillation, 0...1.
    static func fractalNoiseWave01(time: Float) -> Float {
        let phi: Float = 1.618034
        let wave = (sin(time * 0.028 * phi) + sin(time * 0.045 / (phi * phi)) * 0.6) / 1.6  // -1..1
        return (wave + 1) / 2
    }

    /// Fractal hue cycling oscillation, 0.05...0.25. No transition boost (colour surges during a
    /// crossfade feel jarring).
    static func fractalHueRaw(time: Float) -> Float {
        let phi: Float = 1.618034
        let wave = (sin(time * 0.032 / phi) + sin(time * 0.05 * phi * phi) * 0.5) / 1.5  // -1..1
        return 0.05 + 0.20 * (wave + 1) / 2
    }

    /// Organic oscillation of the turbulence amplitude, 0...1: layered sine waves at irrational
    /// frequency ratios. Also an input of `visualActivity`.
    static func distortionWave01(time: Float) -> Float {
        let phi: Float = 1.618034
        let wave = (sin(time * 0.04 * phi) + sin(time * 0.025) * 0.7 + sin(time * 0.06 / phi) * 0.4) / 2.1  // -1..1
        return (wave + 1) / 2
    }

}
