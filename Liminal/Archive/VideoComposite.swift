//
//  VideoComposite.swift
//  Liminal
//
//  Footage -> shader uniforms (docs/plans/archive-video.md 2.2). Pure: look ceilings, the mix formula
//  and the tint colours. `EffectsUniformsComputer.compute(video:)` calls `apply`; with `.off` every
//  video uniform stays 0 and the shader skips the stage.
//  Footage interaction modes (docs/plans/footage-fx.md, decisions F1-): a piece is a `FootageRecipe`, a
//  carrier look (how the film's tones become pixels), a key (where it may show) and a drive (which effect
//  the film steers), with the drive's amount from intensity, the clarity cycle and the fresh-image hold.
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
    /// The film gradient-mapped through the picture: shade -> the picture's own colour -> tint (recipes only).
    case palette = 5
    /// The film as halftone dots or an engraving line screen, inked against what it lands on (recipes only).
    case print = 6
    /// The picture posterised into flat bands whose thresholds the film's figure shifts (recipes only; round 2).
    case poster = 7

    var name: String { String(describing: self) }
    init?(name: String) {
        guard let l = Self.allCases.first(where: { $0.name == name.lowercased() }) else { return nil }
        self = l
    }
}

/// The effect a piece of film steers (shader ids FD_* in EffectsRenderer.metal; plan footage-fx.md 3).
nonisolated enum FootageDrive: Int, CaseIterable, Sendable {
    case none = 0
    /// The film's figure bends and shifts the picture's UVs and lights the pane (thick, moving glass).
    case undertow = 1
    /// The film drawn as a contour map (iso-lines of its figure, light on darks, ink on lights); its edges
    /// split the picture's colours.
    case fringe = 2
    /// The film's motion feeds the feedback trails and the ghost taps.
    case wake = 3
    /// The film's tones rotate the hue waves (luma untouched).
    case aurora = 4
    /// The film's highlights fold the picture's tone curve.
    case solar = 5
    /// The film embossed into the picture's surface.
    case relief = 6
    /// The film projected onto the picture as light and shade; its highlights swell the bloom.
    case glow = 7
    /// Geometric drives move the picture and are held off while a new picture settles (EffectLook.fresh).
    var isGeometric: Bool { self == .undertow || self == .fringe }
    /// The drives that move the picture's samples run in their own shader group (VARIANT_GLASS, decision F25).
    var isGlass: Bool { isGeometric }

    /// Drive amount at effect intensity 0 / 0.5 / 1 (tune): the shader's maxima are the amount 1.
    var ceilings: (Float, Float, Float) {
        switch self {
        case .none: return (0, 0, 0)
        case .undertow: return (0.30, 0.58, 0.85)
        case .fringe: return (0.40, 0.80, 1.0)
        case .wake: return (0.50, 0.90, 1.0)
        case .aurora: return (0.45, 0.80, 1.0)
        case .solar: return (0.0, 0.85, 1.0)
        case .relief: return (0.40, 0.85, 1.0)
        case .glow: return (0.50, 0.85, 1.0)
        }
    }
}

/// Where a piece of film may show (shader ids FK_*).
nonisolated enum FootageKey: Int, Sendable {
    /// The carrier look's own mask.
    case own = 0
    /// The picture's shadows (or highlights on a bright picture): a luminance key.
    case shadow = 1
    /// Far depth, behind the subject (only where a depth map is bound: visionOS).
    case backdrop = 2
    /// The film's own UVs folded into wedges (the picture is not folded).
    case kaleido = 3
}

/// Recipe families: the weaver never picks the same family twice in a row.
nonisolated enum FootageFamily: String, CaseIterable, Sendable {
    case plain, water, colour, keyed, light
}

