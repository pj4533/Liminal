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
#else
    static let autoPlay = false
    static let openDome = false
    static let freezeTime: Float? = nil
    static let perfLogInterval: Double = 1.0
    static let splitPasses = false
    static let testPattern = false
    static let forceStereoFlatDepth = false
    static let forceMonoMaterial = false
    static let noEffects = false
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
        if testPattern { LMLog.general.info("🧪 DEBUG FLAG applied: LiminalTestPattern=YES (orientation test card replaces source images)") }
        if forceStereoFlatDepth { LMLog.general.info("🧪 DEBUG FLAG applied: LiminalForceStereoFlatDepth=YES (stereo material + flat depth)") }
        if forceMonoMaterial { LMLog.general.info("🧪 DEBUG FLAG applied: LiminalForceMonoMaterial=YES (mono UnlitMaterial)") }
        if noEffects { LMLog.general.info("🧪 DEBUG FLAG applied: LiminalNoEffects=YES (passthrough, no effects)") }
#endif
    }()

    /// Log one line per applied flag (idempotent; safe to call from several places).
    static func logApplied() { _ = logOnce }

    /// Effect time to use given the real elapsed time.
    @inline(__always)
    static func effectTime(_ real: Float) -> Float { freezeTime ?? real }
}
