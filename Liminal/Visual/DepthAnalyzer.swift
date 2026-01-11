import Foundation
import Vision
import CoreImage
import OSLog

/// Analyzes images to generate saliency maps using Apple Vision framework.
/// Saliency maps identify "interesting" regions for varying visual effects.
final class DepthAnalyzer {

    static let shared = DepthAnalyzer()

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private init() {}

    /// Generate a saliency map from an image.
    /// Returns a grayscale image where bright = salient/interesting regions.
    /// Uses objectness-based saliency to find subjects vs background.
    func analyzeDepth(from image: PlatformImage) async -> PlatformImage? {
        guard let cgImage = image.cgImageRepresentation else {
            LMLog.visual.error("DepthAnalyzer: Failed to get CGImage")
            return nil
        }

        return await withCheckedContinuation { continuation in
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {
                // Use objectness-based saliency to identify subjects/objects
                let saliencyRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
                try handler.perform([saliencyRequest])

                if let observation = saliencyRequest.results?.first {
                    let pixelBuffer = observation.pixelBuffer
                    let saliencyImage = self.pixelBufferToPlatformImage(pixelBuffer, targetSize: image.pixelSize)
                    LMLog.visual.info("DepthAnalyzer: Generated objectness saliency map")
                    continuation.resume(returning: saliencyImage)
                } else {
                    LMLog.visual.warning("DepthAnalyzer: No saliency result")
                    continuation.resume(returning: nil)
                }
            } catch {
                LMLog.visual.error("DepthAnalyzer: \(error.localizedDescription)")
                continuation.resume(returning: nil)
            }
        }
    }

    /// Convert pixel buffer to PlatformImage at target size
    private func pixelBufferToPlatformImage(_ pixelBuffer: CVPixelBuffer, targetSize: CGSize) -> PlatformImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Scale to match source image dimensions
        let scaleX = targetSize.width / ciImage.extent.width
        let scaleY = targetSize.height / ciImage.extent.height
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        guard let cgImage = ciContext.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        return PlatformImage(cgImage: cgImage)
    }
}
