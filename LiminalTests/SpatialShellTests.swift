import Testing
import Foundation
import simd
import CoreGraphics
@testable import Liminal

/// ShellLayout (docs/plans/spatial.md section 2): grid, UVs, seams, fades, relief radius.
struct SpatialShellLayoutTests {

    private func deg(_ r: Float) -> Float { r * 180 / .pi }

    @Test func gridSize() {
        #expect(ShellLayout.vertexColumns == 113)
        #expect(ShellLayout.vertexRows == 97)
        #expect(ShellLayout.vertexCount == 113 * 97)
        #expect(ShellLayout.indexCount == 112 * 96 * 6)
    }

    @Test func heroUsesWideFramingAndKeepsItsHorizontalExtent() {
        let vertical: Float = 112.5 * 9 / 16
        #expect(abs(ShellLayout.heroVerticalDeg - vertical) < 1e-3)
        for c in [0, 28, 56, 112] {
            let col = ShellLayout.column(c)
            #expect(abs(col.u - Float(c) / 112) < 1e-6)
            #expect(abs(deg(col.azimuth) - (-56.25 + col.u * 112.5)) < 1e-3)
        }
        for j in [0, 18, 36, 72] {
            let row = ShellLayout.row(ShellLayout.bandRows + j)
            #expect(abs(row.v - Float(j) / 72) < 1e-6)
            #expect(row.sampleV == row.v)
            #expect(row.band == 0)
            #expect(abs(deg(row.elevation) - (row.v - 0.5) * vertical) < 1e-3)
        }
    }

    @Test func bandsMirrorAndReachSixtyDegrees() {
        let top = ShellLayout.row(ShellLayout.vertexRows - 1)
        let bottom = ShellLayout.row(0)
        #expect(abs(deg(top.elevation) - 60) < 1e-3)
        #expect(abs(deg(bottom.elevation) + 60) < 1e-3)
        #expect(top.band == 1 && bottom.band == 1)
        // Mirrored: just past the top edge samples just below it.
        let above = ShellLayout.row(ShellLayout.bandRows + ShellLayout.heroRows + 1)
        #expect(above.v > 1 && above.sampleV < 1)
        #expect(abs((above.v - 1) - (1 - above.sampleV)) < 1e-6)
        let mirroredSpan = (60 - ShellLayout.heroVerticalDeg / 2) / ShellLayout.heroVerticalDeg
        #expect(abs(top.sampleV - (1 - mirroredSpan)) < 1e-5)
        #expect(abs(bottom.sampleV - mirroredSpan) < 1e-5)
    }

    @Test func seamsAreContinuous() {
        let heroRight = ShellLayout.Tile.hero.worldAzimuth(local: ShellLayout.column(112).azimuth)
        let heroLeft = ShellLayout.Tile.hero.worldAzimuth(local: ShellLayout.column(0).azimuth)
        // Same u on both sides of each seam, same world azimuth.
        let rightAtU1 = ShellLayout.Tile.right.worldAzimuth(local: ShellLayout.column(112).azimuth)
        let leftAtU0 = ShellLayout.Tile.left.worldAzimuth(local: ShellLayout.column(0).azimuth)
        #expect(abs(deg(heroRight) - 56.25) < 1e-3)
        #expect(abs(deg(rightAtU1) - deg(heroRight)) < 1e-3)
        #expect(abs(deg(leftAtU0) - deg(heroLeft)) < 1e-3)
        // Outer ends of the side tiles: ±168.75° (337.5° covered, 22.5° gap behind).
        let rightEnd = ShellLayout.Tile.right.worldAzimuth(local: ShellLayout.column(0).azimuth)
        let leftEnd = ShellLayout.Tile.left.worldAzimuth(local: ShellLayout.column(112).azimuth)
        #expect(abs(deg(rightEnd) - 168.75) < 1e-3)
        #expect(abs(deg(leftEnd) + 168.75) < 1e-3)
        // Inverse mapping agrees.
        for tile in ShellLayout.Tile.allCases {
            for c in [0, 40, 112] {
                let col = ShellLayout.column(c)
                #expect(abs(tile.u(atWorldAzimuth: tile.worldAzimuth(local: col.azimuth)) - col.u) < 1e-5)
            }
        }
    }

