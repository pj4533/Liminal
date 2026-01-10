import Foundation
import AppKit
import Vision
import CoreML
import VideoToolbox
import OSLog

/// Upscales images using RealESRGAN CoreML model.
/// Input: any size image (will be resized to 512x512)
/// Output: 2048x2048 upscaled image
actor ImageUpscaler {

    // MARK: - Errors

    enum UpscalerError: LocalizedError {
        case modelNotFound
        case modelLoadFailed(Error)
        case resizeFailed
        case processingFailed(Error)
        case noResult
        case imageConversionFailed

        var errorDescription: String? {
            switch self {
            case .modelNotFound: return "RealESRGAN model not found in bundle"
            case .modelLoadFailed(let error): return "Failed to load model: \(error.localizedDescription)"
            case .resizeFailed: return "Failed to resize image to 512x512"
            case .processingFailed(let error): return "Upscaling failed: \(error.localizedDescription)"
            case .noResult: return "No result from upscaler"
            case .imageConversionFailed: return "Failed to convert result to image"
            }
        }
    }

    // MARK: - State

    private var model: VNCoreMLModel?
    private var isModelLoaded = false

    // MARK: - Public API

    /// Upscale an NSImage using RealESRGAN
    /// - Parameter image: Input image (any size)
    /// - Returns: Upscaled 2048x2048 image
    func upscale(_ image: NSImage) async throws -> NSImage {
        // Load model if needed
        if !isModelLoaded {
            try loadModel()
        }

        guard let model = model else {
            throw UpscalerError.modelNotFound
        }

        // Resize to 512x512 for the model
        guard let resizedImage = resize(image, to: CGSize(width: 512, height: 512)) else {
            throw UpscalerError.resizeFailed
        }

        // Convert to CGImage for Vision
        guard let cgImage = resizedImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw UpscalerError.resizeFailed
        }

        // Process through model
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            throw UpscalerError.processingFailed(error)
        }

        // Extract result
        guard let result = request.results?.first as? VNPixelBufferObservation else {
            throw UpscalerError.noResult
        }

        // Convert pixel buffer to NSImage
        var outputCGImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(result.pixelBuffer, options: nil, imageOut: &outputCGImage)

        guard let finalCGImage = outputCGImage else {
            throw UpscalerError.imageConversionFailed
        }

        let outputImage = NSImage(cgImage: finalCGImage, size: NSSize(width: 2048, height: 2048))
        LMLog.visual.info("Upscaled image to 2048x2048")

        return outputImage
    }

    // MARK: - Private

    private func loadModel() throws {
        guard let modelURL = Bundle.main.url(forResource: "realesrgan512", withExtension: "mlmodelc") else {
            throw UpscalerError.modelNotFound
        }

        do {
            let mlModel = try MLModel(contentsOf: modelURL)
            model = try VNCoreMLModel(for: mlModel)
            isModelLoaded = true
            LMLog.visual.info("RealESRGAN model loaded")
        } catch {
            throw UpscalerError.modelLoadFailed(error)
        }
    }

    private func resize(_ image: NSImage, to size: CGSize) -> NSImage? {
        let newImage = NSImage(size: size)
        newImage.lockFocus()

        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )

        newImage.unlockFocus()
        return newImage
    }
}
