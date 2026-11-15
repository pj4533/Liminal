//
//  DebugLaunchOptions.swift
//  Liminal
//
//  DEBUG-only launch arguments used by the performance harness (scripts/perf-run.sh).
//  Read from UserDefaults' argument domain, so pass them as e.g.
//      -LiminalAutoPlay YES -LiminalOpenDome YES -LiminalFreezeTime 100 -LiminalPerfLogInterval 1
//  In Release builds every option is a compile-time constant (off / 1s log interval),
//  so none of this ships.
//

import Foundation
import OSLog

nonisolated enum DebugLaunchOptions {

#if DEBUG
    private static let defaults = UserDefaults.standard

    /// -LiminalAutoPlay YES: start audio + visual playback as soon as the controls appear.
    static let autoPlay: Bool = defaults.bool(forKey: "LiminalAutoPlay")

    /// -LiminalOpenDome YES (visionOS): open the "liminalDome" immersive space once the window appears.
    static let openDome: Bool = defaults.bool(forKey: "LiminalOpenDome")

    /// -LiminalFreezeTime <seconds>: pin the effect clock to a constant for deterministic screenshots.
    static let freezeTime: Float? = {
        guard defaults.object(forKey: "LiminalFreezeTime") != nil else { return nil }
        return defaults.float(forKey: "LiminalFreezeTime")
    }()

    /// -LiminalPerfLogInterval <seconds>: interval of the "📊 ... PERF" log lines (default 1s).
    static let perfLogInterval: Double = {
        let v = defaults.double(forKey: "LiminalPerfLogInterval")
        return v > 0 ? v : 1.0
    }()

    /// -LiminalPerfSplitPasses YES: historically put each eye's output blit in its own command
    /// buffer. Eyes now render directly into their drawables (no blit), so this is a no-op;
    /// kept so existing perf-run invocations still parse.
    static let splitPasses: Bool = defaults.bool(forKey: "LiminalPerfSplitPasses")

    /// -LiminalTestPattern YES: replace every source image with the generated orientation/colour
    /// test card (TestPatternGenerator) and skip image generation entirely.
    static let testPattern: Bool = defaults.bool(forKey: "LiminalTestPattern")

    /// -LiminalTestImage <path>: like -LiminalTestPattern, but show this image file (any path the
    /// app can read; the simulator can read host paths). For before/after colour comparisons.
    static let testImagePath: String? = defaults.string(forKey: "LiminalTestImage")

    /// -LiminalForceStereoFlatDepth YES (visionOS): always use the stereo ShaderGraph material and
    /// feed it a flat (constant mid-grey) depth map instead of the ML depth map, so the stereo path
    /// can be inspected deterministically (zero parallax) in the simulator.
    static let forceStereoFlatDepth: Bool = defaults.bool(forKey: "LiminalForceStereoFlatDepth")

    /// -LiminalForceMonoMaterial YES (visionOS): skip the stereo ShaderGraph material and use the mono
    /// UnlitMaterial fallback, so that path can be inspected (it is otherwise only used on failure).
    static let forceMonoMaterial: Bool = defaults.bool(forKey: "LiminalForceMonoMaterial")

    /// -LiminalNoEffects YES: bypass every effect (passthroughFragment) on both platforms, for clean
    /// orientation/colour checks of the bare image path.
    static let noEffects: Bool = defaults.bool(forKey: "LiminalNoEffects")

    /// -LiminalSyncLog YES: one "🎼 SYNC ..." line per second from each render loop (music -> visuals
    /// reactor state, resulting uniforms, last mood/activity sent to the music).
    static let syncLog: Bool = defaults.bool(forKey: "LiminalSyncLog")

    /// -LiminalSyncStrength <x>: multiply the music -> visuals amount (default 1; e.g. 3 to make the
    /// coupling obvious while tuning). Caps in EffectsUniformsComputer still apply.
    static let syncStrength: Float = {
        guard defaults.object(forKey: "LiminalSyncStrength") != nil else { return 1 }
        return max(0, defaults.float(forKey: "LiminalSyncStrength"))
    }()

    /// -LiminalEffectIntensity <0...1>: use this effect intensity instead of the "Effect intensity"
    /// setting (simulator checks, perf runs). The setting itself is not changed.
    static let effectIntensity: Float? = {
        guard defaults.object(forKey: "LiminalEffectIntensity") != nil else { return nil }
        return min(max(defaults.float(forKey: "LiminalEffectIntensity"), 0), 1)
    }()

    /// -LiminalAllowGeneration YES: let an automated/debug launch call Gemini. Without it, any launch
    /// that uses the automation flags above (perf runs, screenshots, sim checks) never generates new
    /// images: it shows cached images, or the test card when the cache is empty. Testing must not
    /// spend API budget by accident (2026-11-14 budget alert).
    static let allowGeneration: Bool = defaults.bool(forKey: "LiminalAllowGeneration")

    static var blocksImageGeneration: Bool {
        guard !allowGeneration else { return false }
        return autoPlay || openDome || freezeTime != nil || testPattern || testImagePath != nil
            || defaults.object(forKey: "LiminalPerfLogInterval") != nil || splitPasses
            || forceStereoFlatDepth || forceMonoMaterial || noEffects || syncLog
            || defaults.object(forKey: "LiminalSyncStrength") != nil || effectIntensity != nil
    }
#else
    static let allowGeneration = false
    static let blocksImageGeneration = false
    static let autoPlay = false
    static let openDome = false
    static let freezeTime: Float? = nil
    static let perfLogInterval: Double = 1.0
    static let splitPasses = false
    static let testPattern = false
    static let testImagePath: String? = nil
    static let forceStereoFlatDepth = false
    static let forceMonoMaterial = false
    static let noEffects = false
    static let syncLog = false
    static let syncStrength: Float = 1
    static let effectIntensity: Float? = nil
#endif

    private static let logOnce: Void = {
#if DEBUG
        if autoPlay { LMLog.general.info("🧪 DEBUG FLAG applied: LiminalAutoPlay=YES (auto-start playback)") }
        if openDome { LMLog.general.info("🧪 DEBUG FLAG applied: LiminalOpenDome=YES (auto-open immersive dome)") }
        if let t = freezeTime { LMLog.general.info("🧪 DEBUG FLAG applied: LiminalFreezeTime=\(t, format: .fixed(precision: 2))s (effect time pinned)") }
        if defaults.object(forKey: "LiminalPerfLogInterval") != nil {
            LMLog.general.info("🧪 DEBUG FLAG applied: LiminalPerfLogInterval=\(perfLogInterval, format: .fixed(precision: 2))s")
        }
        if splitPasses { LMLog.general.info("🧪 DEBUG FLAG applied: LiminalPerfSplitPasses=YES (no-op: eyes render direct to drawable, no blit to split)") }
        if let p = testImagePath { LMLog.general.info("🧪 DEBUG FLAG applied: LiminalTestImage=\(p, privacy: .public) (fixed source image)") }
        if testPattern { LMLog.general.info("🧪 DEBUG FLAG applied: LiminalTestPattern=YES (orientation test card replaces source images)") }
        if forceStereoFlatDepth { LMLog.general.info("🧪 DEBUG FLAG applied: LiminalForceStereoFlatDepth=YES (stereo material + flat depth)") }
        if forceMonoMaterial { LMLog.general.info("🧪 DEBUG FLAG applied: LiminalForceMonoMaterial=YES (mono UnlitMaterial)") }
        if noEffects { LMLog.general.info("🧪 DEBUG FLAG applied: LiminalNoEffects=YES (passthrough, no effects)") }
        if blocksImageGeneration { LMLog.general.info("🧪 DEBUG: automation launch, Gemini image generation OFF (cached images only; pass -LiminalAllowGeneration YES to override)") }
        if syncLog { LMLog.general.info("🧪 DEBUG FLAG applied: LiminalSyncLog=YES (🎼 SYNC lines)") }
        if let i = effectIntensity { LMLog.general.info("🧪 DEBUG FLAG applied: LiminalEffectIntensity=\(i, format: .fixed(precision: 2)) (overrides the Effect intensity setting)") }
        if syncStrength != 1 { LMLog.general.info("🧪 DEBUG FLAG applied: LiminalSyncStrength=\(syncStrength, format: .fixed(precision: 2))") }
#endif
    }()

    /// Log one line per applied flag (idempotent; safe to call from several places).
    static func logApplied() { _ = logOnce }

    /// Effect time to use given the real elapsed time.
    @inline(__always)
    static func effectTime(_ real: Float) -> Float { freezeTime ?? real }

    /// Effect intensity to use given the setting.
    @inline(__always)
    static func effectIntensity(setting: Float) -> Float { effectIntensity ?? setting }
}
