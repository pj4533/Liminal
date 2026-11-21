//
//  ImageRights.swift
//  Liminal
//
//  Rights rule for API mode (decision D37): keep a picture only when its own record says it is
//  public domain, CC0, carries no known restrictions, or is CC BY / CC BY-SA (credited). Unknown,
//  empty, non-commercial and no-derivatives licences are rejected.
//

import Foundation

nonisolated enum ImageRights {

    enum Verdict: Sendable, Equatable {
        case allowed(license: String)
        case rejected(reason: String)

        var license: String? {
            if case .allowed(let l) = self { return l }
            return nil
        }
    }

    /// Canonical licence label for a rights text, or nil when it is not recognised.
    static func canonical(_ text: String) -> String? {
        var t = text.lowercased()
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix(".") { t.removeLast() }
        t = t.replacingOccurrences(of: "_", with: " ")
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !t.isEmpty else { return nil }

        // Non-commercial / no-derivatives are never allowed, whatever else the text says.
        if t.range(of: #"\b(nc|nd)\b"#, options: .regularExpression) != nil
            || t.contains("noncommercial") || t.contains("non-commercial") || t.contains("noderiv") {
            return nil
        }
        if t.contains("not evaluated") || t.contains("restricted") {
            return nil
        }
        if t == "cc0" || t.hasPrefix("cc0 ") || t.hasPrefix("cc-zero") || t == "cc zero" || t.contains("creative commons zero") {
            return "CC0"
        }
        if t == "pd" || t.hasPrefix("pd-") || t.hasPrefix("pd ") || t.hasPrefix("public domain") || t == "pdm"
            || t.hasPrefix("public domain mark") {
            return "Public domain"
        }
        if t.hasPrefix("no known restrictions") { return "No known restrictions" }
        if t == "no restrictions" { return "No restrictions" }
        if t.hasPrefix("us government work") || t.hasPrefix("u.s. government work") { return "Public domain" }

        // CC BY / CC BY-SA with a version, written with spaces or hyphens ("CC BY-SA 3.0", "CC-BY-SA-3.0"),
        // and an optional port suffix ("CC BY-SA 3.0 de") that is dropped.
        var words = t.replacingOccurrences(of: "-", with: " ").split(separator: " ").map(String.init)
        guard words.count >= 2, words[0] == "cc", words[1] == "by" else { return nil }
        words.removeFirst(2)
        var label = "CC BY"
        if words.first == "sa" { label += "-SA"; words.removeFirst() }
        if let version = words.first, version.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil {
            label += " " + version
            words.removeFirst()
        }
        // Anything left must be a port code ("de", "nl").
        guard words.count <= 1, words.allSatisfy({ $0.range(of: #"^[a-z]{2,3}$"#, options: .regularExpression) != nil }) else { return nil }
        return label
    }

    /// Judges `rightsText` against the allowlist (compared after canonicalisation).
    static func verdict(rightsText: String?, allowlist: [String]) -> Verdict {
        guard let text = rightsText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(reason: "no rights statement")
        }
        guard let label = canonical(text) else { return .rejected(reason: "rights not allowed: \(text.prefix(60))") }
        let allowed = Set(allowlist.compactMap(canonical))
        // "No known restrictions" and "No restrictions" are the same family.
        if allowed.contains(label) { return .allowed(license: label) }
        return .rejected(reason: "licence not on the allowlist: \(label)")
    }

    /// Standard deed links for the credit.
    static func licenseURL(_ label: String) -> String? {
        switch label {
        case "CC0": return "https://creativecommons.org/publicdomain/zero/1.0/"
        case "Public domain": return "https://creativecommons.org/publicdomain/mark/1.0/"
        default:
            let parts = label.split(separator: " ")
            guard parts.count == 3, parts[0] == "CC" else { return nil }
            let kind = parts[1].lowercased()   // by or by-sa
            return "https://creativecommons.org/licenses/\(kind)/\(parts[2])/"
        }
    }
}
