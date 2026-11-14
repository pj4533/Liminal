import Testing
import Foundation
@testable import Liminal

/// Audio-visual coupling checks (docs/plans/av-coupling.md section 5).
/// `capsHoldUnderExtremeInputs` always runs (fast, no audio). `offlineCoupling` drives the real conductor
/// offline for 600 s with the reactor at simulated 90 fps; it is off by default (slow) and run by
/// scripts/av-coupling-check.sh, which writes /private/tmp/liminal-avcoupling-config.txt.
@MainActor
struct AVCouplingTests {

    // MARK: Always-on

    @Test func capsHoldUnderExtremeInputs() {
        var m = MusicModulation()
        m.amount = 10; m.energy = 1; m.pulseColor = 1; m.pulseMotion = 1; m.shimmer = 1; m.air = 1; m.ghostReach = 1
        for t in stride(from: Float(0), to: 2000, by: 7.3) {
            let u = EffectsUniformsComputer.compute(time: t, music: m)
            #expect(u.bloomAmount <= 0.72 + 1e-6)
            #expect(u.vibranceAmount <= 0.50 + 1e-6)
            #expect(u.feedbackMix >= 0.26 - 1e-6 && u.feedbackMix <= 0.34 + 1e-6)
            #expect(u.feedbackWarpAmount <= 0.04 + 1e-6)
            #expect(u.ghostTapMaxDistance <= 0.08 + 1e-6)
            #expect(u.distortionAmplitude <= 0.10 + 1e-6)
            #expect(u.chromaticAmount <= 0.02 + 1e-6)
            #expect(u.logSphereAmount <= 0.024 + 1e-6)
            #expect(u.fractalNoiseAmount <= 0.036 + 1e-6)
        }
    }

    @Test func neutralMatchesUncoupled() {
        for t in stride(from: Float(0), to: 1000, by: 13.7) {
            let a = EffectsUniformsComputer.compute(time: t, transitionProgress: 0.3)
            let b = EffectsUniformsComputer.compute(time: t, transitionProgress: 0.3, music: .neutral)
            #expect(Self.fields(a) == Self.fields(b))
        }
    }

    @Test func reactorOffWithoutMusic() {
        // Bus never started (now = 0): amount stays 0 and visionOS (base rate 0) gets hue 0.
        var r = MusicReactor()
        var m = MusicModulation.neutral
        for i in 0..<900 { m = r.update(state: MusicState(), now: 0, effectTime: Float(i) / 90, enabled: true, baseHueRate: 0) }
        #expect(m.amount == 0 && m.hueBaseShift == 0 && m.motionLead == 0 && m.ghostBurstSerial == 0)
    }

    @Test func fifthsMapping() {
        #expect(MusicReactor.fifths(0) == 0)
        #expect(MusicReactor.fifths(7) == 1)
        #expect(MusicReactor.fifths(5) == -1)
        #expect(MusicReactor.fifths(6) == 6)
        #expect((0..<12).map(MusicReactor.fifths).allSatisfy { $0 >= -5 && $0 <= 6 })
    }

    @Test func allMoodWordsMap() {
        for mood in Mood.allCases {
            let r = VisualCoupling.interpret([mood.rawValue])
            #expect(!r.scenes.isEmpty, "mood \(mood.rawValue) matches no VisualCoupling row")
        }
    }

    // MARK: Offline (scripts/av-coupling-check.sh)

