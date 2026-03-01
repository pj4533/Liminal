//
//  SpatialDioramaView.swift
//  Liminal
//
//  Spatial 3D diorama using visionOS 26 ImagePresentationComponent.
//  Transforms each Gemini image into a walkable 3D spatial scene
//  using Apple's on-device ML (generate()). Supports head-tracked parallax.
//
//  NOTE: generate() does not work in the visionOS Simulator.
//  Must be tested on a physical Vision Pro.
//

#if os(visionOS)

import SwiftUI
import RealityKit
import OSLog

struct SpatialDioramaView: View {
    let imageBuffer: AtomicImageBuffer

    @State private var dioramaEntity: Entity?
    @State private var lastGeneration: UInt64 = 0
    @State private var isGenerating = false

    var body: some View {
        RealityView { content in
            let entity = Entity()
            entity.position = SIMD3<Float>(0, 1.5, -1.5)  // In front of user
            content.add(entity)
            dioramaEntity = entity
        }
        .task {
            await pollForNewImages()
        }
    }

    @MainActor
    private func pollForNewImages() async {
        LMLog.visual.info("🏔️ Diorama: Starting image poll loop")
        var pollCount = 0
        while !Task.isCancelled {
            pollCount += 1
            let (image, generation) = imageBuffer.loadWithGeneration()

            if pollCount <= 3 || pollCount % 30 == 0 {
                LMLog.visual.info("🏔️ Diorama poll #\(pollCount): hasImage=\(image != nil) gen=\(generation) lastGen=\(lastGeneration) isGenerating=\(isGenerating)")
            }

            if let image = image, generation != lastGeneration, !isGenerating {
                lastGeneration = generation
                isGenerating = true
                LMLog.visual.info("🏔️ Diorama: New image detected (gen \(generation)), starting spatial generation...")
                await generateSpatialScene(from: image)
                isGenerating = false
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)  // Poll every 1s
        }
    }

    @MainActor
    private func generateSpatialScene(from cgImage: CGImage) async {
        guard let entity = dioramaEntity else {
            LMLog.visual.error("🏔️ Diorama: No entity available")
            return
        }

        LMLog.visual.info("🏔️ Diorama: Starting generation for \(cgImage.width)x\(cgImage.height) image")

        // Save CGImage to a temporary file (Spatial3DImage requires a file URL)
        guard let tempURL = saveTempImage(cgImage) else {
            LMLog.visual.error("🏔️ Diorama: Failed to save temp image")
            return
        }

        // Verify the file was saved and has content
        if let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
           let size = attrs[.size] as? Int {
            LMLog.visual.info("🏔️ Diorama: Saved temp image to \(tempURL.lastPathComponent) (\(size) bytes)")
        }

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        do {
            let startTime = CFAbsoluteTimeGetCurrent()

            // Create spatial 3D image from file
            LMLog.visual.info("🏔️ Diorama: Creating Spatial3DImage from file...")
            let spatial3D = try await ImagePresentationComponent.Spatial3DImage(contentsOf: tempURL)
            LMLog.visual.info("🏔️ Diorama: Spatial3DImage created, starting generate()...")

            // Generate the 3D representation (ML inference, takes several seconds)
            try await spatial3D.generate()
            LMLog.visual.info("🏔️ Diorama: generate() complete")

            // Create component and attach to entity
            var component = ImagePresentationComponent(spatial3DImage: spatial3D)
            component.desiredViewingMode = .spatial3DImmersive
            LMLog.visual.info("🏔️ Diorama: Using spatial3DImmersive mode")

            entity.components.set(component)

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            LMLog.visual.info("🏔️ Diorama: Generated spatial scene in \(String(format: "%.1f", elapsed))s")
        } catch {
            LMLog.visual.error("🏔️ Diorama: Generation failed: \(error)")
            LMLog.visual.error("🏔️ Diorama: Error type: \(type(of: error)), description: \(error.localizedDescription)")
        }
    }

    private func saveTempImage(_ cgImage: CGImage) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("liminal_diorama_\(UUID().uuidString).jpg")

        // Use JPEG format for better compatibility with ImagePresentationComponent
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            LMLog.visual.error("🏔️ Diorama: Failed to create image destination")
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            LMLog.visual.error("🏔️ Diorama: Failed to finalize image destination")
            return nil
        }

        return url
    }
}

#endif
