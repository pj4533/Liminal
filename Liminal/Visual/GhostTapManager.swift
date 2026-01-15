//
//  GhostTapManager.swift
//  Liminal
//
//  Manages discrete ghost tap lifecycle for the delay echo effect.
//  Creates animated ghost taps that spawn, flow outward in a coherent direction,
//  and fade over time - like audio delay taps.
//

import Foundation

// MARK: - Ghost Tap Data (for shader)

/// Data passed to shader for each ghost tap. Must match Metal struct layout.
struct GhostTapData {
    var progress: Float      // 0 = just spawned, 1 = expired
    var directionX: Float    // normalized direction X component
    var directionY: Float    // normalized direction Y component
    var active: Float        // 1.0 if active, 0.0 if slot empty

    static let inactive = GhostTapData(progress: 0, directionX: 0, directionY: 0, active: 0)
}

// MARK: - Internal Ghost Tap State

/// Internal state for tracking a ghost tap's lifecycle.
private struct GhostTap {
    let spawnTime: Float      // Time when this tap was created
    let direction: Float      // Direction angle in radians
    let lifetime: Float       // How long this tap lives (seconds)

    func progress(at currentTime: Float) -> Float {
        let age = currentTime - spawnTime
        return min(age / lifetime, 1.0)
    }

    func isExpired(at currentTime: Float) -> Bool {
        return currentTime - spawnTime >= lifetime
    }

    func toShaderData(at currentTime: Float) -> GhostTapData {
        let prog = progress(at: currentTime)
        return GhostTapData(
            progress: prog,
            directionX: cos(direction),
            directionY: sin(direction),
            active: 1.0
        )
    }
}

// MARK: - Ghost Tap Manager

/// Manages ghost tap spawning, animation, and expiration.
/// Thread-safe for use from both macOS SwiftUI and visionOS render loops.
final class GhostTapManager {

    // MARK: - Configuration

    /// Maximum number of active ghost taps
    static let maxTaps = 8

    /// How long each tap lives before fully fading (seconds)
    /// Much slower for subtle background effect
    private let tapLifetime: Float = 8.0

    /// Maximum spawn interval when delay is minimum (seconds)
    private let maxSpawnInterval: Float = 5.0

    /// Minimum spawn interval when delay is maximum (seconds)
    private let minSpawnInterval: Float = 2.0

    /// Variance in direction per tap (radians, ~17 degrees)
    private let directionVariance: Float = 0.15

    // MARK: - State

    private var taps: [GhostTap] = []
    private var lastSpawnTime: Float = 0

    // MARK: - Init

    init() {}

    // MARK: - Update

    /// Result of ghost tap update - contains packed data and active count.
    struct UpdateResult {
        let data: [GhostTapData]  // Always exactly 8 elements, active taps packed first
        let activeCount: Int      // Number of active taps (0-8)
    }

    /// Update ghost taps for the current frame.
    /// - Parameters:
    ///   - currentTime: Current animation time in seconds
    ///   - delay: Delay slider value (0-1), controls spawn frequency
    /// - Returns: Array of exactly 8 GhostTapData structs for the shader
    func update(currentTime: Float, delay: Float) -> [GhostTapData] {
        return updateWithCount(currentTime: currentTime, delay: delay).data
    }

    /// Update ghost taps and return both data and active count.
    /// Use this for optimized shader loops that skip inactive slots.
    func updateWithCount(currentTime: Float, delay: Float) -> UpdateResult {
        // Remove expired taps
        taps.removeAll { $0.isExpired(at: currentTime) }

        // Calculate spawn interval from delay (higher delay = faster spawns)
        // delay 0 → maxSpawnInterval (slow), delay 1 → minSpawnInterval (fast)
        let spawnInterval = maxSpawnInterval - (maxSpawnInterval - minSpawnInterval) * delay

        // Spawn new tap if interval elapsed and we have room (and delay > 0)
        if delay > 0.01 && taps.count < Self.maxTaps {
            if currentTime - lastSpawnTime >= spawnInterval {
                let direction = computeDirection(at: currentTime)
                let tap = GhostTap(
                    spawnTime: currentTime,
                    direction: direction,
                    lifetime: tapLifetime
                )
                taps.append(tap)
                lastSpawnTime = currentTime
            }
        }

        let activeCount = min(taps.count, Self.maxTaps)
        return UpdateResult(data: buildShaderData(at: currentTime), activeCount: activeCount)
    }

    /// Reset all ghost taps (call when stopping playback)
    func reset() {
        taps.removeAll()
        lastSpawnTime = 0
    }

    // MARK: - Private

    /// Compute direction for a new tap using flowing drift system.
    /// Base direction slowly rotates over time, with small per-tap variance.
    private func computeDirection(at time: Float) -> Float {
        // Base drift angle: compound sine waves for organic, non-repetitive rotation
        // Slow enough that multiple taps flow in the same direction before changing
        let baseDrift = sin(time * 0.08) * Float.pi + sin(time * 0.03) * 0.5

        // Add small random variance so taps aren't perfectly aligned
        let variance = Float.random(in: -directionVariance...directionVariance)

        return baseDrift + variance
    }

    /// Build shader data array, always exactly maxTaps elements.
    private func buildShaderData(at currentTime: Float) -> [GhostTapData] {
        var data = [GhostTapData]()

        // Add active taps
        for tap in taps.prefix(Self.maxTaps) {
            data.append(tap.toShaderData(at: currentTime))
        }

        // Pad with inactive taps
        while data.count < Self.maxTaps {
            data.append(GhostTapData.inactive)
        }

        return data
    }
}
