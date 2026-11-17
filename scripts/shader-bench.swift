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
//   --video FRAME.png  archive footage frame (docs/plans/archive-video.md 7): built into a 960x720 stage
//                      texture like the app's pre-pass (r = g = luma, b = edge strength standing in for
//                      motion) and bound at textures 7 and 8 (layer B of a piece crossfade, A27: turn it on
//                      with --set videoMixB=0.3,videoLookB=3,videoScaleB=0.95,videoAspectB=0.89,videoWarpB=0.6).
//                      Without it both are 1x1 black and the mixes 0.
//   --video-look NAME  phantom | imprint | window | emerge | palette | print | poster (default phantom)
//   --video-mode NAME  footage recipe (docs/plans/footage-fx.md 5: a blend look or an interaction mode, e.g.
//                      undertow, fringe, wake, aurora, solar, poster, shadowplay, backdrop, kaleido, relief,
//                      glow, print, facets) through VideoComposite, as the app pins it with -LiminalVideoMode;
//                      overrides --video-look. --video-mode-b NAME: layer B of --footage-b (default: the same).
//   --video-mix X      constant footage mix (VideoCompositeState.constantMix; default: the look's
//                      ceiling at the intensity). Video uniforms can also be set with --set.
//   --video-seed X     0...1 placement seed (default 0.3)
//   --footage-seq      render the still image with moving archive footage as a frame sequence (no GPU
//                      timing; needs --out; docs/plans/footage-fx.md 9). The image is fixed and settled,
//                      the effect clock runs from --seq-start for --seq-len seconds, and the footage is
//                      decoded from an mp4 with AVAssetReader at the app's pace and run through the app's
//                      own pre-pass kernel (--prepass-metallib, built by the wrapper from ArchiveVideo.metal)
//                      into three rotating 960x720 stage textures, as VideoFrameSource does. Without
//                      --footage the same timeline is rendered with footage off (the reference).
//   --footage CLIP.mp4 layer A (texture 7).  --footage-start S (default 20)  --footage-rate R (0.72)
//   --footage-b CLIP.mp4  layer B (texture 8), --footage-b-start S, --video-look-b NAME, --video-seed-b X:
//                      a second piece; --footage-xfade AT,LEN crossfades A -> B (complementary smoothsteps,
//                      as FootagePiece.envelope) starting AT seconds into the sequence.
//   --video-level X    piece level as a fraction of the look's ceiling (default 0.5, the weaver's band is
//                      0.42-0.58); the app's mix formula applies. --video-mix X pins the mix instead.
//   --video-warp X     share of the picture's warp the footage rides (default 0.6)
//   --footage-dump     also write each layer's stage texture per frame (s0000-A.png, 240x180, RGB = luma /
//                      slow average / motion): what scripts/ffx-check.py correlates the picture against
//   --seq-len S        length of --footage-seq in seconds (default 8)
//   --seq-ref b        with --footage-seq: the image alone, every effect off, same timeline
//   Interaction modes (docs/plans/footage-fx.md) are pinned with --set once their uniforms exist
//   (every Float of EffectsUniforms listed in `uniformFields` can be set).
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
//   --sequence        render an image transition as a frame sequence (no GPU timing; needs --out and
//                      --prev-image). --prev-image is image A (shown first), --image is image B.
//                      The timeline is the app's: A alone for --seq-pre seconds (image age 30 s - pre ...),
//                      then the crossfade (previous = A, source = B, transitionProgress linear 0...1 over
//                      --seq-duration, image age counted from the crossfade start, vibrance factors
//                      blended A -> B as the renderers do), then B alone for --seq-post seconds
//                      (transitionProgress 0, previous = source, image age keeps counting, so the
//                      fresh-image hold is in the clip). Every frame is simulated at --seq-sim-fps with
//                      continuous feedback and ghost taps; every (sim-fps / fps)-th frame is written as
//                      DIR/f0000-L.png ... and DIR/sequence.json lists time, phase, tp, age and the
//                      uniforms of every written frame. scripts/tx-clip.sh wraps this (clips, filmstrips).
//   --prev-image PATH  image A of --sequence
//   --seq-start T      effect time at which the crossfade starts (default 113)
//   --seq-duration S   crossfade length in seconds (default: 1.5 for classic, else the style's mid range)
//   --seq-pre S / --seq-post S   seconds rendered before / after the crossfade (default 1 / 3)
//   --seq-fps N        written frames per second (default 30); --seq-sim-fps N simulated (default 60)
//   --seq-ref a|b      effect-free reference of the same timeline: image A or B alone, Ken Burns only
//                      (every effect amount 0, no crossfade). scripts/tx-check.py scores frames against these.
//   --tx-style NAME / --tx-seed N   transition style and seed (docs/plans/transitions.md; names in
//                      ImageTransition.swift, "classic" = the pre-family crossfade). The spec is
//                      TransitionSpec.pinned(style, seed: N), as the app's debug flags give it; without
//                      --seq-duration the style's mid duration is used. Applies to --sequence and to
//                      every scenario; a --scenarios entry may set its own "tx_style" / "tx_seed".
//   --gen-depth IMAGE OUT.png   run the app's DepthMapGenerator (DepthAnythingV2SmallF16.mlmodelc
//                      must sit next to the binary; the wrapper arranges it) and save the map
//
// Output: one JSON object on stdout. Progress goes to stderr.

