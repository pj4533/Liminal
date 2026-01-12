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
//  - Background pipeline: Calls `store()` from any thread (no MainActor!)
//  - Render loop: Calls `load()` from any thread (no MainActor!)
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

/// Thread-safe buffer for passing CGImages from background pipeline to render loop.
/// Designed for high-frequency reads (90fps) with infrequent writes.
///
/// IMPORTANT: Stores CGImage directly to avoid any UIImage/NSImage involvement.
/// CGImage operations are fully thread-safe and don't require MainActor.
///
/// Thread Safety: All mutable state is protected by `lock`. The `nonisolated(unsafe)`
/// annotation tells the compiler we're managing thread safety manually via the lock,
/// which is necessary because OSAllocatedUnfairLock.withLock uses @Sendable closures.
final class AtomicImageBuffer: @unchecked Sendable {

    // MARK: - Storage (protected by lock)

    /// The current CGImage. Protected by lock.
    /// nonisolated(unsafe) because we manage thread safety via lock.
    nonisolated(unsafe) private var _current: CGImage?

    /// The next CGImage (for preloading morphs). Protected by lock.
    nonisolated(unsafe) private var _next: CGImage?

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
    func storeCurrent(_ image: CGImage) {
        let (gen, wasEmpty, count) = lock.withLock {
            let wasEmpty = self._current == nil
            self._current = image
            self._generation &+= 1
            self._storeCount += 1
            return (self._generation, wasEmpty, self._storeCount)
        }
        // Log OUTSIDE lock using OSLog (visible in Console.app)
        let selfId = String(describing: ObjectIdentifier(self))
        LMLog.visual.info("📦 AtomicBuffer STORE: \(image.width)x\(image.height), gen=\(gen), wasEmpty=\(wasEmpty), id=\(selfId)")
    }

    /// Store a new next CGImage (for morph preloading). Called from background pipeline.
    func storeNext(_ image: CGImage?) {
        lock.withLock {
            self._next = image
            if let img = image {
                print("📦 [AtomicBuffer] STORE next: \(img.width)x\(img.height)")
            }
        }
    }

    /// Store both current and next atomically.
    func store(current: CGImage, next: CGImage?) {
        lock.withLock {
            let wasEmpty = self._current == nil
            self._current = current
            self._next = next
            self._generation &+= 1
            self._storeCount += 1
            print("📦 [AtomicBuffer] STORE both: current=\(current.width)x\(current.height), next=\(next != nil), gen=\(self._generation), wasEmpty=\(wasEmpty)")
        }
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

    /// Load the next CGImage. Called for morph preloading.
    func loadNext() -> CGImage? {
        lock.withLock {
            _next
        }
    }

    /// Load both current and next atomically.
    func load() -> (current: CGImage?, next: CGImage?) {
        lock.withLock {
            (_current, _next)
        }
    }

    /// Get the current generation counter.
    /// Useful for detecting if the image has changed since last check.
    func generation() -> UInt64 {
        lock.withLock {
            _generation
        }
    }

    /// Load current CGImage and generation atomically.
    /// Allows render loop to detect changes efficiently.
    func loadWithGeneration() -> (image: CGImage?, generation: UInt64) {
        lock.withLock {
            (_current, _generation)
        }
    }

    /// Clear all stored images.
    func clear() {
        lock.withLock {
            _current = nil
            _next = nil
            _generation &+= 1
        }
    }
}
