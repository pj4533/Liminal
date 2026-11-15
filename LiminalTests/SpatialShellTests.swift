import Testing
import Foundation
import simd
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

    @Test func heroMatchesOldDomeMapping() {
        // Old dome: u linear in azimuth over 112.5°, v linear in elevation over 75°, v = 0 at the bottom.
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
            #expect(abs(deg(row.elevation) - (-37.5 + row.v * 75)) < 1e-3)
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
        #expect(abs(top.sampleV - 0.7) < 1e-5)
        #expect(abs(bottom.sampleV - 0.3) < 1e-5)
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
