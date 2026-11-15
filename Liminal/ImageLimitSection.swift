//
//  ImageLimitSection.swift
//  Liminal
//
//  Spending-cap controls shared by macOS and visionOS (GenerationBudget, docs/decisions/images.md D34).
//

import SwiftUI

struct ImageLimitSection: View {
    @ObservedObject var settings: SettingsService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper(value: $settings.maxImagesPerHour, in: 0...200, step: 5) {
                Text("New images per hour: \(settings.maxImagesPerHour)")
                    .monospacedDigit()
                    .wrapping()
            }
            Stepper(value: $settings.maxImagesPerDay, in: 0...1000, step: 25) {
                Text("New images per day: \(settings.maxImagesPerDay)")
                    .monospacedDigit()
                    .wrapping()
            }
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let u = GenerationBudget.shared.usage(now: context.date)
                Text("Generated \(u.lastHour) in the last hour, \(u.lastDay) in the last 24 hours")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .wrapping()
            }
            Text("Each new image is a paid Gemini API call. When a limit is reached, cached images are shown until it resets.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .wrapping()
        }
    }
}
