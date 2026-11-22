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
/// (width = height * visualAspect + controlPanelWidth). Pictures are shown 3:2.
final class SquareVisualWindowDelegate: NSObject, NSWindowDelegate {
    /// Panel + 1 divider; 0 when -LiminalHideControls YES shows the picture alone (content-only recordings).
    static let controlPanelWidth: CGFloat = DebugLaunchOptions.hideControls ? 0 : ContentView.panelWidth + 1
    static let visualAspect: CGFloat = ImageFraming.displayAspect  // 3:2, the pictures' display crop

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
    /// Width of the control panel. Wide enough for "Natural Minor (Aeolian)" in the scale menu.
    static let panelWidth: CGFloat = 320

    @State private var showingSettings = false
    @StateObject private var audioEngine = GenerativeEngine()
    @StateObject private var visualEngine = VisualEngine()
    @StateObject private var settings = SettingsService.shared

    var body: some View {
        HStack(spacing: 0) {
            // Visual display area
            VisualDisplayView(visualEngine: visualEngine, settings: settings, isPlaying: audioEngine.isPlaybackReady,
                              music: audioEngine)
                .frame(minWidth: 400, minHeight: 400)

            if !DebugLaunchOptions.hideControls {
                Divider()

                // Control panel
                controlPanel
                    .frame(width: Self.panelWidth)
            }
        }
        .frame(minWidth: 400 + SquareVisualWindowDelegate.controlPanelWidth, minHeight: 560)
        .background(WindowAccessor())
        .onAppear {
            // Apply saved settings to audio engine on launch
            audioEngine.options = settings.lofiOptions

            // DEBUG perf harness: -LiminalAutoPlay YES (always false in Release)
            DebugLaunchOptions.logApplied()
            RecordingController.shared.scheduleDebugRecording(audio: audioEngine)
            if DebugLaunchOptions.autoPlay, !audioEngine.isRunning {
                audioEngine.start()
                LMLog.general.info("🧪 DEBUG: auto-play started")
            }
        }
        // Settings -> AudioEngine: propagate changes immediately
        .onChange(of: settings.lofiOptions) { _, options in audioEngine.options = options }
        .onChange(of: audioEngine.isPlaybackReady, initial: true) { _, playing in
            if playing { visualEngine.start(music: audioEngine) } else { visualEngine.stop() }
        }
        .archiveFootageSettings(settings, audioEngine: audioEngine)
        .sheet(isPresented: $showingSettings) {
            SettingsSheetView(audioEngine: audioEngine, visualEngine: visualEngine)
        }
    }
}


// MARK: - Control panel

