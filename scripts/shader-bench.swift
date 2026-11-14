// shader-bench.swift — offline Mac-GPU benchmark of Liminal's visionOS eye pass.
//
// What it does
//   Compiles Liminal/Shaders/EffectsRenderer.metal from the working tree at runtime
//   (device.makeLibrary(source:)), then renders the visionOS eye pass exactly as
//   OffscreenEffectsRenderer.renderEyeToDrawable does it:
//     - 2048x2048 bgra8Unorm_srgb target, loadAction .dontCare, storeAction .store
//     - fragment bindings: uniforms bytes @ buffer 0, ghost tap buffer @ buffer 1,
//       source @ tex 0, 1x1 r8 saliency (0.5) @ tex 2, previous @ tex 3 (falls back to source),
//       NOTHING @ tex 4 (feedbackTexture stays unbound, as on visionOS), r8 depth @ tex 5,
//       linear/clamp sampler @ sampler 0, triangle strip of 4 vertices.
//   Inputs are deterministic and procedural (no Gemini image cache): a 2048² colour image with
//   gradients, high-frequency detail and bright spots, a second image for the crossfade, and a
//   2048² depth map. Uniforms are EffectsUniformsComputer.compute ported for a fixed time (t=100).
//
//   Scenarios (each for stereoOffset -0.008 = L and +0.008 = R):
//     steady      transitionProgress 0,   ghostTapCount 0, previous = source
//     ghost4      transitionProgress 0,   ghostTapCount 4, previous = source
//     transition  transitionProgress 0.5, ghostTapCount 4 (shader skips taps mid-transition),
//                 previous = second procedural image
//
//   Timing: every repetition is one command buffer holding --passes eye passes (one render
//   encoder per pass, alternating between two targets like the two eye drawables). Time is
//   gpuEndTime - gpuStartTime divided by --passes. After --warmup buffers, --reps buffers are
//   timed per scenario, and scenarios are interleaved round-robin so host drift hits all of them.
//   Reported per scenario: median and min ms per eye pass, spread = (max-min)/median and
//   iqr = (p75-p25)/median. other_gpu_clients lists a running Liminal / SimMetalHost, which
//   share the GPU and make the numbers noisy: quit the simulator for reference runs.
//
// Build / run (the wrapper scripts/shader-bench.sh does this and caches the binary):
//   swiftc -O scripts/shader-bench.swift -o <scratch>/shader-bench
//   <scratch>/shader-bench [options]
//
// Options
//   --shader PATH      .metal source (default: <repo>/Liminal/Shaders/EffectsRenderer.metal)
//   --fragment NAME    fragment entry point (default effectsFragment)
//   --vertex NAME      vertex entry point (default effectsVertex)
//   --passes N         eye passes per command buffer (default 40)
//   --reps N           timed command buffers per scenario (default 7)
//   --warmup N         untimed command buffers per scenario before timing (default 3)
//   --time T           effect time for the uniforms (default 100)
//   --only a,b         run only these scenarios (e.g. steady-L,transition-R)
//   --out DIR          write <scenario>.png for each scenario (one pass, after timing)
//   --json PATH        also write the JSON summary to PATH
//   --compare A B      no GPU work: compare same-named PNGs in dirs A and B and print
//                      max and mean abs diff per channel (0-255) as JSON
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

func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
func round4(_ x: Double) -> Double { (x * 10000).rounded() / 10000 }

// MARK: - Arguments

var args = Array(CommandLine.arguments.dropFirst())
func takeValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag) else { return nil }
    guard i + 1 < args.count else { fail("\(flag) needs a value") }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent()

// MARK: - PNG IO

func loadRGBA(_ url: URL) -> (w: Int, h: Int, px: [UInt8])? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ok = px.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? (w, h, px) : nil
}

func writePNG(bgra: [UInt8], width: Int, height: Int, to url: URL) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let data = Data(bgra) as CFData
    guard let provider = CGDataProvider(data: data),
          let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: cs,
                            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                     | CGImageAlphaInfo.noneSkipFirst.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("could not write \(url.path)") }
    CGImageDestinationAddImage(dest, img, nil)
    if !CGImageDestinationFinalize(dest) { fail("could not finalize \(url.path)") }
}

// MARK: - Compare mode

