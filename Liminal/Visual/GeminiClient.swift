import Foundation
import OSLog
import CoreGraphics
import ImageIO

/// Client for Gemini API image generation using native multimodal output.
///
/// ARCHITECTURE NOTE: This is intentionally NOT an actor.
/// On visionOS, the 90fps TimelineView can starve cooperative scheduling,
/// causing actor hops to hang indefinitely. Since this class has no mutable
/// state, actor isolation provides no benefit and only adds overhead.
/// URLSession is already thread-safe internally.
final class GeminiClient: Sendable {

    // MARK: - Configuration

    /// Model supporting native image output (Nano Banana - production ready)
    private let model = "gemini-2.5-flash-image"
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    // MARK: - Result Types

    /// Raw image result containing original PNG data and decoded CGImage.
    /// Use this for caching - store the raw data (small), upscale the CGImage on demand.
    struct RawImageResult: Sendable {
        /// Original PNG bytes from Gemini (typically 1024x1024, ~1.5MB)
        let pngData: Data
        /// Decoded CGImage ready for upscaling
        let cgImage: CGImage
    }

    // MARK: - Errors

    enum GeminiError: LocalizedError {
        case missingAPIKey
        case invalidURL
        case networkError(Error)
        case invalidResponse
        case noImageGenerated
        case apiError(String)
        case cgImageCreationFailed

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "Gemini API key not configured"
            case .invalidURL: return "Invalid API URL"
            case .networkError(let error): return "Network error: \(error.localizedDescription)"
            case .invalidResponse: return "Invalid response from API"
            case .noImageGenerated: return "No image in response"
            case .apiError(let message): return "API error: \(message)"
            case .cgImageCreationFailed: return "Failed to create CGImage from data"
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
    /// - Returns: The generated PlatformImage
    func generateImage(prompt: String) async throws -> PlatformImage {
        LMLog.visual.info("🌐 [Gemini] Starting image generation...")

        guard EnvironmentService.shared.hasValidCredentials else {
            LMLog.visual.error("🌐 [Gemini] ❌ Missing API key!")
            throw GeminiError.missingAPIKey
        }
        LMLog.visual.debug("🌐 [Gemini] ✅ API key present")

        let apiKey = EnvironmentService.shared.geminiKey
        let urlString = "\(baseURL)/\(model):generateContent?key=\(apiKey)"

        guard let url = URL(string: urlString) else {
            LMLog.visual.error("🌐 [Gemini] ❌ Invalid URL")
            throw GeminiError.invalidURL
        }
        LMLog.visual.debug("🌐 [Gemini] URL constructed: \(self.model)")

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

        LMLog.visual.info("🌐 [Gemini] Sending request with prompt: \(prompt.prefix(50))...")
        let startTime = Date()

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
            let elapsed = Date().timeIntervalSince(startTime)
            LMLog.visual.info("🌐 [Gemini] Response received in \(String(format: "%.1f", elapsed))s, data size: \(data.count) bytes")
        } catch {
            LMLog.visual.error("🌐 [Gemini] ❌ Network error: \(error.localizedDescription)")
            throw GeminiError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            LMLog.visual.error("🌐 [Gemini] ❌ Invalid response type (not HTTPURLResponse)")
            throw GeminiError.invalidResponse
        }
        LMLog.visual.debug("🌐 [Gemini] HTTP status: \(httpResponse.statusCode)")

        // Parse response
        let decoder = JSONDecoder()
        let result: GenerateContentResponse
        do {
            result = try decoder.decode(GenerateContentResponse.self, from: data)
            LMLog.visual.debug("🌐 [Gemini] Response decoded successfully")
        } catch {
            LMLog.visual.error("🌐 [Gemini] ❌ JSON decode error: \(error.localizedDescription)")
            let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? "not utf8"
            LMLog.visual.error("🌐 [Gemini] Response body preview: \(bodyPreview)")
            throw GeminiError.invalidResponse
        }

        // Check for API error
        if let error = result.error {
            LMLog.visual.error("🌐 [Gemini] ❌ API error: \(error.message) (code: \(error.code ?? -1))")
            throw GeminiError.apiError(error.message)
        }

