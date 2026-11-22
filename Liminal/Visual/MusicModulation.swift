//
//  MusicModulation.swift
//  Liminal
//
//  Music -> visuals coupling values handed to EffectsUniformsComputer.
//  Plain floats, produced once per frame by MusicReactor. No new uniforms: the computer maps these
//  onto existing ones, and `.neutral` reproduces the un-coupled output exactly.
//

import Foundation

nonisolated struct MusicModulation: Sendable, Equatable {
    /// Master wet 0...1 (toggle on and music alive), eased over 1.5 s. Every deviation is scaled by it.
    /// DEBUG -LiminalSyncStrength can push it above 1; the computer's caps still apply.
    var amount: Float = 0
    /// Smoothed phrase intensity 0...1 (2 s).
    var energy: Float = 0.4
    /// Onset envelope, fast follower (90 ms attack, 450 ms release): colour and glow.
    var pulseColor: Float = 0
    var fillAccent: Float = 0
    /// Onset envelope, slow follower (180 ms attack, 900 ms release): geometry.
    var pulseMotion: Float = 0
    /// Integrated hue phase plus the harmony offset (turns). Written straight to `hueBaseShift`.
    var hueBaseShift: Float = 0
    /// Integrated motion timing offset, kept for coupling diagnostics.
    var motionLead: Float = 0
    /// Increments on each phrase change and each rhythm trail; renderers forward it to GhostTapManager.requestBurst.
    var ghostBurstSerial: UInt32 = 0
    /// 0...1 swell of the ghost-tap travel distance after a phrase change.
    var ghostReach: Float = 0

    static let neutral = MusicModulation()

    /// Neutral modulation with a fixed hue shift (macOS keeps `time * 0.03` when the reactor is bypassed).
    static func unsynced(hueBaseShift: Float) -> MusicModulation {
        var m = MusicModulation()
        m.hueBaseShift = hueBaseShift
        return m
    }
}
