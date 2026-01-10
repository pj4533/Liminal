//
//  ContentView.swift
//  Liminal
//
//  Created by PJ Gray on 1/10/26.
//

import SwiftUI
import OSLog

struct ContentView: View {
    @State private var apiKeyStatus = "Checking..."
    @StateObject private var audioEngine = GenerativeEngine()
    @StateObject private var visualEngine = VisualEngine()
    @StateObject private var settings = SettingsService.shared

    var body: some View {
        HStack(spacing: 0) {
            // Visual display area
            VisualDisplayView(visualEngine: visualEngine, isPlaying: audioEngine.isRunning)
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
                }

                Text(apiKeyStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                // Mood sliders - bind to mood's published properties
                MoodSlidersView(mood: audioEngine.mood)
                    .padding(.horizontal)

                // Scale (auto-selected by mood, but can override)
                HStack {
                    Text("Scale:")
                        .foregroundStyle(.secondary)
                    Picker("", selection: $audioEngine.currentScale) {
                        ForEach(ScaleType.allCases, id: \.self) { scale in
                            Text(scale.rawValue).tag(scale)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                    .onChange(of: audioEngine.currentScale, initial: false) { _, newValue in
                        settings.scaleName = newValue.rawValue
                    }
                }

                Spacer()

                // Play/Stop
                Button(audioEngine.isRunning ? "Stop" : "Play") {
                    if audioEngine.isRunning {
                        audioEngine.stop()
                        visualEngine.stop()
                        // Save settings when stopping
                        settings.saveFrom(mood: audioEngine.mood)
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
        .onAppear {
            let hasKey = EnvironmentService.shared.hasValidCredentials
            apiKeyStatus = hasKey ? "✓ Gemini API ready" : "✗ Missing API key"
            visualEngine.observeMood(audioEngine.mood)

            // Apply saved settings
            settings.applyTo(mood: audioEngine.mood)
            audioEngine.currentScale = settings.scale
        }
    }
}

// MARK: - Visual Display

struct VisualDisplayView: View {
    @ObservedObject var visualEngine: VisualEngine
    let isPlaying: Bool
    @StateObject private var morphPlayer = MorphPlayer()
    @StateObject private var effectController = EffectController()
    @State private var lastLoggedSecond: Int = -1

    // Ken Burns is now computed from effectController.time for smooth continuous motion
    private var kenBurnsScale: CGFloat {
        // Oscillates between 1.0 and 1.4 using multiple sine waves for organic feel
        let base = 1.2
        let variation = 0.15 * sin(effectController.time * 0.05) + 0.05 * sin(effectController.time * 0.03)
        return CGFloat(base + variation)
    }

    private var kenBurnsOffset: CGSize {
        // Lissajous-like pattern for smooth panning that never jumps
        let maxOffset: Double = 60
        return CGSize(
            width: maxOffset * sin(effectController.time * 0.04) + 20 * sin(effectController.time * 0.025),
            height: maxOffset * cos(effectController.time * 0.035) + 20 * cos(effectController.time * 0.02)
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                Color.black

                // Current frame from morph player with Ken Burns + Effects
                if let image = morphPlayer.currentFrame {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(kenBurnsScale)
                        .offset(kenBurnsOffset)
                        // Dreamy fBM distortion - underwater/heat haze feel (slow, oscillating)
                        .dreamyDistortion(time: effectController.time, amplitude: 0.012, speed: 0.08)
                        // Hue rotation for color drift (noticeable but not jarring)
                        .hueShift(amount: effectController.time * 0.04)

                    // Status overlay (top corners)
                    VStack {
                        HStack {
                            // Pool size (bottom-left when we flip)
                            HStack(spacing: 4) {
                                Image(systemName: "photo.stack")
                                    .font(.caption2)
                                Text("\(morphPlayer.poolSize)")
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
                        if visualEngine.isGenerating || morphPlayer.isMorphing {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text(morphPlayer.isMorphing ? "Morphing..." : "Generating...")
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
                morphPlayer.transitionTo(image)
            }
        }
        .onChange(of: visualEngine.nextImage) { (_, upcomingImage: NSImage?) in
            // Pre-generate morph frames in background for seamless transition
            if let upcoming = upcomingImage {
                morphPlayer.preloadMorphTo(upcoming)
            }
        }
        .onAppear {
            morphPlayer.start()
            // Effects start when Play is pressed, not on appear
            if let image = visualEngine.currentImage {
                morphPlayer.setInitialImage(image)
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
        .onChange(of: effectController.time) { _, newTime in
            // Log Ken Burns values once per second
            let currentSecond = Int(newTime)
            if currentSecond > lastLoggedSecond {
                lastLoggedSecond = currentSecond
                let scale = kenBurnsScale
                let offset = kenBurnsOffset
                let morphing = morphPlayer.isMorphing
                LMLog.visual.debug("📐 KB t=\(String(format: "%.1f", newTime)) scale=\(String(format: "%.3f", scale)) offset=(\(String(format: "%.1f", offset.width)),\(String(format: "%.1f", offset.height))) morph=\(morphing)")
            }
        }
        .onDisappear {
            morphPlayer.stop()
            effectController.stop()
        }
    }
}

// MARK: - Mood Sliders Container

struct MoodSlidersView: View {
    @ObservedObject var mood: MoodState

    var body: some View {
        VStack(spacing: 12) {
            MoodSlider(
                label: "Brightness",
                value: $mood.brightness,
                leftIcon: "moon.fill",
                rightIcon: "sun.max.fill"
            )
            MoodSlider(
                label: "Tension",
                value: $mood.tension,
                leftIcon: "leaf.fill",
                rightIcon: "bolt.fill"
            )
            MoodSlider(
                label: "Density",
                value: $mood.density,
                leftIcon: "circle.dotted",
                rightIcon: "circle.grid.3x3.fill"
            )
            MoodSlider(
                label: "Movement",
                value: $mood.movement,
                leftIcon: "pause.fill",
                rightIcon: "wind"
            )
        }
    }
}

// MARK: - Mood Slider Component

struct MoodSlider: View {
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
