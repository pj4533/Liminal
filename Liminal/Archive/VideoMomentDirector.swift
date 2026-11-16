//
//  VideoMomentDirector.swift
//  Liminal
//
//  When archive footage appears, for how long, and how (docs/plans/archive-video.md 3). Pure and
//  seeded: ticked twice a second by ArchiveFootageService off the main actor. Times are seconds since
//  playback started (`elapsed`); the render loops only evaluate `MomentPlan.envelope(at:)`.
//

import Foundation

/// Footage amount setting (plan 3 table).
nonisolated enum VideoAmount: String, CaseIterable, Sendable {
    case rare, normal, often
}

/// One appearance of footage, fixed when it begins.
nonisolated struct MomentPlan: Sendable, Equatable {
    let clipID: String
    /// Source seconds where the segment starts.
    let segmentStart: Double
    /// Playback rate of the footage (and its sound), 0.6...0.85: slow motion reads as dreamlike.
    let rate: Float
    let look: VideoLook
    let seed: Float
    /// Elapsed seconds at which the fade in begins.
    let start: Double
    let fadeIn: Double
    let hold: Double
    let fadeOut: Double
    /// Elapsed seconds at which an early fade out began (clip ran out, stop, footage turned off).
    var earlyFadeOutAt: Double?
    var earlyFadeOut: Double?

    var fadeOutStart: Double { earlyFadeOutAt ?? (start + fadeIn + hold) }
    var end: Double { fadeOutStart + (earlyFadeOut ?? fadeOut) }
    var length: Double { end - start }
    /// Source seconds the moment consumes.
    var sourceLength: Double { (fadeIn + hold + fadeOut) * Double(rate) }

    /// 0...1: smoothstep fade in, hold, smoothstep fade out.
    func envelope(at t: Double) -> Float {
        guard t > start, t < end else { return 0 }
        let a = Self.smooth((t - start) / max(fadeIn, 0.01))
        let b = 1 - Self.smooth((t - fadeOutStart) / max(earlyFadeOut ?? fadeOut, 0.01))
        return Float(min(a, b))
    }

    /// Begins the fade out now (if it has not already begun), over `duration` seconds.
    mutating func fadeOutEarly(at t: Double, duration: Double) {
        guard t < fadeOutStart else { return }
        // Continue from the current level: the fade-in level at t is held as the fade-out's start.
        earlyFadeOutAt = t
        earlyFadeOut = duration
    }

    static func smooth(_ x: Double) -> Double { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }
}

