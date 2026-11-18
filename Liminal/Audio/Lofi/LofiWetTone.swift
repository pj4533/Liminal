import Foundation

/// A linked high shelf on the wet stem. Bright fragments briefly pull their own air down.
nonisolated struct LofiWetTone {
    private let crossover: Float
    private let lowCrossover: Float
    private let attack: Float
    private let release: Float
    private var midL: Float = 0
    private var midR: Float = 0
    private var lowL: Float = 0
    private var lowR: Float = 0
    private var level: Float = 0

    init(sampleRate: Double) {
        crossover = Float(1 - exp(-2 * .pi * 1_650 / sampleRate))
        lowCrossover = Float(1 - exp(-2 * .pi * 300 / sampleRate))
        attack = Float(1 - exp(-1 / (0.003 * sampleRate)))
        release = Float(1 - exp(-1 / (0.115 * sampleRate)))
    }

    mutating func process(_ sample: LofiEffects.Stereo, sweep: Float = 0.5,
                          space: Float = 0.5) -> LofiEffects.Stereo {
        // The lower edge moves against the upper edge. Bright transients narrow both
        // edges toward the mids, and the air shelf below follows the same detector.
        let pressure = min(1, level * 9)
        let upper = crossover * (0.82 + 0.37 * sweep - 0.13 * pressure)
        let lower = lowCrossover * (1.32 - 0.54 * sweep + 0.20 * pressure)
        midL += upper * (sample.left - midL)
        midR += upper * (sample.right - midR)
        lowL += lower * (midL - lowL)
        lowR += lower * (midR - lowR)
        let airL = sample.left - midL, airR = sample.right - midR
        let peak = max(abs(airL), abs(airR))
        level += (peak - level) * (peak > level ? attack : release)
        let gain = max(0.10, (0.33 + 0.05 * sweep) / (1 + 14 * level))
        let body = 0.08 + 0.16 * space + 0.07 * pressure
        return (midL + body * (midL - lowL) + airL * gain,
                midR + body * (midR - lowR) + airR * gain)
    }
}
