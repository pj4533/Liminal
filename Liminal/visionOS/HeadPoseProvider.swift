//
//  HeadPoseProvider.swift
//  Liminal
//
//  Head pose for placing the spatial shell (docs/plans/spatial.md section 5): ARKit world tracking,
//  queried once at entry (position + yaw) and then a few times a second for the slow re-centre
//  (ShellRecentre). When world tracking is unavailable (simulator, provider not supported or not
//  running) every query returns nil and the shell stays at ShellPlacement.fallbackCentre, facing
//  forward.
//

#if os(visionOS)

import ARKit
import QuartzCore
import OSLog

@MainActor
final class HeadPoseProvider {

    private let session = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private var isRunning = false

    /// Start world tracking. Safe to call when unsupported (logs and stays idle).
    func start() async {
        guard WorldTrackingProvider.isSupported else {
            LMLog.visual.info("🧭 HeadPose: world tracking not supported here, using the fallback centre")
            return
        }
        do {
            try await session.run([worldTracking])
            isRunning = true
            LMLog.visual.info("🧭 HeadPose: world tracking running")
        } catch {
            LMLog.visual.warning("🧭 HeadPose: world tracking failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        guard isRunning else { return }
        session.stop()
        isRunning = false
    }

    /// Current head transform in the immersive space's origin, or nil when not tracked.
    func headTransform() -> simd_float4x4? {
        guard isRunning, worldTracking.state == .running,
              let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()),
              anchor.isTracked else { return nil }
        return anchor.originFromAnchorTransform
    }

    /// Entry pose: waits up to `timeout` seconds for the first tracked pose (tracking needs a few
    /// frames after `run`), else nil.
    func entryPose(timeout: Double = 1.0) async -> (position: SIMD3<Float>, yaw: Float)? {
        guard isRunning else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let t = headTransform() {
                return (ShellPlacement.position(of: t), ShellPlacement.yaw(of: t))
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }
}

#endif
