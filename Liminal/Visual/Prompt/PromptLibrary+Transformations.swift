//
//  PromptLibrary+Transformations.swift
//  Liminal
//
//  What happens to the subject. One impossibility per image keeps it readable:
//  the viewer should recognize the thing first, then notice what is wrong.
//

import Foundation

nonisolated extension PromptLibrary {

    static let standardTransformations: [Transformation] = [
        // material
        Transformation(id: "madeOf", kind: .material, template: "{S} made entirely of {M}", weight: 1.4,
                       moods: [.playful, .lush], excludedCategories: [.landscape, .celestial]),
        Transformation(id: "carvedFrom", kind: .material, template: "{S} carved from a single block of {MS}", weight: 1.0,
                       moods: [.majestic, .serene], excludedCategories: [.landscape, .celestial]),

        // scale
        Transformation(id: "mountainSize", kind: .scale, template: "{S} the size of a mountain, towering over {E}", weight: 1.0,
                       moods: [.majestic, .ominous], excludedCategories: [.landscape, .celestial],
                       scales: [.tiny, .handheld, .humanSized]),
        Transformation(id: "miniatureOnLeaf", kind: .scale, template: "a miniature {Sn} resting on a single leaf", weight: 1.0,
                       moods: [.playful, .intimate], excludedCategories: [.landscape, .celestial],
                       scales: [.humanSized, .monumental]),

        // displacement
        Transformation(id: "standingAlone", kind: .displacement, template: "{S} standing alone in {E}", weight: 1.0,
                       moods: [.melancholy, .eerie], excludedCategories: [.landscape, .celestial]),
        Transformation(id: "seabed", kind: .displacement, template: "{S} resting on the seabed, perfectly intact", weight: 0.8,
                       moods: [.eerie, .serene], excludedCategories: [.landscape, .celestial, .creature]),

        // hybrid
        Transformation(id: "blossoming", kind: .hybrid, template: "{S} with {S2p} growing out of it like blossoms", weight: 1.0,
                       moods: [.lush, .playful], excludedCategories: [.landscape, .celestial],
                       secondCategories: [.plant, .creature, .food]),
        Transformation(id: "patternedSkin", kind: .hybrid, template: "{S} whose surface is covered in the patterned skin of {S2}", weight: 0.9,
                       moods: [.eerie, .lush], excludedCategories: [.landscape, .celestial, .creature],
                       secondCategories: [.creature]),

        // container
        Transformation(id: "worldInside", kind: .container, template: "{S}, and inside it, in miniature, {E} with its own weather", weight: 0.9,
                       moods: [.intimate, .serene], excludedCategories: [.landscape, .celestial, .creature]),
        Transformation(id: "glassVessel", kind: .container, template: "{S2} sealed inside a giant glass {Sn}", weight: 0.9,
                       moods: [.intimate, .eerie], excludedCategories: [.landscape, .celestial, .creature, .plant],
                       secondCategories: [.creature, .plant, .landscape, .celestial]),

        // multiplicity
        Transformation(id: "spiralHorizon", kind: .multiplicity,
                       template: "hundreds of identical {Sp} arranged in a perfect spiral that recedes to the horizon", weight: 0.9,
                       moods: [.majestic, .eerie], excludedCategories: [.landscape, .celestial]),
        Transformation(id: "flock", kind: .multiplicity, template: "a flock of {Sp} flying in formation across the sky", weight: 0.9,
                       moods: [.euphoric, .playful], excludedCategories: [.landscape, .celestial]),

        // stateChange (strong surreal)
        Transformation(id: "melting", kind: .stateChange,
                       template: "{S} half melted, sagging and flowing like thick syrup while still clearly recognizable", weight: 1.0,
                       needsStrongSurreal: true, moods: [.eerie, .melancholy], excludedCategories: [.landscape]),
        Transformation(id: "bursting", kind: .stateChange, template: "{S} bursting into a cloud of {B}, frozen in mid-air", weight: 1.0,
                       needsStrongSurreal: true, moods: [.euphoric, .electric], excludedCategories: [.landscape]),
        Transformation(id: "unravelling", kind: .stateChange, template: "{S} unravelling into long ribbons that drift on the wind", weight: 0.8,
                       needsStrongSurreal: true, moods: [.melancholy, .serene], excludedCategories: [.landscape]),

        // gravity
        Transformation(id: "float", kind: .gravity, template: "{S} floating a metre above {E}, casting a sharp shadow below", weight: 1.0,
                       moods: [.serene, .eerie], excludedCategories: [.landscape]),
        Transformation(id: "upsideDown", kind: .gravity, template: "{S} hanging upside down from the clouds", weight: 0.7,
                       moods: [.eerie, .playful], excludedCategories: [.landscape, .celestial]),
        Transformation(id: "rising", kind: .gravity, template: "{Sp} drifting slowly upward into the sky like released balloons", weight: 0.7,
                       moods: [.euphoric, .playful], excludedCategories: [.landscape, .celestial]),

        // overgrowth
        Transformation(id: "overgrown", kind: .overgrowth, template: "{S} overgrown with {G}, as if abandoned for a century", weight: 1.0,
                       moods: [.lush, .melancholy], excludedCategories: [.landscape, .celestial, .creature]),

        // reflection
        Transformation(id: "otherReflection", kind: .reflection,
                       template: "{S} reflected in perfectly still water, the reflection showing {S2} instead", weight: 1.0,
                       moods: [.eerie, .serene]),

        // luminous
        Transformation(id: "lantern", kind: .luminous, template: "{S} glowing from within like a paper lantern", weight: 1.0,
                       moods: [.serene, .intimate], excludedCategories: [.landscape]),
        Transformation(id: "translucent", kind: .luminous,
                       template: "a translucent {Sn} with its inner structure visible and softly lit", weight: 0.9,
                       moods: [.intimate, .electric], excludedCategories: [.landscape, .celestial]),

        // plain: no impossibility; style and palette carry the strangeness
        Transformation(id: "plainSpectacular", kind: .plain,
                       template: "{S} at its most spectacular, every real detail crisp and vivid", weight: 1.0,
                       moods: [.majestic, .serene]),
        Transformation(id: "plainRareLight", kind: .plain,
                       template: "{S} in a rare real moment of extraordinary light and weather", weight: 1.0,
                       moods: [.majestic, .eerie]),

        // own-subject styles: the subject phrase is already the whole scene
        Transformation(id: "scene", kind: .plain, template: "{S}", weight: 1.0, moods: [], forOwnSubjects: true),
    ]

    // MARK: Slot values

    /// {M}: any material.
    static let materials: [String] = [
        "blown glass", "liquid chrome", "jade", "white marble", "rose quartz", "honeycomb dripping honey", "living moss",
        "stained glass", "folded paper", "knitted wool", "porcelain with gold kintsugi seams", "translucent amber",
        "clear ice", "woven copper wire", "opal", "soap-bubble film", "citrus fruit slices",
        "pink coral", "iridescent feathers", "polished obsidian", "molten glass", "wildflowers",
    ]

    /// {MS}: materials that can be carved from a block (subset of `materials`).
    static let solidMaterials: [String] = [
        "jade", "white marble", "rose quartz", "translucent amber", "clear ice", "opal", "polished obsidian", "pink coral",
    ]

    /// {E}: environments, with their article.
    static let environments: [String] = [
        "a white salt flat", "a flooded ballroom", "the seabed", "the tops of the clouds", "a black lava field",
        "an empty swimming pool", "fresh snow", "red sand dunes", "a mossy forest", "a mirror-still lake",
        "a wheat field", "a tiled bathhouse", "a foggy pier", "a moonlit rooftop", "a field of poppies", "an ice cave",
    ]

    /// {G}: overgrowth.
    static let growths: [String] = [
        "coral and barnacles", "moss and ferns", "quartz crystals", "glowing mushrooms", "wildflowers",
        "frost feathers", "ivy and wisteria", "bracket fungi",
    ]

    /// {B}: what a subject bursts into.
    static let bursts: [String] = ["petals", "butterflies", "feathers", "soap bubbles", "confetti-like leaves"]
}
