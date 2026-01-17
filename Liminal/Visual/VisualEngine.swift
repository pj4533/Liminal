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
            "moss-covered ruins being slowly consumed by geometric crystal growth",

            // Mycelia and fungal consciousness
            "bioluminescent mushroom forest with glowing mycelia networks visible through translucent soil",
            "cathedral-sized mushroom caps in morning mist with gills dripping luminescent spores",
            "forest floor cross-section revealing vast fungal networks connecting every tree root",
            "ancient mushroom ring where the fruiting bodies pulse with synchronized inner light",
            "decaying log transformed into a galaxy of tiny glowing fungi mapping neural pathways",

            // Interconnection and unity
            "forest at golden hour where visible threads of light connect every living thing",
            "redwood grove with root systems forming luminous neural networks beneath glass-like ground",
            "ocean surface that is simultaneously a membrane showing sky and water as one substance",
            "night sky where constellations are connected to flowers below by streams of descending starlight",
            "web of morning dew spanning a meadow where each droplet reflects all other droplets infinitely",

            // Philosophical dissolution
            "figure dissolving into particles that become birds that become clouds that become thoughts",
            "mirror room where each reflection shows a different possible version of the same moment",
            "hourglass landscape where the sand grains are memories flowing between past and future",
            "doorway standing alone in a field opening to show the same field from the perspective of every blade of grass",
            "library where readers are slowly becoming the books they read molecules exchanging across the boundary",

            // Ego death and rebirth
            "human silhouette made entirely of interconnected mycelium threads against cosmic backdrop",
            "ancient tree with visible sap flowing that contains tiny galaxies and nebulae",
            "meditation space where the meditator and the room have begun merging at the edges",
            "chrysalis moment captured where caterpillar matter is neither one thing nor the other",
            "cave painting that shows the painter painting themselves painting the cave"
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

        // Photographic technique variations (all hyperrealistic, neutral colors)
        let techniques = [
            "tack sharp focus throughout with extreme depth of field",
            "shallow depth of field with creamy bokeh isolating subject",
            "macro-level detail visible in textures and surfaces",
            "wide angle lens capturing vast scale",
            "telephoto compression flattening layers dramatically",
            "perfect exposure balancing highlights and shadows",
            "natural lens characteristics with subtle vignette"
        ]

        // Wildcard elements to inject variety
        let wildcards = [
            "tiny figures in distance for scale",
            "single impossible object as focal point",
            "repeating patterns that shift on close inspection",
            "visible energy or light particles in air",
            "reflective surfaces showing alternate realities",
            "organic and geometric forms in tension",
            "decay and growth happening simultaneously",
            "time appearing to flow at different speeds",
            "boundaries between substances dissolving",
            "fractals emerging from natural forms",
            "", "", "" // empty options for sometimes no wildcard
        ]

        // Build prompt with variation
        let scene = scenes.randomElement()!
        let framing = framings.randomElement()!
        let light = lighting.randomElement()!
        let realistic = realism.randomElement()!
        let mood = moods.randomElement()!
        let technique = techniques.randomElement()!
        let wildcard = wildcards.randomElement()!

        // Build wildcard clause only if not empty
        let wildcardClause = wildcard.isEmpty ? "" : " \(wildcard.capitalized)."

        // Construct narrative prompt - surreal scene, hyperrealistic photographic execution
        let prompt = """
            Photorealistic \(framing) of \(scene). \
            \(light.capitalized). \(mood.capitalized). \
            \(technique.capitalized).\(wildcardClause) \
            \(realistic.capitalized). \
            Natural, realistic colors. Hyper-detailed environment with realistic materials and physics. \
            Looks like an actual photograph of an impossible place. \
            Not illustration, not digital art, not CGI render. \
            Real camera, real film, surreal subject.
            """

        // Log full prompt with dedicated category
        LMLog.prompt.info("🎨 \(prompt)")
        return prompt
    }
}
