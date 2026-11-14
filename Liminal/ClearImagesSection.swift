//
//  ClearImagesSection.swift
//  Liminal
//
//  "Clear All Images" control shared by the macOS settings sheet and the
//  visionOS settings sheet. One path: VisualEngine.clearAllImages().
//

import SwiftUI

struct ClearImagesSection: View {
    @ObservedObject var visualEngine: VisualEngine
    @State private var usage: ImageStore.Usage?
    @State private var confirming = false

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: usage?.bytes ?? 0, countStyle: .file)
    }

    private var usageLine: String {
        guard let usage else { return "Counting cached images..." }
        let noun = usage.imageCount == 1 ? "image" : "images"
        return "\(usage.imageCount) cached \(noun), \(sizeText)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(role: .destructive) {
                confirming = true
            } label: {
                if visualEngine.isClearing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Clear All Images")
                }
            }
            .disabled(visualEngine.isClearing)
            .confirmationDialog(
                "Delete all \(usage?.imageCount ?? 0) images (\(sizeText))?",
                isPresented: $confirming,
                titleVisibility: .visible
            ) {
                Button("Delete All Images", role: .destructive) {
                    Task {
                        await visualEngine.clearAllImages()
                        await refresh()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone. New images will be generated.")
            }

            Text(usageLine)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if let status = visualEngine.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .imageCacheCleared)) { _ in
            Task { await refresh() }
        }
        .onChange(of: visualEngine.totalCachedCount) { _, _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        usage = await visualEngine.cacheUsage()
    }
}
