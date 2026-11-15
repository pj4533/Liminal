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

    @StateObject private var audioEngine = GenerativeEngine()
    @StateObject private var visualEngine = VisualEngine()
    @StateObject private var settings = SettingsService.shared

    /// Progressive by default at full immersion (the Digital Crown can bring the room back down to
    /// 40%), or full.
    @State private var immersionStyle: ImmersionStyle = .progressive(0.4...1.0, initialAmount: 1.0)

    var body: some Scene {
        WindowGroup {
            ControlsView(audioEngine: audioEngine, visualEngine: visualEngine)
        }
        // Use automatic (default) window style - system handles glass and chrome
        .defaultSize(width: 1240, height: 960)

        ImmersiveSpace(id: Self.immersiveSpaceID) {
            ImmersiveDomeView(visualEngine: visualEngine, settings: settings, music: audioEngine)
        }
        .immersionStyle(selection: $immersionStyle, in: .progressive(0.4...1.0, initialAmount: 1.0), .full)
    }
}

#endif
