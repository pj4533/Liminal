import Foundation
import OSLog

/// Centralized access to API keys and configuration.
/// Loads from environment variables first (Xcode scheme), falls back to Secrets struct.
final class EnvironmentService {

    // MARK: - Singleton

    static let shared = EnvironmentService()

    // MARK: - Environment Variable Names

    private enum Keys {
        static let gemini = "GEMINI_API_KEY"
    }

    // MARK: - Cached Values

    private var cachedGeminiKey: String?

    // MARK: - Init

    private init() {
        loadEnvironmentVariables()
    }

    // MARK: - Public API

    /// The Gemini API key for image generation
    var geminiKey: String {
        cachedGeminiKey ?? ""
    }

    /// Returns true if we have a real API key (not a placeholder)
    var hasValidCredentials: Bool {
        let key = geminiKey
        return !key.isEmpty && !key.hasPrefix("${")
    }

    // MARK: - Private

    private func loadEnvironmentVariables() {
        LMLog.general.debug("🔑 Loading API keys...")

        // Priority 1: Environment variables (from Xcode scheme)
        let env = ProcessInfo.processInfo.environment
        cachedGeminiKey = env[Keys.gemini]

        // Priority 2: Secrets struct (for CI/CD builds)
        if cachedGeminiKey == nil {
            cachedGeminiKey = Secrets.geminiKey
        }

        // Log status (without exposing the actual key!)
        let geminiValid = hasValidCredentials
        LMLog.gemini.info("Gemini API key: \(geminiValid ? "✅ Available" : "❌ Missing")")

        if !geminiValid {
            LMLog.gemini.warning("⚠️ No valid Gemini API key. Image generation disabled.")
        }
    }
}
