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
    /// - Returns: Complete EffectsUniforms ready for the shader
    static func compute(
        time: Float,
        transitionProgress: Float = 0,
        hasSaliencyMap: Bool = false,
        ghostTapCount: Int = 0,
        vibrance: VibranceFactors = .neutral
    ) -> EffectsUniforms {

        // Ken Burns: smooth continuous motion
        let kenBurns = computeKenBurns(time: time)

        // Distortion with organic oscillation and optional transition boost
        let distortion = computeDistortion(time: time, transitionProgress: transitionProgress)

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
            hueBaseShift: 0,
            hueWaveIntensity: hueWave,
            hueBlendAmount: hueBlend,
            contrastBoost: 1.4,
            saturationBoost: 1.3,
            ghostTapMaxDistance: 0.06,  // Ghost taps travel 6% of image size - slow drift
            saliencyInfluence: hasSaliencyMap ? 0.6 : 0,
            hasSaliencyMap: hasSaliencyMap ? 1.0 : 0.0,
            transitionProgress: transitionProgress,
            ghostTapCount: Float(ghostTapCount),
            chromaticAmount: computeChromatic(time: time, transitionProgress: transitionProgress),
            feedbackWarpAmount: 0.03,
            feedbackMix: 0.3,
            bloomRadius: 0.04,
            bloomAmount: 0.5,
            stereoOffset: 0,
            logSphereAmount: computeLogSphere(time: time, transitionProgress: transitionProgress),
            fractalNoiseAmount: computeFractalNoise(time: time, transitionProgress: transitionProgress),
            fractalHueAmount: computeFractalHue(time: time)
        )
        uniforms.vibranceAmount = computeVibrance(time: time, imageFactor: vibrance.amount)
        uniforms.blackPoint = baseBlackPoint * vibrance.dark
        return uniforms
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
    static func computeChromatic(time: Float, transitionProgress: Float = 0) -> Float {
        let low: Float = 0.003
        let high: Float = 0.015

        // Organic oscillation using golden ratio offset from color cycle
        let phi: Float = 1.618034
        let wave = (sin(time * 0.07 * phi) + sin(time * 0.03) * 0.6) / 1.6  // -1..1
        let t = (wave + 1) / 2  // 0..1
        let base = low + (high - low) * t

        // Boost during transitions
        let transitionBoost = sin(transitionProgress * .pi)
        return base * (1.0 + 3.0 * transitionBoost)
    }

    // MARK: - Log-Spherical Distortion

    /// Compute log-spherical fractal distortion amount.
    /// Oscillates organically with transition boost for kaleidoscopic warping.
    static func computeLogSphere(time: Float, transitionProgress: Float = 0) -> Float {
        let low: Float = 0.003
        let high: Float = 0.02

        // Golden ratio offset decorrelated from existing oscillators
        let phi: Float = 1.618034
        let wave = (sin(time * 0.035 * phi * phi) + sin(time * 0.022 / phi) * 0.7) / 1.7  // -1..1
        let t = (wave + 1) / 2  // 0..1
        let base = low + (high - low) * t

        // 3x boost during transitions
        let transitionBoost = sin(transitionProgress * .pi)
        return base * (1.0 + 2.0 * transitionBoost)
    }

    // MARK: - Sinusoidal Interference Noise

    /// Compute sinusoidal interference noise distortion amount.
    /// Crystalline distortion that complements XorDev's smoky turbulence.
    static func computeFractalNoise(time: Float, transitionProgress: Float = 0) -> Float {
        let low: Float = 0.005
        let high: Float = 0.03

        // Golden ratio offset decorrelated from log-sphere and existing oscillators
        let phi: Float = 1.618034
        let wave = (sin(time * 0.028 * phi) + sin(time * 0.045 / (phi * phi)) * 0.6) / 1.6  // -1..1
        let t = (wave + 1) / 2  // 0..1
        let base = low + (high - low) * t

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
    static func computeDistortion(time: Float, transitionProgress: Float = 0) -> DistortionParams {
        let low: Float = 0.02
        let high: Float = 0.08

        // Organic oscillation: layered sine waves at irrational frequency ratios
        let phi: Float = 1.618034
        let wave = (sin(time * 0.04 * phi) + sin(time * 0.025) * 0.7 + sin(time * 0.06 / phi) * 0.4) / 2.1  // -1..1
        let t = (wave + 1) / 2  // 0..1
        let baseAmplitude = low + (high - low) * t

        let boostMultiplier: Float = 10.0

        // Boost during transitions (sine curve peaks at 50% through)
        let transitionBoost = sin(transitionProgress * .pi)
        let amplitude = baseAmplitude * (1.0 + (boostMultiplier - 1.0) * transitionBoost)

        return DistortionParams(amplitude: amplitude, speed: 0.08)
    }

}
