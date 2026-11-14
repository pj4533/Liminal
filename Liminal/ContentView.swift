//
//  ContentView.swift
//  Liminal
//
//  Created by PJ Gray on 1/10/26.
//

#if os(macOS)

import SwiftUI
import OSLog
import AppKit

// MARK: - Window Aspect Ratio Constraint

/// Enforces window resizing so the visual area keeps the image aspect ratio
/// (width = height * visualAspect + controlPanelWidth). Images are 3:2 since
/// the Gemini 3.1 switch (docs/decisions/images.md D4).
final class SquareVisualWindowDelegate: NSObject, NSWindowDelegate {
    static let controlPanelWidth: CGFloat = 281  // 280 panel + 1 divider
    static let visualAspect: CGFloat = ImageFraming.displayAspect  // 3:2, matches generated images

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // Calculate title bar height for this window
        let titleBarHeight = sender.frame.height - sender.contentRect(forFrameRect: sender.frame).height
        let contentHeight = frameSize.height - titleBarHeight
        // Enforce: visual width = visual height * aspect
        // Total content width = visual width + control panel width
        let newWidth = (contentHeight * Self.visualAspect).rounded() + Self.controlPanelWidth
        return NSSize(width: newWidth, height: frameSize.height)
    }
}

struct WindowAccessor: NSViewRepresentable {
    // CRITICAL: Store delegate in Coordinator so it stays alive
    class Coordinator {
        let delegate = SquareVisualWindowDelegate()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Use async to ensure window is attached
        DispatchQueue.main.async {
            guard let window = view.window else { return }

            // Set our delegate (stored in coordinator so it won't be deallocated)
            window.delegate = context.coordinator.delegate

            // Set initial frame to enforce the 3:2 visual area
            let contentHeight = window.contentRect(forFrameRect: window.frame).height
            let newWidth = (contentHeight * SquareVisualWindowDelegate.visualAspect).rounded()
                + SquareVisualWindowDelegate.controlPanelWidth
            let newFrame = NSRect(
                x: window.frame.origin.x,
                y: window.frame.origin.y,
                width: newWidth,
                height: window.frame.height
            )
            window.setFrame(newFrame, display: true, animate: false)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Content View

struct ContentView: View {
    @State private var showingSettings = false
    @StateObject private var audioEngine = GenerativeEngine()
    @StateObject private var visualEngine = VisualEngine()
    @StateObject private var settings = SettingsService.shared

    var body: some View {
        HStack(spacing: 0) {
            // Visual display area
            VisualDisplayView(visualEngine: visualEngine, settings: settings, isPlaying: audioEngine.isRunning,
                              music: audioEngine)
                .frame(minWidth: 400, minHeight: 400)

            Divider()

            // Control panel
            VStack(spacing: 16) {
                // Header
                HStack {
                    Image(systemName: "waveform")
                        .imageScale(.large)
                        .foregroundStyle(.tint)
                    Text("Liminal")
                        .font(.largeTitle)

                    Spacer()

                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gear")
                            .imageScale(.large)
                    }
                    .buttonStyle(.plain)
                }

                Divider()

                // Music style
                Picker("Style", selection: $settings.style) {
                    ForEach(MusicStyle.ID.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)

                // Music controls - bound to settings (single source of truth)
                VStack(spacing: 12) {
                    AudioSlider(
                        label: "Density",
                        value: $settings.notes,
                        leftIcon: "circle.dotted",
                        rightIcon: "circle.hexagongrid.fill"
                    )
                    AudioSlider(
                        label: "Space",
                        value: $settings.reverb,
                        leftIcon: "cube.transparent",
                        rightIcon: "cube.fill"
                    )
                    AudioSlider(
                        label: "Echo",
                        value: $settings.delay,
                        leftIcon: "waveform.slash",
                        rightIcon: "waveform.badge.plus"
                    )
                }
                .padding(.horizontal)

                // Scale selector: Auto (evolving) or a pinned scale
                HStack {
                    Text("Scale:")
                        .foregroundStyle(.secondary)
                    Picker("", selection: settings.scaleSelection) {
                        Text("Auto (evolving)").tag(ScaleType?.none)
                        Divider()
                        ForEach(ScaleType.allCases, id: \.self) { scale in
                            Text(scale.rawValue).tag(ScaleType?.some(scale))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal)

                Spacer()

                // Debug effect toggle
                Toggle("Debug Effect", isOn: $settings.debugEffectEnabled)
                    .toggleStyle(.switch)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                // Play/Stop
                Button(audioEngine.isRunning ? "Stop" : "Play") {
                    if audioEngine.isRunning {
                        audioEngine.stop()
                        visualEngine.stop()
                    } else {
                        audioEngine.start()
                        visualEngine.start()
                    }
                }
                .buttonStyle(.borderedProminent)
                .font(.title2)
                .controlSize(.large)
            }
            .padding()
            .frame(width: 280)
        }
        .frame(minWidth: 700, minHeight: 450)
        .background(WindowAccessor())
        .onAppear {
            // Apply saved settings to audio engine on launch
            audioEngine.apply(settings)

            // DEBUG perf harness: -LiminalAutoPlay YES (always false in Release)
            DebugLaunchOptions.logApplied()
            if DebugLaunchOptions.autoPlay, !audioEngine.isRunning {
                audioEngine.start()
                visualEngine.start()
                LMLog.general.info("🧪 DEBUG: auto-play started")
            }
        }
        // Settings -> AudioEngine: propagate changes immediately
        .onChange(of: settings.delay) { _, newValue in audioEngine.delay = newValue }
        .onChange(of: settings.reverb) { _, newValue in audioEngine.space = newValue }
        .onChange(of: settings.notes) { _, newValue in audioEngine.density = newValue }
        .onChange(of: settings.style) { _, newValue in audioEngine.style = newValue }
        .onChange(of: settings.pinnedScale) { _, newValue in audioEngine.pinnedScale = newValue }
        .sheet(isPresented: $showingSettings) {
            SettingsSheetView(audioEngine: audioEngine, visualEngine: visualEngine)
        }
    }
}

// MARK: - Settings Sheet

struct SettingsSheetView: View {
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject var audioEngine: GenerativeEngine
    @ObservedObject var visualEngine: VisualEngine
    @Environment(\.dismiss) private var dismiss
    @State private var cacheCount: Int = 0

    private var apiKeyStatus: String {
        EnvironmentService.shared.hasValidCredentials ? "✓ Gemini API ready" : "✗ Missing API key"
    }

    private func refreshCacheCount() {
        cacheCount = ImageStore.shared.imageCount()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            Divider()

            // API Status
            VStack(alignment: .leading, spacing: 12) {
                Text("API")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text(apiKeyStatus)
                    .font(.body)
            }

            Divider()

            // Visual Settings
            VStack(alignment: .leading, spacing: 12) {
                Text("Visuals")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Toggle("Cache Only Mode", isOn: $settings.cacheOnly)
                    .toggleStyle(.checkbox)

                Toggle("Sync visuals to music", isOn: $settings.syncVisualsToMusic)
                    .toggleStyle(.checkbox)

                if settings.cacheOnly && cacheCount == 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("No cached images! Nothing will display.")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }

                Text("When enabled, only cached images are used - no new images will be generated. Useful for testing effects without API costs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Cache Management
            VStack(alignment: .leading, spacing: 12) {
                Text("Cache")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                ClearImagesSection(visualEngine: visualEngine)

                Text("Deletes every cached image and its metadata. Settings are kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Reset Button
            VStack(alignment: .leading, spacing: 12) {
                Text("Reset")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Button("Reset All to Defaults") {
                    settings.resetToDefaults()
                    // Apply reset values to engine
                    audioEngine.apply(settings)
                }
                .foregroundStyle(.red)

                Text("Resets style, density, space, echo, scale, and visual settings to their default values.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 400, height: 550)
        .onAppear {
            refreshCacheCount()
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageCacheCleared)) { _ in
            refreshCacheCount()
        }
    }
}

// MARK: - Visual Display

/// Music <-> visuals coupling state for the macOS render path. A plain class held in `@State`
/// (not observable), so mutating it while SwiftUI evaluates `body` never invalidates the view.
final class MusicSyncBox {
    var reactor = MusicReactor(strength: DebugLaunchOptions.syncStrength)
    var lastMood: VisualMood?
    var activity = VisualActivityThrottle()
    var lastLogSecond = -1
}

struct VisualDisplayView: View {
    @ObservedObject var visualEngine: VisualEngine
    @ObservedObject var settings: SettingsService
    let isPlaying: Bool
    /// Plain reference, not observed: only its nonisolated bus and visual-input methods are used (C13).
    let music: GenerativeEngine
    @StateObject private var transitionManager = TimerDrivenCrossfade()
    @StateObject private var effectController = EffectController()
    @State private var lastLoggedSecond: Int = -1
    @State private var sync = MusicSyncBox()

    // Single uniforms struct - matches visionOS pattern for platform parity
    private var effectUniforms: EffectsUniforms { frameParams().uniforms }

    /// Uniforms plus the music modulation they were built from (the renderer also needs its burst serial).
    /// Called at least twice per tick (body and the log `onChange`); the reactor caches repeated times.
    private func frameParams() -> (uniforms: EffectsUniforms, modulation: MusicModulation) {
        let effectTime = DebugLaunchOptions.effectTime(Float(effectController.time))
        let vibrance = currentVibrance()
        // Music -> visuals. macOS keeps its 0.03 turns/s hue drift when un-synced. Frozen time bypasses
        // the reactor so deterministic captures are unchanged.
        let modulation: MusicModulation
        if DebugLaunchOptions.freezeTime != nil {
            modulation = .unsynced(hueBaseShift: effectTime * Self.baseHueRate)
        } else {
            let bus = music.musicState
            modulation = sync.reactor.update(state: bus.read(), now: bus.now(), effectTime: effectTime,
                                             enabled: settings.syncVisualsToMusic, baseHueRate: Self.baseHueRate)
        }
        var uniforms = EffectsUniformsComputer.compute(
            time: effectTime,
            transitionProgress: Float(transitionManager.transitionProgress),
            hasSaliencyMap: transitionManager.currentSaliencyMap != nil,
            vibrance: vibrance,
            music: modulation
        )
        // Debug toggle controls the effect currently being tested
        if !settings.debugEffectEnabled {
            uniforms.bloomAmount = 0
        }
        return (uniforms, modulation)
    }

    /// Per-image vibrance factors (measured once per image, cached), blended across a crossfade
    private func currentVibrance() -> VibranceFactors {
        var vibrance = VibranceFactors.neutral
        if let frame = transitionManager.currentFrame {
            vibrance = ImageColorStats.cachedFactors(key: frame) { frame.cgImageRepresentation.map { ImageFraming.coverCrop($0) } }
            if let prev = transitionManager.previousFrame {
                let from = ImageColorStats.cachedFactors(key: prev) { prev.cgImageRepresentation.map { ImageFraming.coverCrop($0) } }
                vibrance = VibranceFactors.lerp(from, vibrance, Float(transitionManager.transitionProgress))
            }
        }
        return vibrance
    }

    /// Hue drift of the un-synced macOS look (turns per second).
    private static let baseHueRate: Float = 0.03

    /// Visuals -> music: describe the image whose crossfade just started (or the first image).
    private func postMood(for image: PlatformImage, imageChanged: Bool) {
        // Atomic read: the two @Published mirrors (image, metadata) have no ordering guarantee (C10).
        let metadata = visualEngine.imageBuffer.loadCurrentWithMetadata().metadata
        let mood = VisualMoodBuilder.mood(metadata: metadata,
                                          image: image.cgImageRepresentation.map { ImageFraming.coverCrop($0) })
        music.setVisualMood(mood)
        if imageChanged { music.imageDidChange(transitionDuration: VisualMoodBuilder.crossfadeDuration) }
        sync.lastMood = mood
        LMLog.visual.info("🎼 setVisualMood b=\(String(format: "%.2f", mood.brightness)) w=\(String(format: "%.2f", mood.warmth)) s=\(String(format: "%.2f", mood.saturation)) e=\(String(format: "%.2f", mood.energy)) words=\(mood.moodWords.joined(separator: ","), privacy: .public) imageDidChange=\(imageChanged)")
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                Color.black

                // Metal view with all effects + ghost tap trails
                if transitionManager.currentFrame != nil {
                    let params = frameParams()
                    EffectsMetalViewRepresentable(
                        sourceImage: transitionManager.currentFrame,
                        previousImage: transitionManager.previousFrame,  // GPU crossfade blending
                        saliencyMap: transitionManager.currentSaliencyMap,
                        uniforms: params.uniforms,
                        delay: settings.delay,
                        ghostBurstSerial: params.modulation.ghostBurstSerial
                    )
                    // Keep the image at its 3:2 display aspect even if the window is not exactly
                    // 3:2 (min sizes, full screen): letterbox on black instead of stretching.
                    .aspectRatio(ImageFraming.displayAspect, contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)

                    // Status overlay (top corners)
                    VStack {
                        HStack {
                            // Total cached images count
                            HStack(spacing: 4) {
                                Image(systemName: "photo.stack")
                                    .font(.caption2)
                                Text("\(visualEngine.totalCachedCount)")
                                    .font(.caption2.monospacedDigit())
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial)
                            .cornerRadius(6)
                            .padding(8)

                            Spacer()
                        }
                        Spacer()
                    }
                } else {
                    // Placeholder
                    VStack(spacing: 12) {
                        if visualEngine.isGenerating || transitionManager.isMorphing {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text(transitionManager.isMorphing ? "Morphing..." : "Generating...")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 48))
                                .foregroundStyle(.white.opacity(0.3))
                            Text("Press Play to begin")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .onChange(of: visualEngine.currentImage) { _, newImage in
            if let image = newImage {
                let hadFrame = transitionManager.currentFrame != nil
                let started = transitionManager.transitionTo(image)
                if started || !hadFrame { postMood(for: image, imageChanged: started) }
            } else {
                // Image was cleared (e.g., cache cleared) - reset transition manager
                transitionManager.reset()
            }
        }
        // nextImage handler removed - preloading not needed with new morph architecture
        // Morphs trigger only when currentImage changes
        .onAppear {
            transitionManager.start()
            // Effects start when Play is pressed, not on appear
            if let image = visualEngine.currentImage {
                transitionManager.setInitialImage(image)
                postMood(for: image, imageChanged: false)
            }
        }
        .onChange(of: isPlaying) { _, playing in
            if playing {
                lastLoggedSecond = -1  // Reset so first log happens immediately
                effectController.start()
            } else {
                effectController.stop()
            }
        }
        // Log Ken Burns values periodically for debugging
        .onChange(of: effectController.time) { _, newTime in
            // Visuals -> music activity (un-modulated oscillators, at most 2 Hz)
            let tp = Float(transitionManager.transitionProgress)
            let activity = EffectsUniformsComputer.visualActivity(time: Float(newTime), transitionProgress: tp)
            if let a = sync.activity.next(activity, at: newTime) { music.setVisualActivity(a) }
            if DebugLaunchOptions.syncLog, Int(newTime) != sync.lastLogSecond {
                sync.lastLogSecond = Int(newTime)
                logSync(time: Float(newTime))
            }
            let currentSecond = Int(newTime)
            if currentSecond > lastLoggedSecond {
                lastLoggedSecond = currentSecond
                let uniforms = effectUniforms
                let morphing = transitionManager.isMorphing
                LMLog.visual.debug("📐 KB t=\(String(format: "%.1f", newTime)) scale=\(String(format: "%.3f", uniforms.kenBurnsScale)) offset=(\(String(format: "%.1f", uniforms.kenBurnsOffsetX)),\(String(format: "%.1f", uniforms.kenBurnsOffsetY))) morph=\(morphing)")
            }
        }
        .onDisappear {
            transitionManager.stop()
            effectController.stop()
        }
    }

    /// DEBUG -LiminalSyncLog: one line per second.
    private func logSync(time: Float) {
        let params = frameParams()
        let neutral = EffectsUniformsComputer.compute(
            time: DebugLaunchOptions.effectTime(time),
            transitionProgress: Float(transitionManager.transitionProgress),
            hasSaliencyMap: transitionManager.currentSaliencyMap != nil,
            vibrance: currentVibrance())
        let line = MusicSyncLog.line(reactor: sync.reactor, state: music.musicState.read(), uniforms: params.uniforms,
                                     neutral: neutral, mood: sync.lastMood, activity: sync.activity.lastSent)
        LMLog.visual.info("\(line, privacy: .public)")
    }
}

// MARK: - Audio Slider Component

struct AudioSlider: View {
    let label: String
    @Binding var value: Float
    let leftIcon: String
    let rightIcon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Image(systemName: leftIcon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Slider(value: $value, in: 0...1)
                Image(systemName: rightIcon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
        }
    }
}

#Preview {
    ContentView()
}

#endif
