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
        static let brightness = "mood.brightness"
        static let tension = "mood.tension"
        static let density = "mood.density"
        static let movement = "mood.movement"
        static let scale = "audio.scale"
        static let imageInterval = "visual.imageInterval"
        static let cacheOnly = "visual.cacheOnly"
    }

    // MARK: - Defaults

    private let defaults = UserDefaults.standard

    // MARK: - Published Settings

    @Published var brightness: Float {
        didSet { defaults.set(brightness, forKey: Keys.brightness) }
    }

    @Published var tension: Float {
        didSet { defaults.set(tension, forKey: Keys.tension) }
    }

    @Published var density: Float {
        didSet { defaults.set(density, forKey: Keys.density) }
    }

    @Published var movement: Float {
        didSet { defaults.set(movement, forKey: Keys.movement) }
    }

    @Published var scaleName: String {
        didSet { defaults.set(scaleName, forKey: Keys.scale) }
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
        self.brightness = defaults.object(forKey: Keys.brightness) as? Float ?? 0.5
        self.tension = defaults.object(forKey: Keys.tension) as? Float ?? 0.3
        self.density = defaults.object(forKey: Keys.density) as? Float ?? 0.4
        self.movement = defaults.object(forKey: Keys.movement) as? Float ?? 0.5
        self.scaleName = defaults.string(forKey: Keys.scale) ?? "Pentatonic Major"
        self.imageInterval = defaults.object(forKey: Keys.imageInterval) as? Double ?? 30.0
        self.cacheOnly = defaults.object(forKey: Keys.cacheOnly) as? Bool ?? false

        LMLog.state.info("Settings loaded: scale=\(self.scaleName), imageInterval=\(self.imageInterval)s, cacheOnly=\(self.cacheOnly)")
    }

    // MARK: - Sync Methods

    /// Apply saved settings to a MoodState
    func applyTo(mood: MoodState) {
        mood.brightness = brightness
        mood.tension = tension
        mood.density = density
        mood.movement = movement
    }

    /// Save current mood values
    func saveFrom(mood: MoodState) {
        brightness = mood.brightness
        tension = mood.tension
        density = mood.density
        movement = mood.movement
    }

    /// Get scale type from saved name
    var scale: ScaleType {
        ScaleType.allCases.first { $0.rawValue == scaleName } ?? .pentatonicMajor
    }
}
