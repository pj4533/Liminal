//
//  EffectsUniforms.swift
//  Liminal
//
//  Uniforms structure for Metal shader - shared between macOS and visionOS.
//

import Foundation

/// Uniforms passed to the Metal shader. Must match the layout in EffectsRenderer.metal.
struct EffectsUniforms {
    var time: Float
    var kenBurnsScale: Float
    var kenBurnsOffsetX: Float
    var kenBurnsOffsetY: Float
    var distortionAmplitude: Float
    var distortionSpeed: Float
    var hueBaseShift: Float
    var hueWaveIntensity: Float
    var hueBlendAmount: Float
    var contrastBoost: Float
    var saturationBoost: Float
    var feedbackAmount: Float
    var feedbackZoom: Float
    var feedbackDecay: Float
    var saliencyInfluence: Float
    var hasSaliencyMap: Float  // 1.0 if saliency map is available, 0.0 otherwise
    var transitionProgress: Float  // 0-1, for GPU crossfade blending
}
