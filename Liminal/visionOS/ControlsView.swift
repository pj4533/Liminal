//
//  ControlsView.swift
//  Liminal
//
//  visionOS floating controls for audio/visual parameters.
//

#if os(visionOS)

import SwiftUI

struct ControlsView: View {
    @ObservedObject var audioEngine: GenerativeEngine
    @ObservedObject var visualEngine: VisualEngine
    @ObservedObject private var settings = SettingsService.shared

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var isImmersed = false
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 24) {
            // Title with settings gear
            HStack {
                Text("Liminal")
                    .font(.largeTitle)
                    .fontWeight(.light)

                Spacer()

                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gear")
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
            }

            // Play/Stop controls
            HStack(spacing: 20) {
                Button(action: {
                    if audioEngine.isRunning {
                        audioEngine.stop()
                        visualEngine.stop()
                    } else {
                        audioEngine.start()
                        visualEngine.start()
                    }
                }) {
                    Label(
                        audioEngine.isRunning ? "Stop" : "Play",
                        systemImage: audioEngine.isRunning ? "stop.fill" : "play.fill"
                    )
                    .font(.title2)
                }
                .buttonStyle(.borderedProminent)

                // Immersive Space toggle
                Button(action: {
                    Task {
                        if isImmersed {
                            await dismissImmersiveSpace()
                            isImmersed = false
                        } else {
                            let result = await openImmersiveSpace(id: "liminalDome")
                            if case .opened = result {
                                isImmersed = true
                            }
                        }
                    }
                }) {
                    Label(
                        isImmersed ? "Exit Dome" : "Enter Dome",
                        systemImage: isImmersed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                    )
                    .font(.title2)
                }
                .buttonStyle(.bordered)
            }

            Divider()

            // Audio Parameters - bound to settings (persisted)
            VStack(alignment: .leading, spacing: 16) {
                Text("Audio")
                    .font(.headline)

                // Delay (0-1 range)
                VStack(alignment: .leading) {
                    Text("Delay: \(Int(settings.delay * 100))%")
                        .font(.caption)
                    Slider(value: $settings.delay, in: 0...1)
                }

                // Reverb (0-1 range)
                VStack(alignment: .leading) {
                    Text("Reverb: \(Int(settings.reverb * 100))%")
                        .font(.caption)
                    Slider(value: $settings.reverb, in: 0...1)
                }

                // Notes (0-1 range)
                VStack(alignment: .leading) {
                    Text("Notes: \(Int(settings.notes * 100))%")
                        .font(.caption)
                    Slider(value: $settings.notes, in: 0...1)
                }
            }

            Divider()

            // Scale Picker - bound to settings (persisted)
            VStack(alignment: .leading, spacing: 8) {
                Text("Scale")
                    .font(.headline)

                Picker("Scale", selection: $settings.currentScale) {
                    ForEach(ScaleType.allCases, id: \.self) { scale in
                        Text(scale.rawValue).tag(scale)
                    }
                }
                .pickerStyle(.menu)
            }

            Spacer()

            // Status
            HStack {
                Circle()
                    .fill(audioEngine.isRunning ? .green : .gray)
                    .frame(width: 8, height: 8)
                Text(audioEngine.isRunning ? "Playing" : "Stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                // Cached image count
                HStack(spacing: 4) {
                    Image(systemName: "photo.stack")
                        .font(.caption2)
                    Text("\(visualEngine.totalCachedCount)")
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.secondary)

                Divider()
                    .frame(height: 12)

                Text("Queue: \(visualEngine.queuedCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 320, height: 500)
        .glassBackgroundEffect()
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
            VisionSettingsSheetView(audioEngine: audioEngine)
        }
    }
}

// MARK: - Settings Sheet

struct VisionSettingsSheetView: View {
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject var audioEngine: GenerativeEngine
    @Environment(\.dismiss) private var dismiss

    private var apiKeyStatus: String {
        EnvironmentService.shared.hasValidCredentials ? "Gemini API ready" : "Missing API key"
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                // API Status
                VStack(alignment: .leading, spacing: 12) {
                    Label("API", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    HStack {
                        Circle()
                            .fill(EnvironmentService.shared.hasValidCredentials ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(apiKeyStatus)
                            .font(.body)
                    }
                }

                Divider()

                // Visual Settings
                VStack(alignment: .leading, spacing: 12) {
                    Label("Visuals", systemImage: "sparkles")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    Toggle("Cache Only Mode", isOn: $settings.cacheOnly)

                    Text("When enabled, only cached images are used. No new images will be generated.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Reset Button
                VStack(alignment: .leading, spacing: 12) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    Button("Reset All to Defaults", role: .destructive) {
                        settings.resetToDefaults()
                        audioEngine.delay = settings.delay
                        audioEngine.reverb = settings.reverb
                        audioEngine.notes = settings.notes
                        audioEngine.currentScale = settings.currentScale
                    }

                    Text("Resets all audio and visual settings to defaults.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(24)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 380, height: 400)
    }
}

#endif
