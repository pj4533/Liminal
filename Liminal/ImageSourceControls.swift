//
//  ImageSourceControls.swift
//  Liminal
//
//  "Images: AI | API" (docs/plans/image-api-mode.md 7), shared by the macOS control panel and the
//  visionOS control window. It sits at the top of the Images & Storage section. The switch reaches
//  the engine through `.onChange` in ContentView / ControlsView.
//

import SwiftUI

struct ImageSourceControls: View {
    @ObservedObject var settings: SettingsService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Images")
            Picker("Images", selection: $settings.imageSource) {
                ForEach(ImageSource.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("imageSource")
            Text(settings.imageSource.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .wrapping()
        }
    }
}

/// Credit of the API picture on screen: "Title · Creator, date · Institution · Licence" and a link
/// to the institution's page. Nothing in AI mode.
struct ImageCreditLine: View {
    let metadata: ImageMetadata?

    var body: some View {
        if let credit = metadata?.source {
            VStack(alignment: .leading, spacing: 4) {
                Text("Now showing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(credit.displayLine)
                    .font(.callout)
                    .wrapping()
                    .accessibilityIdentifier("imageCredit")
                if let url = URL(string: credit.sourceURL) {
                    Link(destination: url) {
                        Label("View at \(credit.institution)", systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                }
            }
        }
    }
}

/// Gemini credentials in AI mode; the collections' state in API mode.
struct APIStatusRow: View {
    var source: ImageSource = .ai
    var apiStatus: (text: String, ok: Bool)? = nil

    var body: some View {
        let ready: Bool
        let text: String
        switch source {
        case .ai:
            ready = EnvironmentService.shared.hasValidCredentials
            text = ready ? "Gemini API ready" : "Missing Gemini API key"
        case .api:
            ready = apiStatus?.ok ?? true
            text = apiStatus?.text ?? "Curated collections"
        }
        return HStack(spacing: 8) {
            Circle()
                .fill(ready ? Color.green : (source == .api ? Color.yellow : Color.red))
                .frame(width: 10, height: 10)
            Text(text)
                .wrapping()
        }
    }
}
