//
//  ImageCreditControls.swift
//  Liminal
//
//  The credit of the picture on screen and the collections' status, shared by the macOS
//  control panel and the visionOS control window (Images & Storage section).
//

import SwiftUI

/// Credit of the picture on screen: "Title · Creator, date · Institution · Licence" and a link
/// to the institution's page. Nothing for the standby art or a test image.
struct ImageCreditLine: View {
    let metadata: ImageMetadata?

    var body: some View {
        if let credit = metadata?.source {
            VStack(alignment: .leading, spacing: 4) {
                Text("Now showing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(credit.displayLine)
                    .font(.callout)
                    .wrapping()
                    .accessibilityIdentifier("imageCredit")
                if let url = URL(string: credit.sourceURL) {
                    Link(destination: url) {
                        Label("View at \(credit.institution)", systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                }
            }
        }
    }
}

/// The curated collections' state: green while every source answers, yellow otherwise.
struct CollectionsStatusRow: View {
    var status: (text: String, ok: Bool)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(status?.ok ?? true ? Color.green : Color.yellow)
                .frame(width: 10, height: 10)
            Text(status?.text ?? "Curated collections")
                .wrapping()
        }
    }
}
