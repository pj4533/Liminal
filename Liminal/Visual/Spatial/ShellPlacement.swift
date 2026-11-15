//
//  ShellPlacement.swift
//  Liminal
//
//  Placement and comfort logic of the visionOS spatial shell (docs/plans/spatial.md sections 3
//  and 5). Pure Swift, no RealityKit or ARKit, so it is unit tested on macOS
//  (LiminalTests/SpatialShellTests.swift). HeadPoseProvider feeds it head poses on visionOS.
//

import Foundation
import simd

nonisolated enum ShellPlacement {

    /// Shell centre when no head pose is available (simulator, ARKit not running): standing eye height.
    static let fallbackCentre = SIMD3<Float>(0, 1.5, 0)

    /// Head distance from the shell centre (metres) that starts a re-centre.
    static let recentreStart: Float = 0.35
    /// Distance at which a re-centre stops (hysteresis, so the shell does not creep after the head).
    static let recentreStop: Float = 0.05
    /// Time constant of the re-centre ease, seconds.
    static let recentreTau: Float = 3

    /// Yaw (radians about +Y, RealityKit convention: positive turns -Z toward -X) of the direction a
    /// transform's -Z axis points, projected on the floor. 0 when looking straight down/up.
    static func yaw(of transform: simd_float4x4) -> Float {
        let forward = -SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        let flat = SIMD2(forward.x, forward.z)
        guard simd_length(flat) > 1e-4 else { return 0 }
        // Rotating -Z by yaw y about +Y gives (-sin y, 0, -cos y).
        return atan2(-flat.x, -flat.y)
    }

    /// Head position (translation) of a transform.
    static func position(of transform: simd_float4x4) -> SIMD3<Float> {
        SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }

    /// Frame-rate independent one-pole factor for a time constant.
    static func easeFactor(dt: Float, tau: Float) -> Float {
        guard tau > 0 else { return 1 }
        return 1 - exp(-max(dt, 0) / tau)
    }
}

/// Slow re-centre: inside 0.35 m the shell stays put and head motion gives true parallax; beyond it
/// the centre eases toward the head (3 s time constant) until it is within 5 cm again.
nonisolated struct ShellRecentre: Equatable {
    var centre: SIMD3<Float>
    private(set) var isRecentring = false

    init(centre: SIMD3<Float>) { self.centre = centre }

    /// Advance by `dt` seconds with the head at `head`. Returns the new centre.
    @discardableResult
    mutating func update(head: SIMD3<Float>, dt: Float) -> SIMD3<Float> {
        let distance = simd_distance(head, centre)
        if !isRecentring && distance > ShellPlacement.recentreStart { isRecentring = true }
        if isRecentring {
            centre += (head - centre) * ShellPlacement.easeFactor(dt: dt, tau: ShellPlacement.recentreTau)
            if simd_distance(head, centre) < ShellPlacement.recentreStop { isRecentring = false }
        }
        return centre
    }
}

/// One-pole smoothing of the Depth setting, so dragging the slider (or a reset) reshapes the
/// relief over about half a second instead of in one frame (comfort).
nonisolated struct DepthSettingSmoother: Equatable {
    static let tau: Float = 0.5
    private(set) var value: Float?

    mutating func next(target: Float, dt: Float) -> Float {
        let t = min(max(target, 0), 1)
        guard let v = value else { value = t; return t }
        let n = v + (t - v) * ShellPlacement.easeFactor(dt: dt, tau: Self.tau)
        value = n
        return n
    }
}

extension ShellLayout {
    /// Breathing amplitude range, metres: calm at rest, up to the 3 cm comfort cap with the music.
    static let breathingCalm: Float = 0.02

    /// Breathing amplitude for the frame: the slow geometry pulse and scene energy of the music push
    /// it from 2 cm toward the 3 cm cap. `amount` is the music coupling's master wet (0 when "Sync
    /// visuals to music" is off or the music is silent).
    static func breathingAmplitude(amount: Float, energy: Float, pulseMotion: Float) -> Float {
        let a = min(max(amount, 0), 1)
        let drive = min(max(0.5 * energy + 0.5 * pulseMotion, 0), 1)
        return breathingCalm + (breathingAmplitude - breathingCalm) * a * drive
    }
}