if let i = args.firstIndex(of: "--compare") {
    guard i + 2 < args.count else { fail("--compare needs two directories") }
    let dirA = URL(fileURLWithPath: args[i + 1]), dirB = URL(fileURLWithPath: args[i + 2])
    let fm = FileManager.default
    let namesA = Set(((try? fm.contentsOfDirectory(atPath: dirA.path)) ?? []).filter { $0.hasSuffix(".png") })
    let namesB = Set(((try? fm.contentsOfDirectory(atPath: dirB.path)) ?? []).filter { $0.hasSuffix(".png") })
    let common = namesA.intersection(namesB).sorted()
    if common.isEmpty { fail("no same-named PNGs in \(dirA.path) and \(dirB.path)") }
    var results: [String: Any] = [:]
    var worstMax = 0
    var meanSum = 0.0
    for name in common {
        guard let a = loadRGBA(dirA.appendingPathComponent(name)),
              let b = loadRGBA(dirB.appendingPathComponent(name)) else { fail("could not read \(name)") }
        guard a.w == b.w, a.h == b.h else { results[name] = ["error": "size mismatch"]; continue }
        var maxD = [0, 0, 0], sumD = [0, 0, 0], differing = 0
        let n = a.w * a.h
        a.px.withUnsafeBufferPointer { pa in
            b.px.withUnsafeBufferPointer { pb in
                for p in 0..<n {
                    var any = false
                    for c in 0..<3 {
                        let d = abs(Int(pa[p * 4 + c]) - Int(pb[p * 4 + c]))
                        if d > maxD[c] { maxD[c] = d }
                        sumD[c] += d
                        if d > 0 { any = true }
                    }
                    if any { differing += 1 }
                }
            }
        }
        let means = sumD.map { round4(Double($0) / Double(n)) }
        worstMax = max(worstMax, maxD.max()!)
        meanSum += means.reduce(0, +) / 3
        results[name] = [
            "max_abs": ["r": maxD[0], "g": maxD[1], "b": maxD[2]],
            "mean_abs": ["r": means[0], "g": means[1], "b": means[2]],
            "pixels_differing_pct": round4(100.0 * Double(differing) / Double(n)),
        ]
    }
    let onlyA = namesA.subtracting(namesB).sorted(), onlyB = namesB.subtracting(namesA).sorted()
    print(jsonString([
        "a": dirA.path, "b": dirB.path,
        "files": results,
        "worst_max_abs": worstMax,
        "mean_abs_avg": round4(meanSum / Double(common.count)),
        "identical": worstMax == 0,
        "only_in_a": onlyA, "only_in_b": onlyB,
    ] as [String: Any]))
    exit(0)
}

// MARK: - Options

let shaderPath = takeValue("--shader") ?? repoRoot.appendingPathComponent("Liminal/Shaders/EffectsRenderer.metal").path
let fragmentName = takeValue("--fragment") ?? "effectsFragment"
let vertexName = takeValue("--vertex") ?? "effectsVertex"
let passesPerBuffer = Int(takeValue("--passes") ?? "40") ?? 40
let reps = Int(takeValue("--reps") ?? "7") ?? 7
let warmup = Int(takeValue("--warmup") ?? "3") ?? 3
let effectTime = Float(takeValue("--time") ?? "100") ?? 100
let onlyList = takeValue("--only")?.split(separator: ",").map(String.init)
let outDir = takeValue("--out")
let jsonPath = takeValue("--json")
if !args.isEmpty { fail("unknown arguments: \(args.joined(separator: " "))") }

let size = 2048

// MARK: - Uniforms (mirror of Liminal/EffectsUniforms.swift, 25 floats)

struct EffectsUniforms {
    var time: Float
    var kenBurnsScale: Float
    var kenBurnsOffsetX: Float
    var kenBurnsOffsetY: Float
    var distortionAmplitude: Float
    var distortionSpeed: Float
    var hueBaseShift: Float
    var hueWaveIntensity: Float
    var hueBlendAmount: Float
    var contrastBoost: Float
    var saturationBoost: Float
    var ghostTapMaxDistance: Float
    var saliencyInfluence: Float
    var hasSaliencyMap: Float
    var transitionProgress: Float
    var ghostTapCount: Float
    var chromaticAmount: Float
    var feedbackWarpAmount: Float
    var feedbackMix: Float
    var bloomRadius: Float
    var bloomAmount: Float
    var stereoOffset: Float
    var logSphereAmount: Float
    var fractalNoiseAmount: Float
    var fractalHueAmount: Float
}
precondition(MemoryLayout<EffectsUniforms>.size == 25 * 4, "EffectsUniforms must be 25 floats")

