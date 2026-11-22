//
//  ClearImagesSection.swift
//  Liminal
//
//  "Clear Curated Pictures" control shared by the macOS settings sheet and the
//  visionOS settings sheet. One path: VisualEngine.clearAllImages().
//

import SwiftUI

struct ClearImagesSection: View {
    @ObservedObject var visualEngine: VisualEngine
    @State private var usage: ImageStore.Usage?
    @State private var confirming = false

    /// visionOS draws a destructive role as red text that is hard to read on glass; there the red
    /// lives in the icon (DestructiveLabel) and the confirmation dialog keeps the destructive role.
    #if os(visionOS)
    private static let buttonRole: ButtonRole? = nil
    #else
    private static let buttonRole: ButtonRole? = .destructive
    #endif

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: usage?.bytes ?? 0, countStyle: .file)
    }

    private var usageLine: String {
        guard let usage else { return "Counting saved pictures" }
        return "\(usage.imageCount) curated \(usage.imageCount == 1 ? "picture" : "pictures") saved, \(sizeText)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(role: Self.buttonRole) {
                confirming = true
            } label: {
                Group {
                    if visualEngine.isClearing {
                        ProgressView().controlSize(.small)
                    } else {
                        DestructiveLabel(title: "Clear Curated Pictures", systemImage: "trash")
                    }
                }
                .frame(minHeight: ControlMetrics.buttonHeight)
            }
            .buttonStyle(.bordered)
            #if os(visionOS)
            .buttonBorderShape(.roundedRectangle(radius: 20))
            #endif
            .disabled(visualEngine.isClearing)
            .confirmationDialog(
                "Delete all \(usage?.imageCount ?? 0) curated pictures (\(sizeText))?",
                isPresented: $confirming,
                titleVisibility: .visible
            ) {
                Button("Delete Curated Pictures", role: .destructive) {
                    Task {
                        await visualEngine.clearAllImages()
                        await refresh()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone. New pictures will be fetched from the collections.")
            }

            Text(usageLine)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .wrapping()

            Text("Deletes the curated pictures saved on this device and their credits. Settings are kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .wrapping()

        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .imageCacheCleared)) { _ in
            Task { await refresh() }
        }
        .onChange(of: visualEngine.poolCount) { _, _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        usage = await visualEngine.cacheUsage()
    }
}
