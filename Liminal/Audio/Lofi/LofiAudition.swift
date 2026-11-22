import Foundation

extension LofiScore {
    /// Offline A/B controls for one render: a forced guitar or plucked-string program, the guitar's
    /// middle phrase (1 or 2), and whether the strummed hook line plays. The capture harness builds
    /// it from its hooks and passes it down; the score, presets and renderer never read the hooks
    /// themselves, so parallel unit tests never see a forced program. `.none` is the app's own draw.
    nonisolated struct Audition: Sendable, Equatable {
        var guitarProgram: String?
        var pluckProgram: String?
        /// The take phrase (1 or 2) that plays the guitar; the plucked string takes the other.
        var guitarSlot: Int?
        /// The strummed hook line. Stored only for now.
        var hook: Bool = true

        static let none = Self()

        init(guitarProgram: String? = nil, pluckProgram: String? = nil, guitarSlot: Int? = nil, hook: Bool = true) {
            self.guitarProgram = guitarProgram
            self.pluckProgram = pluckProgram
            self.guitarSlot = guitarSlot.flatMap { (1...2).contains($0) ? $0 : nil }
            self.hook = hook
        }

        /// Program names match case-insensitively with spaces removed: "Nylon Strum" is "nylonstrum".
        static func key(_ name: String) -> String {
            name.lowercased().filter { !$0.isWhitespace }
        }
    }
}
