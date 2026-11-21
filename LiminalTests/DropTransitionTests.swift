import Testing
import Foundation
@testable import Liminal

/// Drop transitions (docs/plans/drop-transitions.md 8.1): the Lo-Fi image change builds over the drum fill
/// and is an ordinary frame of the new picture from the downbeat on.
@MainActor
struct DropTransitionTests {

    static let tempos: [Double] = [58, 69, 75, 82]

    private func bytes(_ u: EffectsUniforms) -> [UInt8] {
        withUnsafeBytes(of: u) { Array($0) }
    }

    private func reveal(_ style: TransitionStyle, tempo: Double, fillBeats: Double, strength: Float = 1,
                        finisher: DropFinisher? = nil) -> LofiImageReveal {
        let beat = 60 / tempo
        let downbeat = 1000.0 + 64 * beat
        let build = fillBeats * beat
        let spec = TransitionSpec.pinnedDrop(style, seed: 5, duration: Float(build), finisher: finisher, strength: strength)
        let hits = stride(from: downbeat - build, to: downbeat, by: beat / 4).map { $0 }
        return LofiImageReveal(downbeat: downbeat, fillStart: downbeat - build, spec: spec, hits: hits)
    }

    @Test func dropIsDoneAtTheDownbeatAndEqualsAFrameWithoutTransition() {
        let look = EffectLook(intensity: 0.6, imageAge: 3, imageInterval: 30, transitionDuration: 2)
        for style in TransitionStyle.dropFamily {
            for tempo in Self.tempos {
                for beats in [1.0, 2, 4, 8] {
                    let cue = reveal(style, tempo: tempo, fillBeats: beats)
                    let frame = cue.frame(presentedAt: cue.downbeat)
                    #expect(frame.done, "\(style) \(tempo) \(beats)")
                    let a = EffectsUniformsComputer.compute(time: 113, transitionProgress: 1, look: look, zoomAge: 3,
                                                            outgoingZoomScale: 1.2, transition: cue.spec, drop: frame)
                    let b = EffectsUniformsComputer.compute(time: 113, look: look, zoomAge: 3)
                    #expect(bytes(a) == bytes(b), "\(style) cut frame is a frame without transition")
                }
            }
        }
    }

    @Test func buildPeaksOnTheLastFrameAndNeverFalls() {
        for style in TransitionStyle.dropFamily {
            for strength in [Float(1), DropPlan.halfwayStrength] {
                let cue = reveal(style, tempo: 69, fillBeats: 4, strength: strength)
                let last = cue.frame(presentedAt: cue.downbeat - 1.0 / 60)
                #expect(!last.done)
                #expect(cue.spec.envelope(last.progress) >= 0.9 * strength, "\(style) peak at the cut")
                var prev: Float = 0
                for k in 0...200 {
                    let e = cue.spec.envelope(Float(k) / 200 * 0.9999)
                    #expect(e >= prev - 1e-6, "\(style) monotonic")
                    prev = e
                }
                #expect(cue.spec.envelope(1) == 0)
                // Only Bleed shows the new picture before the cut, and never more than its leak.
                for k in 0..<100 {
                    let m = cue.spec.swap(Float(k) / 100)
                    #expect(style == .bleed ? m <= DropPlan.bleedLeak + 1e-6 : m == 0)
                }
                #expect(cue.spec.swap(1) == 1)
            }
        }
    }

    @Test func firstCleanFrameIsPresentedWithinHalfAFrameOfTheDownbeat() {
        let cue = reveal(.tear, tempo: 69, fillBeats: 4)
        for hz in [60.0, 90] {
            let period = 1 / hz
            for k in 0..<16 {
                let phase = Double(k) / 16 * period
                // Draws at t; presented at t + lead (exact lead); the renderer evaluates at t + lead - period / 2,
                // i.e. the half-frame early bias of the lead.
                let lead = 0.020
                var t = cue.fillStart + phase
                var presented: Double?
                while t < cue.downbeat + 1 {
                    if cue.frame(presentedAt: t + lead + period / 2).done { presented = t + lead; break }
                    t += period
                }
                let p = try! #require(presented)
                #expect(p >= cue.downbeat - period / 2 - 1e-9 && p < cue.downbeat + period / 2, "\(hz) Hz phase \(k)")
            }
        }
    }

