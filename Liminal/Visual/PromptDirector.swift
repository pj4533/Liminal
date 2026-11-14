//
//  PromptDirector.swift
//  Liminal
//
//  App-side wrapper around the pure PromptBuilder: owns the history, persists it
//  to UserDefaults so a relaunch does not replay the same style, and logs each prompt.
//  Lock-protected class, not an actor (MainActor starvation on visionOS).
//

import Foundation
import os.lock
import OSLog

nonisolated final class PromptDirector: @unchecked Sendable {

    static let historyKey = "images.promptHistory"

    private let builder: PromptBuilder
    private let defaults: UserDefaults
    private let lock = OSAllocatedUnfairLock()
    nonisolated(unsafe) private var history: PromptHistory

    init(builder: PromptBuilder = PromptBuilder(), defaults: UserDefaults = .standard) {
        self.builder = builder
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode(PromptHistory.self, from: data) {
            history = saved
        } else {
            history = PromptHistory()
        }
    }

    func next() -> PromptSpec {
        let (spec, snapshot) = lock.withLock {
            var rng = SystemRandomNumberGenerator()
            let spec = builder.next(history: &history, using: &rng)
            return (spec, history)
        }
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.historyKey)
        }
        let series = spec.series.map { " series=\($0.kind.rawValue) \($0.index + 1)/\($0.length)" } ?? ""
        LMLog.prompt.info("🎨 [\(spec.styleID) / \(spec.paletteID) / \(spec.subjectID) / \(spec.transformationID)\(series)] \(spec.text)")
        return spec
    }

    /// Called by Clear All Images.
    func reset() {
        lock.withLock { history = PromptHistory() }
        defaults.removeObject(forKey: Self.historyKey)
    }
}
