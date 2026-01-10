//
//  ContentView.swift
//  Liminal
//
//  Created by PJ Gray on 1/10/26.
//

import SwiftUI

struct ContentView: View {
    @State private var apiKeyStatus = "Checking..."
    @StateObject private var audioEngine = GenerativeEngine()
    @StateObject private var visualEngine = VisualEngine()
    @StateObject private var settings = SettingsService.shared
    @State private var imageInterval: Double = 30.0

    var body: some View {
        HStack(spacing: 0) {
            // Visual display area
            VisualDisplayView(visualEngine: visualEngine)
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

                // Image interval slider
                VStack(alignment: .leading, spacing: 4) {
                    Text("Image Interval: \(Int(imageInterval))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $imageInterval, in: 10...120, step: 5)
                        .onChange(of: imageInterval) { _, newValue in
                            settings.imageInterval = newValue
                        }
                }
                .padding(.horizontal)

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
            imageInterval = settings.imageInterval
        }
    }
}

// MARK: - Visual Display

struct VisualDisplayView: View {
    @ObservedObject var visualEngine: VisualEngine
    @StateObject private var morphPlayer = MorphPlayer()
    @StateObject private var effectController = EffectController()
    @State private var kenBurnsScale: CGFloat = 1.0
    @State private var kenBurnsOffset: CGSize = .zero

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
                        // Dreamy fBM distortion - underwater/heat haze feel
                        .dreamyDistortion(time: effectController.time, amplitude: 0.018, speed: 0.2)
                        // Slow hue rotation for color drift
                        .hueShift(amount: effectController.time * 0.015)

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

                            // Preloading indicator (top-right)
                            if morphPlayer.isPreloading {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                    Text("Preloading...")
                                        .font(.caption2)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.ultraThinMaterial)
                                .cornerRadius(6)
                                .padding(8)
                            }
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
                startKenBurnsAnimation()
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
            effectController.start()
            if let image = visualEngine.currentImage {
                morphPlayer.setInitialImage(image)
                startKenBurnsAnimation()
            }
        }
        .onDisappear {
            morphPlayer.stop()
            effectController.stop()
        }
    }

    private func startKenBurnsAnimation() {
        // Reset to starting position
        kenBurnsScale = 1.0
        kenBurnsOffset = .zero

        // Random direction for this cycle - MORE DRAMATIC now!
        let targetScale = CGFloat.random(in: 1.15...1.25)
        let maxOffset: CGFloat = 40
        let targetOffset = CGSize(
            width: CGFloat.random(in: -maxOffset...maxOffset),
            height: CGFloat.random(in: -maxOffset...maxOffset)
        )

        // Slow continuous zoom/pan over the image interval
        withAnimation(.easeInOut(duration: SettingsService.shared.imageInterval)) {
            kenBurnsScale = targetScale
            kenBurnsOffset = targetOffset
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
