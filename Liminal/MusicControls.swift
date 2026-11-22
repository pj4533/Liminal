//
//  MusicControls.swift
//  Liminal
//
//  The Music section shared by the macOS control panel and the visionOS control window.
//

import SwiftUI

/// The Music section: tempo and scale.
struct MusicControls: View {
    @ObservedObject var settings: SettingsService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tempo")
                Spacer()
                Text("\(Int(settings.lofiOptions.safeTempo.rounded())) BPM")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $settings.tempo, in: LofiOptions.tempos, step: 1) { Text("Tempo") }
                .labelsHidden().accessibilityLabel("Tempo")
            ScalePicker(selection: settings.scaleSelection)
        }
    }
}
