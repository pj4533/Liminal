import Foundation

/// Capture-only render tuning for controlled A/B experiments (bass translation plan, Ticket 1). The app
/// always renders `.standard`: the values come from `tune.<key>` capture hooks, which are inert outside
/// the offline harness. `LofiRenderer.render` resolves it once per phrase on the render worker and passes it
/// down as a value; nothing here runs on a realtime thread and no static is mutated.
///
/// Keys (each absent key keeps the standard value, so an unset hook renders bit for bit as before):
/// - `tune.bassSatBand=LO-HI`: the bass chain's parallel harmonic band, a 2-pole high-pass at LO and the
///   4-pole low-pass pair at HI (default `200-450`). Both inside 100-2000 Hz, LO < HI.
/// - `tune.bassSatMix=F`: the blend of that band (default `0.15`), 0 to 0.6.
/// - `tune.bassCueDb=DB|off`: the bass's clean cue partials (`LofiBassVoice.Cue`, D129), the first partial
///   at or above the band's low edge `DB` under the fundamental (-40 to 0); `off` renders no cue layer.
/// - `tune.bassCueBand=LO-HI`: the cue's low edge and 4-pole roll-off (100-2000 Hz).
/// - `tune.bassCueSlopeDb=DB`: level step per partial (0 to 12).
/// - `tune.bassCueOnsetMs=MS`: the cue's raised-cosine rise from the strike (0 to 500 ms).
/// - `tune.bassCueSynthDb=DB`: extra level of the cue on the `synth` tone (-24 to 12).
/// - `tune.bassCueAlign=on|off`: each partial follows the phase of the tone's own harmonic (default `on`;
///   `off` is the round-2 sine phase, which cancels part of a sampled body's harmonics).
///   The shape keys change the cue only while it is on.
/// - `tune.cueDuck=SOURCES:LO-HI:DB|off`: the cue duck (`LofiCueDuck`, D129) on `texture`, `wet` or
///   `texture+wet`, band LO-HI (100-2000 Hz), at most DB (0 to 12); `off` renders no duck.
nonisolated struct LofiRenderTuning: Sendable, Equatable {
    var bass: LofiStemChains.Bass = .standard
    var bassCue: LofiBassVoice.Cue? = Self.defaultBassCue
    var cueDuck: LofiCueDuck? = Self.defaultCueDuck

    /// The app's cue layer and cue duck (`nil`: none).
    /// R3h (D129), shipped 2026-11-23 after a headphone listen; `tune.bassCueDb=off` is the rollback.
    static let defaultBassCue: LofiBassVoice.Cue? = .standard
    static let defaultCueDuck: LofiCueDuck? = nil

    static let standard = LofiRenderTuning()
    static let prefix = "tune."
    /// Every key this build understands; any other `tune.*` hook fails the capture.
    static let keys = ["tune.bassSatBand", "tune.bassSatMix", "tune.bassCueDb", "tune.bassCueBand",
                       "tune.bassCueSlopeDb", "tune.bassCueOnsetMs", "tune.bassCueSynthDb", "tune.bassCueAlign", "tune.cueDuck"]

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknownKey(String)
        case invalid(key: String, value: String, reason: String)

        var description: String {
            switch self {
            case .unknownKey(let key): "Unknown render tuning hook \(key) (known: \(LofiRenderTuning.keys.joined(separator: ", ")))"
            case .invalid(let key, let value, let reason): "Render tuning hook \(key)=\(value): \(reason)"
            }
        }
    }

    var isStandard: Bool { self == .standard }

    /// The tuning of the running capture: `.standard` in the app, or when the hooks are invalid (the
    /// harness validates them with `parse` before rendering and fails the capture instead).
    static func capture() -> LofiRenderTuning {
        guard LofiCaptureHooks.isEnabled else { return .standard }
        return (try? parse(LofiCaptureHooks.options)) ?? .standard
    }

    /// Parses the `tune.*` entries of a capture's hook options; other hooks are ignored.
    static func parse(_ options: [String: String]) throws -> LofiRenderTuning {
        var tuning = LofiRenderTuning.standard
        // The cue's shape keys edit `cue`; `tune.bassCueDb` decides whether it plays.
        var cue = tuning.bassCue ?? .standard
        var cueOn = tuning.bassCue != nil
        for (key, raw) in options.sorted(by: { $0.key < $1.key }) where key.hasPrefix(prefix) {
            let value = raw.trimmingCharacters(in: .whitespaces)
            switch key {
            case "tune.bassSatBand":
                let (lo, hi) = try band(key, value, range: 100...2_000)
                tuning.bass.saturationBand = LofiStemChains.Bass.saturationBand(lowHz: lo, highHz: hi)
            case "tune.bassSatMix":
                tuning.bass.saturationMix = try number(key, value, range: 0...0.6)
            case "tune.bassCueDb":
                if value.lowercased() == "off" {
                    cueOn = false
                } else {
                    cue.levelDB = Double(try number(key, value, range: -40...0))
                    cueOn = true
                }
            case "tune.bassCueBand":
                (cue.lowHz, cue.highHz) = try band(key, value, range: 100...2_000)
            case "tune.bassCueSlopeDb":
                cue.slopeDB = Double(try number(key, value, range: 0...12))
            case "tune.bassCueOnsetMs":
                cue.onset = Double(try number(key, value, range: 0...500)) / 1_000
            case "tune.bassCueSynthDb":
                cue.synthOffsetDB = Double(try number(key, value, range: -24...12))
            case "tune.bassCueAlign":
                switch value.lowercased() {
                case "on": cue.alignToTone = true
                case "off": cue.alignToTone = false
                default: throw ParseError.invalid(key: key, value: value, reason: "expected on or off")
                }
            case "tune.cueDuck":
                tuning.cueDuck = try cueDuck(key, value)
            default:
                throw ParseError.unknownKey(key)
            }
        }
        tuning.bassCue = cueOn ? cue : nil
        return tuning
    }

    /// `SOURCES:LO-HI:DB` (sources `texture`, `wet` or both joined by `+`) or `off`.
    private static func cueDuck(_ key: String, _ value: String) throws -> LofiCueDuck? {
        if value.lowercased() == "off" { return nil }
        let fields = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3 else {
            throw ParseError.invalid(key: key, value: value, reason: "expected SOURCES:LO-HI:DB or off")
        }
        let sources = Set(fields[0].lowercased().split(separator: "+").map(String.init))
        guard !sources.isEmpty, sources.isSubset(of: ["texture", "wet"]) else {
            throw ParseError.invalid(key: key, value: value, reason: "sources are texture, wet or texture+wet")
        }
        var duck = LofiCueDuck.standard
        duck.texture = sources.contains("texture")
        duck.wet = sources.contains("wet")
        (duck.lowHz, duck.highHz) = try band(key, fields[1], range: 100...2_000)
        duck.maxDB = try number(key, fields[2], range: 0...12)
        return duck
    }

    /// `manifest.diagnostics.renderTuning`: every resolved value and whether it is the standard tuning.
    var report: [String: Any] {
        func hz(_ kind: LofiBiquad.Kind) -> Double? {
            switch kind {
            case .highpass(let hz, _), .lowpass(let hz, _): hz
            default: nil
            }
        }
        let band = bass.saturationBand.compactMap(hz)
        let cue: Any = bassCue.map { c -> [String: Any] in
            ["levelDb": c.levelDB, "band": [c.lowHz, c.highHz], "slopeDb": c.slopeDB, "onsetMs": c.onset * 1_000,
             "synthDb": c.synthOffsetDB, "align": c.alignToTone]
        } ?? "off"
        let duck: Any = cueDuck.map { d -> [String: Any] in
            ["sources": (d.texture ? ["texture"] : []) + (d.wet ? ["wet"] : []), "band": [d.lowHz, d.highHz],
             "maxDb": Double(d.maxDB), "attackMs": d.attack * 1_000, "releaseMs": d.release * 1_000]
        } ?? "off"
        return ["isStandard": isStandard,
                "bassSatBand": [band.first ?? 0, band.last ?? 0],
                "bassSatMix": Double(bass.saturationMix),
                "bassCue": cue, "cueDuck": duck]
    }

    private static func number(_ key: String, _ value: String, range: ClosedRange<Float>) throws -> Float {
        guard let x = Float(value), x.isFinite else {
            throw ParseError.invalid(key: key, value: value, reason: "not a number")
        }
        guard range.contains(x) else {
            throw ParseError.invalid(key: key, value: value, reason: "outside \(range.lowerBound)...\(range.upperBound)")
        }
        return x
    }

    private static func band(_ key: String, _ value: String, range: ClosedRange<Double>) throws -> (Double, Double) {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let lo = Double(parts[0]), let hi = Double(parts[1]), lo.isFinite, hi.isFinite else {
            throw ParseError.invalid(key: key, value: value, reason: "expected LO-HI in hertz")
        }
        guard range.contains(lo), range.contains(hi), lo < hi else {
            throw ParseError.invalid(key: key, value: value,
                                     reason: "needs \(Int(range.lowerBound)) <= LO < HI <= \(Int(range.upperBound)) Hz")
        }
        return (lo, hi)
    }
}

nonisolated extension LofiStemChains.Bass {
    /// The parallel harmonic band: a Butterworth high-pass at `lowHz` and a 4-pole Butterworth low-pass
    /// (two sections) at `highHz`. `saturationBand(lowHz: 200, highHz: 450)` is the standard band.
    static func saturationBand(lowHz: Double, highHz: Double) -> [LofiBiquad.Kind] {
        [.highpass(hz: lowHz, q: LofiStemChains.butterworthQ), .lowpass(hz: highHz, q: 0.541_196_100_146_197),
         .lowpass(hz: highHz, q: 1.306_562_964_876_377)]
    }
}
