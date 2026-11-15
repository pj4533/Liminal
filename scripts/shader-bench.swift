// shader-bench.swift — deterministic offline Mac-GPU benchmark of Liminal's visionOS eye pass.
//
// Why: in the visionOS simulator the eye pass reads ~0.15 ms/frame of GPU time, dominated by
// noise and by a random source image per run, so ALU-level shader changes cannot be evaluated
// there. This tool renders the REAL eye pass on the Mac GPU at full cost with fixed inputs.
//
// Compiled together with the app's own EffectsUniforms.swift, EffectsUniformsComputer.swift,
// SmoothOscillator.swift, GhostTapManager.swift, ImageFraming.swift, ImageColorStats.swift and
// DepthMapGenerator.swift (see scripts/shader-bench.sh), so uniforms, ghost taps, framing and
// vibrance factors are exactly what the app computes. The shader is a metallib compiled from the
// working-tree (or a candidate) EffectsRenderer.metal.
//
// What one frame is (mirrors OffscreenEffectsRenderer.renderStereoAndPresent -> renderBothEyes):
//   - ONE command buffer, ONE render pass, effectsFragmentStereo writing both eyes (MRT):
//     color(0) = left, color(1) = right, each a bgra8Unorm VIEW of a 2048² bgra8Unorm_srgb
//     texture (the DrawableQueue format; docs/decisions/vibrance.md V1), loadAction .dontCare.
//   - Bindings: uniforms bytes @ buffer 0 (stereoOffset = |offset|), ghost taps @ buffer 1,
//     source @ tex 0, 1x1 r8 saliency (0.5) @ tex 2, previous @ tex 3 (source when not
//     transitioning), left feedback @ tex 4, right feedback @ tex 6 (each eye's previous output,
//     3 drawables per eye rotating like a DrawableQueue), depth @ tex 5, linear/clamp sampler.
//   - Source upload as updateSourceTexture: ImageFraming.coverCrop to 3:2, sRGB CGContext, BGRA,
//     unflipped, stretched to 2048². Depth as updateDepthTexture: r8 at its native size.
//   - Uniforms: EffectsUniformsComputer.compute(time:, transitionProgress:, hasSaliencyMap: false,
//     vibrance: ImageColorStats.factors(framed image)); ghostTapCount from the real GhostTapManager
//     stepped up to t (delay 0.5); stereoOffset = 0.003 + 0.007 * SmoothOscillator.value(at: t).
//   --mono renders the per-eye fallback instead (two effectsFragment passes per frame).
//
// Scenarios: one per fixed time (--times, default 37,113,260,611) plus "trans113" (t=113,
// transitionProgress 0.5, previous = mirrored source). Frames cycle through the scenarios so any
// host drift hits all of them equally.
//
// Timing: --warmup untimed frames, then --trials trials of --frames frames. Every frame is its own
// command buffer; at most --inflight are in flight (default 1: commit, wait, so each command
// buffer's gpuEndTime - gpuStartTime is exactly that frame's GPU time with no overlap).
// Reported: per-frame GPU ms median, p10, p90 for each trial and over all trials, per-scenario
// medians, and the trial-to-trial spread of the medians.
//
// Ghost tap directions: GhostTapManager adds Float.random(±0.15 rad) per tap; the bench rebuilds
// each direction from its spawn time with zero variance so the output is bit-reproducible.
//
// Parity: --out DIR writes <scenario>-L.png / -R.png (B variant: DIR/b/). Each is rendered from a fresh, deterministic
// state: first frame without feedback (as the app's first frame), then --png-frames frames at the
// frozen time so the feedback trails converge. --compare A B reports per file PSNR (dB),
// max-abs-diff and mean-abs-diff over RGB, and the worst over all files.
//
// Options
//   --metallib PATH    compiled shader library (required; the wrapper builds it)
//   --metallib-b PATH  interleaved A/B: a second library; frames alternate A,B,A,B (order flips
//                      every trial) in the same process, and the JSON adds "b" plus B/A ratios.
//                      This cancels host drift; prefer it for any candidate-vs-reference decision.
//   --image PATH       source image (required; the wrapper passes the fixture)
//   --depth PATH       depth map PNG (grayscale; omit for a flat 0.5 map)
//   --times a,b,...    fixed effect times (default 37,113,260,611)
//   --no-transition    skip the trans113 scenario
//   --frames N         timed frames per trial (default 300)
//   --trials N         trials (default 5)
//   --warmup N         untimed warm-up frames (default 60)
//   --inflight N       command buffers in flight (default 1)
//   --mono             per-eye fallback path (2 passes / frame) instead of the MRT pass
//   --out DIR          write PNGs for parity
//   --png-frames N     frames rendered before each PNG (default 30)
//   --json PATH        also write the JSON summary to PATH
//   --label TEXT       free text recorded in the JSON
//   --compare A B      no GPU timing: compare same-named PNGs in dirs A and B
//   --set k=v,k=v      override uniforms after EffectsUniformsComputer.compute, in every scenario
//                      (field names of EffectsUniforms, e.g. logSphereAmount=0,feedbackMix=0).
//                      Effect attribution: switch one effect off, or all but one.
//   --scenarios FILE   replace --times / trans113 by a JSON list of scenarios:
//                      [{"name": "a", "time": 37, "tp": 0, "set": {"logSphereAmount": 0}}, ...]
//                      ("tp" = transitionProgress, "set" = per-scenario overrides applied after --set;
//                      optional "intensity" and "age" per scenario, as --intensity / --image-age).
//   --intensity X      Effect-intensity setting 0...1 passed to compute() (docs/plans/effects-balance.md)
//   --image-age S      seconds since the current image's crossfade began, passed to compute()
//   --render-only      no GPU timing: write the PNGs (--out) and a JSON with each scenario's uniforms
//   --png-size WxH     scale the PNGs (e.g. 768x512 = the 3:2 picture as displayed; default 2048x2048)
//   --left-only        write only the left eye
//   --gen-depth IMAGE OUT.png   run the app's DepthMapGenerator (DepthAnythingV2SmallF16.mlmodelc
//                      must sit next to the binary; the wrapper arranges it) and save the map
//
// Output: one JSON object on stdout. Progress goes to stderr.