struct ShaderGhostTap {
    var progress: Float
    var directionX: Float
    var directionY: Float
    var active: Float
}

/// Port of EffectsUniformsComputer.compute (hasSaliencyMap false, as ImmersiveDomeView passes).
func computeUniforms(time: Float, transitionProgress tp: Float) -> EffectsUniforms {
    let phi: Float = 1.618034
    let boost = sin(tp * .pi)

    let kbScale: Float = 1.2 + 0.15 * sin(time * 0.05) + 0.05 * sin(time * 0.03)
    let kbX = (60 * sin(time * 0.04) + 20 * sin(time * 0.025)) / 100
    let kbY = (60 * cos(time * 0.035) + 20 * cos(time * 0.02)) / 100

    let dWave = (sin(time * 0.04 * phi) + sin(time * 0.025) * 0.7 + sin(time * 0.06 / phi) * 0.4) / 2.1
    let dAmp = (0.02 + 0.06 * (dWave + 1) / 2) * (1 + 9 * boost)

    let osc: Float = {
        let c = (sin(time * 0.1) + sin(time * 0.1 * phi) * 0.7 + sin(time * 0.1 * phi * phi) * 0.5
                 + sin(time * 0.037) * 0.6) / 2.8
        return (c + 1) / 2
    }()

    let cWave = (sin(time * 0.07 * phi) + sin(time * 0.03) * 0.6) / 1.6
    let chromatic = (0.003 + 0.012 * (cWave + 1) / 2) * (1 + 3 * boost)

    let lWave = (sin(time * 0.035 * phi * phi) + sin(time * 0.022 / phi) * 0.7) / 1.7
    let logSphere = (0.003 + 0.017 * (lWave + 1) / 2) * (1 + 2 * boost)

    let nWave = (sin(time * 0.028 * phi) + sin(time * 0.045 / (phi * phi)) * 0.6) / 1.6
    let fNoise = (0.005 + 0.025 * (nWave + 1) / 2) * (1 + 4 * boost)

    let hWave = (sin(time * 0.032 / phi) + sin(time * 0.05 * phi * phi) * 0.5) / 1.5
    let fHue = 0.05 + 0.2 * (hWave + 1) / 2

    return EffectsUniforms(
        time: time, kenBurnsScale: kbScale, kenBurnsOffsetX: kbX, kenBurnsOffsetY: kbY,
        distortionAmplitude: dAmp, distortionSpeed: 0.08,
        hueBaseShift: 0, hueWaveIntensity: osc * 0.6, hueBlendAmount: osc * 0.8,
        contrastBoost: 1.4, saturationBoost: 1.3, ghostTapMaxDistance: 0.06,
        saliencyInfluence: 0, hasSaliencyMap: 0, transitionProgress: tp, ghostTapCount: 0,
        chromaticAmount: chromatic, feedbackWarpAmount: 0.03, feedbackMix: 0.3,
        bloomRadius: 0.04, bloomAmount: 0.5, stereoOffset: 0,
        logSphereAmount: logSphere, fractalNoiseAmount: fNoise, fractalHueAmount: fHue)
}

// MARK: - Metal setup

guard let device = MTLCreateSystemDefaultDevice() else { fail("no Metal device") }
guard let queue = device.makeCommandQueue() else { fail("no command queue") }
guard let source = try? String(contentsOfFile: shaderPath, encoding: .utf8) else { fail("cannot read \(shaderPath)") }

let library: MTLLibrary
do {
    let opts = MTLCompileOptions()
    opts.languageVersion = .version3_0
    library = try device.makeLibrary(source: source, options: opts)
} catch { fail("shader compile failed: \(error)") }

guard let vfn = library.makeFunction(name: vertexName) else { fail("no vertex function \(vertexName)") }
guard let ffn = library.makeFunction(name: fragmentName) else { fail("no fragment function \(fragmentName)") }

