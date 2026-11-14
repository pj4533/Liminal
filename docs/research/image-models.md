# Image model evaluation (2026-11-14)

Evaluated with the project's Gemini API key (AI Studio, v1beta). Test images live in the session scratchpad (`images-eval/models/<model>/<n>.png`), not in the repo.

## Models visible to this key (image output, generateContent)
`gemini-2.5-flash-image` (current), `gemini-3-pro-image` (+ `-preview`, alias `nano-banana-pro-preview`), `gemini-3.1-flash-image` (+ `-preview`, "Nano Banana 2"), `gemini-3.1-flash-lite-image`, `gemini-nano-banana-2.1`. No Imagen (`predict`) models are exposed to this key.

## Test prompts
a) photorealistic macro chameleon on iridescent glass orchid, teal/magenta
b) hyperreal cinematic lighthouse made of stacked koi, liquid mercury ocean, golden hour
c) infrared film carousel melting into a forest, saturated red foliage

All requested 16:9 at default (1K) size.

## Results (avg latency, output px, scores 1-5 averaged over 3 prompts, by eye)
| Model | Latency | Pixels (16:9) | Photoreal | Recognizable | Color | Surreal | Notes |
|---|---|---|---|---|---|---|---|
| gemini-2.5-flash-image (control) | ~6s | 1344x768 | 3 | 4 | 3 | 3 | Soft, CG/illustrated look; lighthouse scene had floating koi clutter; carousel was a plain carousel in red trees (didn't melt) |
| gemini-3-pro-image | ~16s | 1376x768 | 4 | 5 | 4 | 4 | Best prompt fidelity and mercury-like metallic water; photo-like; slowest/most expensive |
| gemini-3.1-flash-image | ~9s | 1376x768 | 5 | 5 | 5 | 3 | Most photographic (bokeh, lens feel, wet rock); strong color; follows "surreal" conservatively (mercury ocean came out as ordinary sunset water) |
| gemini-3.1-flash-lite-image | ~3.7s | 1376x768 | 4 | 4 | 4 | 3 | Very fast and cheap; good, slightly more stylized; lighthouse had mercury-ish water |
| gemini-nano-banana-2.1 | ~15s | 1376x768 | 4 | 5 | 4 | 5 | Best "melting" carousel, very surreal; slightly more painterly/HDR |

## Pricing (third-party reported; verify on Google's pricing page)
- gemini-3.1-flash-image: ~$0.067 (1K), ~$0.10 (2K), ~$0.15 (4K); batch ~50% off.
- gemini-3-pro-image: ~$0.134 (1K/2K), ~$0.24 (4K).
- gemini-2.5-flash-image: ~$0.039 per image.
- lite / nano-banana-2.1: not confirmed.

## Recommendation
Primary: **`gemini-3.1-flash-image`** (best photorealism and color, ~9s, roughly half the price of Pro). Optionally mix in `gemini-nano-banana-2.1` or `gemini-3-pro-image` for a share of generations to get more surreal output; use `gemini-3.1-flash-lite-image` as a cheap/fast fallback. Strengthen surrealism through the prompt text rather than model choice.

## Exact request that worked (all models)
```
POST https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent
Header: x-goog-api-key: <key>
{
  "contents": [{"parts": [{"text": "<prompt>"}]}],
  "generationConfig": {
    "responseModalities": ["IMAGE"],
    "imageConfig": {"aspectRatio": "16:9"}
  }
}
```
Response: `candidates[0].content.parts[].inlineData.{mimeType,data}` (base64; JPEG bytes in practice, even if saved as .png). Verified also with `"imageSize": "2K"` plus `"aspectRatio": "21:9"` on gemini-3.1-flash-image (returned 3168x1344, ~16s). imageSize must be uppercase (`1K`, `2K`, `4K`; 3.1 flash also has `512`). Note 16:9 yields 1376x768 (not exact 16:9) for 3.x models.

## Caveats
- Output is JPEG data; the app must not assume PNG.
- Latency 4-16s per image at 1K; 2K adds time. No rate-limit errors hit in 18 sequential calls; paid-tier limits not probed.
- Models are subject to safety blocks; handle responses with no inlineData (treat as failure, retry with a different prompt).
- Non-Google providers: for photoreal-surreal imagery, Flux 1.1 Pro / Flux Kontext (Black Forest Labs), Midjourney v7 (no official API), and OpenAI gpt-image are competitive, but none is clearly better than Gemini 3.x for this use; not worth a new key/provider. Not tested.