import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Helpers

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("error: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

func log(_ msg: String) {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
}

func jsonString(_ obj: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    return String(data: data, encoding: .utf8)!
}

func r4(_ x: Double) -> Double { (x * 10000).rounded() / 10000 }
func r2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

func median(_ xs: [Double]) -> Double { quantile(xs, 0.5) }

/// Linear-interpolated quantile.
func quantile(_ xs: [Double], _ q: Double) -> Double {
    let s = xs.sorted()
    guard !s.isEmpty else { return .nan }
    let pos = q * Double(s.count - 1)
    let lo = Int(pos.rounded(.down)), hi = min(lo + 1, s.count - 1)
    return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
}

func sha256Prefix(_ path: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    p.arguments = ["-a", "256", path]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String((String(data: data, encoding: .utf8) ?? "").prefix(12))
}

// MARK: - Arguments

var args = Array(CommandLine.arguments.dropFirst())
func takeValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag) else { return nil }
    guard i + 1 < args.count else { fail("\(flag) needs a value") }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
func takeFlag(_ flag: String) -> Bool {
    guard let i = args.firstIndex(of: flag) else { return false }
    args.remove(at: i)
    return true
}

// MARK: - Image IO

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let bgraInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

func loadCGImage(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("cannot read image \(path)") }
    return img
}

func writePNG(_ img: CGImage, _ path: String) {
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil) else {
        fail("could not write \(path)")
    }
    CGImageDestinationAddImage(dest, img, nil)
    if !CGImageDestinationFinalize(dest) { fail("could not finalize \(path)") }
}

/// RGBA8 pixels of a PNG (for --compare).
func loadRGBA(_ path: String) -> (w: Int, h: Int, px: [UInt8]) {
    let img = loadCGImage(path)
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, px)
}

// MARK: - Compare mode

if let i = args.firstIndex(of: "--compare") {
    guard i + 2 < args.count else { fail("--compare needs two directories") }
    let dirA = args[i + 1], dirB = args[i + 2]
    let fm = FileManager.default
    let namesA = Set(((try? fm.contentsOfDirectory(atPath: dirA)) ?? []).filter { $0.hasSuffix(".png") })
    let namesB = Set(((try? fm.contentsOfDirectory(atPath: dirB)) ?? []).filter { $0.hasSuffix(".png") })
    let common = namesA.intersection(namesB).sorted()
    if common.isEmpty { fail("no same-named PNGs in \(dirA) and \(dirB)") }
    var files: [String: Any] = [:]
    var worstMax = 0
    var worstPSNR = Double.infinity
    var meanAbsSum = 0.0
    for name in common {
        let a = loadRGBA("\(dirA)/\(name)"), b = loadRGBA("\(dirB)/\(name)")
        guard a.w == b.w, a.h == b.h else { files[name] = ["error": "size mismatch"]; continue }
        var maxD = 0, sumAbs = 0, sumSq = 0, differing = 0
        let n = a.w * a.h
        a.px.withUnsafeBufferPointer { pa in
            b.px.withUnsafeBufferPointer { pb in
                for p in 0..<n {
                    var any = false
                    for c in 0..<3 {
                        let d = abs(Int(pa[p * 4 + c]) - Int(pb[p * 4 + c]))
                        if d > maxD { maxD = d }
                        sumAbs += d
                        sumSq += d * d
                        if d > 0 { any = true }
                    }
                    if any { differing += 1 }
                }
            }
        }
        let mse = Double(sumSq) / Double(n * 3)
        let psnr = mse == 0 ? Double.infinity : 10 * log10(255.0 * 255.0 / mse)
        let meanAbs = Double(sumAbs) / Double(n * 3)
        worstMax = max(worstMax, maxD)
        worstPSNR = min(worstPSNR, psnr)
        meanAbsSum += meanAbs
        files[name] = [
            "psnr_db": psnr.isInfinite ? "inf" : r2(psnr) as Any,
            "max_abs": maxD,
            "mean_abs": r4(meanAbs),
            "pixels_differing_pct": r4(100.0 * Double(differing) / Double(n)),
        ]
    }
    print(jsonString([
        "a": dirA, "b": dirB,
        "files": files,
        "worst_psnr_db": worstPSNR.isInfinite ? "inf" : r2(worstPSNR) as Any,
        "worst_max_abs": worstMax,
        "mean_abs_avg": r4(meanAbsSum / Double(common.count)),
        "identical": worstMax == 0,
        "only_in_a": namesA.subtracting(namesB).sorted(),
        "only_in_b": namesB.subtracting(namesA).sorted(),
    ] as [String: Any]))
    exit(0)
}

