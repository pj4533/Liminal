import Foundation
import OSLog
import CoreGraphics
import ImageIO

/// One generated image exactly as the model returned it, plus its decoded CGImage.
nonisolated struct GeneratedImageData: @unchecked Sendable {
    let data: Data          // bytes exactly as returned (JPEG in practice)
    let mimeType: String
    let cgImage: CGImage    // decoded with CGImageSource, no UIImage/NSImage
    let model: String
    let latency: TimeInterval
}

nonisolated enum GeminiError: LocalizedError, Sendable {
    case missingAPIKey
    case http(status: Int, message: String)
    case noImage(finishReason: String?)   // safety block or empty response
    case decodeFailed
    case network(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Gemini API key not configured"
        case .http(let status, let message): return "HTTP \(status): \(message)"
        case .noImage(let reason): return "No image in response (\(reason ?? "no reason"))"
        case .decodeFailed: return "Could not decode the returned image"
        case .network(let message): return "Network error: \(message)"
        }
    }

    /// Quota, server, missing model or network: cool the model down and try the next one.
    var isQuotaOrServer: Bool {
        switch self {
        case .http(let status, _): return status == 429 || status == 404 || status >= 500
        case .network: return true
        default: return false
        }
    }

    /// 400 complaining about imageConfig/imageSize (some models reject the size field).
    var isImageConfigRejection: Bool {
        guard case .http(400, let message) = self else { return false }
        let lower = message.lowercased()
        return lower.contains("imagesize") || lower.contains("image_size") || lower.contains("imageconfig")
            || lower.contains("image_config") || lower.contains("aspect")
    }
}

/// Client for Gemini native image generation.
///
/// ARCHITECTURE NOTE: This is intentionally NOT an actor (and is nonisolated).
/// On visionOS, the 90fps TimelineView can starve cooperative scheduling,
/// causing actor hops to hang indefinitely. The class has no mutable state;
/// URLSession is thread-safe. The API key goes in the x-goog-api-key header,
/// never in the URL, so it cannot leak through URL logging.
nonisolated final class GeminiClient: Sendable {

    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"
    private let timeout: TimeInterval

    init(timeout: TimeInterval = ImageGenerationConfig.standard.requestTimeout) {
        self.timeout = timeout
    }

    // MARK: - Wire types

    private struct GenerateContentRequest: Encodable {
        struct Part: Encodable { let text: String }
        struct Content: Encodable { let parts: [Part] }
        struct ImageConfig: Encodable {
            let aspectRatio: String?
            let imageSize: String?
        }
        struct GenerationConfig: Encodable {
            let responseModalities: [String]
            let imageConfig: ImageConfig?
        }
        let contents: [Content]
        let generationConfig: GenerationConfig
    }

    private struct GenerateContentResponse: Decodable {
        struct Candidate: Decodable {
            let content: Content?
            let finishReason: String?
        }
        struct Content: Decodable { let parts: [Part]? }
        struct Part: Decodable { let inlineData: InlineData? }
        struct InlineData: Decodable {
            let mimeType: String?
            let data: String
        }
        struct PromptFeedback: Decodable { let blockReason: String? }
        struct APIError: Decodable { let message: String?; let code: Int? }

        let candidates: [Candidate]?
        let promptFeedback: PromptFeedback?
        let error: APIError?
    }

    // MARK: - Public API

    /// Generate one image. `imageSize` nil leaves the field out (for models that reject it).
    @concurrent
    func generate(prompt: String, model: String, aspectRatio: String?, imageSize: String?) async throws -> GeneratedImageData {
        let apiKey = EnvironmentService.shared.geminiKey
        guard EnvironmentService.shared.hasValidCredentials else { throw GeminiError.missingAPIKey }
        guard let url = URL(string: "\(baseURL)/\(model):generateContent") else {
            throw GeminiError.http(status: 404, message: "bad model name \(model)")
        }

        let imageConfig = (aspectRatio == nil && imageSize == nil)
            ? nil
            : GenerateContentRequest.ImageConfig(aspectRatio: aspectRatio, imageSize: imageSize)
        let body = GenerateContentRequest(
            contents: [.init(parts: [.init(text: prompt)])],
            generationConfig: .init(responseModalities: ["IMAGE"], imageConfig: imageConfig)
        )

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(body)

        LMLog.gemini.info("🌐 [Gemini] \(model) \(aspectRatio ?? "-") \(imageSize ?? "-"): \(prompt.prefix(80))...")
        let start = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            LMLog.gemini.error("🌐 [Gemini] ❌ network: \(error.localizedDescription)")
            throw GeminiError.network(error.localizedDescription)
        }
        let latency = Date().timeIntervalSince(start)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        let decoded = try? JSONDecoder().decode(GenerateContentResponse.self, from: data)
        guard status == 200 else {
            let message = decoded?.error?.message ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
            LMLog.gemini.error("🌐 [Gemini] ❌ HTTP \(status) from \(model): \(message.prefix(200))")
            throw GeminiError.http(status: status, message: message)
        }
        guard let decoded else {
            throw GeminiError.noImage(finishReason: "unparseable response")
        }

        for candidate in decoded.candidates ?? [] {
            for part in candidate.content?.parts ?? [] {
                guard let inline = part.inlineData, let bytes = Data(base64Encoded: inline.data) else { continue }
                guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(
                        source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                    throw GeminiError.decodeFailed
                }
                let mime = inline.mimeType ?? (bytes.starts(with: [0x89, 0x50]) ? "image/png" : "image/jpeg")
                LMLog.gemini.info("🌐 [Gemini] ✅ \(model) \(cgImage.width)x\(cgImage.height) \(bytes.count) bytes in \(String(format: "%.1f", latency), privacy: .public)s")
                return GeneratedImageData(data: bytes, mimeType: mime, cgImage: cgImage, model: model, latency: latency)
            }
        }

        let reason = decoded.candidates?.first?.finishReason ?? decoded.promptFeedback?.blockReason
        LMLog.gemini.warning("🌐 [Gemini] ⚠️ no image from \(model) (\(reason ?? "none"))")
        throw GeminiError.noImage(finishReason: reason)
    }
}
