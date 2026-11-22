//
//  ArchiveFootageSection.swift
//  Liminal
//
//  "Archive Footage" settings section shared by the macOS control panel and the visionOS control
//  window (docs/plans/archive-video.md 6, A27): on/off, the film's sound level, what is showing,
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
    @State private var speechStatus: DialogueSpeechStatus?

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

            Text("Footage changes with the drum fills every eight bars. The cut is quicker at sixteen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .wrapping()

            ValueSlider(title: "Footage audio", value: $settings.archiveAudioLevel,
                        minimumLabel: "Off", maximumLabel: "Louder",
                        explanation: "A clear echo repeats on the beat, with a softer offbeat reflection.")
                .disabled(!settings.archiveEnabled)

            dialogueUnderstanding

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

    /// "Dialogue understanding" (plan 7): whether dialogue chopping may use the on-device speech model.
    private var dialogueUnderstanding: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dialogue understanding").wrapping()
            Picker("Dialogue understanding", selection: $settings.dialogueTranscription) {
                ForEach(DialogueTranscriptionMode.allCases, id: \.self) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("dialogueUnderstandingPicker")
            Text(speechStatus.map { $0.title } ?? "Checking")
                .font(.caption)
                .foregroundStyle(.secondary)
                .wrapping()
                .accessibilityIdentifier("dialogueUnderstandingStatus")
        }
        .disabled(!settings.archiveEnabled)
        .onChange(of: settings.dialogueTranscription) { _, mode in
            if mode == .allowDownload { DialogueSpeechAssets.requestInstallIfAllowed() }
            Task { speechStatus = await DialogueSpeechAssets.status() }
        }
    }

    private func refresh() async {
        speechStatus = await DialogueSpeechAssets.status()
        status = ArchiveFootageService.shared.status
        let c = await ArchiveFootageService.shared.cacheSummary()
        if cache?.count != c.count || cache?.bytes != c.bytes { cache = c }
    }
}

extension DialogueTranscriptionMode {
    var title: String {
        switch self {
        case .off: return "Off"
        case .installedOnly: return "If installed"
        case .allowDownload: return "Download model"
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
                // Learn the speech model status once at launch, so the first cue can use it.
                // A Download model choice from an earlier launch resumes here (once per launch).
                DialogueSpeechAssets.refreshStatus()
                if settings.dialogueTranscription == .allowDownload { DialogueSpeechAssets.requestInstallIfAllowed() }
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