// MARK: - Depth generation mode (the app's DepthMapGenerator, run once to make the fixture)

if let i = args.firstIndex(of: "--gen-depth") {
    guard i + 2 < args.count else { fail("--gen-depth needs IMAGE OUT.png") }
    let imagePath = args[i + 1], outPath = args[i + 2]
    let framed = ImageFraming.coverCrop(loadCGImage(imagePath))
    let sem = DispatchSemaphore(value: 0)
    Task {
        guard let gen = DepthMapGenerator() else { fail("DepthMapGenerator init failed (model next to binary?)") }
        do {
            let depth = try await gen.generateDepth(from: framed)
            writePNG(depth, outPath)
            log("wrote depth \(depth.width)x\(depth.height) to \(outPath)")
        } catch { fail("depth generation failed: \(error)") }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// MARK: - Options

guard let metallibPath = takeValue("--metallib") else { fail("--metallib is required") }
let metallibPathB = takeValue("--metallib-b")
guard let imagePath = takeValue("--image") else { fail("--image is required") }
let depthPath = takeValue("--depth")
let times: [Float] = (takeValue("--times") ?? "37,113,260,611").split(separator: ",").map {
    guard let t = Float($0) else { fail("bad --times") }; return t
}
let withTransition = !takeFlag("--no-transition")
let framesPerTrial = Int(takeValue("--frames") ?? "300") ?? 300
let trials = Int(takeValue("--trials") ?? "5") ?? 5
let warmupFrames = Int(takeValue("--warmup") ?? "60") ?? 60
let inflight = max(1, Int(takeValue("--inflight") ?? "1") ?? 1)
let mono = takeFlag("--mono")
let outDir = takeValue("--out")
let pngFrames = Int(takeValue("--png-frames") ?? "30") ?? 30
let jsonPath = takeValue("--json")
let label = takeValue("--label") ?? ""
let setArg = takeValue("--set")
let scenariosPath = takeValue("--scenarios")
let intensityArg = takeValue("--intensity").map { v -> Float in guard let f = Float(v) else { fail("bad --intensity") }; return f }
let imageAgeArg = takeValue("--image-age").map { v -> Float in guard let f = Float(v) else { fail("bad --image-age") }; return f }
let renderOnly = takeFlag("--render-only")
let leftOnly = takeFlag("--left-only")
let pngSize: (w: Int, h: Int)? = takeValue("--png-size").map { v in
    let p = v.lowercased().split(separator: "x").compactMap { Int($0) }
    guard p.count == 2, p[0] > 0, p[1] > 0 else { fail("bad --png-size (want WxH)") }
    return (p[0], p[1])
}
if renderOnly && outDir == nil { fail("--render-only needs --out DIR") }
if !args.isEmpty { fail("unknown arguments: \(args.joined(separator: " "))") }

let size = 2048            // OffscreenEffectsRenderer.outputSize — never reduce
let delay: Float = 0.5     // SettingsService default delay (ghost tap spawning)
let renderFormat: MTLPixelFormat = .bgra8Unorm          // OffscreenEffectsRenderer.renderFormat
let drawableFormat: MTLPixelFormat = .bgra8Unorm_srgb   // DrawableQueue texture format
let drawablesPerEye = 3

// MARK: - Metal setup

guard let device = MTLCreateSystemDefaultDevice() else { fail("no Metal device") }
guard let queue = device.makeCommandQueue() else { fail("no command queue") }
func loadLibrary(_ path: String) -> MTLLibrary {
    do { return try device.makeLibrary(URL: URL(fileURLWithPath: path)) }
    catch { fail("cannot load metallib \(path): \(error)") }
}

func makePipeline(_ library: MTLLibrary, _ fragment: String, attachments: Int) -> MTLRenderPipelineState {
    guard let vfn = library.makeFunction(name: "effectsVertex"),
          let ffn = library.makeFunction(name: fragment) else { fail("missing shader function \(fragment)") }
    let pd = MTLRenderPipelineDescriptor()
    pd.vertexFunction = vfn
    pd.fragmentFunction = ffn
    for a in 0..<attachments { pd.colorAttachments[a].pixelFormat = renderFormat }
    do { return try device.makeRenderPipelineState(descriptor: pd) } catch { fail("pipeline \(fragment): \(error)") }
}
/// Variant 0 = --metallib (A), variant 1 = --metallib-b (B, interleaved A/B mode).
struct Variant {
    let name: String
    let path: String
    let stereo: MTLRenderPipelineState?
    let mono: MTLRenderPipelineState
}
let variantPaths: [(String, String)] = [("A", metallibPath)] + (metallibPathB.map { [("B", $0)] } ?? [])
let variants: [Variant] = variantPaths.map { name, path in
        let lib = loadLibrary(path)
        return Variant(name: name, path: path,
                       stereo: mono ? nil : makePipeline(lib, "effectsFragmentStereo", attachments: 2),
                       mono: makePipeline(lib, "effectsFragment", attachments: 1))
    }

let sampler: MTLSamplerState = {
    let sd = MTLSamplerDescriptor()
    sd.minFilter = .linear
    sd.magFilter = .linear
    sd.sAddressMode = .clampToEdge
    sd.tAddressMode = .clampToEdge
    return device.makeSamplerState(descriptor: sd)!
}()

func makeTexture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, usage: MTLTextureUsage,
                 storage: MTLStorageMode) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
    d.usage = usage
    d.storageMode = storage
    guard let t = device.makeTexture(descriptor: d) else { fail("texture alloc failed") }
    return t
}

