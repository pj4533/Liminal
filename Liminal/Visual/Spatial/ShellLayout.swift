//
//  ShellLayout.swift
//  Liminal
//
//  Geometry and UV maths of the visionOS spatial shell (docs/plans/spatial.md, section 2).
//  Pure Swift with no RealityKit dependency, so it compiles on every platform and is unit tested
//  on macOS (LiminalTests/SpatialShellTests.swift).
//
//  The shell is a cylinder around the viewer made of three tiles that all show the SAME effected
//  2048² texture:
//    - hero: 112.5° x 75° straight ahead, the image undistorted (same framing as the old dome);
//    - right / left: the hero mirrored in u and turned ±112.5°, so the picture continues across the
//      seams at ±56.25° like a kaleidoscope. Their outer halves fade to black toward the 22.5° gap
//      directly behind the viewer.
//  Every tile also has a band above and below the image, mirrored in v, that fades to black.
//
//  Angles are measured from the shell centre (the viewer's head). Azimuth is positive to the
//  viewer's right, elevation positive up. Mesh-local position for azimuth h and elevation e at the
//  base radius: rho0 * (sin h, tan e, -cos h) (a cylinder, like the old dome mesh).
//  UV convention as the old dome (docs/decisions/orientation.md): u = 0 at the image's left edge,
//  v = 0 at the BOTTOM, v = 1 at the TOP. Materials flip v when sampling.
//

import Foundation
import simd

