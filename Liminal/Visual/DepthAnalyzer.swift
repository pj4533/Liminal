import Foundation
import Vision
import CoreImage
import OSLog

/// Vision's objectness saliency is sampled in normalized image coordinates by Metal.
actor DepthAnalyzer {
    static let shared = DepthAnalyzer()
    private lazy var ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func analyzeDepth(from image: CGImage) -> CGImage? {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        request.preferBackgroundProcessing = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            guard let buffer = request.results?.first?.pixelBuffer else { return nil }
            let map = CIImage(cvPixelBuffer: buffer)
            return ciContext.createCGImage(map, from: map.extent)
        } catch {
            LMLog.visual.warning("Saliency analysis failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
