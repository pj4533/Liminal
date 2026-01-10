import Foundation
import Combine
import OSLog

/// Persists user preferences using UserDefaults.
/// Settings are automatically saved when changed and restored on launch.
@MainActor
final class SettingsService: ObservableObject {

    static let shared = SettingsService()

    // MARK: - Keys

    private enum Keys {
        static let delay = "audio.delay"
        static let reverb = "audio.reverb"
        static let notes = "audio.notes"
        static let scale = "audio.scale"
        static let imageInterval = "visual.imageInterval"
        static let cacheOnly = "visual.cacheOnly"
    }

    // MARK: - Defaults

    private let defaults = UserDefaults.standard

    // MARK: - Default Values

    static let defaultDelay: Float = 0.5
    static let defaultReverb: Float = 0.5
    static let defaultNotes: Float = 0.5
    static let defaultScale: ScaleType = .pentatonicMajor
    static let defaultImageInterval: Double = 30.0
    static let defaultCacheOnly: Bool = false

    // MARK: - Published Settings

    @Published var delay: Float {
        didSet { defaults.set(delay, forKey: Keys.delay) }
    }

    @Published var reverb: Float {
        didSet { defaults.set(reverb, forKey: Keys.reverb) }
    }

    @Published var notes: Float {
        didSet { defaults.set(notes, forKey: Keys.notes) }
    }

    @Published var currentScale: ScaleType {
        didSet { defaults.set(currentScale.rawValue, forKey: Keys.scale) }
    }

    @Published var imageInterval: Double {
        didSet { defaults.set(imageInterval, forKey: Keys.imageInterval) }
    }

    @Published var cacheOnly: Bool {
        didSet { defaults.set(cacheOnly, forKey: Keys.cacheOnly) }
    }

    // MARK: - Init

    private init() {
        // Load saved values or use defaults
        self.delay = defaults.object(forKey: Keys.delay) as? Float ?? Self.defaultDelay
        self.reverb = defaults.object(forKey: Keys.reverb) as? Float ?? Self.defaultReverb
        self.notes = defaults.object(forKey: Keys.notes) as? Float ?? Self.defaultNotes

        // Load scale from saved string, fallback to default
        let savedScaleName = defaults.string(forKey: Keys.scale) ?? Self.defaultScale.rawValue
        self.currentScale = ScaleType.allCases.first { $0.rawValue == savedScaleName } ?? Self.defaultScale

        self.imageInterval = defaults.object(forKey: Keys.imageInterval) as? Double ?? Self.defaultImageInterval
        self.cacheOnly = defaults.object(forKey: Keys.cacheOnly) as? Bool ?? Self.defaultCacheOnly

        LMLog.state.info("Settings loaded: scale=\(self.currentScale.rawValue), delay=\(self.delay), reverb=\(self.reverb), notes=\(self.notes)")
    }

    // MARK: - Reset

    func resetToDefaults() {
        delay = Self.defaultDelay
        reverb = Self.defaultReverb
        notes = Self.defaultNotes
        currentScale = Self.defaultScale
        imageInterval = Self.defaultImageInterval
        cacheOnly = Self.defaultCacheOnly
        LMLog.state.info("Settings reset to defaults")
    }
}
