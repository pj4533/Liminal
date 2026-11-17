//
//  ArchiveFootageSection.swift
//  Liminal
//
//  "Archive Footage" settings section shared by the macOS control panel and the visionOS control
//  window (docs/plans/archive-video.md 6, A27): on/off, change speed, the film's sound level, what is showing,
//  the cache with a clear button, and the film source credit. Plus the modifier that pushes the
//  settings into ArchiveFootageService and attaches the music engine.
//

import SwiftUI

struct ArchiveFootageSection: View {
    @ObservedObject var settings: SettingsService
    @State private var status = ArchiveFootageService.shared.status
    @State private var cache: (count: Int, bytes: Int64)?
    @State private var confirming = false
    @State private var clearing = false

    #if os(visionOS)
    private static let buttonRole: ButtonRole? = nil
    #else
    private static let buttonRole: ButtonRole? = .destructive
    #endif

    private var cacheLine: String {
        guard let cache else { return "Counting cached films" }
        let size = ByteCountFormatter.string(fromByteCount: cache.bytes, countStyle: .file)
        return "\(cache.count) \(cache.count == 1 ? "film" : "films") cached, \(size)"
    }

    var body: some View {
        ControlSection(title: "Archive Footage", systemImage: "film") {
            ExplainedToggle(title: "Archive footage",
                            explanation: "Old film from the Internet Archive, always woven subtly into the scene.",
                            isOn: $settings.archiveEnabled)

            VStack(alignment: .leading, spacing: 6) {
                Text("Change speed").wrapping()
                Picker("Change speed", selection: $settings.archiveChangeSpeed) {
                    ForEach(FootageChangeSpeed.allCases, id: \.self) { s in
                        Text(s.title).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(settings.archiveChangeSpeed.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .wrapping()
            }
            .disabled(!settings.archiveEnabled)

            ValueSlider(title: "Footage audio", value: $settings.archiveAudioLevel,
                        minimumLabel: "Off", maximumLabel: "Louder",
                        explanation: "The film’s sound drifts between echo, reverb, and clearer voices at original or slowed speed. 0% is silent.")
                .disabled(!settings.archiveEnabled)

            Label(status, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .wrapping()

            Divider()

            Button(role: Self.buttonRole) {
                confirming = true
            } label: {
                Group {
                    if clearing {
                        ProgressView().controlSize(.small)
                    } else {
                        DestructiveLabel(title: "Clear Footage", systemImage: "trash")
                    }
                }
                .frame(minHeight: ControlMetrics.buttonHeight)
            }
            .buttonStyle(.bordered)
            #if os(visionOS)
            .buttonBorderShape(.roundedRectangle(radius: 20))
            #endif
            .disabled(clearing || (cache?.count ?? 0) == 0)
            .confirmationDialog("Delete the cached films (\(cacheLine))?", isPresented: $confirming,
                                titleVisibility: .visible) {
                Button("Delete Films", role: .destructive) {
                    Task {
                        clearing = true
                        await ArchiveFootageService.shared.clearCache()
                        await refresh()
                        clearing = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The film on screen is kept. New films are downloaded while footage is on.")
            }

            Text(cacheLine)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .wrapping()

            Text("Films from the Internet Archive, including the Prelinger Archives.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .wrapping()
        }
        .task {
            // The status and cache change off the main actor; a 2 s poll is enough for a settings panel.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func refresh() async {
        status = ArchiveFootageService.shared.status
        let c = await ArchiveFootageService.shared.cacheSummary()
        if cache?.count != c.count || cache?.bytes != c.bytes { cache = c }
    }
}

extension FootageChangeSpeed {
    var title: String {
        switch self {
        case .slow: return "Slow"
        case .medium: return "Medium"
        case .fast: return "Fast"
        }
    }

    /// The piece lengths of FootageWeaver.Timing.speed, in words.
    var explanation: String {
        switch self {
        case .slow: return "A new piece of film drifts in every 20-30 seconds."
        case .medium: return "A new piece of film drifts in every 12-20 seconds."
        case .fast: return "A new piece of film drifts in every 8-12 seconds."
        }
    }
}

/// Pushes the "Archive Footage" settings into ArchiveFootageService and attaches the music engine.
struct ArchiveFootageSettingsSync: ViewModifier {
    @ObservedObject var settings: SettingsService
    let audioEngine: GenerativeEngine

    func body(content: Content) -> some View {
        content
            .onAppear {
                ArchiveFootageService.shared.attachMusic(audioEngine)
                apply()
            }
            .onChange(of: settings.archiveEnabled) { _, _ in apply() }
            .onChange(of: settings.archiveChangeSpeed) { _, _ in apply() }
            .onChange(of: settings.archiveAudioLevel) { _, _ in apply() }
    }

    private func apply() {
        ArchiveFootageService.shared.apply(enabled: settings.archiveEnabled, speed: settings.archiveChangeSpeed,
                                           audioLevel: settings.archiveAudioLevel)
    }
}

extension View {
    func archiveFootageSettings(_ settings: SettingsService, audioEngine: GenerativeEngine) -> some View {
        modifier(ArchiveFootageSettingsSync(settings: settings, audioEngine: audioEngine))
    }
}
