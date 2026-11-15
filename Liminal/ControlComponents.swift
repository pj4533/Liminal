//
//  ControlComponents.swift
//  Liminal
//
//  Building blocks shared by the macOS control panel and the visionOS control window
//  (docs/decisions/ui.md). Every text view here wraps instead of truncating.
//

import SwiftUI

// MARK: - Section card

/// A titled group of controls ("Playback", "Music", "Visuals", "Images").
struct ControlSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: ControlMetrics.rowSpacing) {
            Label(title, systemImage: systemImage)
                .font(ControlMetrics.sectionFont)
                .foregroundStyle(.secondary)
                .wrapping()
            content
        }
        .padding(ControlMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ControlMetrics.cardFill, in: RoundedRectangle(cornerRadius: ControlMetrics.cardRadius,
                                                                 style: .continuous))
    }
}

// MARK: - Slider with a visible value

/// "Density            60%" above a full-width slider.
struct ValueSlider: View {
    let title: String
    @Binding var value: Float
    var minimumLabel: String? = nil
    var maximumLabel: String? = nil
    /// Optional caption under the slider.
    var explanation: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .wrapping()
                Spacer(minLength: 8)
                Text("\(Int((value * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Slider(value: $value, in: 0...1) {
                Text(title)
            } minimumValueLabel: {
                if let minimumLabel { sliderEnd(minimumLabel) }
            } maximumValueLabel: {
                if let maximumLabel { sliderEnd(maximumLabel) }
            }
            .labelsHidden()
            .accessibilityLabel(title)
            .accessibilityValue("\(Int((value * 100).rounded())) percent")
            if let explanation {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .wrapping()
            }
        }
    }

    private func sliderEnd(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

// MARK: - Style + scale pickers

/// Segmented music style picker (Drift / Glass / Deep / Garden), labelled.
struct StylePicker: View {
    @Binding var style: MusicStyle.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Style")
            Picker("Style", selection: $style) {
                ForEach(MusicStyle.ID.allCases, id: \.self) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

/// "Scale" with a menu: "Auto (evolving)" or a pinned scale. The menu sits on its own line
/// under the title so long names such as "Natural Minor (Aeolian)" never truncate.
struct ScalePicker: View {
    @Binding var selection: ScaleType?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scale")
            Picker("Scale", selection: $selection) {
                Text("Auto (evolving)").tag(ScaleType?.none)
                Divider()
                ForEach(ScaleType.allCases, id: \.self) { scale in
                    Text(scale.rawValue).tag(ScaleType?.some(scale))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            Text(selection.map { "Pinned to \($0.rawValue)." } ?? "The scale changes as the music evolves.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .wrapping()
        }
    }
}

// MARK: - Status

/// "Playing", cached image count and generation queue, as wrapping text.
struct PlaybackStatus: View {
    let isPlaying: Bool
    let cachedCount: Int
    let queuedCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isPlaying ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                Text(isPlaying ? "Playing" : "Stopped")
                    .fontWeight(.medium)
                    .wrapping()
            }
            Text("\(cachedCount) \(cachedCount == 1 ? "image" : "images") cached, \(queuedCount) in queue")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .wrapping()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Gemini credential status with a colored dot.
struct APIStatusRow: View {
    var body: some View {
        let ready = EnvironmentService.shared.hasValidCredentials
        HStack(spacing: 8) {
            Circle()
                .fill(ready ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(ready ? "Gemini API ready" : "Missing Gemini API key")
                .wrapping()
        }
    }
}

/// A toggle with an explanation underneath that wraps.
struct ExplainedToggle: View {
    let title: String
    let explanation: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            #if os(macOS)
            // Outside a Form, a macOS switch hugs its label; push it to the trailing edge.
            HStack(alignment: .firstTextBaseline) {
                Text(title).wrapping()
                Spacer(minLength: 8)
                Toggle(title, isOn: $isOn)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            #else
            Toggle(isOn: $isOn) {
                Text(title).wrapping()
            }
            #endif
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .wrapping()
        }
    }
}

/// Label for a destructive button. On visionOS the system's red title text is hard to read
/// on glass, so only the icon is red and the title stays primary.
struct DestructiveLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        #if os(visionOS)
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(.red)
            Text(title).foregroundStyle(.primary)
        }
        .fixedSize()
        #else
        Label(title, systemImage: systemImage).fixedSize()
        #endif
    }
}

// MARK: - Metrics

enum ControlMetrics {
    #if os(visionOS)
    static let rowSpacing: CGFloat = 16
    static let cardPadding: CGFloat = 24
    static let cardRadius: CGFloat = 28
    static let sectionFont: Font = .title3.weight(.semibold)
    /// HIG: at least 60 pt hit targets for primary actions in visionOS.
    static let buttonHeight: CGFloat = 60
    static let cardFill = Color.black.opacity(0.12)
    #else
    static let rowSpacing: CGFloat = 10
    static let cardPadding: CGFloat = 12
    static let cardRadius: CGFloat = 10
    static let sectionFont: Font = .subheadline.weight(.semibold)
    static let buttonHeight: CGFloat = 28
    static let cardFill = Color.primary.opacity(0.05)
    #endif
}

extension View {
    /// Never truncate: grow vertically and wrap instead.
    func wrapping() -> some View {
        lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
    }
}