import Foundation
import AVFoundation
import CoreVideo
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
let videoPath = takeValue("--video")
let videoLookArg = takeValue("--video-look") ?? "phantom"
let videoMixArg = takeValue("--video-mix").map { v -> Float in guard let f = Float(v) else { fail("bad --video-mix") }; return f }
let videoSeedArg = Float(takeValue("--video-seed") ?? "0.3") ?? 0.3
let footageSeq = takeFlag("--footage-seq")
let footagePath = takeValue("--footage")
let footagePathB = takeValue("--footage-b")
let footageStart = Double(takeValue("--footage-start") ?? "20") ?? 20
let footageStartB = Double(takeValue("--footage-b-start") ?? "20") ?? 20
let footageRate = Double(takeValue("--footage-rate") ?? "0.72") ?? 0.72
let footageXfade: (at: Double, len: Double)? = takeValue("--footage-xfade").map { v in
    let p = v.split(separator: ",").compactMap { Double($0) }
    guard p.count == 2, p[1] > 0 else { fail("bad --footage-xfade (want AT,LEN)") }
    return (p[0], p[1])
}
let videoLookArgB = takeValue("--video-look-b")
let videoModeArg = takeValue("--video-mode").map { v -> FootageRecipe in
    guard let r = FootageRecipe(name: v) else { fail("--video-mode: \(FootageRecipe.allCases.map(\.name).joined(separator: ", "))") }
    return r
}
let videoModeArgB = takeValue("--video-mode-b").map { v -> FootageRecipe in
    guard let r = FootageRecipe(name: v) else { fail("--video-mode-b: \(FootageRecipe.allCases.map(\.name).joined(separator: ", "))") }
    return r
}
let videoSeedArgB = Float(takeValue("--video-seed-b") ?? "0.7") ?? 0.7
let videoLevelArg = Float(takeValue("--video-level") ?? "0.5") ?? 0.5
let videoWarpArg = Float(takeValue("--video-warp") ?? "0.6") ?? 0.6
let prepassMetallibPath = takeValue("--prepass-metallib")
let footageDump = takeFlag("--footage-dump")
let seqLen = Double(takeValue("--seq-len") ?? "8") ?? 8
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
let sequenceMode = takeFlag("--sequence")
let prevImagePath = takeValue("--prev-image")
func floatOpt(_ flag: String, _ def: Float) -> Float {
    guard let v = takeValue(flag) else { return def }
    guard let f = Float(v) else { fail("bad \(flag)") }
    return f
}
let seqStart = floatOpt("--seq-start", 113)
let seqDurationArg = takeValue("--seq-duration").map { v -> Float in guard let f = Float(v) else { fail("bad --seq-duration") }; return f }
let seqPre = floatOpt("--seq-pre", 1)
let seqPost = floatOpt("--seq-post", 3)
let seqFps = Int(floatOpt("--seq-fps", 30))
let seqSimFps = Int(floatOpt("--seq-sim-fps", 60))
let seqRef = takeValue("--seq-ref")
let txStyle = takeValue("--tx-style") ?? "classic"
let txSeed = Int(takeValue("--tx-seed") ?? "0") ?? 0
guard let txStyleValue = TransitionStyle(name: txStyle) else {
    fail("--tx-style \(txStyle): one of \(TransitionStyle.allCases.map { $0.name }.joined(separator: ", "))")
}
/// The transition of --sequence (and of scenarios without their own "tx_style"): same mapping as the
/// app's -LiminalTransitionStyle / -LiminalTransitionSeed. Duration: --seq-duration, else the style's mid range.
let txSpec: TransitionSpec = txStyleValue == .classic
    ? TransitionSpec(style: .classic, seed: 0, duration: seqDurationArg ?? 1.5, flip: false)
    : TransitionSpec.pinned(txStyleValue, seed: txSeed, duration: seqDurationArg)
