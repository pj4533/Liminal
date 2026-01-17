# Liminal visionOS 3D/AR Effects Brainstorm

*Brainstormed: January 2026*

## Design Criteria
1. **Super psychedelic** - trippy, mind-expanding
2. **Subtle integration** - NOT flying shapes, but woven into the experience
3. **Derived from content** - extrapolated from images or existing effects

## Current Direction
- **Depth approach:** visionOS 26 Spatial Scenes (Apple's generative AI)
- **Audio reactivity:** Not needed - keep audio/visuals separate
- **Interaction:** Fully passive - ambient, meditative experience
- **First target:** Panel Breathing - mesh vertex animation

---

## Current Architecture (What We're Building On)

| Component | Capability |
|-----------|------------|
| **Curved Panel** | 110° x 75° sphere section at 2m, 32x24 vertices |
| **Effects Shader** | fBM distortion, Ken Burns, hue waves, ghost taps |
| **DepthAnalyzer** | Vision framework saliency (exists but unused) |
| **Performance** | ~3-5ms/frame of 11.1ms budget (lots of headroom) |
| **Audio Engine** | Soft pad synth (no visual bridge yet) |

---

## TIER 1: Subtle Depth Effects (The Sweet Spot)

### 1. **Depth-Extruded Parallax Layers** ★★★★★
*The image floats in space with real depth*

**Concept:** Split AI image into 2-3 depth layers on concentric curved panels. Head movement creates natural parallax - foreground floats toward you, background recedes.

**Why it's subtle:** No added objects - just the image itself gains dimensionality. Combined with fBM, creates "breathing underwater in 3D" effect.

**Technical:**
- Generate depth map from image (Apple's [Depth Pro](https://machinelearning.apple.com/research/depth-pro) or visionOS 26's Spatial Scenes API)
- Create 2-3 panels at radii 1.9m, 2.0m, 2.1m
- Alpha-mask each layer by depth bands
- Apply existing effects to each layer

**Performance:** 2-3x render cost (doable given headroom)

---

### 2. **Gentle Panel Breathing** ★★★★★ (IMPLEMENTED)
*The viewing surface itself becomes organic*

**Concept:** Animate mesh vertices with sine waves - the curved panel gently undulates like a membrane. Subtle enough to avoid motion sickness but perceptible as alive.

**Why it's subtle:** The "screen" transforms into living tissue. No new objects, just the existing surface breathing.

**Technical (Lessons Learned):**
- **LowLevelMesh + withUnsafeMutableBytes DOES NOT WORK** for CPU-side visual updates (changes don't reflect)
- **LowLevelMesh + Metal compute shader** works but requires GPU integration
- **MeshResource.replace(with: contents)** works - generate new mesh, extract contents, replace
- **ShaderGraphMaterial + Geometry Modifier** is the "proper" visionOS approach (requires Reality Composer Pro)
- Current implementation: `MeshResource.generate()` → `.contents` → `.replace(with:)` each frame
- Mesh segments: 48x36 (1813 vertices)
- Parameters: amplitude=0.06, speed=0.4

**Performance:** ~1-2ms per frame for mesh regeneration (acceptable given headroom)

**Resources:**
- [Apple WWDC24: Build a spatial drawing app](https://developer.apple.com/videos/play/wwdc2024/10104/)
- [GitHub: metal-spatial-dynamic-mesh](https://github.com/metal-by-example/metal-spatial-dynamic-mesh)
- [ShaderGraphCoder](https://github.com/praeclarum/ShaderGraphCoder) - Programmatic ShaderGraphMaterial

---

### 3. **Depth-Based Z-Displacement** ★★★★★
*The image physically pushes forward and back*

**Concept:** Use depth map to displace vertices in Z-axis. Salient objects (faces, subjects) literally push toward viewer. Apply fBM to Z-displacement too.

**Why it's subtle:** The flat image becomes a relief sculpture. Nothing added - just revealing the depth already implied by the content.

**Technical:**
- Pass depth texture to vertex shader
- Sample depth at vertex UV, displace along normal
- Combine with fBM for trippy organic undulation

**Performance:** Minimal (vertex shader addition)

---

### 4. **visionOS 26 Spatial Scenes Integration** ★★★★
*Use Apple's AI to add perspective*

**Concept:** Feed AI images to visionOS 26's Spatial Scenes API. Apple's generative AI adds depth and multiple perspectives - you can lean in and look around.

**Why it's subtle:** Apple's system is designed for photos - creates convincing depth without explicit 3D modeling.

**Technical:**
- Use [Spatial Scene API](https://www.apple.com/newsroom/2025/06/visionos-26-introduces-powerful-new-spatial-experiences-for-apple-vision-pro/) (available to developers)
- Requires visionOS 26+ target
- May need to integrate differently than current Metal pipeline

**Performance:** Unknown (Apple's system)

---

## TIER 2: Atmospheric/Spatial Effects

### 5. **Audio-Reactive Volumetric Haze** ★★★★
*The music becomes visible atmosphere*

**Concept:** Spawn subtle fog layer between user and display (~1.5m). Density responds to audio amplitude. Shimmer notes create luminous wisps. Color matched to current image.

**Why it's subtle:** Not a visualizer - just felt atmospheric presence. Like experiencing music as weather.

**Technical:**
- Secondary quad with animated alpha shader
- Sample dominant colors from image for tinting
- Connect audio amplitude to density uniform
- Particle wisps on `shimmerNotePlayed` events

**Performance:** Single extra quad (~1ms)

---

### 6. **Peripheral Particle Aurora** ★★★★
*Always there but never quite seen*

**Concept:** RealityKit particles at 45° from center view. Particles drift inward slowly, color-matched to image. Always in peripheral vision, fade as they approach center.

**Why it's subtle:** Exploits peripheral vision psychology - you sense movement but can't directly observe it. The "corner of your eye" effect.

**Technical:**
- [ParticleEmitterComponent](https://developer.apple.com/documentation/RealityKit/simulating-particles-in-your-visionos-app) in RealityKit
- Position emitters at peripheral angles
- Sample image palette for particle colors
- Fade alpha based on distance to gaze center

**Performance:** Modern particles are cheap (50-100 particles)

---

### 7. **Spatial Audio Orbs** ★★★
*Sound has physical location*

**Concept:** 3 small glowing spheres around user - bass (below/behind), mid (sides), shimmer (above/front). Pulse with audio. Use `SpatialAudioComponent` so actual sound emanates from positions.

**Why it's subtle:** Tiny, glowing presences. The music surrounds you spatially rather than coming from everywhere.

**Technical:**
- 3 sphere entities with emissive materials
- Orbital motion + size pulsing from audio
- visionOS spatial audio for positional sound

**Performance:** Minimal (3 simple meshes)

---

## TIER 3: Interaction Effects

### 8. **Head-Movement Color Trails** ★★★★
*Your movement creates rainbow echoes*

**Concept:** As you turn your head, leave behind ghost panels at previous positions. Ghosts fade out with increasing hue shift - creates rainbow trail during head rotation.

**Why it's subtle:** Only visible when you move. At rest, nothing extra exists.

**Technical:**
- Track head rotation velocity via ARKit
- Spawn ghost panels at threshold
- Apply strong hue shift to older ghosts
- Fade over 0.5-1 second

**Performance:** Multiple render targets (needs optimization)

---

### 9. **Hand-Presence Ripples** ★★★
*Your physical presence creates waves*

**Concept:** When hands enter view, create ripple effects emanating from hand positions in the visual display. Your existence disturbs the visual field.

**Why it's subtle:** Only when you raise hands. Passive viewing = no effect.

**Technical:**
- [ARKit hand tracking](https://developer.apple.com/documentation/arkit/arkit-in-visionos) for positions
- Project onto curved panel UV space
- Ripple displacement shader

**Performance:** Hand tracking already runs

---

### 10. **Gaze-Reactive Focal Warping** ★★★★★
*What you attend to responds*

**Concept:** Eye tracking identifies gaze point. Gazed area becomes clearer/more saturated while periphery becomes dreamier. Your attention literally shapes reality.

**Why it's subtle:** Imperceptible until you start moving your eyes. Then it feels like the world responds to your attention.

**Technical:**
- ARKit gaze ray → intersect with panel
- Reduce fBM at gaze point
- Increase saturation where you look
- Smooth falloff from gaze center

**Performance:** Eye tracking is lightweight

---

## TIER 4: Experimental

### 11. **Temporal Echo Chamber** ★★★★
*Time becomes visible as depth*

**Concept:** Ring buffer of rendered frames at different depths. Nearest = now, layers behind = 1, 2, 3 seconds ago. The past literally fades into distance.

**Why it's subtle:** At rest, all layers show same thing. During transitions, time itself becomes visible.

**Technical:**
- 4-5 frame ring buffer
- Multiple curved panels at increasing radii
- Blur + color shift on older frames

**Performance:** High memory (5x frame buffers)

---

### 12. **Stereoscopic Depth Enhancement** ★★★
*True 3D from 2D art*

**Concept:** Render slightly different images to each eye based on depth map. Creates true stereoscopic depth - objects float at different distances.

**Why it's subtle:** Just adds natural depth perception. No flying objects.

**Technical:**
- Generate depth map
- Create L/R eye variations with disparity
- visionOS handles stereo automatically

**Performance:** 2x rendering (separate eye passes)

---

### 13. **Environment Color Bleeding** ★★★★
*(Mixed mode only)*

**Concept:** In progressive immersion, blend colors from real environment into virtual display. The art absorbs your room - different in every space, every time of day.

**Why it's subtle:** Art responds to context without showing the room explicitly.

**Technical:**
- Environment lighting probes (standard API)
- Extract dominant colors
- Blend into hue shift calculation

**Performance:** Probes are lightweight

---

## Effect Combinations (Maximum Trip)

| Combination | Result |
|-------------|--------|
| **Parallax + Panel Breathing** | The layered image breathes in 3D space |
| **Depth Z-Displacement + fBM** | Relief sculpture that flows organically |
| **Gaze Warping + Peripheral Aurora** | What you look at sharpens, edges shimmer |
| **Audio Haze + Spatial Orbs** | Music as weather + localized sound sources |
| **Head Trails + Temporal Echo** | Movement creates rainbow time-trails |

---

## Technical Resources

- [visionOS 26 Spatial Scenes](https://www.apple.com/newsroom/2025/06/visionos-26-introduces-powerful-new-spatial-experiences-for-apple-vision-pro/) - AI depth from photos
- [Apple Depth Pro](https://machinelearning.apple.com/research/depth-pro) - Monocular depth estimation (backup option)
- [RealityKit Geometry Modifiers](https://developer.apple.com/videos/play/wwdc2021/10075/) - Vertex displacement techniques
- [RealityKit Particles](https://developer.apple.com/documentation/RealityKit/simulating-particles-in-your-visionos-app) - For peripheral aurora
- [ARKit in visionOS](https://developer.apple.com/documentation/arkit/arkit-in-visionos) - Hand/eye tracking

---

## Implementation Priority

### Phase 1: Foundation
1. **Panel Breathing** - vertex displacement (FIRST TARGET)
2. **Depth Z-Displacement** - vertex shader + depth texture

### Phase 2: Atmosphere
3. **Peripheral Particles** - RealityKit particles

### Phase 3: True Depth
4. **visionOS 26 Spatial Scenes** - Apple's AI depth
5. **Parallax Layers** - multi-panel depth

### Phase 4: Future (if desired)
6. Interactive effects (gaze, hand)
7. Temporal effects
