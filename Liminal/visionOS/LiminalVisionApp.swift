//
//  LiminalVisionApp.swift
//  Liminal
//
//  visionOS app entry point: the controls window plus ONE immersive space, the wrap-around
//  depth-relief shell with the effects on it (docs/plans/spatial.md). The two earlier immersive
//  modes were merged into it (decision S1).
//

#if os(visionOS)

import SwiftUI

@main
struct LiminalVisionApp: App {
    /// The single immersive space.
    static let immersiveSpaceID = "liminalSpace"
    static let controlsWindowID = "liminalControls"

    @StateObject private var audioEngine = GenerativeEngine()
    @StateObject private var visualEngine = VisualEngine()
    @StateObject private var settings = SettingsService.shared
    @State private var isImmersed = false
    @State private var controlsVisible = true
    @State private var immersivePictureReady = false

    @State private var immersionStyle: ImmersionStyle = .full

    var body: some Scene {
        WindowGroup(id: Self.controlsWindowID) {
            ControlsView(audioEngine: audioEngine, visualEngine: visualEngine,
                         isImmersed: $isImmersed, controlsVisible: $controlsVisible,
                         immersivePictureReady: immersivePictureReady)
        }
        // Use automatic (default) window style - system handles glass and chrome
        .defaultSize(width: DebugLaunchOptions.controlsWidth ?? 1240, height: 960)

        ImmersiveSpace(id: Self.immersiveSpaceID) {
            ImmersiveDomeView(visualEngine: visualEngine, settings: settings, music: audioEngine,
                              isImmersed: $isImmersed, controlsVisible: $controlsVisible,
                              immersivePictureReady: $immersivePictureReady)
        }
        .immersionStyle(selection: $immersionStyle, in: .full)
    }
}

#endif
