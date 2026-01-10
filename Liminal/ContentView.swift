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
                    .onChange(of: audioEngine.currentScale) { _, newValue in
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
    @State private var displayedImage: NSImage?
    @State private var imageID = UUID()

    var body: some View {
        ZStack {
            // Background
            Color.black

            // Current image with crossfade animation
            if let image = displayedImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .id(imageID)
                    .transition(.opacity.animation(.easeInOut(duration: 2.0)))
            } else {
                // Placeholder
                VStack(spacing: 12) {
                    if visualEngine.isGenerating {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Generating...")
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
        .clipped()
        .onChange(of: visualEngine.currentImage) { _, newImage in
            withAnimation(.easeInOut(duration: 2.0)) {
                displayedImage = newImage
                imageID = UUID()
            }
        }
        .onAppear {
            displayedImage = visualEngine.currentImage
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
