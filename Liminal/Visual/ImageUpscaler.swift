import Foundation
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
        case timeout

        var errorDescription: String? {
            switch self {
            case .modelNotFound: return "RealESRGAN model not found in bundle"
            case .modelLoadFailed(let error): return "Failed to load model: \(error.localizedDescription)"
            case .resizeFailed: return "Failed to resize image to 512x512"
            case .processingFailed(let error): return "Upscaling failed: \(error.localizedDescription)"
            case .noResult: return "No result from upscaler"
            case .imageConversionFailed: return "Failed to convert result to image"
            case .timeout: return "Upscaling timed out (CoreML may not be supported)"
            }
        }
    }

    // MARK: - State

    private var model: VNCoreMLModel?
    private var isModelLoaded = false

    // MARK: - Public API

    /// Upscale a PlatformImage using RealESRGAN
    /// - Parameter image: Input image (any size)
    /// - Returns: Upscaled 2048x2048 image, or original image if upscaling fails/skipped
    @MainActor
    func upscale(_ image: PlatformImage) async -> PlatformImage {
        // Skip upscaling entirely in simulator - CPU-only is too slow
        #if targetEnvironment(simulator)
        LMLog.visual.info("⏭️ SKIPPING UPSCALE (simulator) - using original 1024x1024")
        return image
        #else

        // Extract CGImage on main actor (where PlatformImage access is safe)
        guard let inputCGImage = image.cgImageRepresentation else {
            LMLog.visual.error("⚠️🚨⚠️ UPSCALER FAILED: Could not extract CGImage from input ⚠️🚨⚠️")
            LMLog.visual.error("⚠️🚨⚠️ RETURNING ORIGINAL IMAGE (NOT UPSCALED) ⚠️🚨⚠️")
            return image
        }

        do {
            // Do the actual upscaling work with a 30-second timeout
            let outputCGImage = try await withThrowingTaskGroup(of: CGImage.self) { group in
                group.addTask {
                    try await self.upscaleCGImage(inputCGImage)
                }

                group.addTask {
                    try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                    throw UpscalerError.timeout
                }

                // Return first result (success or timeout)
                let result = try await group.next()!
                group.cancelAll()
                return result
            }

            LMLog.visual.info("✅ Upscaling completed successfully")
            // Convert back to PlatformImage on main actor
            return PlatformImage(cgImage: outputCGImage)
        } catch {
            // LOUD logging so we know upscaling failed
            LMLog.visual.error("⚠️🚨⚠️ UPSCALER FAILED ⚠️🚨⚠️")
            LMLog.visual.error("⚠️🚨⚠️ Error: \(error.localizedDescription) ⚠️🚨⚠️")
            LMLog.visual.error("⚠️🚨⚠️ RETURNING ORIGINAL IMAGE (NOT UPSCALED) ⚠️🚨⚠️")
            return image
        }
        #endif
    }

    /// Internal upscaling that works with CGImage (can run on any thread)
    private func upscaleCGImage(_ inputCGImage: CGImage) async throws -> CGImage {
        // Load model if needed
        if !isModelLoaded {
            try loadModel()
        }

        guard let model = model else {
            throw UpscalerError.modelNotFound
        }

        // Resize to 512x512 for the model using nonisolated helper
        guard let resizedCGImage = resizeCGImage(inputCGImage, to: CGSize(width: 512, height: 512)) else {
            throw UpscalerError.resizeFailed
        }

        // Process through model
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill

        #if targetEnvironment(simulator)
        request.usesCPUOnly = true  // Neural Engine not available in simulator
        #endif

        let handler = VNImageRequestHandler(cgImage: resizedCGImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            throw UpscalerError.processingFailed(error)
        }

        // Extract result
        guard let result = request.results?.first as? VNPixelBufferObservation else {
            throw UpscalerError.noResult
        }

        // Convert pixel buffer to CGImage
        var outputCGImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(result.pixelBuffer, options: nil, imageOut: &outputCGImage)

        guard let finalCGImage = outputCGImage else {
            throw UpscalerError.imageConversionFailed
        }

        return finalCGImage
    }

    // MARK: - Private

    private func loadModel() throws {
        guard let modelURL = Bundle.main.url(forResource: "realesrgan512", withExtension: "mlmodelc") else {
            throw UpscalerError.modelNotFound
        }

        // Configure compute units based on environment
        // Neural Engine is NOT supported in simulator - it will hang indefinitely
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        LMLog.visual.info("🧠 CoreML: Using CPU-only mode (simulator)")
        #else
        config.computeUnits = .cpuAndGPU  // Avoid ANE for large image models
        LMLog.visual.info("🧠 CoreML: Using CPU+GPU mode (device)")
        #endif

        do {
            let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
            model = try VNCoreMLModel(for: mlModel)
            isModelLoaded = true
            LMLog.visual.info("🧠 CoreML model loaded successfully")
        } catch {
            throw UpscalerError.modelLoadFailed(error)
        }
    }

}
