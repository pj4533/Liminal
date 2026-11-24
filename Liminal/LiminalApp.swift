//
//  LiminalApp.swift
//  Liminal
//
//  Created by PJ Gray on 1/10/26.
//

#if os(macOS)

import SwiftUI

@main
struct LiminalApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 640 * ImageFraming.displayAspect + VisualWindowDelegate.controlPanelWidth, height: 640)
    }
}

#endif
