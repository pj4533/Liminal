//
//  ImageSource.swift
//  Liminal
//
//  Where pictures come from (docs/plans/image-api-mode.md 2, decision D36):
//  AI = Gemini generation (with the AI cache as its fallback), API = curated public-domain and
//  openly licensed pictures fetched from library, museum and space-agency APIs.
//

import Foundation

nonisolated enum ImageSource: String, CaseIterable, Codable, Sendable {
    case ai, api

    var title: String {
        switch self {
        case .ai: return "AI"
        case .api: return "API"
        }
    }

    /// One-line explanation under the picker.
    var explanation: String {
        switch self {
        case .ai: return "New pictures are generated with Gemini."
        case .api: return "Curated public-domain pictures from libraries, museums and NASA. No generation."
        }
    }

    static let defaultsKey = "visual.imageSource"
    static let defaultSource: ImageSource = .ai

    /// Accepts "ai" / "api" in any case.
    init?(argument: String) {
        self.init(rawValue: argument.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// The DEBUG flag wins (for this launch only), then the stored setting, then AI.
    static func resolve(stored: String?, debugFlag: String?) -> ImageSource {
        if let flag = debugFlag, let source = ImageSource(argument: flag) { return source }
        if let stored, let source = ImageSource(rawValue: stored) { return source }
        return defaultSource
    }

    /// Readable off the main actor (ImageQueue). SettingsService writes the same key.
    static var current: ImageSource {
        resolve(stored: UserDefaults.standard.string(forKey: defaultsKey), debugFlag: DebugLaunchOptions.imageSource)
    }
}
