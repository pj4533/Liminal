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
    /// - Returns: Complete EffectsUniforms ready for the shader
    static func compute(
        time: Float,
        transitionProgress: Float = 0,
        hasSaliencyMap: Bool = false,
        ghostTapCount: Int = 0,
        vibrance: VibranceFactors = .neutral,
        music: MusicModulation = .neutral
    ) -> EffectsUniforms {
        let a = music.amount
        let e = music.energy

        // Ken Burns: smooth continuous motion (music runs its clock 0.85x...1.35x via motionLead)
        let kenBurns = computeKenBurns(time: time + music.motionLead)

        // Distortion with organic oscillation and optional transition boost
        let distortion = computeDistortion(
            time: time, transitionProgress: transitionProgress,
            baseScale: 1 + a * (0.35 * e - 0.15), baseAdd: a * 0.004 * music.pulseMotion)

        // Autonomous color cycling - smooth oscillator produces organic, non-repeating patterns
        let colorCycle = SmoothOscillator.value(at: time)
        let hueBlend = colorCycle * 0.8  // Max blend at 80% to preserve some original color
        let hueWave = colorCycle * 0.6   // Spatial wave intensity also scales with color cycle

        var uniforms = EffectsUniforms(
            time: time,
            kenBurnsScale: kenBurns.scale,
            kenBurnsOffsetX: kenBurns.offsetX,
            kenBurnsOffsetY: kenBurns.offsetY,
            distortionAmplitude: distortion.amplitude,
            distortionSpeed: distortion.speed,
            hueBaseShift: music.hueBaseShift,
            hueWaveIntensity: hueWave,
            hueBlendAmount: hueBlend,
            contrastBoost: 1.4,
            saturationBoost: 1.3,
            // Ghost taps travel 6% of image size - slow drift; swells to 8% after a music scene change
            ghostTapMaxDistance: min(max(0.06 + a * 0.02 * music.ghostReach, 0.06), Caps.ghostTapMaxDistance),
            saliencyInfluence: hasSaliencyMap ? 0.6 : 0,
            hasSaliencyMap: hasSaliencyMap ? 1.0 : 0.0,
            transitionProgress: transitionProgress,
            ghostTapCount: Float(ghostTapCount),
            chromaticAmount: computeChromatic(
                time: time, transitionProgress: transitionProgress,
                baseScale: 1 + a * (0.30 * e - 0.10), baseAdd: a * 0.002 * music.pulseMotion),
            feedbackWarpAmount: min(max(0.03 + a * 0.01 * music.air, 0.03), Caps.feedbackWarp),
            feedbackMix: min(max(0.3 + a * (0.08 * e - 0.04), Caps.feedbackMixLow), Caps.feedbackMixHigh),
            bloomRadius: 0.04,
            bloomAmount: min(max(0.5 + a * (0.12 * music.pulseColor + 0.10 * music.shimmer), 0.5), Caps.bloom),
            stereoOffset: 0,
            logSphereAmount: computeLogSphere(time: time, transitionProgress: transitionProgress,
                                              baseScale: 1 + a * (0.30 * e - 0.15)),
            fractalNoiseAmount: computeFractalNoise(time: time, transitionProgress: transitionProgress,
                                                    baseScale: 1 + a * (0.30 * e - 0.15)),
            fractalHueAmount: computeFractalHue(time: time)
        )
        let vib = computeVibrance(time: time, imageFactor: vibrance.amount)
            + a * 0.06 * music.pulseColor * vibrance.amount
        uniforms.vibranceAmount = min(max(vib, 0), Caps.vibrance * vibrance.amount)
        uniforms.blackPoint = baseBlackPoint * vibrance.dark
        return uniforms
    }

    /// Hard limits on every music-modulated uniform (plan 1.3 cap column).
    enum Caps {
        static let distortionBase: Float = 0.10      // before the transition boost
        static let chromaticBase: Float = 0.02       // before the transition boost
        static let logSphereBase: Float = 0.02 * 1.2
        static let fractalNoiseBase: Float = 0.03 * 1.2
        static let bloom: Float = 0.72
        static let vibrance: Float = 0.50            // times the image factor
        static let feedbackMixLow: Float = 0.26
        static let feedbackMixHigh: Float = 0.34
        static let feedbackWarp: Float = 0.04
        static let ghostTapMaxDistance: Float = 0.08
    }

    // MARK: - Visual activity (visuals -> music)

    /// How busy the picture is, 0...1, sent to `GenerativeEngine.setVisualActivity` (plan 2.3).
    /// Computed from the un-modulated oscillators on purpose (C12) so music cannot feed back into itself.
    static func visualActivity(time: Float, transitionProgress: Float) -> Float {
        let v = 0.25 + 0.5 * distortionWave01(time: time) + 0.5 * sin(Float.pi * min(max(transitionProgress, 0), 1))
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
        // Scale: gentle breathing between 1.05 and 1.4
        let scale: Float = 1.2 + 0.15 * sin(time * 0.05) + 0.05 * sin(time * 0.03)

        // Offset: wandering pan (normalized to -0.8...0.8 range)
        let maxOffset: Float = 60
        let rawOffsetX = maxOffset * sin(time * 0.04) + 20 * sin(time * 0.025)
        let rawOffsetY = maxOffset * cos(time * 0.035) + 20 * cos(time * 0.02)

        // Normalize offsets (shader expects small values)
        let offsetX = rawOffsetX / 100.0
        let offsetY = rawOffsetY / 100.0

        return KenBurnsParams(scale: scale, offsetX: offsetX, offsetY: offsetY)
    }

    // MARK: - Distortion

    struct DistortionParams {
        let amplitude: Float
        let speed: Float
    }

    // MARK: - Chromatic Aberration

    /// Compute chromatic aberration amount.
    /// Oscillates organically between low and high values, with extra boost during transitions.
    static func computeChromatic(time: Float, transitionProgress: Float = 0,
                                 baseScale: Float = 1, baseAdd: Float = 0) -> Float {
        let low: Float = 0.003
        let high: Float = 0.015

        // Organic oscillation using golden ratio offset from color cycle
        let phi: Float = 1.618034
        let wave = (sin(time * 0.07 * phi) + sin(time * 0.03) * 0.6) / 1.6  // -1..1
        let t = (wave + 1) / 2  // 0..1
        let base = min(max((low + (high - low) * t) * baseScale + baseAdd, 0), Caps.chromaticBase)

        // Boost during transitions
        let transitionBoost = sin(transitionProgress * .pi)
        return base * (1.0 + 3.0 * transitionBoost)
    }

    // MARK: - Log-Spherical Distortion

    /// Compute log-spherical fractal distortion amount.
    /// Oscillates organically with transition boost for kaleidoscopic warping.
    static func computeLogSphere(time: Float, transitionProgress: Float = 0, baseScale: Float = 1) -> Float {
        let low: Float = 0.003
        let high: Float = 0.02

        // Golden ratio offset decorrelated from existing oscillators
        let phi: Float = 1.618034
        let wave = (sin(time * 0.035 * phi * phi) + sin(time * 0.022 / phi) * 0.7) / 1.7  // -1..1
        let t = (wave + 1) / 2  // 0..1
        let base = min(max((low + (high - low) * t) * baseScale, 0), Caps.logSphereBase)

        // 3x boost during transitions
        let transitionBoost = sin(transitionProgress * .pi)
        return base * (1.0 + 2.0 * transitionBoost)
    }

    // MARK: - Sinusoidal Interference Noise

    /// Compute sinusoidal interference noise distortion amount.
    /// Crystalline distortion that complements XorDev's smoky turbulence.
    static func computeFractalNoise(time: Float, transitionProgress: Float = 0, baseScale: Float = 1) -> Float {
        let low: Float = 0.005
        let high: Float = 0.03

        // Golden ratio offset decorrelated from log-sphere and existing oscillators
        let phi: Float = 1.618034
        let wave = (sin(time * 0.028 * phi) + sin(time * 0.045 / (phi * phi)) * 0.6) / 1.6  // -1..1
        let t = (wave + 1) / 2  // 0..1
        let base = min(max((low + (high - low) * t) * baseScale, 0), Caps.fractalNoiseBase)

        // 5x boost during transitions
        let transitionBoost = sin(transitionProgress * .pi)
        return base * (1.0 + 4.0 * transitionBoost)
    }

    // MARK: - Fractal Hue Cycling

    /// Compute fractal hue cycling amount.
    /// No transition boost — color surges during crossfade feel jarring.
    static func computeFractalHue(time: Float) -> Float {
        let low: Float = 0.05
        let high: Float = 0.25

        // Golden ratio offset decorrelated from all other oscillators
        let phi: Float = 1.618034
        let wave = (sin(time * 0.032 / phi) + sin(time * 0.05 * phi * phi) * 0.5) / 1.5  // -1..1
        let t = (wave + 1) / 2  // 0..1
        return low + (high - low) * t
    }

    /// Compute turbulence distortion parameters.
    /// Amplitude oscillates organically over time using layered sine waves with
    /// golden-ratio-offset frequencies for non-repeating motion.
    /// - Parameters:
    ///   - time: Current animation time in seconds
    ///   - transitionProgress: 0-1 progress through crossfade (0 = no transition)
    /// - Returns: Distortion amplitude and speed
    static func computeDistortion(time: Float, transitionProgress: Float = 0,
                                  baseScale: Float = 1, baseAdd: Float = 0) -> DistortionParams {
        let low: Float = 0.02
        let high: Float = 0.08

        let t = distortionWave01(time: time)
        // Music scales the base (pre-boost) amplitude only; the tuned transition boost is unchanged (C7).
        let baseAmplitude = min(max((low + (high - low) * t) * baseScale + baseAdd, 0), Caps.distortionBase)

        let boostMultiplier: Float = 10.0

        // Boost during transitions (sine curve peaks at 50% through)
        let transitionBoost = sin(transitionProgress * .pi)
        let amplitude = baseAmplitude * (1.0 + (boostMultiplier - 1.0) * transitionBoost)

        return DistortionParams(amplitude: amplitude, speed: 0.08)
    }

    /// Organic oscillation of the turbulence amplitude, 0...1: layered sine waves at irrational
    /// frequency ratios. Also the un-modulated input of `visualActivity`.
    static func distortionWave01(time: Float) -> Float {
        let phi: Float = 1.618034
        let wave = (sin(time * 0.04 * phi) + sin(time * 0.025) * 0.7 + sin(time * 0.06 / phi) * 0.4) / 2.1  // -1..1
        return (wave + 1) / 2
    }

}