    @Test func rearFadeAndGain() {
        let hero = ShellLayout.Tile.hero
        #expect(hero.rearFade == nil)
        #expect(hero.brightness(u: 0.5, band: 0) == 1)
        for (tile, sign) in [(ShellLayout.Tile.right, Float(1)), (.left, -1)] {
            let start = tile.u(atWorldAzimuth: sign * 124 * .pi / 180)
            let end = tile.u(atWorldAzimuth: sign * 168.75 * .pi / 180)
            #expect(abs(tile.brightness(u: start, band: 0) - ShellLayout.sideGain) < 1e-5)
            #expect(tile.brightness(u: end, band: 0) < 1e-6)
            // Seam side is at full side gain.
            let seamU: Float = tile == .right ? 1 : 0
            #expect(abs(tile.brightness(u: seamU, band: 0) - ShellLayout.sideGain) < 1e-6)
        }
    }

    @Test func verticalFade() {
        #expect(ShellLayout.verticalFade(band: 0) == 1)
        #expect(ShellLayout.verticalFade(band: ShellLayout.bandFadeStart) == 1)
        #expect(ShellLayout.verticalFade(band: 1) == 0)
        #expect(ShellLayout.verticalFade(band: 0.6) > 0 && ShellLayout.verticalFade(band: 0.6) < 1)
    }

    @Test func reliefRadiusRange() {
        #expect(abs(ShellLayout.radius(q: 0, k: 1) - 2.5) < 1e-5)
        #expect(abs(ShellLayout.radius(q: 0.5, k: 1) - 1.6) < 0.02)
        #expect(abs(ShellLayout.radius(q: -0.5, k: 1) - 5.85) < 0.01)  // plan: 1.6 ... 5.85 m at k = 1
        #expect(abs(ShellLayout.radius(q: 0.5, k: 0) - 2.5) < 1e-5)
    }

    @Test func breathingIsSmallAndTaperedInBands() {
        for t: Float in [0, 7, 33] {
            #expect(abs(ShellLayout.breathing(hFrac: 0.3, vFrac: 0.6, band: 0, time: t)) <= ShellLayout.breathingAmplitude)
            #expect(ShellLayout.breathing(hFrac: 0.3, vFrac: 1, band: 1, time: t) == 0)
        }
    }

    @Test func viewRotationBringsTargetInFront() {
        // Content at azimuth 90° (right) ends up straight ahead (-Z).
        let right = ShellLayout.basePosition(azimuth: .pi / 2, elevation: 0)
        let r = ShellLayout.viewRotation(yawDeg: 90, pitchDeg: 0).act(simd_normalize(right))
        #expect(simd_distance(r, SIMD3<Float>(0, 0, -1)) < 1e-4)
        // Content at elevation 45° ends up straight ahead.
        let up = simd_normalize(SIMD3<Float>(0, 1, -1))
        let u = ShellLayout.viewRotation(yawDeg: 0, pitchDeg: 45).act(up)
        #expect(simd_distance(u, SIMD3<Float>(0, 0, -1)) < 1e-4)
    }
}

/// DepthReliefField + ReliefBlend (docs/plans/spatial.md section 3).
struct DepthReliefFieldTests {

    private let cols = DepthReliefField.columns, rows = DepthReliefField.rows

