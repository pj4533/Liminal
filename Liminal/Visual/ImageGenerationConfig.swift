//
//  ImageGenerationConfig.swift
//  Liminal
//
//  Model and request settings for image generation (docs/decisions/images.md D2, D3).
//

import Foundation

nonisolated struct ImageGenerationConfig: Sendable {
    /// Most photographic and colorful of the models this key exposes.
    var primaryModel = "gemini-3.1-flash-image"
    /// Only model that really melts/unravels; used for part of the needsStrongSurreal prompts.
    var surrealModel = "gemini-nano-banana-2.1"
    /// Share of needsStrongSurreal prompts sent to `surrealModel` (about 10% of all images at 0.5).
    var surrealModelShare = 0.5
    /// Tried in order when the primary is cooling down after quota/server errors.
    var fallbackModels = ["gemini-3.1-flash-lite-image", "gemini-2.5-flash-image"]
    /// 3:2 matches the 110x75 degree dome panel within about 2%.
    var aspectRatio = "3:2"
    /// 2K = 2528x1696, already larger than the renderer texture, so no upscaling.
    var imageSize = "2K"
    /// Fallback models are asked for this size.
    var fallbackImageSize = "1K"
    var requestTimeout: TimeInterval = 60
    /// Backpressure: generate only while fewer than this many images wait for display.
    var targetPendingCount = 2

    static let standard = ImageGenerationConfig()

    /// Primary first, then fallbacks.
    var chain: [String] { [primaryModel] + fallbackModels }

    func imageSize(for model: String) -> String {
        fallbackModels.contains(model) ? fallbackImageSize : imageSize
    }
}
