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
        .defaultSize(width: 320, height: 560)

        ImmersiveSpace(id: "liminalDome") {
            ImmersiveDomeView(visualEngine: visualEngine, settings: settings)
        }
        .immersionStyle(selection: $immersionStyle, in: .progressive, .full)
    }
}

#endif
