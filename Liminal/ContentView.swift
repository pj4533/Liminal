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

/// Enforces window resizing so visual area stays square (width = height + controlPanelWidth)
final class SquareVisualWindowDelegate: NSObject, NSWindowDelegate {
    static let controlPanelWidth: CGFloat = 281  // 280 panel + 1 divider

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // Calculate title bar height for this window
        let titleBarHeight = sender.frame.height - sender.contentRect(forFrameRect: sender.frame).height
        let contentHeight = frameSize.height - titleBarHeight
        // Enforce: visual width = visual height (square)
        // Total content width = visual width + control panel width
        let newWidth = contentHeight + Self.controlPanelWidth
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

            // Set initial frame to enforce square visual area
            let titleBarHeight = window.frame.height - window.contentRect(forFrameRect: window.frame).height
            let contentHeight = window.contentRect(forFrameRect: window.frame).height
            let newWidth = contentHeight + SquareVisualWindowDelegate.controlPanelWidth
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
            VisualDisplayView(visualEngine: visualEngine, settings: settings, isPlaying: audioEngine.isRunning)
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

                // Simple audio controls - bound to settings (single source of truth)
                VStack(spacing: 12) {
                    AudioSlider(
                        label: "Delay",
                        value: $settings.delay,
                        leftIcon: "waveform.slash",
                        rightIcon: "waveform.badge.plus"
                    )
                    AudioSlider(
                        label: "Reverb",
                        value: $settings.reverb,
                        leftIcon: "cube.transparent",
                        rightIcon: "cube.fill"
                    )
                    AudioSlider(
                        label: "Notes",
                        value: $settings.notes,
                        leftIcon: "music.note",
                        rightIcon: "music.quarternote.3"
                    )
                }
                .padding(.horizontal)

                // Scale selector - bound to settings
                HStack {
                    Text("Scale:")
                        .foregroundStyle(.secondary)
                    Picker("", selection: $settings.currentScale) {
                        ForEach(ScaleType.allCases, id: \.self) { scale in
                            Text(scale.rawValue).tag(scale)
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
            audioEngine.delay = settings.delay
            audioEngine.reverb = settings.reverb
            audioEngine.notes = settings.notes
            audioEngine.currentScale = settings.currentScale
        }
        // Settings -> AudioEngine: propagate changes immediately
        .onChange(of: settings.delay) { _, newValue in audioEngine.delay = newValue }
        .onChange(of: settings.reverb) { _, newValue in audioEngine.reverb = newValue }
        .onChange(of: settings.notes) { _, newValue in audioEngine.notes = newValue }
        .onChange(of: settings.currentScale) { _, newValue in audioEngine.currentScale = newValue }
        .sheet(isPresented: $showingSettings) {
            SettingsSheetView(audioEngine: audioEngine)
        }
    }
}

// MARK: - Settings Sheet

struct SettingsSheetView: View {
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject var audioEngine: GenerativeEngine
    @Environment(\.dismiss) private var dismiss
    @State private var cacheCount: Int = 0

    private var apiKeyStatus: String {
        EnvironmentService.shared.hasValidCredentials ? "✓ Gemini API ready" : "✗ Missing API key"
    }

    private func refreshCacheCount() {
        let cache = ImageCache()
        cacheCount = cache.count + cache.rawCount
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

                Button("Clear Image Cache") {
                    let cache = ImageCache()
                    cache.clearAll()
                    cache.clearAllRaw()
                }
                .foregroundStyle(.red)

                Text("Deletes all cached images. New images will be generated on next play.")
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
                    audioEngine.delay = settings.delay
                    audioEngine.reverb = settings.reverb
                    audioEngine.notes = settings.notes
                    audioEngine.currentScale = settings.currentScale
                }
                .foregroundStyle(.red)

                Text("Resets delay, reverb, notes, scale, and visual settings to their default values.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 400, height: 480)
        .onAppear {
            refreshCacheCount()
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageCacheCleared)) { _ in
            refreshCacheCount()
        }
    }
}

// MARK: - Visual Display

struct VisualDisplayView: View {
    @ObservedObject var visualEngine: VisualEngine
    @ObservedObject var settings: SettingsService
    let isPlaying: Bool
    @StateObject private var transitionManager = TimerDrivenCrossfade()
    @StateObject private var effectController = EffectController()
    @State private var lastLoggedSecond: Int = -1

    // Single uniforms struct - matches visionOS pattern for platform parity
    private var effectUniforms: EffectsUniforms {
        var uniforms = EffectsUniformsComputer.compute(
            time: Float(effectController.time),
            transitionProgress: Float(transitionManager.transitionProgress),
            hasSaliencyMap: transitionManager.currentSaliencyMap != nil
        )
        // Add time-based hue shift (macOS-specific for now)
        uniforms.hueBaseShift = Float(effectController.time * 0.03)
        // Debug toggle controls the effect currently being tested
        if !settings.debugEffectEnabled {
            uniforms.feedbackMix = 0
        }
        return uniforms
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                Color.black

                // Metal view with all effects + ghost tap trails
                if transitionManager.currentFrame != nil {
                    EffectsMetalViewRepresentable(
                        sourceImage: transitionManager.currentFrame,
                        previousImage: transitionManager.previousFrame,  // GPU crossfade blending
                        saliencyMap: transitionManager.currentSaliencyMap,
                        uniforms: effectUniforms,
                        delay: settings.delay
                    )
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
                transitionManager.transitionTo(image)
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
