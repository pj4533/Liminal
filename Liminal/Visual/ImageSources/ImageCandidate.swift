//
//  ImageCandidate.swift
//  Liminal
//
//  One picture a provider could supply, before and after resolving its final image URL
//  (docs/plans/image-api-mode.md 3.1).
//

import Foundation

nonisolated struct ImageCandidate: Codable, Sendable, Equatable {
    let providerID: String
    /// The provider's id: LOC item id, NASA id, Commons "File:..." title, museum object id.
    let itemID: String
    var title: String?
    var creator: String?
    var date: String?
    /// Declared pixel size and bytes when the search result carries them.
    var width: Int?
    var height: Int?
    var bytes: Int?
    var mime: String?
    /// The provider's rights text, judged by ImageRights.
    var rights: String?
    var pageURL: String?
    /// Final image URL when the search already gives one (Commons, Cleveland).
    var imageURL: String?
    /// Provider-specific hint for resolving the image (LOC IIIF service id, Met classification).
    var hint: String?

    var key: String { "\(providerID):\(itemID)" }

    /// A pinned id with nothing known yet; `resolve` looks it up.
    static func stub(provider: String, id: String) -> ImageCandidate {
        ImageCandidate(providerID: provider, itemID: id)
    }

    var isStub: Bool { title == nil && imageURL == nil && hint == nil }
}

/// A candidate with everything needed to download it.
nonisolated struct ResolvedImage: Sendable, Equatable {
    let url: URL
    /// Declared size before download, when known (checked again after decode).
    var width: Int?
    var height: Int?
    var bytes: Int?
    var mime: String?
    let credit: ImageSourceCredit
    /// Tried once when `url` answers HTTP 5xx. LoC: some FSA/OWI masters fail every scaled IIIF
    /// request with 500 but serve `full/full` (1-5 MB JPEG, measured 2026-11-21); decode scales it.
    var fallbackURL: URL? = nil
}

/// One page of search results. `next` is the cursor of the following page (a page number, an
/// offset or a Commons continue token), nil on the last page.
nonisolated struct CandidatePage: Sendable, Equatable {
    var candidates: [ImageCandidate]
    var next: String?
}
