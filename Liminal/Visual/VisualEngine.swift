import Foundation
import Combine
import OSLog

/// Coordinates visual generation.
/// Triggers new images on a schedule with psychedelic prompts.
@MainActor
final class VisualEngine: ObservableObject {

    // MARK: - Configuration

    private var scheduledInterval: TimeInterval { SettingsService.shared.imageInterval }

    // MARK: - State

    @Published private(set) var currentImage: PlatformImage?
    @Published private(set) var nextImage: PlatformImage?  // For morph preloading
    @Published private(set) var isGenerating: Bool = false
    @Published private(set) var totalCachedCount: Int = 0
    @Published private(set) var queuedCount: Int = 0

    private let imageQueue = ImageQueue()
    private var scheduledTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        setupQueueObservation()
    }

    // MARK: - Setup

    private func setupQueueObservation() {
        // Mirror queue's current image
        imageQueue.$currentImage
            .receive(on: RunLoop.main)
            .sink { [weak self] image in
                self?.currentImage = image
            }
            .store(in: &cancellables)

        // Mirror next image for morph preloading
        imageQueue.$nextImage
            .receive(on: RunLoop.main)
            .sink { [weak self] image in
                self?.nextImage = image
            }
            .store(in: &cancellables)

        imageQueue.$isGenerating
            .receive(on: RunLoop.main)
            .sink { [weak self] generating in
                self?.isGenerating = generating
            }
            .store(in: &cancellables)

        imageQueue.$totalCachedCount
            .receive(on: RunLoop.main)
            .sink { [weak self] count in
                self?.totalCachedCount = count
            }
            .store(in: &cancellables)

        imageQueue.$queuedCount
            .receive(on: RunLoop.main)
            .sink { [weak self] count in
                self?.queuedCount = count
            }
            .store(in: &cancellables)

        // Set up prompt builder
        imageQueue.promptBuilder = { [weak self] in
            self?.buildPrompt() ?? "Abstract ambient visual"
        }
    }

    // MARK: - Control

    func start() {
        guard EnvironmentService.shared.hasValidCredentials else {
            LMLog.visual.warning("Cannot start VisualEngine: missing API key")
            return
        }

        imageQueue.start()
        startScheduledAdvances()
        LMLog.visual.info("VisualEngine started")
    }

    func stop() {
        scheduledTimer?.invalidate()
        scheduledTimer = nil
        imageQueue.stop()
        LMLog.visual.info("VisualEngine stopped")
    }

    /// Manually request the next image
    func advance() {
        imageQueue.advance()
    }

    // MARK: - Private

    private func startScheduledAdvances() {
        scheduledTimer = Timer.scheduledTimer(withTimeInterval: scheduledInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.imageQueue.advance()
            }
        }
    }

    // MARK: - Prompt Building

    private func buildPrompt() -> String {
        // Start with strong visual anchors - actual things to render
        var descriptors: [String] = [
            "digital art",
            "4k wallpaper",
            "abstract landscape"
        ]

        // Pick a random visual subject for variety - psychedelic and symbolic
        let subjects = [
            "glowing mushrooms in mystical forest",
            "sacred geometry mandala",
            "third eye opening cosmic vision",
            "psychedelic mushroom kingdom",
            "fractal spiral infinite zoom",
            "lotus flower blooming light rays",
            "serpent coiled around tree of life",
            "melting clock surrealist landscape",
            "kaleidoscope butterfly wings",
            "ancient temple overgrown with vines",
            "all-seeing eye pyramid",
            "bioluminescent jellyfish swarm",
            "crystalline cave with glowing minerals",
            "phoenix rising from flames",
            "moon phases celestial diagram",
            "entheogenic plant spirits",
            "aztec sun stone glowing",
            "dmt entity geometric beings",
            "ayahuasca vine patterns",
            "ouroboros snake eating tail"
        ]
        descriptors.append(subjects.randomElement()!)

        // Random style variations
        let styles = [
            ["dark moody palette", "deep blues and purples", "noir lighting"],
            ["luminous", "golden hour light", "ethereal glow"],
            ["twilight colors", "muted tones", "dusk atmosphere"],
            ["vibrant neon", "electric colors", "psychedelic glow"],
            ["soft pastels", "dreamy atmosphere", "gentle gradients"]
        ]
        descriptors.append(contentsOf: styles.randomElement()!)

        // Random complexity
        let complexities = [
            ["intricate details", "complex textures", "layered depth"],
            ["minimalist", "negative space", "clean lines"],
            ["balanced composition", "focused detail"]
        ]
        descriptors.append(contentsOf: complexities.randomElement()!)

        // Random movement feel
        let movements = [
            ["motion blur", "flowing energy", "swirling"],
            ["still and calm", "frozen moment", "meditative"],
            ["gentle movement", "subtle flow"]
        ]
        descriptors.append(contentsOf: movements.randomElement()!)

        let prompt = descriptors.joined(separator: ", ")
        LMLog.visual.debug("Built prompt: \(prompt.prefix(80))...")
        return prompt
    }
}