extension ContentView {
    var controlPanel: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    Text("Liminal")
                        .font(.title.weight(.semibold))
                }
                .padding(.bottom, 4)

                ControlSection(title: "Playback", systemImage: "play.circle") {
                    Button(action: togglePlayback) {
                        Label(audioEngine.isRunning ? (audioEngine.isPlaybackReady ? "Stop" : "Cancel") : "Play",
                              systemImage: audioEngine.isRunning ? "stop.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    PlaybackStatus(isPlaying: audioEngine.isPlaybackReady,
                           isPreparing: audioEngine.isRunning && !audioEngine.isPlaybackReady,
                                   poolCount: visualEngine.poolCount,
                                   queuedCount: visualEngine.queuedCount)
                    RecordControls(audio: audioEngine)
                    if let status = visualEngine.statusMessage {
                        Label(status, systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.yellow)
                            .wrapping()
                    }
                }

                ControlSection(title: "Music", systemImage: "music.note") {
                    MusicControls(settings: settings)
                }

                ControlSection(title: "Visuals", systemImage: "sparkles") {
                    ValueSlider(title: "Effect intensity", value: $settings.effectIntensity,
                                minimumLabel: "Subtle", maximumLabel: "Wild",
                                explanation: "How far the effects bend the picture. Low keeps the image clear.")
                    ExplainedToggle(title: "Sync visuals to music",
                                    explanation: "Color, motion and bloom follow the music as it plays.",
                                    isOn: $settings.syncVisualsToMusic)
                    ExplainedToggle(title: "Debug effect",
                                    explanation: "Turns the effect under test (bloom) on or off.",
                                    isOn: $settings.debugEffectEnabled)
                }

                ArchiveFootageSection(settings: settings)
                    .id("archive")

                ControlSection(title: "Images & Storage", systemImage: "photo.stack") {
                    CollectionsStatusRow(status: visualEngine.sourceStatus)
                    ImageCreditLine(metadata: visualEngine.currentMetadata)
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Storage & Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .keyboardShortcut(",", modifiers: .command)
                }
                .id("images")
            }
            .padding(16)
        }
        .scrollIndicators(.automatic)
        .onAppear {
            // DEBUG: -LiminalControlsScroll archive (settings screenshots).
            if let id = DebugLaunchOptions.controlsScroll {
                Task { try? await Task.sleep(nanoseconds: 800_000_000); proxy.scrollTo(id, anchor: .top) }
            }
        }
        }
    }

    private func togglePlayback() {
        if audioEngine.isRunning {
            RecordingController.shared.playbackStopped()   // finish and save the movie first
            audioEngine.stop()
        } else {
            audioEngine.start()
        }
    }
}

// MARK: - Settings Sheet

struct SettingsSheetView: View {
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject var audioEngine: GenerativeEngine
    @ObservedObject var visualEngine: VisualEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Storage & Settings")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ControlSection(title: "Images", systemImage: "photo.stack") {
                        ClearImagesSection(visualEngine: visualEngine)
                    }

                    ControlSection(title: "Reset", systemImage: "arrow.counterclockwise") {
                        Button("Reset All Settings", role: .destructive) {
                            settings.resetToDefaults()
                        }
                        Text("Restores tempo, scale, visual and footage settings to their defaults.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .wrapping()
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 440)
        .frame(minHeight: 420, idealHeight: 560)
    }
}

// MARK: - Visual Display

/// Music <-> visuals coupling state for the macOS render path. A plain class held in `@State`
/// (not observable), so mutating it while SwiftUI evaluates `body` never invalidates the view.
final class MusicSyncBox {
    var reactor = MusicReactor(strength: DebugLaunchOptions.syncStrength)
    var lastLogSecond = -1
    /// Effect time at which the current image's crossfade began (nil before the first crossfade).
    var transitionStart: Float?
    var zoom = ImageZoomTiming()
    /// The current (or last) image transition; its duration also anchors the fresh-image hold.
    var transition: TransitionSpec = .classic
    var intensity = EffectIntensitySmoother()
    /// Effect-controller time of the last footage-conditions update.
    var lastFootageUpdate: Double = 0

    /// The effect look for this frame (effects-balance plan 7.3).
    func look(effectTime: Float, setting: Float, imageInterval: Double) -> EffectLook {
        let target = DebugLaunchOptions.effectIntensity(setting: setting)
        let i = DebugLaunchOptions.freezeTime != nil ? target : intensity.next(target: target, time: effectTime)
        let age = transitionStart.map { effectTime - $0 }.flatMap { $0 >= 0 ? $0 : nil }
        return EffectLook(intensity: i, imageAge: age, imageInterval: Float(imageInterval),
                          transitionDuration: transition.duration,
                          freshFadeEnd: transition.drop != nil ? transition.duration : nil)
    }
}

struct VisualDisplayView: View {
    @ObservedObject var visualEngine: VisualEngine
    @ObservedObject var settings: SettingsService
    let isPlaying: Bool
    /// Plain reference, not observed: only its nonisolated state bus is read.
    let music: GenerativeEngine
    @StateObject private var transitionManager = TimerDrivenCrossfade()
    @StateObject private var effectController = EffectController()
    @State private var lastLoggedSecond: Int = -1
    @State private var sync = MusicSyncBox()

