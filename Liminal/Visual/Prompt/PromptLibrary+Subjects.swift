//
//  PromptLibrary+Subjects.swift
//  Liminal
//
//  116 concrete, recognizable subjects in 9 categories. Things whose text is
//  the first thing to go wrong (clocks, road signs, books, labelled bottles,
//  neon signs) are left out; borderline ones are tagged textProne and get
//  "all surfaces blank and unmarked" (docs/decisions/images.md D8).
//

import Foundation

nonisolated extension PromptLibrary {

    private static func s(_ id: String, _ phrase: String, _ plural: String, _ category: SubjectCategory,
                          _ scale: SubjectScale, text: Bool = false) -> Subject {
        Subject(id: id, phrase: phrase, plural: plural, category: category, scale: scale, textProne: text)
    }

    static let standardSubjects: [Subject] = [
        // creature (16)
        s("chameleon", "a chameleon", "chameleons", .creature, .handheld),
        s("octopus", "an octopus", "octopuses", .creature, .handheld),
        s("snowyOwl", "a snowy owl", "snowy owls", .creature, .handheld),
        s("koi", "a koi fish", "koi fish", .creature, .handheld),
        s("jellyfish", "a jellyfish", "jellyfish", .creature, .handheld),
        s("stag", "a stag with full antlers", "stags with full antlers", .creature, .humanSized),
        s("hummingbird", "a hummingbird", "hummingbirds", .creature, .tiny),
        s("tiger", "a tiger", "tigers", .creature, .humanSized),
        s("peacock", "a peacock with its tail fanned", "peacocks with their tails fanned", .creature, .humanSized),
        s("humpbackWhale", "a humpback whale", "humpback whales", .creature, .monumental),
        s("moth", "a luna moth", "luna moths", .creature, .tiny),
        s("seahorse", "a seahorse", "seahorses", .creature, .tiny),
        s("fox", "a red fox", "red foxes", .creature, .humanSized),
        s("flamingo", "a flamingo", "flamingos", .creature, .humanSized),
        s("beetle", "a jewel beetle", "jewel beetles", .creature, .tiny),
        s("mantaRay", "a manta ray", "manta rays", .creature, .humanSized),

        // plant (12)
        s("orchid", "an orchid", "orchids", .plant, .handheld),
        s("sequoia", "a giant sequoia", "giant sequoias", .plant, .monumental),
        s("sunflower", "a sunflower", "sunflowers", .plant, .handheld),
        s("cactus", "a saguaro cactus", "saguaro cacti", .plant, .humanSized),
        s("mushrooms", "a cluster of mushrooms", "clusters of mushrooms", .plant, .handheld),
        s("waterLily", "a water lily", "water lilies", .plant, .handheld),
        s("bonsai", "a bonsai tree", "bonsai trees", .plant, .handheld),
        s("dandelion", "a dandelion seed head", "dandelion seed heads", .plant, .tiny),
        s("flytrap", "a venus flytrap", "venus flytraps", .plant, .tiny),
        s("cherryTree", "a cherry tree in full blossom", "cherry trees in full blossom", .plant, .monumental),
        s("fern", "a fern", "ferns", .plant, .handheld),
        s("pinecone", "a pinecone", "pinecones", .plant, .handheld),

        // architecture (14)
        s("lighthouse", "a lighthouse", "lighthouses", .architecture, .monumental),
        s("spiralStaircase", "a spiral staircase", "spiral staircases", .architecture, .monumental),
        s("greenhouse", "a Victorian greenhouse", "Victorian greenhouses", .architecture, .monumental),
        s("cathedral", "a gothic cathedral", "gothic cathedrals", .architecture, .monumental),
        s("suspensionBridge", "a suspension bridge", "suspension bridges", .architecture, .landscape),
        s("waterTower", "a water tower", "water towers", .architecture, .monumental, text: true),
        s("carousel", "a carousel", "carousels", .architecture, .monumental),
        s("windmill", "a windmill", "windmills", .architecture, .monumental),
        s("subwayStation", "an empty subway station", "empty subway stations", .architecture, .monumental, text: true),
        s("driveInScreen", "a drive-in movie screen with a blank white screen", "drive-in movie screens", .architecture, .monumental, text: true),
        s("stoneArchway", "a stone archway", "stone archways", .architecture, .monumental),
        s("swimmingPool", "a swimming pool", "swimming pools", .architecture, .monumental),
        s("phoneBooth", "a phone booth", "phone booths", .architecture, .humanSized, text: true),
        s("ferrisWheel", "a ferris wheel", "ferris wheels", .architecture, .monumental),

        // object (16)
        s("rotaryPhone", "a rotary telephone with a blank dial", "rotary telephones", .object, .handheld, text: true),
        s("armchair", "a velvet armchair", "velvet armchairs", .object, .humanSized),
        s("chandelier", "a crystal chandelier", "crystal chandeliers", .object, .humanSized),
        s("umbrella", "an open umbrella", "open umbrellas", .object, .handheld),
        s("typewriter", "a typewriter with blank keys", "typewriters", .object, .handheld, text: true),
        s("lightbulb", "a lightbulb", "lightbulbs", .object, .tiny),
        s("bicycle", "a bicycle", "bicycles", .object, .humanSized),
        s("hourglass", "an hourglass", "hourglasses", .object, .handheld),
        s("teapot", "a teapot", "teapots", .object, .handheld),
        s("television", "a vintage television with a blank screen", "vintage televisions", .object, .handheld, text: true),
        s("sneaker", "a sneaker", "sneakers", .object, .handheld, text: true),
        s("key", "an antique key", "antique keys", .object, .tiny),
        s("bathtub", "a clawfoot bathtub", "clawfoot bathtubs", .object, .humanSized),
        s("ladder", "a wooden ladder", "wooden ladders", .object, .humanSized),
        s("chessSet", "a chess set", "chess sets", .object, .handheld),
        s("discoBall", "a disco ball", "disco balls", .object, .handheld),

        // vehicle (12)
        s("locomotive", "a steam locomotive", "steam locomotives", .vehicle, .monumental, text: true),
        s("sailboat", "a sailboat", "sailboats", .vehicle, .monumental),
        s("hotAirBalloon", "a hot-air balloon", "hot-air balloons", .vehicle, .monumental),
        s("convertible", "a classic convertible", "classic convertibles", .vehicle, .humanSized, text: true),
        s("tram", "a vintage tram", "vintage trams", .vehicle, .monumental, text: true),
        s("biplane", "a biplane", "biplanes", .vehicle, .monumental),
        s("submarine", "a submarine", "submarines", .vehicle, .monumental, text: true),
        s("cableCar", "a cable car", "cable cars", .vehicle, .humanSized, text: true),
        s("rowingBoat", "a wooden rowing boat", "wooden rowing boats", .vehicle, .humanSized),
        s("motorcycle", "a motorcycle", "motorcycles", .vehicle, .humanSized, text: true),
        s("zeppelin", "a zeppelin", "zeppelins", .vehicle, .monumental, text: true),
        s("schoolBus", "a yellow school bus", "yellow school buses", .vehicle, .monumental, text: true),

        // landscape (12)
        s("saltFlat", "a salt flat", "salt flats", .landscape, .landscape),
        s("waterfall", "a waterfall", "waterfalls", .landscape, .landscape),
        s("seaStack", "a sea stack", "sea stacks", .landscape, .landscape),
        s("sandDunes", "rolling sand dunes", "sand dunes", .landscape, .landscape),
        s("glacierCave", "a glacier ice cave", "glacier ice caves", .landscape, .landscape),
        s("volcano", "a volcano", "volcanoes", .landscape, .landscape),
        s("riceTerraces", "terraced rice fields", "terraced rice fields", .landscape, .landscape),
        s("slotCanyon", "a slot canyon", "slot canyons", .landscape, .landscape),
        s("lavenderField", "a lavender field", "lavender fields", .landscape, .landscape),
        s("mangrove", "a mangrove forest", "mangrove forests", .landscape, .landscape),
        s("hotSpring", "a steaming hot spring", "steaming hot springs", .landscape, .landscape),
        s("basaltColumns", "basalt columns", "basalt columns", .landscape, .landscape),

        // food (12)
        s("pomegranate", "a split pomegranate", "split pomegranates", .food, .handheld),
        s("layeredCake", "a layered cake", "layered cakes", .food, .handheld),
        s("bloodOrange", "a halved blood orange", "halved blood oranges", .food, .handheld),
        s("honeycomb", "a slab of honeycomb", "slabs of honeycomb", .food, .handheld),
        s("pineapple", "a pineapple", "pineapples", .food, .handheld),
        s("iceCream", "an ice-cream cone", "ice-cream cones", .food, .handheld),
        s("noodles", "a bowl of noodles", "bowls of noodles", .food, .handheld),
        s("artichoke", "an artichoke", "artichokes", .food, .handheld),
        s("watermelon", "a watermelon", "watermelons", .food, .handheld),
        s("softEgg", "a soft-boiled egg", "soft-boiled eggs", .food, .tiny),
        s("croissant", "a croissant", "croissants", .food, .handheld),
        s("dragonFruit", "a dragon fruit", "dragon fruits", .food, .handheld),

        // instrument (12)
        s("grandPiano", "a grand piano", "grand pianos", .instrument, .humanSized),
        s("cello", "a cello", "cellos", .instrument, .humanSized),
        s("trumpet", "a trumpet", "trumpets", .instrument, .handheld),
        s("harp", "a concert harp", "concert harps", .instrument, .humanSized),
        s("drumKit", "a drum kit", "drum kits", .instrument, .humanSized),
        s("turntable", "a vinyl turntable", "vinyl turntables", .instrument, .handheld, text: true),
        s("accordion", "an accordion", "accordions", .instrument, .handheld),
        s("electricGuitar", "an electric guitar", "electric guitars", .instrument, .handheld),
        s("pipeOrgan", "a pipe organ", "pipe organs", .instrument, .monumental),
        s("gramophone", "a gramophone", "gramophones", .instrument, .handheld),
        s("saxophone", "a saxophone", "saxophones", .instrument, .handheld),
        s("synthesizer", "a modular synthesizer", "modular synthesizers", .instrument, .handheld, text: true),

        // celestial (10)
        s("fullMoon", "a full moon", "full moons", .celestial, .landscape),
        s("ringedPlanet", "a ringed planet", "ringed planets", .celestial, .landscape),
        s("comet", "a comet", "comets", .celestial, .landscape),
        s("solarEclipse", "a total solar eclipse", "total solar eclipses", .celestial, .landscape),
        s("aurora", "the aurora borealis", "auroras", .celestial, .landscape),
        s("spiralGalaxy", "a spiral galaxy", "spiral galaxies", .celestial, .landscape),
        s("thunderhead", "a thunderhead lit by lightning", "thunderheads", .celestial, .landscape),
        s("meteorShower", "a meteor shower", "meteor showers", .celestial, .landscape),
        s("crescentMoon", "a crescent moon", "crescent moons", .celestial, .landscape),
        s("sun", "the sun", "suns", .celestial, .landscape),
    ]
}
