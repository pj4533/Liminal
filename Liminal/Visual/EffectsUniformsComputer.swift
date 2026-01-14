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
    ///   - delay: Delay slider value (0-1) from settings - controls feedback trails
    ///   - transitionProgress: Optional crossfade transition progress (0-1) for distortion boost
    ///   - hasSaliencyMap: Whether a saliency texture is available
    /// - Returns: Complete EffectsUniforms ready for the shader
    static func compute(
        time: Float,
        delay: Float,
        transitionProgress: Float = 0,
        hasSaliencyMap: Bool = false
    ) -> EffectsUniforms {

        // Ken Burns: smooth continuous motion
        let kenBurns = computeKenBurns(time: time)

        // Distortion with optional transition boost
        let distortion = computeDistortion(transitionProgress: transitionProgress)

        // Feedback from delay slider
        let feedbackAmount = delay * 0.85  // 0-1 maps to 0-0.85 for usable range

        return EffectsUniforms(
            time: time,
            kenBurnsScale: kenBurns.scale,
            kenBurnsOffsetX: kenBurns.offsetX,
            kenBurnsOffsetY: kenBurns.offsetY,
            distortionAmplitude: distortion.amplitude,
            distortionSpeed: distortion.speed,
            hueBaseShift: 0,
            hueWaveIntensity: 0.5,
            hueBlendAmount: 0.65,
            contrastBoost: 1.4,
            saturationBoost: 1.3,
            feedbackAmount: feedbackAmount,
            feedbackZoom: 0.96,
            feedbackDecay: 0.5,
            saliencyInfluence: hasSaliencyMap ? 0.6 : 0,
            hasSaliencyMap: hasSaliencyMap ? 1.0 : 0.0,
            transitionProgress: transitionProgress
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

    /// Compute fBM distortion parameters.
    /// - Parameter transitionProgress: 0-1 progress through crossfade (0 = no transition)
    /// - Returns: Distortion amplitude and speed
    static func computeDistortion(transitionProgress: Float = 0) -> DistortionParams {
        let baseAmplitude: Float = 0.012
        let boostMultiplier: Float = 10.0

        // Boost during transitions (sine curve peaks at 50% through)
        let transitionBoost = sin(transitionProgress * .pi)
        let amplitude = baseAmplitude * (1.0 + (boostMultiplier - 1.0) * transitionBoost)

        return DistortionParams(amplitude: amplitude, speed: 0.08)
    }

    // MARK: - Individual Components (for partial updates)

    /// Compute just feedback amount from delay slider.
    /// Useful when only feedback needs updating.
    static func feedbackAmount(from delay: Float) -> Float {
        return delay * 0.85
    }
}