    @Test func latePlanningShortensOrSkipsTheBuild() throws {
        let beat = 60.0 / 69
        let grid = LofiTakeGrid(origin: 50, beatDuration: beat)
        let downbeat = grid.origin + 32 * beat
        func plan(_ lead: Double) -> LofiImageReveal? {
            LofiImageReveal.next(on: grid, after: downbeat - lead, now: downbeat - lead, fills: nil, hasDrums: true,
                                 pickDrop: { b, _, s in .pinnedDrop(.tear, seed: 1, duration: Float(b), strength: s) },
                                 pickBell: { _ in .classic }).reveal
        }
        #expect(plan(0.5) == nil)
        let late = try #require(plan(0.7))
        #expect(abs(late.duration - 0.55) < 1e-6)
        #expect(abs(Double(late.spec.duration) - 0.55) < 1e-5)
    }

    @Test func revealUsesTheTakeFillsAndClampsTheBuild() throws {
        let beat = 60.0 / 58
        let grid = LofiTakeGrid(origin: 50, beatDuration: beat)
        var fills = LofiTakeFills.defaults
        fills.turnaroundStartBeat = 56.5
        fills.turnaroundHits = [56.5, 58, 60, 62, 63.75]
        fills.halfwayStartBeat = 31.5
        let after = grid.origin + 33 * beat
        let r = try #require(LofiImageReveal.next(
            on: grid, after: after, now: after, fills: fills, hasDrums: true,
            pickDrop: { b, _, s in .pinnedDrop(.blocks, seed: 1, duration: Float(b), strength: s) },
            pickBell: { _ in .classic }).reveal)
        // 7.5 beats at 58 BPM is 7.8 s: clamped to the largest whole number of beats within 6 s (5 beats).
        #expect(abs((r.downbeat - r.fillStart) / beat - 5) < 1e-6)
        #expect(r.duration <= 6 + 1e-9)
        #expect(r.hits.count == 3 && r.hits.allSatisfy { $0 >= r.fillStart && $0 < r.downbeat })
        #expect(r.spec.drop?.strength == 1)
        // A one-beat minimum at the halfway change, and the halfway strength.
        let h = try #require(LofiImageReveal.next(
            on: grid, after: grid.origin + 20 * beat, now: grid.origin + 20 * beat, fills: fills, hasDrums: true,
            pickDrop: { b, _, s in .pinnedDrop(.blocks, seed: 1, duration: Float(b), strength: s) },
            pickBell: { _ in .classic }).reveal)
        #expect(abs((h.downbeat - h.fillStart) / beat - 1) < 1e-6)
        #expect(h.spec.drop?.strength == DropPlan.halfwayStrength)
        // Without drum takes: the default build, no hits, the halfway strength at the turnaround too.
        let n = try #require(LofiImageReveal.next(
            on: grid, after: after, now: after, fills: fills, hasDrums: false,
            pickDrop: { b, _, s in .pinnedDrop(.blocks, seed: 1, duration: Float(b), strength: s) },
            pickBell: { _ in .classic }).reveal)
        #expect(abs((n.downbeat - n.fillStart) / beat - 4) < 1e-6 && n.hits.isEmpty)
        #expect(n.spec.drop?.strength == DropPlan.halfwayStrength)
    }

    @Test func dropFrameKicksOnHitsAndStepsFaster() {
        let f0 = DropFrame.make(at: 0.5, build: 2, hits: [0.1, 0.5])
        #expect(abs(f0.kick - 1) < 1e-6)
        let f1 = DropFrame.make(at: 0.64, build: 2, hits: [0.1, 0.5])
        #expect(f1.kick < 0.2 && f1.kick > 0.05)
        #expect(f1.step >= 2)
        // The clock part runs at 4 Hz at the start and 24 Hz at the cut.
        let early = DropFrame.make(at: 0.25, build: 2, hits: []).step
        let late1 = DropFrame.make(at: 1.95, build: 2, hits: []).step
        let late2 = DropFrame.make(at: 1.999, build: 2, hits: []).step
        #expect(early <= 2)
        #expect(late2 - late1 >= 1)
        #expect(DropFrame.make(at: 2, build: 2, hits: []).done)
    }

    @Test func finisherRampsOverTheEndOfTheBuild() {
        for f in DropFinisher.allCases where f != .none {
            let spec = TransitionSpec.pinnedDrop(.tear, seed: 0, duration: 2, finisher: f)
            #expect(spec.finish(0.5) == 0)
            #expect(spec.finish(1 - 0.5 / 120) > 0.5, "\(f) near the cut")
            #expect(spec.finish(1) == 0)
        }
        let w = TransitionSpec.pinnedDrop(.tear, seed: 0, duration: 2, finisher: .whiteout)
        // The last 60 Hz frame of the build is mostly white: f^2 >= 0.9.
        let f = w.finish(1 - 1 / 120.0)
        #expect(f * f >= 0.9)
    }

    // MARK: Director

    @Test func directorDropModeFollowsItsRules() {
        var d = TransitionDirector(seed: 11)
        var specs: [TransitionSpec] = []
        var halfway: [Bool] = []
        for k in 0..<48 {
            let h = k % 2 == 0
            specs.append(d.nextDrop(time: Float(k) * 27, intensity: 0.6, build: k % 3 == 0 ? 1.2 : 3,
                                    halfway: h, strength: h ? 0.7 : 1))
            halfway.append(h)
        }
        let styles = specs.map(\.style)
        #expect(!styles.contains(.classic))
        #expect(styles.allSatisfy { TransitionStyle.dropFamily.contains($0) })
        for i in styles.indices {
            #expect(!styles[max(0, i - TransitionDirector.recency)..<i].contains(styles[i]), "recency at \(i)")
            if i > 0 { #expect(styles[i].familyGroup != styles[i - 1].familyGroup, "family at \(i)") }
        }
        let fins = specs.map { $0.drop!.finisher }
        for (a, b) in zip(fins, fins.dropFirst()) { #expect(a != b) }
        #expect(Set(styles).count >= 12)
        #expect(Set(fins).count >= 4)
        for (s, h) in zip(specs, halfway) where h {
            #expect(s.drop!.finisher != .whiteout && s.drop!.finisher != .invert)
        }
        #expect(specs.allSatisfy { $0.drop!.strength == 0.7 || $0.drop!.strength == 1 })
        #expect(specs.filter { $0.style == .crush }.allSatisfy { $0.drop!.colour == .posterize })
    }

    @Test func gentleDropsBelowAQuarterIntensity() {
        var d = TransitionDirector(seed: 3)
        for k in 0..<24 {
            let s = d.nextDrop(time: Float(k), intensity: 0.1, build: 2, halfway: false, strength: 1)
            #expect(s.style.isDropGentle)
            #expect(s.drop!.finisher == .blackout || s.drop!.finisher == .collapse)
        }
    }

    /// The bell picks for seeds 0-3, captured from main before the drop styles existed.
    @Test func bellSequenceIsUnchanged() {
        let expected: [(String, Double, Double, Int)] = [
            ("85b7985b231c82b459ca1596b832a798c479836abc9784c395ba297185964218", 31.77169, 193.5474, 35),
            ("9ab6812b698acb2153bc1a8bc9a863b4512b68a5132b6471589641c82b469328", 30.49809, 190.6968, 34),
            ("95a63985a14897318bc316b5a96b8215987bc9a18296483ba542973b5182b731", 31.88398, 193.6888, 35),
            ("98c32ba9c84617a854738c4951246813bca9423b8154c937421a593b74c31a28", 32.38158, 187.2178, 30),
        ]
        for (s, e) in expected.enumerated() {
            var d = TransitionDirector(seed: UInt64(s))
            var hex = "", seedSum = 0.0, durSum = 0.0, flips = 0
            for k in 0..<64 {
                let spec = d.next(time: Float(k) * 31, intensity: Float(k % 5) / 4, energy: k % 3 == 0 ? nil : Float(k % 7) / 6,
                                  hasDepth: k % 2 == 0, imageInterval: 30)
                hex += String(spec.style.rawValue, radix: 16)
                seedSum += Double(spec.seed); durSum += Double(spec.duration); flips += spec.flip ? 1 : 0
                #expect(spec.drop == nil)
            }
            #expect(hex == e.0, "seed \(s)")
            #expect(abs(seedSum - e.1) < 1e-3 && abs(durSum - e.2) < 1e-2 && flips == e.3, "seed \(s)")
        }
    }

    // MARK: Uniform contract

    @Test func uniformFieldNamesMatchTheMetalStruct() throws {
        let metal = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Liminal/Shaders/EffectsRenderer.metal")
        let text = try String(contentsOf: metal, encoding: .utf8)
        let body = try #require(text.components(separatedBy: "struct EffectsUniforms {").dropFirst().first?
            .components(separatedBy: "};").first)
        var metalNames: [String] = []
        for line in body.split(separator: "\n") {
            let code = line.components(separatedBy: "//")[0].trimmingCharacters(in: .whitespaces)
            guard code.hasPrefix("float ") else { continue }
            let decl = code.dropFirst(6).replacingOccurrences(of: ";", with: "")
            metalNames += decl.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let swiftNames = Mirror(reflecting: EffectsUniformsComputer.compute(time: 0)).children.compactMap(\.label)
        #expect(swiftNames == metalNames)
        #expect(swiftNames.count == 65)
    }

    // MARK: Fill detector

    private func take(fillBeats: Int, at boundary: Int = 64, busyBackbeat: Bool = false) -> [LofiDrumLandmark] {
        let fpb = 40_000.0
        var marks: [LofiDrumLandmark] = []
        func add(_ kind: LofiDrumLandmark.Kind, _ beat: Double, _ strength: Float = 1) {
            let f = Int(beat * fpb)
            marks.append(LofiDrumLandmark(kind: kind, attackFrame: f, peakFrame: f + 40, strength: strength, confidence: 0.9))
        }
        for b in 0..<64 {
            let inFill = b >= boundary - fillBeats && b < boundary
            if inFill {
                for q in 0..<4 { add(q % 2 == 0 ? .snare : .other, Double(b) + Double(q) * 0.25 + 0.01) }
            } else {
                add(b % 2 == 0 ? .kick : .snare, Double(b) + 0.01)
                if busyBackbeat && b % 4 == 3 { add(.snare, Double(b) + 0.51); add(.other, Double(b) + 0.76) }
            }
            add(.hat, Double(b) + 0.02, 0.8)
            add(.hat, Double(b) + 0.52, 0.6)
        }
        return marks
    }

    @Test func fillDetectorFindsSyntheticFills() {
        for f in [1, 2, 4, 8] {
            let r = LofiFillDetector.detect(landmarks: take(fillBeats: f), framesPerBeat: 40_000)
            #expect(r.turnaroundDetected, "fill \(f)")
            #expect(abs(r.turnaroundStartBeat - Double(64 - f)) < 0.5, "fill \(f): \(r.turnaroundStartBeat)")
            #expect(!r.turnaroundHits.isEmpty && r.turnaroundHits.count <= LofiFillDetector.maxHits)
            #expect(r.turnaroundHits.allSatisfy { $0 >= r.turnaroundStartBeat && $0 < 64 })
            let h = LofiFillDetector.detect(landmarks: take(fillBeats: f, at: 32), framesPerBeat: 40_000)
            #expect(h.halfwayDetected && abs(h.halfwayStartBeat - Double(32 - f)) < 0.5, "halfway fill \(f)")
        }
        let none = LofiFillDetector.detect(landmarks: take(fillBeats: 0), framesPerBeat: 40_000)
        #expect(!none.turnaroundDetected && none.turnaroundStartBeat == 60)
        #expect(!none.halfwayDetected && none.halfwayStartBeat == 30)
        let busy = LofiFillDetector.detect(landmarks: take(fillBeats: 0, busyBackbeat: true), framesPerBeat: 40_000)
        #expect(!busy.turnaroundDetected && !busy.halfwayDetected)
        #expect(LofiFillDetector.detect(landmarks: [], framesPerBeat: 40_000) == .defaults)
    }

    /// The cut is drawn a display lead before the downbeat, i.e. before the held zoom's `start`: the new
    /// picture must start at its own framing (age 0) there, not inherit the old picture's push for a few frames.
    @Test func cutFrameStartsTheNewPicturesFramingBeforeTheDownbeat() {
        var zoom = ImageZoomTiming()
        zoom.imageChanged(at: 100, replacing: false)
        // Image shown at 130 (pre-roll), cut (downbeat) at 133 on the effect clock.
        zoom.imageChanged(at: 130, replacing: true, holdUntil: 133)
        let lead: Float = 0.028
        // During the build the old framing keeps moving.
        #expect(zoom.age(at: 132) == 32)
        #expect(zoom.age(at: 133 - lead) > 32)
        // The cut frame (drawn before the downbeat) and the frames after it: the new picture's push from 0.
        #expect(zoom.age(at: 133 - lead, cut: true) == 0)
        #expect(zoom.age(at: 133, cut: true) == 0)
        #expect(abs(zoom.age(at: 133.5, cut: true) - 0.5) < 1e-4)
        #expect(abs(zoom.age(at: 133.5) - 0.5) < 1e-4)
        let atCut = EffectsUniformsComputer.imageZoomScale(age: zoom.age(at: 133 - lead, cut: true))
        let after = EffectsUniformsComputer.imageZoomScale(age: zoom.age(at: 133 + 1.0 / 90, cut: true))
        #expect(abs(after - atCut) < 0.001)
    }
}
