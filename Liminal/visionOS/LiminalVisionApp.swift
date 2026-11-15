//
//  LiminalVisionApp.swift
//  Liminal
//
//  visionOS app entry point with ImmersiveSpace for dome experience.
//

#if os(visionOS)

import SwiftUI

@main
struct LiminalVisionApp: App {
    @StateObject private var audioEngine = GenerativeEngine()
    @StateObject private var visualEngine = VisualEngine()
    @StateObject private var settings = SettingsService.shared

    @State private var immersionStyle: ImmersionStyle = .progressive

    var body: some Scene {
        WindowGroup {
            ControlsView(audioEngine: audioEngine, visualEngine: visualEngine)
        }
        // Use automatic (default) window style - system handles glass and chrome
        .defaultSize(width: 1240, height: 960)

        ImmersiveSpace(id: "liminalDome") {
            ImmersiveDomeView(visualEngine: visualEngine, settings: settings, music: audioEngine)
        }
        .immersionStyle(selection: $immersionStyle, in: .progressive, .full)

        ImmersiveSpace(id: "liminalDiorama") {
            SpatialDioramaView(imageBuffer: visualEngine.imageBuffer)
        }
        .immersionStyle(selection: $immersionStyle, in: .progressive)
    }
}

#endif