let pipeline: MTLRenderPipelineState
do {
    let pd = MTLRenderPipelineDescriptor()
    pd.vertexFunction = vfn
    pd.fragmentFunction = ffn
    pd.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
    pipeline = try device.makeRenderPipelineState(descriptor: pd)
} catch { fail("pipeline failed: \(error)") }

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

/// Upload CPU pixels into a .shared texture, matching the app's source/previous/depth textures.
func sharedTexture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, bytesPerPixel: Int, _ px: [UInt8]) -> MTLTexture {
    let t = makeTexture(format, w, h, usage: .shaderRead, storage: .shared)
    px.withUnsafeBytes { buf in
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                  withBytes: buf.baseAddress!, bytesPerRow: w * bytesPerPixel)
    }
    return t
}

// MARK: - Procedural inputs (deterministic)

/// Small integer hash -> 0..1, deterministic across runs.
@inline(__always) func hash01(_ x: UInt32, _ y: UInt32, _ seed: UInt32) -> Float {
    var h = x &* 0x8da6b343 ^ y &* 0xd8163841 ^ seed &* 0xcb1ab31f
    h ^= h >> 13; h = h &* 0x5bd1e995; h ^= h >> 15
    return Float(h & 0xffffff) / Float(0xffffff)
}

func makeColorImage(seed: UInt32) -> [UInt8] {
    var px = [UInt8](repeating: 255, count: size * size * 4)
    let s = Float(seed)
    // Bright spots: fixed pseudo-random centres
    var spots: [(Float, Float, Float)] = []
    for k in 0..<24 {
        spots.append((hash01(UInt32(k), 1, seed), hash01(UInt32(k), 2, seed), 0.01 + 0.03 * hash01(UInt32(k), 3, seed)))
    }
    px.withUnsafeMutableBufferPointer { p in
        DispatchQueue.concurrentPerform(iterations: size) { y in
            let v = Float(y) / Float(size - 1)
            for x in 0..<size {
                let u = Float(x) / Float(size - 1)
                // Smooth gradients
                var r = 0.5 + 0.45 * sin(6.0 * u + 1.3 * s)
                var g = 0.5 + 0.45 * sin(5.0 * v + 2.1 + 0.7 * s)
                var b = 0.5 + 0.45 * sin(4.0 * (u + v) + 4.2 + 0.3 * s)
                // High-frequency detail: fine stripes + checker + per-pixel grain
                let stripes = 0.12 * sin(Float(x) * 0.9 + Float(y) * 0.35)
                let checker: Float = ((x >> 4) ^ (y >> 4)) & 1 == 0 ? 0.08 : -0.08
                let grain = (hash01(UInt32(x), UInt32(y), seed) - 0.5) * 0.15
                r += stripes + checker + grain
                g += -stripes + checker + grain
                b += stripes * 0.5 - checker + grain
                // Bright spots (bloom + chromatic fringing)
                for sp in spots {
                    let dx = u - sp.0, dy = v - sp.1
                    let d2 = (dx * dx + dy * dy) / (sp.2 * sp.2)
                    if d2 < 4 {
                        let e = exp(-d2) * 1.2
                        r += e; g += e * 0.95; b += e * 0.85
                    }
                }
                let i = (y * size + x) * 4
                // BGRA
                p[i + 0] = UInt8(max(0, min(1, b)) * 255)
                p[i + 1] = UInt8(max(0, min(1, g)) * 255)
                p[i + 2] = UInt8(max(0, min(1, r)) * 255)
                p[i + 3] = 255
            }
        }
    }
    return px
}

func makeDepth() -> [UInt8] {
    var px = [UInt8](repeating: 0, count: size * size)
    px.withUnsafeMutableBufferPointer { p in
        DispatchQueue.concurrentPerform(iterations: size) { y in
            let v = Float(y) / Float(size - 1)
            for x in 0..<size {
                let u = Float(x) / Float(size - 1)
                // Far background gradient + a near blob in the middle + soft ripples
                var d = 0.15 + 0.25 * v
                let dx = u - 0.5, dy = v - 0.55
                d += 0.6 * exp(-(dx * dx + dy * dy) / 0.03)
                d += 0.05 * sin(u * 40) * sin(v * 33)
                p[y * size + x] = UInt8(max(0, min(1, d)) * 255)
            }
        }
    }
    return px
}

