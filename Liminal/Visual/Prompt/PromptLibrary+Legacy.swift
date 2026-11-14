//
//  PromptLibrary+Legacy.swift
//  Liminal
//
//  Subject lists for the three abstract/continuity styles.
//
//  cosmicScenes are the survivors of the 50 scenes that VisualEngine.buildPrompt()
//  used before prompt version 2: the ones that name a concrete place. The
//  abstract-metaphor scenes ("stacked moments in time") were dropped because
//  models render them as generic digital art (docs/decisions/images.md D6).
//  fractalSubjects and liquidSubjects carry the old fractal and pattern
//  vocabulary as real photographed things.
//

import Foundation

nonisolated extension PromptLibrary {

    private static func scene(_ id: String, _ phrase: String, _ category: SubjectCategory,
                              _ scale: SubjectScale = .landscape) -> Subject {
        Subject(id: id, phrase: phrase, plural: phrase, category: category, scale: scale, textProne: false)
    }

    static let cosmicScenes: [Subject] = [
        scene("galaxySapTree", "an ancient tree whose visible sap flows with tiny galaxies and nebulae", .plant),
        scene("mercuryBeach", "a beach at sunset where the waves are made of liquid mercury", .landscape),
        scene("nestedObservatory", "an observatory dome opened to reveal nested glass spheres, each holding a different sky", .architecture),
        scene("cathedralMushrooms", "cathedral-sized mushroom caps in morning mist, their gills dripping luminous spores", .plant),
        scene("auroraRivers", "a valley where the aurora touches the ground and becomes rivers of liquid light", .landscape),
        scene("origamiMountains", "a mountain range folded like origami paper under a deep sky", .landscape),
        scene("otherCity", "a city skyline reflected in a still river, the reflection showing a completely different city", .architecture),
        scene("fungalNetwork", "a forest floor cut away in cross-section to reveal glowing fungal threads linking every tree root", .plant),
        scene("cloudPool", "an abandoned swimming pool filled with clouds instead of water under a starry sky", .architecture),
        scene("alienGreenhouse", "a greenhouse at night whose glass reflects an alien landscape instead of the garden outside", .architecture),
        scene("galaxyOcean", "a cliff edge overlooking an ocean of swirling galaxies instead of water", .celestial),
        scene("coralTemple", "an underwater temple overgrown with coral that glows with inner light", .architecture),
        scene("moonBridge", "a stone bridge spanning between two moons above the clouds of a gas giant", .celestial),
        scene("crystalCave", "a cave of giant crystals casting geometric light patterns across its walls", .landscape),
    ]

    static let fractalSubjects: [Subject] = [
        scene("romanesco", "a romanesco broccoli head with its spiralling cones", .food, .handheld),
        scene("fernFrond", "an unfurling fern frond, spiral inside spiral", .plant, .handheld),
        scene("frostGlass", "frost feathers branching across a window pane", .object, .handheld),
        scene("riverDelta", "a river delta branching across tidal mudflats, seen from the air", .landscape),
        scene("nautilus", "a nautilus shell cut in half to show its chambers", .creature, .handheld),
        scene("lightningFork", "a fork of lightning branching across the night sky", .celestial),
        scene("bismuth", "a bismuth crystal with stepped iridescent terraces", .object, .tiny),
        scene("succulent", "a succulent rosette growing in a perfect spiral", .plant, .handheld),
        scene("coralFan", "a branching sea fan coral", .creature, .humanSized),
        scene("sunflowerSeeds", "a sunflower seed head packed in interlocking spirals", .plant, .handheld),
        scene("snowflake", "a single snowflake resting on dark wool", .object, .tiny),
    ]

    static let liquidSubjects: [Subject] = [
        scene("inkBloom", "ink blooming through clear water in slow billowing clouds", .object, .handheld),
        scene("oilCells", "oil drops floating on colored water, packed into round cells", .object, .handheld),
        scene("ferrofluid", "ferrofluid rising into a crown of glossy black spikes", .object, .tiny),
        scene("soapFilm", "a soap film stretched across a wire ring with swirling interference bands", .object, .handheld),
        scene("marbling", "marbled paint swirling across the surface of water", .object, .handheld),
        scene("dyedIce", "melting dyed ice cubes bleeding color into each other", .food, .handheld),
        scene("milkCrown", "a droplet splashing into milk and forming a perfect crown", .food, .tiny),
        scene("oilInHoney", "bubbles of colored oil rising slowly through honey", .food, .handheld),
        scene("paintPour", "layers of poured paint spreading into each other in cells and lacing", .object, .handheld),
        scene("dyeInSyrup", "streams of dye folding through clear syrup like silk", .object, .handheld),
    ]
}