let seqDuration = txSpec.duration
if sequenceMode {
    if prevImagePath == nil { fail("--sequence needs --prev-image (image A); --image is image B") }
    if seqFps < 1 || seqSimFps % seqFps != 0 { fail("--seq-sim-fps must be a multiple of --seq-fps") }
    if seqDuration <= 0 { fail("--seq-duration must be > 0") }
    if let r = seqRef, r != "a", r != "b" { fail("--seq-ref is a or b") }
}
if footageSeq {
    if footagePath != nil && prepassMetallibPath == nil { fail("--footage needs --prepass-metallib (the wrapper passes it)") }
    if footagePathB != nil && (footagePath == nil || footageXfade == nil) { fail("--footage-b needs --footage and --footage-xfade") }
    if seqFps < 1 || seqSimFps % seqFps != 0 { fail("--seq-sim-fps must be a multiple of --seq-fps") }
} else if footagePath != nil || footagePathB != nil { fail("--footage needs --footage-seq") }
let renderOnly = takeFlag("--render-only") || sequenceMode || footageSeq
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
    /// The footage interaction-mode variants (effectsFragment*Video{Keys,Drives,FX}) by variant id, when the
    /// library has them: used for frames whose uniforms need them (VideoComposite.footageVariant), as the
    /// renderers do.
    let stereoFX: [Int: MTLRenderPipelineState]
    let monoFX: [Int: MTLRenderPipelineState]
    func pipeline(mono m: Bool, _ u: EffectsUniforms) -> MTLRenderPipelineState {
        let v = VideoComposite.footageVariant(u)
        if m { return monoFX[v] ?? mono }
        return stereoFX[v] ?? stereo!
    }
}
let variantPaths: [(String, String)] = [("A", metallibPath)] + (metallibPathB.map { [("B", $0)] } ?? [])
/// With --video, a library that has the footage variants (effectsFragmentVideo / effectsFragmentStereoVideo,
/// docs/plans/archive-video.md 2.3) renders with them, as the renderers do while footage shows; a library
/// without them (main) renders its plain fragments.
func fragmentName(_ lib: MTLLibrary, _ base: String) -> String {
    (videoPath != nil || footagePath != nil) && lib.functionNames.contains(base + "Video") ? base + "Video" : base
}
let variants: [Variant] = variantPaths.map { name, path in
        let lib = loadLibrary(path)
        let fx = (videoPath != nil || footagePath != nil) && lib.functionNames.contains("effectsFragmentVideoFX")
        var sfx: [Int: MTLRenderPipelineState] = [:], mfx: [Int: MTLRenderPipelineState] = [:]
        if fx {
            for v in FootageRecipe.fxVariants {
                let suffix = VideoComposite.variantSuffix(v)
                mfx[v] = makePipeline(lib, "effectsFragment" + suffix, attachments: 1)
                if !mono { sfx[v] = makePipeline(lib, "effectsFragmentStereo" + suffix, attachments: 2) }
            }
        }
        return Variant(name: name, path: path,
                       stereo: mono ? nil : makePipeline(lib, fragmentName(lib, "effectsFragmentStereo"), attachments: 2),
                       mono: makePipeline(lib, fragmentName(lib, "effectsFragment"), attachments: 1),
                       stereoFX: sfx, monoFX: mfx)
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

/// Footage stage texture (--video): the app's pre-pass layout at 960x720, rgba8Unorm.
func videoStage(_ img: CGImage) -> MTLTexture {
    let w = 960, h = 720
    var g = [UInt8](repeating: 0, count: w * h)
    let ctx = CGContext(data: &g, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.interpolationQuality = .high
    // 6 % inset crop of film borders, as the pre-pass.
    let cw = CGFloat(w) / 0.88, ch = CGFloat(h) / 0.88
    ctx.draw(img, in: CGRect(x: -(cw - CGFloat(w)) / 2, y: -(ch - CGFloat(h)) / 2, width: cw, height: ch))
    var lo = 255, hi = 0
    var hist = [Int](repeating: 0, count: 256)
    for v in g { hist[Int(v)] += 1 }
    var acc = 0
    for i in 0..<256 { acc += hist[i]; if lo == 255 && acc >= g.count / 20 { lo = i }; if acc >= g.count * 19 / 20 { hi = i; break } }
    let span = Float(max(hi - lo, 12))
    var px = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let i = y * w + x
            let l = min(max((Float(g[i]) - Float(lo)) / span, 0), 1)
            let gx = Float(g[y * w + min(x + 1, w - 1)]) - Float(g[y * w + max(x - 1, 0)])
            let gy = Float(g[min(y + 1, h - 1) * w + x]) - Float(g[max(y - 1, 0) * w + x])
            let e = min((gx * gx + gy * gy).squareRoot() / 255 * 4, 1)
            px[i * 4] = UInt8(l * 255); px[i * 4 + 1] = UInt8(l * 255); px[i * 4 + 2] = UInt8(e * 255)
            px[i * 4 + 3] = UInt8(e * 255)   // edge (the pre-pass's alpha, footage-fx.md 6)
        }
    }
    return px.withUnsafeBytes { uploadTexture(.rgba8Unorm, w, h, bytesPerRow: w * 4, $0.baseAddress!) }
}
var videoTex: MTLTexture = videoPath.map { videoStage(loadCGImage($0)) } ?? onePixel(.rgba8Unorm, [0, 0, 0, 255])
var videoTexB: MTLTexture = videoTex   // layer B (texture 8): the same stage unless --footage-b
let videoState: VideoCompositeState = {
    guard let path = videoPath else { return .off }
    guard let look = VideoLook(name: videoLookArg) else { fail("--video-look: phantom, imprint, window or emerge") }
    let img = loadCGImage(path)
    let t = VideoComposite.stats(of: framed)
    var st = VideoCompositeState(envelope: 1, look: look, seed: videoSeedArg,
                                 aspect: Float(img.width) / Float(img.height), tint: t.tint, shade: t.shade)
    st.a?.recipe = videoModeArg
    st.constantMix = videoMixArg
    st.keyPolarity = t.polarity
    st.keyCoverage = t.coverage
    return st
}()