/// Liminal running in the visionOS simulator (or the Mac app) competes for the same GPU and
/// inflates both the numbers and the spread. Detect it so the JSON records it.
let otherGPUClients: [String] = {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-Ao", "comm"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    // Read before waiting: ps output can exceed the pipe buffer and deadlock otherwise.
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
if !otherGPUClients.isEmpty {
    log("warning: other GPU clients running (\(otherGPUClients.joined(separator: ", "))); expect noisy numbers. Quit the simulator / app for a clean run.")
}

log("shader-bench: \(device.name), shader \(shaderPath), fragment \(fragmentName)")
log("generating procedural inputs ...")
let sourceTex = sharedTexture(.bgra8Unorm, size, size, bytesPerPixel: 4, makeColorImage(seed: 1))
let previousTex = sharedTexture(.bgra8Unorm, size, size, bytesPerPixel: 4, makeColorImage(seed: 2))
let depthTex = sharedTexture(.r8Unorm, size, size, bytesPerPixel: 1, makeDepth())
let saliencyTex = sharedTexture(.r8Unorm, 1, 1, bytesPerPixel: 1, [128])

// Ghost taps: 8 slots, first 4 active (packed at the front like GhostTapManager.buildShaderData)
let ghostBuffer: MTLBuffer = {
    var taps = [ShaderGhostTap](repeating: ShaderGhostTap(progress: 0, directionX: 0, directionY: 0, active: 0), count: 8)
    let progresses: [Float] = [0.1, 0.35, 0.6, 0.85]
    for (k, pr) in progresses.enumerated() {
        let a = 0.7 + Float(k) * 0.25
        taps[k] = ShaderGhostTap(progress: pr, directionX: cos(a), directionY: sin(a), active: 1)
    }
    return device.makeBuffer(bytes: taps, length: MemoryLayout<ShaderGhostTap>.stride * 8, options: .storageModeShared)!
}()

// Two render targets, like the two eye drawables
let targets = (0..<2).map { _ in
    makeTexture(.bgra8Unorm_srgb, size, size, usage: [.renderTarget, .shaderRead], storage: .private)
}

// MARK: - Scenarios

struct Scenario {
    let name: String
    var uniforms: EffectsUniforms
    let previous: MTLTexture
}

var scenarios: [Scenario] = []
for (eye, off) in [("L", Float(-0.008)), ("R", Float(0.008))] {
    var steady = computeUniforms(time: effectTime, transitionProgress: 0)
    steady.stereoOffset = off
    var ghost = steady
    ghost.ghostTapCount = 4
    var trans = computeUniforms(time: effectTime, transitionProgress: 0.5)
    trans.stereoOffset = off
    trans.ghostTapCount = 4
    scenarios.append(Scenario(name: "steady-\(eye)", uniforms: steady, previous: sourceTex))
    scenarios.append(Scenario(name: "ghost4-\(eye)", uniforms: ghost, previous: sourceTex))
    scenarios.append(Scenario(name: "transition-\(eye)", uniforms: trans, previous: previousTex))
}
if let only = onlyList {
    scenarios = scenarios.filter { only.contains($0.name) }
    if scenarios.isEmpty { fail("--only matched no scenario") }
}

// MARK: - Encoding (mirrors OffscreenEffectsRenderer.renderEyeToDrawable)

func encodeEyePass(_ cb: MTLCommandBuffer, _ sc: Scenario, target: MTLTexture) {
    let rpd = MTLRenderPassDescriptor()
    rpd.colorAttachments[0].texture = target
    rpd.colorAttachments[0].loadAction = .dontCare
    rpd.colorAttachments[0].storeAction = .store
    guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { fail("no encoder") }
    enc.setRenderPipelineState(pipeline)
    var u = sc.uniforms
    enc.setFragmentBytes(&u, length: MemoryLayout<EffectsUniforms>.size, index: 0)
    enc.setFragmentBuffer(ghostBuffer, offset: 0, index: 1)
    enc.setFragmentTexture(sourceTex, index: 0)
    enc.setFragmentTexture(saliencyTex, index: 2)
    enc.setFragmentTexture(sc.previous, index: 3)
    // texture 4 (feedbackTexture) intentionally left unbound, as on visionOS
    enc.setFragmentTexture(depthTex, index: 5)
    enc.setFragmentSamplerState(sampler, index: 0)
    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    enc.endEncoding()
}

func runBuffer(_ sc: Scenario, passes: Int) -> Double {
    guard let cb = queue.makeCommandBuffer() else { fail("no command buffer") }
    for i in 0..<passes { encodeEyePass(cb, sc, target: targets[i & 1]) }
    cb.commit()
    cb.waitUntilCompleted()
    if let err = cb.error { fail("command buffer error: \(err)") }
    return (cb.gpuEndTime - cb.gpuStartTime) * 1000.0 / Double(passes)
}

// MARK: - Timing (scenarios interleaved round-robin)

log("warming up (\(warmup) buffers x \(passesPerBuffer) passes per scenario) ...")
for _ in 0..<warmup { for sc in scenarios { _ = runBuffer(sc, passes: passesPerBuffer) } }

var samples = [String: [Double]]()
for r in 0..<reps {
    for sc in scenarios { samples[sc.name, default: []].append(runBuffer(sc, passes: passesPerBuffer)) }
    log("rep \(r + 1)/\(reps) done")
}

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

/// Linear-interpolated quantile.
func quantile(_ xs: [Double], _ q: Double) -> Double {
    let s = xs.sorted()
    let pos = q * Double(s.count - 1)
    let lo = Int(pos.rounded(.down)), hi = min(lo + 1, s.count - 1)
    return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
}

var scenarioOut: [String: Any] = [:]
var medians: [Double] = []
var worstSpread = 0.0
var worstIQR = 0.0
for sc in scenarios {
    let xs = samples[sc.name]!
    let med = median(xs)
    let spread = (xs.max()! - xs.min()!) / med * 100
    let iqr = (quantile(xs, 0.75) - quantile(xs, 0.25)) / med * 100
    medians.append(med)
    worstSpread = max(worstSpread, spread)
    worstIQR = max(worstIQR, iqr)
    scenarioOut[sc.name] = [
        "median_ms": round4(med),
        "min_ms": round4(xs.min()!),
        "max_ms": round4(xs.max()!),
        "spread_pct": round3(spread),
        "iqr_pct": round3(iqr),
        "runs_ms": xs.map(round4),
    ]
}

// MARK: - PNG output (one pass per scenario, read back after timing)

if let outDir = outDir {
    let dir = URL(fileURLWithPath: outDir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let bytesPerRow = size * 4
    guard let readback = device.makeBuffer(length: bytesPerRow * size, options: .storageModeShared) else { fail("readback alloc") }
    for sc in scenarios {
        guard let cb = queue.makeCommandBuffer() else { fail("no command buffer") }
        encodeEyePass(cb, sc, target: targets[0])
        let blit = cb.makeBlitCommandEncoder()!
        blit.copy(from: targets[0], sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: size, height: size, depth: 1),
                  to: readback, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: bytesPerRow * size)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let ptr = readback.contents().bindMemory(to: UInt8.self, capacity: bytesPerRow * size)
        let bytes = Array(UnsafeBufferPointer(start: ptr, count: bytesPerRow * size))
        writePNG(bgra: bytes, width: size, height: size, to: dir.appendingPathComponent("\(sc.name).png"))
    }
    log("wrote \(scenarios.count) PNGs to \(dir.path)")
}

let gitHead: String = {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", repoRoot.path, "rev-parse", "--short", "HEAD"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}()

let summary: [String: Any] = [
    "gpu": device.name,
    "git_head": gitHead,
    "shader": shaderPath,
    "fragment": fragmentName,
    "size": size,
    "time": Double(effectTime),
    "passes_per_buffer": passesPerBuffer,
    "reps": reps,
    "scenarios": scenarioOut,
    "mean_of_medians_ms_per_eye": round4(medians.reduce(0, +) / Double(medians.count)),
    "worst_spread_pct": round3(worstSpread),
    "worst_iqr_pct": round3(worstIQR),
    "other_gpu_clients": otherGPUClients,
    "out": outDir ?? NSNull(),
]
let text = jsonString(summary)
print(text)
if let jsonPath = jsonPath { try? text.write(toFile: jsonPath, atomically: true, encoding: .utf8) }
