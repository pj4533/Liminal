//
//  ImageGenerationConfig.swift
//  Liminal
//
//  Model and request settings for image generation (docs/decisions/images.md D2, D3).
//

import Foundation

nonisolated struct ImageGenerationConfig: Sendable {
    /// Newest image model on the key (D35, 2026-11-15): Google's successor to the deprecated
    /// gemini-3.1-flash-image, better realism, and $0.05 per 2K image (half the old primary).
    /// Policy: always use the latest non-deprecated image model; re-check with ListModels.
    var primaryModel = "gemini-nano-banana-2.1"
    /// The surreal split is retired now that the primary is the model that melts best (D35).
    var surrealModel = "gemini-nano-banana-2.1"
    var surrealModelShare = 0.0
    /// Tried when the primary is cooling down after quota/server errors (current generation only;
    /// deprecated 3.1-flash and old 2.5-flash removed). Then the cache is recycled.
    var fallbackModels = ["gemini-3.1-flash-lite-image"]
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
