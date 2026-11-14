# Music decisions log

Format: decision / why / alternatives.

## D1. Offline harness drives the real GenerativeEngine through a simulated clock
- What: `GenerativeEngine.schedule(after:)` replaces direct `Timer`s; `OfflineClock` replaces timers in offline renders. Harness lives in the app target (`OfflineRender.swift`) so the test target needs no AudioKit linkage.
- Why: lets a 5-minute piece render in seconds using the exact production code path, so analysis reflects reality.
- Alternatives: pumping RunLoop in real time (slow); re-implementing the generator inside the test (drifts from production); AudioKit `renderToFile` alone (cannot advance Timers).
- Note: unseeded randomness, so numbers vary run to run; compare trends, not decimals.

## D2. Analysis uses numpy/scipy only
- Why: no extra deps; chord detection = triad/sus/power-chord chroma templates over 2 s windows; onsets = log-spectral flux peaks; novelty = cosine distance of per-minute mean log-spectrum / chroma.