/// Shared texture + optimizeContentsForGPUAccess, as the app's uploads.
func uploadTexture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, bytesPerRow: Int, _ bytes: UnsafeRawPointer) -> MTLTexture {
    let t = makeTexture(format, w, h, usage: .shaderRead, storage: .shared)
    t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: bytesPerRow)
    let cb = queue.makeCommandBuffer()!
    let blit = cb.makeBlitCommandEncoder()!
    blit.optimizeContentsForGPUAccess(texture: t)
    blit.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    return t
}

/// OffscreenEffectsRenderer.updateSourceTexture: draw unflipped into a 2048² sRGB BGRA context.
func uploadColor(_ img: CGImage, mirrored: Bool = false) -> MTLTexture {
    let bpr = size * 4
    var buf = [UInt8](repeating: 0, count: bpr * size)
    let ctx = CGContext(data: &buf, width: size, height: size, bitsPerComponent: 8, bytesPerRow: bpr,
                        space: srgb, bitmapInfo: bgraInfo)!
    ctx.interpolationQuality = .high
    if mirrored { ctx.translateBy(x: CGFloat(size), y: 0); ctx.scaleBy(x: -1, y: 1) }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
    return buf.withUnsafeBytes { uploadTexture(.bgra8Unorm, size, size, bytesPerRow: bpr, $0.baseAddress!) }
}

/// OffscreenEffectsRenderer.updateDepthTexture: r8 at the map's own size, unflipped.
func uploadGray(_ img: CGImage) -> MTLTexture {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return buf.withUnsafeBytes { uploadTexture(.r8Unorm, w, h, bytesPerRow: w, $0.baseAddress!) }
}

func onePixel(_ format: MTLPixelFormat, _ bytes: [UInt8]) -> MTLTexture {
    bytes.withUnsafeBytes { uploadTexture(format, 1, 1, bytesPerRow: bytes.count, $0.baseAddress!) }
}

// MARK: - Inputs

log("shader-bench: \(device.name), metallib \(metallibPath)")
let framed = ImageFraming.coverCrop(loadCGImage(imagePath))
let vibrance = ImageColorStats.factors(for: framed)
let sourceTex = uploadColor(framed)
let previousTex = uploadColor(framed, mirrored: true)
let depthTex: MTLTexture = depthPath.map { uploadGray(loadCGImage($0)) } ?? onePixel(.r8Unorm, [128])
let saliencyTex = onePixel(.r8Unorm, [128])       // default 1x1 neutral saliency
let blackTex = onePixel(renderFormat, [0, 0, 0, 255])  // feedback placeholder (first frame)

// MARK: - Scenarios

struct Scenario {
    let name: String
    let uniforms: EffectsUniforms   // stereoOffset = |eye offset|
    let taps: MTLBuffer
    let previous: MTLTexture
}

