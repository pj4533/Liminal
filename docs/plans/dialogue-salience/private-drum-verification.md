# Private native drum verification — 23 November 2026

This route prepares the user's four original Slow Burn packs for **fresh regenerated**
baseline/candidate verification. It does not reconstruct the historical installed cache
or establish historical mix equivalence. No app, planner, DSP or criteria are changed.
The public repository must never receive unencrypted samples, mixed private audio,
private build products or detailed private capture logs.

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

Actual local preparation succeeded: **112 originals, 100 eligible, 12 excluded**,
with per-file identity, eligibility reason and volume recorded inside encrypted
provenance. Grid SHA256:
`f04ed987acd0d693aa46b717fcac4a1ef6c2b07e3153d90dd41ebbba9ff0dbee`.
The bundle and all transport material are outside the public checkout, under
`/app/state/liminal-private-verification/` (directory mode 700):

- `bundle/`: private plaintext corpus and provenance; never upload.
- `key`: random 32-byte AES-256 key, mode 600; never print, commit or upload.
- `key.b64`: mode-600 stdin source for the ephemeral Actions secret; never print.
- `fixtures.enc`: authenticated ciphertext, 960450605 bytes, SHA256
  `7a77cc69f487e2fb33808085589fde56734d217050f9bf94276fd12067dc5913`.

The complete actual ciphertext was locally decrypted, all 100 WAV hashes and RIFF
metadata compared, and the grid hash compared. The temporary plaintext roundtrip
copy was removed. This proves transport/corpus preparation only, not native tests.

## Transport boundaries

`encrypt DIRECTORY OUTPUT --key-file KEY` streams an uncompressed tar directly
through AES-256-GCM. Every archive has a fresh 12-byte nonce. Magic/version and nonce
are authenticated additional data; the 16-byte GCM tag terminates the file. The key
must be a mode-600 regular file outside the archived directory. Existing output is
never overwritten, and links/special files in the input are rejected.

`decrypt INPUT NEW_DIRECTORY --key-file KEY` streams to a private staged tar and
validates the GCM tag **before** parsing/extracting it. Invalid headers, tampering,
wrong keys and truncation leave no extracted output. The staged tar is removed on
success/failure. Every member is validated before any extraction: regular files
only, no absolute paths, parent traversal, backslashes, duplicate names, symlinks,
hard links, devices or directories. Extracted files are mode 600 under mode-700
output. This authenticates ciphertext; it is not a secure-erasure claim.

## Review, then execute

No secret, release, asset or Actions execution is created by local preparation or by
pushing `verify/dialogue-private-20261123`. The parent first reviews this code and the
fixed ciphertext hash. After that review, the authorized execution flow is:

```sh
# The shell reads the already-created mode-600 stdin file; no key enters an argv.
gh secret set LIMINAL_PRIVATE_DRUMS_KEY_20261123 --repo pj4533/Liminal \
  < /app/state/liminal-private-verification/key.b64

# DRAFT only. Only encrypted bytes are attached. Do not publish this release.
gh release create private-drums-20261123 \
  /app/state/liminal-private-verification/fixtures.enc \
  --repo pj4533/Liminal --draft --target verify/dialogue-private-20261123 \
  --title 'Temporary encrypted private verification fixture' \
  --notes 'Authenticated ciphertext only. Temporary verification transport; never publish.'

# Substitute the reviewed commit, then push once to the narrowly scoped execute ref.
git push origin REVIEWED_COMMIT:refs/heads/verify/private-execute/20261123
```

The workflow uses only `contents: read`. The hosted read token cannot access the
unpublished draft: initial run `45226611308` failed at ciphertext fetch, before any
private corpus reached the runner. The authorized owner CLI captures the draft
asset's signed HTTPS redirect using its documented verbose HEAD response:

```sh
python3 scripts/private-ciphertext-download.py capture 783833664 \
  /app/state/liminal-private-verification/ciphertext-download-url
gh secret set LIMINAL_PRIVATE_DRUMS_URL_20261123 --repo pj4533/Liminal \
  < /app/state/liminal-private-verification/ciphertext-download-url
```

