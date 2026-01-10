import SwiftUI
import Combine
import OSLog

/// Applies real-time visual effects using Metal shaders.
/// All effects are designed to be organic and flowing, matching the ambient audio aesthetic.
struct VisualEffects {

    // MARK: - Shader References

    /// Fractal Brownian Motion displacement - creates underwater/heat haze effect
    static let dreamyDistortion = ShaderLibrary.dreamyDistortion(
        .boundingRect,
        .float(0),      // time
        .float(0.015),  // amplitude (subtle!)
        .float(3.0),    // frequency
        .float(0.3)     // speed
    )

    /// Hue rotation - slowly shifts colors through spectrum
    static let hueShift = ShaderLibrary.hueShift(
        .float(0)  // shift amount (0-1)
    )

    /// Breathing wave - gentle sine wave displacement
    static let breathingWave = ShaderLibrary.breathingWave(
        .boundingRect,
        .float(0),     // time
        .float(0.01),  // amplitude
        .float(4.0)    // frequency
    )

    // MARK: - Dynamic Shader Builders

    /// Creates dreamy distortion with animated time
    static func dreamyDistortion(time: Double, amplitude: Double = 0.015, speed: Double = 0.3) -> Shader {
        ShaderLibrary.dreamyDistortion(
            .boundingRect,
            .float(time),
            .float(amplitude),
            .float(3.0),
            .float(speed)
        )
    }

    /// Creates hue shift with specified rotation
    static func hueShift(amount: Double) -> Shader {
        ShaderLibrary.hueShift(
            .float(amount)
        )
    }

    /// Creates breathing wave with animated time
    static func breathingWave(time: Double, amplitude: Double = 0.01) -> Shader {
        ShaderLibrary.breathingWave(
            .boundingRect,
            .float(time),
            .float(amplitude),
            .float(4.0)
        )
    }
}

// MARK: - View Extension for Easy Effect Application

extension View {
    /// Applies dreamy fBM distortion effect
    func dreamyDistortion(time: Double, amplitude: Double = 0.015, speed: Double = 0.3) -> some View {
        self.distortionEffect(
            VisualEffects.dreamyDistortion(time: time, amplitude: amplitude, speed: speed),
            maxSampleOffset: CGSize(width: 50, height: 50)
        )
    }

    /// Applies slow hue rotation
    func hueShift(amount: Double) -> some View {
        self.colorEffect(VisualEffects.hueShift(amount: amount))
    }

    /// Applies breathing wave distortion
    func breathingWave(time: Double, amplitude: Double = 0.01) -> some View {
        self.distortionEffect(
            VisualEffects.breathingWave(time: time, amplitude: amplitude),
            maxSampleOffset: CGSize(width: 30, height: 30)
        )
    }

    /// Applies all ambient effects at once (dreamy + hue shift)
    func ambientEffects(time: Double, hueSpeed: Double = 0.02) -> some View {
        self
            .dreamyDistortion(time: time, amplitude: 0.012, speed: 0.25)
            .hueShift(amount: time * hueSpeed)
    }
}

// MARK: - Effect Controller

/// Manages effect animation state
@MainActor
class EffectController: ObservableObject {
    @Published var time: Double = 0
    @Published var effectsEnabled: Bool = true

    private var displayLink: Timer?

    func start() {
        displayLink = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.time += 1.0/60.0
            }
        }
        LMLog.visual.info("Effect controller started")
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        LMLog.visual.info("Effect controller stopped")
    }
}
