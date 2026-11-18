#if DEBUG
import AudioKit
import AudioToolbox
import AVFoundation
import Foundation
import OSLog
import Synchronization

/// Diagnostics for optional Audio Units. This host has no connection to playback or the audio device.
nonisolated enum LofiProviderProbe {
    struct Target: Sendable {
        let name: String
        let manufacturers: [String]
        let componentNames: [String]
        let role: Role
    }

    enum Role: String, Sendable { case limiter, compressor, instrument, texture, midi }

    private static let targets: [Target] = [
        .init(name: "Pro-L 2", manufacturers: ["FabFilter", "FabFilter Software Instruments"],
              componentNames: ["Pro-L 2", "FabFilter Pro-L 2"], role: .limiter),
        .init(name: "Pro-C 2", manufacturers: ["FabFilter", "FabFilter Software Instruments"],
              componentNames: ["Pro-C 2", "FabFilter Pro-C 2"], role: .compressor),
        .init(name: "Animoog Z", manufacturers: ["Moog Music", "Moog Music Inc", "Moog"], componentNames: ["Animoog Z"], role: .instrument),
        .init(name: "Model 15", manufacturers: ["Moog Music", "Moog Music Inc", "Moog"], componentNames: ["Model 15", "Model 15 Modular Synthesizer"], role: .instrument),
        .init(name: "Gauss", manufacturers: ["Bram Bos", "Bram Bos & Hainbach"], componentNames: ["Gauss", "Gauss Field Looper"], role: .texture),
        .init(name: "Fluss", manufacturers: ["Bram Bos", "Bram Bos & Hainbach"], componentNames: ["Fluss", "Fluss - Granular Playground"], role: .texture),
        .init(name: "Rozeta", manufacturers: ["Bram Bos"], componentNames: ["Rozeta Bassline", "Rozeta Arpeggio"], role: .midi),
        .init(name: "Fugue Machine", manufacturers: ["Alexandernaut", "Alexander Randon"], componentNames: ["Fugue Machine", "Fugue Machine Rubato"], role: .midi),
        .init(name: "Wotja 22", manufacturers: ["Intermorphic", "Intermorphic Ltd"], componentNames: ["Wotja 22", "Wotja Pro 22"], role: .midi),
    ]

    struct Identity: Hashable, Sendable {
        let type: OSType
        let subtype: OSType
        let manufacturer: OSType
        let version: UInt32

        var label: String {
            [type, subtype, manufacturer].map { code in
                let bytes = (0..<4).reversed().map { UInt8(truncatingIfNeeded: code >> ($0 * 8)) }
                return bytes.allSatisfy { (32...126).contains($0) }
                    ? String(decoding: bytes, as: UTF8.self) : String(format: "%08x", code)
            }.joined(separator: "/") + String(format: "@%08x", version)
        }
    }

    struct Candidate: Sendable {
        let identity: Identity
        let componentName: String
        let manufacturerName: String
        let role: Role
        let isV3: Bool

        var description: AudioComponentDescription {
            .init(componentType: identity.type, componentSubType: identity.subtype,
                  componentManufacturer: identity.manufacturer, componentFlags: 0, componentFlagsMask: 0)
        }
    }

    static func runIfRequested() {
        let settings = UserDefaults.standard
        guard settings.bool(forKey: "LiminalProbeLofiProviders") else { return }
        let cycles = min(20, max(1, settings.integer(forKey: "LiminalProbeLofiProviderCycles")))
        let control = settings.bool(forKey: "LiminalProbeLofiBuiltinAU")
        Task.detached(priority: .utility) { await Coordinator.shared.start(cycles: cycles, includeBuiltin: control) }
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private static func discover(reportMissing: Bool = true) -> [Candidate] {
        let types = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect, kAudioUnitType_MusicDevice,
                     kAudioUnitType_MIDIProcessor]
        let manager = AVAudioUnitComponentManager.shared()
        let components = types.flatMap {
            manager.components(matching: .init(componentType: $0, componentSubType: 0, componentManufacturer: 0,
                                                componentFlags: 0, componentFlagsMask: 0))
        }
        var known = Set<Identity>()
        var candidates: [Candidate] = []
        for target in targets {
            let publishers = Set(target.manufacturers.map(normalized))
            let names = Set(target.componentNames.map(normalized))
            let matches = components.filter {
                publishers.contains(normalized($0.manufacturerName)) && names.contains(normalized($0.name))
            }
            if reportMissing && matches.isEmpty {
                LMLog.audio.info("Lo-Fi AU discovery \(target.name, privacy: .public) has no matching native registration")
            }
            for match in matches {
                let description = match.audioComponentDescription
                let identity = Identity(type: description.componentType, subtype: description.componentSubType,
                                        manufacturer: description.componentManufacturer, version: UInt32(truncatingIfNeeded: match.version))
                guard known.insert(identity).inserted else { continue }
                let isV3 = AudioComponentFlags(rawValue: description.componentFlags).contains(.isV3AudioUnit)
                candidates.append(.init(identity: identity, componentName: match.name, manufacturerName: match.manufacturerName,
                                        role: target.role, isV3: isV3))
            }
        }
        return candidates
    }

    private static let appleLimiter = Candidate(
        identity: .init(type: kAudioUnitType_Effect, subtype: kAudioUnitSubType_PeakLimiter,
                        manufacturer: kAudioUnitManufacturer_Apple, version: 0),
        componentName: "Apple Peak Limiter diagnostic control", manufacturerName: "Apple",
        role: .limiter, isV3: false
    )

    enum ComparisonFailure: LocalizedError {
        case unavailable(String), rejected(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let identity): "No allowlisted limiter matches \(identity)"
            case .rejected(let reason): "Limiter comparison fixture did not qualify: \(reason)"
            }
        }
    }

    /// Explicitly opt in to a separate offline experiment. A failed candidate is surfaced to the
    /// comparison runner, so an unchanged fallback cannot be mistaken for a successful audition.
    @MainActor
    static func makeComparisonLimiter(identity: String, input: Node) async throws -> LofiOfflineComparisonUnit {
        let builtin = identity == "apple-peak-limiter"
        let candidate: Candidate
        if builtin {
            candidate = appleLimiter
        } else {
            guard let match = discover(reportMissing: false).first(where: {
                $0.role == .limiter && $0.isV3 && $0.identity.label == identity
            }) else { throw ComparisonFailure.unavailable(identity) }
            candidate = match
            let report = try await LofiAUQualification.probe(candidate, builtin: false).get()
            guard report.passed else { throw ComparisonFailure.rejected(report.summary) }
        }
        let instance = try await LofiAUQualification.freshComparisonUnit(candidate, builtin: builtin)
        return LofiOfflineComparisonUnit(input: input, unit: instance.node,
                                         providerID: builtin ? identity : candidate.identity.label)
    }

    actor Coordinator {
        static let shared = Coordinator()
        private var started = false
        private var checking = false
        private var refreshRequested = false
        private var timedOut = false
        private var cycles = 1
        private var includeBuiltin = false
        private var observer: NSObjectProtocol?
        private var debounce: Task<Void, Never>?
        private var checked = Set<Identity>()
        private var quarantine = Set<Identity>()

        func start(cycles: Int, includeBuiltin: Bool) async {
            guard !started else { return }
            started = true
            self.cycles = cycles
            self.includeBuiltin = includeBuiltin
            observer = NotificationCenter.default.addObserver(forName: AVAudioUnitComponentManager.registrationsChangedNotification,
                                                              object: nil, queue: nil) { _ in
                Task { await self.registrationsChanged() }
            }
            await report()
        }

        private func registrationsChanged() {
            debounce?.cancel()
            debounce = Task {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await report()
            }
        }

        private func report() async {
            guard !checking else { refreshRequested = true; return }
            checking = true
            defer {
                checking = false
                if refreshRequested {
                    refreshRequested = false
                    registrationsChanged()
                }
            }
            var candidates = LofiProviderProbe.discover()
            LMLog.audio.info("Lo-Fi AU host \(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public) registered candidates=\(candidates.count)")
            if includeBuiltin {
                candidates.append(LofiProviderProbe.appleLimiter)
            }
            for candidate in candidates {
                let id = candidate.identity
                guard checked.insert(id).inserted, !quarantine.contains(id) else { continue }
                LMLog.audio.info("Lo-Fi AU metadata \(candidate.componentName, privacy: .public) \(candidate.manufacturerName, privacy: .public) \(id.label, privacy: .public) AUv3=\(candidate.isV3)")
                let builtin = id.manufacturer == kAudioUnitManufacturer_Apple
                guard candidate.isV3 || builtin else { continue }
                guard !timedOut else {
                    LMLog.audio.notice("Lo-Fi AU fixture skipped after an earlier provider timeout")
                    continue
                }
                for cycle in 1...cycles {
                    let result = await LofiAUQualification.probe(candidate, builtin: builtin)
                    switch result {
                    case .success(let report):
                        LMLog.audio.info("Lo-Fi AU fixture \(id.label, privacy: .public) cold cycle=\(cycle) \(report.summary, privacy: .public)")
                        if cycle == 1 {
                            for parameter in report.parameters {
                                LMLog.audio.info("Lo-Fi AU parameter \(id.label, privacy: .public) \(parameter, privacy: .public)")
                            }
                        }
                        if !report.passed { quarantine.insert(id) }
                    case .failure(let problem):
                        LMLog.audio.notice("Lo-Fi AU fixture \(id.label, privacy: .public) cold cycle=\(cycle) \(problem.localizedDescription, privacy: .public)")
                        quarantine.insert(id)
                        if problem == .timeout { timedOut = true }
                    }
                    if quarantine.contains(id) { break }
                }
            }
            LMLog.audio.info("Lo-Fi AU diagnostic completed. Active playback provider remains built-in.")
        }
    }
}

nonisolated final class LofiOfflineComparisonUnit: Node {
    let input: Node
    let unit: AVAudioUnit
    let providerID: String
    var connections: [Node] { [input] }
    var avAudioNode: AVAudioNode { unit }

    init(input: Node, unit: AVAudioUnit, providerID: String) {
        self.input = input
        self.unit = unit
        self.providerID = providerID
    }
}
#endif
