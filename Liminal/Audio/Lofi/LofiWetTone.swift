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

    mutating func process(_ sample: LofiEffects.Stereo) -> LofiEffects.Stereo {
        midL += crossover * (sample.left - midL)
        midR += crossover * (sample.right - midR)
        lowL += lowCrossover * (midL - lowL)
        lowR += lowCrossover * (midR - lowR)
        let airL = sample.left - midL, airR = sample.right - midR
        let peak = max(abs(airL), abs(airR))
        level += (peak - level) * (peak > level ? attack : release)
        let gain = max(0.10, 0.38 / (1 + 14 * level))
        return (midL + 0.12 * (midL - lowL) + airL * gain,
                midR + 0.12 * (midR - lowR) + airR * gain)
    }
}