    // Single uniforms struct - matches visionOS pattern for platform parity
    private var effectUniforms: EffectsUniforms { frameParams().uniforms }

    /// Uniforms plus the music modulation they were built from (the renderer also needs its burst serial).
    /// Called at least twice per tick (body and the log `onChange`); the reactor caches repeated times.
    private func frameParams() -> (uniforms: EffectsUniforms, modulation: MusicModulation, cut: EffectsUniforms?) {
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
        // Archive footage (docs/plans/archive-video.md): one lock read; the tint is measured once per picture.
        let frame = transitionManager.currentFrame
        let footage = ArchiveFootageService.shared.frame(key: frame) {
            frame?.cgImageRepresentation.map { ImageFraming.coverCrop($0) }
        }
        // A drop (docs/plans/drop-transitions.md 3.5) is evaluated at the frame's presentation time; the
        // draw switches to `cut` (an ordinary frame of the new picture) on the first frame past the downbeat.
        let reveal = transitionManager.isMorphing ? transitionManager.beatReveal : nil
        let dropReveal = reveal?.isDrop == true ? reveal : nil
        let look = currentLook(effectTime: effectTime)
        var uniforms = EffectsUniformsComputer.compute(
            time: effectTime,
            transitionProgress: Float(transitionManager.transitionProgress),
            hasSaliencyMap: transitionManager.currentSaliencyMap != nil,
            vibrance: dropReveal != nil ? previousVibrance() ?? vibrance : vibrance,
            music: modulation,
            look: look,
            zoomAge: sync.zoom.age(at: effectTime, cut: dropReveal == nil),
            outgoingZoomScale: transitionManager.previousFrame == nil ? 0 : sync.zoom.outgoingScale,
            transition: sync.transition,
            video: footage.state,
            drop: dropReveal?.frame(presentedAt: ArchiveFootageService.uptime() + EffectsMetalView.dropLead)
        )
        var cut: EffectsUniforms?
        if dropReveal != nil {
            cut = EffectsUniformsComputer.compute(
                time: effectTime, hasSaliencyMap: transitionManager.currentSaliencyMap != nil, vibrance: vibrance,
                music: modulation, look: look, zoomAge: sync.zoom.age(at: effectTime, cut: true), video: footage.state)
        }
        // Debug toggle controls the effect currently being tested
        if !settings.debugEffectEnabled {
            uniforms.bloomAmount = 0
            cut?.bloomAmount = 0
        }
        return (uniforms, modulation, cut)
    }

    /// The outgoing picture's vibrance factors (a drop keeps them until the cut).
    private func previousVibrance() -> VibranceFactors? {
        guard let prev = transitionManager.previousFrame else { return nil }
        return ImageColorStats.cachedFactors(key: prev) { prev.cgImageRepresentation.map { ImageFraming.coverCrop($0) } }
    }

    private func currentLook(effectTime: Float) -> EffectLook {
        sync.look(effectTime: effectTime, setting: settings.effectIntensity, imageInterval: settings.imageInterval)
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

    /// The transition for a crossfade that is starting (docs/plans/transitions.md 7). macOS binds no depth map.
    private func pickTransition() -> TransitionSpec {
        let effectTime = DebugLaunchOptions.effectTime(Float(effectController.time))
        let modulation = frameParams().modulation
        return visualEngine.nextTransition(
            effectTime: effectTime,
            intensity: DebugLaunchOptions.effectIntensity(setting: settings.effectIntensity),
            energy: modulation.amount > 0 ? modulation.energy : nil,
            hasDepth: false)
    }

    /// Hue drift of the un-synced macOS look (turns per second).
    private static let baseHueRate: Float = 0.03

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
                        stagedImage: visualEngine.stagedImage,
                        beatReveal: transitionManager.isMorphing ? transitionManager.beatReveal : nil,
                        previousImage: transitionManager.previousFrame,  // GPU crossfade blending
                        saliencyMap: transitionManager.currentSaliencyMap,
                        uniforms: params.uniforms,
                        cutUniforms: params.cut,
                        ghostBurstSerial: params.modulation.ghostBurstSerial
                    )
                    // Keep the image at its 3:2 display aspect even if the window is not exactly
                    // 3:2 (min sizes, full screen): letterbox on black instead of stretching.
                    .aspectRatio(ImageFraming.displayAspect, contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)

