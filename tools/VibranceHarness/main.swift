//
//  main.swift — VibranceHarness
//
//  Offline renderer for measuring color loss in Liminal's effect pipeline.
//  Compiled together with the app's real EffectsUniforms.swift, EffectsUniformsComputer.swift,
//  SmoothOscillator.swift and GhostTapManager.swift, and run against the real compiled
//  EffectsRenderer metallib, so uniforms and shader are exactly what the app uses.
//
//  Usage (see scripts/vibrance-eval.sh):
//    vibrance-harness --metallib <path> --in <dir> --out <dir> [--mode visionos|macos]
//                     [--size 512] [--times 0,37,113,260,611] [--no-solo]
//
//  Modes:
//    visionos — mirrors OffscreenEffectsRenderer: bgra8Unorm source, render target is a
//               bgra8Unorm VIEW of a bgra8Unorm_srgb texture (the DrawableQueue format), so the
//               stored bytes are the shader's values (no second sRGB encode). Feedback reads the
//               previous frame's output view (as the renderer does with its last drawable).
//    macos    — mirrors EffectsMetalView: bgra8Unorm target, real feedback ping-pong.
//  Both modes run warm-up frames at 60fps leading into each time t, and apply the app's
//  per-image vibrance factors (ImageColorStats, measured on the cropped source).
//
//  Output per image <name>:
//    <out>/<mode>/<name>/input.png                 square-resampled input (baseline)
//    <out>/<mode>/<name>/passthrough.png           passthroughFragment into the mode's target format
//    <out>/<mode>/<name>/t<T>_full.png             full pipeline
//    <out>/<mode>/<name>/t<T>_ko_<stage>.png       full pipeline with <stage> neutralized
//    <out>/<mode>/<name>/t<T>_solo_<stage>.png     only <stage> enabled (others neutral)
//

import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Args

var metallibPath = ""
var inDir = ""
var outDir = ""
var mode = "visionos"
var size = 512
var times: [Float] = [0, 37, 113, 260, 611]
var doSolo = true
var warmupFrames = 30
let delay: Float = 0.5  // SettingsService.defaultDelay

do {
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--metallib": metallibPath = args.removeFirst()
        case "--in": inDir = args.removeFirst()
        case "--out": outDir = args.removeFirst()
        case "--mode": mode = args.removeFirst()
        case "--size": size = Int(args.removeFirst())!
        case "--times": times = args.removeFirst().split(separator: ",").map { Float($0)! }
        case "--warmup": warmupFrames = Int(args.removeFirst())!
        case "--no-solo": doSolo = false
        default: fatalError("unknown arg \(a)")
        }
    }
    guard !metallibPath.isEmpty, !inDir.isEmpty, !outDir.isEmpty,
          mode == "visionos" || mode == "macos" else {
        fatalError("usage: --metallib <path> --in <dir> --out <dir> [--mode visionos|macos]")
    }
}

// MARK: - Metal setup

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let library = try! device.makeLibrary(URL: URL(fileURLWithPath: metallibPath))
// Pipelines always render bgra8Unorm (visionOS: into a view of an _srgb texture).
let targetFormat: MTLPixelFormat = .bgra8Unorm
/// Render target as the mode's renderer allocates it, plus the bgra8Unorm texture passes write/read.
func makeTarget() -> (storage: MTLTexture, view: MTLTexture) {
    if mode == "visionos" {
        let t = makeTexture(.bgra8Unorm_srgb, size, size, usage: [.renderTarget, .shaderRead])
        return (t, t.makeTextureView(pixelFormat: .bgra8Unorm)!)
    }
    let t = makeTexture(.bgra8Unorm, size, size, usage: [.renderTarget, .shaderRead])
    return (t, t)
}

func makePipeline(_ fragment: String) -> MTLRenderPipelineState {
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = library.makeFunction(name: "effectsVertex")!
    d.fragmentFunction = library.makeFunction(name: fragment)!
    d.colorAttachments[0].pixelFormat = targetFormat
    return try! device.makeRenderPipelineState(descriptor: d)
}
let effectsPipeline = makePipeline("effectsFragment")
let passthroughPipeline = makePipeline("passthroughFragment")