/// Real GhostTapManager stepped through the preceding 40 s up to t (as the render loop does).
func ghostTaps(at t: Float) -> (MTLBuffer, Int) {
    let m = GhostTapManager()
    var time = max(0, t - 40)
    var last = m.updateWithCount(currentTime: time, delay: delay)
    while time < t {
        time = min(t, time + 1.0 / 60.0)
        last = m.updateWithCount(currentTime: time, delay: delay)
    }
    // Determinism: GhostTapManager adds Float.random(±0.15 rad) to each tap's direction. Rebuild the
    // direction from the spawn time (t - progress * 8 s lifetime) with zero variance, i.e. the
    // manager's base drift. Count and progress (what drives the cost) are the manager's own.
    var data = last.data
    for k in 0..<last.activeCount {
        let spawn = t - data[k].progress * 8.0
        let a = sin(spawn * 0.08) * Float.pi + sin(spawn * 0.03) * 0.5
        data[k].directionX = cos(a)
        data[k].directionY = sin(a)
    }
    let len = GhostTapManager.maxTaps * MemoryLayout<GhostTapData>.stride
    let buf = device.makeBuffer(length: len, options: .storageModeShared)!
    buf.contents().copyMemory(from: data, byteCount: len)
    return (buf, last.activeCount)
}

/// Uniform fields that --set / a scenario's "set" may override (every Float of EffectsUniforms).
let uniformFields: [String: WritableKeyPath<EffectsUniforms, Float>] = [
    "time": \.time, "kenBurnsScale": \.kenBurnsScale, "kenBurnsOffsetX": \.kenBurnsOffsetX,
    "kenBurnsOffsetY": \.kenBurnsOffsetY, "distortionAmplitude": \.distortionAmplitude,
    "distortionSpeed": \.distortionSpeed, "hueBaseShift": \.hueBaseShift,
    "hueWaveIntensity": \.hueWaveIntensity, "hueBlendAmount": \.hueBlendAmount,
    "contrastBoost": \.contrastBoost, "saturationBoost": \.saturationBoost,
    "ghostTapMaxDistance": \.ghostTapMaxDistance, "saliencyInfluence": \.saliencyInfluence,
    "hasSaliencyMap": \.hasSaliencyMap, "transitionProgress": \.transitionProgress,
    "ghostTapCount": \.ghostTapCount, "chromaticAmount": \.chromaticAmount,
    "feedbackWarpAmount": \.feedbackWarpAmount, "feedbackMix": \.feedbackMix,
    "bloomRadius": \.bloomRadius, "bloomAmount": \.bloomAmount, "stereoOffset": \.stereoOffset,
    "logSphereAmount": \.logSphereAmount, "fractalNoiseAmount": \.fractalNoiseAmount,
    "fractalHueAmount": \.fractalHueAmount, "vibranceAmount": \.vibranceAmount, "blackPoint": \.blackPoint,
]
func uniformsDict(_ u: EffectsUniforms) -> [String: Double] {
    var d: [String: Double] = [:]
    for (k, kp) in uniformFields { d[k] = Double(u[keyPath: kp]) }
    return d
}
func applyOverrides(_ u: inout EffectsUniforms, _ over: [String: Float]) {
    for (k, v) in over {
        guard let kp = uniformFields[k] else { fail("unknown uniform '\(k)' (known: \(uniformFields.keys.sorted().joined(separator: ", ")))") }
        u[keyPath: kp] = v
    }
}
let globalOverrides: [String: Float] = {
    var d: [String: Float] = [:]
    for pair in (setArg ?? "").split(separator: ",") {
        let kv = pair.split(separator: "=")
        guard kv.count == 2, let v = Float(kv[1]) else { fail("bad --set entry '\(pair)'") }
        d[String(kv[0])] = v
    }
    return d
}()

/// The app's uniforms for one scenario. Intensity / image age (--intensity, --image-age, or a
/// scenario's "intensity" / "age") reach the app's own computer here (docs/plans/effects-balance.md
/// 7.1), so the bench renders exactly what the setting does.
func computeUniforms(t: Float, tp: Float, intensity: Float?, age: Float?) -> EffectsUniforms {
    // Default (no --intensity / --image-age): intensity 0.5, age nil = the shipped default look.
    EffectsUniformsComputer.compute(time: t, transitionProgress: tp, hasSaliencyMap: false, vibrance: vibrance,
        look: EffectLook(intensity: intensity ?? EffectLook.defaultIntensity, imageAge: age))
}

