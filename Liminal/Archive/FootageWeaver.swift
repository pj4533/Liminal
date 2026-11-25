//
//  FootageWeaver.swift
//  Liminal
//
//  Archive footage as a continuous stream of short pieces (docs/decisions/archive-video.md A27). While
//  footage is on, some film is always woven into the picture: pieces from random points of cached clips,
//  each crossfading into the next (never a cut, never a gap to zero). Every piece change is planned on the
//  drum grid: it completes on a fill boundary's downbeat, and the crossfade spans that fill's dissolve.
//  Per piece: clip, start point, recipe (blend look or interaction mode, docs/plans/footage-fx.md 5), warp,
//  a level inside a subtle band (some pieces swell slowly to more prominent) and whether the film's sound
//  comes in. Pure and seeded: ticked twice a second by ArchiveFootageService off the main actor; the
//  render loops evaluate `FootagePiece.weight(at:)` only. Times are seconds since footage started (`elapsed`).
//

import Foundation

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
        /// Fade in of the very first piece.
        var firstFade: Double = 5
        var rate: ClosedRange<Float> = 0.6...0.85
        var warp: ClosedRange<Float> = 0.35...0.85
        /// Pieces long enough for a cue bring the film's sound.
        var sound = true
        /// Seconds the next piece's decoder (and its sound decode) get before its crossfade begins.
        var lead: Double = 3
        /// Longest the first piece waits for its decoder's first frame before it is dropped.
        var maxReadyWait: Double = 10
        /// Once the first piece exists no further piece is prepared.
        var holdsFirstPiece = false

        static let standard = Timing()
        /// -LiminalVideoMix (stills): one silent piece that fades in over 1 s and stays.
        static let stills = Timing(firstFade: 1, sound: false, holdsFirstPiece: true)
    }

    /// The subtle band (fraction of the look's ceiling): every piece sits between `floor` and `bandTop`;
    /// some swell slowly by `swell` at their middle.
    static let floor: Float = 0.42
    static let bandTop: Float = 0.58
    static let swellChance: Float = 0.3
    static let swellRange: ClosedRange<Float> = 0.15...0.38
    static let swellMinLength: Double = 14
    /// Seconds past a fade in's end before the next fill boundary may end the piece.
    static let boundaryMargin: Double = 0.01
    /// The first piece fades in this soon after a clip is available.
    static let firstLead: Double = 1
    /// Sound: starts this long after the piece's fade in begins; ends this long after its planned change.
    static let soundDelay: Double = 0.75
    static let soundTail: Double = 0.25
    /// A piece shorter than this (sound start to end) brings no sound.
    static let soundMinSpan: Double = 5

    struct Conditions: Sendable, Equatable {
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

    let timing: Timing
    private var rng: MusicRNG
    /// At most two: the current piece and, from its preparation until the old one has faded, the next.
    private(set) var pieces: [FootagePiece] = []
    private(set) var pieceCount = 0
    private(set) var lastRecipe: FootageRecipe?
    /// The recipes of the last `recentCount` pieces, newest last (down-weighted in the choice).
    private(set) var recent: [FootageRecipe] = []
    private var holdSince: Double?
    private static let pinnedPiecesPerDiscovery = 2
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

    mutating func tick(elapsed t: Double, conditions c: Conditions, hasClip: Bool,
                       grid: LofiTakeGrid, ready: (Int) -> Bool) -> Decision {
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
        // 3. The first piece close to its fade in: hold it while its decoder has no frame yet; give up on a
        //    decoder that never delivers (a later tick prepares another first piece). A later piece is a
        //    fill edit on its exact clock: it is never held, and the check above drops it.
        if t < last.start {
            guard last.fill == nil, t >= last.start - 0.75, !ready(last.slot) else { return .none }
            let since = holdSince ?? t
            if t - since >= timing.maxReadyWait {
                pieces.removeLast()
                pinnedRun = pinnedRunBeforePrepare
                holdSince = nil
                return .drop(slot: last.slot)
            }
            holdSince = since
            pieces[pieces.count - 1].start += 1
            return .none
        }
        if pieces.count == 2 || timing.holdsFirstPiece { return .none }
        // 4. One piece showing: the next one crossfades in over the coming fill boundary's dissolve and is
        //    complete on its downbeat, with the picture's drop cut (drop-transitions.md 3.5). It is prepared
        //    `lead` seconds before its crossfade begins, never before this piece has fully faded in.
        let boundary = grid.nextBoundary(after: max(last.start + last.fadeIn, t + 0.5))
        let fade = boundary.fill.dissolveBeats * grid.beatDuration
        let start = boundary.time - fade
        guard hasClip, t >= start - timing.lead else { return .none }
        awaiting = true
        return .prepare(makeRequest(slot: 1 - last.slot, start: start, fadeIn: fade, conditions: c,
                                    grid: grid, fill: boundary.fill))
    }

    private mutating func makeRequest(slot: Int, start: Double, fadeIn: Double, conditions c: Conditions,
                                      grid: LofiTakeGrid, fill: LofiFill? = nil) -> Request {
        // A piece lasts until the fill boundary after its fade in. A fill edit's fade in ends on its own
        // boundary, and `start + fadeIn` may round to just below it: the margin keeps that boundary out.
        let length = grid.nextBoundary(after: start + fadeIn + Self.boundaryMargin).time - start
        let recipe = pinnedRecipe ?? Self.chooseRecipe(last: lastRecipe, recent: recent, intensity: c.effectIntensity,
                                                       hasDepth: c.hasDepth, minimumLength: length, rng: &rng)
        let level = rng.rangeF(Self.floor...Self.bandTop)
        // Swells are slow: only on pieces of 14 s or more (and never on the capped recipes, which take the
        // frame or its tones).
        let swells = rng.chance(Self.swellChance)
        let swell = swells && recipe.maxLength == nil && length >= Self.swellMinLength ? rng.rangeF(Self.swellRange) : 0
        let soundSpan = length + Self.soundTail - Self.soundDelay
        let sound = timing.sound && soundSpan >= Self.soundMinSpan
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

    /// Give discoveries a regular turn without letting the pin quota repeat a recent film.
    func chooseClipForPlayback(_ clips: [ArchiveClip], boost: [String: Float] = [:], rng: inout MusicRNG) -> ArchiveClip? {
        Self.chooseClip(eligibleClips(clips), avoiding: Set(pieces.map(\.clipID)), boost: boost, rng: &rng)
    }

    func eligibleClips(_ clips: [ArchiveClip]) -> [ArchiveClip] {
        let onScreen = Set(pieces.map(\.clipID))
        let offScreen = clips.filter { !onScreen.contains($0.id) }
        let pool = offScreen.isEmpty ? clips : offScreen
        let recent = pool.filter { $0.lastUsed != nil }.sorted { $0.recency > $1.recency }
        // Scale the cooldown to the population so small and offline pools still work.
        let rest = Set(recent.prefix(min(3, max(0, (pool.count - 1) / 2))).map(\.id))
        let ready = pool.filter { !rest.contains($0.id) }
        let curated = ready.filter { ArchiveSeedList.pinnedIDs.contains($0.id) }
        let discoveries = ready.filter(ArchiveCachePolicy.isFreshDiscovery)
        if curated.isEmpty { return discoveries.isEmpty ? ready : discoveries }
        return pinnedRun >= Self.pinnedPiecesPerDiscovery && !discoveries.isEmpty ? discoveries : curated
    }

    /// Which cached clip a piece comes from: least recently used clips are likelier, never one of the
    /// clips on screen when another exists.
    static func chooseClip(_ clips: [ArchiveClip], avoiding: Set<String>, boost: [String: Float] = [:], rng: inout MusicRNG) -> ArchiveClip? {
        let rest = clips.filter { !avoiding.contains($0.id) }
        let pool = rest.isEmpty ? clips : rest
        guard !pool.isEmpty else { return nil }
        let order = pool.sorted { $0.recency < $1.recency }
        // Weights 1/(rank+1): the oldest is likeliest, the newest still possible.
        let weights = order.indices.map { (1 / Float($0 + 1)) * max(1, min(3, boost[order[$0].id] ?? 1)) }
        return order[rng.weighted(weights)]
    }
}
