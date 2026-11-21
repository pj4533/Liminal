//
//  ImageSourceCredit.swift
//  Liminal
//
//  Provenance of an API-mode picture, stored in its sidecar and shown next to the film credit
//  (docs/plans/image-api-mode.md 7). Every field comes from the institution's own record.
//

import Foundation

nonisolated struct ImageSourceCredit: Codable, Sendable, Equatable {
    /// "loc", "nasa", "wikimedia", "cma", "met".
    let providerID: String
    /// Curated source id from image-collections.json, e.g. "loc-highsmith-roadside".
    let sourceID: String
    /// The provider's own id (LOC item id, NASA id, Commons file title, museum object id).
    let itemID: String
    let title: String
    var creator: String?
    var date: String?
    /// "Library of Congress", "NASA", "Wikimedia Commons", ...
    let institution: String
    /// Normalised licence label from ImageRights, e.g. "Public domain", "CC0", "CC BY-SA 4.0".
    let license: String
    var licenseURL: String?
    /// The item's page at the institution.
    let sourceURL: String
    /// The exact file that was downloaded.
    let imageURL: String

    /// Ledger key, unique across providers.
    var candidateKey: String { "\(providerID):\(itemID)" }

    /// CC BY and CC BY-SA need the creator and licence shown with the picture.
    var requiresAttribution: Bool {
        license.uppercased().hasPrefix("CC BY")
    }

    /// "Title · Creator, date · Institution · Licence".
    var displayLine: String {
        var parts = [title]
        let who = [creator, date].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
        if !who.isEmpty { parts.append(who) }
        parts.append(institution)
        parts.append(license)
        return parts.joined(separator: " · ")
    }
}
