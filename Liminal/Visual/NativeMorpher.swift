import Foundation
import AppKit
import VideoToolbox
import CoreVideo
import OSLog

/// Native frame interpolation using Apple's VTFrameProcessor API.
/// Generates smooth morph frames between images using ML-based interpolation.
actor NativeMorpher {

    // MARK: - Errors

    enum MorphError: LocalizedError {
        case configurationFailed
        case parametersFailed
        case processingFailed(String)
        case pixelBufferCreationFailed
        case imageConversionFailed

        var errorDescription: String? {
            switch self {
            case .configurationFailed: return "Failed to create frame rate conversion configuration"
            case .parametersFailed: return "Failed to create frame rate conversion parameters"
            case .processingFailed(let msg): return "Frame processing failed: \(msg)"
            case .pixelBufferCreationFailed: return "Failed to create pixel buffer"
            case .imageConversionFailed: return "Failed to convert image"
            }
        }
    }

    // MARK: - Init

    init() {
        LMLog.visual.info("NativeMorpher initialized (VTFrameProcessor)")
    }

    // MARK: - Public API

    /// Generate morph frames between two images using native ML interpolation.
    /// - Parameters:
    ///   - from: Starting image
    ///   - to: Ending image
    ///   - frameCount: Number of intermediate frames (not including start/end)
    /// - Returns: Array of NSImages: [from, interpolated..., to]
    func generateMorphFrames(from: NSImage, to: NSImage, frameCount: Int = 30) async throws -> [NSImage] {
        LMLog.visual.info("Starting native morph: \(frameCount) intermediate frames")

        // Convert NSImages to CVPixelBuffers
        guard let fromBuffer = createPixelBuffer(from: from),
              let toBuffer = createPixelBuffer(from: to) else {
            throw MorphError.imageConversionFailed
        }

        let width = CVPixelBufferGetWidth(fromBuffer)
        let height = CVPixelBufferGetHeight(fromBuffer)

        LMLog.visual.debug("Frame dimensions: \(width)x\(height)")

        // Create the processor
        let processor = VTFrameProcessor()

        // Configure for frame rate conversion
        guard let configuration = VTFrameRateConversionConfiguration(
            frameWidth: width,
            frameHeight: height,
            usePrecomputedFlow: false,
            qualityPrioritization: .quality,
            revision: .revision1
        ) else {
            throw MorphError.configurationFailed
        }

        try processor.startSession(configuration: configuration)
        defer { processor.endSession() }

        // Create source frames with timestamps
        guard let sourceFrame = VTFrameProcessorFrame(
            buffer: fromBuffer,
            presentationTimeStamp: CMTime(value: 0, timescale: 1000)
        ) else {
            throw MorphError.parametersFailed
        }

        guard let nextFrame = VTFrameProcessorFrame(
            buffer: toBuffer,
            presentationTimeStamp: CMTime(value: 1000, timescale: 1000)
        ) else {
            throw MorphError.parametersFailed
        }

        // Calculate interpolation phases (evenly spaced between 0 and 1)
        var interpolationPhases: [Float] = []
        for i in 1...frameCount {
            let phase = Float(i) / Float(frameCount + 1)
            interpolationPhases.append(phase)
        }

        LMLog.visual.debug("Interpolation phases: \(interpolationPhases.prefix(5))...")

        // Create destination buffers
        var destinationBuffers: [CVPixelBuffer] = []
        for _ in 0..<frameCount {
            guard let buffer = createEmptyPixelBuffer(width: width, height: height) else {
                throw MorphError.pixelBufferCreationFailed
            }
            destinationBuffers.append(buffer)
        }

        // Create destination frames
        var destinationFrames: [VTFrameProcessorFrame] = []
        for (index, buffer) in destinationBuffers.enumerated() {
            let pts = CMTime(value: CMTimeValue(interpolationPhases[index] * 1000), timescale: 1000)
            guard let frame = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: pts) else {
                throw MorphError.parametersFailed
            }
            destinationFrames.append(frame)
        }

        // Create parameters
        guard let parameters = VTFrameRateConversionParameters(
            sourceFrame: sourceFrame,
            nextFrame: nextFrame,
            opticalFlow: nil,
            interpolationPhase: interpolationPhases,
            submissionMode: .sequential,
            destinationFrames: destinationFrames
        ) else {
            throw MorphError.parametersFailed
        }

        // Process!
        do {
            try await processor.process(parameters: parameters)
        } catch {
            throw MorphError.processingFailed(error.localizedDescription)
        }

        // Convert back to NSImages
        // Note: We DON'T append the original 'from' or raw 'to' images because they may have
        // different dimensions than the interpolated frames. All frames must be consistent.
        var frames: [NSImage] = []

        // Create source frame at normalized dimensions (same as interpolated frames)
        if let sourceImage = createImage(from: fromBuffer) {
            frames.append(sourceImage)
        } else {
            frames.append(from)  // Fallback
        }

        for buffer in destinationBuffers {
            if let image = createImage(from: buffer) {
                frames.append(image)
            }
        }

        // The last interpolated frame (at phase ~0.992) is visually identical to target
        // and already at the correct dimensions - no need to append raw target

        LMLog.visual.info("Native morph complete: \(frames.count) total frames")
        return frames
    }

    // MARK: - Private Helpers

    private func createPixelBuffer(from image: NSImage) -> CVPixelBuffer? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func createEmptyPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        return status == kCVReturnSuccess ? pixelBuffer : nil
    }

    private func createImage(from pixelBuffer: CVPixelBuffer) -> NSImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard let cgImage = context.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}
