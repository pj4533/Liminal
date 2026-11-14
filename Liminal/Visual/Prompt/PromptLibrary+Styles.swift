//
//  PromptLibrary+Styles.swift
//  Liminal
//
//  17 styles. 14 photographic, 3 abstract/continuity (22%).
//  Wording rules (docs/decisions/images.md D7): positive phrasing only, no
//  "film scan" or "medium format film", and never the words checked by
//  PromptBuilderTests.bannedWords.
//

import Foundation

nonisolated extension PromptLibrary {

    static let standardStyles: [Style] = [
        // MARK: Photographic

        Style(
            id: "macro", weight: 8,
            lead: "Extreme macro photograph",
            camera: "100mm macro lens, f/8, focus-stacked",
            lighting: "Ring flash softened by diffusion, the background falling away to dark",
            texture: "Visible pores, scales, dew beads, pollen grains and fine fibres",
            scales: [.tiny, .handheld],
            scaleOverrides: ["miniatureOnLeaf"],
            excludedTransformations: ["mountainSize", "spiralHorizon", "flock", "upsideDown", "rising", "standingAlone", "float"],
            compositions: ["closeUp", "centeredHero"],
            moods: [.intimate, .lush], energy: 0.45
        ),
        Style(
            id: "cineStill", weight: 7,
            lead: "Cinematic film still",
            camera: "40mm anamorphic lens, shallow depth of field, oval bokeh",
            lighting: "Motivated practical lights, thin haze, soft halation around the highlights",
            texture: "Fine grain, wet reflective ground, atmospheric depth",
            moods: [.melancholy, .eerie, .intimate], energy: 0.5
        ),
        Style(
            id: "aerochrome", weight: 6,
            lead: "Color infrared landscape photograph in the look of Aerochrome film",
            camera: "50mm lens, deep focus",
            lighting: "Hard late-afternoon sun, long crisp shadows",
            texture: "Fine grain, foliage glowing crimson and pink",
            categories: [.landscape, .plant, .architecture, .vehicle, .object, .instrument, .creature],
            paletteRule: .only(["aerochrome"]),
            moods: [.eerie, .euphoric], energy: 0.7
        ),
        Style(
            id: "longExposure", weight: 6,
            lead: "Long-exposure night photograph",
            camera: "24mm lens, f/11, thirty-second exposure on a tripod",
            lighting: "Ambient twilight plus moving light sources",
            texture: "Light trails, silk-smooth water, star streaks, a razor-sharp static subject",
            categories: [.architecture, .vehicle, .landscape, .celestial, .object, .instrument],
            scales: [.humanSized, .monumental, .landscape],
            scaleOverrides: ["mountainSize"],
            excludedTransformations: ["miniatureOnLeaf"],
            paletteRule: .darkOnly,
            moods: [.serene, .electric, .majestic], energy: 0.55
        ),
        Style(
            id: "underwater", weight: 6,
            lead: "Underwater wide-angle photograph",
            camera: "16mm lens behind a dome port",
            lighting: "Shafts of sunlight slanting down from the surface",
            texture: "Suspended particles, caustic ripples, rising bubbles",
            categories: [.creature, .plant, .architecture, .object, .vehicle, .food, .instrument],
            excludedTransformations: ["flock", "upsideDown", "rising", "float", "miniatureOnLeaf"],
            moods: [.serene, .eerie, .lush], energy: 0.4
        ),
        Style(
            id: "doubleExposure", weight: 4,
            lead: "In-camera double exposure photograph",
            camera: "85mm lens",
            lighting: "A dark silhouette against a deep saturated dusk sky",
            texture: "The silhouette of the subject filled with a second photograph of a vast landscape, soft blended edges",
            categories: [.creature, .plant, .architecture, .instrument, .vehicle, .object],
            kinds: [.plain, .luminous, .hybrid, .multiplicity],
            paletteRule: .any,
            compositions: ["centeredHero"],
            moods: [.melancholy, .serene, .intimate], energy: 0.35
        ),
        Style(
            id: "tiltShift", weight: 5,
            lead: "Tilt-shift photograph from a high vantage, the scene looking like a miniature model",
            camera: "90mm tilt-shift lens",
            lighting: "Bright midday sun, saturated color",
            texture: "Tiny crisp details in a narrow band of focus, creamy blur above and below",
            categories: [.architecture, .vehicle, .landscape, .object, .food, .instrument, .creature, .plant],
            scales: [.humanSized, .monumental, .landscape],
            scaleOverrides: ["mountainSize"],
            excludedTransformations: ["upsideDown", "miniatureOnLeaf", "translucent"],
            compositions: ["centeredHero", "patternHorizon", "vastSpace"],
            moods: [.playful, .euphoric], energy: 0.6
        ),
        Style(
            id: "biolumNight", weight: 6,
            lead: "Night photograph lit only by bioluminescence",
            camera: "35mm lens, f/1.4",
            lighting: "The glow is the only light source, the surroundings near black",
            texture: "Wet surfaces, glowing veins and spores, light spilling onto nearby surfaces",
            paletteRule: .darkOnly,
            moods: [.eerie, .lush, .serene], energy: 0.55
        ),
        Style(
            id: "studioProduct", weight: 3.5,
            lead: "High-end studio product photograph",
            camera: "100mm lens, f/11, focus-stacked",
            lighting: "Softbox key light with a hard rim light, seamless backdrop in a bold palette color that contrasts with the subject",
            texture: "Glossy highlights, beads of moisture, immaculate surfaces",
            categories: [.object, .food, .instrument, .plant, .creature, .vehicle],
            scales: [.tiny, .handheld, .humanSized],
            scaleOverrides: ["miniatureOnLeaf"],
            excludedTransformations: ["mountainSize", "flock", "upsideDown", "rising", "spiralHorizon", "standingAlone", "seabed", "float"],
            paletteRule: .any,
            compositions: ["centeredHero", "lowAngle", "closeUp"],
            moods: [.playful, .intimate, .electric], energy: 0.6
        ),
        Style(
            id: "sunlitStill", weight: 3,
            lead: "Sunlit still-life photograph",
            camera: "70mm lens, f/9",
            lighting: "Hard window sun casting a long graphic shadow across a plaster wall and a glossy tabletop",
            texture: "Crisp shadow edges, glossy highlights, fine surface grain",
            categories: [.object, .food, .instrument, .plant, .creature, .vehicle],
            scales: [.tiny, .handheld, .humanSized],
            scaleOverrides: ["miniatureOnLeaf"],
            excludedTransformations: ["mountainSize", "flock", "upsideDown", "rising", "spiralHorizon", "standingAlone", "seabed", "float"],
            paletteRule: .any,
            compositions: ["centeredHero", "lowAngle", "closeUp"],
            moods: [.serene, .intimate, .playful], energy: 0.5
        ),
        Style(
            id: "aerial", weight: 6,
            lead: "Top-down drone photograph",
            camera: "24mm lens pointing straight down, f/8",
            lighting: "Low sun, long graphic shadows",
            texture: "Repeated shapes, ridges, furrows, strong pattern",
            categories: [.landscape, .architecture, .vehicle, .object, .food, .instrument, .creature, .plant],
            scales: [.humanSized, .monumental, .landscape],
            scaleOverrides: ["mountainSize"],
            excludedTransformations: ["upsideDown", "rising", "miniatureOnLeaf", "translucent", "flock"],
            compositions: ["topDown"],
            moods: [.majestic, .serene], energy: 0.5
        ),
        Style(
            id: "grandLandscape", weight: 6,
            lead: "Large-format landscape photograph",
            camera: "90mm view-camera lens, f/22, everything in focus",
            lighting: "Golden hour light with fog lying in layers",
            texture: "Rock strata, water and cloud detail from foreground to horizon",
            scales: [.humanSized, .monumental, .landscape],
            scaleOverrides: ["mountainSize"],
            excludedTransformations: ["miniatureOnLeaf", "translucent"],
            compositions: ["lowAngle", "symmetryReflection", "patternHorizon", "vastSpace", "throughOpening", "centeredHero"],
            moods: [.majestic, .serene, .ominous], energy: 0.45
        ),
        Style(
            id: "flashNight", weight: 5,
            lead: "Direct on-camera flash photograph at night",
            camera: "28mm lens, hard flash",
            lighting: "The subject brightly lit against a black background",
            texture: "Saturated color, sharp specular highlights, a hard shadow directly behind",
            categories: [.object, .food, .creature, .plant, .vehicle, .instrument, .architecture],
            scales: [.tiny, .handheld, .humanSized],
            excludedTransformations: ["mountainSize", "spiralHorizon", "flock", "rising"],
            paletteRule: .darkOnly,
            compositions: ["centeredHero", "lowAngle", "closeUp"],
            moods: [.playful, .electric, .eerie], energy: 0.75
        ),
        Style(
            id: "prism", weight: 5,
            lead: "Photograph shot through a glass prism held against the lens",
            camera: "50mm lens, f/2",
            lighting: "Backlit, strong sun flare",
            texture: "Rainbow flares, mirrored fragments of the subject repeating around the outer edges",
            excludedTransformations: ["spiralHorizon"],
            compositions: ["centeredHero", "closeUp", "lowAngle"],
            moods: [.euphoric, .electric], energy: 0.8
        ),

        // MARK: Abstract and continuity

        Style(
            id: "liquidAbstract", family: .abstract, weight: 8,
            lead: "Macro photograph of real fluids",
            camera: "100mm macro lens, backlit on a light table",
            lighting: "Clean transmitted light glowing through the liquid",
            texture: "Fine swirls, sharp droplet edges, layered translucent color that fills the whole picture with pattern",
            kinds: [.plain],
            paletteRule: .any,
            compositions: ["closeUp", "topDown", "centeredHero"],
            moods: [.electric, .euphoric, .playful], energy: 0.7,
            ownSubjects: liquidSubjects
        ),
        Style(
            id: "fractalNature", family: .abstract, weight: 8,
            lead: "Photograph of a natural fractal structure",
            camera: "100mm lens, f/11, tack sharp",
            lighting: "Raking side light that carves out every repeating step",
            texture: "Self-similar detail repeating at every scale, crisp edges",
            kinds: [.plain],
            compositions: ["closeUp", "topDown", "centeredHero", "patternHorizon"],
            moods: [.serene, .majestic, .lush], energy: 0.5,
            ownSubjects: fractalSubjects
        ),
        Style(
            id: "cosmicDream", family: .abstract, weight: 6,
            lead: "Photorealistic wide view of an impossible place",
            camera: "24mm lens, deep focus",
            lighting: "Luminous atmospheric light with depth in layers",
            texture: "Real materials, wet stone, mist and fine detail into the distance",
            kinds: [.plain],
            compositions: ["vastSpace", "lowAngle", "symmetryReflection", "throughOpening", "centeredHero"],
            moods: [.majestic, .eerie, .euphoric], energy: 0.6,
            ownSubjects: cosmicScenes
        ),
    ]

    static let standardCompositions: [Composition] = [
        Composition(id: "centeredHero", fragment: "Centered at eye level, the subject seen whole", weight: 1.4),
        Composition(id: "lowAngle", fragment: "Low angle looking up at it like a monument against the sky", weight: 1),
        Composition(id: "topDown", fragment: "Seen straight from above, flat and graphic", weight: 0.8),
        Composition(id: "symmetryReflection", fragment: "Perfectly symmetrical composition with a mirror reflection below", weight: 0.8),
        Composition(id: "patternHorizon", fragment: "The pattern repeats toward the horizon", weight: 0.7),
        Composition(id: "closeUp", fragment: "Extreme close-up, surface detail filling the view", weight: 0.9),
        Composition(id: "vastSpace", fragment: "The subject small and alone in vast open space", weight: 0.8),
        Composition(id: "throughOpening", fragment: "Seen through a soft out-of-focus opening in the foreground", weight: 0.7),
    ]

    /// Fixed closing sentences. This exact wording tested clean (no borders, no text).
    static let tail = "One large focal subject filling at least a third of the picture with a strong readable silhouette, crisp edges and rich tactile surface texture, uncluttered surroundings. Full-bleed photograph: the scene fills the entire image edge to edge. Physically plausible materials and light, as if really photographed. The image contains only the scene itself: no lettering, no logos, no people."

    static let fullBleedSentence = "Full-bleed photograph: the scene fills the entire image edge to edge."

    static let blankClause = "all surfaces blank and unmarked"
}