// MARK: - Scenarios

struct Scenario {
    let name: String
    let uniforms: EffectsUniforms   // stereoOffset = |eye offset|
    let taps: MTLBuffer
    let previous: MTLTexture
    var source: MTLTexture = sourceTex
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
    "txStyle": \.txStyle, "txMix": \.txMix, "txEnv": \.txEnv, "txSeed": \.txSeed, "txSoft": \.txSoft,
    "txAmount": \.txAmount,
    "videoMix": \.videoMix, "videoLook": \.videoLook, "videoSeed": \.videoSeed, "videoScale": \.videoScale,
    "videoAspect": \.videoAspect, "videoTintR": \.videoTintR, "videoTintG": \.videoTintG, "videoTintB": \.videoTintB,
    "videoShadeR": \.videoShadeR, "videoShadeG": \.videoShadeG, "videoShadeB": \.videoShadeB,
    "videoWarp": \.videoWarp, "videoMixB": \.videoMixB, "videoLookB": \.videoLookB, "videoSeedB": \.videoSeedB,
    "videoScaleB": \.videoScaleB, "videoAspectB": \.videoAspectB, "videoWarpB": \.videoWarpB,
    "videoDrive": \.videoDrive, "videoDriveAmt": \.videoDriveAmt, "videoKey": \.videoKey, "videoKeyAmt": \.videoKeyAmt,
    "videoDriveB": \.videoDriveB, "videoDriveAmtB": \.videoDriveAmtB, "videoKeyB": \.videoKeyB,
    "videoKeyAmtB": \.videoKeyAmtB, "tunnelStrength": \.tunnelStrength,
    "outgoingZoomScale": \.outgoingZoomScale,
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
func computeUniforms(t: Float, tp: Float, intensity: Float?, age: Float?, spec: TransitionSpec = txSpec) -> EffectsUniforms {
    // Default (no --intensity / --image-age): intensity 0.5, age nil = the shipped default look.
    EffectsUniformsComputer.compute(time: t, transitionProgress: tp, hasSaliencyMap: false, vibrance: vibrance,
        look: EffectLook(intensity: intensity ?? EffectLook.defaultIntensity, imageAge: age,
                         transitionDuration: spec.duration),
        transition: spec, video: videoState)
}

func makeScenario(_ name: String, t: Float, tp: Float, over: [String: Float] = [:],
                  intensity: Float? = intensityArg, age: Float? = imageAgeArg, spec: TransitionSpec = txSpec) -> Scenario {
    var u = computeUniforms(t: t, tp: tp, intensity: intensity, age: age, spec: spec)
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
        var spec = txSpec
        if let st = item["tx_style"] as? String {
            guard let style = TransitionStyle(name: st) else { fail("scenario \(name): unknown tx_style \(st)") }
            spec = style == .classic ? .classic : TransitionSpec.pinned(style, seed: (item["tx_seed"] as? NSNumber)?.intValue ?? 0)
        }
        return makeScenario(name, t: t, tp: tp, over: over,
                            intensity: (item["intensity"] as? NSNumber)?.floatValue ?? intensityArg,
                            age: (item["age"] as? NSNumber)?.floatValue ?? imageAgeArg, spec: spec)
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
            enc.setRenderPipelineState(variants[variant].pipeline(mono: true, u))
            var ue = u
            ue.stereoOffset = eye == 0 ? -abs(u.stereoOffset) : abs(u.stereoOffset)
            if st.last[eye] == nil { ue.feedbackMix = 0 }
            enc.setFragmentTexture(st.last[eye] ?? blackTex, index: 4)
            enc.setFragmentBytes(&ue, length: MemoryLayout<EffectsUniforms>.size, index: 0)
            enc.setFragmentBuffer(sc.taps, offset: 0, index: 1)
            enc.setFragmentTexture(sc.source, index: 0)
            enc.setFragmentTexture(saliencyTex, index: 2)
            enc.setFragmentTexture(sc.previous, index: 3)
            enc.setFragmentTexture(depthTex, index: 5)
        enc.setFragmentTexture(videoTex, index: 7)
        enc.setFragmentTexture(videoTexB, index: 8)
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
        enc.setRenderPipelineState(variants[variant].pipeline(mono: false, u))
        if st.last[0] == nil || st.last[1] == nil { u.feedbackMix = 0 }
        enc.setFragmentTexture(st.last[0] ?? blackTex, index: 4)
        enc.setFragmentTexture(st.last[1] ?? blackTex, index: 6)
        enc.setFragmentBytes(&u, length: MemoryLayout<EffectsUniforms>.size, index: 0)
        enc.setFragmentBuffer(sc.taps, offset: 0, index: 1)
        enc.setFragmentTexture(sc.source, index: 0)
        enc.setFragmentTexture(saliencyTex, index: 2)
        enc.setFragmentTexture(sc.previous, index: 3)
        enc.setFragmentTexture(depthTex, index: 5)
        enc.setFragmentTexture(videoTex, index: 7)
        enc.setFragmentTexture(videoTexB, index: 8)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }
    st.last = [left.view, right.view]
    return (left, right)
}

