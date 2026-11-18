//
//  FootageWeaver.swift
//  Liminal
//
//  Archive footage as a continuous stream of short pieces (docs/decisions/archive-video.md A27). While
//  footage is on, some film is always woven into the picture: pieces of 8-30 s from random points of
//  cached clips, each crossfading into the next over a few seconds (never a cut, never a gap to zero).
//  Per piece: clip, start point, recipe (blend look or interaction mode, docs/plans/footage-fx.md 5), warp, a level inside a subtle band (some pieces swell slowly to
//  more prominent) and whether the film's sound comes in. Pure and seeded: ticked twice a second by
//  ArchiveFootageService off the main actor; the render loops evaluate `FootagePiece.weight(at:)` only.
//  Times are seconds since footage started (`elapsed`).
//

import Foundation

/// "Change speed" setting: how long each piece stays before the next drifts in.
nonisolated enum FootageChangeSpeed: String, CaseIterable, Sendable {
    case slow, medium, fast
}

/// One piece of footage, fixed when it is prepared (its fade out is set once the next piece is placed).
nonisolated struct FootagePiece: Sendable, Equatable {
    let index: Int
    /// Decoder and shader layer (0 = texture 7 / videoMix, 1 = texture 8 / videoMixB). Alternates.
    let slot: Int
    let clipID: String
    /// Source seconds shown at `start` (the decoder pre-rolls a little before).
    let segmentStart: Double
    /// Playback rate of the footage (and its sound), 0.6...0.85: slow motion reads as dreamlike.
    let rate: Float
    /// How the film is woven in: a blend look or an interaction mode (docs/plans/footage-fx.md 5).
    let recipe: FootageRecipe
    let seed: Float
    /// How much of the picture's warp the footage rides (0 = none, 1 = all of it).
    let warp: Float
    /// Base level as a fraction of the look's ceiling (always >= `FootageWeaver.floor`).
    let level: Float
    /// Extra level at the middle of the piece (0 for most pieces: a slow swell for some).
    let swell: Float
    /// Elapsed seconds at which the fade in begins (later than `origin` if the piece was held).
    var start: Double
    /// Elapsed seconds at which the footage is at `segmentStart` (fixed: the decoder's clock and the
    /// sound are anchored here, so holding a piece never breaks their sync).
    let origin: Double
    let fadeIn: Double
    /// Planned seconds from `start` to the next piece's crossfade.
    var length: Double
    /// Set when the next piece is placed: it starts here and fades in over `fadeOut`.
    var fadeOutStart: Double?
    var fadeOut: Double?
    /// The film's sound plays with this piece.
    var sound: Bool

    var fill: LofiFill?

    /// The carrier look (Window for the carrier-less recipes: their size and drift).
    var look: VideoLook { recipe.carrier ?? .window }
    var plannedChange: Double { start + length }
    /// Elapsed seconds at which this piece has fully faded out (nil while it is the newest piece).
    var end: Double? { fadeOutStart.map { $0 + (fadeOut ?? 0) } }

    /// 0...1: smoothstep fade in, then hold, then (once the next piece is placed) the complementary
    /// smoothstep of the next piece's fade in, so outgoing + incoming is exactly 1 through a crossfade.
    func envelope(at t: Double) -> Float {
        guard t > start else { return 0 }
        let a = Self.smooth((t - start) / max(fadeIn, 0.01))
        guard let fo = fadeOutStart else { return Float(a) }
        let b = 1 - Self.smooth((t - fo) / max(fadeOut ?? 0, 0.01))
        return Float(min(a, b))
    }

    /// Level (fraction of the look ceiling) at `t`: the base plus a sin^2 swell over the planned length.
    func level(at t: Double) -> Float {
        guard swell > 0 else { return level }
        let u = min(max((t - start) / max(length, 1), 0), 1)
        let s = sin(Double.pi * u)
        return level + swell * Float(s * s)
    }

    /// envelope x level: what the composite scales by the look's ceiling.
    func weight(at t: Double) -> Float { envelope(at: t) * level(at: t) }

    /// envelope x the swell's factor (no level): what the drive amount scales by.
    func driveEnvelope(at t: Double) -> Float { envelope(at: t) * level(at: t) / max(level, 0.01) }

    static func smooth(_ x: Double) -> Double { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }
}

