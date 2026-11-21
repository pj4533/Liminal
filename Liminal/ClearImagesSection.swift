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

    private var isAPI: Bool { visualEngine.imageSource == .api }

    private var usageLine: String {
        guard let usage else { return isAPI ? "Counting saved pictures" : "Counting cached images" }
        if isAPI {
            return "\(usage.imageCount) curated \(usage.imageCount == 1 ? "picture" : "pictures") saved, \(sizeText)"
        }
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
                        DestructiveLabel(title: isAPI ? "Clear Curated Pictures" : "Clear All Images", systemImage: "trash")
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
                isAPI ? "Delete all \(usage?.imageCount ?? 0) curated pictures (\(sizeText))?"
                      : "Delete all \(usage?.imageCount ?? 0) images (\(sizeText))?",
                isPresented: $confirming,
                titleVisibility: .visible
            ) {
                Button(isAPI ? "Delete Curated Pictures" : "Delete All Images", role: .destructive) {
                    Task {
                        await visualEngine.clearAllImages()
                        await refresh()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(isAPI ? "This cannot be undone. New pictures will be fetched from the collections."
                           : "This cannot be undone. New images will be generated.")
            }

            Text(usageLine)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .wrapping()

            Text(isAPI ? "Deletes the curated pictures saved on this device and their credits. AI images and settings are kept."
                       : "Deletes every cached AI image and its metadata. Settings are kept.")
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
        .onChange(of: visualEngine.imageSource) { _, _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        usage = await visualEngine.cacheUsage()
    }
}
