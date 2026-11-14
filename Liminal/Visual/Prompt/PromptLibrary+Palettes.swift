//
//  PromptLibrary+Palettes.swift
//  Liminal
//
//  17 named palettes. Each prompt names three colors and an accent explicitly;
//  the old "Natural, realistic colors" line is gone (it was the main cause of
//  the samey look). Swatches are the intended colors, stored in metadata.
//

import Foundation

nonisolated extension PromptLibrary {

    static let standardPalettes: [Palette] = [
        Palette(id: "aerochrome", words: ["crimson", "hot pink", "deep teal"], accent: "bone white",
                swatches: [RGB(hex: 0xC8102E), RGB(hex: 0xFF4FA3), RGB(hex: 0x0E5E6F), RGB(hex: 0xEDE6D6)],
                isDark: false, warmth: 0.4, energy: 0.8, moods: [.eerie, .euphoric]),
        Palette(id: "acidCitrus", words: ["acid lime green", "tangerine", "hot magenta"], accent: "ultramarine",
                swatches: [RGB(hex: 0xB0FF1A), RGB(hex: 0xFF8C1A), RGB(hex: 0xFF1D8E), RGB(hex: 0x2A3DE8)],
                isDark: false, warmth: 0.5, energy: 0.95, moods: [.electric, .playful]),
        Palette(id: "deepSea", words: ["cobalt blue", "turquoise", "oxidized copper green"], accent: "sunflower yellow",
                swatches: [RGB(hex: 0x0047AB), RGB(hex: 0x30D5C8), RGB(hex: 0x4F8A73), RGB(hex: 0xFFC512)],
                isDark: true, warmth: -0.7, energy: 0.5, moods: [.serene, .eerie]),
        Palette(id: "neonNoir", words: ["electric cyan", "neon magenta", "violet"], accent: "wet black",
                swatches: [RGB(hex: 0x00F0FF), RGB(hex: 0xFF00C8), RGB(hex: 0x7A1FFF), RGB(hex: 0x0A0A12)],
                isDark: true, warmth: -0.3, energy: 0.9, moods: [.electric, .ominous]),
        Palette(id: "desertSunset", words: ["burnt sienna", "coral", "apricot"], accent: "dusty violet",
                swatches: [RGB(hex: 0xA0522D), RGB(hex: 0xFF7F6A), RGB(hex: 0xFBCEB1), RGB(hex: 0x8E7CA6)],
                isDark: false, warmth: 0.9, energy: 0.5, moods: [.serene, .melancholy]),
        Palette(id: "borealis", words: ["emerald", "aurora green", "ice blue"], accent: "indigo",
                swatches: [RGB(hex: 0x009B77), RGB(hex: 0x5CFF9D), RGB(hex: 0xA5E6FF), RGB(hex: 0x3B2C8F)],
                isDark: true, warmth: -0.6, energy: 0.6, moods: [.majestic, .serene]),
        Palette(id: "candyPastel", words: ["bubblegum pink", "mint", "butter yellow"], accent: "baby blue",
                swatches: [RGB(hex: 0xFF8FC7), RGB(hex: 0x98F5C8), RGB(hex: 0xFFF1A0), RGB(hex: 0x9FD3FF)],
                isDark: false, warmth: 0.2, energy: 0.4, moods: [.playful, .intimate]),
        Palette(id: "moltenGold", words: ["molten gold", "ember orange", "cream"], accent: "obsidian black",
                swatches: [RGB(hex: 0xE8A317), RGB(hex: 0xF0581E), RGB(hex: 0xF7EBD3), RGB(hex: 0x111014)],
                isDark: true, warmth: 1.0, energy: 0.75, moods: [.majestic, .ominous]),
        Palette(id: "jewelBox", words: ["emerald", "ruby", "sapphire", "amethyst"], accent: "black velvet",
                swatches: [RGB(hex: 0x0B8F5A), RGB(hex: 0xC5163C), RGB(hex: 0x1C3FAA), RGB(hex: 0x8B4FC9)],
                isDark: true, warmth: 0.0, energy: 0.7, moods: [.lush, .majestic]),
        Palette(id: "monoCobalt", words: ["navy", "cobalt", "ice blue"], accent: "vermilion",
                swatches: [RGB(hex: 0x0B1F4D), RGB(hex: 0x0047AB), RGB(hex: 0xBFE3FF), RGB(hex: 0xE34234)],
                isDark: true, warmth: -0.9, energy: 0.45, moods: [.melancholy, .serene],
                customClause: "Color palette: every shade of blue from navy to ice blue with one vermilion accent, vivid and clearly separated."),
        Palette(id: "toxicBloom", words: ["chartreuse", "deep violet", "acid yellow"], accent: "black",
                swatches: [RGB(hex: 0x9EFF00), RGB(hex: 0x4B0F7A), RGB(hex: 0xEFFF2E), RGB(hex: 0x050505)],
                isDark: true, warmth: 0.1, energy: 0.85, moods: [.ominous, .electric]),
        Palette(id: "rustAndTeal", words: ["oxidized teal", "rust orange", "charcoal"], accent: "bone",
                swatches: [RGB(hex: 0x2F7F7A), RGB(hex: 0xB7410E), RGB(hex: 0x36393D), RGB(hex: 0xE3DAC9)],
                isDark: false, warmth: 0.2, energy: 0.5, moods: [.melancholy, .eerie]),
        Palette(id: "pearl", words: ["pearl white", "opal shimmer", "lilac"], accent: "pale gold",
                swatches: [RGB(hex: 0xF4F1EA), RGB(hex: 0xD9E8F0), RGB(hex: 0xC8A2C8), RGB(hex: 0xE6CF8B)],
                isDark: false, warmth: 0.1, energy: 0.25, moods: [.serene, .intimate]),
        Palette(id: "primaries", words: ["fire-engine red", "sky blue", "sun yellow"], accent: "grass green",
                swatches: [RGB(hex: 0xCE2029), RGB(hex: 0x4FB3FF), RGB(hex: 0xFFD500), RGB(hex: 0x4CAF50)],
                isDark: false, warmth: 0.3, energy: 0.8, moods: [.playful, .euphoric]),
        Palette(id: "bloodMoon", words: ["deep maroon", "copper", "moon white"], accent: "black",
                swatches: [RGB(hex: 0x5C0A12), RGB(hex: 0xB87333), RGB(hex: 0xF2EFE6), RGB(hex: 0x050505)],
                isDark: true, warmth: 0.7, energy: 0.6, moods: [.ominous, .majestic]),
        Palette(id: "ultraviolet", words: ["ultraviolet purple", "fluorescent green", "hot orange"], accent: "blue-black",
                swatches: [RGB(hex: 0x6A0DFF), RGB(hex: 0x39FF14), RGB(hex: 0xFF6A00), RGB(hex: 0x0A0B1E)],
                isDark: true, warmth: 0.0, energy: 1.0, moods: [.electric, .euphoric]),
        Palette(id: "earth", words: ["moss green", "ochre", "slate"], accent: "cream",
                swatches: [RGB(hex: 0x6B7F3A), RGB(hex: 0xCC7722), RGB(hex: 0x6D7B8D), RGB(hex: 0xF3E9D2)],
                isDark: false, warmth: 0.4, energy: 0.3, moods: [.serene, .melancholy], weight: 0.4),
    ]
}
