import Accelerate
import Foundation

/// Dub throws on the bass (plan 2.4): the body layer alone of a thrown note (no sub), high-passed at
/// 250 Hz, into a tape echo of three quarters of a beat with a dark saturating loop, and a short spring.
/// The return goes into the phrase's space arrays, so it shares the wet stem, its ducks and its carried
/// tail; the low end stays dry and mono in the bass stem. Offline, on the render worker.
nonisolated enum LofiBassThrow {
    static let sendHighpass = 250.0
    static let echoBeats = 0.75
    static let feedback: Float = 0.35
    static let loopLowpass = 2_500.0
    /// The right tap trails the left by this much, seconds.
    static let rightOffset = 0.012
    static let springDecay = 1.1
    static let springPreDelay = 0.030
    static let springUnderEchoDB: Float = 6
    /// The return's strongest 400 ms sits this far under the thrown notes' own strongest 400 ms (sub plus
    /// body) before the space chain (start; calibrated so the throw sits about 20 dB under the bass stem's
    /// strongest 400 ms in the finished wet stem, plan 2.4).
    static let returnUnderNoteDB: Float = 21
    /// A 48 dB per octave high-pass on the return (the loop's tanh makes difference tones): with the
    /// send's and the space chain's, nothing below 200 Hz comes within 40 dB of the return's strongest band.
    static let returnHighpass = 350.0

    /// How long the return rings after the last thrown note ends: the echo falls 9 dB a repeat, so six
    /// repeats reach -55 dB; the spring is gone after its decay.
    static func ringFrames(_ clock: LofiClock) -> Int { 6 * clock.frame(at: echoBeats) + Int((springDecay + springPreDelay) * clock.sampleRate) }

    /// Tests render a phrase without throws to isolate the return.
    @TaskLocal static var isEnabled = true

    /// The return of `thrown` over phrase frames `origin ..< origin + frames`.
    static func render(_ thrown: [LofiScore.Note], kit: LofiBassSamples.Kit, clock: LofiClock, frames: Int,
                       origin: Int = 0, sweep: ClosedRange<Double>? = nil, samples: LofiBassSamples = .bundled)
        -> (left: [Float], right: [Float]) {
        let rate = clock.sampleRate
        var send = [Float](repeating: 0, count: frames)
        for note in thrown {
            let start = clock.frame(at: note.beat) - origin
            guard start >= 0, start < frames else { continue }
            let body = LofiBassVoice.render(note, kit: kit, clock: clock, limit: frames - start, samples: samples,
                                            sweep: sweep, layers: .body)
            body.withUnsafeBufferPointer { b in
                send.withUnsafeMutableBufferPointer { s in
                    vDSP_vadd(s.baseAddress! + start, 1, b.baseAddress!, 1, s.baseAddress! + start, 1, vDSP_Length(b.count))
                }
            }
        }
        let q = (0.541_196_100_146_197, 1.306_562_964_876_377)
        var highpass = LofiFilterChain([.highpass(hz: sendHighpass, q: q.0), .highpass(hz: sendHighpass, q: q.1)],
                                       sampleRate: rate)
        send.withUnsafeMutableBufferPointer { highpass.process($0.baseAddress!, count: frames) }

        var echo = self.echo(send, delay: max(1, clock.frame(at: echoBeats)), offset: Int(rightOffset * rate), rate: rate)
        var spring = self.spring(send, rate: rate)
        // The spring sits `springUnderEchoDB` under the echo (RMS over the phrase plus tail).
        let echoRMS = rms(echo.left), springRMS = rms(spring.left)
        var springGain = springRMS > 1e-9 ? echoRMS * powf(10, -springUnderEchoDB / 20) / springRMS : 0
        vDSP_vsma(spring.left, 1, &springGain, echo.left, 1, &echo.left, 1, vDSP_Length(frames))
        vDSP_vsma(spring.right, 1, &springGain, echo.right, 1, &echo.right, 1, vDSP_Length(frames))
        spring = ([], [])
        var after = LofiFilterChain([.highpass(hz: returnHighpass, q: q.0), .highpass(hz: returnHighpass, q: q.1),
                                     .highpass(hz: returnHighpass, q: q.0), .highpass(hz: returnHighpass, q: q.1)],
                                    sampleRate: rate)
        after.process(left: &echo.left, right: &echo.right)
        // Level against the thrown notes themselves.
        var voice = [Float](repeating: 0, count: frames)
        for note in thrown {
            let start = clock.frame(at: note.beat) - origin
            guard start >= 0, start < frames else { continue }
            let full = LofiBassVoice.render(note, kit: kit, clock: clock, limit: frames - start, samples: samples, sweep: sweep)
            voice.withUnsafeMutableBufferPointer { v in
                vDSP_vadd(v.baseAddress! + start, 1, full, 1, v.baseAddress! + start, 1, vDSP_Length(full.count))
            }
        }
        let wanted = strongest(voice, rate: rate) * powf(10, -returnUnderNoteDB / 20)
        let have = max(strongest(echo.left, rate: rate), strongest(echo.right, rate: rate))
        var gain = have > 1e-9 ? wanted / have : 0
        vDSP_vsmul(echo.left, 1, &gain, &echo.left, 1, vDSP_Length(frames))
        vDSP_vsmul(echo.right, 1, &gain, &echo.right, 1, vDSP_Length(frames))
        return echo
    }

    /// Repeats only (no dry), the left tap `delay` frames late and the right `offset` later still, each
    /// through the loop's 2.5 kHz one-pole and a tanh.
    static func echo(_ send: [Float], delay: Int, offset: Int, rate: Double) -> (left: [Float], right: [Float]) {
        let count = send.count
        var line = [Float](repeating: 0, count: count)
        var left = line, right = line
        let a = Float(1 - exp(-2 * .pi * loopLowpass / rate))
        let first = send.firstIndex { $0 != 0 } ?? count
        var stateL: Float = 0, stateR: Float = 0
        send.withUnsafeBufferPointer { x in
            line.withUnsafeMutableBufferPointer { d in
                left.withUnsafeMutableBufferPointer { l in
                    right.withUnsafeMutableBufferPointer { r in
                        for i in first..<count {
                            let tapL = i >= delay ? d[i - delay] : 0
                            let tapR = i >= delay + offset ? d[i - delay - offset] : 0
                            stateL += a * (tapL - stateL)
                            stateR += a * (tapR - stateR)
                            l[i] = stateL
                            r[i] = stateR
                            d[i] = x[i] + feedback * tanhf(stateL)
                        }
                    }
                }
            }
        }
        return (left, right)
    }

    /// A small spring: pre-delay, a dispersive allpass chain (the chirp), then two damped combs (left and
    /// right) whose decay reaches -60 dB after `springDecay` seconds.
    static func spring(_ send: [Float], rate: Double) -> (left: [Float], right: [Float]) {
        let count = send.count
        let pre = Int(springPreDelay * rate)
        var x = [Float](repeating: 0, count: count)
        if pre < count { x.replaceSubrange(pre..<count, with: send[0..<(count - pre)]) }
        let first = x.firstIndex { $0 != 0 } ?? count
        x.withUnsafeMutableBufferPointer { b in
            for ms in [1.3, 1.9, 2.7, 3.3, 4.1, 5.3] {
                let d = max(1, Int(ms * 0.001 * rate))
                var buffer = [Float](repeating: 0, count: d)
                buffer.withUnsafeMutableBufferPointer { z in
                    var k = 0
                    let g: Float = 0.62
                    for i in first..<count {
                        let delayed = z[k]
                        let v = b[i] + g * delayed
                        b[i] = delayed - g * v
                        z[k] = v
                        k += 1
                        if k == d { k = 0 }
                    }
                }
            }
        }
        func comb(_ seconds: Double) -> [Float] {
            let d = max(1, Int(seconds * rate))
            let g = Float(pow(10, -3 * seconds / springDecay))
            let damp = Float(1 - exp(-2 * .pi * 3_000 / rate))
            var buffer = [Float](repeating: 0, count: d)
            var out = [Float](repeating: 0, count: count)
            x.withUnsafeBufferPointer { input in
                buffer.withUnsafeMutableBufferPointer { z in
                    out.withUnsafeMutableBufferPointer { o in
                        var k = 0, lp: Float = 0
                        for i in first..<count {
                            let delayed = z[k]
                            lp += damp * (delayed - lp)
                            o[i] = delayed
                            z[k] = input[i] + g * lp
                            k += 1
                            if k == d { k = 0 }
                        }
                    }
                }
            }
            return out
        }
        return (comb(0.0371), comb(0.0413))
    }

    /// RMS of the strongest 400 ms window (100 ms hop).
    static func strongest(_ x: [Float], rate: Double) -> Float {
        let window = Int(0.4 * rate), hop = Int(0.1 * rate)
        guard x.count >= window else { return rms(x) }
        var best: Float = 0
        x.withUnsafeBufferPointer { p in
            var start = 0
            while start + window <= x.count {
                var value: Float = 0
                vDSP_rmsqv(p.baseAddress! + start, 1, &value, vDSP_Length(window))
                best = max(best, value)
                start += hop
            }
        }
        return best
    }

    private static func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(x, 1, &value, vDSP_Length(x.count))
        return value
    }
}
