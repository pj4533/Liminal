// This file is a template with placeholders.
// Real values come from environment variables (Liminal-Dev scheme)
// or are injected during CI/CD builds.
import Foundation

struct Secrets {
    static let geminiKey: String = "${GEMINI_API_KEY}"
}
