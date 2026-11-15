//
//  GenerationBudget.swift
//  Liminal
//
//  Spending cap for Gemini image generation (docs/decisions/images.md D34).
//  Every successfully generated image is recorded with its timestamp in UserDefaults, so the
//  cap survives relaunches. Before each request the generation loop asks `check()`; when the
//  hourly or daily limit is reached the loop shows cached images instead until the window rolls.
//  Limits are user settings (SettingsService.maxImagesPerHour / maxImagesPerDay); 0 = no new images.
//

import Foundation
import os

nonisolated final class GenerationBudget: @unchecked Sendable {

    static let shared = GenerationBudget()

    enum Keys {
        static let ledger = "visual.generationLedger"
        static let perHour = "visual.maxImagesPerHour"
        static let perDay = "visual.maxImagesPerDay"
    }

    static let defaultPerHour = 20
    static let defaultPerDay = 100

    enum Verdict: Equatable {
        case allowed
        /// Limit reached; generation may resume at `resumeAt`.
        case limited(resumeAt: Date, perHour: Bool)
    }

    struct Usage: Equatable {
        var lastHour: Int
        var lastDay: Int
        var perHour: Int
        var perDay: Int
    }

    private let defaults: UserDefaults
    private let lock = OSAllocatedUnfairLock()
    private var stamps: [TimeInterval]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.stamps = (defaults.array(forKey: Keys.ledger) as? [Double]) ?? []
    }

    var perHour: Int { limit(Keys.perHour, Self.defaultPerHour) }
    var perDay: Int { limit(Keys.perDay, Self.defaultPerDay) }

    private func limit(_ key: String, _ fallback: Int) -> Int {
        defaults.object(forKey: key) == nil ? fallback : max(0, defaults.integer(forKey: key))
    }

    func check(now: Date = Date()) -> Verdict {
        let hourLimit = perHour, dayLimit = perDay
        return lock.withLockUnchecked {
            prune(now)
            let t = now.timeIntervalSince1970
            let hour = stamps.filter { $0 > t - 3600 }
            if stamps.count >= dayLimit {
                // Oldest stamp that must age out for the count to drop below the limit.
                let idx = stamps.count - max(dayLimit, 1)
                let resume = stamps.isEmpty ? now.addingTimeInterval(3600) : Date(timeIntervalSince1970: stamps[max(0, idx)] + 86_400)
                return .limited(resumeAt: resume, perHour: false)
            }
            if hour.count >= hourLimit {
                let idx = hour.count - max(hourLimit, 1)
                let resume = hour.isEmpty ? now.addingTimeInterval(600) : Date(timeIntervalSince1970: hour[max(0, idx)] + 3600)
                return .limited(resumeAt: resume, perHour: true)
            }
            return .allowed
        }
    }

    /// Record one generated (billed) image.
    func record(now: Date = Date()) {
        lock.withLockUnchecked {
            prune(now)
            stamps.append(now.timeIntervalSince1970)
            defaults.set(stamps, forKey: Keys.ledger)
        }
    }

    func usage(now: Date = Date()) -> Usage {
        let hourLimit = perHour, dayLimit = perDay
        return lock.withLockUnchecked {
            prune(now)
            let t = now.timeIntervalSince1970
            return Usage(lastHour: stamps.filter { $0 > t - 3600 }.count, lastDay: stamps.count,
                         perHour: hourLimit, perDay: dayLimit)
        }
    }

    private func prune(_ now: Date) {
        let cutoff = now.timeIntervalSince1970 - 86_400
        if let first = stamps.first, first <= cutoff {
            stamps.removeAll { $0 <= cutoff }
            defaults.set(stamps, forKey: Keys.ledger)
        }
    }
}