/// Raw stored bytes are the shader's gamma values; interpret them as sRGB (what is shown).
func savePNG(_ eye: Eye, _ path: String) {
    let bpr = size * 4
    var buf = [UInt8](repeating: 0, count: bpr * size)
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
    writePNG(image, path)
}

// MARK: - Footage sequence (--footage-seq): the still image with moving archive footage

/// VideoFrameSource without the clock: decodes a clip with AVAssetReader and runs the app's pre-pass
/// kernel into three rotating stage textures (r = levelled luma, g = slow average, b = motion).
final class FootageFeed {
    struct Params { var black: Float, white: Float, blend: Float, slowK: Float, motionK: Float, crop: Float, hasPrev: Float, pad: Float }
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let pipeline: MTLComputePipelineState
    let commands: MTLCommandQueue
    var stages: [MTLTexture] = []
    var frameTex: MTLTexture?
    var pending: CMSampleBuffer?
    var writeIndex = 0, decoded = 0
    var hasHistory = false
    var lastFrameWall = 0.0
    let start: Double, rate: Double
    let black: Float, white: Float
    let aspect: Float
    private(set) var latest: MTLTexture?

    static func texture(_ device: MTLDevice, _ format: MTLPixelFormat, _ w: Int, _ h: Int, usage: MTLTextureUsage,
                        storage: MTLStorageMode) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.usage = usage
        d.storageMode = storage
        return device.makeTexture(descriptor: d)!
    }

    init(path: String, start: Double, rate: Double, pipeline: MTLComputePipelineState, commands: MTLCommandQueue) {
        self.commands = commands
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = asset.tracks(withMediaType: .video).first, let r = try? AVAssetReader(asset: asset) else {
            fatalError("cannot open footage \(path)")
        }
        let duration = asset.duration.seconds
        let s = min(max(start, 0), max(duration - 1, 0))
        r.timeRange = CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600), duration: .positiveInfinity)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        r.add(o)
        guard r.startReading() else { fatalError("footage \(path): \(r.error?.localizedDescription ?? "cannot read")") }
        reader = r; output = o; self.pipeline = pipeline; self.start = s; self.rate = rate
        let size = track.naturalSize
        // The stage shows the frame minus the 6 % crop on each side: same aspect as the frame.
        aspect = Float(abs(size.width) / max(abs(size.height), 1))
        // ArchiveClipValidator.levels: 5th / 95th luma percentiles over 8 small frames, 6 % inset.
        let gen = AVAssetImageGenerator(asset: asset)
        gen.maximumSize = CGSize(width: 160, height: 160)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        var hist = [Int](repeating: 0, count: 256)
        for k in 0..<8 {
            let t = CMTime(seconds: duration * (0.1 + 0.8 * Double(k) / 7), preferredTimescale: 600)
            guard let img = try? gen.copyCGImage(at: t, actualTime: nil) else { continue }
            let w = img.width, h = img.height
            var px = [UInt8](repeating: 0, count: w * h)
            let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            let ix = w * 6 / 100, iy = h * 6 / 100
            for y in iy..<(h - iy) { for x in ix..<(w - ix) { hist[Int(px[y * w + x])] += 1 } }
        }
        let total = hist.reduce(0, +)
        func pct(_ p: Double) -> Float {
            var acc = 0
            for (i, n) in hist.enumerated() { acc += n; if Double(acc) >= p * Double(max(total, 1)) { return Float(i) / 255 } }
            return 1
        }
        var b = pct(0.05), w = pct(0.95)
        if total == 0 { b = 0; w = 1 }
        if w - b < 0.25 { let m = (w + b) / 2; b = max(0, m - 0.125); w = min(1, m + 0.125) }
        black = b; white = w
        stages = (0..<3).map { _ in Self.texture(commands.device, .rgba8Unorm, 960, 720, usage: [.shaderRead, .shaderWrite], storage: .shared) }
    }

    /// The newest stage as a 240x180 image (RGB = luma / slow average / motion).
    func stageImage() -> CGImage? {
        guard let t = latest else { return nil }
        let w = t.width, h = t.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        t.getBytes(&buf, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        guard let full = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: cs, bitmapInfo: info)?.makeImage(),
              let small = CGContext(data: nil, width: 240, height: 180, bitsPerComponent: 8, bytesPerRow: 960,
                                    space: cs, bitmapInfo: info) else { return nil }
        small.interpolationQuality = .medium
        small.draw(full, in: CGRect(x: 0, y: 0, width: 240, height: 180))
        return small.makeImage()
    }

    /// Advance to `wall` seconds since the piece began (the decoder's 30 Hz tick): show the newest frame
    /// whose time has come, as VideoFrameSource.tick.
    func tick(wall: Double) {
        let target = start + wall * rate
        var newest: CMSampleBuffer?
        while true {
            if pending == nil { pending = output.copyNextSampleBuffer() }
            guard let sb = pending else { break }   // end of the clip: hold the last frame
            if CMSampleBufferGetPresentationTimeStamp(sb).seconds > target && (decoded > 0 || newest != nil) { break }
            newest = sb
            pending = nil
        }
        guard let frame = newest, let pb = CMSampleBufferGetImageBuffer(frame) else { return }
        decoded += 1
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if frameTex?.width != w || frameTex?.height != h {
            frameTex = Self.texture(commands.device, .bgra8Unorm, w, h, usage: .shaderRead, storage: .shared)
        }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        frameTex!.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                          withBytes: CVPixelBufferGetBaseAddress(pb)!, bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        let dt = max(wall - lastFrameWall, 1.0 / 60)
        lastFrameWall = wall
        var p = Params(black: black, white: max(white, black + 0.05), blend: 0.4,
                       slowK: Float(1 - exp(-dt / 0.5)), motionK: Float(1 - exp(-dt / 0.25)),
                       crop: 0.06, hasPrev: hasHistory ? 1 : 0, pad: 0)
        let cb = commands.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        let out = stages[writeIndex]
        enc.setComputePipelineState(pipeline)
        enc.setTexture(frameTex, index: 0)
        enc.setTexture(stages[(writeIndex + 2) % 3], index: 1)
        enc.setTexture(out, index: 2)
        enc.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: 60, height: 45, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        latest = out
        hasHistory = true
        writeIndex = (writeIndex + 1) % 3
    }
}

