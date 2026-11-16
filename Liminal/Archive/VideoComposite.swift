//
//  VideoComposite.swift
//  Liminal
//
//  Footage -> shader uniforms (docs/plans/archive-video.md 2.2). Pure: look ceilings, the mix formula
//  and the tint colours. `EffectsUniformsComputer.compute(video:)` calls `apply`; with `.off` every
//  video uniform stays 0 and the shader skips the stage.
//

import CoreGraphics
import simd
import Foundation

/// How footage is composited (one look per appearance; shader ids VIDEO_* in EffectsRenderer.metal).
nonisolated enum VideoLook: Int, CaseIterable, Sendable, Codable {
    /// Screen blend of the footage highlights, tinted, weighted by motion: a projection on smoke.
    case phantom = 1
    /// Soft-light: the footage's luma shades the picture's own colours.
    case imprint = 2
    /// A soft, flow-edged region near the centre where the footage shows as a duotone.
    case window = 3
    /// The footage takes over the frame as a duotone (intensity >= 0.4 only, at most 20 s at peak).
    case emerge = 4

    var name: String { String(describing: self) }
    init?(name: String) {
        guard let l = Self.allCases.first(where: { $0.name == name.lowercased() }) else { return nil }
        self = l
    }
    /// Choice weights (plan 2.2, tune).
    var weight: Float { self == .emerge ? 1 : 3 }
}

/// The footage state of one frame, as the render loop hands it to `EffectsUniformsComputer.compute`.
nonisolated struct VideoCompositeState: Sendable, Equatable {
    /// Moment envelope 0...1 (MomentPlan.envelope).
    var envelope: Float
    var look: VideoLook
    var seed: Float
    /// Width / height of the footage as shown (after the crop).
    var aspect: Float
    /// Highlight and shadow colours (sRGB 0...1) from the current picture.
    var tint: SIMD3<Float>
    var shade: SIMD3<Float>
    /// -LiminalVideoMix: constant mix (replaces envelope x ceiling x terms), for frozen-time stills.
    var constantMix: Float? = nil

    static let off = VideoCompositeState(envelope: 0, look: .phantom, seed: 0, aspect: 4.0 / 3.0,
                                         tint: SIMD3(1, 1, 1), shade: SIMD3(0, 0, 0))

    var isOff: Bool { envelope <= 0 && (constantMix ?? 0) <= 0 }
}

nonisolated enum VideoComposite {

    /// Mix ceiling at effect intensity 0 / 0.5 / 1 (plan 2.2 table, tune).
    static func ceilings(_ look: VideoLook) -> (Float, Float, Float) {
        switch look {
        case .phantom: return (0.35, 0.60, 0.80)
        case .imprint: return (0.40, 0.70, 0.90)
        case .window: return (0.50, 0.75, 0.90)
        case .emerge: return (0.00, 0.65, 0.85)
        }
    }

    static func ceiling(_ look: VideoLook, intensity: Float) -> Float {
        EffectLook.tri(min(max(intensity, 0), 1), ceilings(look))
    }

    /// ImageFraming.displayAspect (main-actor isolated there): the 3:2 frame on both platforms.
    static let frameAspect: Float = 1.5

    /// Footage size relative to the frame (1 = cover fit).
    static func scale(_ look: VideoLook) -> Float {
        switch look {
        case .phantom: return 0.85
        case .imprint: return 1.0
        case .window: return 0.95
        case .emerge: return 1.0
        }
    }

    /// videoMix = envelope x ceiling(intensity) x (0.75 + 0.25 drive) x (0.55 + 0.45 settled).
    /// `drive` is the clarity cycle (EffectLook.drive): the footage is a little clearer in wild stretches.
    /// `settled` is 0 while a new image arrives and 1 once it has been on screen a while: a new
    /// picture pulls the footage back while it is fresh.
    static func mix(_ s: VideoCompositeState, intensity: Float, drive: Float, settled: Float) -> Float {
        if let m = s.constantMix { return min(max(m, 0), 1) }
        let e = min(max(s.envelope, 0), 1)
        guard e > 0 else { return 0 }
        let d = min(max(drive, 0), 1), f = min(max(settled, 0), 1)
        return e * ceiling(s.look, intensity: intensity) * (0.75 + 0.25 * d) * (0.55 + 0.45 * f)
    }

    /// How settled the current picture is: 0 during its crossfade, rising to 1 over 6 s after it.
    static func settled(imageAge: Float?, transitionDuration: Float, inTransition: Bool) -> Float {
        if inTransition { return 0 }
        guard let age = imageAge else { return 1 }
        let x = min(max((age - transitionDuration) / 6, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// Writes the video uniforms. `.off` (or a zero mix) leaves them all 0.
    static func apply(_ s: VideoCompositeState, to u: inout EffectsUniforms,
                      intensity: Float, drive: Float, settled: Float) {
        let m = mix(s, intensity: intensity, drive: drive, settled: settled)
        guard m > 0.0005 else { return }
        u.videoMix = m
        u.videoLook = Float(s.look.rawValue)
        u.videoSeed = s.seed
        u.videoScale = scale(s.look)
        u.videoAspect = max(s.aspect, 0.1) / frameAspect
        u.videoTintR = s.tint.x; u.videoTintG = s.tint.y; u.videoTintB = s.tint.z
        u.videoShadeR = s.shade.x; u.videoShadeG = s.shade.y; u.videoShadeB = s.shade.z
    }

    // MARK: - Tint

    /// Highlight / shadow colours from a picture: mean of its brightest and darkest fifth (16 x 16
    /// thumbnail), the highlight lifted toward a bright, saturated version of its hue and the shadow
    /// pressed toward black, so the black-and-white footage takes the picture's palette.
    static func tint(of image: CGImage) -> (tint: SIMD3<Float>, shade: SIMD3<Float>) {
        let n = 16
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return (SIMD3(1, 1, 1), SIMD3(0, 0, 0))
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        var cols: [(l: Float, c: SIMD3<Float>)] = []
        cols.reserveCapacity(n * n)
        for i in 0..<(n * n) {
            let c = SIMD3(Float(px[i * 4]), Float(px[i * 4 + 1]), Float(px[i * 4 + 2])) / 255
            cols.append((0.299 * c.x + 0.587 * c.y + 0.114 * c.z, c))
        }
        cols.sort { $0.l < $1.l }
        let k = max(1, cols.count / 5)
        let dark = cols.prefix(k).reduce(SIMD3<Float>(repeating: 0)) { $0 + $1.c } / Float(k)
        let light = cols.suffix(k).reduce(SIMD3<Float>(repeating: 0)) { $0 + $1.c } / Float(k)
        return (tint: brighten(light), shade: darken(dark))
    }

    /// Scale so the largest channel is 0.95, then push chroma up a little (a glow colour, not grey).
    static func brighten(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let mx = max(c.x, max(c.y, c.z), 0.05)
        var v = c * (0.95 / mx)
        let l = (v.x + v.y + v.z) / 3
        v = SIMD3(repeating: l) + (v - SIMD3(repeating: l)) * 1.25
        return simd_clamp(v, SIMD3(repeating: 0.35), SIMD3(repeating: 1))
    }

    /// Shadow: the dark colour's hue at low value (0.06...0.14 max channel).
    static func darken(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let mx = max(c.x, max(c.y, c.z), 0.001)
        let target = min(max(mx, 0.06), 0.14)
        return simd_clamp(c * (target / mx), SIMD3(repeating: 0), SIMD3(repeating: 1))
    }
}
