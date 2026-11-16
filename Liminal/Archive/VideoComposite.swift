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

/// How footage is composited (one look per piece; shader ids VIDEO_* in EffectsRenderer.metal).
nonisolated enum VideoLook: Int, CaseIterable, Sendable, Codable {
    /// Screen blend of the footage highlights, tinted, weighted by motion: a projection on smoke.
    case phantom = 1
    /// Soft-light: the footage's luma shades the picture's own colours.
    case imprint = 2
    /// A soft, flow-edged region near the centre where the footage shows as a duotone.
    case window = 3
    /// The footage takes over the frame as a duotone (intensity >= 0.4 only, pieces of at most 16 s).
    case emerge = 4

    var name: String { String(describing: self) }
    init?(name: String) {
        guard let l = Self.allCases.first(where: { $0.name == name.lowercased() }) else { return nil }
        self = l
    }
    /// Choice weights (plan 2.2, tune).
    var weight: Float { self == .emerge ? 1 : 3 }
}

/// One footage layer of a frame: a piece as the composite sees it (decision A27). Slot 0 is shader layer A
/// (texture 7), slot 1 layer B (texture 8); during a crossfade both show.
nonisolated struct VideoLayer: Sendable, Equatable {
    /// envelope x level x calm (FootagePiece.weight): scaled by the look's ceiling in `VideoComposite.mix`.
    var weight: Float
    var look: VideoLook
    var seed: Float
    /// Width / height of the footage as shown (after the crop).
    var aspect: Float
    /// Share of the picture's warp the footage rides (0.6 was the fixed value before A27).
    var warp: Float = 0.6
}

/// The footage state of one frame, as the render loop hands it to `EffectsUniformsComputer.compute`.
nonisolated struct VideoCompositeState: Sendable, Equatable {
    /// Layer A (slot 0) and layer B (slot 1); nil = that layer is not drawn.
    var a: VideoLayer?
    var b: VideoLayer?
    /// Highlight and shadow colours (sRGB 0...1) from the current picture.
    var tint: SIMD3<Float>
    var shade: SIMD3<Float>
    /// -LiminalVideoMix: constant mix for every drawn layer (replaces weight x ceiling x terms), for stills.
    var constantMix: Float? = nil

    init(a: VideoLayer?, b: VideoLayer? = nil, tint: SIMD3<Float>, shade: SIMD3<Float>) {
        self.a = a
        self.b = b
        self.tint = tint
        self.shade = shade
    }

    /// One layer (slot 0) at weight `envelope` (shader bench, tests).
    init(envelope: Float, look: VideoLook, seed: Float, aspect: Float, tint: SIMD3<Float>, shade: SIMD3<Float>) {
        self.init(a: VideoLayer(weight: envelope, look: look, seed: seed, aspect: aspect), tint: tint, shade: shade)
    }

    static let off = VideoCompositeState(a: nil, tint: SIMD3(1, 1, 1), shade: SIMD3(0, 0, 0))

    var isOff: Bool {
        let wa = a?.weight ?? 0, wb = b?.weight ?? 0
        if constantMix != nil { return a == nil && b == nil }
        return wa <= 0 && wb <= 0
    }
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

    /// Share of the mix kept while a new picture arrives (`settled` 0): the footage dips, never vanishes.
    static let transitionFloor: Float = 0.6

    /// videoMix of one layer = weight x ceiling(intensity) x (0.75 + 0.25 drive) x (0.6 + 0.4 settled).
    /// `drive` is the clarity cycle (EffectLook.drive): the footage is a little clearer in wild stretches.
    /// `settled` is 0 while a new image arrives and 1 once it has been on screen a while: a new
    /// picture pulls the footage back while it is fresh.
    static func mix(_ l: VideoLayer?, constantMix: Float? = nil, intensity: Float, drive: Float, settled: Float) -> Float {
        guard let l else { return 0 }
        if let m = constantMix { return min(max(m, 0), 1) }
        let w = min(max(l.weight, 0), 1)
        guard w > 0 else { return 0 }
        let d = min(max(drive, 0), 1), f = min(max(settled, 0), 1)
        return w * ceiling(l.look, intensity: intensity) * (0.75 + 0.25 * d)
            * (transitionFloor + (1 - transitionFloor) * f)
    }

    /// How settled the current picture is: falls from 1 to 0 over the first 30 % of its crossfade (no step),
    /// then rises back to 1 over the 6 s after it.
    static func settled(imageAge: Float?, transitionDuration: Float, inTransition: Bool, progress: Float = 1) -> Float {
        func smooth(_ x: Float) -> Float { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }
        if inTransition { return 1 - smooth(progress / 0.3) }
        guard let age = imageAge else { return 1 }
        return smooth((age - transitionDuration) / 6)
    }

    /// Writes the video uniforms. `.off` (or zero mixes) leaves them all 0.
    static func apply(_ s: VideoCompositeState, to u: inout EffectsUniforms,
                      intensity: Float, drive: Float, settled: Float) {
        let ma = mix(s.a, constantMix: s.constantMix, intensity: intensity, drive: drive, settled: settled)
        let mb = mix(s.b, constantMix: s.constantMix, intensity: intensity, drive: drive, settled: settled)
        guard ma > 0.0005 || mb > 0.0005 else { return }
        if ma > 0.0005, let l = s.a {
            u.videoMix = ma
            u.videoLook = Float(l.look.rawValue)
            u.videoSeed = l.seed
            u.videoScale = scale(l.look)
            u.videoAspect = max(l.aspect, 0.1) / frameAspect
            u.videoWarp = min(max(l.warp, 0), 1)
        }
        if mb > 0.0005, let l = s.b {
            u.videoMixB = mb
            u.videoLookB = Float(l.look.rawValue)
            u.videoSeedB = l.seed
            u.videoScaleB = scale(l.look)
            u.videoAspectB = max(l.aspect, 0.1) / frameAspect
            u.videoWarpB = min(max(l.warp, 0), 1)
        }
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
