import SwiftUI

struct MusicModeControls: View {
    @ObservedObject var settings: SettingsService
    @ObservedObject var audio: GenerativeEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Music mode", selection: $settings.musicMode) {
                ForEach(MusicMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("musicMode")
            // AI vs API sits directly under Ambient vs Lo-Fi (docs/plans/image-api-mode.md 7).
            ImageSourceControls(settings: settings)
            if settings.musicMode == .ambient {
                StylePicker(style: $settings.style)
            } else {
                HStack {
                    Text("Tempo")
                    Spacer()
                    Text("\(Int(settings.lofi.safeTempo.rounded())) BPM")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $settings.lofi.tempo, in: LofiOptions.tempos, step: 1) { Text("Tempo") }
                    .labelsHidden().accessibilityLabel("Tempo")
            }
            ScalePicker(selection: settings.scaleSelection)
        }
        .onChange(of: settings.musicMode) { _, mode in audio.musicMode = mode }
        .onChange(of: settings.lofi) { _, options in audio.applyLofi(options) }
    }
}
