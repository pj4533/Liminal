# Mix distortion measurements (2026-11-20)

Measurement summary behind [D121](../../decisions/music.md). Reference capture: seed 2077, 72 BPM, 32 bars, private drums, film reel. Plan: [mix-distortion](../../plans/mix-distortion.md). Tool: `scripts/distortion-report.py` ([how to read it](../../mix-verification.md#distortion-and-headroom)). Captures themselves are not committed.

Implementation notes from the run (rows are net drive in dB after the -2 dB staging, clip threshold in dBFS; "gain" in the sweep rows is the `masterInputGainDb` hook value):

# Implementation notes: docs/plans/mix-distortion.md

Base 6c73d06. Captures in share/distortion/<name> (dcap.sh; DD=dd-dist).

## Step 1 baseline
- mix-report --strict on cap-readme vs final-main: 26 pass, 0 fail, 4 warn, 2 skipped -> no pre-existing failures.
- cap-readme vs S3/S4 null: music stems -240 dB, but dialogue-chops -105, footage -92.4, lofi -115.6 (cap-readme built
  in another DerivedData). S3 vs S4: all -240. So G7 uses a fresh S0 from the same build dir.

## Sweep (hooks only, source at 6c73d06 + python-only edits)
row  gain clip  bursts>.5/>1  clipMax  G2 reduce  1k/2k reduce   clip1-4k  c+l max  LUFS
S4   4    -3    3/0           0.79     -44.0     -35.0/-30.3    -23.6     1.42     -13.9   (G2 fail)
S3   4.5  -3    8/1           1.06     -42.8     -32.7/-28.7    -20.9     1.84     -13.5
S2   5    -3    18/3          1.36     -41.0     -32.0/-28.6    -19.6     2.24     -13.1
S1   5.5  -3    25/8          1.68     -40.0     -31.3/-28.5    -19.1     2.64     -12.7
S6   4    -2    0/0           0.29     -51.5     -44.9/-40.0    n/a       1.42     -14.0   (G1-G4 pass)
S5   4.5  -2    0/0           0.47     -48.3     -43.0/-37.8    -24.3(fail) 1.84   -13.5
S0   none (6 / -3): reproduces cap-readme sample for sample (master -240 dB).
Selected S6 (+2 net = 2 - lofiStagingDB, clip -2). C1 (no hooks, commit 3618652) master == S6 at -240 dB.
C1 mix-report strict: no failures (C-M1 -13.91, C-M3 12.71, C-M5 14.01 inside revised bounds).
Run-to-run: film-soundtrack decode differs ~-135 dB between runs; footage -92..-95, chops -105, lofi -115.6.
  G7 split: music stems <= -120, film-derived <= -90.
Drum tape null (C1): rounding 2.35 dB, residual -27.5 dB, 1-4 kHz -20.8 dB re band -> above -30: follow-up, no change.

## Bass 2.2
Audit (--bass-samples) offExact 120-450 Hz re band: upright 28-1 -0.6, 28-2 -0.8, 31-1 -5.7, 31-2 -2.4, 33-1 -5.6,
33-2 -6.5, 36-1 -1.2, 36-2 -7.2, 39-1 -5.2, 39-2 -3.3. Partials stretched +15..+50 cents (stiff string).
U0 (bassTone=upright, HEAD 3618652): upright inharmonic median -20.6 (max -15.4), 58 notes.
U1 selection {31:1,33:2,36:2,39:1}: -20.8 (max -16.6). C-B3 1.02 / -11.75 ok.
U2 selection + bodyUnderSubDB 15.5 (plan maximum): -23.4 (max -18.9); C-B3 0.82 / -14.02.
=> G6 upright (-28) not reachable inside plan 2.2; per step 4 stop and report; bass source reverted (no change shipped).

## Final
Commits: 3618652 (master+tools), e468c17 (docs+preview), 6105000 (README link), 010ee17 (maps).
Matrix share/distortion/matrix: strict failures = pre-existing (long C-B8; fast C-B8 C-D6 C-D9; same C-B6).
  new warn nofilm C-M7 glue mean 0.29 < 0.30; same C-M5 14.50 on bound.
Gate tables: distortion/final-S0.txt, distortion/final-C1.txt.
A/B: dist-before (cap-readme), dist-after (C1), both with the -1 dB encode trim.
