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

    /// -LiminalOpenDome YES (visionOS): open the immersive space ("liminalSpace") once the window appears.
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

    // Spatial shell harness (docs/plans/spatial.md). The simulator camera is fixed and looks forward,
    // so these move the scene instead of the head.

    /// Negative values must be passed with a leading space (e.g. `-LiminalShellYaw " -90"`):
    /// the argument domain reads a bare "-90" as the next key and drops the value.
    /// -LiminalShellYaw <deg> (visionOS): rotate the immersive scene so the content at this azimuth
    /// (positive = to the viewer's right) is straight ahead.
    static let shellYaw: Float = defaults.float(forKey: "LiminalShellYaw")

    /// -LiminalShellPitch <deg> (visionOS): rotate the scene so the content at this elevation
    /// (positive = up) is straight ahead. Applied after the yaw.
    static let shellPitch: Float = defaults.float(forKey: "LiminalShellPitch")

    /// -LiminalShellHeadOffset "x,y,z" (visionOS, metres): move the scene by minus this vector, which
    /// is what the viewer would see after moving their head by it (shows parallax in the simulator).
    static let shellHeadOffset: SIMD3<Float> = {
        guard let s = defaults.string(forKey: "LiminalShellHeadOffset") else { return .zero }
        let parts = s.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        return parts.count == 3 ? SIMD3(parts[0], parts[1], parts[2]) : .zero
    }()

    /// -LiminalShellDepth <0...1> (visionOS): use this relief strength instead of the default.
    static let shellDepth: Float? = {
        guard defaults.object(forKey: "LiminalShellDepth") != nil else { return nil }
        return min(max(defaults.float(forKey: "LiminalShellDepth"), 0), 1)
    }()

    /// -LiminalShellTextureStereo YES (visionOS): A/B option for device review. Render the effects with
    /// the old per-eye texture parallax (stereo MRT) and show it on the hero tile; the side tiles use
    /// the left eye. Default is one mono effects render shown to both eyes (decision S4).
    static let shellTextureStereo: Bool = defaults.bool(forKey: "LiminalShellTextureStereo")

    /// -LiminalHideControls YES (visionOS): close the controls window once the immersive space is open,
    /// so simulator screenshots show the scene unobstructed.
    static let hideControls: Bool = defaults.bool(forKey: "LiminalHideControls")

    /// -LiminalAutoExitAfter <seconds> (visionOS): after the auto-opened immersive space has been up
    /// this long, leave it through the same path as the Exit Liminal button (verifies Exit in the
    /// simulator, where taps on the window do not work).
    static let autoExitAfter: Double? = {
        let v = defaults.double(forKey: "LiminalAutoExitAfter")
        return v > 0 ? v : nil
    }()

    /// -LiminalDepthImage <path> (visionOS): use this grey depth image (0 far, 1 near, made from the
    /// cover-cropped image) instead of the ML depth map. Depth Anything returns an all-zero map in the
    /// visionOS simulator, so relief can only be inspected there with a depth map made on the Mac.
    static let depthImagePath: String? = defaults.string(forKey: "LiminalDepthImage")

    /// -LiminalShellCycle "img1.jpg|depth1.png,img2.jpg|depth2.png" (visionOS): every
    /// -LiminalShellCycleSeconds (default 12) show the next image of this list (depth map optional),
    /// so image changes can be recorded with fixed images and Mac-made depth maps.
    static let shellCycle: [(image: String, depth: String?)] = {
        guard let s = defaults.string(forKey: "LiminalShellCycle") else { return [] }
        return s.split(separator: ",").map { item in
            let parts = item.split(separator: "|").map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : nil)
        }
    }()
    static let shellCycleSeconds: Double = {
        let v = defaults.double(forKey: "LiminalShellCycleSeconds")
        return v > 0 ? v : 12
    }()

    /// True when any shell harness flag is set (they also block generation).
    static var anyShellFlag: Bool {
        defaults.object(forKey: "LiminalShellYaw") != nil || defaults.object(forKey: "LiminalShellPitch") != nil
            || defaults.object(forKey: "LiminalShellHeadOffset") != nil || shellDepth != nil || shellTextureStereo
            || hideControls || depthImagePath != nil || !shellCycle.isEmpty
    }

    static var blocksImageGeneration: Bool {
        guard !allowGeneration else { return false }
        return autoPlay || openDome || freezeTime != nil || testPattern || testImagePath != nil
            || defaults.object(forKey: "LiminalPerfLogInterval") != nil || splitPasses
            || forceStereoFlatDepth || forceMonoMaterial || noEffects || syncLog
            || defaults.object(forKey: "LiminalSyncStrength") != nil || effectIntensity != nil
            || anyShellFlag
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
    static let shellYaw: Float = 0
    static let shellPitch: Float = 0
    static let shellHeadOffset: SIMD3<Float> = .zero
    static let shellDepth: Float? = nil
    static let shellTextureStereo = false
    static let hideControls = false
    static let autoExitAfter: Double? = nil
    static let depthImagePath: String? = nil
    static let shellCycle: [(image: String, depth: String?)] = []
    static let shellCycleSeconds: Double = 12
#endif

    private static let logOnce: Void = {
#if DEBUG
        if autoPlay { LMLog.general.info("🧪 DEBUG FLAG applied: LiminalAutoPlay=YES (auto-start playback)") }
        if openDome { LMLog.general.info("🧪 DEBUG FLAG applied: LiminalOpenDome=YES (auto-open the immersive space)") }
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
        if shellYaw != 0 || shellPitch != 0 {
            LMLog.general.info("🧪 DEBUG FLAG applied: LiminalShellYaw=\(shellYaw, format: .fixed(precision: 1)) LiminalShellPitch=\(shellPitch, format: .fixed(precision: 1)) (scene rotated)")
        }
        if shellHeadOffset != .zero {
            LMLog.general.info("🧪 DEBUG FLAG applied: LiminalShellHeadOffset=\(shellHeadOffset.x, format: .fixed(precision: 3)),\(shellHeadOffset.y, format: .fixed(precision: 3)),\(shellHeadOffset.z, format: .fixed(precision: 3))")
        }
        if let d = shellDepth { LMLog.general.info("🧪 DEBUG FLAG applied: LiminalShellDepth=\(d, format: .fixed(precision: 2))") }
        if let p = depthImagePath { LMLog.general.info("🧪 DEBUG FLAG applied: LiminalDepthImage=\(p, privacy: .public) (replaces the ML depth map)") }
        if shellTextureStereo { LMLog.general.info("🧪 DEBUG FLAG applied: LiminalShellTextureStereo=YES (per-eye texture parallax, hero tile)") }
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
