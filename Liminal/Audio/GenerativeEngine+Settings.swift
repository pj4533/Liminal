import Foundation

extension GenerativeEngine {
    /// Push the saved music choices into the engine at launch or reset.
    func apply(_ settings: SettingsService) {
        style = settings.style
        pinnedScale = settings.pinnedScale
        applyLofi(settings.lofi)
        musicMode = settings.musicMode
    }
}
