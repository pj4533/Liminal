//
//  ModelRouter.swift
//  Liminal
//
//  Picks the model for each request and handles failures (docs/decisions/images.md D2).
//  Pure value type: callers pass `now`, so it is unit-testable without a clock.
//
//  Rules:
//  - Safety block / empty response: keep the model (it is a prompt problem); the caller
//    draws a new prompt. After 3 in a row, pause 10s.
//  - 429, 5xx, 404, network: cool that model down (30s doubling to 10 min) and use the
//    next one in the chain; the primary is retried when its cooldown ends.
//  - 402 (billing): pause every model on the project (1 min doubling to 10 min).
//  - Every model cooling down: model(...) returns nil and the queue recycles cached images.
//

import Foundation

nonisolated struct ModelRouter: Sendable {

    static let baseCooldown: TimeInterval = 30
    static let maxCooldown: TimeInterval = 600
    static let initialBillingCooldown: TimeInterval = 60
    static let safetyBlocksBeforePause = 3
    static let safetyPause: TimeInterval = 10

    let config: ImageGenerationConfig
    private var cooldownUntil: [String: Date] = [:]
    private var failureCounts: [String: Int] = [:]
    private var consecutiveSafetyBlocks = 0
    private var pauseUntil: Date?
    private var billingPauseUntil: Date?
    private var nextBillingCooldown = ModelRouter.initialBillingCooldown

    init(config: ImageGenerationConfig) {
        self.config = config
    }

    func isCoolingDown(_ model: String, now: Date) -> Bool {
        guard let until = cooldownUntil[model] else { return false }
        return until > now
    }

    func cooldownRemaining(_ model: String, now: Date) -> TimeInterval {
        max(0, (cooldownUntil[model] ?? now).timeIntervalSince(now))
    }

    /// Model for this prompt, or nil when every model is cooling down.
    mutating func model<R: RandomNumberGenerator>(for spec: PromptSpec, now: Date, using rng: inout R) -> String? {
        guard !isBillingPaused(now: now) else { return nil }
        if spec.needsStrongSurreal, config.surrealModelShare > 0,
           !isCoolingDown(config.surrealModel, now: now),
           RandomDraw.unit(&rng) < config.surrealModelShare {
            return config.surrealModel
        }
        return config.chain.first { !isCoolingDown($0, now: now) }
    }

    mutating func recordSuccess(model: String) {
        cooldownUntil[model] = nil
        failureCounts[model] = 0
        consecutiveSafetyBlocks = 0
        pauseUntil = nil
        billingPauseUntil = nil
        nextBillingCooldown = Self.initialBillingCooldown
    }

    mutating func recordFailure(model: String, error: GeminiError, now: Date) {
        switch error {
        case .http(402, _):
            billingPauseUntil = now.addingTimeInterval(nextBillingCooldown)
            nextBillingCooldown = min(Self.maxCooldown, nextBillingCooldown * 2)
        case .noImage:
            consecutiveSafetyBlocks += 1
            if consecutiveSafetyBlocks >= Self.safetyBlocksBeforePause {
                pauseUntil = now.addingTimeInterval(Self.safetyPause)
                consecutiveSafetyBlocks = 0
            }
        case _ where error.isQuotaOrServer:
            let count = (failureCounts[model] ?? 0) + 1
            failureCounts[model] = count
            let cooldown = min(Self.maxCooldown, Self.baseCooldown * pow(2, Double(count - 1)))
            cooldownUntil[model] = now.addingTimeInterval(cooldown)
        default:
            // decodeFailed, other 4xx: treat like a bad prompt, short pause, keep the model.
            pauseUntil = now.addingTimeInterval(2)
        }
    }

    /// Seconds to wait before the next attempt (0 = go now).
    func delayBeforeNextAttempt(now: Date) -> TimeInterval {
        var delay = (billingPauseUntil ?? now).timeIntervalSince(now)
        if let pauseUntil { delay = max(delay, pauseUntil.timeIntervalSince(now)) }
        if config.chain.allSatisfy({ isCoolingDown($0, now: now) }) {
            let soonest = config.chain.map { cooldownRemaining($0, now: now) }.min() ?? 0
            delay = max(delay, soonest)
        }
        return max(0, delay)
    }

    /// True when no model in the chain is available right now.
    func allCoolingDown(now: Date) -> Bool {
        isBillingPaused(now: now) || config.chain.allSatisfy { isCoolingDown($0, now: now) }
    }

    func isBillingPaused(now: Date) -> Bool {
        billingPauseUntil.map { $0 > now } ?? false
    }
}
