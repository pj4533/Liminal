import Foundation
import OSLog
import CoreGraphics
import ImageIO

/// Manages persistent cache of images.
///
/// Two cache directories:
/// - RawImages/: Original Gemini images (1024x1024 PNG) - cached for re-upscaling
/// - UpscaledImages/: Legacy upscaled images (macOS backward compatibility)
///
/// ARCHITECTURE NOTE: This is intentionally NOT @MainActor.
/// On visionOS, the 90fps TimelineView starves MainActor, causing any
/// @MainActor code to hang indefinitely. FileManager operations are
/// thread-safe, so this class needs no actor isolation.
final class ImageCache: @unchecked Sendable {

    // MARK: - Configuration

    /// Legacy directory for upscaled images (macOS backward compat)
    private let cacheDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let liminalDir = appSupport.appendingPathComponent("Liminal", isDirectory: true)
        let imagesDir = liminalDir.appendingPathComponent("UpscaledImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        return imagesDir
    }()

    /// Directory for raw Gemini images (smaller, for re-upscaling)
    private let rawCacheDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let liminalDir = appSupport.appendingPathComponent("Liminal", isDirectory: true)
        let rawDir = liminalDir.appendingPathComponent("RawImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        return rawDir
    }()

    // MARK: - Public API

    /// Save an upscaled image to the cache
    /// - Parameter image: The upscaled PlatformImage to save
    /// - Returns: The URL where the image was saved
    @discardableResult
    func save(_ image: PlatformImage) throws -> URL {
        let filename = UUID().uuidString + ".png"
        let fileURL = cacheDirectory.appendingPathComponent(filename)

        guard let pngData = image.pngData else {
            throw CacheError.conversionFailed
        }

        try pngData.write(to: fileURL)
        LMLog.visual.debug("Cached upscaled image: \(filename)")

        return fileURL
    }

    /// Load all cached images
    /// - Returns: Array of cached PlatformImages, newest first
    func loadAll() -> [PlatformImage] {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )

            // Filter to only PNG files and sort by creation date (newest first)
            let pngFiles = files.filter { $0.pathExtension == "png" }
            let sortedFiles = pngFiles.sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                return date1 > date2
            }

            var images: [PlatformImage] = []
            for fileURL in sortedFiles {
                if let image = PlatformImage.from(url: fileURL) {
                    images.append(image)
                }
            }

            LMLog.visual.info("Loaded \(images.count) cached upscaled images")
            return images
        } catch {
            LMLog.visual.error("Failed to load cached images: \(error.localizedDescription)")
            return []
        }
    }

    /// Get count of cached images
    var count: Int {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            return files.filter { $0.pathExtension == "png" }.count
        } catch {
            return 0
        }
    }

    /// Clear all cached images
    func clearAll() {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            for file in files where file.pathExtension == "png" {
                try FileManager.default.removeItem(at: file)
            }

            LMLog.visual.info("Cleared image cache")
        } catch {
            LMLog.visual.error("Failed to clear cache: \(error.localizedDescription)")
        }
    }

    /// Get the cache directory URL (for inspection/debugging)
    var directoryURL: URL {
        cacheDirectory
    }

    // MARK: - Raw Data API (visionOS - MainActor-free)

    /// Save raw PNG data directly to cache (no UIImage conversion needed).
    /// Use this on visionOS to avoid MainActor starvation.
    /// - Parameter data: Raw PNG bytes from Gemini
    /// - Returns: The URL where the data was saved
    @discardableResult
    func saveRawData(_ data: Data) throws -> URL {
        let filename = UUID().uuidString + ".png"
        let fileURL = rawCacheDirectory.appendingPathComponent(filename)
        try data.write(to: fileURL)
        LMLog.visual.debug("💾 Cached raw image: \(filename) (\(data.count) bytes)")
        return fileURL
    }

    /// Load all raw cached images as CGImages (completely MainActor-free).
    /// Uses CGImageSource to decode without touching UIImage.
    /// - Returns: Array of CGImages, newest first
    func loadAllRawAsCGImages() -> [CGImage] {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: rawCacheDirectory,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )

            let pngFiles = files.filter { $0.pathExtension == "png" }
            let sortedFiles = pngFiles.sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                return date1 > date2
            }

            var images: [CGImage] = []
            for fileURL in sortedFiles {
                // Use CGImageSource - completely MainActor-free!
                guard let data = try? Data(contentsOf: fileURL),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    continue
                }
                images.append(cgImage)
            }

            LMLog.visual.info("📂 Loaded \(images.count) raw cached images as CGImage")
            return images
        } catch {
            LMLog.visual.error("Failed to load raw cached images: \(error.localizedDescription)")
            return []
        }
    }

    /// Get count of raw cached images
    var rawCount: Int {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: rawCacheDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            return files.filter { $0.pathExtension == "png" }.count
        } catch {
            return 0
        }
    }

    /// Clear all raw cached images
    func clearAllRaw() {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: rawCacheDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            for file in files where file.pathExtension == "png" {
                try FileManager.default.removeItem(at: file)
            }

            LMLog.visual.info("Cleared raw image cache")
        } catch {
            LMLog.visual.error("Failed to clear raw cache: \(error.localizedDescription)")
        }
    }

    // MARK: - Errors

    enum CacheError: LocalizedError {
        case conversionFailed
        case writeFailed(Error)

        var errorDescription: String? {
            switch self {
            case .conversionFailed: return "Failed to convert image to PNG"
            case .writeFailed(let error): return "Failed to write image: \(error.localizedDescription)"
            }
        }
    }
}
