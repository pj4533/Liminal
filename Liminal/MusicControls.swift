import SwiftUI

/// The Music section: tempo and scale.
struct MusicControls: View {
    @ObservedObject var settings: SettingsService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tempo")
                Spacer()
                Text("\(Int(settings.lofi.safeTempo.rounded())) BPM")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $settings.lofi.tempo, in: LofiOptions.tempos, step: 1) { Text("Tempo") }
                .labelsHidden().accessibilityLabel("Tempo")
            ScalePicker(selection: settings.scaleSelection)
        }
    }
}