func makeTexture(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, usage: MTLTextureUsage) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
    d.usage = usage
    d.storageMode = .shared
    return device.makeTexture(descriptor: d)!
}

func fill1x1(_ fmt: MTLPixelFormat, bytes: [UInt8]) -> MTLTexture {
    let t = makeTexture(fmt, 1, 1, usage: .shaderRead)
    var b = bytes
    t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &b, bytesPerRow: bytes.count)
    return t
}

// Same defaults as OffscreenEffectsRenderer: 1x1 gray saliency (0.5).
let saliencyTex = fill1x1(.r8Unorm, bytes: [128])
// Flat mid depth (DepthAnything map unavailable offline).
let depthTex = fill1x1(.r8Unorm, bytes: [128])
// visionOS never binds index 4; unbound textures read as zero on Apple GPUs.
let blackTex = fill1x1(.bgra8Unorm, bytes: [0, 0, 0, 255])

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let bgraInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

/// Upload exactly like OffscreenEffectsRenderer.updateSourceTexture: 3:2 cover-crop (as the dome
/// view does before upload), sRGB CGContext, BGRA, NOT flipped (bitmap memory is top row first =
/// Metal row 0 = image top). Also returns the app's vibrance factors for the image. Output PNGs are therefore upright (square, i.e. the 3:2 frame
/// squeezed horizontally exactly as stored in the 2048² texture).
func loadSource(_ url: URL) -> (MTLTexture, VibranceFactors) {
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let img = ImageFraming.coverCrop(CGImageSourceCreateImageAtIndex(src, 0, nil)!)
    let factors = ImageColorStats.factors(for: img)
    let bpr = size * 4
    var buf = [UInt8](repeating: 0, count: bpr * size)
    let ctx = CGContext(data: &buf, width: size, height: size, bitsPerComponent: 8, bytesPerRow: bpr,
                        space: srgb, bitmapInfo: bgraInfo)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
    let t = makeTexture(.bgra8Unorm, size, size, usage: .shaderRead)
    t.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: buf, bytesPerRow: bpr)
    return (t, factors)
}

