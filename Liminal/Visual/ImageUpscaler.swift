import Foundation
import Vision
import CoreML
import VideoToolbox
import OSLog

/// Upscales images using RealESRGAN CoreML model.
/// Input: CGImage (any size, will be resized to 512x512)
/// Output: CGImage (2048x2048 upscaled)
///
/// ARCHITECTURE: This class is 100% MainActor-free!
/// Uses a dedicated DispatchQueue for CoreML work and works entirely with CGImage.
/// CGImage is a Core Graphics type that is fully thread-safe.
///
/// This is CRITICAL for visionOS where the 90fps render loop starves MainActor.
/// Any `await MainActor.run` would cause continuation starvation.
final class ImageUpscaler {

    // MARK: - Errors

    enum UpscalerError: LocalizedError {
        case modelNotFound
        case modelLoadFailed(Error)
        case resizeFailed
        case processingFailed(Error)
        case noResult
        case imageConversionFailed
        case timeout
        case cancelled
        case invalidInput

        var errorDescription: String? {
            switch self {
            case .modelNotFound: return "RealESRGAN model not found in bundle"
            case .modelLoadFailed(let error): return "Failed to load model: \(error.localizedDescription)"
            case .resizeFailed: return "Failed to resize image to 512x512"
            case .processingFailed(let error): return "Upscaling failed: \(error.localizedDescription)"
            case .noResult: return "No result from upscaler"
            case .imageConversionFailed: return "Failed to convert result to image"
            case .timeout: return "Upscaling timed out (CoreML may not be supported)"
            case .cancelled: return "Upscaling was cancelled"
            case .invalidInput: return "Input CGImage is nil"
            }
        }
    }

    // MARK: - State

    /// Dedicated queue for heavy CoreML work - completely outside actor system
    private let processingQueue = DispatchQueue(
        label: "com.liminal.imageupscaler",
        qos: .userInitiated
    )

    /// Thread-safe state for model (accessed only from processingQueue)
    private var model: VNCoreMLModel?
    private var isModelLoaded = false

    // MARK: - Public API

