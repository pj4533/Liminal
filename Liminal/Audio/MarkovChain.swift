import Foundation

/// A Markov chain for probabilistic note selection.
/// Transitions between scale degrees based on weighted probabilities.
final class MarkovChain {

    /// Transition matrix: [fromDegree][toDegree] = probability weight
    private var transitions: [[Float]]
    private let degreeCount: Int

    /// Current state (scale degree)
    private(set) var currentDegree: Int

    init(degreeCount: Int) {
        self.degreeCount = degreeCount
        self.currentDegree = 0

        // Initialize with uniform probabilities
        let uniform = 1.0 / Float(degreeCount)
        self.transitions = Array(
            repeating: Array(repeating: uniform, count: degreeCount),
            count: degreeCount
        )
    }

    /// Set transition probability from one degree to another
    func setTransition(from: Int, to: Int, weight: Float) {
        guard from < degreeCount && to < degreeCount else { return }
        transitions[from][to] = weight
        normalizeRow(from)
    }

    /// Get next degree based on transition probabilities
    func next() -> Int {
        let probabilities = transitions[currentDegree]
        currentDegree = weightedRandomChoice(weights: probabilities)
        return currentDegree
    }

    /// Reset to a specific degree
    func reset(to degree: Int) {
        currentDegree = min(degree, degreeCount - 1)
    }

    // MARK: - Private

    private func normalizeRow(_ row: Int) {
        let sum = transitions[row].reduce(0, +)
        guard sum > 0 else { return }
        transitions[row] = transitions[row].map { $0 / sum }
    }

    private func weightedRandomChoice(weights: [Float]) -> Int {
        let total = weights.reduce(0, +)
        var random = Float.random(in: 0..<total)

        for (index, weight) in weights.enumerated() {
            random -= weight
            if random <= 0 {
                return index
            }
        }
        return weights.count - 1
    }
}

// MARK: - Preset Chains

extension MarkovChain {

    /// Bass drone: heavily favors root (0) and fifth (4 in 7-note, 3 in 5-note)
    /// Slow movement, gravitates back to root
    static func bassDrone(degreeCount: Int) -> MarkovChain {
        let chain = MarkovChain(degreeCount: degreeCount)

        // Pentatonic (5 notes): 0=root, 2=third, 3=fifth
        // Diatonic (7 notes): 0=root, 4=fifth

        for from in 0..<degreeCount {
            // Strong pull back to root
            chain.setTransition(from: from, to: 0, weight: 3.0)

            // Fifth is also stable
            let fifth = degreeCount == 5 ? 3 : 4
            chain.setTransition(from: from, to: fifth, weight: 2.0)

            // Self-loop (stay on same note)
            chain.setTransition(from: from, to: from, weight: 2.5)

            // Adjacent notes less likely
            if from > 0 {
                chain.setTransition(from: from, to: from - 1, weight: 0.5)
            }
            if from < degreeCount - 1 {
                chain.setTransition(from: from, to: from + 1, weight: 0.5)
            }
        }

        return chain
    }

    /// Mid pad: balanced movement, chord-tone preference
    static func midPad(degreeCount: Int) -> MarkovChain {
        let chain = MarkovChain(degreeCount: degreeCount)

        for from in 0..<degreeCount {
            // Root and fifth still favored
            chain.setTransition(from: from, to: 0, weight: 1.5)

            let fifth = degreeCount == 5 ? 3 : 4
            chain.setTransition(from: from, to: fifth, weight: 1.5)

            // Third is nice too
            let third = degreeCount == 5 ? 2 : 2
            chain.setTransition(from: from, to: third, weight: 1.2)

            // Stepwise motion encouraged
            if from > 0 {
                chain.setTransition(from: from, to: from - 1, weight: 1.0)
            }
            if from < degreeCount - 1 {
                chain.setTransition(from: from, to: from + 1, weight: 1.0)
            }

            // Some self-loop
            chain.setTransition(from: from, to: from, weight: 1.0)
        }

        return chain
    }

    /// High shimmer: more movement, color tones, sparse
    static func highShimmer(degreeCount: Int) -> MarkovChain {
        let chain = MarkovChain(degreeCount: degreeCount)

        for from in 0..<degreeCount {
            // Less root emphasis
            chain.setTransition(from: from, to: 0, weight: 0.8)

            // Color tones favored (2nd, 6th in diatonic)
            if degreeCount >= 7 {
                chain.setTransition(from: from, to: 1, weight: 1.5)  // 2nd
                chain.setTransition(from: from, to: 5, weight: 1.5)  // 6th
            }

            // Larger leaps more common
            let leap = (from + 3) % degreeCount
            chain.setTransition(from: from, to: leap, weight: 1.2)

            // Less self-loop (more movement)
            chain.setTransition(from: from, to: from, weight: 0.5)

            // Stepwise still present
            if from > 0 {
                chain.setTransition(from: from, to: from - 1, weight: 0.8)
            }
            if from < degreeCount - 1 {
                chain.setTransition(from: from, to: from + 1, weight: 0.8)
            }
        }

        return chain
    }
}