                    // Status overlay (top corners), hidden with the controls (-LiminalHideControls).
                    if !DebugLaunchOptions.hideControls { VStack {
                        HStack {
                            // Saved pictures count
                            HStack(spacing: 4) {
                                Image(systemName: "photo.stack")
                                    .font(.caption2)
                                Text("\(visualEngine.poolCount)")
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
                    } }
                } else {
                    // Placeholder
                    VStack(spacing: 12) {
                        if transitionManager.isMorphing {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("Morphing...")
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
        .onReceive(visualEngine.$stagedImage) { staged in
            if let staged, let image = staged.image { transitionManager.prepareSaliency(for: image, pixels: staged.cgImage) }
        }
        .onChange(of: visualEngine.currentImage) { _, newImage in
            if let image = newImage {
                let hadFrame = transitionManager.currentFrame != nil
                let started = transitionManager.transitionTo(image, reveal: visualEngine.reveal, duration: {
                    sync.transition = pickTransition()
                    return Double(sync.transition.duration)
                })
                if started || !hadFrame {
                    let time = DebugLaunchOptions.effectTime(Float(effectController.time))
                    if started { sync.transitionStart = time }
                    let zoomStart = !hadFrame && DebugLaunchOptions.freezeTime != nil ? 0 : time
                    // A drop: the new picture's push starts on the cut, not under the build.
                    let cut = started ? visualEngine.reveal.flatMap { r in
                        r.isDrop ? zoomStart + Float(r.downbeat - ArchiveFootageService.uptime()) : nil } : nil
                    sync.zoom.imageChanged(at: zoomStart, replacing: started, holdUntil: cut)
                }
            } else {
                // The pictures were cleared: reset the transition manager.
                transitionManager.reset()
            }
        }
        // Morphs trigger only when currentImage changes
        .onAppear {
            transitionManager.start()
            // Effects start when Play is pressed, not on appear
            if let image = visualEngine.currentImage {
                transitionManager.setInitialImage(image)
            }
        }
        .onChange(of: isPlaying) { _, playing in
            if playing {
                lastLoggedSecond = -1  // Reset so first log happens immediately
                sync.transitionStart = nil  // the effect clock restarts at 0
                sync.zoom = ImageZoomTiming()
                effectController.start()
                ArchiveFootageService.shared.start()
            } else {
                effectController.stop()
                ArchiveFootageService.shared.stop()
            }
        }
        // Log Ken Burns values periodically for debugging
        .onChange(of: effectController.time) { _, newTime in
            // Archive footage: what the footage weaver listens to (about 2 Hz).
            if newTime - sync.lastFootageUpdate >= 0.5 || newTime < sync.lastFootageUpdate {
                sync.lastFootageUpdate = newTime
                let modulation = sync.reactor.modulation
                ArchiveFootageService.shared.update(.init(
                    musicIntensity: modulation.amount > 0 ? modulation.energy : 0,
                    effectIntensity: DebugLaunchOptions.effectIntensity(setting: settings.effectIntensity)))
            }
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
            vibrance: currentVibrance(),
            look: currentLook(effectTime: DebugLaunchOptions.effectTime(time)),
            transition: sync.transition)
        let line = MusicSyncLog.line(reactor: sync.reactor, state: music.musicState.read(), uniforms: params.uniforms,
                                     neutral: neutral)
        LMLog.visual.info("\(line, privacy: .public)")
    }
}

#Preview {
    ContentView()
}

#endif
