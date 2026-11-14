//
//  GPUTimingStats.swift
//  Liminal
//
//  Cheap per-pass GPU timing using MTLCommandBuffer.gpuStartTime/gpuEndTime.
//
//  Usage (render thread):
//      let frame = stats.beginFrame()            // once per frame, before encoding
//      stats.track(commandBuffer, pass: "eyeL")  // before commit(); adds a completed handler
//  Usage (logging):
//      let snap = stats.drain()                  // aggregates since last drain, resets
//
//  Per-frame GPU time = sum of the GPU durations of all command buffers tagged with the
//  same frame id (the "GPU busy" cost of the frame; passes on one queue run back to back).
//  Completion handlers on a single queue fire in commit order, so a frame is finalized as
//  soon as the first buffer of the next frame completes. Overhead: one closure + one
//  uncontended unfair-lock acquire per command buffer.
//

import Foundation
import Metal
import os

nonisolated final class GPUTimingStats: @unchecked Sendable {

    struct PassStat {
        let name: String
        let avgMs: Double
        let maxMs: Double
        let count: Int
    }

    struct Snapshot {
        let frames: Int
        let avgMs: Double
        let p95Ms: Double
        let maxMs: Double
        let passes: [PassStat]
        let invalidSamples: Int

        /// Machine-parsable fragment appended to the PERF log lines.
        var logFragment: String {
            guard frames > 0 else {
                return "gpu n=0 (no timestamps\(invalidSamples > 0 ? ", invalid=\(invalidSamples)" : ""))"
            }
            let passStr = passes
                .map { "\($0.name)=\(Self.f($0.avgMs))/\(Self.f($0.maxMs))" }
                .joined(separator: " ")
            return "gpu avg=\(Self.f(avgMs))ms p95=\(Self.f(p95Ms))ms max=\(Self.f(maxMs))ms n=\(frames) passes[avg/max ms]: \(passStr)"
        }

        private static func f(_ v: Double) -> String { String(format: "%.3f", v) }
    }

    private struct PassAccum {
        var sum: Double = 0
        var max: Double = 0
        var count: Int = 0
    }

    private let lock = OSAllocatedUnfairLock()

    // Guarded by `lock`
    private var passOrder: [String] = []
    private var passAccum: [String: PassAccum] = [:]
    private var frameTotals: [Double] = []
    private var currentFrameId: UInt64 = .max
    private var currentFrameSum: Double = 0
    private var invalidSamples = 0

    // Only touched on the encoding thread
    private var encodeFrameId: UInt64 = 0

    init() {
        frameTotals.reserveCapacity(1024)
    }

    /// Start a new frame. Call on the encoding thread before tracking that frame's buffers.
    @discardableResult
    func beginFrame() -> UInt64 {
        encodeFrameId &+= 1
        return encodeFrameId
    }

    /// Attach a completed handler that records this command buffer's GPU time
    /// under `pass` for the current frame. Call before `commit()`.
    func track(_ commandBuffer: MTLCommandBuffer, pass: String) {
        let frame = encodeFrameId
        commandBuffer.addCompletedHandler { [weak self] cb in
            let start = cb.gpuStartTime
            let end = cb.gpuEndTime
            self?.record(pass: pass, frame: frame, start: start, end: end)
        }
    }

    private func record(pass: String, frame: UInt64, start: CFTimeInterval, end: CFTimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard start > 0, end >= start else {
            invalidSamples += 1
            return
        }
        let ms = (end - start) * 1000

        if passAccum[pass] == nil { passOrder.append(pass) }
        var acc = passAccum[pass, default: PassAccum()]
        acc.sum += ms
        acc.max = Swift.max(acc.max, ms)
        acc.count += 1
        passAccum[pass] = acc

        if frame != currentFrameId {
            if currentFrameId != .max { frameTotals.append(currentFrameSum) }
            currentFrameId = frame
            currentFrameSum = 0
        }
        currentFrameSum += ms
    }

    /// Aggregate everything recorded since the last drain and reset. The frame whose
    /// buffers are still completing carries over to the next drain.
    func drain() -> Snapshot {
        lock.lock()
        let totals = frameTotals
        let order = passOrder
        let accum = passAccum
        let invalid = invalidSamples
        frameTotals.removeAll(keepingCapacity: true)
        passAccum.removeAll(keepingCapacity: true)
        passOrder.removeAll(keepingCapacity: true)
        invalidSamples = 0
        lock.unlock()

        let passes = order.sorted().compactMap { name -> PassStat? in
            guard let a = accum[name], a.count > 0 else { return nil }
            return PassStat(name: name, avgMs: a.sum / Double(a.count), maxMs: a.max, count: a.count)
        }
        guard !totals.isEmpty else {
            return Snapshot(frames: 0, avgMs: 0, p95Ms: 0, maxMs: 0, passes: passes, invalidSamples: invalid)
        }
        let sorted = totals.sorted()
        let avg = totals.reduce(0, +) / Double(totals.count)
        return Snapshot(
            frames: totals.count,
            avgMs: avg,
            p95Ms: Self.percentile(sorted, 0.95),
            maxMs: sorted.last ?? 0,
            passes: passes,
            invalidSamples: invalid
        )
    }

    /// Nearest-rank percentile of an ascending-sorted array.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[Swift.min(Swift.max(rank, 0), sorted.count - 1)]
    }
}