nonisolated struct VideoMomentDirector {

    struct Timing: Sendable, Equatable {
        var first: ClosedRange<Double>
        var gap: ClosedRange<Double>
        var length: ClosedRange<Double> = 30...80
        var fadeIn: ClosedRange<Double> = 8...14
        var fadeOut: ClosedRange<Double> = 10...16
        var rate: ClosedRange<Float> = 0.6...0.85
        /// Never a moment before this (plan 3).
        var notBefore: Double = 60
        /// Longest wait for a transition / a fresh image before starting anyway, and for loud music.
        var maxImageWait: Double = 30
        var maxMusicWait: Double = 60

        static func amount(_ a: VideoAmount) -> Timing {
            switch a {
            case .rare: return Timing(first: 150...240, gap: 300...540)
            case .normal: return Timing(first: 90...150, gap: 150...360)
            case .often: return Timing(first: 60...90, gap: 60...150)
            }
        }
        /// -LiminalVideoForce: first moment at 5 s, 10 s gaps.
        static let forced = Timing(first: 5...5, gap: 10...10, notBefore: 0, maxImageWait: 6, maxMusicWait: 6)
    }

    struct Conditions: Sendable, Equatable {
        var transitionRunning = false
        /// Seconds since the current image's crossfade began (nil: no image yet / first image).
        var imageAge: Double? = nil
        /// Music energy 0...1.
        var musicIntensity: Float = 0
        /// Effect intensity setting 0...1.
        var effectIntensity: Float = 0.5
    }

    /// What to start: the service supplies the clip and the segment.
    struct Begin: Sendable, Equatable {
        let look: VideoLook
        let seed: Float
        let rate: Float
        let fadeIn: Double
        let hold: Double
        let fadeOut: Double
        var total: Double { fadeIn + hold + fadeOut }
    }

    enum Decision: Sendable, Equatable { case none, begin(Begin), end }

    let timing: Timing
    private var rng: MusicRNG
    private(set) var nextDue: Double
    private(set) var waitingSince: Double?
    private(set) var lastLook: VideoLook?
    private(set) var current: MomentPlan?
    private(set) var momentCount = 0
    /// -LiminalVideoLook: every moment uses this look.
    let pinnedLook: VideoLook?

    init(seed: UInt64, timing: Timing, pinnedLook: VideoLook? = nil) {
        self.timing = timing
        self.pinnedLook = pinnedLook
        var r = MusicRNG(seed: seed)
        nextDue = max(r.range(timing.first), timing.notBefore)
        rng = r
    }

    /// Called by the service once it has turned a `.begin` into a plan (clip and segment chosen).
    mutating func didBegin(_ plan: MomentPlan) {
        current = plan
        lastLook = plan.look
        momentCount += 1
        waitingSince = nil
    }

    /// The clip ran out, playback stopped or footage was turned off: fade out early.
    mutating func fadeOut(at t: Double, duration: Double) {
        current?.fadeOutEarly(at: t, duration: duration)
    }

    mutating func tick(elapsed t: Double, conditions c: Conditions, hasClip: Bool) -> Decision {
        if let plan = current {
            guard t >= plan.end else { return .none }
            current = nil
            nextDue = t + rng.range(timing.gap)
            return .end
        }
        guard t >= nextDue else { return .none }
        guard hasClip else {
            nextDue = t + 15   // nothing cached yet: look again soon
            waitingSince = nil
            return .none
        }
        let since = waitingSince ?? t
        waitingSince = since
        let waited = t - since
        let imageOK = !c.transitionRunning && (c.imageAge ?? .infinity) >= 8
        let musicOK = c.musicIntensity <= 0.8
        guard (imageOK || waited >= timing.maxImageWait) && (musicOK || waited >= timing.maxMusicWait) else { return .none }
        return .begin(makeBegin(intensity: c.effectIntensity))
    }

    private mutating func makeBegin(intensity: Float) -> Begin {
        let look = pinnedLook ?? Self.chooseLook(last: lastLook, intensity: intensity, rng: &rng)
        let fadeIn = rng.range(timing.fadeIn)
        let fadeOut = rng.range(timing.fadeOut)
        let total = max(rng.range(timing.length), fadeIn + fadeOut + 4)
        var hold = total - fadeIn - fadeOut
        if look == .emerge { hold = min(hold, 20) }
        return Begin(look: look, seed: rng.unit(), rate: rng.rangeF(timing.rate),
                     fadeIn: fadeIn, hold: hold, fadeOut: fadeOut)
    }

    /// Weighted look choice, never the same look twice in a row; Emerge only at intensity >= 0.4.
    static func chooseLook(last: VideoLook?, intensity: Float, rng: inout MusicRNG) -> VideoLook {
        let options = VideoLook.allCases.filter { $0 != last && ($0 != .emerge || intensity >= 0.4) }
        return options[rng.weighted(options.map(\.weight))]
    }

    /// Which cached clip to show: least recently used clips are likelier, never the previous clip
    /// when another exists.
    static func chooseClip(_ clips: [ArchiveClip], lastID: String?, rng: inout MusicRNG) -> ArchiveClip? {
        let pool = clips.count > 1 ? clips.filter { $0.id != lastID } : clips
        guard !pool.isEmpty else { return nil }
        let order = pool.sorted { $0.recency < $1.recency }
        // Weights 1/(rank+1): the oldest is likeliest, the newest still possible.
        let weights = order.indices.map { 1 / Float($0 + 1) }
        return order[rng.weighted(weights)]
    }
}
