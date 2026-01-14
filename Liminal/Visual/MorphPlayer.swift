import Foundation
import CoreImage
import Combine
import OSLog

/// Manages crossfade transitions between images when new content arrives.
/// On macOS, exposes raw images for GPU shader blending (no Core Image).
/// On visionOS, provides lock-free CGImage access for render loops.
@MainActor
final class MorphPlayer: ObservableObject {

    // MARK: - Configuration

    private let targetFPS: Double = 30
    private let crossfadeDuration: Double = 1.5  // seconds for crossfade

    // MARK: - State

    /// The current target image (what we're transitioning TO, or current if not transitioning)
    @Published private(set) var currentFrame: PlatformImage?
    /// The previous image (what we're transitioning FROM) - for GPU shader blending
    @Published private(set) var previousFrame: PlatformImage?
    @Published private(set) var currentSaliencyMap: PlatformImage?  // Saliency map for current target image
    @Published private(set) var isMorphing = false
    @Published private(set) var transitionProgress: Double = 0  // 0-1, for GPU crossfade
    @Published private(set) var poolSize = 0

    // MARK: - visionOS Render Path (non-published to avoid SwiftUI contention)

    /// Direct CGImage storage for visionOS render loop - bypasses @Published to avoid
    /// SwiftUI observation overhead during 60fps rendering.
    /// On macOS, falls back to currentFrame conversion.
    #if os(visionOS)
    private var _renderCGImage: CGImage?
    private var _renderTransitionProgress: Double = 0
    #endif

    /// CGImage accessor for render loops. On visionOS, uses non-published backing store.
    var currentFrameCGImage: CGImage? {
        #if os(visionOS)
        return _renderCGImage
        #else
        return currentFrame?.cgImageRepresentation
        #endif
    }

    /// Transition progress for render loops. On visionOS, uses non-published backing store.
    var renderTransitionProgress: Double {
        #if os(visionOS)
        return _renderTransitionProgress
        #else
        return transitionProgress
        #endif
    }

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

    /// Start without internal Timer - caller is responsible for calling tick()
    /// Use this on visionOS where we drive updates from the render loop to avoid Timer conflicts
    func startWithoutTimer() {
        LMLog.visual.info("MorphPlayer started (manual tick mode)")
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        LMLog.visual.info("MorphPlayer stopped")
    }

    /// Manual frame update - call this from external render loops (visionOS)
    /// This advances crossfade blending without relying on internal Timer
    func tick() {
        updateFrame()
    }

    func setInitialImage(_ image: PlatformImage) {
        LMLog.visual.info("🔍 setInitialImage: START")

        // On visionOS, populate the non-published render storage directly
        #if os(visionOS)
        if let cgImage = image.cgImageRepresentation {
            _renderCGImage = cgImage
            LMLog.visual.info("🔍 setInitialImage: _renderCGImage set (\(cgImage.width)x\(cgImage.height))")
        } else {
            LMLog.visual.error("🔍 setInitialImage: failed to get CGImage from PlatformImage!")
        }
        #endif

        currentFrame = image
        LMLog.visual.info("🔍 setInitialImage: currentFrame set")
        addToHistory(image)
        LMLog.visual.info("🔍 setInitialImage: added to history")
        poolSize = imageHistory.count
        LMLog.visual.info("🔍 setInitialImage: poolSize updated")
        LMLog.visual.info("Initial image set")

        // TEMPORARILY DISABLED: Saliency generation might be blocking on visionOS
        #if os(macOS)
        Task {
            await generateSaliencyMap(for: image)
        }
        #else
        LMLog.visual.info("🔍 setInitialImage: skipping saliency on visionOS")
        #endif
    }

    func transitionTo(_ newImage: PlatformImage) {
        LMLog.visual.info("🔍 transitionTo: START")
        guard let current = currentFrame else {
            LMLog.visual.info("🔍 transitionTo: no current frame, setting directly")
            currentFrame = newImage
            addToHistory(newImage)
            poolSize = imageHistory.count
            LMLog.visual.info("First image displayed (no transition needed)")

            // TEMPORARILY DISABLED: Saliency generation might be blocking on visionOS
            #if os(macOS)
            Task {
                await generateSaliencyMap(for: newImage)
            }
            #endif
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
        LMLog.visual.info("🔍 transitionTo: crossfade started")

        // TEMPORARILY DISABLED: Saliency generation might be blocking on visionOS
        #if os(macOS)
        Task {
            await generateSaliencyMap(for: newImage)
        }
        #endif
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

        // Set previousFrame for GPU shader blending (macOS)
        // Store the "from" image so shader can blend between previous and current
        previousFrame = fromImage

        LMLog.visual.info("🎨 Starting crossfade transition...")
    }

    private func updateFrame() {
        guard isMorphing,
              let startTime = crossfadeStartTime else {
            return
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let progress = min(elapsed / crossfadeDuration, 1.0)

        // On visionOS, update non-published render storage to avoid SwiftUI contention
        #if os(visionOS)
        _renderTransitionProgress = progress
        // Render blended CGImage directly without PlatformImage conversion
        if let blendedCGImage = blendImagesToCGImage(progress: progress) {
            _renderCGImage = blendedCGImage
        }
        #else
        // macOS: GPU shader blending - just update progress, shader does the blend
        transitionProgress = progress
        // Set currentFrame to target image (shader blends previousFrame → currentFrame)
        if let target = toImage {
            currentFrame = target
        }
        #endif

        // Log progress periodically
        if Int(elapsed * 10) % 5 == 0 && Int(elapsed * 10) > 0 {
            LMLog.visual.debug("🔄 CROSSFADE progress=\(String(format: "%.1f", progress * 100))%")
        }

        // Check if complete
        if progress >= 1.0 {
            LMLog.visual.info("🔄 CROSSFADE COMPLETE")
            isMorphing = false

            #if os(visionOS)
            _renderTransitionProgress = 0
            #else
            transitionProgress = 0
            // Clear previousFrame when transition completes
            previousFrame = nil
            #endif

            fromImage = nil
            toImage = nil
            fromCIImage = nil
            toCIImage = nil
            crossfadeStartTime = nil
        }
    }

    /// GPU-accelerated image blending using Core Image dissolve transition
    private func blendImages(progress: Double) -> PlatformImage? {
        guard let cgImage = blendImagesToCGImage(progress: progress) else { return nil }
        return PlatformImage(cgImage: cgImage)
    }

    /// GPU-accelerated image blending returning CGImage directly (avoids PlatformImage overhead)
    private func blendImagesToCGImage(progress: Double) -> CGImage? {
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
        return ciContext.createCGImage(outputCI, from: extent)
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