        // Check HTTP status
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            LMLog.visual.error("🌐 [Gemini] ❌ HTTP \(httpResponse.statusCode): \(body.prefix(200))")
            throw GeminiError.apiError("HTTP \(httpResponse.statusCode)")
        }

        // Extract image from response
        guard let candidates = result.candidates else {
            LMLog.visual.error("🌐 [Gemini] ❌ No candidates in response")
            throw GeminiError.noImageGenerated
        }
        LMLog.visual.debug("🌐 [Gemini] Found \(candidates.count) candidate(s)")

        guard let content = candidates.first?.content else {
            LMLog.visual.error("🌐 [Gemini] ❌ No content in first candidate")
            throw GeminiError.noImageGenerated
        }

        guard let parts = content.parts else {
            LMLog.visual.error("🌐 [Gemini] ❌ No parts in content")
            throw GeminiError.noImageGenerated
        }
        LMLog.visual.debug("🌐 [Gemini] Found \(parts.count) part(s) in response")

        // Find the image part
        for (index, part) in parts.enumerated() {
            if let text = part.text {
                LMLog.visual.debug("🌐 [Gemini] Part \(index): text (\(text.count) chars)")
            }
            if let inlineData = part.inlineData {
                LMLog.visual.debug("🌐 [Gemini] Part \(index): image data (mimeType: \(inlineData.mimeType), base64 length: \(inlineData.data.count))")

                guard let imageData = Data(base64Encoded: inlineData.data) else {
                    LMLog.visual.error("🌐 [Gemini] ❌ Failed to decode base64 for part \(index)")
                    continue
                }
                LMLog.visual.info("🌐 [Gemini] Base64 decoded: \(imageData.count) bytes, creating PlatformImage...")

                guard let image = PlatformImage.from(data: imageData) else {
                    LMLog.visual.error("🌐 [Gemini] ❌ Failed to create PlatformImage from \(imageData.count) bytes (part \(index))")
                    continue
                }

                LMLog.visual.info("🌐 [Gemini] ✅ Image created: \(Int(image.pixelSize.width))x\(Int(image.pixelSize.height))")
                return image
            }
        }

        LMLog.visual.error("🌐 [Gemini] ❌ No valid image found in any parts")
        throw GeminiError.noImageGenerated
    }

    /// Generate an image and return raw PNG data + CGImage for MainActor-free caching.
    /// Use this on visionOS to avoid UIImage operations that can starve MainActor.
    /// - Parameter prompt: The image generation prompt
    /// - Returns: RawImageResult with PNG bytes and decoded CGImage
    func generateImageRaw(prompt: String) async throws -> RawImageResult {
        LMLog.visual.info("🌐 [Gemini] Starting raw image generation...")

        guard EnvironmentService.shared.hasValidCredentials else {
            throw GeminiError.missingAPIKey
        }

        let apiKey = EnvironmentService.shared.geminiKey
        let urlString = "\(baseURL)/\(model):generateContent?key=\(apiKey)"

        guard let url = URL(string: urlString) else {
            throw GeminiError.invalidURL
        }

        // Build request
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

        LMLog.visual.info("🌐 [Gemini] Sending request...")
        let startTime = Date()
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let elapsed = Date().timeIntervalSince(startTime)
        LMLog.visual.info("🌐 [Gemini] Response in \(String(format: "%.1f", elapsed))s")

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw GeminiError.invalidResponse
        }

        let result = try JSONDecoder().decode(GenerateContentResponse.self, from: data)

        if let error = result.error {
            throw GeminiError.apiError(error.message)
        }

        guard let parts = result.candidates?.first?.content?.parts else {
            throw GeminiError.noImageGenerated
        }

        // Find image data and convert directly to CGImage (no UIImage!)
        for part in parts {
            if let inlineData = part.inlineData {
                guard let imageData = Data(base64Encoded: inlineData.data) else {
                    continue
                }

                // Use CGImageSource - completely MainActor-free!
                guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    LMLog.visual.error("🌐 [Gemini] ❌ CGImageSource failed")
                    throw GeminiError.cgImageCreationFailed
                }

                LMLog.visual.info("🌐 [Gemini] ✅ Raw image: \(cgImage.width)x\(cgImage.height), data: \(imageData.count) bytes")
                return RawImageResult(pngData: imageData, cgImage: cgImage)
            }
        }

        throw GeminiError.noImageGenerated
    }
}