if footageSeq, let outDir = outDir {
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let intensity = intensityArg ?? EffectLook.defaultIntensity
    let age: Float = imageAgeArg ?? 30   // a settled picture
    let refOff: [String: Float] = [
        "distortionAmplitude": 0, "logSphereAmount": 0, "fractalNoiseAmount": 0, "chromaticAmount": 0,
        "hueBlendAmount": 0, "hueWaveIntensity": 0, "fractalHueAmount": 0, "bloomAmount": 0,
        "ghostTapCount": 0, "feedbackMix": 0, "vibranceAmount": 0, "blackPoint": 0, "stereoOffset": 0,
    ]
    var feedA: FootageFeed?, feedB: FootageFeed?
    if seqRef == nil, let fp = footagePath, let pm = prepassMetallibPath {
        guard let fn = loadLibrary(pm).makeFunction(name: "videoPrepass"),
              let pipe = try? device.makeComputePipelineState(function: fn) else { fail("no videoPrepass in \(pm)") }
        feedA = FootageFeed(path: fp, start: footageStart, rate: footageRate, pipeline: pipe, commands: queue)
        if let fb = footagePathB { feedB = FootageFeed(path: fb, start: footageStartB, rate: footageRate, pipeline: pipe, commands: queue) }
    }
    guard let lookA = VideoLook(name: videoLookArg) else { fail("--video-look: phantom, imprint, window or emerge") }
    guard let lookB = VideoLook(name: videoLookArgB ?? videoLookArg) else { fail("--video-look-b: phantom, imprint, window or emerge") }
    let tint = VideoComposite.stats(of: framed)
    let stride = seqSimFps / seqFps
    let total = Int((seqLen * Double(seqSimFps)).rounded())
    let decodeEvery = max(1, seqSimFps / 30)   // VideoFrameSource ticks every 33 ms
    let leadB = 3.0                            // the incoming decoder starts 3 s before its crossfade
    let st = FrameState(makeEyes(storage: .shared))
    var frameList: [[String: Any]] = []
    func smooth(_ x: Double) -> Double { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }

    func scenario(at k: Int) -> (Scenario, [String: Any]) {
        let rel = Double(k) / Double(seqSimFps)
        let t = seqStart + Float(rel)
        let x = footageXfade.map { smooth((rel - $0.at) / $0.len) } ?? 0
        var envA = feedA == nil ? 0 : 1 - x, envB = feedB == nil ? 0 : x
        if feedA?.latest == nil { envA = 0 }
        if feedB?.latest == nil { envB = 0 }
        var state = VideoCompositeState.off
        if envA > 0 || envB > 0 {
            state = VideoCompositeState(
                a: envA > 0 ? VideoLayer(weight: Float(envA) * videoLevelArg, look: lookA, seed: videoSeedArg,
                                         aspect: feedA!.aspect, warp: videoWarpArg, recipe: videoModeArg,
                                         envelope: Float(envA)) : nil,
                b: envB > 0 ? VideoLayer(weight: Float(envB) * videoLevelArg, look: lookB, seed: videoSeedArgB,
                                         aspect: feedB!.aspect, warp: videoWarpArg, recipe: videoModeArgB ?? videoModeArg,
                                         envelope: Float(envB)) : nil,
                tint: tint.tint, shade: tint.shade)
            state.constantMix = videoMixArg
            state.keyPolarity = tint.polarity
            state.keyCoverage = tint.coverage
        }
        var u = EffectsUniformsComputer.compute(time: t, transitionProgress: 0, hasSaliencyMap: false, vibrance: vibrance,
            look: EffectLook(intensity: intensity, imageAge: age, transitionDuration: txSpec.duration),
            transition: txSpec, video: state)
        if videoMixArg != nil {   // a pinned mix (and its drive) still crossfades
            u.videoMix *= Float(envA); u.videoMixB *= Float(envB)
            u.videoDriveAmt *= Float(envA); u.videoDriveAmtB *= Float(envB)
        }
        let (buf, count) = ghostTaps(at: t)
        u.ghostTapCount = Float(count)
        if seqRef != nil {
            applyOverrides(&u, refOff)
        } else {
            let offset = 0.003 + 0.007 * SmoothOscillator.value(at: t)
            u.stereoOffset = depthPath != nil ? abs(offset) : 0
            applyOverrides(&u, globalOverrides)
        }
        var info: [String: Any] = ["time": Double(t), "rel": rel, "env_a": envA, "env_b": envB]
        info["uniforms"] = uniformsDict(u)
        return (Scenario(name: "footage", uniforms: u, taps: buf, previous: sourceTex), info)
    }
    func feed(at k: Int) {
        guard k % decodeEvery == 0 else { return }
        let rel = Double(k) / Double(seqSimFps)
        feedA?.tick(wall: rel)
        if let fb = feedB, let xf = footageXfade, rel >= xf.at - leadB { fb.tick(wall: rel - (xf.at - leadB)) }
        if let tex = feedA?.latest { videoTex = tex }
        videoTexB = feedB?.latest ?? videoTex
    }

    // Warm-up at the first frame's time so the feedback trails have converged before frame 0.
    feed(at: 0)
    if seqRef == nil {
        let (first, _) = scenario(at: 0)
        let cb = queue.makeCommandBuffer()!
        for _ in 0..<max(1, pngFrames) { _ = encodeFrame(cb, first, st) }
        cb.commit()
        cb.waitUntilCompleted()
    }
    var written = 0
    for k in 0...total {
        if seqRef != nil && k % stride != 0 { continue }
        feed(at: k)
        let (sc, info) = scenario(at: k)
        let cb = queue.makeCommandBuffer()!
        let out = encodeFrame(cb, sc, st)
        cb.commit()
        cb.waitUntilCompleted()
        if let err = cb.error { fail("command buffer error: \(err)") }
        if k % stride == 0 {
            let name = String(format: "f%04d", written)
            savePNG(out.left, "\(outDir)/\(name)-L.png")
            if !leftOnly { savePNG(out.right, "\(outDir)/\(name)-R.png") }
            if footageDump {
                let n = String(format: "s%04d", written)
                if let img = feedA?.stageImage() { writePNG(img, "\(outDir)/\(n)-A.png") }
                if let img = feedB?.stageImage() { writePNG(img, "\(outDir)/\(n)-B.png") }
            }
            var entry = info
            entry["frame"] = name
            frameList.append(entry)
            written += 1
        }
    }
    log("wrote \(written) footage-sequence frames to \(outDir) (decoded A \(feedA?.decoded ?? 0), B \(feedB?.decoded ?? 0))")
    let text = jsonString([
        "label": label, "image": imagePath, "out": outDir, "footage": footagePath ?? "", "footage_b": footagePathB ?? "",
        "footage_start": footageStart, "footage_rate": footageRate,
        "levels": feedA.map { ["black": Double($0.black), "white": Double($0.white)] } ?? [:],
        "look": seqRef == nil && feedA != nil ? lookA.name : "", "look_b": feedB != nil ? lookB.name : "",
        "mode": videoModeArg?.name ?? "", "mode_b": (videoModeArgB ?? videoModeArg)?.name ?? "",
        "level": Double(videoLevelArg), "mix": videoMixArg.map { Double($0) } ?? -1, "warp": Double(videoWarpArg),
        "ref": seqRef ?? "", "intensity": Double(intensity), "start": Double(seqStart), "len": seqLen,
        "fps": seqFps, "sim_fps": seqSimFps, "frames": frameList,
    ] as [String: Any])
    try? text.write(toFile: jsonPath ?? "\(outDir)/sequence.json", atomically: true, encoding: .utf8)
    print(jsonString(["out": outDir, "frames": written, "look": lookA.name, "footage": footagePath ?? ""] as [String: Any]))
    exit(0)
}