    @Test func offlineCoupling() throws {
        let cfg = Self.loadConfig()
        guard cfg["enabled"] == "1" else { return }
        let seconds = Double(cfg["seconds"] ?? "") ?? 600
        let seed = UInt64(cfg["seed"] ?? "") ?? 3
        let dir = cfg["outdir"] ?? NSTemporaryDirectory()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let engine = GenerativeEngine(seed: seed)
        let conductor = engine.conductor
        let bus = conductor.stateBus
        conductor.beginOffline()

        let fps = 90.0
        let offAt = seconds - 60          // last minute: sync toggled off
        var reactor = MusicReactor()
        var conductorT = 0.0
        var rows: [String] = ["t,amount,intensity,energy,pulseColor,pulseMotion,shimmer,air,hue,harmonyHue,lead,dist,distNeutral,bloom,vib,fb,warp,chrom,gtd,burst,scene,chordCount"]
        rows.reserveCapacity(Int(seconds * fps) + 2)

        var failures: [String] = []
        var bloom: [Float] = [], vib: [Float] = []
        var ratio: [Double] = [], intensity: [Double] = []
        var prev: EffectsUniforms?
        var maxStep = (bloom: Float(0), vib: Float(0), dist: Float(0), hue: Float(0))
        var scenesSeen = 0, lastScene: UInt32?
        var firstBurst: UInt32?
        var harmonyMin: Float = 0, harmonyMax: Float = 0
        var images: [(t: Double, bright: Bool, nudge0: Float, warm0: Float)] = []
        var musicChecks: [String] = []
        var chordHits = 0, chordTrials = 0
        var chordTimes: [Double] = []
        var lastChordCount: UInt32 = 0
        var offChecked = 0, offMismatch = 0
        var nextImage = 30.0

        let frames = Int(seconds * fps)
        for i in 1...frames {
            let t = Double(i) / fps
            while conductorT + 0.02 <= t { conductorT += 0.02; conductor.advance(to: conductorT) }
            // Synthetic image change every 30 s, alternating dark-cool and bright-warm.
            if t >= nextImage && t < offAt {
                let bright = images.count % 2 == 1
                var mood = VisualMood()
                mood.brightness = bright ? 0.8 : 0.15
                mood.warmth = bright ? 0.85 : 0.15
                mood.saturation = bright ? 0.7 : 0.3
                mood.energy = bright ? 0.6 : 0.3
                mood.moodWords = bright ? ["euphoric", "lush", "plant"] : ["eerie", "ominous", "landscape"]
                let p = conductor.couplingProbe
                images.append((t, bright, p.brightnessNudge, p.warmthDb))
                engine.setVisualMood(mood)
                engine.imageDidChange(transitionDuration: 1.5)
                nextImage += 30
            }
            for k in images.indices where abs(t - (images[k].t + 20)) < 0.5 / fps {
                let p = conductor.couplingProbe
                let dn = p.brightnessNudge - images[k].nudge0, dw = p.warmthDb - images[k].warm0
                let ok = images[k].bright ? (dn > 0 && dw > 0) : (dn < 0 && dw < 0)
                musicChecks.append(String(format: "img@%.0f %@ dNudge=%+.3f dWarmDb=%+.2f %@", images[k].t, images[k].bright ? "bright-warm" : "dark-cool", dn, dw, ok ? "ok" : "WRONG"))
                if !ok { failures.append("music side did not follow mood at \(images[k].t)") }
            }

            let state = bus.read()
            if state.chordChangeCount != lastChordCount { lastChordCount = state.chordChangeCount; chordTimes.append(state.time) }
            let enabled = t < offAt
            let m = reactor.update(state: state, now: t, effectTime: Float(t), enabled: enabled, baseHueRate: 0)
            let u = EffectsUniformsComputer.compute(time: Float(t), music: m)
            var neutralM = MusicModulation.neutral
            neutralM.hueBaseShift = m.hueBaseShift; neutralM.motionLead = m.motionLead
            let n = EffectsUniformsComputer.compute(time: Float(t), music: neutralM)

            // 1. caps
            if u.bloomAmount > 0.72 + 1e-6 || u.vibranceAmount > 0.5 + 1e-6 || u.feedbackMix < 0.26 - 1e-6
                || u.feedbackMix > 0.34 + 1e-6 || u.feedbackWarpAmount > 0.04 + 1e-6 || u.ghostTapMaxDistance > 0.08 + 1e-6
                || u.distortionAmplitude > 0.10 + 1e-6 || u.chromaticAmount > 0.02 + 1e-6 {
                failures.append(String(format: "cap exceeded at t=%.2f", t))
            }
            // 2. slew
            if let p = prev {
                maxStep.bloom = max(maxStep.bloom, abs(u.bloomAmount - p.bloomAmount))
                maxStep.vib = max(maxStep.vib, abs(u.vibranceAmount - p.vibranceAmount))
                maxStep.dist = max(maxStep.dist, abs(u.distortionAmplitude - p.distortionAmplitude))
                var dh = abs(u.hueBaseShift - p.hueBaseShift); dh = min(dh, 1 - dh)
                maxStep.hue = max(maxStep.hue, dh)
            }
            prev = u
            bloom.append(u.bloomAmount); vib.append(u.vibranceAmount)
            // 4. coupling correlation (sync on, settled)
            if enabled && t > 15 {
                // Intensity path only (the onset add is a separate, deliberately fast term).
                var noPulse = m; noPulse.pulseMotion = 0
                let up = EffectsUniformsComputer.compute(time: Float(t), music: noPulse)
                ratio.append(Double(up.distortionAmplitude / max(n.distortionAmplitude, 1e-6)))
                intensity.append(Double(state.intensity))
                harmonyMin = min(harmonyMin, reactor.harmonyHue); harmonyMax = max(harmonyMax, reactor.harmonyHue)
            }
            if enabled && reactor.alive && m.amount > 0.5 {
                if let ls = lastScene, ls != state.sceneIndex { scenesSeen += 1 }
                if firstBurst == nil { firstBurst = m.ghostBurstSerial }
            }
            lastScene = state.sceneIndex
            // 5. off = un-coupled output (except the hue and Ken Burns phases, which keep their offset)
            if t > offAt + 8 {
                offChecked += 1
                if Self.fields(u) != Self.fields(n) { offMismatch += 1 }
            }
            if i % 3 == 0 {
                rows.append(String(format: "%.3f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%.5f,%.5f,%.4f,%.4f,%.4f,%.4f,%.5f,%.4f,%u,%u,%u",
                                   t, m.amount, state.intensity, m.energy, m.pulseColor, m.pulseMotion, m.shimmer, m.air,
                                   m.hueBaseShift, reactor.harmonyHue, m.motionLead, u.distortionAmplitude, n.distortionAmplitude,
                                   u.bloomAmount, u.vibranceAmount, u.feedbackMix, u.feedbackWarpAmount, u.chromaticAmount,
                                   u.ghostTapMaxDistance, m.ghostBurstSerial, state.sceneIndex, state.chordChangeCount))
            }
        }
        // 6b. chord change within 1 s of each crossfade midpoint (when the conductor allows one: > 8 s into a chord)
        for img in images {
            let mid = img.t + 0.75
            chordTrials += 1
            if chordTimes.contains(where: { abs($0 - mid) <= 1.0 }) { chordHits += 1 }
        }

        let bursts = Int(reactor.modulation.ghostBurstSerial)
        if maxStep.bloom > 0.03 { failures.append("bloom slew \(maxStep.bloom)") }
        if maxStep.vib > 0.015 { failures.append("vibrance slew \(maxStep.vib)") }
        if maxStep.dist > 0.0006 { failures.append("distortion slew \(maxStep.dist)") }
        if maxStep.hue > 0.002 { failures.append("hue slew \(maxStep.hue)") }
        // 3. no strobing: 3...30 Hz band of bloom / vibrance under 5 % of variance.
        let bandBloom = Self.bandFraction(bloom, fps: fps), bandVib = Self.bandFraction(vib, fps: fps)
        if bandBloom > 0.05 { failures.append("bloom 3-30 Hz band \(bandBloom)") }
        if bandVib > 0.05 { failures.append("vibrance 3-30 Hz band \(bandVib)") }
        let corr = Self.correlation(ratio, intensity)
        if corr < 0.8 { failures.append("distortion ratio vs intensity correlation \(corr)") }
        if bursts < scenesSeen { failures.append("bursts \(bursts) < scene changes \(scenesSeen)") }
        if harmonyMax - harmonyMin < 0.02 { failures.append("harmony hue never moved") }
        if harmonyMax > 0.16 + 1e-4 || harmonyMin < -0.16 - 1e-4 { failures.append("harmony hue out of range") }
        if offMismatch > 0 { failures.append("sync off differs from un-coupled in \(offMismatch)/\(offChecked) frames") }
        if chordHits * 2 < chordTrials { failures.append("chord at crossfade midpoint only \(chordHits)/\(chordTrials)") }

        var summary = [
            String(format: "seconds=%.0f seed=%llu frames=%d", seconds, seed, frames),
            String(format: "maxStep bloom=%.4f vib=%.4f dist=%.5f hue=%.4f", maxStep.bloom, maxStep.vib, maxStep.dist, maxStep.hue),
            String(format: "band3to30Hz bloom=%.4f vib=%.4f", bandBloom, bandVib),
            String(format: "corr(distRatio,intensity)=%.3f", corr),
            "sceneChanges=\(scenesSeen) bursts=\(bursts)",
            String(format: "harmonyHue range %.3f...%.3f", harmonyMin, harmonyMax),
            "offFramesChecked=\(offChecked) mismatches=\(offMismatch)",
            "chordAtMidpoint=\(chordHits)/\(chordTrials)",
        ]
        summary += musicChecks
        summary.append(failures.isEmpty ? "AVCOUPLING PASS" : "AVCOUPLING FAIL: " + failures.joined(separator: "; "))
        try rows.joined(separator: "\n").write(toFile: dir + "/coupling.csv", atomically: true, encoding: .utf8)
        try summary.joined(separator: "\n").write(toFile: dir + "/summary.txt", atomically: true, encoding: .utf8)
        for l in summary { print("AVCOUPLING \(l)") }
        #expect(failures.isEmpty, "\(failures)")
    }

