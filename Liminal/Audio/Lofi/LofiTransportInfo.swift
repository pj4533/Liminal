import Foundation

/// What the dialogue coordinator needs to know about the Lo-Fi transport (plan 3.6, 6.4).
/// Published by `LofiPlayback` through the `MusicStateBus` side channel, never inside the
/// fixed-size `MusicState`. Main-actor writes, read by the footage worker, never by a render thread.
nonisolated struct LofiTransportInfo: Sendable {
    /// Incremented on start, stop and whenever a queued take changes tempo.
    let revision: UInt32
    let takeIndex: Int
    /// Global phrase index of the take's first beat (`drumBreakIndex * 4`).
    let phraseAtTakeStart: Int
    /// Transport seconds of the take's beat 0: the same origin as `MusicState.lofiTakeGrid`.
    let origin: Double
    let beatDuration: Double
    /// Beat length after beat 64, when the next take is already queued.
    let nextBeatDuration: Double?
    /// `LofiPlayback.Request.seed` of the session and the take's options.
    let seed: UInt64
    let options: LofiOptions
    /// The take's sparse drum timing (landmarks in take frames).
    let timing: LofiTimingField?

    init(revision: UInt32, takeIndex: Int, phraseAtTakeStart: Int, origin: Double, beatDuration: Double,
         nextBeatDuration: Double?, seed: UInt64, options: LofiOptions, timing: LofiTimingField?) {
        self.revision = revision
        self.takeIndex = takeIndex
        self.phraseAtTakeStart = phraseAtTakeStart
        self.origin = origin
        self.beatDuration = beatDuration
        self.nextBeatDuration = nextBeatDuration
        self.seed = seed
        self.options = options
        self.timing = timing
    }

    /// The take grid the footage weaver already reads, on the same clock.
    var grid: LofiTakeGrid {
        LofiTakeGrid(origin: origin, beatDuration: beatDuration, takeIndex: takeIndex, nextBeatDuration: nextBeatDuration)
    }

    func with(revision: UInt32) -> Self {
        .init(revision: revision, takeIndex: takeIndex, phraseAtTakeStart: phraseAtTakeStart, origin: origin,
              beatDuration: beatDuration, nextBeatDuration: nextBeatDuration, seed: seed, options: options, timing: timing)
    }
}
