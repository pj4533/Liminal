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

    @State private var isImmersed = false
    @State private var isDioramaActive = false

    /// Minimum column width that keeps every label on one line at visionOS type sizes.
    private static let columnWidth: CGFloat = 360

    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 24) { content() }
            .frame(minWidth: Self.columnWidth, idealWidth: Self.columnWidth, maxWidth: .infinity)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                // Three columns at the default size, two or one when the window is narrowed.
                // idealWidth: wrapping captions would otherwise report their one-line width and
                // ViewThatFits would always fall back to the narrowest layout.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        column { playbackSection; imagesSection }
                        column { musicSection }
                        column { visualsSection }
                    }
                    HStack(alignment: .top, spacing: 24) {
                        column { playbackSection; visualsSection }
                        column { musicSection; imagesSection }
                    }
                    VStack(spacing: 24) {
                        playbackSection; musicSection; visualsSection; imagesSection
                    }
                }
            }
            .padding(32)
        }
        .onAppear {
            audioEngine.apply(settings)
            applyDebugLaunchOptions()
        }
        .onChange(of: settings.delay) { _, newValue in audioEngine.delay = newValue }
        .onChange(of: settings.reverb) { _, newValue in audioEngine.space = newValue }
        .onChange(of: settings.notes) { _, newValue in audioEngine.density = newValue }
        .onChange(of: settings.style) { _, newValue in audioEngine.style = newValue }
        .onChange(of: settings.pinnedScale) { _, newValue in audioEngine.pinnedScale = newValue }
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
                Label(audioEngine.isRunning ? "Stop" : "Play",
                      systemImage: audioEngine.isRunning ? "stop.fill" : "play.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: ControlMetrics.buttonHeight)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 20))
            .tint(audioEngine.isRunning ? .red : .blue)
            .accessibilityIdentifier("play")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { domeButton; dioramaButton }
                VStack(spacing: 12) { domeButton; dioramaButton }
            }

            PlaybackStatus(isPlaying: audioEngine.isRunning,
                           cachedCount: visualEngine.totalCachedCount,
                           queuedCount: visualEngine.queuedCount)
            if let status = visualEngine.statusMessage {
                Label(status, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.yellow)
                    .wrapping()
            }
        }
    }

    private var domeButton: some View {
        Button(action: toggleDome) {
            Label(isImmersed ? "Exit Dome" : "Enter Dome",
                  systemImage: isImmersed ? "arrow.down.right.and.arrow.up.left"
                                          : "arrow.up.left.and.arrow.down.right")
                .fixedSize()
                .frame(maxWidth: .infinity, minHeight: ControlMetrics.buttonHeight)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 20))
        .accessibilityIdentifier("enterDome")
    }

    private var dioramaButton: some View {
        Button(action: toggleDiorama) {
            Label(isDioramaActive ? "Exit Diorama" : "Spatial Diorama",
                  systemImage: isDioramaActive ? "cube.transparent" : "cube.transparent.fill")
                .fixedSize()
                .frame(maxWidth: .infinity, minHeight: ControlMetrics.buttonHeight)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 20))
        .accessibilityIdentifier("spatial")
    }

    // MARK: Music

    private var musicSection: some View {
        ControlSection(title: "Music", systemImage: "music.note") {
            StylePicker(style: $settings.style)
            ValueSlider(title: "Density", value: $settings.notes)
            ValueSlider(title: "Space", value: $settings.reverb)
            ValueSlider(title: "Echo", value: $settings.delay)
            ScalePicker(selection: settings.scaleSelection)
        }
    }

    // MARK: Visuals

    private var visualsSection: some View {
        ControlSection(title: "Visuals", systemImage: "sparkles") {
            ValueSlider(title: "Effect intensity", value: $settings.effectIntensity,
                        minimumLabel: "Subtle", maximumLabel: "Wild",
                        explanation: "How far the effects bend the picture. Low keeps the image clear.")
            ExplainedToggle(title: "Sync visuals to music",
                            explanation: "Color, motion and bloom follow the music as it plays.",
                            isOn: $settings.syncVisualsToMusic)
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

    // MARK: Images & storage

    private var imagesSection: some View {
        ControlSection(title: "Images & Storage", systemImage: "photo.stack") {
            APIStatusRow()
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
            Text("Restores style, density, space, echo, scale and visual settings to their defaults.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .wrapping()
        }
    }

    // MARK: Actions

    private func togglePlayback() {
        if audioEngine.isRunning {
            audioEngine.stop()
            visualEngine.stop()
        } else {
            audioEngine.start()
            visualEngine.start()
        }
    }

    private func toggleDome() {
        Task {
            if isImmersed {
                await dismissImmersiveSpace()
                isImmersed = false
            } else {
                if isDioramaActive {
                    await dismissImmersiveSpace()
                    isDioramaActive = false
                }
                let result = await openImmersiveSpace(id: "liminalDome")
                if case .opened = result { isImmersed = true }
            }
        }
    }

    private func toggleDiorama() {
        Task {
            if isDioramaActive {
                await dismissImmersiveSpace()
                isDioramaActive = false
            } else {
                if isImmersed {
                    await dismissImmersiveSpace()
                    isImmersed = false
                }
                let result = await openImmersiveSpace(id: "liminalDiorama")
                if case .opened = result { isDioramaActive = true }
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
            visualEngine.start()
            LMLog.general.info("🧪 DEBUG: auto-play started")
        }
        if DebugLaunchOptions.openDome, !isImmersed {
            Task {
                // Give the window a moment to finish presenting before requesting the space.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let result = await openImmersiveSpace(id: "liminalDome")
                if case .opened = result {
                    isImmersed = true
                    LMLog.general.info("🧪 DEBUG: auto-opened liminalDome immersive space")
                } else {
                    LMLog.general.error("🧪 DEBUG: auto-open of liminalDome failed: \(String(describing: result), privacy: .public)")
                }
            }
        }
    }
}

#endif
