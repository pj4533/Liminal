//
//  ShellMaterialBuilder.swift
//  Liminal
//
//  Unlit ShaderGraph material for one spatial shell tile (docs/plans/spatial.md, section 4).
//  Samples the effected texture with the same V flip as StereoMaterialBuilder (ShaderGraph's image
//  node reads row v * H, RealityKit UVs have v = 1 at the top), then multiplies by:
//    - the tile gain (side tiles slightly dimmer),
//    - the vertical fade from uv1.x (band coordinate),
//    - the rear fade in u for the side tiles.
//  Fades go to opaque black, so there is no blending. The per-tile constants are baked into one
//  material per tile (no runtime parameters needed). Both faces are drawn because the side tiles
//  are mirrored with a negative scale, which flips the triangle winding.
//

#if os(visionOS)

import RealityKit
import ShaderGraphCoder

@MainActor
enum ShellMaterialBuilder {

    static func build(texture: TextureResource, tile: ShellLayout.Tile) async throws -> ShaderGraphMaterial {
        let uv = SGValue.uv0
        let flipped = SGValue.vector2f(uv.x, SGValue.float(1.0) - uv.y)
        let color = SGValue.texture(texture).sampleColor3f(texcoord: flipped)

        let band = SGValue.uv1.x
        var fade = (SGValue.float(1.0) - smoothStep(band, low: SGValue.float(ShellLayout.bandFadeStart),
                                                    high: SGValue.float(1.0))) * tile.gain
        if let rear = tile.rearFade {
            if rear.full > rear.zero {
                fade = fade * smoothStep(uv.x, low: SGValue.float(rear.zero), high: SGValue.float(rear.full))
            } else {
                fade = fade * (SGValue.float(1.0) - smoothStep(uv.x, low: SGValue.float(rear.full),
                                                               high: SGValue.float(rear.zero)))
            }
        }

        let surface = unlitSurface(color: color * fade, applyPostProcessToneMap: false)
        var material = try await ShaderGraphMaterial(surface: surface)
        material.faceCulling = .none
        return material
    }
}

#endif