/// One piece's way of weaving the film in (plan footage-fx.md 5): a curated carrier + key + drive.
nonisolated enum FootageRecipe: String, CaseIterable, Sendable, Codable {
    // Today's four blend looks.
    case phantom, imprint, window, emerge
    // Water: the film moves the picture.
    case undertow, wake
    // Colour: the film steers the picture's colours.
    case fringe, aurora, solar, poster
    // Keyed: the film shows only in part of the picture.
    case shadowplay, backdrop, kaleido
    // Light: the film lights, shades or inks the picture.
    case relief, glow, print

    var name: String { rawValue }
    init?(name: String) {
        let n = name.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        guard let r = Self.allCases.first(where: { $0.rawValue == n }) else { return nil }
        self = r
    }

    /// The plain recipe of a blend look (-LiminalVideoLook).
    static func plain(_ look: VideoLook) -> FootageRecipe {
        switch look {
        case .phantom: return .phantom
        case .imprint: return .imprint
        case .window: return .window
        case .emerge: return .emerge
        case .palette: return .shadowplay
        case .print: return .print
        case .poster: return .poster
        }
    }

    /// The blend that carries the film's tones (nil: none, the film is only felt through its drive).
    var carrier: VideoLook? {
        switch self {
        case .phantom, .wake, .fringe, .glow: return .phantom
        case .imprint, .undertow, .aurora, .relief: return .imprint
        case .window, .backdrop: return .window
        case .emerge: return .emerge
        case .shadowplay, .kaleido: return .palette
        case .print: return .print
        case .poster: return .poster
        case .solar: return nil
        }
    }

    /// Share of the carrier's usual mix: a drive makes the film felt, so its carrier runs lower; a key
    /// shrinks the film's area, so its carrier runs higher.
    var carrierShare: Float {
        switch self {
        // Round 1 (decision F21): every mode's film share raised; round 0's judges could not find the film.
        // Round 2 (F24): Poster, Kaleido, Shadowplay, Backdrop and Wake up again; Glow and Undertow down (their drives now carry
        // the film's figure as light and glass).
        case .phantom, .imprint, .window, .emerge: return 1
        case .poster: return 2.6
        case .print: return 1.5
        case .undertow: return 0.45
        case .wake: return 1.0
        case .fringe: return 0.5
        case .aurora: return 0.45
        case .relief: return 0.5
        case .glow: return 0.4
        case .kaleido: return 2.2
        case .shadowplay: return 2.2
        case .backdrop: return 1.9
        case .solar: return 0
        }
    }

    var key: FootageKey {
        switch self {
        case .shadowplay: return .shadow
        case .backdrop: return .backdrop
        case .kaleido: return .kaleido
        default: return .own
        }
    }

    var drive: FootageDrive {
        switch self {
        case .undertow: return .undertow
        case .wake: return .wake
        case .fringe: return .fringe
        case .aurora: return .aurora
        case .solar: return .solar
        case .relief: return .relief
        case .glow: return .glow
        default: return .none
        }
    }

    var family: FootageFamily {
        switch self {
        case .phantom, .imprint, .window, .emerge: return .plain
        case .undertow, .wake: return .water
        case .fringe, .aurora, .solar, .poster: return .colour
        case .shadowplay, .backdrop, .kaleido: return .keyed
        case .relief, .glow, .print: return .light
        }
    }

    /// Choice weight (tune): the quiet recipes are favoured.
    var weight: Float {
        switch self {
        case .phantom, .window: return 3
        case .imprint: return 2
        case .emerge, .solar, .print: return 1
        case .undertow, .wake, .fringe, .aurora, .shadowplay, .backdrop, .glow: return 3
        case .poster, .kaleido, .relief: return 2
        }
    }

    /// Lowest effect intensity the recipe is picked at.
    var minIntensity: Float {
        switch self {
        case .emerge, .print: return 0.4
        case .solar: return 0.35
        case .kaleido: return 0.25
        case .undertow: return 0.2
        default: return 0
        }
    }

    /// Shader hook group (VARIANT_* in EffectsRenderer.metal): 1 the blend looks, 3 keys / new carriers,
    /// 5 drives. The weaver never crossfades a 3 into a 5 (or back): that frame would need the full variant
    /// (decision F11).
    var shaderGroup: Int {
        if carrier != nil && carrier!.rawValue <= 4 && key == .own && drive == .none { return 1 }
        if drive.isGlass { return 9 }
        return drive != .none || carrier == nil ? 5 : 3
    }

    /// Every shader variant the app builds (footageVariant values other than 0 and 1).
    static let fxVariants = [3, 5, 7, 9, 11, 13, 15]

    /// Only where a depth map exists (visionOS).
    var needsDepth: Bool { self == .backdrop }

    /// The most stylised recipes take the frame or change its tones: their pieces are capped and never swell.
    static let cappedLength: Double = 16
    var maxLength: Double? {
        switch self {
        case .emerge, .solar, .print: return Self.cappedLength
        default: return nil
        }
    }
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
    /// The piece's interaction mode (nil: the plain recipe of `look`).
    var recipe: FootageRecipe? = nil
    /// envelope x calm x swell factor (no level): scales the drive (nil: from `weight`).
    var envelope: Float? = nil

    var resolvedRecipe: FootageRecipe { recipe ?? .plain(look) }
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
    /// Shadowplay key polarity, -1 (the picture's highlights) ... 1 (its shadows), eased by the service as the
    /// picture changes (continuous in the shader, so a new picture never flips the key).
    var keyPolarity: Float = 1
    /// Share of the picture inside the Shadowplay key (16 x 16 thumbnail): on a picture that is mostly
    /// shadow the key covers nearly the frame, so its mix is scaled down (`keyGain`).
    var keyCoverage: Float = 0.35

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
        case .palette: return (0.45, 0.70, 0.85)
        case .print: return (0.00, 0.75, 0.90)
        case .poster: return (0.40, 0.70, 0.85)
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
        case .palette: return 0.95
        case .print: return 1.0
        case .poster: return 1.0
        }
    }

    /// Share of the mix kept while a new picture arrives (`settled` 0): the footage dips, never vanishes.
    static let transitionFloor: Float = 0.6

    /// videoMix of one layer = weight x ceiling(intensity) x (0.75 + 0.25 drive) x (0.6 + 0.4 settled).
    /// `drive` is the clarity cycle (EffectLook.drive): the footage is a little clearer in wild stretches.
    /// `settled` is 0 while a new image arrives and 1 once it has been on screen a while: a new
    /// picture pulls the footage back while it is fresh.
    /// A recipe's carrier runs at `carrierShare` of that; a carrier-less recipe uses the Window ceiling as its
    /// presence (the shader's layer gate; its look is VIDEO_NONE, so nothing is blended).
    static func mix(_ l: VideoLayer?, constantMix: Float? = nil, intensity: Float, drive: Float, settled: Float) -> Float {
        guard let l else { return 0 }
        let r = l.resolvedRecipe
        let share = r.carrier == nil ? 1 : r.carrierShare
        if let m = constantMix { return min(max(m * share, 0), 1) }
        let w = min(max(l.weight, 0), 1)
        guard w > 0 else { return 0 }
        let d = min(max(drive, 0), 1), f = min(max(settled, 0), 1)
        return min(w * ceiling(r.carrier ?? .window, intensity: intensity) * share * (0.75 + 0.25 * d)
            * (transitionFloor + (1 - transitionFloor) * f), 0.95)
    }

    /// videoDriveAmt of one layer (plan footage-fx.md 4) = envelope x ceiling(drive, intensity)
    /// x (0.6 + 0.4 drive) x hold. Geometric drives hold with the fresh-image hold (a new picture is not
    /// bent); the others dip with the mix's settled term.
    static func driveAmount(_ l: VideoLayer?, constant: Bool = false, intensity: Float, drive: Float,
                            settled: Float, fresh: Float) -> Float {
        guard let l else { return 0 }
        let dr = l.resolvedRecipe.drive
        guard dr != .none else { return 0 }
        let env = constant ? 1 : min(max(l.envelope ?? min(l.weight / 0.5, 1), 0), 1)
        let d = min(max(drive, 0), 1), f = min(max(settled, 0), 1), h = min(max(fresh, 0), 1)
        let hold = dr.isGeometric ? h : transitionFloor + (1 - transitionFloor) * f
        return min(env * EffectLook.tri(min(max(intensity, 0), 1), dr.ceilings) * (0.6 + 0.4 * d) * hold, 1)
    }

    /// videoKeyAmt: Shadowplay's polarity, Kaleido's fold (sign = wedge count by seed, size = strength).
    static func keyAmount(_ l: VideoLayer, intensity: Float, polarity: Float) -> Float {
        switch l.resolvedRecipe.key {
        case .own: return 0
        case .shadow: return min(max(polarity, -1), 1)
        case .backdrop: return 1
        case .kaleido: return (l.seed < 0.5 ? 1 : -1) * (0.85 + 0.15 * min(max(intensity, 0), 1))
        }
    }

    /// How settled the current picture is: falls from 1 to 0 over the first 30 % of its crossfade (no step),
    /// then rises back to 1 over the 6 s after it.
    static func settled(imageAge: Float?, transitionDuration: Float, inTransition: Bool, progress: Float = 1) -> Float {
        func smooth(_ x: Float) -> Float { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }
        if inTransition { return 1 - smooth(progress / 0.3) }
        guard let age = imageAge else { return 1 }
        return smooth((age - transitionDuration) / 6)
    }

    /// Footage shader variant a frame needs (decision F11; VARIANT_* in EffectsRenderer.metal): 1 the blend
    /// looks (effectsFragment*Video), | 2 keys / Kaleido / Palette / Print (*VideoKeys), | 4 drives or a
    /// carrier-less layer (*VideoDrives); 7 = both (*VideoFX). 0 = no footage layer is drawn. Each hook group
    /// costs registers every frame of its variant pays for, so a frame binds only the groups it shows.
    static func footageVariant(_ u: EffectsUniforms) -> Int {
        func bits(_ mix: Float, _ look: Float, _ drive: Float, _ key: Float) -> Int {
            guard mix > 0 else { return 0 }
            var v = 1
            if key != 0 || look > 4.5 { v |= 2 }
            if FootageDrive(rawValue: Int(drive + 0.5))?.isGlass == true { v |= 8 }
            else if drive != 0 || look < 0.5 { v |= 4 }
            return v
        }
        return bits(u.videoMix, u.videoLook, u.videoDrive, u.videoKey) | bits(u.videoMixB, u.videoLookB, u.videoDriveB, u.videoKeyB)
    }

    /// Fragment function name suffix of a footage variant ("" for 0).
    static func variantSuffix(_ v: Int) -> String {
        switch v {
        case 0: return ""
        case 1: return "Video"
        case 3: return "VideoKeys"
        case 5: return "VideoDrives"
        case 7: return "VideoFX"
        case 9: return "VideoGlass"
        case 11: return "VideoKeysGlass"
        case 13: return "VideoDrivesGlass"
        default: return "VideoFXGlass"
        }
    }

    /// Writes the video uniforms. `.off` (or zero mixes) leaves them all 0.
    /// `fresh` is the fresh-image hold (EffectLook.fresh): 0 while a new picture settles.
    static func apply(_ s: VideoCompositeState, to u: inout EffectsUniforms,
                      intensity: Float, drive: Float, settled: Float, fresh: Float = 1) {
        let gain = keyGain(coverage: s.keyCoverage)
        func keyed(_ l: VideoLayer?, _ m: Float) -> Float { l?.resolvedRecipe.key == .shadow ? m * gain : m }
        let ma = keyed(s.a, mix(s.a, constantMix: s.constantMix, intensity: intensity, drive: drive, settled: settled))
        let mb = keyed(s.b, mix(s.b, constantMix: s.constantMix, intensity: intensity, drive: drive, settled: settled))
        guard ma > 0.0005 || mb > 0.0005 else { return }
        func amt(_ l: VideoLayer?) -> Float {
            driveAmount(l, constant: s.constantMix != nil, intensity: intensity, drive: drive, settled: settled, fresh: fresh)
        }
        if ma > 0.0005, let l = s.a {
            let r = l.resolvedRecipe
            u.videoMix = ma
            u.videoLook = Float(r.carrier?.rawValue ?? 0)
            u.videoSeed = l.seed
            u.videoScale = scale(r.carrier ?? .window)
            u.videoAspect = max(l.aspect, 0.1) / frameAspect
            u.videoWarp = min(max(l.warp, 0), 1)
            u.videoDrive = Float(r.drive.rawValue)
            u.videoDriveAmt = amt(l)
            u.videoKey = Float(r.key.rawValue)
            u.videoKeyAmt = keyAmount(l, intensity: intensity, polarity: s.keyPolarity)
        }
        if mb > 0.0005, let l = s.b {
            let r = l.resolvedRecipe
            u.videoMixB = mb
            u.videoLookB = Float(r.carrier?.rawValue ?? 0)
            u.videoSeedB = l.seed
            u.videoScaleB = scale(r.carrier ?? .window)
            u.videoAspectB = max(l.aspect, 0.1) / frameAspect
            u.videoWarpB = min(max(l.warp, 0), 1)
            u.videoDriveB = Float(r.drive.rawValue)
            u.videoDriveAmtB = amt(l)
            u.videoKeyB = Float(r.key.rawValue)
            u.videoKeyAmtB = keyAmount(l, intensity: intensity, polarity: s.keyPolarity)
        }
        u.videoTintR = s.tint.x; u.videoTintG = s.tint.y; u.videoTintB = s.tint.z
        u.videoShadeR = s.shade.x; u.videoShadeG = s.shade.y; u.videoShadeB = s.shade.z
    }

    // MARK: - Tint

    /// Highlight / shadow colours from a picture: mean of its brightest and darkest fifth (16 x 16
    /// thumbnail), the highlight lifted toward a bright, saturated version of its hue and the shadow
    /// pressed toward black, so the black-and-white footage takes the picture's palette.
    static func tint(of image: CGImage) -> (tint: SIMD3<Float>, shade: SIMD3<Float>) {
        let s = stats(of: image)
        return (s.tint, s.shade)
    }

    /// Share of the thumbnail darker than `shadowLuma`: at least `shadowMinShare` keys Shadowplay to the
    /// picture's shadows, else (a bright picture with no dark ground) to its highlights.
    static let shadowLuma: Float = 0.3
    static let shadowMinShare: Float = 0.18

    static func polarity(shadowShare: Float) -> Float { shadowShare >= shadowMinShare ? 1 : -1 }

    /// Shadowplay's mix factor for a key covering `coverage` of the picture: full up to 35 %, then falling so
    /// the film's area stays about the same, never under 0.4 (decision F18).
    static func keyGain(coverage: Float) -> Float { min(max(0.35 / max(coverage, 0.01), 0.4), 1) }

    /// Tint, shade and the Shadowplay key polarity of a picture (one 16 x 16 thumbnail).
    static func stats(of image: CGImage) -> (tint: SIMD3<Float>, shade: SIMD3<Float>, polarity: Float, coverage: Float) {
        let n = 16
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return (SIMD3(1, 1, 1), SIMD3(0, 0, 0), 1, 0.35)
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
        let total = Float(max(cols.count, 1))
        let share = Float(cols.filter { $0.l < shadowLuma }.count) / total
        let pol = polarity(shadowShare: share)
        let coverage = pol > 0 ? share : Float(cols.filter { $0.l > 0.6 }.count) / total
        return (tint: brighten(light), shade: darken(dark), polarity: pol, coverage: coverage)
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
