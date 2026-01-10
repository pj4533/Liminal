import Foundation
import AppKit
import OSLog

/// Generates smooth morph frames between two images using RIFE AI interpolation.
actor RIFEMorpher {

    // MARK: - Configuration

    private let rifePath: String
    private let modelPath: String
    private let tempDir: URL

    // MARK: - Errors

    enum MorphError: LocalizedError {
        case rifeNotFound
        case saveFailed
        case morphFailed(String)
        case noFramesGenerated

        var errorDescription: String? {
            switch self {
            case .rifeNotFound: return "RIFE binary not found"
            case .saveFailed: return "Failed to save images for morphing"
            case .morphFailed(let msg): return "Morph failed: \(msg)"
            case .noFramesGenerated: return "No morph frames generated"
            }
        }
    }

    // MARK: - Init

    init() {
        // Path to bundled RIFE binary
        let bundlePath = Bundle.main.resourcePath ?? ""
        let externalPath = (bundlePath as NSString).deletingLastPathComponent + "/External/rife-ncnn-vulkan-20221029-macos"

        // Also check the development path
        let devPath = "/Users/pj4533/Developer/reachy/Liminal/External/rife-ncnn-vulkan-20221029-macos"

        if FileManager.default.fileExists(atPath: externalPath + "/rife-ncnn-vulkan") {
            self.rifePath = externalPath + "/rife-ncnn-vulkan"
            self.modelPath = externalPath + "/rife-v4.6"
        } else {
            self.rifePath = devPath + "/rife-ncnn-vulkan"
            self.modelPath = devPath + "/rife-v4.6"
        }

        // Create temp directory for morph operations
        self.tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("liminal-morph")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        LMLog.visual.info("RIFE initialized: \(self.rifePath)")
    }

    // MARK: - Public API

    /// Generate morph frames between two images
    /// - Parameters:
    ///   - from: Starting image
    ///   - to: Ending image
    ///   - frameCount: Number of intermediate frames to generate (default 30 for ~1 second at 30fps)
    /// - Returns: Array of NSImages including start, intermediates, and end
    func generateMorphFrames(from: NSImage, to: NSImage, frameCount: Int = 30) async throws -> [NSImage] {
        guard FileManager.default.fileExists(atPath: rifePath) else {
            throw MorphError.rifeNotFound
        }

        // Clean temp directory
        let morphID = UUID().uuidString
        let workDir = tempDir.appendingPathComponent(morphID)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workDir)
        }

        // Save input images
        let img0Path = workDir.appendingPathComponent("0.png")
        let img1Path = workDir.appendingPathComponent("1.png")
        let outputDir = workDir.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        guard saveImage(from, to: img0Path),
              saveImage(to, to: img1Path) else {
            throw MorphError.saveFailed
        }

        // Run RIFE
        // Using -n to specify frame count (includes start and end)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rifePath)
        process.arguments = [
            "-0", img0Path.path,
            "-1", img1Path.path,
            "-o", outputDir.path,
            "-n", String(frameCount + 2),  // +2 to include start and end frames
            "-m", modelPath
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        LMLog.visual.debug("Running RIFE: \(frameCount) frames")

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw MorphError.morphFailed(error.localizedDescription)
        }

        if process.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw MorphError.morphFailed("Exit code \(process.terminationStatus): \(output)")
        }

        // Load generated frames
        let files = try FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !files.isEmpty else {
            throw MorphError.noFramesGenerated
        }

        var frames: [NSImage] = []
        for file in files {
            if let image = NSImage(contentsOf: file) {
                frames.append(image)
            }
        }

        LMLog.visual.info("Generated \(frames.count) morph frames")
        return frames
    }

    // MARK: - Private

    private func saveImage(_ image: NSImage, to url: URL) -> Bool {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try pngData.write(to: url)
            return true
        } catch {
            return false
        }
    }
}