func writePNG(_ tex: MTLTexture, _ path: String) {
    let bpr = tex.width * 4
    var buf = [UInt8](repeating: 0, count: bpr * tex.height)
    tex.getBytes(&buf, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0)
    // Raw stored bytes are interpreted as sRGB — what the display ultimately shows.
    let ctx = CGContext(data: &buf, width: tex.width, height: tex.height, bitsPerComponent: 8,
                        bytesPerRow: bpr, space: srgb, bitmapInfo: bgraInfo)!
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - Render

func encodeDraw(_ cb: MTLCommandBuffer, pipeline: MTLRenderPipelineState, target: MTLTexture,
                source: MTLTexture, feedback: MTLTexture, uniforms: EffectsUniforms, taps: [GhostTapData]) {
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = target
    rp.colorAttachments[0].loadAction = .clear
    rp.colorAttachments[0].storeAction = .store
    rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
    enc.setRenderPipelineState(pipeline)
    var u = uniforms
    enc.setFragmentBytes(&u, length: MemoryLayout<EffectsUniforms>.size, index: 0)
    var t = taps
    while t.count < GhostTapManager.maxTaps { t.append(.inactive) }
    enc.setFragmentBytes(&t, length: MemoryLayout<GhostTapData>.stride * GhostTapManager.maxTaps, index: 1)
    enc.setFragmentTexture(source, index: 0)
    enc.setFragmentTexture(saliencyTex, index: 2)
    enc.setFragmentTexture(source, index: 3)  // previous == source when not transitioning
    enc.setFragmentTexture(feedback, index: 4)
    enc.setFragmentTexture(depthTex, index: 5)
    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    enc.endEncoding()
}

/// Ghost tap state at time t: step the real GhostTapManager through the preceding 40s.
func ghostTaps(at t: Float) -> [GhostTapData] {
    let m = GhostTapManager()
    var time = max(0, t - 40)
    var last = m.updateWithCount(currentTime: time, delay: delay)
    while time < t {
        time = min(t, time + 0.25)
        last = m.updateWithCount(currentTime: time, delay: delay)
    }
    return Array(last.data.prefix(last.activeCount))
}

typealias Mutator = (inout EffectsUniforms, inout [GhostTapData]) -> Void

/// Neutralize each stage via its uniform amount.
let stages: [(String, Mutator)] = [
    ("kenburns", { u, _ in u.kenBurnsScale = 1; u.kenBurnsOffsetX = 0; u.kenBurnsOffsetY = 0 }),
    ("turbulence", { u, _ in u.distortionAmplitude = 0 }),
    ("logsphere", { u, _ in u.logSphereAmount = 0 }),
    ("fractalnoise", { u, _ in u.fractalNoiseAmount = 0 }),
    ("chromatic", { u, _ in u.chromaticAmount = 0 }),
    ("hueshift", { u, _ in u.hueWaveIntensity = 0; u.hueBaseShift = 0 }),      // spatial hue waves only
    ("contrastsat", { u, _ in u.contrastBoost = 1; u.saturationBoost = 1 }),    // explicit contrast/sat boosts
    ("colorblock", { u, _ in u.hueBlendAmount = 0 }),                           // whole hue/HSV-sat/contrast/sat block
    ("fractalhue", { u, _ in u.fractalHueAmount = 0 }),
    ("ghosttaps", { u, g in u.ghostTapCount = 0; g = [] }),
    ("bloom", { u, _ in u.bloomAmount = 0 }),
    ("feedback", { u, _ in u.feedbackMix = 0 }),
    ("vibrance", { u, _ in u.vibranceAmount = 0; u.blackPoint = 0 }),
]

func allOff(_ u: inout EffectsUniforms, _ g: inout [GhostTapData]) {
    for (_, m) in stages { m(&u, &g) }
}

/// Render one variant at time t. In macOS mode, runs `warmupFrames` frames of feedback leading into t.
func render(source: MTLTexture, vibrance: VibranceFactors, t: Float, mutate: Mutator, path: String) {
    let target = makeTarget()
    let baseTaps = ghostTaps(at: t)
    func uniformsAt(_ time: Float) -> (EffectsUniforms, [GhostTapData]) {
        var u = EffectsUniformsComputer.compute(time: time, transitionProgress: 0, hasSaliencyMap: false,
                                                ghostTapCount: baseTaps.count, vibrance: vibrance)
        var g = baseTaps
        mutate(&u, &g)
        u.ghostTapCount = Float(g.count)
        return (u, g)
    }
    let cb = queue.makeCommandBuffer()!
    let (u, g) = uniformsAt(t)
    if u.feedbackMix > 0.001 {
        let fbA = makeTarget().view
        let fbB = makeTarget().view
        // Feedback starts from black (macOS zero-inits; visionOS skips feedback on its first frame,
        // which converges to the same state within the warm-up).
        var read = blackTex
        var write = fbA
        let dt: Float = 1.0 / 60.0
        for i in stride(from: warmupFrames, to: 0, by: -1) {
            let (ui, gi) = uniformsAt(t - Float(i) * dt)
            encodeDraw(cb, pipeline: effectsPipeline, target: write, source: source, feedback: read, uniforms: ui, taps: gi)
            read = write
            write = (write === fbA) ? fbB : fbA
        }
        encodeDraw(cb, pipeline: effectsPipeline, target: target.view, source: source, feedback: read, uniforms: u, taps: g)
    } else {
        encodeDraw(cb, pipeline: effectsPipeline, target: target.view, source: source, feedback: blackTex, uniforms: u, taps: g)
    }
    cb.commit()
    cb.waitUntilCompleted()
    writePNG(target.storage, path)
}

/// passthroughFragment into a plain bgra8Unorm texture (asTarget false: the input reference) or
/// into the mode's real render target (asTarget true).
func renderPassthrough(source: MTLTexture, path: String, asTarget: Bool) {
    let target = asTarget ? makeTarget() : {
        let t = makeTexture(.bgra8Unorm, size, size, usage: [.renderTarget, .shaderRead]); return (t, t)
    }()
    let cb = queue.makeCommandBuffer()!
    let u = EffectsUniformsComputer.compute(time: 0)
    encodeDraw(cb, pipeline: passthroughPipeline, target: target.view, source: source, feedback: blackTex, uniforms: u, taps: [])
    cb.commit()
    cb.waitUntilCompleted()
    writePNG(target.storage, path)
}

// MARK: - Main

let fm = FileManager.default
let inputs = try! fm.contentsOfDirectory(atPath: inDir)
    .filter { ["jpg", "jpeg", "png"].contains(($0 as NSString).pathExtension.lowercased()) }
    .filter { !$0.hasPrefix("contact") }
    .sorted()

let start = Date()
for file in inputs {
    let name = (file as NSString).deletingPathExtension
    let dir = "\(outDir)/\(mode)/\(name)"
    try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let (source, vibrance) = loadSource(URL(fileURLWithPath: "\(inDir)/\(file)"))
    renderPassthrough(source: source, path: "\(dir)/input.png", asTarget: false)
    renderPassthrough(source: source, path: "\(dir)/passthrough.png", asTarget: true)
    for t in times {
        let tag = "t\(Int(t))"
        render(source: source, vibrance: vibrance, t: t, mutate: { _, _ in }, path: "\(dir)/\(tag)_full.png")
        render(source: source, vibrance: vibrance, t: t, mutate: { u, g in allOff(&u, &g) }, path: "\(dir)/\(tag)_none.png")
        for (stage, neutralize) in stages {
            render(source: source, vibrance: vibrance, t: t, mutate: neutralize, path: "\(dir)/\(tag)_ko_\(stage).png")
            if doSolo && stage != "colorblock" {
                // Solo: everything off, then restore this stage's real values.
                render(source: source, vibrance: vibrance, t: t, mutate: { u, g in
                    let real = u
                    let realTaps = g
                    allOff(&u, &g)
                    switch stage {
                    case "kenburns": u.kenBurnsScale = real.kenBurnsScale; u.kenBurnsOffsetX = real.kenBurnsOffsetX; u.kenBurnsOffsetY = real.kenBurnsOffsetY
                    case "turbulence": u.distortionAmplitude = real.distortionAmplitude
                    case "logsphere": u.logSphereAmount = real.logSphereAmount
                    case "fractalnoise": u.fractalNoiseAmount = real.fractalNoiseAmount
                    case "chromatic": u.chromaticAmount = real.chromaticAmount
                    case "hueshift":  // hue waves need the block mix on, but with neutral contrast/sat
                        u.hueBlendAmount = real.hueBlendAmount; u.hueWaveIntensity = real.hueWaveIntensity
                    case "contrastsat":
                        u.hueBlendAmount = real.hueBlendAmount; u.contrastBoost = real.contrastBoost; u.saturationBoost = real.saturationBoost
                    case "fractalhue": u.fractalHueAmount = real.fractalHueAmount
                    case "ghosttaps": g = realTaps
                    case "bloom": u.bloomAmount = real.bloomAmount
                    case "feedback": u.feedbackMix = real.feedbackMix; u.feedbackWarpAmount = real.feedbackWarpAmount
                    case "vibrance": u.vibranceAmount = real.vibranceAmount; u.blackPoint = real.blackPoint
                    default: break
                    }
                }, path: "\(dir)/\(tag)_solo_\(stage).png")
            }
        }
    }
    print(String(format: "[%@] %@ done (%.1fs)", mode, name, Date().timeIntervalSince(start)))
}
