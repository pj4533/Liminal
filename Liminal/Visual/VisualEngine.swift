import Foundation
import AppKit
import Combine
import OSLog

/// Coordinates visual generation based on mood state.
/// Triggers new images on schedule and on significant mood changes.
@MainActor
final class VisualEngine: ObservableObject {

    // MARK: - Configuration

    private var scheduledInterval: TimeInterval { SettingsService.shared.imageInterval }
    private let moodChangeThreshold: Float = 0.15     // significant change threshold

    // MARK: - State

    @Published private(set) var currentImage: NSImage?
    @Published private(set) var nextImage: NSImage?  // For morph preloading
    @Published private(set) var isGenerating: Bool = false

    private let imageQueue = ImageQueue()
    private var scheduledTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var lastMoodValues: (Float, Float, Float, Float) = (0.5, 0.3, 0.4, 0.5)

    // Reference to mood state for prompt building
    weak var mood: MoodState?

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

    /// Observe mood for significant changes
    func observeMood(_ moodState: MoodState) {
        self.mood = moodState

        Publishers.CombineLatest4(
            moodState.$brightness,
            moodState.$tension,
            moodState.$density,
            moodState.$movement
        )
        .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
        .sink { [weak self] b, t, d, m in
            self?.handleMoodChange(brightness: b, tension: t, density: d, movement: m)
        }
        .store(in: &cancellables)
    }

    // MARK: - Private

    private func startScheduledAdvances() {
        scheduledTimer = Timer.scheduledTimer(withTimeInterval: scheduledInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.imageQueue.advance()
            }
        }
    }

    private func handleMoodChange(brightness: Float, tension: Float, density: Float, movement: Float) {
        let (lastB, lastT, lastD, lastM) = lastMoodValues

        // Check if any parameter changed significantly
        let changed = abs(brightness - lastB) > moodChangeThreshold ||
                      abs(tension - lastT) > moodChangeThreshold ||
                      abs(density - lastD) > moodChangeThreshold ||
                      abs(movement - lastM) > moodChangeThreshold

        if changed {
            LMLog.visual.debug("Significant mood change detected, requesting new image")
            imageQueue.requestNewImage()
            lastMoodValues = (brightness, tension, density, movement)
        }
    }

    // MARK: - Prompt Building

    private func buildPrompt() -> String {
        guard let mood = mood else {
            return defaultPrompt()
        }

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

        // Brightness affects palette
        if mood.brightness < 0.3 {
            descriptors.append(contentsOf: ["dark moody palette", "deep blues and purples", "noir lighting", "shadows"])
        } else if mood.brightness > 0.7 {
            descriptors.append(contentsOf: ["luminous", "golden hour light", "ethereal glow", "bright and airy"])
        } else {
            descriptors.append(contentsOf: ["twilight colors", "muted tones", "dusk atmosphere"])
        }

        // Tension affects visual complexity
        if mood.tension > 0.6 {
            descriptors.append(contentsOf: ["dramatic angles", "high contrast", "sharp edges", "intense"])
        } else if mood.tension < 0.3 {
            descriptors.append(contentsOf: ["soft focus", "gentle curves", "harmonious", "peaceful"])
        } else {
            descriptors.append(contentsOf: ["balanced composition", "subtle tension"])
        }

        // Density affects detail richness
        if mood.density > 0.6 {
            descriptors.append(contentsOf: ["intricate details", "complex textures", "layered depth", "maximalist"])
        } else if mood.density < 0.3 {
            descriptors.append(contentsOf: ["minimalist", "negative space", "clean lines", "sparse elements"])
        } else {
            descriptors.append(contentsOf: ["moderate detail", "focused composition"])
        }

        // Movement affects dynamism
        if mood.movement > 0.6 {
            descriptors.append(contentsOf: ["motion blur", "flowing energy", "dynamic movement", "swirling"])
        } else if mood.movement < 0.3 {
            descriptors.append(contentsOf: ["still and calm", "frozen moment", "meditative", "tranquil"])
        } else {
            descriptors.append(contentsOf: ["gentle movement", "subtle flow"])
        }

        let prompt = descriptors.joined(separator: ", ")
        LMLog.visual.debug("Built prompt: \(prompt.prefix(80))...")
        return prompt
    }

    private func defaultPrompt() -> String {
        "Digital art, 4k wallpaper, abstract cosmic nebula, ethereal glow, soft colors, peaceful atmosphere, dreamy"
    }
}
