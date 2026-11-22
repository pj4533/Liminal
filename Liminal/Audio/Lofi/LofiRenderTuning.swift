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
nonisolated struct LofiRenderTuning: Sendable, Equatable {
    var bass: LofiStemChains.Bass = .standard

    static let standard = LofiRenderTuning()
    static let prefix = "tune."
    /// Every key this build understands; any other `tune.*` hook fails the capture.
    static let keys = ["tune.bassSatBand", "tune.bassSatMix"]

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
        for (key, raw) in options.sorted(by: { $0.key < $1.key }) where key.hasPrefix(prefix) {
            let value = raw.trimmingCharacters(in: .whitespaces)
            switch key {
            case "tune.bassSatBand":
                let (lo, hi) = try band(key, value, range: 100...2_000)
                tuning.bass.saturationBand = LofiStemChains.Bass.saturationBand(lowHz: lo, highHz: hi)
            case "tune.bassSatMix":
                tuning.bass.saturationMix = try number(key, value, range: 0...0.6)
            default:
                throw ParseError.unknownKey(key)
            }
        }
        return tuning
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
        return ["isStandard": isStandard,
                "bassSatBand": [band.first ?? 0, band.last ?? 0],
                "bassSatMix": Double(bass.saturationMix)]
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
