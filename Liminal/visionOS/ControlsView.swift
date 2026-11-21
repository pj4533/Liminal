//
//  ControlsView.swift
//  Liminal
//
//  visionOS floating controls for audio/visual parameters.
//

#if os(visionOS)

import SwiftUI
import OSLog

struct ControlsView: View {
    @ObservedObject var audioEngine: GenerativeEngine
    @ObservedObject var visualEngine: VisualEngine
    @ObservedObject private var settings = SettingsService.shared

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    @Binding var isImmersed: Bool
    @Binding var controlsVisible: Bool
    @State private var immersiveRequestPending = false

    /// Minimum column width that keeps every label on one line at visionOS type sizes.
    private static let columnWidth: CGFloat = 360

    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 24) { content() }
            .frame(minWidth: Self.columnWidth, idealWidth: Self.columnWidth, maxWidth: .infinity)
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                // Three columns at the default size, two or one when the window is narrowed.
                // idealWidth: wrapping captions would otherwise report their one-line width and
                // ViewThatFits would always fall back to the narrowest layout.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        column { playbackSection; imagesSection }
                        column { musicSection; archiveSection }
                        column { visualsSection }
                    }
                    HStack(alignment: .top, spacing: 24) {
                        column { playbackSection; visualsSection }
                        column { musicSection; archiveSection; imagesSection }
                    }
                    VStack(spacing: 24) {
                        playbackSection; musicSection; visualsSection; archiveSection; imagesSection
                    }
                }
            }
            .padding(32)
        }
        .onAppear {
            RecordingController.shared.scheduleDebugRecording(audio: audioEngine)
            controlsVisible = true
            audioEngine.apply(settings)
            applyDebugLaunchOptions()
            if let id = DebugLaunchOptions.controlsScroll {
                Task { try? await Task.sleep(nanoseconds: 800_000_000); proxy.scrollTo(id, anchor: .top) }
            }
        }
        }
        .onDisappear { controlsVisible = false }
        .onChange(of: settings.style) { _, newValue in audioEngine.style = newValue }
        .onChange(of: settings.pinnedScale) { _, newValue in audioEngine.pinnedScale = newValue }
        .onChange(of: settings.imageSource) { _, source in visualEngine.setImageSource(source) }
        .onChange(of: audioEngine.isPlaybackReady ? audioEngine.musicMode : nil, initial: true) { _, playingMode in
            if playingMode != nil { visualEngine.start(music: audioEngine) } else { visualEngine.stop() }
        }
        .archiveFootageSettings(settings, audioEngine: audioEngine)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Liminal")
                .font(.extraLargeTitle2)
            Text("Generative ambient music with evolving visuals")
                .font(.title3)
                .foregroundStyle(.secondary)
                .wrapping()
        }
    }

    // MARK: Playback

    private var playbackSection: some View {
        ControlSection(title: "Playback", systemImage: "play.circle") {
            Button(action: togglePlayback) {
                Label(audioEngine.isRunning ? (audioEngine.isPlaybackReady ? "Stop" : "Cancel") : "Play",
                      systemImage: audioEngine.isRunning ? "stop.fill" : "play.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: ControlMetrics.buttonHeight)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 20))
            .tint(audioEngine.isRunning ? .red : .blue)
            .accessibilityIdentifier("play")

            immersiveButton

            PlaybackStatus(isPlaying: audioEngine.isPlaybackReady,
                           isPreparing: audioEngine.isRunning && !audioEngine.isPlaybackReady,
                           cachedCount: visualEngine.totalCachedCount,
                           queuedCount: visualEngine.queuedCount,
                           source: visualEngine.imageSource)
            RecordControls(audio: audioEngine)
            if let status = visualEngine.statusMessage {
                Label(status, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.yellow)
                    .wrapping()
            }
        }
    }

    /// One immersive mode: the wrap-around depth-relief shell with the effects on it
    /// (docs/plans/spatial.md). The id stays "enterDome" for scripts/sim-tap.sh.
    private var immersiveButton: some View {
        Button(action: toggleImmersive) {
            Label(isImmersed ? "Exit Liminal" : "Enter Liminal",
                  systemImage: isImmersed ? "arrow.down.right.and.arrow.up.left"
                                          : "visionpro")
                .frame(maxWidth: .infinity, minHeight: ControlMetrics.buttonHeight)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 20))
        .accessibilityIdentifier("enterDome")
    }

    // MARK: Music

    private var musicSection: some View {
        ControlSection(title: "Music", systemImage: "music.note") {
            MusicModeControls(settings: settings, audio: audioEngine)
        }
    }

    // MARK: Visuals

    private var visualsSection: some View {
        ControlSection(title: "Visuals", systemImage: "sparkles") {
            ValueSlider(title: "Effect intensity", value: $settings.effectIntensity,
                        minimumLabel: "Subtle", maximumLabel: "Wild",
                        explanation: "How far the effects bend the picture. Low keeps the image clear.")
            ValueSlider(title: "Depth", value: $settings.depthStrength,
                        minimumLabel: "Flat", maximumLabel: "Deep",
                        explanation: "How far near parts of the picture come toward you in the immersive space.")
            ExplainedToggle(title: "Sync visuals to music",
                            explanation: "Color, motion and bloom follow the music as it plays.",
                            isOn: $settings.syncVisualsToMusic)
            // Gemini controls only matter in AI mode; API mode never generates.
            if settings.imageSource == .ai {
                ExplainedToggle(title: "Cache only",
                                explanation: "Show only images already saved on this device. No new images are generated.",
                                isOn: $settings.cacheOnly)
                if settings.cacheOnly && visualEngine.totalCachedCount == 0 {
                    Label("No cached images, so nothing will display.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.yellow)
                        .wrapping()
                }
                if !settings.cacheOnly {
                    ImageLimitSection(settings: settings)
                }
            }
        }
    }

    // MARK: Archive footage

    private var archiveSection: some View {
        ArchiveFootageSection(settings: settings)
            .id("archive")
    }

    // MARK: Images & storage

    private var imagesSection: some View {
        imagesSectionContent.id("images")
    }

    private var imagesSectionContent: some View {
        ControlSection(title: "Images & Storage", systemImage: "photo.stack") {
            APIStatusRow(source: visualEngine.imageSource, apiStatus: visualEngine.sourceStatus)
            ImageCreditLine(metadata: visualEngine.currentMetadata)
            ClearImagesSection(visualEngine: visualEngine)
            Divider()
            // No destructive role: its red title is unreadable on glass; the icon is red instead.
            Button {
                settings.resetToDefaults()
                audioEngine.apply(settings)
            } label: {
                DestructiveLabel(title: "Reset All Settings", systemImage: "arrow.counterclockwise")
                    .frame(minHeight: ControlMetrics.buttonHeight)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 20))
            Text("Restores style, density, space, echo, scale, visual and footage settings to their defaults.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .wrapping()
        }
    }

    // MARK: Actions

    private func togglePlayback() {
        if audioEngine.isRunning {
            RecordingController.shared.playbackStopped()   // finish and save the movie first
            audioEngine.stop()
        } else {
            audioEngine.start()
        }
    }

    private func toggleImmersive() {
        guard !immersiveRequestPending else { return }
        immersiveRequestPending = true
        Task {
            defer { immersiveRequestPending = false }
            if isImmersed {
                await dismissImmersiveSpace()
                isImmersed = false
            } else {
                let result = await openImmersiveSpace(id: LiminalVisionApp.immersiveSpaceID)
                if case .opened = result { isImmersed = true }
            }
        }
    }
}

// MARK: - DEBUG launch options (perf harness)

extension ControlsView {
    /// Honors -LiminalAutoPlay / -LiminalOpenDome (always false in Release builds).
    fileprivate func applyDebugLaunchOptions() {
        DebugLaunchOptions.logApplied()
        if DebugLaunchOptions.autoPlay, !audioEngine.isRunning {
            audioEngine.start()
            LMLog.general.info("🧪 DEBUG: auto-play started")
        }
        if DebugLaunchOptions.openDome, !isImmersed {
            Task {
                // Give the window a moment to finish presenting before requesting the space.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let result = await openImmersiveSpace(id: LiminalVisionApp.immersiveSpaceID)
                if case .opened = result {
                    isImmersed = true
                    LMLog.general.info("🧪 DEBUG: auto-opened the immersive space")
                    if DebugLaunchOptions.hideControls {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        controlsVisible = false
                        dismissWindow(id: LiminalVisionApp.controlsWindowID)
                        LMLog.general.info("🧪 DEBUG: controls window closed (-LiminalHideControls)")
                    }
                    if let delay = DebugLaunchOptions.autoExitAfter {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        LMLog.general.info("🧪 DEBUG: auto-exit (-LiminalAutoExitAfter), same path as Exit Liminal")
                        toggleImmersive()
                    }
                } else {
                    LMLog.general.error("🧪 DEBUG: auto-open of the immersive space failed: \(String(describing: result), privacy: .public)")
                }
            }
        }
    }
}

#endif