func makeScenario(_ name: String, t: Float, tp: Float, over: [String: Float] = [:],
                  intensity: Float? = intensityArg, age: Float? = imageAgeArg) -> Scenario {
    var u = computeUniforms(t: t, tp: tp, intensity: intensity, age: age)
    let (buf, count) = ghostTaps(at: t)
    u.ghostTapCount = Float(count)
    let offset = 0.003 + 0.007 * SmoothOscillator.value(at: t)
    u.stereoOffset = depthPath != nil ? abs(offset) : 0   // renderer: 0 without a depth map
    applyOverrides(&u, globalOverrides)
    applyOverrides(&u, over)
    return Scenario(name: name, uniforms: u, taps: buf, previous: tp > 0 ? previousTex : sourceTex)
}

var scenarios: [Scenario]
if let scenariosPath = scenariosPath {
    guard let data = FileManager.default.contents(atPath: scenariosPath),
          let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !list.isEmpty else {
        fail("cannot read scenario list \(scenariosPath)")
    }
    scenarios = list.map { item in
        guard let name = item["name"] as? String, let t = (item["time"] as? NSNumber)?.floatValue else {
            fail("scenario needs \"name\" and \"time\"")
        }
        let tp = (item["tp"] as? NSNumber)?.floatValue ?? 0
        let over = (item["set"] as? [String: NSNumber] ?? [:]).mapValues { $0.floatValue }
        return makeScenario(name, t: t, tp: tp, over: over,
                            intensity: (item["intensity"] as? NSNumber)?.floatValue ?? intensityArg,
                            age: (item["age"] as? NSNumber)?.floatValue ?? imageAgeArg)
    }
} else {
    scenarios = times.map { makeScenario("t\(Int($0))", t: $0, tp: 0) }
    if withTransition { scenarios.append(makeScenario("trans113", t: 113, tp: 0.5)) }
}

// MARK: - Targets (DrawableQueue-like rotation per eye, each with its bgra8Unorm view)

struct Eye {
    let storage: MTLTexture
    let view: MTLTexture
}
func makeEyes(storage: MTLStorageMode) -> [[Eye]] {
    (0..<2).map { _ in
        (0..<drawablesPerEye).map { _ in
            let t = makeTexture(drawableFormat, size, size, usage: [.renderTarget, .shaderRead], storage: storage)
            guard let v = t.makeTextureView(pixelFormat: renderFormat) else { fail("cannot make bgra8Unorm view") }
            return Eye(storage: t, view: v)
        }
    }
}
let timedEyes = makeEyes(storage: .private)

/// Per-frame state: which drawable each eye writes next, and the last output (feedback).
final class FrameState {
    let eyes: [[Eye]]
    var next = 0
    var last: [MTLTexture?] = [nil, nil]
    init(_ eyes: [[Eye]]) { self.eyes = eyes }
}

func encodeFrame(_ cb: MTLCommandBuffer, _ sc: Scenario, _ st: FrameState, variant: Int = 0) -> (left: Eye, right: Eye) {
    let left = st.eyes[0][st.next], right = st.eyes[1][st.next]
    st.next = (st.next + 1) % drawablesPerEye
    var u = sc.uniforms
    if mono {
        for (eye, target) in [left, right].enumerated() {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target.view
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
            enc.setRenderPipelineState(variants[variant].mono)
            var ue = u
            ue.stereoOffset = eye == 0 ? -abs(u.stereoOffset) : abs(u.stereoOffset)
            if st.last[eye] == nil { ue.feedbackMix = 0 }
            enc.setFragmentTexture(st.last[eye] ?? blackTex, index: 4)
            enc.setFragmentBytes(&ue, length: MemoryLayout<EffectsUniforms>.size, index: 0)
            enc.setFragmentBuffer(sc.taps, offset: 0, index: 1)
            enc.setFragmentTexture(sourceTex, index: 0)
            enc.setFragmentTexture(saliencyTex, index: 2)
            enc.setFragmentTexture(sc.previous, index: 3)
            enc.setFragmentTexture(depthTex, index: 5)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }
    } else {
        let rpd = MTLRenderPassDescriptor()
        for (a, target) in [left, right].enumerated() {
            rpd.colorAttachments[a].texture = target.view
            rpd.colorAttachments[a].loadAction = .dontCare
            rpd.colorAttachments[a].storeAction = .store
        }
        let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
        enc.setRenderPipelineState(variants[variant].stereo!)
        if st.last[0] == nil || st.last[1] == nil { u.feedbackMix = 0 }
        enc.setFragmentTexture(st.last[0] ?? blackTex, index: 4)
        enc.setFragmentTexture(st.last[1] ?? blackTex, index: 6)
        enc.setFragmentBytes(&u, length: MemoryLayout<EffectsUniforms>.size, index: 0)
        enc.setFragmentBuffer(sc.taps, offset: 0, index: 1)
        enc.setFragmentTexture(sourceTex, index: 0)
        enc.setFragmentTexture(saliencyTex, index: 2)
        enc.setFragmentTexture(sc.previous, index: 3)
        enc.setFragmentTexture(depthTex, index: 5)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }
    st.last = [left.view, right.view]
    return (left, right)
}

