import Foundation
import SwiftUI
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
        static let style = "audio.style"
        static let scaleAuto = "audio.scaleAuto"
        static let imageInterval = "visual.imageInterval"
        static let cacheOnly = "visual.cacheOnly"
        static let syncVisualsToMusic = "visual.syncToMusic"
    }

    // MARK: - Defaults

    private let defaults = UserDefaults.standard

    // MARK: - Default Values

    static let defaultDelay: Float = 0.5
    static let defaultReverb: Float = 0.5
    static let defaultNotes: Float = 0.5
    static let defaultScale: ScaleType = .pentatonicMajor
    static let defaultStyle: MusicStyle.ID = .drift
    static let defaultScaleAuto: Bool = true
    static let defaultImageInterval: Double = 30.0
    static let defaultCacheOnly: Bool = false
    static let defaultSyncVisualsToMusic: Bool = true

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

    /// Music style (Drift, Glass, Deep, Garden).
    @Published var style: MusicStyle.ID {
        didSet { defaults.set(style.rawValue, forKey: Keys.style) }
    }

    /// true = "Auto (evolving)" harmony; false = `currentScale` is pinned.
    @Published var scaleAuto: Bool {
        didSet { defaults.set(scaleAuto, forKey: Keys.scaleAuto) }
    }

    /// The scale the engine should pin, or nil for Auto.
    var pinnedScale: ScaleType? { scaleAuto ? nil : currentScale }

    /// Picker binding: nil = "Auto (evolving)", otherwise the pinned scale.
    var scaleSelection: Binding<ScaleType?> {
        Binding(get: { self.pinnedScale },
                set: { newValue in
                    if let s = newValue { self.currentScale = s; self.scaleAuto = false } else { self.scaleAuto = true }
                })
    }

    @Published var imageInterval: Double {
        didSet { defaults.set(imageInterval, forKey: Keys.imageInterval) }
    }

    @Published var cacheOnly: Bool {
        didSet { defaults.set(cacheOnly, forKey: Keys.cacheOnly) }
    }

    /// "Sync visuals to music": music -> visuals coupling (docs/plans/av-coupling.md section 4).
    /// Gates only that direction, with a 1.5 s fade; image -> music always runs.
    @Published var syncVisualsToMusic: Bool {
        didSet { defaults.set(syncVisualsToMusic, forKey: Keys.syncVisualsToMusic) }
    }

    /// Generic debug toggle for testing new effects (not persisted)
    @Published var debugEffectEnabled: Bool = true

    // MARK: - Init

    private init() {
        // Load saved values or use defaults
        self.delay = defaults.object(forKey: Keys.delay) as? Float ?? Self.defaultDelay
        self.reverb = defaults.object(forKey: Keys.reverb) as? Float ?? Self.defaultReverb
        self.notes = defaults.object(forKey: Keys.notes) as? Float ?? Self.defaultNotes

        // Load scale from saved string, fallback to default
        let savedScaleName = defaults.string(forKey: Keys.scale) ?? Self.defaultScale.rawValue
        self.currentScale = ScaleType.allCases.first { $0.rawValue == savedScaleName } ?? Self.defaultScale

        self.style = MusicStyle.ID(rawValue: defaults.string(forKey: Keys.style) ?? "") ?? Self.defaultStyle
        self.scaleAuto = defaults.object(forKey: Keys.scaleAuto) as? Bool ?? Self.defaultScaleAuto

        self.imageInterval = defaults.object(forKey: Keys.imageInterval) as? Double ?? Self.defaultImageInterval
        self.cacheOnly = defaults.object(forKey: Keys.cacheOnly) as? Bool ?? Self.defaultCacheOnly
        self.syncVisualsToMusic = defaults.object(forKey: Keys.syncVisualsToMusic) as? Bool ?? Self.defaultSyncVisualsToMusic

        LMLog.state.info("Settings loaded: scale=\(self.currentScale.rawValue), delay=\(self.delay), reverb=\(self.reverb), notes=\(self.notes)")
    }

    // MARK: - Reset

    func resetToDefaults() {
        delay = Self.defaultDelay
        reverb = Self.defaultReverb
        notes = Self.defaultNotes
        currentScale = Self.defaultScale
        style = Self.defaultStyle
        scaleAuto = Self.defaultScaleAuto
        imageInterval = Self.defaultImageInterval
        cacheOnly = Self.defaultCacheOnly
        syncVisualsToMusic = Self.defaultSyncVisualsToMusic
        LMLog.state.info("Settings reset to defaults")
    }
}
