//
//  SpatialShellMesh.swift
//  Liminal
//
//  One tile of the spatial shell (ShellLayout) as a LowLevelMesh. The three tile entities share it.
//  Each frame the CPU writes every vertex: base position times a radial scale made of
//  relief (inverse-radius field q from DepthReliefField, blended previous -> current, times k) and
//  breathing (the old dome's four-sine wave, ShellLayout.breathing). Replaces LowLevelDomeMesh.
//
//  Vertex layout (40 bytes): position float3, normal float3, uv0 float2 (u, mirrored v),
//  uv1 float2 (band coordinate for the vertical fade, 0).
//
//  Per-frame work is a few hundred vDSP calls over the 13.7k-vertex grid (no per-vertex Swift
//  loop), so it is cheap in the unoptimised Debug build (simulator, perf harness) as well: a plain
//  loop measured ~1.6 ms there, and `@_optimize(speed)` is ignored at -Onone.
//

#if os(visionOS)

import RealityKit
import Metal
import Accelerate
import OSLog

@MainActor
final class SpatialShellMesh {

    static let vertexStride = 40
    private static let floatsPerVertex = 10

    let lowLevelMesh: LowLevelMesh
    let meshResource: MeshResource

    private let cols = ShellLayout.vertexColumns
    private let rows = ShellLayout.vertexRows
    private let vertexCount = ShellLayout.vertexCount

    // Constant per-vertex data (allocated once, freed in deinit).
    /// Base-radius positions, 3 floats per vertex.
    private let base: UnsafeMutablePointer<Float>
    /// Normal + uv0 + uv1, 7 floats per vertex.
    private let tail: UnsafeMutablePointer<Float>
    /// sin / cos of 8 x (distance from the image centre in uv), per vertex (breathing radial term).
    private let radSin8: UnsafeMutablePointer<Float>
    private let radCos8: UnsafeMutablePointer<Float>
    /// Per-column u, sin(4u), cos(4u); per-row clamped v and band taper (1 - band).
    private let colU: [Float]
    private let colSin4: UnsafeMutablePointer<Float>
    private let colCos4: UnsafeMutablePointer<Float>
    private let rowV: [Float]
    private let rowTaper: [Float]

    // Per-frame scratch.
    private let colTerm: UnsafeMutablePointer<Float>
    private let scale: UnsafeMutablePointer<Float>
    private let qBlend: UnsafeMutablePointer<Float>
    private let zeros: UnsafeMutablePointer<Float>