    /// Upscale a CGImage using RealESRGAN
    /// - Parameter cgImage: Input CGImage (any size)
    /// - Returns: Upscaled 2048x2048 CGImage
    /// - Throws: UpscalerError if upscaling fails
    ///
    /// NOTE: This method is 100% MainActor-free! It can be called from any thread
    /// and will never block on MainActor, which is critical for visionOS.
    func upscale(_ cgImage: CGImage) async throws -> CGImage {
        LMLog.visual.info("🔬 [Upscaler] Starting upscale: input \(cgImage.width)x\(cgImage.height)")

        // Skip upscaling entirely in simulator - CPU-only CoreML is too slow, MetalFX not available
        #if targetEnvironment(simulator)
        LMLog.visual.info("🔬 [Upscaler] ⏭️ SKIPPING (simulator) - returning original CGImage")
        return cgImage

        // visionOS DEVICE: Use MetalFX instead of CoreML (CoreML competes with RealityKit for GPU)
        #elseif os(visionOS)
        LMLog.visual.info("🔬 [Upscaler] Using MetalFX for visionOS device...")
        return try await upscaleWithMetalFX(cgImage)

        // macOS/iOS: Use CoreML RealESRGAN
        #else

        LMLog.visual.debug("🔬 [Upscaler] Running on device, starting CoreML task group...")
        let startTime = Date()

        // Heavy CoreML work on dedicated queue with timeout
        // NO MAINACTOR INVOLVEMENT AT ALL!
        let outputCGImage: CGImage
        do {
            outputCGImage = try await withThrowingTaskGroup(of: CGImage.self) { group in
                group.addTask {
                    LMLog.visual.debug("🔬 [Upscaler] CoreML task started...")
                    return try await self.performUpscaleOnQueue(cgImage)
                }

                group.addTask {
                    LMLog.visual.debug("🔬 [Upscaler] Timeout task started (30s)...")
                    try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                    LMLog.visual.error("🔬 [Upscaler] ❌ TIMEOUT after 30 seconds!")
                    throw UpscalerError.timeout
                }

                // Return first result (success or timeout)
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            LMLog.visual.error("🔬 [Upscaler] ❌ Task group failed after \(String(format: "%.1f", elapsed))s: \(error.localizedDescription)")
            throw error
        }

        let elapsed = Date().timeIntervalSince(startTime)
        LMLog.visual.info("🔬 [Upscaler] ✅ Upscaling completed in \(String(format: "%.1f", elapsed))s: \(outputCGImage.width)x\(outputCGImage.height)")
        return outputCGImage
        #endif
    }

    /// Convenience: Upscale a PlatformImage and return CGImage
    /// Extracts CGImage synchronously (thread-safe on iOS/visionOS) and upscales.
    /// - Parameter image: Input PlatformImage
    /// - Returns: Upscaled CGImage, or original CGImage if upscaling fails
    func upscaleToCGImage(_ image: PlatformImage) async -> CGImage? {
        LMLog.visual.info("🔬 [Upscaler] upscaleToCGImage called, extracting CGImage from PlatformImage...")

        // Extract CGImage - this is thread-safe on iOS/visionOS (UIImage.cgImage)
        // On macOS, NSImage.cgImage(forProposedRect:) is also safe to call from any thread
        guard let inputCGImage = image.cgImageRepresentation else {
            LMLog.visual.error("🔬 [Upscaler] ❌ Could not extract CGImage from PlatformImage!")
            return nil
        }
        LMLog.visual.debug("🔬 [Upscaler] Extracted CGImage: \(inputCGImage.width)x\(inputCGImage.height)")

        do {
            let result = try await upscale(inputCGImage)
            LMLog.visual.info("🔬 [Upscaler] ✅ upscaleToCGImage returning: \(result.width)x\(result.height)")
            return result
        } catch {
            LMLog.visual.error("🔬 [Upscaler] ⚠️ Upscale failed: \(error.localizedDescription), returning original")
            return inputCGImage
        }
    }

    // MARK: - Private

    /// Bridge async/await to GCD - runs heavy work completely outside actor system
    private func performUpscaleOnQueue(_ inputCGImage: CGImage) async throws -> CGImage {
        LMLog.visual.debug("🔬 [Upscaler] performUpscaleOnQueue: bridging to GCD...")

        return try await withCheckedThrowingContinuation { continuation in
            processingQueue.async { [self] in
                LMLog.visual.debug("🔬 [Upscaler] GCD block started on processing queue")

                do {
                    // Load model if needed (on processing queue)
                    if !self.isModelLoaded {
                        LMLog.visual.info("🔬 [Upscaler] Model not loaded, loading now...")
                        try self.loadModel()
                    } else {
                        LMLog.visual.debug("🔬 [Upscaler] Model already loaded")
                    }

                    guard let model = self.model else {
                        LMLog.visual.error("🔬 [Upscaler] ❌ Model is nil after loading!")
                        continuation.resume(throwing: UpscalerError.modelNotFound)
                        return
                    }
                    LMLog.visual.debug("🔬 [Upscaler] Model ready for inference")

                    // Resize to 512x512 for the model
                    LMLog.visual.debug("🔬 [Upscaler] Resizing input to 512x512...")
                    guard let resizedCGImage = resizeCGImage(inputCGImage, to: CGSize(width: 512, height: 512)) else {
                        LMLog.visual.error("🔬 [Upscaler] ❌ Resize to 512x512 failed!")
                        continuation.resume(throwing: UpscalerError.resizeFailed)
                        return
                    }
                    LMLog.visual.debug("🔬 [Upscaler] Resize successful: \(resizedCGImage.width)x\(resizedCGImage.height)")

                    // Process through model
                    LMLog.visual.debug("🔬 [Upscaler] Creating VNCoreMLRequest...")
                    let request = VNCoreMLRequest(model: model)
                    request.imageCropAndScaleOption = .scaleFill

                    let handler = VNImageRequestHandler(cgImage: resizedCGImage, options: [:])
                    LMLog.visual.info("🔬 [Upscaler] Starting CoreML inference...")
                    let inferenceStart = Date()

                    do {
                        try handler.perform([request])
                        let inferenceTime = Date().timeIntervalSince(inferenceStart)
                        LMLog.visual.info("🔬 [Upscaler] CoreML inference completed in \(String(format: "%.2f", inferenceTime))s")
                    } catch {
                        let inferenceTime = Date().timeIntervalSince(inferenceStart)
                        LMLog.visual.error("🔬 [Upscaler] ❌ CoreML inference failed after \(String(format: "%.2f", inferenceTime))s: \(error.localizedDescription)")
                        continuation.resume(throwing: UpscalerError.processingFailed(error))
                        return
                    }

                    // Extract result
                    LMLog.visual.debug("🔬 [Upscaler] Extracting result from request...")
                    guard let result = request.results?.first as? VNPixelBufferObservation else {
                        LMLog.visual.error("🔬 [Upscaler] ❌ No VNPixelBufferObservation in results! resultCount=\(request.results?.count ?? 0)")
                        continuation.resume(throwing: UpscalerError.noResult)
                        return
                    }
                    LMLog.visual.debug("🔬 [Upscaler] Got VNPixelBufferObservation, converting to CGImage...")

                    // Convert pixel buffer to CGImage
                    var outputCGImage: CGImage?
                    let vtStatus = VTCreateCGImageFromCVPixelBuffer(result.pixelBuffer, options: nil, imageOut: &outputCGImage)

                    guard let finalCGImage = outputCGImage else {
                        LMLog.visual.error("🔬 [Upscaler] ❌ VTCreateCGImageFromCVPixelBuffer failed! status=\(vtStatus)")
                        continuation.resume(throwing: UpscalerError.imageConversionFailed)
                        return
                    }

                    LMLog.visual.info("🔬 [Upscaler] ✅ Upscale complete on GCD queue: \(finalCGImage.width)x\(finalCGImage.height)")
                    continuation.resume(returning: finalCGImage)
                } catch {
                    LMLog.visual.error("🔬 [Upscaler] ❌ GCD block threw: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Load the CoreML model (called on processingQueue)
    private func loadModel() throws {
        LMLog.visual.info("🧠 [Upscaler] loadModel: Looking for realesrgan512.mlmodelc...")

        guard let modelURL = Bundle.main.url(forResource: "realesrgan512", withExtension: "mlmodelc") else {
            LMLog.visual.error("🧠 [Upscaler] ❌ realesrgan512.mlmodelc NOT FOUND in bundle!")
            throw UpscalerError.modelNotFound
        }
        LMLog.visual.info("🧠 [Upscaler] Model found at: \(modelURL.lastPathComponent)")

        // Configure compute units based on environment
        // Neural Engine is NOT supported in simulator - it will hang indefinitely
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        LMLog.visual.info("🧠 [Upscaler] Using CPU-only mode (simulator)")
        #else
        config.computeUnits = .cpuAndGPU  // Avoid ANE for large image models
        LMLog.visual.info("🧠 [Upscaler] Using CPU+GPU mode (device)")
        #endif

        do {
            LMLog.visual.debug("🧠 [Upscaler] Loading MLModel...")
            let loadStart = Date()
            let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
            let loadTime = Date().timeIntervalSince(loadStart)
            LMLog.visual.info("🧠 [Upscaler] MLModel loaded in \(String(format: "%.2f", loadTime))s")

            LMLog.visual.debug("🧠 [Upscaler] Creating VNCoreMLModel...")
            model = try VNCoreMLModel(for: mlModel)
            isModelLoaded = true
            LMLog.visual.info("🧠 [Upscaler] ✅ CoreML model ready for inference")
        } catch {
            LMLog.visual.error("🧠 [Upscaler] ❌ Model load failed: \(error.localizedDescription)")
            throw UpscalerError.modelLoadFailed(error)
        }
    }

    // MARK: - MetalFX (visionOS device only)

    #if os(visionOS) && !targetEnvironment(simulator)
    /// Lazy-loaded MetalFX upscaler for visionOS
    private static var metalFXUpscaler: MetalFXUpscaler?
    private static var metalFXInitialized = false

    /// Upscale using MetalFX on visionOS (doesn't compete with RealityKit)
    /// NOTE: MetalFX now runs ASYNC - doesn't block GPU, allowing parallel render loop execution
    private func upscaleWithMetalFX(_ cgImage: CGImage) async throws -> CGImage {
        // Initialize MetalFX upscaler once
        if !Self.metalFXInitialized {
            Self.metalFXUpscaler = MetalFXUpscaler()
            Self.metalFXInitialized = true
            if Self.metalFXUpscaler == nil {
                LMLog.visual.error("🔬 [Upscaler] ⚠️🚨⚠️ MetalFX init FAILED - falling back to original image!")
            }
        }

        guard let upscaler = Self.metalFXUpscaler else {
            LMLog.visual.warning("🔬 [Upscaler] ⚠️ MetalFX not available, returning original")
            return cgImage
        }

        do {
            // MetalFX.upscale() is now async - uses completion handler instead of waitUntilCompleted()
            // This allows the render loop's GPU commands to run in parallel with upscaling
            return try await upscaler.upscale(cgImage)
        } catch {
            LMLog.visual.error("🔬 [Upscaler] ⚠️🚨⚠️ MetalFX upscale FAILED: \(error.localizedDescription)")
            return cgImage
        }
    }
    #endif
}