    // MARK: Helpers

    static func fields(_ u: EffectsUniforms) -> [Float] {
        [u.kenBurnsScale, u.kenBurnsOffsetX, u.kenBurnsOffsetY, u.distortionAmplitude, u.distortionSpeed, u.hueBaseShift,
         u.hueWaveIntensity, u.hueBlendAmount, u.ghostTapMaxDistance, u.chromaticAmount, u.feedbackWarpAmount, u.feedbackMix,
         u.bloomAmount, u.logSphereAmount, u.fractalNoiseAmount, u.fractalHueAmount, u.vibranceAmount, u.blackPoint]
    }

    /// Fraction of variance in the 3...30 Hz band, estimated as the difference of two box filters
    /// (3 frames ~ 30 Hz low-pass minus 30 frames ~ 3 Hz low-pass at 90 fps).
    static func bandFraction(_ x: [Float], fps: Double) -> Double {
        func boxed(_ n: Int) -> [Double] {
            var out = [Double](repeating: 0, count: x.count), acc = 0.0
            for i in x.indices {
                acc += Double(x[i]); if i >= n { acc -= Double(x[i - n]) }
                out[i] = acc / Double(min(i + 1, n))
            }
            return out
        }
        let fast = boxed(max(1, Int(fps / 30))), slow = boxed(max(1, Int(fps / 3)))
        let band = zip(fast, slow).map { $0 - $1 }
        let v = variance(x.map(Double.init)), vb = variance(Array(band.dropFirst(Int(fps))))
        return v > 1e-12 ? vb / v : 0
    }

    static func variance(_ x: [Double]) -> Double {
        guard x.count > 1 else { return 0 }
        let m = x.reduce(0, +) / Double(x.count)
        return x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count)
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(min(a.count, b.count)); guard n > 2 else { return 0 }
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for (x, y) in zip(a, b) { sab += (x - ma) * (y - mb); saa += (x - ma) * (x - ma); sbb += (y - mb) * (y - mb) }
        return saa > 0 && sbb > 0 ? sab / (saa * sbb).squareRoot() : 0
    }

    private static func loadConfig() -> [String: String] {
        var out: [String: String] = [:]
        guard let text = try? String(contentsOfFile: "/private/tmp/liminal-avcoupling-config.txt", encoding: .utf8) else { return out }
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }
}
