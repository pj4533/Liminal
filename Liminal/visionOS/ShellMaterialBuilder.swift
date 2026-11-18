//
//  ShellMaterialBuilder.swift
//  Liminal
//
//  Unlit ShaderGraph material for one spatial shell tile (docs/plans/spatial.md, section 4).
//  Samples the effected texture with the same V flip as StereoMaterialBuilder (ShaderGraph's image
//  node reads row v * H, RealityKit UVs have v = 1 at the top), then multiplies by:
//  The tile gain dims the sides slightly. The vertical and rear fades reveal the full sphere
//  behind the relief shell. Both faces are drawn because mirroring flips the side tiles' winding.
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
        var fade = SGValue.float(1.0) - smoothStep(band, low: SGValue.float(ShellLayout.bandFadeStart),
                                                   high: SGValue.float(1.0))
        if let rear = tile.rearFade {
            if rear.full > rear.zero {
                fade = fade * smoothStep(uv.x, low: SGValue.float(rear.zero), high: SGValue.float(rear.full))
            } else {
                fade = fade * (SGValue.float(1.0) - smoothStep(uv.x, low: SGValue.float(rear.full),
                                                               high: SGValue.float(rear.zero)))
            }
        }

        let surface = unlitSurface(color: color * tile.gain, opacity: fade, applyPostProcessToneMap: false)
        var material = try await ShaderGraphMaterial(surface: surface)
        material.faceCulling = .none
        return material
    }

    /// Project the same live texture onto the sphere. The rear uses a vertical projection,
    /// and the poles gradually turn to a horizontal projection to avoid pinching.
    static func buildSurround(texture: TextureResource) async throws -> ShaderGraphMaterial {
        let direction = normalize(SGValue.modelPosition)
        let polar = smoothStep(direction.y * direction.y, low: SGValue.float(0.35), high: SGValue.float(0.8))
        let vertical = direction.y * (SGValue.float(1.0) - polar) + direction.z * polar
        let uv = SGValue.vector2f(SGValue.float(0.5) + direction.x * 0.45,
                                  SGValue.float(0.5) - vertical * 0.45)
        let color = SGValue.texture(texture).sampleColor3f(texcoord: uv)
        let surface = unlitSurface(color: color * 0.55, applyPostProcessToneMap: false)
        var material = try await ShaderGraphMaterial(surface: surface)
        material.faceCulling = .front
        return material
    }
}

#endif
