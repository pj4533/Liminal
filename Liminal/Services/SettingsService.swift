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
        static let scale = "audio.scale"
        static let style = "audio.style"
        static let musicMode = "audio.musicMode"
        static let lofi = "audio.lofi"
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
        static let dialogueTranscription = DialogueTranscriptionMode.defaultsKey
        static let imageSource = ImageSource.defaultsKey
    }

    // MARK: - Defaults

    private let defaults = UserDefaults.standard

    // MARK: - Default Values

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

    @Published var currentScale: ScaleType {
        didSet { defaults.set(currentScale.rawValue, forKey: Keys.scale) }
    }

    /// Music style (Drift, Glass, Deep, Garden).
    @Published var style: MusicStyle.ID {
        didSet { defaults.set(style.rawValue, forKey: Keys.style) }
    }

    @Published var musicMode: MusicMode {
        didSet { defaults.set(musicMode.rawValue, forKey: Keys.musicMode) }
    }

    /// "Images": AI (Gemini generation) or API (curated collections, D36). Read off the main actor
    /// through `ImageSource.current`, which uses the same key.
    @Published var imageSource: ImageSource {
        didSet { defaults.set(imageSource.rawValue, forKey: Keys.imageSource) }
    }

    @Published var lofi: LofiOptions {
        didSet { defaults.set(try? JSONEncoder().encode(lofi), forKey: Keys.lofi) }
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

    /// "Dialogue understanding": on-device transcription of footage dialogue (plan 7). The
    /// acoustic chopping never depends on it. Read off the main actor through
    /// `DialogueTranscriptionMode.current`, which uses the same key.
    @Published var dialogueTranscription: DialogueTranscriptionMode {
        didSet { defaults.set(dialogueTranscription.rawValue, forKey: Keys.dialogueTranscription) }
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
        // Load scale from saved string, fallback to default
        let savedScaleName = defaults.string(forKey: Keys.scale) ?? Self.defaultScale.rawValue
        self.currentScale = ScaleType.allCases.first { $0.rawValue == savedScaleName } ?? Self.defaultScale

        self.style = MusicStyle.ID(rawValue: defaults.string(forKey: Keys.style) ?? "") ?? Self.defaultStyle
        self.musicMode = MusicMode(rawValue: defaults.string(forKey: Keys.musicMode) ?? "") ?? .ambient
        // -LiminalImageSource (DEBUG) wins; assigning in init does not run didSet, so it is not saved.
        self.imageSource = ImageSource.resolve(stored: defaults.string(forKey: Keys.imageSource),
                                               debugFlag: DebugLaunchOptions.imageSource)
        self.lofi = defaults.data(forKey: Keys.lofi).flatMap { try? JSONDecoder().decode(LofiOptions.self, from: $0) } ?? LofiOptions()
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

        self.dialogueTranscription = DialogueTranscriptionMode(rawValue: defaults.string(forKey: Keys.dialogueTranscription) ?? "")
            ?? DialogueTranscriptionMode.defaultMode

        self.maxImagesPerHour = defaults.object(forKey: GenerationBudget.Keys.perHour) as? Int ?? GenerationBudget.defaultPerHour
        self.maxImagesPerDay = defaults.object(forKey: GenerationBudget.Keys.perDay) as? Int ?? GenerationBudget.defaultPerDay

        LMLog.state.info("Settings loaded: scale=\(self.currentScale.rawValue), style=\(self.style.rawValue)")
    }

    // MARK: - Reset

    func resetToDefaults() {
        currentScale = Self.defaultScale
        style = Self.defaultStyle
        musicMode = .ambient
        imageSource = ImageSource.defaultSource
        lofi = LofiOptions()
        scaleAuto = Self.defaultScaleAuto
        imageInterval = Self.defaultImageInterval
        cacheOnly = Self.defaultCacheOnly
        syncVisualsToMusic = Self.defaultSyncVisualsToMusic
        effectIntensity = Self.defaultEffectIntensity
        depthStrength = Self.defaultDepthStrength
        archiveEnabled = Self.defaultArchiveEnabled
        archiveChangeSpeed = Self.defaultArchiveChangeSpeed
        archiveAudioLevel = Self.defaultArchiveAudioLevel
        dialogueTranscription = DialogueTranscriptionMode.defaultMode
        maxImagesPerHour = GenerationBudget.defaultPerHour
        maxImagesPerDay = GenerationBudget.defaultPerDay
        LMLog.state.info("Settings reset to defaults")
    }
}
