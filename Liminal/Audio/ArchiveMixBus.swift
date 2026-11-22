import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import AVFoundation
import Foundation

/// The film bed's buses, shared effects and limiter.
///
///     strip -> dryBus ----------------------------------------------------------------------+
///     strip -> delayBus -> LPF -> two prepared tempo lanes (echo, answer, room) -> delayReturn --+--> master
///                                            reflections and repeats -> reverbBus
///     strip -> reverbBus -> ZitaReverb (wet) -> LPF 2.9 kHz -> reverbReturn -> phaser ----------------+
///              reverbBus -> HPF 300 -> LPF 1.8k -> Costello (halo) -> shimmerReturn ------------------+
///     master -> HPF 28 Hz -> LPF 5.4 kHz -> masterTrim -> PeakLimiter -> -1.5 dB -> output
nonisolated final class ArchiveMixBus {
    let dryBus = Mixer()
    let reverbBus = Mixer()
    let delayBus = Mixer()
    let delayPreFilter: LowPassButterworthFilter
    let delayReturn: Fader
    let delayToReverb: Fader
    let reflectionToReverb: Fader
    let spacePhaser: Phaser
    let spaceMovement: Fader
    let shimmerHP: HighPassButterworthFilter
    let shimmerLP: LowPassButterworthFilter
    let shimmerVerb: CostelloReverb
    let shimmerReturn: Fader
    let reverb: ZitaReverb
    let reverbLP: LowPassButterworthFilter
    let reverbReturn: Fader
    let master: Mixer
    let highpass: HighPassButterworthFilter
    let lowpass: LowPassButterworthFilter
    let masterTrim: Fader
    let limiter: PeakLimiter
    let finalTrim: Fader

    var output: Node { finalTrim }

    /// The room of this seed: reverb amount and echo amount, 0...1, fixed for the session.
    let space: Float
    let delayAmount: Float

    private var echoBeat: Float?
    private let beatEchoes: [BeatEcho]
    private var activeBeatEcho: Int?
    private var activeEchoPattern = EchoPattern.straight
    private var echoPhaseStart = 0.0
    private var lastBeatEcho = 1
    private var delaySettings = (feedback: Float(0.4), gain: dbToGain(-10), cutoff: Float(2400), input: Float(2000))
    /// Halo return (linear).
    private(set) var shimmerLevel: Float = 0
    private var shimmerOut: Float = 0
    private let spaceDrift = ParameterDrift.Channel(period: 47, phase: 0.6)
    private let widthDrift = ParameterDrift.Channel(period: 71, phase: 2.1)

    init(strip: ArchiveStrip, seed: UInt64) {
        var r = MusicRNG(seed: seed).fork(6)
        _ = r.range(135...185)
        _ = r.range(0...(2 * .pi))
        let spaceDrift = ParameterDrift.Channel(period: r.range(170...230), phase: r.range(0...(2 * .pi)))
        let echoDrift = ParameterDrift.Channel(period: r.range(110...160), phase: r.range(0...(2 * .pi)))
        space = ParameterDrift.apply(center: 0.62, drift: spaceDrift.value(at: 0), range: 0.13)
        delayAmount = ParameterDrift.apply(center: 0.52, drift: echoDrift.value(at: 0), range: 0.13)

        dryBus.addInput(strip.outputs.dry)
        reverbBus.addInput(strip.outputs.reverbSend)
        delayBus.addInput(strip.outputs.delaySend)
        // The echo input is low-passed before the lanes so every repeat is dark.
        delayPreFilter = LowPassButterworthFilter(delayBus, cutoffFrequency: 2000)
        beatEchoes = [BeatEcho(delayPreFilter), BeatEcho(delayPreFilter)]
        delayReturn = Fader(Mixer(beatEchoes.map(\.echoOutput)), gain: dbToGain(-10))
        delayToReverb = Fader(delayReturn, gain: 0.5)
        reverbBus.addInput(delayToReverb)
        reflectionToReverb = Fader(Mixer(beatEchoes.map(\.reflectionOutput)), gain: 0.22)
        reverbBus.addInput(reflectionToReverb)
        reverb = ZitaReverb(reverbBus, predelay: 60, crossoverFrequency: 200, lowReleaseTime: 4.8,
                            midReleaseTime: 8, dampingFrequency: 2400, dryWetMix: 1)
        // Filter the late tail so short accents leave a soft wash behind.
        reverbLP = LowPassButterworthFilter(reverb, cutoffFrequency: 2900)
        reverbReturn = Fader(reverbLP, gain: dbToGain(-5))
        spacePhaser = Phaser(reverbReturn, notchMinimumFrequency: 190, notchMaximumFrequency: 940,
                             notchWidth: 440, vibratoMode: 0, depth: 0.45, feedback: 0.1,
                             lfoBPM: 28, dryWetMix: 1)
        spaceMovement = Fader(spacePhaser, gain: 0.12)
        // Halo: the reverb send, band-limited to 300 Hz-1.8 kHz, into its own long Costello tail.
        shimmerHP = HighPassButterworthFilter(reverbBus, cutoffFrequency: 300)
        shimmerLP = LowPassButterworthFilter(shimmerHP, cutoffFrequency: 1800)
        shimmerVerb = CostelloReverb(shimmerLP, balance: 1, feedback: 0.93, cutoffFrequency: 2500)
        shimmerReturn = Fader(shimmerVerb, gain: 0)
        master = Mixer(dryBus, reverbReturn, delayReturn, shimmerReturn, spaceMovement)
        highpass = HighPassButterworthFilter(master, cutoffFrequency: 28)
        lowpass = LowPassButterworthFilter(highpass, cutoffFrequency: Self.lowpassHz)
        masterTrim = Fader(lowpass, gain: 0)
        limiter = PeakLimiter(masterTrim, attackTime: 0.01, decayTime: 0.06, preGain: 0)
        finalTrim = Fader(limiter, gain: dbToGain(-1.5))
    }

    /// Master low-pass of the film bed.
    static let lowpassHz: Float = 5400

    /// Offline diagnosis only (stem renders): returns named here ("reverb", "delay", "shimmer") stay at zero.
    var mutedReturns: Set<String> = []

    /// Sets the seed's room when the conductor begins: reverb return -9...-1 dB, RT60 6 s up to Zita's
    /// 8 s ceiling, warm damping, echo feedback up to 0.5, and a little halo.
    func applyRoom(over: Double) {
        let brightness: Float = 0.5
        let ret = dbToGain(-9 + 8 * space)
        let mid = min(8, 6 + 6 * space)
        // The low band decays faster than the mids so the stereo tail does not smear the sub.
        ParamRamp.setGain(reverbReturn, mutedReturns.contains("reverb") ? 0 : ret, over: over)
        ParamRamp.set(reverb.$midReleaseTime, mid, over: over)
        ParamRamp.set(reverb.$lowReleaseTime, max(1, 0.48 * mid), over: over)
        ParamRamp.set(reverb.$dampingFrequency, expMap(brightness, 1450, 2500), over: over)
        let fb = 0.3 + 0.2 * (0.4 * space + 0.6 * delayAmount)
        delaySettings = (fb, dbToGain(-10 + 5 * delayAmount), expMap(brightness, 1450, 2300), expMap(brightness, 1200, 1900))
        applyDelaySettings(over: over)
        // Halo: -26 dB at space 0 to -12 dB at space 1, capped at -14 dB.
        shimmerLevel = min(dbToGain(-26 + 14 * space), dbToGain(-14))
    }

    private func applyDelaySettings(over: Double) {
        let settings = delaySettings
        let gain = mutedReturns.contains("delay") ? 0 : settings.gain
        // Lead with the quarter-note repeat. Keep its later repeats and the offbeat wash softer.
        ParamRamp.set(delayPreFilter.$cutoffFrequency, settings.input * 1.36, over: over)
        for echo in beatEchoes {
            ParamRamp.set(echo.delay.$feedback, min(0.55, settings.feedback * 0.78), over: over)
            ParamRamp.set(echo.filter.$cutoffFrequency, settings.cutoff * 1.11, over: over)
        }
        ParamRamp.setGain(delayReturn, gain * 1.52, over: over)
        ParamRamp.setGain(delayToReverb, 0.38, over: over)
        ParamRamp.setGain(reflectionToReverb, gain * 0.54, over: over)
    }

    struct EchoPattern: Equatable, Sendable {
        let main: Double
        let answer: Double
        let room: Double
        let spread: Float
        let swell: Float
        var endingFill: LofiFill?

        static let straight = Self(main: 1, answer: 0, room: 0.5, spread: 0, swell: 0)
        private static let palette: [Self] = [
            .init(main: 0.75, answer: 1.75, room: 0.375, spread: 0.64, swell: 0.80),
            .init(main: 1.5, answer: 0.625, room: 0.75, spread: -0.73, swell: 0.67),
            .init(main: 0.5, answer: 2.25, room: 0.875, spread: 0.55, swell: 0.94),
            .init(main: 1.25, answer: 0.375, room: 0.625, spread: -0.58, swell: 0.56),
            .init(main: 2, answer: 0.875, room: 0.5, spread: 0.72, swell: 0.87)
        ]

        static func choose(seed: UInt64, phrase: Int) -> Self {
            var pattern = MusicRNG(seed: seed).fork(3156).shuffledCycle(palette, index: phrase)
            pattern.endingFill = LofiFill.ending(phrase: phrase)
            return pattern
        }
    }

    /// A new tempo or pattern lands on the unused lane. The previous lane's feed closes and its return
    /// dissolves instead of moving the read point in the middle of a spoken echo. A non-finite or
    /// out-of-range beat keeps the current lane.
    func syncEcho(beatDuration: Double, pattern: EchoPattern = .straight, now: Double = 0) {
        guard beatDuration.isFinite, (0.55...1.25).contains(beatDuration) else { return }
        let seconds = Float(beatDuration)
        guard seconds != echoBeat || pattern != activeEchoPattern else { return }
        if let activeBeatEcho, let echoBeat {
            let retirementBeats = activeEchoPattern.answer > 0 ? 3.25 : 1.8
            beatEchoes[activeBeatEcho].set(active: false, outputRamp: min(3.5, Double(echoBeat) * retirementBeats))
        }
        echoBeat = seconds
        let next = 1 - lastBeatEcho
        let echo = beatEchoes[next]
        echo.prepare(beatDuration: seconds, pattern: pattern)
        echo.set(active: true, outputRamp: 0.24, answer: pattern.answer > 0)
        activeEchoPattern = pattern
        echoPhaseStart = now
        activeBeatEcho = next
        lastBeatEcho = next
        applyDelaySettings(over: 0.09)
    }

    /// Each lane keeps an independent feedback state and runs with no input between tempo assignments.
    private struct BeatEcho {
        let feed: Fader
        let delay: VariableDelay
        let filter: LowPassButterworthFilter
        let echoOutput: Fader
        let mainPan: Panner
        let answer: VariableDelay
        let answerGain: Fader
        let answerPan: Panner
        let reflection: VariableDelay
        let reflectionOutput: Fader

        init(_ input: Node) {
            feed = Fader(input, gain: 0)
            delay = VariableDelay(feed, time: 0.85, feedback: 0.32, maximumTime: 3.5, dryWetMix: 1)
            filter = LowPassButterworthFilter(delay, cutoffFrequency: 2640)
            mainPan = Panner(filter)
            answer = VariableDelay(feed, time: 1.2, feedback: 0.21, maximumTime: 3.5, dryWetMix: 1)
            answerGain = Fader(LowPassButterworthFilter(answer, cutoffFrequency: 1_680), gain: 0)
            answerPan = Panner(answerGain)
            echoOutput = Fader(Mixer(mainPan, answerPan), gain: 0)
            reflection = VariableDelay(feed, time: 0.425, feedback: 0.19, maximumTime: 2, dryWetMix: 1)
            reflectionOutput = Fader(reflection, gain: 0)
        }

        func prepare(beatDuration: Float, pattern: EchoPattern) {
            // The line's return is silent while the two read positions are assigned.
            // Use the AU parameter tree directly. AudioKit's property wrapper also writes
            // these AUv3 addresses through the legacy API, which reports an invalid address.
            delay.$time.parameter?.value = beatDuration * Float(pattern.main)
            answer.$time.parameter?.value = beatDuration * Float(max(0.25, pattern.answer))
            reflection.$time.parameter?.value = beatDuration * Float(pattern.room)
            motion(pattern: pattern, beat: 0)
        }

        func set(active: Bool, outputRamp: Double, answer: Bool = false) {
            let gain: Float = active ? 1 : 0
            ParamRamp.setGain(feed, gain, over: 0.035)
            ParamRamp.setGain(echoOutput, gain, over: outputRamp)
            ParamRamp.setGain(reflectionOutput, gain, over: outputRamp)
            if active && !answer { ParamRamp.setGain(answerGain, 0, over: 0.035) }
        }

        func motion(pattern: EchoPattern, beat: Double) {
            guard pattern.answer > 0 else {
                ParamRamp.set(mainPan.$pan, 0, over: 0.16)
                return
            }
            let u = Float(beat)
            let sweep = 0.7 + 0.3 * sinf(u * .pi / 4)
            let bloom = powf(0.5 - 0.5 * cosf(u * .pi / 3), 2)
            let crest = pattern.endingFill?.accent(beatsFromBoundary: beat - LofiClock.beats) ?? 0
            ParamRamp.set(mainPan.$pan, pattern.spread * min(1.18, sweep + 0.35 * crest), over: 0.17)
            ParamRamp.set(answerPan.$pan, -pattern.spread * (1 - 0.28 * bloom), over: 0.17)
            ParamRamp.setGain(answerGain, 0.23 + pattern.swell * 0.64 * max(bloom, crest) + 0.18 * crest, over: 0.18)
            ParamRamp.setGain(reflectionOutput, 0.55 + 0.45 * max(bloom, crest), over: 0.18)
        }
    }

    /// 10 Hz: the halo return, the room's phaser drift and the active echo lane's motion.
    func modulate(t: Double) {
        let g = mutedReturns.contains("shimmer") ? 0 : shimmerLevel
        if abs(g - shimmerOut) > 1e-5 { ParamRamp.setGain(shimmerReturn, g, over: 0.12); shimmerOut = g }
        let color = spaceDrift.value(at: t), width = widthDrift.value(at: t)
        ParamRamp.set(spacePhaser.$notchMaximumFrequency, 960 + 320 * color, over: 0.15)
        ParamRamp.set(spacePhaser.$depth, 0.48 + 0.22 * width, over: 0.15)
        ParamRamp.setGain(spaceMovement, 0.14 + 0.10 * color, over: 0.15)
        if let seconds = echoBeat, let lane = activeBeatEcho {
            beatEchoes[lane].motion(pattern: activeEchoPattern, beat: max(0, t - echoPhaseStart) / Double(seconds))
        }
    }

    /// Start/stop fades.
    func setMaster(_ gain: Float, over: Double) {
        ParamRamp.setGain(masterTrim, gain, over: over)
    }
}