nonisolated struct FootageWeaver {

    struct Timing: Sendable, Equatable {
        var pieceLength: ClosedRange<Double>
        var crossfade: ClosedRange<Double>
        /// Fade in of the very first piece.
        var firstFade: Double = 5
        var rate: ClosedRange<Float> = 0.6...0.85
        var warp: ClosedRange<Float> = 0.35...0.85
        /// Chance that a piece brings its sound.
        var soundChance: Float
        /// Seconds the next piece's decoder (and its sound decode) get before its crossfade begins.
        var lead: Double = 3
        /// Longest a crossfade waits for an image transition to finish.
        var maxTransitionWait: Double = 6
        /// Longest a crossfade waits for the incoming decoder's first frame before that piece is dropped.
        var maxReadyWait: Double = 10

        static func speed(_ s: FootageChangeSpeed) -> Timing {
            switch s {
            case .slow: return Timing(pieceLength: 20...30, crossfade: 5...7, soundChance: 0.97)
            case .medium: return Timing(pieceLength: 12...20, crossfade: 3.5...5, soundChance: 0.97)
            case .fast: return Timing(pieceLength: 8...12, crossfade: 2.5...3.5, soundChance: 0.97)
            }
        }
        /// -LiminalVideoMix (stills): one piece for an hour, in 1 s.
        static let stills = Timing(pieceLength: 3600...3600, crossfade: 3...3, firstFade: 1, soundChance: 0)
    }

    /// The subtle band (fraction of the look's ceiling): every piece sits between `floor` and `bandTop`;
    /// some swell slowly by `swell` at their middle.
    static let floor: Float = 0.42
    static let bandTop: Float = 0.58
    static let swellChance: Float = 0.3
    static let swellRange: ClosedRange<Float> = 0.15...0.38
    static let swellMinLength: Double = 14
    /// Emerge takes the whole frame: its pieces are capped.
    static let emergeMaxLength: Double = FootageRecipe.cappedLength
    /// The first piece fades in this soon after a clip is available.
    static let firstLead: Double = 1
    /// Sound: starts this long after the piece's fade in begins; ends this long after its planned change.
    static let soundDelay: Double = 0.75
    static let soundTail: Double = 0.25
    /// A piece shorter than this (sound start to end) brings no sound.
    static let soundMinSpan: Double = 5

    struct Conditions: Sendable, Equatable {
        var transitionRunning = false
        /// Seconds since the current image's crossfade began (nil: no image yet / first image).
        var imageAge: Double? = nil
        /// Music energy 0...1.
        var musicIntensity: Float = 0
        /// Effect intensity setting 0...1.
        var effectIntensity: Float = 0.5
        /// A depth map is bound (visionOS): Backdrop may be picked.
        var hasDepth = false
    }

    /// What to prepare: the service supplies the clip and the segment and calls `didPrepare`.
    struct Request: Sendable, Equatable {
        let index: Int
        let slot: Int
        let start: Double
        let fadeIn: Double
        let length: Double
        let recipe: FootageRecipe
        let seed: Float
        let rate: Float
        let warp: Float
        let level: Float
        let swell: Float
        let sound: Bool

        var fill: LofiFill?
        var look: VideoLook { recipe.carrier ?? .window }

        func piece(clipID: String, segmentStart: Double, length: Double? = nil, sound: Bool? = nil) -> FootagePiece {
            FootagePiece(index: index, slot: slot, clipID: clipID, segmentStart: segmentStart, rate: rate, recipe: recipe,
                         seed: seed, warp: warp, level: level, swell: swell, start: start, origin: start, fadeIn: fadeIn,
                         length: length ?? self.length, fadeOutStart: nil, fadeOut: nil, sound: sound ?? self.sound, fill: fill)
        }
    }

    enum Decision: Sendable, Equatable {
        case none
        /// Prepare the next piece (start its decoder now; its crossfade begins at `request.start`).
        case prepare(Request)
        /// A piece has fully faded out: stop its decoder.
        case retire(slot: Int)
        /// The incoming piece never produced a frame: stop its decoder; the current piece holds.
        case drop(slot: Int)
    }

    /// Settable: the "Change speed" setting applies from the next piece on.
    var timing: Timing
    private var rng: MusicRNG
    /// At most two: the current piece and, from its preparation until the old one has faded, the next.
    private(set) var pieces: [FootagePiece] = []
    private(set) var pieceCount = 0
    private(set) var lastRecipe: FootageRecipe?
    /// The recipes of the last `recentCount` pieces, newest last (down-weighted in the choice).
    private(set) var recent: [FootageRecipe] = []
    private var holdSince: Double?
    private static let pinnedPiecesPerDiscovery = 4
    private var pinnedRun = 0
    private var pinnedRunBeforePrepare = 0
    /// A `.prepare` was issued and not yet answered.
    private var awaiting = false
    /// -LiminalVideoLook / -LiminalVideoMode: every piece uses this recipe.
    let pinnedRecipe: FootageRecipe?

    init(seed: UInt64, timing: Timing, pinnedLook: VideoLook? = nil, pinnedRecipe: FootageRecipe? = nil) {
        self.timing = timing
        self.pinnedRecipe = pinnedRecipe ?? pinnedLook.map(FootageRecipe.plain)
        rng = MusicRNG(seed: seed)
    }

    var current: FootagePiece? { pieces.last }

    /// Weight of all pieces at `t` (tests, logs): outgoing + incoming envelopes x levels.
    func presence(at t: Double) -> Float { pieces.reduce(0) { $0 + $1.weight(at: t) } }

    /// The service turned a `.prepare` into a piece (clip and segment chosen, decoder started).
    mutating func didPrepare(_ piece: FootagePiece) {
        awaiting = false
        if var last = pieces.last {
            last.fadeOutStart = piece.start
            last.fadeOut = piece.fadeIn
            // The planned length follows the real change (a crossfade that started late).
            last.length = max(last.length, piece.start - last.start)
            pieces[pieces.count - 1] = last
        }
        pieces.append(piece)
        pinnedRunBeforePrepare = pinnedRun
        pinnedRun = ArchiveSeedList.pinnedIDs.contains(piece.clipID) ? min(pinnedRun + 1, Self.pinnedPiecesPerDiscovery) : 0
        lastRecipe = piece.recipe
        recent.append(piece.recipe)
        if recent.count > Self.recentCount { recent.removeFirst(recent.count - Self.recentCount) }
        pieceCount += 1
        holdSince = nil
    }

    /// No clip could be prepared (cache empty, file gone): ask again on a later tick.
    mutating func prepareFailed() { awaiting = false }

    /// The current piece's clip ran out early: bring the next piece in as soon as possible.
    mutating func hurry(at t: Double) {
        guard pieces.count == 1, var p = pieces.last else { return }
        let change = max(t + timing.lead, p.start + p.fadeIn + 1)
        if change < p.plannedChange { p.length = change - p.start; pieces[0] = p }
    }

    mutating func tick(elapsed t: Double, conditions c: Conditions, hasClip: Bool,
                       matchingImageTransition: Bool = false, grid: LofiTakeGrid? = nil, ready: (Int) -> Bool) -> Decision {
        // A scheduled film edit is published in advance so the render loop can
        // crossfade on its exact clock even though the weaver ticks at 2 Hz.
        if let incoming = pieces.last, incoming.fill != nil, pieces.count == 2,
           !ready(incoming.slot), t >= incoming.start {
            pieces.removeLast()
            pinnedRun = pinnedRunBeforePrepare
            pieces[0].fadeOutStart = nil
            pieces[0].fadeOut = nil
            holdSince = nil
            return .drop(slot: incoming.slot)
        }
        // 1. A piece that has fully faded out is retired.
        if let i = pieces.firstIndex(where: { ($0.end ?? .infinity) <= t }) {
            let p = pieces.remove(at: i)
            return .retire(slot: p.slot)
        }
        guard !awaiting else { return .none }
        // 2. Nothing showing: the first piece, as soon as a clip is cached.
        guard let last = pieces.last else {
            guard hasClip else { return .none }
            awaiting = true
            return .prepare(makeRequest(slot: 0, start: t + Self.firstLead, fadeIn: timing.firstFade,
                                        conditions: c, grid: grid))
        }
        // 3. A piece close to its fade in: hold it (and the outgoing piece) while its decoder has no frame
        //    yet or an image transition runs; give up on a decoder that never delivers.
        if t < last.start {
            if last.fill != nil { return .none }
            guard t >= last.start - 0.75 else { return .none }
            let isReady = ready(last.slot)
            let since = holdSince ?? t
            let waited = t - since
            // Give a speculative pair only a brief grace period. The current film
            // stays visible and the next ordinary pick can take over if it fails.
            let readyWait = matchingImageTransition ? min(timing.maxReadyWait, 1.5) : timing.maxReadyWait
            if !isReady && waited >= readyWait {
                pieces.removeLast()
                pinnedRun = pinnedRunBeforePrepare
                if var cur = pieces.last {
                    cur.fadeOutStart = nil
                    cur.fadeOut = nil
                    cur.length = max(cur.length, t - cur.start + timing.lead + 1)
                    pieces[pieces.count - 1] = cur
                }
                holdSince = nil
                return .drop(slot: last.slot)
            }
            let transitionHold = pieces.count == 2 && c.transitionRunning && !matchingImageTransition
                && waited < timing.maxTransitionWait
            if !isReady || transitionHold {
                holdSince = since
                postponeNewest(by: 1)
            }
            return .none
        }
        if pieces.count == 2 { return .none }
        if let grid {
            let boundary = grid.nextBoundary(after: max(last.start + last.fadeIn, t + 0.5))
            let fade = boundary.fill.dissolveBeats * grid.beatDuration
            let start = boundary.time - fade * 0.5
            guard hasClip, t >= start - timing.lead else { return .none }
            awaiting = true
            return .prepare(makeRequest(slot: 1 - last.slot, start: start, fadeIn: fade, conditions: c,
                                        grid: grid, fill: boundary.fill))
        }
        // 4. One piece showing: prepare the next `lead` seconds before the planned change.
        guard hasClip, t >= last.plannedChange - timing.lead else { return .none }
        awaiting = true
        let fade = rng.range(timing.crossfade)
        // The next crossfade may not begin before this piece has fully faded in.
        let start = max(last.plannedChange, t + 1, last.start + last.fadeIn + 0.5)
        return .prepare(makeRequest(slot: 1 - last.slot, start: start, fadeIn: fade, conditions: c))
    }

    /// Moves the newest piece's fade in (and the outgoing piece's fade out) later.
    private mutating func postponeNewest(by dt: Double) {
        guard let n = pieces.indices.last else { return }
        pieces[n].start += dt
        if n > 0 {
            pieces[n - 1].fadeOutStart = pieces[n].start
            pieces[n - 1].length = max(pieces[n - 1].length, pieces[n].start - pieces[n - 1].start)
        }
    }

    private mutating func makeRequest(slot: Int, start: Double, fadeIn: Double, conditions c: Conditions,
                                      grid: LofiTakeGrid? = nil, fill: LofiFill? = nil) -> Request {
        let gridLength = grid.map { $0.nextBoundary(after: start + fadeIn).time - start }
        let recipe = pinnedRecipe ?? Self.chooseRecipe(last: lastRecipe, recent: recent, intensity: c.effectIntensity,
                                                       hasDepth: c.hasDepth, minimumLength: gridLength ?? 0, rng: &rng)
        let length = gridLength ?? max(fadeIn + 4, min(rng.range(timing.pieceLength), recipe.maxLength ?? .infinity))
        let level = rng.rangeF(Self.floor...Self.bandTop)
        // Swells are slow: only on pieces of 14 s or more (and never on the capped recipes, which take the
        // frame or its tones).
        let swells = rng.chance(Self.swellChance)
        let swell = swells && recipe.maxLength == nil && length >= Self.swellMinLength ? rng.rangeF(Self.swellRange) : 0
        let soundSpan = length + Self.soundTail - Self.soundDelay
        let sound = soundSpan >= Self.soundMinSpan
            && rng.chance(timing.soundChance)
        let index = pieceCount
        return Request(index: index, slot: slot, start: start, fadeIn: fadeIn, length: length, recipe: recipe,
                       seed: rng.unit(), rate: rng.rangeF(timing.rate), warp: rng.rangeF(timing.warp),
                       level: level, swell: swell, sound: sound, fill: fill)
    }

    /// Pieces remembered for the recent-use down-weighting.
    static let recentCount = 4
    /// After an interaction mode, today's plain looks keep at least this share of the choice (so about
    /// 30 % of all pieces are plain: a plain piece is never followed by another).
    static let plainShareAfterMode: Float = 0.45

    /// Recipes the weaver may pick at this intensity and depth (plan footage-fx.md 5, step 1).
    static func eligible(intensity: Float, hasDepth: Bool) -> [FootageRecipe] {
        FootageRecipe.allCases.filter { intensity >= $0.minIntensity && (!$0.needsDepth || hasDepth) }
    }

    /// Two recipes may crossfade into each other when the frame can use a slim shader variant: a key-group and
    /// a drive-group recipe meet only through a plain look (decision F11).
    static func compatible(_ a: FootageRecipe?, _ b: FootageRecipe) -> Bool {
        guard let a else { return true }
        // A key-group recipe never meets a drive or glass one (variants 7, 11, 15: the costliest, decision F11).
        // Drives and glass may crossfade (variant 13, round 1's cost for those seconds, F25): forbidding it too
        // left a glass piece only plain looks to follow, and the plain share rose over the weaver's band.
        let u = a.shaderGroup | b.shaderGroup
        return u & 2 == 0 || u & 12 == 0
    }

    /// Weighted recipe choice (plan footage-fx.md 5): never the previous recipe or its family, never a
    /// key-group recipe next to a drive-group one, recently used
    /// recipes at half weight, the water family halved at low intensity, and the plain looks at least
    /// `plainShareAfterMode` of the weight after a mode.
    static func chooseRecipe(last: FootageRecipe?, recent: [FootageRecipe], intensity: Float, hasDepth: Bool,
                             minimumLength: Double = 0, rng: inout MusicRNG) -> FootageRecipe {
        var options = eligible(intensity: intensity, hasDepth: hasDepth)
            .filter { ($0.maxLength ?? .infinity) >= minimumLength && $0.family != last?.family && compatible(last, $0) }
        if options.isEmpty { options = [last == .window ? .phantom : .window] }
        var weights = options.map { r -> Float in
            var w = r.weight
            if recent.contains(r) { w *= 0.5 }
            if r.family == .water && intensity < 0.25 { w *= 0.5 }
            return w
        }
        let plain = zip(options, weights).filter { $0.0.family == .plain }.reduce(Float(0)) { $0 + $1.1 }
        let total = weights.reduce(0, +)
        if plain > 0, plain < total, plain / total < plainShareAfterMode {
            let k = plainShareAfterMode / (1 - plainShareAfterMode) * (total - plain) / plain
            for i in options.indices where options[i].family == .plain { weights[i] *= k }
        }
        return options[rng.weighted(weights)]
    }

    /// Four curated excerpts for every discovery when both are available.
    func chooseClipForPlayback(_ clips: [ArchiveClip], rng: inout MusicRNG) -> ArchiveClip? {
        Self.chooseClip(eligibleClips(clips), avoiding: Set(pieces.map(\.clipID)), rng: &rng)
    }

    func eligibleClips(_ clips: [ArchiveClip]) -> [ArchiveClip] {
        let curated = clips.filter { ArchiveSeedList.pinnedIDs.contains($0.id) }
        let discoveries = clips.filter(ArchiveCachePolicy.isFreshDiscovery)
        if curated.isEmpty { return discoveries.isEmpty ? clips : discoveries }
        return pinnedRun >= Self.pinnedPiecesPerDiscovery && !discoveries.isEmpty ? discoveries : curated
    }

    /// Which cached clip a piece comes from: least recently used clips are likelier, never one of the
    /// clips on screen when another exists.
    static func chooseClip(_ clips: [ArchiveClip], avoiding: Set<String>, rng: inout MusicRNG) -> ArchiveClip? {
        let rest = clips.filter { !avoiding.contains($0.id) }
        let pool = rest.isEmpty ? clips : rest
        guard !pool.isEmpty else { return nil }
        let order = pool.sorted { $0.recency < $1.recency }
        // Weights 1/(rank+1): the oldest is likeliest, the newest still possible.
        let weights = order.indices.map { 1 / Float($0 + 1) }
        return order[rng.weighted(weights)]
    }
}
