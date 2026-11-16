//
//  ArchiveFootageSection.swift
//  Liminal
//
//  "Archive Footage" settings section shared by the macOS control panel and the visionOS control
//  window (docs/plans/archive-video.md 6): on/off, amount, the film's sound level, what is showing,
//  the cache with a clear button, and the Prelinger credit. Plus the modifier that pushes the
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
                            explanation: "Old film from the Internet Archive fades into the scene now and then.",
                            isOn: $settings.archiveEnabled)

            VStack(alignment: .leading, spacing: 6) {
                Text("Footage amount")
                Picker("Footage amount", selection: $settings.archiveAmount) {
                    ForEach(VideoAmount.allCases, id: \.self) { a in
                        Text(a.title).tag(a)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .disabled(!settings.archiveEnabled)

            ValueSlider(title: "Footage audio", value: $settings.archiveAudioLevel,
                        minimumLabel: "Off", maximumLabel: "Louder",
                        explanation: "The film's own sound, slowed and deep in the reverb. 0% is silent.")
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

            Text("Films: Prelinger Archives via the Internet Archive, public domain.")
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

extension VideoAmount {
    var title: String {
        switch self {
        case .rare: return "Rare"
        case .normal: return "Normal"
        case .often: return "Often"
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
            .onChange(of: settings.archiveAmount) { _, _ in apply() }
            .onChange(of: settings.archiveAudioLevel) { _, _ in apply() }
    }

    private func apply() {
        ArchiveFootageService.shared.apply(enabled: settings.archiveEnabled, amount: settings.archiveAmount,
                                           audioLevel: settings.archiveAudioLevel)
    }
}

extension View {
    func archiveFootageSettings(_ settings: SettingsService, audioEngine: GenerativeEngine) -> some View {
        modifier(ArchiveFootageSettingsSync(settings: settings, audioEngine: audioEngine))
    }
}
