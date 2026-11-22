//
//  AtomicImageBuffer.swift
//  Liminal
//
//  A lock-free, thread-safe CGImage buffer for communicating between
//  a background image pipeline and a 90fps render loop.
//
//  ARCHITECTURE RATIONALE:
//  On visionOS, TimelineView(.animation) runs at 90fps and consumes ALL
//  MainActor capacity. Any code waiting for MainActor (like @Published
//  property updates) will be starved indefinitely.
//
//  This buffer provides a MainActor-free communication channel:
//  - Image queue: calls `storeCurrent()` from any thread (no MainActor!)
//  - Render loop: calls `loadCurrent()` from any thread (no MainActor!)
//
//  CRITICAL: Uses CGImage directly, NOT PlatformImage (UIImage/NSImage).
//  CGImage is a Core Graphics type that is fully thread-safe.
//  This eliminates ALL MainActor dependencies from the critical path.
//
//  Uses os_unfair_lock for minimal overhead (no priority inversion,
//  no syscalls in the uncontended case).
//

import Foundation
import CoreGraphics
import os.lock
import OSLog

/// Thread-safe buffer for passing CGImages from the image queue to the render loop.
/// Designed for high-frequency reads (90fps) with infrequent writes.
///
/// IMPORTANT: Stores CGImage directly to avoid any UIImage/NSImage involvement.
/// CGImage operations are fully thread-safe and don't require MainActor.
///
/// Thread Safety: All mutable state is protected by `lock`. The `nonisolated(unsafe)`
/// annotation tells the compiler we're managing thread safety manually via the lock,
/// which is necessary because OSAllocatedUnfairLock.withLock uses @Sendable closures.
nonisolated final class AtomicImageBuffer: @unchecked Sendable {

    // MARK: - Storage (protected by lock)

    /// The current CGImage. Protected by lock.
    /// nonisolated(unsafe) because we manage thread safety via lock.
    nonisolated(unsafe) private var _current: CGImage?

    /// The current depth map CGImage (grayscale, 0=far, 1=near). Protected by lock.
    nonisolated(unsafe) private var _currentDepth: CGImage?

    private var currentID: UUID?
    func displayedID() -> UUID? { lock.withLock { currentID } }

    /// Generation counter for depth maps - independent from image generation.
    nonisolated(unsafe) private var _depthGeneration: UInt64 = 0

    /// Metadata for `_current` (credit, measured saturation, openness). Protected by lock.
    nonisolated(unsafe) private var _currentMetadata: ImageMetadata?

    /// Generation counter - increments on each store, allows detecting changes.
    nonisolated(unsafe) private var _generation: UInt64 = 0

    /// Lock protecting all state
    private let lock = OSAllocatedUnfairLock()

    // MARK: - Logging

    /// Log counter to avoid spamming on high-frequency operations
    nonisolated(unsafe) private var _storeCount: Int = 0
    nonisolated(unsafe) private var _loadCount: Int = 0

    // MARK: - Public API

    /// Store a new current CGImage. Called from background pipeline.
    /// This is O(1), fully thread-safe, and does NOT require MainActor.
    func storeCurrent(_ image: CGImage, metadata: ImageMetadata? = nil, id: UUID? = nil) {
        let (gen, wasEmpty, _) = lock.withLock {
            let wasEmpty = self._current == nil
            self._current = image
            self._currentMetadata = metadata
            self.currentID = id ?? metadata?.id
            self._generation &+= 1
            self._storeCount += 1
            return (self._generation, wasEmpty, self._storeCount)
        }
        // Log OUTSIDE lock using OSLog (visible in Console.app)
        let selfId = String(describing: ObjectIdentifier(self))
        LMLog.visual.info("📦 AtomicBuffer STORE: \(image.width)x\(image.height), gen=\(gen), wasEmpty=\(wasEmpty), id=\(selfId)")
    }

    /// Load the current CGImage. Called from render loop.
    /// Returns nil if no image has been stored yet.
    /// Fully thread-safe, no MainActor required.
    func loadCurrent() -> CGImage? {
        let (image, gen, count) = lock.withLock {
            self._loadCount += 1
            return (self._current, self._generation, self._loadCount)
        }
        // Log OUTSIDE lock using OSLog - every 300 loads (~5 seconds at 60fps)
        if count % 300 == 1 {
            let selfId = String(describing: ObjectIdentifier(self))
            if let img = image {
                LMLog.visual.info("📦 AtomicBuffer LOAD: \(img.width)x\(img.height), gen=\(gen), loadCount=\(count), id=\(selfId)")
            } else {
                LMLog.visual.warning("📦 AtomicBuffer LOAD: nil! gen=\(gen), loadCount=\(count), id=\(selfId)")
            }
        }
        return image
    }

    /// Clear all stored images.
    func clear() {
        lock.withLock {
            _current = nil
            _currentDepth = nil
            _currentMetadata = nil
            currentID = nil
            _generation &+= 1
            _depthGeneration &+= 1
        }
    }

    // MARK: - Depth Map Storage

    /// Store a depth map CGImage. Called from background depth inference.
    func storeDepth(_ depth: CGImage) {
        let gen = lock.withLock {
            self._currentDepth = depth
            self._depthGeneration &+= 1
            return self._depthGeneration
        }
        LMLog.visual.info("🗺️ AtomicBuffer STORE depth: \(depth.width)x\(depth.height), depthGen=\(gen)")
    }

    /// Load depth map and its generation counter atomically.
    func loadDepthWithGeneration() -> (depth: CGImage?, generation: UInt64) {
        lock.withLock {
            (_currentDepth, _depthGeneration)
        }
    }

    // MARK: - Metadata

    /// Metadata for the image currently displayed (nil for images without a sidecar).
    func loadCurrentMetadata() -> ImageMetadata? {
        lock.withLock { _currentMetadata }
    }

    /// Current image and the generation counter, read atomically.
    func loadCurrentWithGeneration() -> (image: CGImage?, generation: UInt64) {
        lock.withLock { (_current, _generation) }
    }

    /// Check if there's a current image to display.
    func hasCurrent() -> Bool {
        lock.withLock {
            self._current != nil
        }
    }
}
