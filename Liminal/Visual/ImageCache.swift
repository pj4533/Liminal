import Foundation
import OSLog

/// Manages persistent cache of upscaled images.
/// Images are stored in Application Support/Liminal/UpscaledImages/
/// Each image is saved with a UUID filename and loaded on startup.
@MainActor
final class ImageCache {

    // MARK: - Configuration

    private let cacheDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let liminalDir = appSupport.appendingPathComponent("Liminal", isDirectory: true)
        let imagesDir = liminalDir.appendingPathComponent("UpscaledImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        return imagesDir
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
