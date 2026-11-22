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
        static let lofi = "audio.lofi"
        static let scaleAuto = "audio.scaleAuto"
        static let imageInterval = "visual.imageInterval"
        static let syncVisualsToMusic = "visual.syncToMusic"
        static let effectIntensity = "visual.effectIntensity"
        static let depthStrength = "visual.depthStrength"
        static let archiveEnabled = "archive.enabled"
        static let archiveChangeSpeed = "archive.changeSpeed"
        /// Removed in A27 ("Footage amount" Rare / Normal / Often): deleted on launch.
        static let legacyArchiveAmount = "archive.amount"
        static let archiveAudioLevel = "archive.audioLevel"
        static let dialogueTranscription = DialogueTranscriptionMode.defaultsKey
    }

    // MARK: - Defaults

    private let defaults = UserDefaults.standard

    // MARK: - Default Values

    static let defaultScale: ScaleType = .pentatonicMajor
    static let defaultScaleAuto: Bool = true
    static let defaultImageInterval: Double = 30.0
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

    @Published var lofi: LofiOptions {
        didSet { defaults.set(try? JSONEncoder().encode(lofi), forKey: Keys.lofi) }
    }

    /// true = "Auto": the transport chooses the scale; false = `currentScale` is pinned.
    @Published var scaleAuto: Bool {
        didSet { defaults.set(scaleAuto, forKey: Keys.scaleAuto) }
    }

    /// The scale the engine should pin, or nil for Auto.
    var pinnedScale: ScaleType? { scaleAuto ? nil : currentScale }

    /// What the engine plays: the saved tempo and the pinned scale.
    var lofiOptions: LofiOptions { LofiOptions(tempo: lofi.tempo, scale: pinnedScale) }

    /// Picker binding: nil = "Auto", otherwise the pinned scale.
    var scaleSelection: Binding<ScaleType?> {
        Binding(get: { self.pinnedScale },
                set: { newValue in
                    if let s = newValue { self.currentScale = s; self.scaleAuto = false } else { self.scaleAuto = true }
                })
    }

    @Published var imageInterval: Double {
        didSet { defaults.set(imageInterval, forKey: Keys.imageInterval) }
    }

    /// "Sync visuals to music": music -> visuals coupling (docs/plans/av-coupling.md section 4).
    /// Gates that direction only, with a 1.5 s fade.
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

    /// Generic debug toggle for testing new effects (not persisted)
    @Published var debugEffectEnabled: Bool = true

    // MARK: - Init

    private init() {
        // Load scale from saved string, fallback to default
        let savedScaleName = defaults.string(forKey: Keys.scale) ?? Self.defaultScale.rawValue
        self.currentScale = ScaleType.allCases.first { $0.rawValue == savedScaleName } ?? Self.defaultScale

        self.lofi = defaults.data(forKey: Keys.lofi).flatMap { try? JSONDecoder().decode(LofiOptions.self, from: $0) } ?? LofiOptions()
        self.scaleAuto = defaults.object(forKey: Keys.scaleAuto) as? Bool ?? Self.defaultScaleAuto

        // -LiminalImageInterval (DEBUG) wins; assigning in init does not run didSet, so it is not saved.
        self.imageInterval = DebugLaunchOptions.imageInterval
            ?? defaults.object(forKey: Keys.imageInterval) as? Double ?? Self.defaultImageInterval
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

        LMLog.state.info("Settings loaded: scale=\(self.scaleAuto ? "auto" : self.currentScale.rawValue), tempo=\(self.lofi.tempo)")
    }

    // MARK: - Reset

    func resetToDefaults() {
        currentScale = Self.defaultScale
        lofi = LofiOptions()
        scaleAuto = Self.defaultScaleAuto
        imageInterval = Self.defaultImageInterval
        syncVisualsToMusic = Self.defaultSyncVisualsToMusic
        effectIntensity = Self.defaultEffectIntensity
        depthStrength = Self.defaultDepthStrength
        archiveEnabled = Self.defaultArchiveEnabled
        archiveChangeSpeed = Self.defaultArchiveChangeSpeed
        archiveAudioLevel = Self.defaultArchiveAudioLevel
        dialogueTranscription = DialogueTranscriptionMode.defaultMode
        LMLog.state.info("Settings reset to defaults")
    }
}
