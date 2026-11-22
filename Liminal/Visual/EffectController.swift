//
//  EffectController.swift
//  Liminal
//

import SwiftUI
import Combine
import OSLog

/// The macOS effect clock: counts up at 60 Hz from Play and feeds the effect uniforms.
@MainActor
class EffectController: ObservableObject {
    @Published var time: Double = 0

    private var displayLink: Timer?
    private var frameCount: Int = 0

    func start() {
        time = 0
        frameCount = 0
        displayLink = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.time += 1.0/60.0
                self.frameCount += 1

                // Log every second (60 frames) for diagnostics
                if self.frameCount % 60 == 0 {
                    LMLog.visual.debug("⏱️ EFFECT t=\(String(format: "%.2f", self.time))")
                }
            }
        }
        LMLog.visual.info("Effect controller started at t=0")
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        LMLog.visual.info("Effect controller stopped at t=\(String(format: "%.2f", self.time))")
    }
}
