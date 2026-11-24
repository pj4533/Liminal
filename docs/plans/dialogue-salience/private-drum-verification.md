# Private native drum verification — 23 November 2026

Keep the source packs, prepared bundle, builds, raw reports, and capture audio
on the Mac outside public Git. Continue from the [local handoff](../HANDOFF-2026-11-23-CODEX-LOCAL.md).
The initial local pair reproduced the historical landmark and drum-bus
failures. The repaired candidate at `3a97d07` passed the original strict
installed-drum criteria in all four captures and had no new targeted failures.
Both revisions used the same 100 source recordings. The final build and native
checks are recorded in the [acceptance ledger](acceptance-ledger.md).

Use the four original Slow Burn packs for fresh baseline and candidate verification.
The regenerated D122 corpus has a separate identity from the historical installed
cache.

## Prepared corpus and local evidence

`scripts/private-verification-assets.py prepare SOURCE OUTPUT` selects only the four
original breaks directories listed in its `PACKS` table, excluding stems and bonus
melodies. It requires the exact original counts 25/25/25/37, then the D122 eligibility
counts 20/23/25/32. RIFF parsing accepts PCM/IEEE float, including extensible formats;
selection requires 45–120 BPM, mono/stereo, 22050–96000 Hz and 64 beats within two
frames at the labeled BPM. No trimming, decoding, resampling or rewriting occurs.
Source and copied bytes must have identical SHA256. Canonical names handle Vol. 2's
space before BPM, the original BUBBA_KUSH `DRUM_BREA` typo and BISCOFF_BUTTER's
trailing exclamation mark. Each grid Entry includes the original frame count, rate,
channels, `frameCount / 64`, zero phase/support and actual byte hash.

Preparation selected **100 of 112 originals**. The local provenance records each
file's identity, volume and any exclusion reason. The regenerated grid SHA-256 is
`f04ed987acd0d693aa46b717fcac4a1ef6c2b07e3153d90dd41ebbba9ff0dbee`.

## Native run and evidence interpretation

`verify-private-drums.py setup` requires genuine baseline
`47a01fe267a3972241ed6918d031fffe55f26ed2` and installs the exact same validated
100-file bundle/grid into both checkouts, refusing existing installations. The
candidate's matrix harness is copied to the baseline to enforce identical required
cases. `prepare-baseline-compiler.py` makes its existing exact compiler expansions.
`prepare-baseline-capture.py` checks the historical harness's entire SHA256 and
applies only the reviewed `LIMINAL_CAPTURE_CODE_SIGNING_ALLOWED` override; its
entire output hash must equal the reviewed harness. The driver records the baseline adapter diff with the detailed local evidence. The public real-media preparation now
also invokes this exact signing adapter and requires its result in final gating.

`native` runs LofiTests, LofiRhythmTests and LofiStemChainTests serially in **both**
checkouts, with explicit macOS arm64 destination. It records actual test completion
coverage (disabled/skipped tests do not count) and independently verifies that each
built app contains the exact grid and all 100 byte-hashed original WAVs. Both
checkouts are attempted even when baseline tests fail. Native tests are independent
of public film preparation or speech availability. Install NumPy and SciPy for
the native phase's independent kick check. It uses the original WAVs to verify
strong, low-band-supported kick labels within 20 ms and checks mixed transients
for a nearby onset. The report retains observed counts for class recall, precision
and mixed-attack coverage. It requires complete logs for all 100 WAVs. The legacy
kick detector remains an arrangement compatibility check and a diagnostic reference.

`prepare` fetches one authentic public film cache for both checkouts. Each matrix
runs serial `ref,fast,same,transcribe`, private drums, strict criteria, with candidate
compared to baseline. A matrix still runs after native failures; candidate still
runs after baseline matrix failures. Full raw strict status and no-new-targeted
C-B8/C-B9/C-D failures remain separate observations. Missing real transcriptions
are **UNMET**, including a transcribe case skipped by the underlying harness.
Provision SpeechTranscriber separately on the Mac using the speech phase of the
[real-media harness](real-media-verification.md).

Run each phase serially with absolute paths to dedicated checkouts and a private
output directory outside Git. Run setup only once on a fresh pair of checkouts.
The prepare phase writes to `$PRIVATE_OUT/ArchiveFootage`. Pass
`--archive-dir PATH` consistently to every phase if reusing a dedicated public
verification corpus. Setup applies the historical baseline cache adapter.

```sh
python3 scripts/private-verification-assets.py prepare "$PRIVATE_SOURCE" "$PRIVATE_BUNDLE"
for phase in setup native prepare baseline after final; do
  python3 scripts/verify-private-drums.py "$phase" \
    --after "$AFTER" --baseline "$BASELINE" --out "$PRIVATE_OUT" --bundle "$PRIVATE_BUNDLE"
done
```

Use the exit status of each phase. The local summary at
`$PRIVATE_OUT/sanitized/summary.json` contains revision and corpus identities,
test coverage, matrix criteria and phase status. Detailed evidence stays under
`$PRIVATE_OUT/raw`. A verified result requires exactly one successful completion
of each required step, exact built-resource hashes, executed native tests and
complete paired matrix cases.

## Recorded kick attacks

The controlled drum fixture keeps its 20% rise limit. The installed test
continues to log the original 80 ms full-take ratio. The recorded-take gate
uses shared raw kick anchors and the 40–150 Hz envelopes before and after the
chain. The first supported raw trough bounds both the first audible crossing
and the −6 dB body crossing. The absolute timing error limits are the C-B2
scale of 5 ms median and 12 ms p90, using the same linear percentiles.

The comparison requires an early signal at least 6 dB above its own pre-hit
floor. It uses the 25 ms early body to test for smearing without letting a
later body peak change the gate. If the shared lobe remains unresolved, a
comparison of the first 25 ms to the first 80 ms records energy only.
The median and p90 energy-loss limits are 3 and 6 dB. This distinguishes
timing-qualified, energy-only and unresolved observations in each take.
At least half of the attempted corpus anchors need qualifying evidence, and
every take with confident kick anchors requires at least one measured result.
A sparse take with no confident anchors can use lower-confidence kick
candidates if the audio supports them. The native log records a take with
neither source of support explicitly.