// MARK: - Transition sequence (--sequence): image A -> image B on the app's timeline

if sequenceMode, let outDir = outDir, let prevImagePath = prevImagePath {
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let framedA = ImageFraming.coverCrop(loadCGImage(prevImagePath))
    let vibA = ImageColorStats.factors(for: framedA), vibB = vibrance
    let texA = uploadColor(framedA), texB = sourceTex
    let intensity = intensityArg ?? EffectLook.defaultIntensity
    let imageInterval: Float = 30
    // Every effect amount off (scripts/fx-structure.py `ref`): Ken Burns is all that is left.
    let refOff: [String: Float] = [
        "distortionAmplitude": 0, "logSphereAmount": 0, "fractalNoiseAmount": 0, "chromaticAmount": 0,
        "hueBlendAmount": 0, "hueWaveIntensity": 0, "fractalHueAmount": 0, "bloomAmount": 0,
        "ghostTapCount": 0, "feedbackMix": 0, "vibranceAmount": 0, "blackPoint": 0, "stereoOffset": 0,
    ]
    let stride = seqSimFps / seqFps
    let total = Int(((seqPre + seqDuration + seqPost) * Float(seqSimFps)).rounded())
    let st = FrameState(makeEyes(storage: .shared))
    var frameList: [[String: Any]] = []

    func scenario(at k: Int) -> (Scenario, [String: Any]) {
        let rel = Float(k) / Float(seqSimFps) - seqPre          // seconds since the crossfade started
        let t = seqStart + rel
        let phase = rel < 0 ? "pre" : (rel < seqDuration ? "transition" : "post")
        let tp: Float = phase == "transition" ? rel / seqDuration : 0
        let age: Float = rel < 0 ? imageInterval + rel : rel     // image A has been up for one interval
        let vib = phase == "pre" ? vibA : (phase == "post" ? vibB : VibranceFactors.lerp(vibA, vibB, tp))
        var u: EffectsUniforms
        var source = phase == "pre" ? texA : texB
        var previous = phase == "transition" ? texA : source
        if let ref = seqRef {
            source = ref == "a" ? texA : texB
            previous = source
            u = EffectsUniformsComputer.compute(time: t, transitionProgress: 0, hasSaliencyMap: false,
                vibrance: ref == "a" ? vibA : vibB, look: EffectLook(intensity: intensity, imageAge: age, imageInterval: imageInterval,
                                                                     transitionDuration: txSpec.duration))
            applyOverrides(&u, refOff)
        } else {
            u = EffectsUniformsComputer.compute(time: t, transitionProgress: tp, hasSaliencyMap: false, vibrance: vib,
                look: EffectLook(intensity: intensity, imageAge: age, imageInterval: imageInterval,
                                 transitionDuration: txSpec.duration),
                transition: txSpec)
            let offset = 0.003 + 0.007 * SmoothOscillator.value(at: t)
            u.stereoOffset = depthPath != nil ? abs(offset) : 0
            applyOverrides(&u, globalOverrides)
        }
        let (buf, count) = ghostTaps(at: t)
        if seqRef == nil && globalOverrides["ghostTapCount"] == nil { u.ghostTapCount = Float(count) }
        var info: [String: Any] = ["time": Double(t), "rel": Double(rel), "phase": phase, "tp": Double(tp), "age": Double(age)]
        info["uniforms"] = uniformsDict(u)
        return (Scenario(name: "seq", uniforms: u, taps: buf, previous: previous, source: source), info)
    }

    // Warm-up at the first frame's time so the feedback trails have converged before frame 0.
    if seqRef == nil {
        let (first, _) = scenario(at: 0)
        let cb = queue.makeCommandBuffer()!
        for _ in 0..<max(1, pngFrames) { _ = encodeFrame(cb, first, st) }
        cb.commit()
        cb.waitUntilCompleted()
    }
    var written = 0
    for k in 0...total {
        if seqRef != nil && k % stride != 0 { continue }   // references carry no state between frames
        let (sc, info) = scenario(at: k)
        let cb = queue.makeCommandBuffer()!
        let out = encodeFrame(cb, sc, st)
        cb.commit()
        if k % stride == 0 {
            cb.waitUntilCompleted()
            if let err = cb.error { fail("command buffer error: \(err)") }
            let name = String(format: "f%04d", written)
            savePNG(out.left, "\(outDir)/\(name)-L.png")
            if !leftOnly { savePNG(out.right, "\(outDir)/\(name)-R.png") }
            var entry = info
            entry["frame"] = name
            frameList.append(entry)
            written += 1
        }
    }
    log("wrote \(written) sequence frames to \(outDir)")
    let text = jsonString([
        "label": label, "image_a": prevImagePath, "image_b": imagePath, "out": outDir,
        "tx_style": txStyle, "tx_seed": txSeed, "tx_spec_seed": Double(txSpec.seed), "tx_flip": txSpec.flip,
        "ref": seqRef ?? "", "intensity": Double(intensity),
        "start": Double(seqStart), "duration": Double(seqDuration), "pre": Double(seqPre), "post": Double(seqPost),
        "fps": seqFps, "sim_fps": seqSimFps, "frames": frameList,
    ] as [String: Any])
    try? text.write(toFile: jsonPath ?? "\(outDir)/sequence.json", atomically: true, encoding: .utf8)
    print(jsonString(["out": outDir, "frames": written, "tx_style": txStyle, "ref": seqRef ?? ""] as [String: Any]))
    exit(0)
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
                savePNG(eye, "\(dir)/\(sc.name)-\(tag).png")
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