nonisolated enum ShellLayout {

    // MARK: Constants

    /// Base (zero-relief) cylinder radius in metres.
    static let baseRadius: Float = 2.5
    /// Vertical angle of the image, degrees.
    static let heroVerticalDeg: Float = 75
    /// Horizontal angle of the image (3:2 like ImageFraming.displayAspect), degrees.
    static let heroHorizontalDeg: Float = heroVerticalDeg * Float(ImageFraming.displayAspect)  // 112.5

    /// Grid segments across one tile, and down the image and each band.
    static let columns = 112
    static let heroRows = 72
    static let bandRows = 12
    /// Elevation the bands add above and below the image, degrees. Same angular rate as the image
    /// (75° per unit v), so the mirror continues at the same scale: the band shows the 30% of the
    /// image nearest the edge and reaches ±60° elevation.
    static let bandDeg: Float = 22.5
    /// Band coordinate (0 at the image edge, 1 at the outer edge) where the vertical fade starts.
    static let bandFadeStart: Float = 0.2

    /// Brightness of the mirrored side tiles relative to the hero.
    static let sideGain: Float = 0.9
    /// World azimuths (degrees from straight ahead) where the side tiles start / finish fading.
    static let rearFadeStartDeg: Float = 124
    static let rearFadeEndDeg: Float = 168.75

    /// Relief limits: nearest and farthest radius at full relief strength, metres.
    static let nearRadius: Float = 1.6
    static let farRadius: Float = 6.0
    /// 1/near - 1/far (1/m): inverse-radius span of q = -0.5...0.5 at k = 1.
    static let inverseSpan: Float = 1 / nearRadius - 1 / farRadius
    /// Largest inverse-radius step between neighbouring vertices at k = 1 (1/m).
    static let slopeLimit: Float = 0.035
    /// Default relief strength (the "Depth" setting, phase 3).
    static let defaultDepth: Float = 0.6

    /// Breathing: radius change in metres (old dome: 4 cm on a 2 m panel).
    static let breathingAmplitude: Float = 0.03
    static let breathingSpeed: Float = 0.4

    // MARK: Grid

    static var vertexColumns: Int { columns + 1 }
    static var vertexRows: Int { heroRows + 2 * bandRows + 1 }
    static var vertexCount: Int { vertexColumns * vertexRows }
    static var indexCount: Int { columns * (heroRows + 2 * bandRows) * 6 }

    static var halfHorizontalRad: Float { heroHorizontalDeg * .pi / 360 }
    static var halfVerticalRad: Float { heroVerticalDeg * .pi / 360 }

    /// Column c: u (0 at the image's left edge) and mesh-local azimuth in radians.
    static func column(_ c: Int) -> (u: Float, azimuth: Float) {
        let u = Float(c) / Float(columns)
        return (u, -halfHorizontalRad + u * heroHorizontalDeg * .pi / 180)
    }

    struct Row: Equatable {
        /// v of the unmirrored continuation (< 0 below the image, > 1 above).
        var v: Float
        /// v actually sampled (mirrored back into 0...1).
        var sampleV: Float
        /// 0 inside the image, rising to 1 at the outer edge of a band.
        var band: Float
        /// Elevation, radians.
        var elevation: Float
    }

    /// Row r (0 = bottom edge of the lower band).
    static func row(_ r: Int) -> Row {
        let bandV = bandDeg / heroVerticalDeg  // 0.3
        let v: Float
        let band: Float
        if r < bandRows {
            band = 1 - Float(r) / Float(bandRows)
            v = -band * bandV
        } else if r > bandRows + heroRows {
            band = Float(r - bandRows - heroRows) / Float(bandRows)
            v = 1 + band * bandV
        } else {
            band = 0
            v = Float(r - bandRows) / Float(heroRows)
        }
        let elevation = -halfVerticalRad + v * heroVerticalDeg * .pi / 180
        return Row(v: v, sampleV: mirror(v), band: band, elevation: elevation)
    }

    /// Mirror a coordinate back into 0...1 (one reflection each side is enough here).
    static func mirror(_ x: Float) -> Float {
        if x < 0 { return -x }
        if x > 1 { return 2 - x }
        return x
    }

    /// Mesh-local position at the base radius.
    static func basePosition(azimuth: Float, elevation: Float) -> SIMD3<Float> {
        baseRadius * SIMD3(sin(azimuth), tan(elevation), -cos(azimuth))
    }

    // MARK: Relief

    /// Radius for an inverse-radius offset q (-0.5...0.5) at relief strength k.
    static func radius(q: Float, k: Float) -> Float {
        1 / (1 / baseRadius + k * q * inverseSpan)
    }

    /// Vertical fade (brightness) at band coordinate b. Mirrors the material graph.
    static func verticalFade(band b: Float) -> Float {
        1 - smoothstep(bandFadeStart, 1, b)
    }

    static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: Tiles

    enum Tile: CaseIterable {
        case hero, right, left

        /// Mirrored in u (entity scale x = -1 before the yaw).
        var isMirrored: Bool { self != .hero }

        /// Yaw about +Y applied to the tile entity, radians (RealityKit: positive turns -Z toward -X).
        var yaw: Float {
            switch self {
            case .hero: return 0
            case .right: return -ShellLayout.heroHorizontalDeg * .pi / 180
            case .left: return ShellLayout.heroHorizontalDeg * .pi / 180
            }
        }

        var gain: Float { self == .hero ? 1 : ShellLayout.sideGain }

        /// World azimuth (radians, positive right) of a mesh-local azimuth on this tile.
        func worldAzimuth(local h: Float) -> Float {
            let x: Float = isMirrored ? -h : h
            return x - yaw
        }

        /// u at a world azimuth on this tile (inverse of column + worldAzimuth).
        func u(atWorldAzimuth a: Float) -> Float {
            let local = isMirrored ? -(a + yaw) : a + yaw
            return (local + ShellLayout.halfHorizontalRad) / (ShellLayout.heroHorizontalDeg * .pi / 180)
        }

        /// Rear fade as a smoothstep in u: brightness 1 at `full`, 0 at `zero`. Nil for the hero.
        var rearFade: (full: Float, zero: Float)? {
            guard self != .hero else { return nil }
            let sign: Float = self == .right ? 1 : -1
            return (u(atWorldAzimuth: sign * ShellLayout.rearFadeStartDeg * .pi / 180),
                    u(atWorldAzimuth: sign * ShellLayout.rearFadeEndDeg * .pi / 180))
        }

        /// Total brightness at (u, band), as the material computes it.
        func brightness(u: Float, band: Float) -> Float {
            var b = gain * ShellLayout.verticalFade(band: band)
            if let f = rearFade {
                b *= f.full > f.zero ? ShellLayout.smoothstep(f.zero, f.full, u)
                                     : 1 - ShellLayout.smoothstep(f.full, f.zero, u)
            }
            return b
        }
    }

    /// Breathing radius offset (metres) for grid fractions (hFrac, vFrac 0...1 over the tile).
    /// Same four-sine wave as the old dome, tapered to zero in the bands.
    static func breathing(hFrac h: Float, vFrac v: Float, band: Float, time: Float) -> Float {
        let t = time * breathingSpeed
        let dh = h - 0.5, dv = v - 0.5
        let w = sin(h * 6 + t) * 0.4 + sin(v * 5 + t * 0.7) * 0.3
            + sin((h + v) * 4 + t * 0.5) * 0.2 + sin((dh * dh + dv * dv).squareRoot() * 8 - t * 0.8) * 0.1
        return w * breathingAmplitude * (1 - band)
    }

    /// Rotation that brings the content at (yaw, pitch) degrees in front of a fixed camera
    /// (DEBUG simulator harness). Identity for (0, 0).
    static func viewRotation(yawDeg: Float, pitchDeg: Float) -> simd_quatf {
        simd_quatf(angle: -pitchDeg * .pi / 180, axis: [1, 0, 0]) * simd_quatf(angle: yawDeg * .pi / 180, axis: [0, 1, 0])
    }
}
