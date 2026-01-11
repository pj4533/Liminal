import Foundation
import CoreImage
import Combine
import OSLog

/// Manages crossfade transitions between images when new content arrives.
/// Uses Core Image for GPU-accelerated blending at high resolutions.
@MainActor
final class MorphPlayer: ObservableObject {

    // MARK: - Configuration

    private let targetFPS: Double = 30
    private let crossfadeDuration: Double = 1.5  // seconds for crossfade

    // MARK: - State

    @Published private(set) var currentFrame: PlatformImage?
    @Published private(set) var currentSaliencyMap: PlatformImage?  // Saliency map for current target image
    @Published private(set) var isMorphing = false
    @Published private(set) var transitionProgress: Double = 0  // 0-1, for effects to use
    @Published private(set) var poolSize = 0

    private var fromImage: PlatformImage?
    private var toImage: PlatformImage?
    private var fromCIImage: CIImage?
    private var toCIImage: CIImage?
    private var crossfadeStartTime: Date?
    private var displayLink: Timer?

    private var imageHistory: [PlatformImage] = []
    private let maxHistorySize = 10

    // Core Image context for GPU rendering
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Public API

    func start() {
        startDisplayLink()
        LMLog.visual.info("MorphPlayer started (crossfade mode)")
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        LMLog.visual.info("MorphPlayer stopped")
    }

    func setInitialImage(_ image: PlatformImage) {
        currentFrame = image
        addToHistory(image)
        poolSize = imageHistory.count
        LMLog.visual.info("Initial image set")

        // Generate saliency map asynchronously
        Task {
            await generateSaliencyMap(for: image)
        }
    }

    func transitionTo(_ newImage: PlatformImage) {
        guard let current = currentFrame else {
            currentFrame = newImage
            addToHistory(newImage)
            poolSize = imageHistory.count
            LMLog.visual.info("First image displayed (no transition needed)")

            // Generate saliency map asynchronously
            Task {
                await generateSaliencyMap(for: newImage)
            }
            return
        }

        if current.hash == newImage.hash {
            LMLog.visual.debug("Same image, skipping transition")
            return
        }

        if isMorphing {
            LMLog.visual.info("New image arrived during transition - redirecting")
            if let oldTarget = toImage {
                fromImage = oldTarget
                fromCIImage = toCIImage
            }
        } else {
            fromImage = current
            fromCIImage = ciImage(from: current)
        }

        toImage = newImage
        toCIImage = ciImage(from: newImage)
        addToHistory(newImage)
        poolSize = imageHistory.count
        startCrossfade()

        // Generate saliency map for the target image asynchronously
        Task {
            await generateSaliencyMap(for: newImage)
        }
    }

    func addToPool(_ image: PlatformImage) {
        if currentFrame != nil {
            transitionTo(image)
        } else {
            setInitialImage(image)
        }
    }

    // MARK: - Private

    private func addToHistory(_ image: PlatformImage) {
        imageHistory.append(image)
        while imageHistory.count > maxHistorySize {
            imageHistory.removeFirst()
        }
    }

    private func startDisplayLink() {
        displayLink?.invalidate()
        displayLink = Timer.scheduledTimer(withTimeInterval: 1.0 / targetFPS, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateFrame()
            }
        }
    }

    private func startCrossfade() {
        isMorphing = true
        transitionProgress = 0
        crossfadeStartTime = Date()
        LMLog.visual.info("🎨 Starting crossfade transition...")
    }

    private func updateFrame() {
        guard isMorphing,
              fromCIImage != nil,
              toCIImage != nil,
              let startTime = crossfadeStartTime else {
            return
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let progress = min(elapsed / crossfadeDuration, 1.0)
        transitionProgress = progress

        // Generate blended frame using GPU-accelerated Core Image
        if let blended = blendImages(progress: progress) {
            currentFrame = blended
        }

        // Log progress periodically
        if Int(elapsed * 10) % 5 == 0 && Int(elapsed * 10) > 0 {
            LMLog.visual.debug("🔄 CROSSFADE progress=\(String(format: "%.1f", progress * 100))%")
        }

        // Check if complete - DON'T snap to raw 'to' image, keep using blended frame
        if progress >= 1.0 {
            LMLog.visual.info("🔄 CROSSFADE COMPLETE")
            // Final frame is already the fully blended image
            isMorphing = false
            transitionProgress = 0
            fromImage = nil
            toImage = nil
            fromCIImage = nil
            toCIImage = nil
            crossfadeStartTime = nil
        }
    }

    /// GPU-accelerated image blending using Core Image dissolve transition
    private func blendImages(progress: Double) -> PlatformImage? {
        guard let fromCI = fromCIImage, let toCI = toCIImage else { return nil }

        let easedProgress = easeInOutCubic(progress)

        // Use CIDissolveTransition for GPU-accelerated crossfade
        guard let dissolveFilter = CIFilter(name: "CIDissolveTransition") else { return nil }
        dissolveFilter.setValue(fromCI, forKey: kCIInputImageKey)
        dissolveFilter.setValue(toCI, forKey: kCIInputTargetImageKey)
        dissolveFilter.setValue(easedProgress, forKey: kCIInputTimeKey)

        guard let outputCI = dissolveFilter.outputImage else { return nil }

        // Render to CGImage on GPU
        let extent = outputCI.extent
        guard let cgImage = ciContext.createCGImage(outputCI, from: extent) else { return nil }

        // Convert to PlatformImage
        return PlatformImage(cgImage: cgImage)
    }

    /// Convert PlatformImage to CIImage for GPU processing
    private func ciImage(from image: PlatformImage) -> CIImage? {
        guard let cgImage = image.cgImageRepresentation else {
            return nil
        }
        return CIImage(cgImage: cgImage)
    }

    private func easeInOutCubic(_ t: Double) -> Double {
        if t < 0.5 {
            return 4 * t * t * t
        } else {
            return 1 - pow(-2 * t + 2, 3) / 2
        }
    }

    // MARK: - Saliency Analysis

    private func generateSaliencyMap(for image: PlatformImage) async {
        let startTime = Date()

        if let saliencyMap = await DepthAnalyzer.shared.analyzeDepth(from: image) {
            // Update on main actor
            await MainActor.run {
                self.currentSaliencyMap = saliencyMap
            }
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            LMLog.visual.info("🔍 Saliency map generated in \(String(format: "%.0f", elapsed))ms")
        } else {
            LMLog.visual.warning("⚠️ Failed to generate saliency map")
        }
    }
}
