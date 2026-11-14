# Vibrance decisions

Decision log for the vibrance workstream. Plan: `docs/plans/vibrance.md`. Measurements: `docs/plans/vibrance-measurements.md`.

## D1. Fix the visionOS encoding with a `bgra8Unorm` view of the `_srgb` drawable

- **Why:** the shader writes gamma-encoded values into an `_srgb` attachment, which encodes them a second time.
  RealityKit needs an `_srgb` texture that contains the un-re-encoded bytes.
- **Rejected:** a plain `bgra8Unorm` DrawableQueue. RealityKit would sample it without a decode and still treat
  the values as linear, so the result would be the same lifted image.
- **Rejected:** `_srgb` source textures (linear-light shader math). Correct, but it changes how every effect looks
  relative to macOS and invalidates the tuned constants.
- **Fallback:** decode at the end of the shader behind a uniform flag (3 MAD).
- **Open:** not confirmed on device. The plan has a gray-card check that uses the existing passthrough and
  solid-color test paths. If they already match, this decision is void.

## D2. Bind real feedback on visionOS; `feedbackMix = 0` there until it is bound

- **Why:** texture 4 is never bound, so 30% black is mixed into every frame and visionOS has no trails.
- A second color attachment (no blit, vibrance kept out of the loop) is left to the GPU workstream.

## D3. Saturation-compensated RGB blends, not OKLab mixing

- `restoreChroma(mix(a, b, t), mix(chroma(a), chroma(b), t), maxGain)` after the hue blend, the ghost-tap loop
  and the feedback mix.
- **Why:** about 25 scalar ops per blend against two cube roots and two matrices per OKLab conversion. The target
  is a convex combination of input chroma, so feedback cannot run away (300 frames measured equal to 30).
- **Gain caps:** 2.0 for the hue blend, 1.5 for taps and feedback. Floor of 0.02 on measured chroma so gray noise
  is not amplified.

## D4. Hue stage: cap the luma-restore scale instead of clamping

- **Why:** scale-then-clamp turns saturated dark hues into pastels. Capping at `1 / max channel` keeps hue and
  saturation and gives up luminance instead, which is the trade the user asked for.

## D5. Bloom: saturate the glow ×1.5 and screen it

- **Why:** the clamped add blew 1.7% of pixels to pure white (25% in the worst frame). Screen rolls off with color.
- `bloomAmount` and `bloomRadius` unchanged. If bloom needs more saturation headroom, raise 1.5 toward 1.8 first.

## D6. Vibrance stage design

- Last stage, in gamma RGB: black-point pull, then chroma gain `1 + amount * (1 - sat)`, gated off below chroma
  0.02, then `gamutFit`.
- **Defaults:** `vibranceAmount` 0.30 oscillating ±0.12 on golden-ratio frequencies; `blackPoint` 0.015.
- **Why not a bigger black point:** 0.03 crushed 4.3% of pixels (43% on the darkest image).
- **Adaptive per-image factor** is specified (CPU, once per image) but deferred. The stage already self-limits per
  pixel, and the factor is not prototyped.
- Runs inside the macOS feedback loop. Accepted because the compounding is bounded and measured stable.

## D7. No existing effect amount is reduced

- Every uniform in `EffectsUniformsComputer` keeps its current value and range. All changes are to how colors
  are combined, plus the one added stage.

## D8. Acceptance uses saturation, chroma and clipping, not a colorfulness ceiling

- **Why:** the Hasler colorfulness metric rewards hue variety, and the unfixed macOS output is already at +23%.
  An upper bound of +25% would fail any real fix. Upper limits are placed on saturation mean (+35%), p90 (+20%)
  and per-image boost (+60%) instead.
- Checked by `scripts/vibrance-check.py`. Today's output fails it in both modes; the prototype passes.

## D9. Prototype lives outside the app shader

- `tools/VibranceHarness/proto_patch.py` patches a copy of `EffectsRenderer.metal`; `scripts/vibrance-proto.sh`
  runs it. The app shader is untouched in this workstream because the shader-optimisation workstream owns it
  for now.