// MARK: - Other GPU clients (recorded; they share the GPU and add noise)

let otherGPUClients: [String] = {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-Ao", "comm"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return out.split(separator: "\n").map(String.init)
        .filter { $0.hasSuffix("/Liminal") || $0.hasSuffix("/SimMetalHost") }
        .map { $0.contains("CoreSimulator/Devices") ? "Liminal (simulator)"
               : $0.hasSuffix("/SimMetalHost") ? "SimMetalHost" : "Liminal (Mac)" }
        .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        .sorted { $0.key < $1.key }
        .map { "\($0.key) x\($0.value)" }
}()
if otherGPUClients.contains(where: { $0.hasPrefix("Liminal") }) {
    log("warning: Liminal is running (\(otherGPUClients.joined(separator: ", "))); it shares the GPU.")
}

// MARK: - Timing

struct FrameResult { let variant: Int; let scenario: Int; let ms: Double }

/// Runs `count` frames per variant. Variants alternate frame by frame (A B A B ..., or B A B A ...
/// when `bFirst`), scenarios advance every len(variants) frames, so drift hits everything equally.
func runFrames(_ count: Int, _ st: FrameState, bFirst: Bool = false) -> [FrameResult] {
    let nv = variants.count
    let sem = DispatchSemaphore(value: inflight)
    let lock = NSLock()
    var results: [FrameResult] = []
    results.reserveCapacity(count * nv)
    for f in 0..<(count * nv) {
        sem.wait()
        let v = bFirst ? (nv - 1 - f % nv) : f % nv
        let si = (f / nv) % scenarios.count
        guard let cb = queue.makeCommandBuffer() else { fail("no command buffer") }
        _ = encodeFrame(cb, scenarios[si], st, variant: v)
        cb.addCompletedHandler { cb in
            if let err = cb.error { fail("command buffer error: \(err)") }
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            lock.lock(); results.append(FrameResult(variant: v, scenario: si, ms: ms)); lock.unlock()
            sem.signal()
        }
        cb.commit()
    }
    // Every completion handler signals after recording, so this waits for all of them.
    for _ in 0..<inflight { sem.wait() }
    for _ in 0..<inflight { sem.signal() }
    return results
}

log("scenarios: \(scenarios.map { "\($0.name)(taps \(Int($0.uniforms.ghostTapCount)))" }.joined(separator: " ")), \(mono ? "mono 2 passes" : "MRT stereo"), inflight \(inflight), variants \(variants.map { $0.name }.joined(separator: "/"))")
let timedState = FrameState(timedEyes)
if !renderOnly {
    log("warm-up \(warmupFrames) frames ...")
    _ = runFrames(warmupFrames, timedState)
}

var frames = [[Double]](repeating: [], count: variants.count)                       // [variant]
var perScenario = [[[Double]]](repeating: [[Double]](repeating: [], count: scenarios.count), count: variants.count)
var trialMedians = [[Double]](repeating: [], count: variants.count)
var trialOut: [[String: Any]] = []
for tr in 0..<(renderOnly ? 0 : trials) {
    let start = Date()
    let res = runFrames(framesPerTrial, timedState, bFirst: tr % 2 == 1)
    let wall = Date().timeIntervalSince(start) * 1000 / Double(framesPerTrial * variants.count)
    var detail: [String: Any] = ["wall_ms_per_frame": r4(wall)]
    var line = "trial \(tr + 1)/\(trials):"
    for v in variants.indices {
        let ms = res.filter { $0.variant == v }.map { $0.ms }
        for r in res where r.variant == v { perScenario[v][r.scenario].append(r.ms) }
        frames[v] += ms
        let med = median(ms)
        trialMedians[v].append(med)
        detail[variants[v].name] = ["median_ms": r4(med), "p10_ms": r4(quantile(ms, 0.1)), "p90_ms": r4(quantile(ms, 0.9))]
        line += String(format: " %@ median %.3f ms (p10 %.3f, p90 %.3f)", variants[v].name, med, quantile(ms, 0.1), quantile(ms, 0.9))
    }
    if variants.count == 2 {
        let ratio = trialMedians[1][tr] / trialMedians[0][tr]
        detail["ratio_b_over_a"] = r4(ratio)
        line += String(format: "  B/A %.4f", ratio)
    }
    trialOut.append(detail)
    log(line)
}

