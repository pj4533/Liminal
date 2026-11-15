//
//  GenerationBudgetTests.swift
//  LiminalTests
//
//  Spending cap for Gemini image generation (D34).
//

import Foundation
import Testing
@testable import Liminal

struct GenerationBudgetTests {

    private func makeDefaults(perHour: Int, perDay: Int) -> UserDefaults {
        let d = UserDefaults(suiteName: "GenerationBudgetTests-\(UUID().uuidString)")!
        d.set(perHour, forKey: GenerationBudget.Keys.perHour)
        d.set(perDay, forKey: GenerationBudget.Keys.perDay)
        return d
    }

    @Test func hourlyLimitBlocksThenRolls() {
        let d = makeDefaults(perHour: 3, perDay: 100)
        let b = GenerationBudget(defaults: d)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<3 { #expect(b.check(now: t0.addingTimeInterval(Double(i))) == .allowed); b.record(now: t0.addingTimeInterval(Double(i))) }
        guard case .limited(let resume, let perHour) = b.check(now: t0.addingTimeInterval(10)) else { Issue.record("expected limit"); return }
        #expect(perHour)
        #expect(abs(resume.timeIntervalSince(t0.addingTimeInterval(3600))) < 1)
        #expect(b.check(now: t0.addingTimeInterval(3601)) == .allowed)
    }

    @Test func dailyLimitBlocks() {
        let d = makeDefaults(perHour: 100, perDay: 4)
        let b = GenerationBudget(defaults: d)
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        for i in 0..<4 { b.record(now: t0.addingTimeInterval(Double(i) * 4000)) }
        let now = t0.addingTimeInterval(4 * 4000)
        guard case .limited(_, let perHour) = b.check(now: now) else { Issue.record("expected limit"); return }
        #expect(!perHour)
        #expect(b.check(now: t0.addingTimeInterval(86_401)) == .allowed)
    }

    @Test func ledgerPersistsAcrossInstances() {
        let d = makeDefaults(perHour: 2, perDay: 10)
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        let a = GenerationBudget(defaults: d)
        a.record(now: t0); a.record(now: t0.addingTimeInterval(1))
        let b = GenerationBudget(defaults: d)
        #expect(b.usage(now: t0.addingTimeInterval(2)).lastHour == 2)
        #expect(b.check(now: t0.addingTimeInterval(2)) != .allowed)
    }

    @Test func zeroMeansNoNewImages() {
        let b = GenerationBudget(defaults: makeDefaults(perHour: 0, perDay: 0))
        #expect(b.check(now: Date(timeIntervalSince1970: 4_000_000)) != .allowed)
    }
}
