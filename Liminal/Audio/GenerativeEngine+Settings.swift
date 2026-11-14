import Foundation

extension GenerativeEngine {
    /// Push every persisted music setting into the engine (launch, reset). Keys are unchanged from the
    /// three-voice engine (decision D67): `audio.notes` drives Density, `audio.reverb` drives Space,
    /// `audio.delay` drives the delay amount (and the visual ghost-tap trail), plus `audio.style` and
    /// `audio.scaleAuto`.
    func apply(_ settings: SettingsService) {
        delay = settings.delay
        space = settings.reverb
        density = settings.notes
        style = settings.style
        pinnedScale = settings.pinnedScale
    }
}
