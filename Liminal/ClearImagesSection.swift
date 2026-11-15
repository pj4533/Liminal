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
        guard let usage else { return "Counting cached images" }
        let noun = usage.imageCount == 1 ? "image" : "images"
        return "\(usage.imageCount) cached \(noun), \(sizeText)"
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
                        DestructiveLabel(title: "Clear All Images", systemImage: "trash")
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
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .wrapping()

            Text("Deletes every cached image and its metadata. Settings are kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .wrapping()

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
