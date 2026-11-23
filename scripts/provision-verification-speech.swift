// Explicit CI-runner provisioning, separate from the app and installed-only probe.
import Foundation
import Speech

@main struct ProvisionVerificationSpeech {
    static func main() async throws {
        print("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("SpeechTranscriber.isAvailable: \(SpeechTranscriber.isAvailable)")
        print("supported: \(await SpeechTranscriber.supportedLocales)")
        print("installed before: \(await SpeechTranscriber.installedLocales)")
        guard SpeechTranscriber.isAvailable else {
            throw NSError(domain: "VerificationSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "SpeechTranscriber unavailable on this runner"])
        }
        let locale = Locale(identifier: "en-US")
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                       attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        try await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        let installed = await SpeechTranscriber.installedLocales
        print("installed after: \(installed)")
        guard installed.contains(where: { $0.identifier(.bcp47).lowercased() == "en-us" }) else {
            throw NSError(domain: "VerificationSpeech", code: 2, userInfo: [NSLocalizedDescriptionKey: "en-US still not installed"])
        }
    }
}