    init?() {
        let cols = ShellLayout.vertexColumns, rows = ShellLayout.vertexRows
        let n = ShellLayout.vertexCount
        let indexCount = ShellLayout.indexCount

        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexCapacity = n
        descriptor.vertexAttributes = [
            .init(semantic: .position, format: .float3, offset: 0),
            .init(semantic: .normal, format: .float3, offset: 12),
            .init(semantic: .uv0, format: .float2, offset: 24),
            .init(semantic: .uv1, format: .float2, offset: 32)
        ]
        descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferOffset: 0, bufferStride: Self.vertexStride)]
        descriptor.indexCapacity = indexCount
        descriptor.indexType = .uint32

        guard let mesh = try? LowLevelMesh(descriptor: descriptor) else {
            LMLog.visual.error("❌ SpatialShellMesh: failed to create LowLevelMesh")
            return nil
        }
        lowLevelMesh = mesh

        base = .allocate(capacity: n * 3)
        tail = .allocate(capacity: n * 7)
        radSin8 = .allocate(capacity: n)
        radCos8 = .allocate(capacity: n)
        colSin4 = .allocate(capacity: cols)
        colCos4 = .allocate(capacity: cols)
        colTerm = .allocate(capacity: cols)
        scale = .allocate(capacity: n)
        qBlend = .allocate(capacity: n)
        zeros = .allocate(capacity: n)
        zeros.initialize(repeating: 0, count: n)

        let us = (0..<cols).map { ShellLayout.column($0).u }
        let rowInfo = (0..<rows).map { ShellLayout.row($0) }
        colU = us
        rowV = rowInfo.map { min(max($0.v, 0), 1) }
        rowTaper = rowInfo.map { 1 - $0.band }
        for c in 0..<cols {
            colSin4[c] = sin(us[c] * 4)
            colCos4[c] = cos(us[c] * 4)
        }
        for r in 0..<rows {
            let row = rowInfo[r]
            let v = min(max(row.v, 0), 1)
            for c in 0..<cols {
                let i = r * cols + c
                let col = ShellLayout.column(c)
                let p = ShellLayout.basePosition(azimuth: col.azimuth, elevation: row.elevation)
                let nrm = simd_normalize(SIMD3<Float>(-p.x, 0, -p.z))
                base[i * 3] = p.x; base[i * 3 + 1] = p.y; base[i * 3 + 2] = p.z
                let t: [Float] = [nrm.x, nrm.y, nrm.z, col.u, row.sampleV, row.band, 0]
                for j in 0..<7 { tail[i * 7 + j] = t[j] }
                let dh = col.u - 0.5, dv = v - 0.5
                let d = (dh * dh + dv * dv).squareRoot()
                radSin8[i] = sin(d * 8)
                radCos8[i] = cos(d * 8)
            }
        }

        var indices = [UInt32]()
        indices.reserveCapacity(indexCount)
        for r in 0..<(rows - 1) {
            for c in 0..<(cols - 1) {
                let bl = UInt32(r * cols + c), br = bl + 1
                let tl = UInt32((r + 1) * cols + c), tr = tl + 1
                // Same winding as the old dome (faces the viewer); mirrored tiles flip it, so the
                // material draws both faces.
                indices += [bl, br, tl, br, tr, tl]
            }
        }
        mesh.withUnsafeMutableIndices { raw in
            indices.withUnsafeBytes { raw.baseAddress!.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }

        let e: Float = 7
        mesh.parts.replaceAll([
            LowLevelMesh.Part(indexOffset: 0, indexCount: indexCount, topology: .triangle, materialIndex: 0,
                              bounds: BoundingBox(min: [-e, -e, -e], max: [e, e, e]))
        ])

        do {
            meshResource = try MeshResource(from: mesh)
        } catch {
            LMLog.visual.error("❌ SpatialShellMesh: MeshResource failed: \(error.localizedDescription)")
            return nil
        }
        update(previous: nil, current: nil, weight: 1, k: 0, time: 0)
        LMLog.visual.info("✅ SpatialShellMesh: \(n) vertices, \(indexCount / 3) triangles per tile, stride=\(Self.vertexStride)")
    }

    deinit {
        for p in [base, tail, radSin8, radCos8, colSin4, colCos4, colTerm, scale, qBlend, zeros] { p.deallocate() }
    }

    /// Write every vertex. `previous` / `current` are per-vertex q fields (DepthReliefField.q,
    /// vertexCount values; nil or wrong size = flat). q = previous + (current - previous) * weight,
    /// radius = 1 / (1/rho0 + k * q * inverseSpan) + breathing.
    func update(previous: [Float]?, current: [Float]?, weight: Float, k: Float, time: Float) {
        let n = vertexCount
        let N = vDSP_Length(n), C = vDSP_Length(cols)
        let rho0 = ShellLayout.baseRadius
        let t = time * ShellLayout.breathingSpeed
        let ampOverRho = ShellLayout.breathingAmplitude / rho0

        // Breathing (ShellLayout.breathing), split by angle-sum identities:
        //   wave = 0.4 sin(6u + t) + 0.3 sin(5v + 0.7t)
        //        + 0.2 [sin4u cos(4v + t/2) + cos4u sin(4v + t/2)]
        //        + 0.1 [sin8d cos(0.8t) - cos8d sin(0.8t)]
        //   scale = 1 + wave * amp/rho0 * (1 - band)
        var a = 0.1 * cos(t * 0.8), b = -0.1 * sin(t * 0.8)
        vDSP_vsmsma(radSin8, 1, &a, radCos8, 1, &b, scale, 1, N)  // radial term
        for c in 0..<cols { colTerm[c] = 0.4 * sin(colU[c] * 6 + t) }
        for r in 0..<rows {
            let row = scale + r * cols
            var rc = 0.2 * cos(rowV[r] * 4 + t * 0.5), rs = 0.2 * sin(rowV[r] * 4 + t * 0.5)
            vDSP_vadd(row, 1, colTerm, 1, row, 1, C)
            vDSP_vsma(colSin4, 1, &rc, row, 1, row, 1, C)
            vDSP_vsma(colCos4, 1, &rs, row, 1, row, 1, C)
            var tp = rowTaper[r] * ampOverRho
            var offset = 1 + 0.3 * sin(rowV[r] * 5 + t * 0.7) * tp
            vDSP_vsmsa(row, 1, &tp, &offset, row, 1, C)
        }

        // Relief: scale += 1 / (1 + rho0 k span q) - 1
        let prevOK = previous?.count == n, curOK = current?.count == n
        if k != 0 && (prevOK || curOK) {
            var w = min(max(weight, 0), 1)
            let out = qBlend
            let blend = { (p: UnsafePointer<Float>, c: UnsafePointer<Float>) in
                vDSP_vintb(p, 1, c, 1, &w, out, 1, N)
            }
            switch (prevOK, curOK) {
            case (true, true):
                previous!.withUnsafeBufferPointer { p in current!.withUnsafeBufferPointer { c in blend(p.baseAddress!, c.baseAddress!) } }
            case (true, false):
                previous!.withUnsafeBufferPointer { p in blend(p.baseAddress!, zeros) }
            default:
                current!.withUnsafeBufferPointer { c in blend(zeros, c.baseAddress!) }
            }
            var kSpan = rho0 * k * ShellLayout.inverseSpan, one: Float = 1, minusOne: Float = -1
            vDSP_vsmsa(qBlend, 1, &kSpan, &one, qBlend, 1, N)   // 1 + kSpan q
            var count = Int32(n)
            vvrecf(qBlend, qBlend, &count)                      // 1 / (...)
            vDSP_vadd(scale, 1, qBlend, 1, scale, 1, N)
            vDSP_vsadd(scale, 1, &minusOne, scale, 1, N)
        }

        let base = self.base, tail = self.tail, scale = self.scale
        lowLevelMesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            guard raw.count >= n * Self.vertexStride,
                  let dst = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            let stride = vDSP_Stride(Self.floatsPerVertex)
            for j in 0..<3 { vDSP_vmul(base + j, 3, scale, 1, dst + j, stride, N) }
            var zero: Float = 0
            for j in 0..<7 { vDSP_vsadd(tail + j, 7, &zero, dst + 3 + j, stride, N) }
        }
    }
}

#endif
