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
    var ghostTapMaxDistance: Float  // How far ghost taps travel (0.25 = 25% of image)
    var saliencyInfluence: Float
    var hasSaliencyMap: Float  // 1.0 if saliency map is available, 0.0 otherwise
    var transitionProgress: Float  // 0-1, for GPU crossfade blending
    var ghostTapCount: Float  // Number of active ghost taps (0-8), as float for Metal alignment
    var chromaticAmount: Float  // Radial chromatic aberration strength (0 = off, 0.01 = subtle)
    var feedbackWarpAmount: Float  // Turbulence displacement on feedback UV lookup
    var feedbackMix: Float  // How much previous frame bleeds through (0 = none, 0.3 = trails)
    var bloomRadius: Float  // Stochastic bloom sample offset radius
    var bloomAmount: Float  // Bloom intensity (0 = off)
    var stereoOffset: Float  // Per-eye UV shift, scaled by depth (0 in mono mode)
    var logSphereAmount: Float  // Log-spherical fractal distortion intensity
    var fractalNoiseAmount: Float  // Sinusoidal interference noise distortion intensity
    var fractalHueAmount: Float  // Fractal-driven hue cycling intensity
    // Final VIBRANCE stage (appended last; order must match the Metal struct).
    // Defaults of 0 = stage is a no-op, so debug/dummy initialisers need not list them.
    var vibranceAmount: Float = 0  // Chroma gain for under-saturated pixels (0 = off)
    var blackPoint: Float = 0  // Black-point pull-down before the gain (0 = off)
    // Image transition (docs/plans/transitions.md 9.1; appended last, defaults 0 = no transition).
    var txStyle: Float = 0  // TransitionStyle raw value (0 = classic whole-frame dissolve)
    var txMix: Float = 0  // swap progress M, 0...1
    var txEnv: Float = 0  // envelope E, 0...1 (shader-side fold / swirl / tap gain)
    var txSeed: Float = 0  // 0...1: direction, centre, wedge count, channel order
    var txSoft: Float = 0  // swap mask edge softness; negative = reversed order
    var txAmount: Float = 0  // style amount: Prism stagger, fold, swirl angle, wave, lens, tone fold
    // Archive footage (docs/plans/archive-video.md 2.2; appended last, defaults 0 = no footage).
    var videoMix: Float = 0  // envelope x look ceiling; 0 = the whole footage stage is skipped
    var videoLook: Float = 0  // VideoLook raw value (1 phantom, 2 imprint, 3 window, 4 emerge)
    var videoSeed: Float = 0  // 0...1: drift direction, region shape
    var videoScale: Float = 0  // footage size relative to the frame (1 = cover fit)
    var videoAspect: Float = 0  // (footage width / height) / display aspect: the cover-fit factor
    var videoTintR: Float = 0  // highlight colour (from the picture)
    var videoTintG: Float = 0
    var videoTintB: Float = 0
    var videoShadeR: Float = 0  // shadow colour of the duotone looks
    var videoShadeG: Float = 0
    var videoShadeB: Float = 0
    // Archive footage as a stream of crossfading pieces (docs/decisions/archive-video.md A27; appended last).
    // Layer A above is slot 0 (texture 7), layer B below slot 1 (texture 8); videoMixB 0 = layer B skipped.
    var videoWarp: Float = 0  // share of the picture's warp layer A rides (0...1)
    var videoMixB: Float = 0
    var videoLookB: Float = 0
    var videoSeedB: Float = 0
    var videoScaleB: Float = 0
    var videoAspectB: Float = 0
    var videoWarpB: Float = 0
    // Footage interaction modes (docs/plans/footage-fx.md 6; appended last, defaults 0 = blend only).
    var videoDrive: Float = 0  // FootageDrive raw value of layer A (0 = none)
    var videoDriveAmt: Float = 0  // 0...1: intensity, clarity cycle, fresh hold and the piece's envelope
    var videoKey: Float = 0  // FootageKey raw value of layer A (0 = the look's own mask)
    var videoKeyAmt: Float = 0  // sign = polarity (Shadowplay) / wedge count (Kaleido); size = fold strength
    var videoDriveB: Float = 0
    var videoDriveAmtB: Float = 0
    var videoKeyB: Float = 0
    var videoKeyAmtB: Float = 0
    var tunnelStrength: Float = 0  // Maximum peripheral radial displacement during the image push
    var outgoingZoomScale: Float = 0  // Frozen crop of the fading image; zero outside a swap
}

/// Ghost tap data for shader. Must match Metal struct layout.
/// Passed in separate buffer (index 1) as array of 8 taps.
struct ShaderGhostTap {
    var progress: Float      // 0 = just spawned, 1 = expired
    var directionX: Float    // normalized direction X component
    var directionY: Float    // normalized direction Y component
    var active: Float        // 1.0 if active, 0.0 if slot empty
}
