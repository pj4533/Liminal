import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import AVFoundation
import Foundation

/// Buses, shared effects and master chain (section 3, decisions D10-D14, D57, D58; calm retune D92).
///
///     strips -> dryBus --------------------------------------------------------------------------+
///     strips -> delayBus -> LPF -> Ambient wow / two prepared Lo-Fi tempo lanes -> delayReturn --+--> master
///                                                         reflections and repeats -> reverbBus
///     strips -> reverbBus -> ZitaReverb (wet) -> LPF 2.9 kHz -> reverbReturn -------------------------+
///               reverbBus -> HPF 300 -> LPF 1.8k -> Costello (halo) -> shimmerReturn ----------------+
///     master -> HPF 28 Hz -> LPF 5.4 kHz -> masterTrim -> PeakLimiter -> -1.5 dB -> output
nonisolated final class MixBus {
    let dryBus = Mixer()
    let reverbBus = Mixer()
    let delayBus = Mixer()
    let delayPreFilter: LowPassButterworthFilter
    let delay: VariableDelay
    let delayFilter: LowPassButterworthFilter
    let delayReturn: Fader
    let delayToReverb: Fader
    let reflection: VariableDelay
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
    let performanceSpace: ControllerChannelStrip
    let master: Mixer
    let highpass: HighPassButterworthFilter
    let lowpass: LowPassButterworthFilter
    let masterTrim: Fader
    let limiter: PeakLimiter
    let finalTrim: Fader

    var output: Node { finalTrim }

    /// Base return gains before the space macro.
    private(set) var space: Float = 0.5
    private(set) var delayAmount: Float = 0.5

    private let baseDelayTime: Float
    private var syncedDelayTime: Float?
    private let ambientDelayFeed: Fader
    private let ambientDelayOutput: Fader
    private let ambientReflectionOutput: Fader
    private let beatEchoes: [BeatEcho]
    private var activeBeatEcho: Int?
    private var activeEchoPattern = ArchiveEchoPattern.straight
    private var echoPhaseStart = 0.0
    private var lastBeatEcho = 1
    private var delaySettings = (feedback: Float(0.4), gain: dbToGain(-10), cutoff: Float(2400), input: Float(2000))
    /// Shimmer return (linear) before the bloom envelope; published as `MusicState.shimmerLevel`.
    private(set) var shimmerLevel: Float = 0
    private var shimmerBloom = SoftEnv(0)
    private var wowPhase = 0.0, flutterPhase = 0.0
    private let spaceDrift = ParameterDrift.Channel(period: 47, phase: 0.6)
    private let widthDrift = ParameterDrift.Channel(period: 71, phase: 2.1)

    init(layers: [LayerStrip], delayTime: Float) {
        baseDelayTime = delayTime
        for s in layers {
            dryBus.addInput(s.outputs.dry)
            reverbBus.addInput(s.outputs.reverbSend)
            delayBus.addInput(s.outputs.delaySend)
        }
        // Calm (decision D92): the delay input is low-passed before the loop so every repeat is dark (the
        // filter after the delay only darkened the output, the loop itself kept the attack's top end).
        delayPreFilter = LowPassButterworthFilter(delayBus, cutoffFrequency: 2000)
        ambientDelayFeed = Fader(delayPreFilter, gain: 1)
        delay = VariableDelay(ambientDelayFeed, time: delayTime, feedback: 0.4, maximumTime: 10, dryWetMix: 1)
        delayFilter = LowPassButterworthFilter(delay, cutoffFrequency: 2400)
        ambientDelayOutput = Fader(delayFilter, gain: 1)
        beatEchoes = [BeatEcho(delayPreFilter), BeatEcho(delayPreFilter)]
        // Tape character is wow on the delay time only; TanhDistortion was measured at 5 % of the render
        // budget for no audible effect at the -20 dBFS levels the delay runs at (decision D58).
        delayReturn = Fader(Mixer([ambientDelayOutput] + beatEchoes.map(\.echoOutput)), gain: dbToGain(-10))
        delayToReverb = Fader(delayReturn, gain: 0.5)
        reverbBus.addInput(delayToReverb)
        reflection = VariableDelay(ambientDelayFeed, time: delayTime * 0.61, feedback: 0.19,
                                   maximumTime: 10, dryWetMix: 1)
        ambientReflectionOutput = Fader(reflection, gain: 1)
        reflectionToReverb = Fader(Mixer([ambientReflectionOutput] + beatEchoes.map(\.reflectionOutput)), gain: 0.22)
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
        // Halo (D92, was the octave-up shimmer of D12/D57): the reverb send, band-limited to 300 Hz-1.8 kHz,
        // into its own long Costello tail. No pitch shifter: an octave up of every note was the opposite of calm.
        shimmerHP = HighPassButterworthFilter(reverbBus, cutoffFrequency: 300)
        shimmerLP = LowPassButterworthFilter(shimmerHP, cutoffFrequency: 1800)
        shimmerVerb = CostelloReverb(shimmerLP, balance: 1, feedback: 0.93, cutoffFrequency: 2500)
        shimmerReturn = Fader(shimmerVerb, gain: 0)
        performanceSpace = ControllerChannelStrip(Mixer(reverbReturn, delayReturn, shimmerReturn, spaceMovement))
        master = Mixer(dryBus, performanceSpace.output)
        highpass = HighPassButterworthFilter(master, cutoffFrequency: 28)
        lowpass = LowPassButterworthFilter(highpass, cutoffFrequency: Self.ambientLowpassHz)
        masterTrim = Fader(lowpass, gain: 0)
        limiter = PeakLimiter(masterTrim, attackTime: 0.01, decayTime: 0.06, preGain: 0)
        finalTrim = Fader(limiter, gain: dbToGain(-1.5))
    }

    /// Offline verification only: render with the limiter bypassed (must still peak at or below -3 dBFS).
    var limiterBypassed: Bool {
        get { limiter.avAudioNode.auAudioUnit.shouldBypassEffect }
        set { limiter.avAudioNode.auAudioUnit.shouldBypassEffect = newValue }
    }

    /// Space macro 0...1 (section 9, calm retune D92): reverb return -9...-1 dB, RT60 6 s up to Zita's 8 s
    /// ceiling (8 s from space 0.33), warm damping, delay feedback up to 0.5, and a little halo.
    func setSpace(_ s: Float, delayAmount d: Float, brightness b: Float, shimmerScale: Float = 1, over: Double) {
        space = min(max(s, 0), 1)
        delayAmount = min(max(d, 0), 1)
        let ret = dbToGain(-9 + 8 * space)
        let mid = min(8, 6 + 6 * space)
        // Low band decays faster than the mids so the stereo reverb tail does not smear the sub (D74).
        setReverb(returnGain: ret, midRT60: mid, lowRT60: max(1, 0.48 * mid), damping: expMap(b, 1450, 2500), over: over)
        let fb = 0.3 + 0.2 * (0.4 * space + 0.6 * delayAmount)
        setDelay(feedback: fb, returnGain: dbToGain(-10 + 5 * delayAmount), cutoff: expMap(b, 1450, 2300),
                 preCutoff: expMap(b, 1200, 1900), over: over)
        // Halo: -26 dB at space 0 to -12 dB at space 1, scaled by style and image; capped at -14 dB.
        setShimmer(returnGain: dbToGain(-26 + 14 * space) * shimmerScale, over: over)
    }

    /// Scale for every layer's delay send (space x delay amount), 0.3 ... 1.4.
    var delaySendScale: Float { (0.3 + 0.7 * space) * (0.6 + 0.8 * delayAmount) }

    /// Offline diagnosis only (stem renders): returns named here ("reverb", "delay", "shimmer") stay at zero.
    var mutedReturns: Set<String> = []

    func setReverb(returnGain: Float, midRT60: Float, lowRT60: Float, damping: Float, over: Double) {
        ParamRamp.setGain(reverbReturn, mutedReturns.contains("reverb") ? 0 : returnGain, over: over)
        ParamRamp.set(reverb.$midReleaseTime, midRT60, over: over)
        ParamRamp.set(reverb.$lowReleaseTime, lowRT60, over: over)
        ParamRamp.set(reverb.$dampingFrequency, damping, over: over)
    }

    func setDelay(feedback: Float, returnGain: Float, cutoff: Float, preCutoff: Float, over: Double) {
        delaySettings = (feedback, returnGain, cutoff, preCutoff)
        applyDelaySettings(over: over)
    }

    private func applyDelaySettings(over: Double) {
        let synced = syncedDelayTime != nil
        let settings = delaySettings
        let gain = mutedReturns.contains("delay") ? 0 : settings.gain
        // Lead with the quarter-note repeat. Keep its later repeats and the offbeat wash softer.
        ParamRamp.set(delay.$feedback, settings.feedback * (synced ? 0.78 : 1), over: over)
        ParamRamp.set(delayPreFilter.$cutoffFrequency, settings.input * (synced ? 1.36 : 1), over: over)
        ParamRamp.set(delayFilter.$cutoffFrequency, settings.cutoff * (synced ? 1.11 : 1), over: over)
        for echo in beatEchoes {
            ParamRamp.set(echo.delay.$feedback, min(0.55, settings.feedback * 0.78), over: over)
            ParamRamp.set(echo.filter.$cutoffFrequency, settings.cutoff * 1.11, over: over)
        }
        ParamRamp.setGain(delayReturn, gain * (synced ? 1.52 : 1), over: over)
        ParamRamp.setGain(delayToReverb, synced ? 0.38 : 0.50, over: over)
        ParamRamp.setGain(reflectionToReverb, gain * (synced ? 0.54 : 0.66), over: over)
    }

    /// Halo return target (linear), at or below -14 dB except during a bloom (up to -10 dB).
    func setShimmer(returnGain: Float, over: Double) {
        shimmerLevel = min(returnGain, dbToGain(-14))
    }

    /// Rare event: halo return rises toward -10 dB and back over `duration` seconds.
    func bloomShimmer(duration: Double, now: Double) {
        shimmerBloom.go(to: 1, over: duration * 0.4, now: now)
        bloomEnd = now + duration * 0.45
        bloomRelease = duration * 0.55
    }
    private var bloomEnd = -1.0
    private var bloomRelease = 10.0

    /// Current shimmer return (linear), for MusicState.
    private(set) var shimmerOut: Float = 0

    struct ArchiveEchoPattern: Equatable, Sendable {
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

    /// Tempo lands on an unused bank of lines. Retire the previous feed and let its existing
    /// return dissolve instead of modulating the read point in the middle of a spoken echo.
    func syncDelay(toBeatDuration beatDuration: Double?, pattern: ArchiveEchoPattern = .straight, now: Double = 0) {
        let seconds = beatDuration.flatMap { $0.isFinite && (0.55...1.25).contains($0) ? Float($0) : nil }
        guard seconds != syncedDelayTime || (seconds != nil && pattern != activeEchoPattern) else { return }
        let retirementBeats = activeEchoPattern.answer > 0 ? 3.25 : 1.8
        let retirement = Double(syncedDelayTime ?? baseDelayTime) * retirementBeats
        if let activeBeatEcho {
            beatEchoes[activeBeatEcho].set(active: false, outputRamp: min(3.5, retirement))
        } else {
            ParamRamp.setGain(ambientDelayFeed, 0, over: 0.035)
            ParamRamp.setGain(ambientDelayOutput, 0, over: min(2.1, retirement))
            ParamRamp.setGain(ambientReflectionOutput, 0, over: min(2.1, retirement))
        }
        syncedDelayTime = seconds
        if let seconds {
            let next = 1 - lastBeatEcho
            let echo = beatEchoes[next]
            echo.prepare(beatDuration: seconds, pattern: pattern)
            echo.set(active: true, outputRamp: 0.24, answer: pattern.answer > 0)
            activeEchoPattern = pattern
            echoPhaseStart = now
            activeBeatEcho = next
            lastBeatEcho = next
        } else {
            ParamRamp.setGain(ambientDelayFeed, 1, over: 0.035)
            ParamRamp.setGain(ambientDelayOutput, 1, over: 0.10)
            ParamRamp.setGain(ambientReflectionOutput, 1, over: 0.10)
            activeBeatEcho = nil
        }
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

        func prepare(beatDuration: Float, pattern: ArchiveEchoPattern) {
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

        func motion(pattern: ArchiveEchoPattern, beat: Double) {
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

    /// 10 Hz: tape wow on the delay time (0.2 % at 0.41 Hz plus 0.06 % at 0.13 Hz), and the
    /// shimmer return with its bloom envelope.
    func modulate(t: Double, dt: Double) {
        if bloomEnd > 0 && t >= bloomEnd { shimmerBloom.go(to: 0, over: bloomRelease, now: t); bloomEnd = -1 }
        let b = shimmerBloom.tick(t)
        let g = mutedReturns.contains("shimmer") ? 0 : shimmerLevel + (dbToGain(-10) - shimmerLevel) * b
        if abs(g - shimmerOut) > 1e-5 { ParamRamp.setGain(shimmerReturn, g, over: 0.12); shimmerOut = g }
        let color = spaceDrift.value(at: t), width = widthDrift.value(at: t)
        ParamRamp.set(spacePhaser.$notchMaximumFrequency, 960 + 320 * color, over: 0.15)
        ParamRamp.set(spacePhaser.$depth, 0.48 + 0.22 * width, over: 0.15)
        ParamRamp.setGain(spaceMovement, 0.14 + 0.10 * color, over: 0.15)
        if let seconds = syncedDelayTime, let lane = activeBeatEcho {
            beatEchoes[lane].motion(pattern: activeEchoPattern, beat: max(0, t - echoPhaseStart) / Double(seconds))
        } else {
            wowPhase += dt * 2 * .pi * 0.41
            flutterPhase += dt * 2 * .pi * 0.13
            let wow = 0.002 * sin(wowPhase) + 0.0006 * sin(flutterPhase + 1)
            ParamRamp.set(delay.$time, baseDelayTime * Float(1 + wow), over: 0.11)
        }
    }

    /// Start/stop fades.
    func setMaster(_ gain: Float, over: Double) {
        ParamRamp.setGain(masterTrim, gain, over: over)
    }

    /// Master low-pass for Ambient (the calm D92 voicing).
    static let ambientLowpassHz: Float = 5400

}
