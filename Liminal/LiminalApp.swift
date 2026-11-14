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
        // 3:2 visual area plus the control panel (the window delegate keeps the ratio on resize).
        .defaultSize(width: 640 * 1.5 + ContentView.panelWidth + 1, height: 640)
    }
}

#endif
