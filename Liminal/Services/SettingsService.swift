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
        static let effectIntensity = "visual.effectIntensity"
        static let depthStrength = "visual.depthStrength"
        static let archiveEnabled = "archive.enabled"
        static let archiveChangeSpeed = "archive.changeSpeed"
        /// Removed in A27 ("Footage amount" Rare / Normal / Often): deleted on launch.
        static let legacyArchiveAmount = "archive.amount"
        static let archiveAudioLevel = "archive.audioLevel"
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
    static let defaultEffectIntensity: Float = EffectLook.defaultIntensity
    static let defaultDepthStrength: Float = ShellLayout.defaultDepth
    static let defaultArchiveEnabled: Bool = true
    static let defaultArchiveChangeSpeed: FootageChangeSpeed = .medium
    static let defaultArchiveAudioLevel: Float = 0.5

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

    /// "Effect intensity", 0 (subtle) ... 1 (wild): how far the effects bend the picture and how much
    /// of the slow clarity cycle is spent wild (docs/plans/effects-balance.md).
    @Published var effectIntensity: Float {
        didSet { defaults.set(effectIntensity, forKey: Keys.effectIntensity) }
    }

    /// "Depth", 0 (flat) ... 1 (deepest): strength of the visionOS shell's depth relief
    /// (docs/plans/spatial.md section 3). Unused on macOS.
    @Published var depthStrength: Float {
        didSet { defaults.set(depthStrength, forKey: Keys.depthStrength) }
    }

    /// "Archive footage": old Internet Archive film always woven subtly into the scene while on
    /// (docs/plans/archive-video.md 6, decision A27).
    @Published var archiveEnabled: Bool {
        didSet { defaults.set(archiveEnabled, forKey: Keys.archiveEnabled) }
    }

    /// "Change speed": how long each piece of footage stays before the next drifts in (Slow / Medium / Fast).
    @Published var archiveChangeSpeed: FootageChangeSpeed {
        didSet { defaults.set(archiveChangeSpeed.rawValue, forKey: Keys.archiveChangeSpeed) }
    }

    /// "Footage audio", 0 (silent) ... 1: level of the film's sound. 0.5 is the default.
    @Published var archiveAudioLevel: Float {
        didSet { defaults.set(archiveAudioLevel, forKey: Keys.archiveAudioLevel) }
    }

    /// Spending cap: new Gemini images allowed per rolling hour / 24 h (GenerationBudget, D34).
    @Published var maxImagesPerHour: Int {
        didSet { defaults.set(maxImagesPerHour, forKey: GenerationBudget.Keys.perHour) }
    }

    @Published var maxImagesPerDay: Int {
        didSet { defaults.set(maxImagesPerDay, forKey: GenerationBudget.Keys.perDay) }
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

        // -LiminalImageInterval (DEBUG) wins; assigning in init does not run didSet, so it is not saved.
        self.imageInterval = DebugLaunchOptions.imageInterval
            ?? defaults.object(forKey: Keys.imageInterval) as? Double ?? Self.defaultImageInterval
        self.cacheOnly = defaults.object(forKey: Keys.cacheOnly) as? Bool ?? Self.defaultCacheOnly
        self.syncVisualsToMusic = defaults.object(forKey: Keys.syncVisualsToMusic) as? Bool ?? Self.defaultSyncVisualsToMusic
        self.effectIntensity = min(max(defaults.object(forKey: Keys.effectIntensity) as? Float ?? Self.defaultEffectIntensity, 0), 1)

        self.depthStrength = min(max(defaults.object(forKey: Keys.depthStrength) as? Float ?? Self.defaultDepthStrength, 0), 1)

        self.archiveEnabled = defaults.object(forKey: Keys.archiveEnabled) as? Bool ?? Self.defaultArchiveEnabled
        self.archiveChangeSpeed = FootageChangeSpeed(rawValue: defaults.string(forKey: Keys.archiveChangeSpeed) ?? "")
            ?? Self.defaultArchiveChangeSpeed
        // "Footage amount" no longer exists (footage is always present while on); it does not map onto a speed.
        defaults.removeObject(forKey: Keys.legacyArchiveAmount)
        self.archiveAudioLevel = min(max(defaults.object(forKey: Keys.archiveAudioLevel) as? Float ?? Self.defaultArchiveAudioLevel, 0), 1)

        self.maxImagesPerHour = defaults.object(forKey: GenerationBudget.Keys.perHour) as? Int ?? GenerationBudget.defaultPerHour
        self.maxImagesPerDay = defaults.object(forKey: GenerationBudget.Keys.perDay) as? Int ?? GenerationBudget.defaultPerDay

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
        effectIntensity = Self.defaultEffectIntensity
        depthStrength = Self.defaultDepthStrength
        archiveEnabled = Self.defaultArchiveEnabled
        archiveChangeSpeed = Self.defaultArchiveChangeSpeed
        archiveAudioLevel = Self.defaultArchiveAudioLevel
        maxImagesPerHour = GenerationBudget.defaultPerHour
        maxImagesPerDay = GenerationBudget.defaultPerDay
        LMLog.state.info("Settings reset to defaults")
    }
}
