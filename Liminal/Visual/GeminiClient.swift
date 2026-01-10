import Foundation
import AppKit
import OSLog

/// Client for Gemini API image generation using native multimodal output.
actor GeminiClient {

    // MARK: - Configuration

    /// Model supporting native image output (Nano Banana - production ready)
    private let model = "gemini-2.5-flash-image"
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    // MARK: - Errors

    enum GeminiError: LocalizedError {
        case missingAPIKey
        case invalidURL
        case networkError(Error)
        case invalidResponse
        case noImageGenerated
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "Gemini API key not configured"
            case .invalidURL: return "Invalid API URL"
            case .networkError(let error): return "Network error: \(error.localizedDescription)"
            case .invalidResponse: return "Invalid response from API"
            case .noImageGenerated: return "No image in response"
            case .apiError(let message): return "API error: \(message)"
            }
        }
    }

    // MARK: - Response Types

    private struct GenerateContentResponse: Codable {
        let candidates: [Candidate]?
        let error: APIError?

        struct Candidate: Codable {
            let content: Content?
        }

        struct Content: Codable {
            let parts: [Part]?
        }

        struct Part: Codable {
            let text: String?
            let inlineData: InlineData?
        }

        struct InlineData: Codable {
            let mimeType: String
            let data: String  // base64 encoded
        }

        struct APIError: Codable {
            let message: String
            let code: Int?
        }
    }

    // MARK: - Request Types

    private struct GenerateContentRequest: Codable {
        let contents: [ContentItem]
        let generationConfig: GenerationConfig

        struct ContentItem: Codable {
            let parts: [PartItem]
        }

        struct PartItem: Codable {
            let text: String?
        }

        struct GenerationConfig: Codable {
            let responseModalities: [String]
        }
    }

    // MARK: - Public API

    /// Generate an image from a text prompt
    /// - Parameter prompt: The image generation prompt
    /// - Returns: The generated NSImage
    func generateImage(prompt: String) async throws -> NSImage {
        guard EnvironmentService.shared.hasValidCredentials else {
            throw GeminiError.missingAPIKey
        }

        let apiKey = EnvironmentService.shared.geminiKey
        let urlString = "\(baseURL)/\(model):generateContent?key=\(apiKey)"

        guard let url = URL(string: urlString) else {
            throw GeminiError.invalidURL
        }

        // Build request body
        let request = GenerateContentRequest(
            contents: [
                GenerateContentRequest.ContentItem(
                    parts: [GenerateContentRequest.PartItem(text: prompt)]
                )
            ],
            generationConfig: GenerateContentRequest.GenerationConfig(
                responseModalities: ["TEXT", "IMAGE"]
            )
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        LMLog.visual.debug("Generating image with prompt: \(prompt.prefix(50))...")

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }

        // Parse response
        let decoder = JSONDecoder()
        let result = try decoder.decode(GenerateContentResponse.self, from: data)

        // Check for API error
        if let error = result.error {
            LMLog.visual.error("Gemini API error: \(error.message)")
            throw GeminiError.apiError(error.message)
        }

        // Check HTTP status
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            LMLog.visual.error("HTTP \(httpResponse.statusCode): \(body)")
            throw GeminiError.apiError("HTTP \(httpResponse.statusCode)")
        }

        // Extract image from response
        guard let candidates = result.candidates,
              let content = candidates.first?.content,
              let parts = content.parts else {
            throw GeminiError.noImageGenerated
        }

        // Find the image part
        for part in parts {
            if let inlineData = part.inlineData,
               let imageData = Data(base64Encoded: inlineData.data),
               let image = NSImage(data: imageData) {
                LMLog.visual.info("Image generated successfully (\(Int(image.size.width))x\(Int(image.size.height)))")
                return image
            }
        }

        throw GeminiError.noImageGenerated
    }
}