    /// Depth image: near (1) at the top-left, far (0) at the bottom-right, with a sharp near block.
    private func gradient(width: Int = 64, height: Int = 48, block: Bool = true) -> [Float] {
        var d = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var v = 1 - (Float(x) / Float(width - 1) + Float(y) / Float(height - 1)) / 2
                if block, x > width / 2, x < width * 3 / 4, y > height / 3, y < height * 2 / 3 { v = 1 }
                d[y * width + x] = v
            }
        }
        return d
    }

    private func qAt(_ f: DepthReliefField, u: Float, v: Float) -> Float {
        let c = Int((u * Float(ShellLayout.columns)).rounded())
        let r = ShellLayout.bandRows + Int((v * Float(ShellLayout.heroRows)).rounded())
        return f.q[r * cols + c]
    }

    @Test func constantDepthGivesSmoothShell() {
        let f = DepthReliefField.build(depth: [Float](repeating: 0.37, count: 64 * 48), width: 64, height: 48)
        #expect(f.q.count == ShellLayout.vertexCount)
        #expect(f.q.allSatisfy { $0 == 0 })
    }

    @Test func nearIsInFrontAndOrientationMatchesImage() {
        let f = DepthReliefField.build(depth: gradient(block: false), width: 64, height: 48)
        // Image top-left (u 0, v 1) is near -> positive q (smaller radius); bottom-right far.
        #expect(qAt(f, u: 0.05, v: 0.95) > 0.2)
        #expect(qAt(f, u: 0.95, v: 0.05) < -0.2)
        #expect(ShellLayout.radius(q: qAt(f, u: 0.05, v: 0.95), k: 1) < ShellLayout.baseRadius)
        // Median-centred: roughly half in front.
        let hero = (ShellLayout.bandRows...(ShellLayout.bandRows + ShellLayout.heroRows)).flatMap { r in
            (0..<cols).map { f.q[r * cols + $0] }
        }
        let front = Float(hero.filter { $0 > 0 }.count) / Float(hero.count)
        #expect(front > 0.35 && front < 0.65)
    }

    @Test func radiusStaysInBoundsForNoisyInput() {
        var rng = SystemRandomNumberGenerator()
        let d = (0..<(80 * 60)).map { _ in Float.random(in: 0...1, using: &rng) }
        let f = DepthReliefField.build(depth: d, width: 80, height: 60)
        for q in f.q {
            #expect(q >= -0.5 && q <= 0.5)
            let r = ShellLayout.radius(q: q, k: 1)
            #expect(r >= 1.58 && r <= 5.86)
        }
    }

    @Test func slopeLimitHolds() {
        let f = DepthReliefField.build(depth: gradient(), width: 64, height: 48)
        let step = DepthReliefField.maxNeighbourStep(f.q, cols: cols, rows: rows)
        #expect(step <= DepthReliefField.qSlopeLimit + 1e-5)
        #expect(f.range.max > 0.1)  // the near block survives the limit
    }

    @Test func slopeLimitLeavesSmoothFieldsAlone() {
        let smooth = (0..<(10 * 8)).map { Float($0 % 10) * 0.01 }
        #expect(DepthReliefField.slopeLimited(smooth, cols: 10, rows: 8, limit: 0.05) == smooth)
        var spike = [Float](repeating: 0, count: 100)
        spike[55] = 1
        let limited = DepthReliefField.slopeLimited(spike, cols: 10, rows: 10, limit: 0.1)
        #expect(DepthReliefField.maxNeighbourStep(limited, cols: 10, rows: 10) <= 0.1 + 1e-6)
        #expect(limited.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func bandsTaperToZeroAtTheOuterEdge() {
        let f = DepthReliefField.build(depth: gradient(), width: 64, height: 48)
        for c in 0..<cols {
            #expect(abs(f.q[c]) < 0.02)
            #expect(abs(f.q[(rows - 1) * cols + c]) < 0.02)
        }
    }

    @Test func percentilesHandleFlatAndTinyInputs() {
        #expect(DepthReliefField.percentile([], 0.5) == 0)
        #expect(DepthReliefField.percentile([3], 0.98) == 3)
        #expect(DepthReliefField.percentile([0, 1], 0.5) == 0.5)
        // Mostly flat with a few outliers: outliers clipped, not a crash or NaN.
        var d = [Float](repeating: 0.5, count: 64 * 48)
        d[10] = 1; d[20] = 0
        let f = DepthReliefField.build(depth: d, width: 64, height: 48)
        #expect(f.q.allSatisfy { $0.isFinite })
    }

    @Test func buildFromCGImage() throws {
        let w = 64, h = 48
        let bytes = gradient(width: w, height: h).map { UInt8($0 * 255) }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let f = try #require(DepthReliefField.build(depthImage: image))
        #expect(qAt(f, u: 0.05, v: 0.95) > 0.2)
    }

    @Test func reliefStrength() {
        #expect(ShellLayout.reliefStrength(depth: 1, drive: 0, transitionProgress: 0) == 1)
        #expect(abs(ShellLayout.reliefStrength(depth: 1, drive: 1, transitionProgress: 0) - 0.4) < 1e-6)
        #expect(abs(ShellLayout.reliefStrength(depth: 0.6, drive: 0, transitionProgress: 0.5) - 0.3) < 1e-6)
        #expect(ShellLayout.reliefStrength(depth: 0, drive: 0.3, transitionProgress: 0.2) == 0)
    }

    @Test func blendHoldsOldFieldUntilNewDepthThenEases() {
        var b = ReliefBlend()
        b.imageChanged(generation: 1)
        b.depthArrived([1], generation: 1, now: 10)
        #expect(b.weight(transitionProgress: nil, now: 10) == 0)
        #expect(b.weight(transitionProgress: nil, now: 10.7) == 1)
        b.imageChanged(generation: 2)
        #expect(b.previous == [1] && b.current == nil)
        #expect(b.weight(transitionProgress: 0.5, now: 11) == 0)  // new depth late: hold old field
        b.depthArrived([0], generation: 1, now: 11)               // stale generation ignored
        #expect(b.current == nil)
        b.depthArrived([2], generation: 2, now: 11)
        #expect(b.weight(transitionProgress: 0.5, now: 12) == 0.5)
        #expect(b.weight(transitionProgress: nil, now: 12) == 1)
    }
}