The capture command saves only a validated redirect, mode 600, and never logs HTTP
headers, credentials or the URL. Refresh it immediately before executing: only
`https://release-assets.githubusercontent.com` is allowed, without userinfo,
fragments or whitespace and with over 30 minutes until the signed `se` expiry.
The URL grants temporary access only to ciphertext and is scoped to the download
step's ephemeral secret. The downloader removes the secret from its environment,
rejects redirects, verifies the pinned SHA256 above before completing the output,
and emits only a fixed failure message. No owner credential enters Actions. The
AES secret remains separately scoped to key materialization, and the shell unsets
it before starting decrypt/verification subprocesses. No public release or broader
job permission is used. Delete both ephemeral secrets after evidence retrieval.

Only `verify/private-execute/**` pushes trigger this workflow; there is no PR trigger.
The review branch stays inert. This push route avoids a dependency on registering
a new workflow_dispatch file on the default branch. Dispatch remains available
when GitHub registers the workflow. Do not push the execute ref before review and
fixture provisioning. Execution uses the stable `private-drums-pj4533-liminal` concurrency group and does not cancel running jobs.

After evidence is retrieved, the parent removes the ephemeral Actions secret and
draft release/asset through the authorized cleanup flow, and records those actions.
Keep the local key private for decrypting the encrypted evidence until retention
and listening needs are resolved. Neither the key nor plaintext evidence belongs
in a public issue, release, artifact, report or commit.

## Native run and evidence interpretation

`verify-private-drums.py setup` requires genuine baseline
`47a01fe267a3972241ed6918d031fffe55f26ed2` and installs the exact same validated
100-file bundle/grid into both checkouts, refusing existing installations. The
candidate's matrix harness is copied to the baseline to enforce identical required
cases. `prepare-baseline-compiler.py` makes its existing exact compiler expansions.
`prepare-baseline-capture.py` checks the historical harness's entire SHA256 and
applies only the reviewed `LIMINAL_CAPTURE_CODE_SIGNING_ALLOWED` override; its
entire output hash must equal the reviewed harness. The raw baseline adapter diff
is encrypted with the detailed evidence. The public real-media preparation now
also invokes this exact signing adapter and requires its result in final gating.

`native` runs LofiTests, LofiRhythmTests and LofiStemChainTests serially in **both**
checkouts, with explicit macOS arm64 destination. It records actual test completion
coverage (disabled/skipped tests do not count) and independently verifies that each
built app contains the exact grid and all 100 byte-hashed original WAVs. Both
checkouts are attempted even when baseline tests fail. Native tests are independent
of public film preparation or speech availability.

`prepare` fetches one authentic public film cache for both checkouts. Each matrix
runs serial `ref,fast,same,transcribe`, private drums, strict criteria, with candidate
compared to baseline. A matrix still runs after native failures; candidate still
runs after baseline matrix failures. Full raw strict status and no-new-targeted
C-B8/C-B9/C-D failures remain separate observations. Missing real transcriptions
are **UNMET**, including a transcribe case skipped by the underlying harness.
The workflow does not provision/download a speech model or replace unavailable
transcription with a passing acoustic result.

Public upload is restricted to one allowlisted summary JSON: revision hashes,
counts, source hashes, native coverage, resource identities, per-case integrity,
criterion IDs/status and numeric values whose names occur in the trusted report
code. No raw manifest, transcript, source title, arbitrary error, log, WAV, app or
capture directory is uploaded. All detailed capture audio/logs/reports and exact
adapter diffs are encrypted before a separate ciphertext-only artifact upload.
Final gating also requires exactly one recorded successful completion of every adapter, native, media and matrix phase; missing/timeout/nonzero/duplicate completions remain UNMET even when passing report JSON already exists. Failures never enable a plaintext fallback upload. Relevant Liminal/xctest crash reports are collected only into encrypted raw evidence. An `always()` cleanup removes
runner bundle, key, build products, both installed source copies, sandboxed and unsandboxed `Liminal/OfflineAudio` capture caches, the stale capture configuration and targeted app/test crash reports; abrupt runner
loss additionally relies on hosted runner destruction. No Actions cache stores
private files.

Local tests cover byte preservation, RIFF metadata and exclusions, the known name
repairs, inventory rejection, GCM roundtrip/fresh nonce/tamper/wrong-key/truncation,
key permissions and archive boundaries, no overwrite, safe artifacts, truthful
transcription failure, post-report command failures/timeouts, targeted crash/cache cleanup and signed URL host/expiry/hash/error boundaries (22 tests). Native Apple execution remains pending: this environment
has no Xcode or Apple audio framework, and no remote run is implied by those tests.
