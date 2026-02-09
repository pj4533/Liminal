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
    /// - Returns: Complete EffectsUniforms ready for the shader
    static func compute(
        time: Float,
        transitionProgress: Float = 0,
        hasSaliencyMap: Bool = false,
        ghostTapCount: Int = 0
    ) -> EffectsUniforms {

        // Ken Burns: smooth continuous motion
        let kenBurns = computeKenBurns(time: time)

        // Distortion with optional transition boost
        let distortion = computeDistortion(transitionProgress: transitionProgress)

        // Autonomous color cycling - smooth oscillator produces organic, non-repeating patterns
        let colorCycle = SmoothOscillator.value(at: time)
        let hueBlend = colorCycle * 0.8  // Max blend at 80% to preserve some original color
        let hueWave = colorCycle * 0.6   // Spatial wave intensity also scales with color cycle

        return EffectsUniforms(
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
            feedbackMix: 0.3
        )
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

    /// Compute fBM distortion parameters.
    /// - Parameter transitionProgress: 0-1 progress through crossfade (0 = no transition)
    /// - Returns: Distortion amplitude and speed
    static func computeDistortion(transitionProgress: Float = 0) -> DistortionParams {
        let baseAmplitude: Float = 0.08
        let boostMultiplier: Float = 10.0

        // Boost during transitions (sine curve peaks at 50% through)
        let transitionBoost = sin(transitionProgress * .pi)
        let amplitude = baseAmplitude * (1.0 + (boostMultiplier - 1.0) * transitionBoost)

        return DistortionParams(amplitude: amplitude, speed: 0.08)
    }

}