/// ShellPlacement / ShellRecentre / DepthSettingSmoother / breathing amplitude (phase 3).
struct SpatialShellPlacementTests {

    private func transform(yaw: Float, position: SIMD3<Float>, pitch: Float = 0) -> simd_float4x4 {
        let q = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
        var m = simd_float4x4(q)
        m.columns.3 = SIMD4(position, 1)
        return m
    }

    @Test func yawRoundTripsAndIgnoresPitch() {
        for deg: Float in [0, 30, -45, 90, 170, -170] {
            let y = deg * .pi / 180
            let got = ShellPlacement.yaw(of: transform(yaw: y, position: .zero, pitch: 0.4))
            #expect(abs(remainder(got - y, 2 * .pi)) < 1e-4)
        }
        #expect(ShellPlacement.yaw(of: matrix_identity_float4x4) == 0)
        let p = ShellPlacement.position(of: transform(yaw: 1, position: [0.2, 1.6, -0.3]))
        #expect(simd_distance(p, [0.2, 1.6, -0.3]) < 1e-6)
    }

    @Test func recentreIgnoresSmallHeadMotion() {
        var r = ShellRecentre(centre: [0, 1.5, 0])
        for _ in 0..<600 { r.update(head: [0.3, 1.5, 0], dt: 0.1) }
        #expect(r.centre == [0, 1.5, 0])
        #expect(!r.isRecentring)
    }

    @Test func recentreEasesWithTimeConstantAndSettles() {
        var r = ShellRecentre(centre: [0, 1.5, 0])
        let head = SIMD3<Float>(1, 1.5, 0)
        // One time constant (3 s) covers 1 - 1/e of the way.
        for _ in 0..<30 { r.update(head: head, dt: 0.1) }
        #expect(abs(r.centre.x - (1 - exp(-1))) < 0.01)
        #expect(r.isRecentring)
        for _ in 0..<300 { r.update(head: head, dt: 0.1) }
        #expect(!r.isRecentring)
        #expect(simd_distance(r.centre, head) < ShellPlacement.recentreStop)
        // Settled: the next small move does not restart it (hysteresis).
        let before = r.centre
        r.update(head: head + [0.2, 0, 0], dt: 0.1)
        #expect(r.centre == before)
    }

    @Test func recentreIsFrameRateIndependent() {
        var a = ShellRecentre(centre: .zero), b = ShellRecentre(centre: .zero)
        let head = SIMD3<Float>(0, 0, 2)
        for _ in 0..<20 { a.update(head: head, dt: 0.1) }
        for _ in 0..<200 { b.update(head: head, dt: 0.01) }
        #expect(abs(a.centre.z - b.centre.z) < 1e-3)
    }

    @Test func depthSmootherStartsAtTargetThenEases() {
        var s = DepthSettingSmoother()
        #expect(s.next(target: 0.6, dt: 0.011) == 0.6)
        let one = s.next(target: 1, dt: 0.5)  // one time constant
        #expect(abs(one - (0.6 + 0.4 * (1 - exp(-1)))) < 1e-4)
        for _ in 0..<500 { _ = s.next(target: 1, dt: 0.011) }
        #expect(abs((s.value ?? 0) - 1) < 1e-3)
        #expect(s.next(target: 5, dt: 100) <= 1)
    }

    @Test func breathingStaysWithinComfortCap() {
        #expect(ShellLayout.breathingAmplitude(amount: 0, energy: 1, pulseMotion: 1) == ShellLayout.breathingCalm)
        #expect(abs(ShellLayout.breathingAmplitude(amount: 1, energy: 1, pulseMotion: 1) - ShellLayout.breathingAmplitude) < 1e-6)
        for a: Float in [-1, 0, 0.5, 1, 3] {
            for e: Float in [0, 0.5, 2] {
                let v = ShellLayout.breathingAmplitude(amount: a, energy: e, pulseMotion: e)
                #expect(v >= ShellLayout.breathingCalm && v <= 0.03 + 1e-6)
            }
        }
    }
}