func variantSummary(_ v: Int) -> [String: Any] {
    var sc: [String: Any] = [:]
    for (i, s) in scenarios.enumerated() {
        let xs = perScenario[v][i]
        sc[s.name] = [
            "median_ms": r4(median(xs)), "p10_ms": r4(quantile(xs, 0.1)), "p90_ms": r4(quantile(xs, 0.9)),
            "ghost_taps": Int(s.uniforms.ghostTapCount), "time": Double(s.uniforms.time),
            "transition": Double(s.uniforms.transitionProgress),
        ]
    }
    let tm = trialMedians[v]
    let mean = tm.reduce(0, +) / Double(tm.count)
    return [
        "metallib": variants[v].path,
        "median_ms": r4(median(frames[v])),
        "p10_ms": r4(quantile(frames[v], 0.1)),
        "p90_ms": r4(quantile(frames[v], 0.9)),
        "trial_medians_ms": tm.map(r4),
        "trial_spread_pct": r2((tm.max()! - tm.min()!) / mean * 100),
        "scenarios": sc,
    ]
}

// MARK: - PNG output (deterministic: fresh state, first frame without feedback, then N frames)
// A goes to DIR, B (if any) to DIR/b, so `--compare DIR DIR/b` is the A/B parity check.

if let outDir = outDir {
    let pngEyes = makeEyes(storage: .shared)
    for v in variants.indices {
        let dir = v == 0 ? outDir : "\(outDir)/b"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for sc in scenarios {
            let st = FrameState(pngEyes)
            var final: (left: Eye, right: Eye)?
            let cb = queue.makeCommandBuffer()!
            for _ in 0..<max(1, pngFrames) { final = encodeFrame(cb, sc, st, variant: v) }
            cb.commit()
            cb.waitUntilCompleted()
            for (tag, eye) in leftOnly ? [("L", final!.left)] : [("L", final!.left), ("R", final!.right)] {
                let bpr = size * 4
                var buf = [UInt8](repeating: 0, count: bpr * size)
                // Raw stored bytes are the shader's gamma values; interpret them as sRGB (what is shown).
                eye.storage.getBytes(&buf, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
                let ctx = CGContext(data: &buf, width: size, height: size, bitsPerComponent: 8, bytesPerRow: bpr,
                                    space: srgb, bitmapInfo: bgraInfo)!
                var image = ctx.makeImage()!
                if let ps = pngSize {
                    let small = CGContext(data: nil, width: ps.w, height: ps.h, bitsPerComponent: 8, bytesPerRow: ps.w * 4,
                                          space: srgb, bitmapInfo: bgraInfo)!
                    small.interpolationQuality = .high
                    small.draw(image, in: CGRect(x: 0, y: 0, width: ps.w, height: ps.h))
                    image = small.makeImage()!
                }
                writePNG(image, "\(dir)/\(sc.name)-\(tag).png")
            }
        }
        log("wrote \(scenarios.count * (leftOnly ? 1 : 2)) PNGs to \(dir)")
    }
}

// MARK: - Summary

let gitHead: String = {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", ProcessInfo.processInfo.environment["LIMINAL_REPO"] ?? ".", "rev-parse", "--short", "HEAD"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}()

if renderOnly {
    var sc: [String: Any] = [:]
    for s in scenarios { sc[s.name] = uniformsDict(s.uniforms) }
    let text = jsonString([
        "label": label, "git_head": gitHead, "image": imagePath, "out": outDir ?? "",
        "vibrance_factors": ["amount": Double(vibrance.amount), "dark": Double(vibrance.dark)],
        "png_frames": pngFrames, "uniforms": sc,
    ] as [String: Any])
    print(text)
    if let jsonPath = jsonPath { try? text.write(toFile: jsonPath, atomically: true, encoding: .utf8) }
    exit(0)
}

var summary: [String: Any] = [
    "label": label,
    "gpu": device.name,
    "git_head": gitHead,
    "image": imagePath, "image_sha": sha256Prefix(imagePath),
    "depth": depthPath ?? NSNull(),
    "vibrance_factors": ["amount": Double(vibrance.amount), "dark": Double(vibrance.dark)],
    "size": size,
    "path": mono ? "mono-2pass" : "mrt-stereo",
    "frames_per_trial": framesPerTrial, "trials": trials, "warmup": warmupFrames, "inflight": inflight,
    "trials_detail": trialOut,
    "other_gpu_clients": otherGPUClients,
    "out": outDir ?? NSNull(),
]
// A's numbers at the top level (single-shader runs read these directly).
for (k, v) in variantSummary(0) { summary[k] = v }
if variants.count == 2 {
    summary["b"] = variantSummary(1)
    let ratios = trialOut.compactMap { $0["ratio_b_over_a"] as? Double }
    summary["ratio_b_over_a_median_of_trials"] = r4(median(ratios))
    summary["ratio_b_over_a_trials"] = ratios
    summary["ratio_b_over_a_overall"] = r4(median(frames[1]) / median(frames[0]))
}
let text = jsonString(summary)
print(text)
if let jsonPath = jsonPath { try? text.write(toFile: jsonPath, atomically: true, encoding: .utf8) }
