# Stage 2 and 3 implementation, 23 November 2026

Work branch: `work/dialogue-salience-finish`. Implementation and synthetic verification are separate
from stage 4 real-media acceptance. No probe, mix, listening, device or latency targets are claimed met.

## Stage 2 decisions

- Late anchored recuts retain content in response and third roles, including a single content piece.
  Intro endings, returns and non-walk outro tags use content whenever available. Only the O0 in-order
  whole-line walk may use connective pieces.
- Spaced initialism tokens stay in one parent before letter-unit cutting. Complete spelling figures
  require every ordered unit on a uniform one- or two-sixteenth grid, followed by the whole word on
  the next beat. The fill searches later signature occurrences when its step-zero signature has no room.
- Follow the original plan's salience threshold 0.7 and up to four syllable units; remove the interrupted
  implementation's 0.85/three-unit restriction and lexicon-only restriction. Acoustic minimum-share,
  nucleus and clean-boundary constraints still apply. Initialisms retain exact letter/nucleus matching.
- Rank by interest tier and value; preferred length contributes to value rather than overriding it
  within a tier. An outro cannot count an optional, omitted whole word as a completed spell figure.
- `OK.` and `OK!` remain excluded initialisms. Dotted `U.F.O.` is recognized.
- Tightness tests and mix criteria are unchanged. Lower hit density from whole words remains the
  deliberate trade described in the plan; measurements are still required.

## Stage 3 decisions

`DialogueSalienceIndex` uses a mutex, coalesced utility-queue atomic JSON writes and an in-memory
initializer for tests. It retains scanned film spans and up to six non-overlapping ranked candidates
per 30-second neighborhood, interest at least 0.45. Old lexicon versions are dropped, including their
scanned spans, so future transcripts can repopulate them. Cue storage records both timely and late
transcripts outside the cache lock. Automation uses an isolated index.

The original catalog segment-start draw remains in place. Sound-only overrides use a deterministic
independent clip-ID/piece-index RNG, a 65% draw and interest-weighted selection among the best five
feasible unplayed candidates. Start placement accounts for decoder preroll, picture-rate sound delay,
film clamping and the complete line inside the actual sound decode's 32-second analysis window.
The actual cue plan is checked again after placement. Shown starts within 20 seconds are excluded.
Optional sound-only film boosts multiply recency weights by at most two; pinned/discovery eligibility
and the original RNG stream are preserved. Empty-index behavior is identical.

Background scanning is **off** (`scannerEnabled = false`); no scanner or speculative transcription
runs. Enabling or implementing it needs the plan's cue-latency/performance evidence and cancellation
policy first. Played-cue learning works independently of it.

The opt-in real-media probe now builds an isolated index from its transcripts and emits paired
`SALIENCE-FOOTAGE` 500-request simulations (catalog vs indexed), with salient/random counts and
per-film shares. The Python summary retains these records. Stage 4 must measure the planned doubling,
0.60 salient share, 0.25 random share and per-film half-baseline-share gates on the real cache.

## Verification limitations

The hosted runner lacks a developer identity. Apple verification passes `CODE_SIGNING_ALLOWED=NO`
only on CI command lines; project signing and app entitlements are unchanged. This verifies compilation
and synthetic tests, not signed distribution or device installation. A pre-existing bass-renderer
local/function name collision was fixed by qualifying `Self.cuePartials` after the first hosted build
reported it. The CI focused list includes the new footage salience and existing footage-weaver suites.

Local executable Python report regressions: `python3 scripts/test_dialogue_salience_report.py`, 8 passed.
`git diff --check` passed. Mac/visionOS compile and Swift test outcomes must be taken from the latest
hosted run; the implementation report records the run IDs rather than treating an in-flight run as green.
