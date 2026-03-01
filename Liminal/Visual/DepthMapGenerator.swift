//
//  DepthMapGenerator.swift
//  Liminal
//
//  ML depth map generation using DepthAnythingV2 (CoreML).
//  Produces single-channel grayscale depth maps (0=far, 1=near).
//  Runs inference on ANE, ~31ms per image.
//

import CoreML
import CoreImage
import CoreGraphics
import OSLog

/// Thread-safe depth map generator using DepthAnythingV2 CoreML model.
actor DepthMapGenerator {

    private let model: MLModel
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let inputPixelBuffer: CVPixelBuffer
    private let logger = Logger(subsystem: "com.saygoodnight.Liminal", category: "Visual")

    // DepthAnythingV2SmallF16 requires this exact input geometry.
    private static let modelInputWidth = 518
    private static let modelInputHeight = 392

    init?() {
        let config = MLModelConfiguration()
        config.computeUnits = .all  // Prefer ANE

        do {
            guard let modelURL = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc") else {
                logger.error("❌ DepthMapGenerator: Could not find DepthAnythingV2SmallF16.mlmodelc in bundle")
                return nil
            }
            self.model = try MLModel(contentsOf: modelURL, configuration: config)

            guard let inputPixelBuffer = Self.makeInputPixelBuffer(
                width: Self.modelInputWidth,
                height: Self.modelInputHeight
            ) else {
                logger.error("❌ DepthMapGenerator: Failed to create input pixel buffer")
                return nil
            }
            self.inputPixelBuffer = inputPixelBuffer

            logger.info("✅ DepthMapGenerator: Model loaded (\(Self.modelInputWidth)x\(Self.modelInputHeight))")
        } catch {
            logger.error("❌ DepthMapGenerator: Failed to load model: \(error.localizedDescription)")
            return nil
        }
    }

    /// Generate a depth map from a CGImage.
    /// Returns a single-channel grayscale CGImage (0=far, 1=near).
    /// Input is resized to model's expected dimensions automatically.
    /// Inference takes ~31ms on modern hardware.
    func generateDepth(from image: CGImage) throws -> CGImage {
        let startTime = CFAbsoluteTimeGetCurrent()

        // The model only accepts 518x392. Using any other size causes inference failure.
        let targetSize = CGSize(width: Self.modelInputWidth, height: Self.modelInputHeight)
        let sourceImage = CIImage(cgImage: image)
        let scaleX = targetSize.width / sourceImage.extent.width
        let scaleY = targetSize.height / sourceImage.extent.height
        var resized = sourceImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        resized = resized.transformed(
            by: CGAffineTransform(
                translationX: -resized.extent.origin.x,
                y: -resized.extent.origin.y
            )
        )
        ciContext.render(resized, to: inputPixelBuffer)

        // Run inference
        let outputBuffer: CVPixelBuffer
        do {
            let input = try MLDictionaryFeatureProvider(
                dictionary: ["image": MLFeatureValue(pixelBuffer: inputPixelBuffer)]
            )
            let output = try model.prediction(from: input)
            guard let depthBuffer = output.featureValue(for: "depth")?.imageBufferValue else {
                throw DepthMapError.outputExtractionFailed
            }
            outputBuffer = depthBuffer
        } catch {
            throw DepthMapError.inferenceFailed(error)
        }

        // Normalize 16-bit half-float depth to full-range 8-bit grayscale.
        // This produces consistent contrast for mesh displacement and fog.
        let depthCGImage = try normalizeDepthMap(from: outputBuffer)

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger.info("🗺️ DepthMapGenerator: Inference \(String(format: "%.1f", elapsed))ms, output \(depthCGImage.width)x\(depthCGImage.height)")

        return depthCGImage
    }

    private func normalizeDepthMap(from depthBuffer: CVPixelBuffer) throws -> CGImage {
        let pixelFormat = CVPixelBufferGetPixelFormatType(depthBuffer)
        guard pixelFormat == kCVPixelFormatType_OneComponent16Half else {
            throw DepthMapError.unsupportedDepthPixelFormat(pixelFormat)
        }

        let width = CVPixelBufferGetWidth(depthBuffer)
        let height = CVPixelBufferGetHeight(depthBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthBuffer)
        let elementsPerRow = bytesPerRow / MemoryLayout<UInt16>.stride

        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthBuffer) else {
            throw DepthMapError.outputExtractionFailed
        }

        let halfPtr = baseAddress.assumingMemoryBound(to: UInt16.self)

        var minDepth = Float.greatestFiniteMagnitude
        var maxDepth = -Float.greatestFiniteMagnitude

        for y in 0..<height {
            let row = halfPtr.advanced(by: y * elementsPerRow)
            for x in 0..<width {
                let value = Float(Float16(bitPattern: row[x]))
                if value.isFinite {
                    minDepth = min(minDepth, value)
                    maxDepth = max(maxDepth, value)
                }
            }
        }

        guard minDepth.isFinite, maxDepth.isFinite else {
            throw DepthMapError.outputConversionFailed
        }

        let range = max(maxDepth - minDepth, 1e-6)
        let invRange = 1.0 / range

        var normalized = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = halfPtr.advanced(by: y * elementsPerRow)
            let destRowOffset = y * width
            for x in 0..<width {
                let raw = Float(Float16(bitPattern: row[x]))
                let value = raw.isFinite ? raw : minDepth
                let t = max(0, min(1, (value - minDepth) * invRange))
                normalized[destRowOffset + x] = UInt8(t * 255)
            }
        }

        let data = Data(normalized)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw DepthMapError.outputConversionFailed
        }

        return cgImage
    }

    private static func makeInputPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    enum DepthMapError: Error {
        case inferenceFailed(Error)
        case outputExtractionFailed
        case outputConversionFailed
        case unsupportedDepthPixelFormat(OSType)
    }
}
