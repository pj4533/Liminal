# Mix distortion research

Research done on 2026-11-20 after listening to the shared Lo-Fi clips and hearing distortion in the mix and the bass. The outcome is [D121](../../../decisions/music.md); the plan is [mix-distortion](../../../plans/mix-distortion.md).

| Doc | Contents |
|-----|----------|
| [detection.md](detection.md) | How engineers detect distortion without trusting the ear: clip detection, true peak, null tests, harmonic and inharmonic content, encode overs |
| [gain-staging.md](gain-staging.md) | Nominal levels, headroom, loudness targets and where a chain should leave margin |
| [measurements.md](measurements.md) | What the reference capture measured before and after, the drive sweep, bass and drum tape results |

Tool: `scripts/distortion-report.py`; gates in the `distortion` block of `scripts/mix-criteria.json`.
