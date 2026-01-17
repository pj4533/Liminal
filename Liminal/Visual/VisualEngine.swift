import Foundation
import Combine
import OSLog

/// Coordinates visual generation.
/// Triggers new images on a schedule with psychedelic prompts.
///
/// ARCHITECTURE NOTE for visionOS:
/// The 90fps TimelineView render loop should NOT read from @Published properties.
/// Those require MainActor scheduling, which is starved by the render loop itself.
///
/// Instead, the render loop should read from `imageBuffer` directly:
///   let image = visualEngine.imageBuffer.loadCurrent()
///
/// This bypasses MainActor entirely and uses a lock-free atomic read.
@MainActor
final class VisualEngine: ObservableObject {

    // MARK: - Configuration

    private var scheduledInterval: TimeInterval { SettingsService.shared.imageInterval }

    // MARK: - Atomic Image Buffer (for render loop - bypasses MainActor)

    /// Thread-safe buffer for the 90fps render loop.
    /// Call `imageBuffer.loadCurrent()` directly from render loop.
    /// This does NOT require MainActor and will not cause starvation.
    var imageBuffer: AtomicImageBuffer { imageQueue.imageBuffer }

    // MARK: - State (@Published for UI only - NOT for render loop)

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
        // SURREALIST SCENES - impossible but photographically real
        // Full environments and landscapes, not single objects
        let scenes = [
            // Infinite spaces and impossible architecture
            "endless hallway stretching to infinity with doors on both sides that open to different dimensions",
            "staircase that loops back on itself defying gravity in an MC Escher style building",
            "vast desert landscape where the sand dunes transform into ocean waves mid-motion",
            "cathedral interior where the columns are made of frozen lightning and the ceiling is open sky",
            "room where gravity pulls in multiple directions with furniture on walls and ceiling",

            // Reality bending landscapes
            "forest where the trees are melting like candle wax into pools of color",
            "mountain range that folds into itself like origami against a fractal sky",
            "city skyline reflected in water but the reflection shows a completely different city",
            "field of flowers where each petal contains a tiny universe with stars and galaxies",
            "canyon where the rock layers are actually stacked moments in time showing different eras",

            // Psychedelic environments
            "jungle where bioluminescent patterns pulse through every leaf and vine in waves",
            "cave system where crystalline formations project geometric mandalas on the walls",
            "underwater temple overgrown with coral that glows with inner light",
            "ancient library where the books float and their pages form fractal spirals in the air",
            "garden where the plants grow in sacred geometry patterns and emit visible energy",

            // Liminal and dreamscape spaces
            "abandoned swimming pool filled with clouds instead of water under a starfield ceiling",
            "train station platform that extends infinitely in both directions into fog",
            "hotel corridor where each door opens to a different biome visible through the cracks",
            "empty theater where the stage shows a window into deep space",
            "greenhouse at night where the glass reflects an alien landscape instead of outside",

            // Cosmic and interdimensional vistas
            "cliff edge overlooking an ocean of swirling galaxies instead of water",
            "portal in a meadow showing through to an identical meadow in reverse colors",
            "observatory dome open to reveal nested spheres of different realities",
            "bridge spanning between two moons over a gas giant atmosphere",
            "valley where aurora borealis touches the ground and becomes liquid light rivers",

            // Transformation scenes
            "beach at sunset where the waves are made of liquid mercury reflecting impossible colors",
            "winter forest where snowflakes are tiny geometric crystals visible to the naked eye",
            "desert oasis where the water surface shows the view from outer space looking down",
            "volcanic landscape where the lava flows in slow spiraling fractal patterns",
            "moss-covered ruins being slowly consumed by geometric crystal growth"
        ]

        // Photographic framing for surreal scenes
        let framings = [
            "wide angle establishing shot",
            "cinematic landscape photograph",
            "environmental portrait perspective",
            "panoramic vista capture",
            "intimate scene documentation",
            "dramatic low angle composition",
            "atmospheric long shot"
        ]

        // Lighting that grounds the surreal in reality
        let lighting = [
            "golden hour sunlight casting long shadows",
            "overcast diffused daylight with soft shadows",
            "dramatic storm light breaking through clouds",
            "blue hour twilight with emerging stars",
            "harsh midday sun creating deep contrast",
            "bioluminescent glow as primary illumination",
            "mixed natural and artificial light sources",
            "fog diffused lighting creating depth layers"
        ]

        // Photorealistic rendering cues
        let realism = [
            "captured on medium format film with natural grain",
            "shot on full frame mirrorless with tack sharp detail",
            "large format photography with extreme depth",
            "35mm film aesthetic with subtle color shift",
            "IMAX documentary footage frame grab"
        ]

        // Atmosphere and mood
        let moods = [
            "haunting and dreamlike atmosphere",
            "serene but deeply unsettling feeling",
            "awe-inspiring cosmic scale",
            "intimate yet infinite space",
            "calm before transformation moment",
            "timeless and eternal presence"
        ]

        // Build prompt
        let scene = scenes.randomElement()!
        let framing = framings.randomElement()!
        let light = lighting.randomElement()!
        let realistic = realism.randomElement()!
        let mood = moods.randomElement()!

        // Construct narrative prompt - surreal scene, photographic execution
        let prompt = """
            Photorealistic \(framing) of \(scene). \
            \(light.capitalized). \(mood.capitalized). \
            \(realistic.capitalized). \
            Hyper-detailed environment with realistic materials and physics. \
            Looks like an actual photograph of an impossible place. \
            Not illustration, not digital art, not CGI render. \
            Real camera, real film, surreal subject.
            """

        // Log full prompt with dedicated category
        LMLog.prompt.info("🎨 \(prompt)")
        return prompt
    }
}
