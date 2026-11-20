# Objective distortion detection: research findings

Legend: [SRC] = stated by a source I retrieved (via web search snippets; paywalled PDFs not read in full). [JUDGMENT] = my inference, not sourced. [UNVERIFIED] = could not confirm.

## 1. Clipping, true peak, and lossy-codec overs

- Run-length clipping detection [SRC]: Sound Forge "Detecting and Marking Clipping" flags a region when N consecutive samples reach a threshold (Clip Length), and can use true peaks. https://cdn.borisfx.com/borisfx/Documentation/soundforge/2026/en/content/proonly/detect_clipping.htm . MATLAB File Exchange "Clipping Indicator" does the same (threshold + min consecutive count): https://www.mathworks.com/matlabcentral/fileexchange/28115-clipping-indicator
- Limit [SRC]: constant-run detection only catches hard clipping; soft clipping or clipping smeared by later filtering needs histogram/shape methods (USPTO 9426592 https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/9426592 ; Laguna & Lerch, AES Conv. 141, histogram + time-domain shape, f-measure 0.92: https://www.aes.org/e-lib/browse.cfm?elib=18486). [JUDGMENT] So also check amplitude histogram spikes near the ceiling, and flat-topped crests after limiter.
- True peak [SRC]: ITU-R BS.1770-4 Annex 2 estimates inter-sample peaks via 4x oversampling (48-tap polyphase, 4x12, Table 2, specified for 48 kHz). https://www.itu.int/rec/R-REC-BS.1770-4-201510-S/en . EBU R128: max true peak -1 dBTP for linear audio, meter per BS.1770/EBU Tech 3341, tolerance +/-0.3 dB. https://tech.ebu.ch/docs/r/r128v4_0.pdf , https://tech.ebu.ch/docs/tech/tech3341.pdf . Essentia tutorial: https://essentia.upf.edu/tutorial_audioproblems_truepeakdetector.html
- Lossy-encode overs [SRC]: iZotope "Avoid Artifacts with Clip-Free Compression in RX 7": peak increase is caused by quantization in the lossy encoder (not only inter-sample peaks); example true peaks rose 1.73 dB after MP3 from a -1 dBTP master; clipping happens when decoder rounds to 16-bit; ~0.5 dB headroom removes most audible clipping, ~1 dB is the traditional guidance. https://www.izotope.com/community/blog/avoid-artifacts-with-clip-free-compression-in-rx-7 . A third-party note quotes AES TD1008: overshoot increases as bitrate decreases; -1 dBTP ceiling reserves headroom for encoder overshoot (-0.5 dBTP is a floor for high-rate codec inputs). https://raw.githubusercontent.com/M-Igashi/baken/main/docs/true-peak-ceiling.md (secondary source).
- Apple [UNVERIFIED primary]: Apple Digital Masters PDF (https://apple.com/itunes/docs/apple-digital-masters.pdf) is a compressed PDF I could not read; the -1 dBTP/-1 dBFS figures for Apple come from third-party guides (e.g. https://www.sonarworks.com/soundid-reference/blog/learn/mastering-for-apple-digital-masters/ ). Apple's doc is reported to favor high-res/float masters so the encoder sees accurate peaks. Check the PDF locally (pdftotext) before quoting Apple.
- [JUDGMENT] For our 256k/160k AAC previews: measure true peak of the pre-encode WAV AND decode the m4a back and count samples at/over full scale and the decoded true peak. Lower bitrate (160k) = larger overshoot. A master ceiling near -1 dBTP leaves little margin at 160k; -1.5 dBTP (also suggested by some engineers for bright/transient masters, per the Apple-guide search results) is safer for the share clips.

## 2. THD, THD+N, IMD and measuring on program material

- SMPTE RP 120-2005 (IMD method): https://pub.smpte.org/doc/rp120/20050406-pub/rp0120-2005_stable2015.pdf . SMPTE/DIN: LF tone + HF tone at 4:1 (excites LF-driven modulation); ITU-R/CCIF: closely spaced HF tones (difference products), per NI reference https://www.ni.com/docs/en-US/bundle/labview-sound-and-vibration-toolkit/page/intermodulation-distortion-standards.html . B&K Audio Distortion Measurements https://www.bksv.com/media/doc/BO0385.pdf
- Audibility [SRC]: Tan, Moore, Zacharov (JAES 51(11), 2003, https://www.aes.org/e-lib/browse.cfm?elib=12197): hard/peak clipping had large effects on perceived quality; soft and center clipping small. Objective multitone metric DS predicts reasonably; 2004 follow-up (gammatone-filterbank metric, https://www.aes.org/e-lib/browse.cfm?elib=13034) correlates better. Aalborg thesis: clipping thresholds are much lower than 2nd/3rd order and nearly music-independent; THD/IMD poorly predict perception on complex signals. https://projekter.aau.dk/projekter/files/9852082/07gr1061_Thesis.pdf . B&K citing Moir: harmonic distortion below ~400 Hz is much harder to detect than above. Historic thresholds ~0.8-1.3% (sine tones) and 2-4% (piano IMD) per https://www.audioholics.com/human-hearing-distortion-audibility-part-3 (secondary, dated). "1% THD" is a rule of thumb, not a controlled threshold. Temme/Olive et al.: non-coherent distortion can predict audibility on some music (https://www.rtings.com/headphones/learn/research/distortion-audibility).
- Program-material methods (standard practice, not found as a single cited doc this run) [JUDGMENT, method well established]:
  1. Null/residual test: align stage input and output (cross-correlation delay), gain-match by least squares, subtract; residual RMS in dB relative to signal = nonlinear + linear error. Run on a quiet reference (stage at low level) vs hot level to isolate level-dependent nonlinearity. Residual spectrum shows harmonic vs inharmonic vs HF content.
  2. Harmonic tracking: for bass with known note schedule (our score gives fundamentals), measure energy at 2f, 3f, 4f... vs f in short windows; rising H2/H3 with level indicates saturation. Excess energy at non-integer multiples = IMD/aliasing.
  3. Sine-sweep (Farina) separates harmonic orders in time: https://ccrma.stanford.edu/realsimple/imp_meas/Sine_Sweep_Measurement_Weakly.html (applies to static test, not music).
  4. Multitone/DS-style metrics: Tan et al. above.
- Aliasing [SRC partial]: oversample -> nonlinear -> filter -> decimate mitigates aliasing (principle per patent search result; no FabFilter manual retrieved). [JUDGMENT] Detect by checking energy between harmonics / above the highest legitimate partial, or by rendering the stage at 2x/4x internal rate and nulling against 1x.

## 3. Crest factor, PLR, limiting, LF IMD

- PLR = true peak - integrated LUFS; Shepherd: akin to crest factor/DR meter in LUFS. https://productionadvice.co.uk/plr/ . Stereophile: popular-music PLR fell from ~16 dB (1982-84) to ~9 dB (2006-08): https://stereophile.com/content/winning-loudness-wars . Rule of thumb "PLR >= 12" is disputed, even by the sources that cite it. I found NO source with a numeric gain-reduction dB at which limiting becomes audible. [UNVERIFIED]
- LF IMD from limiting [SRC]: limiting loud bass causes pumping/modulation of higher content; fix is band-split (~400 Hz) limiting and recombination, and Bessel filtering reduces limiter IMD (har-bal limiter docs https://www.har-bal.com/har-bal-limiter-help/ ). Omnia manual: hard-limited bass stage generates IM in the following clipper; low-pass after heavy bass clipping reduces artifacts (https://www.manualslib.com/manual/690707/Omnia-One-Fm.html?page=38 ). [JUDGMENT] In our chain check master limiter/clipper GR correlated with bass note onsets (master-gr.csv) and HF modulation by bass.

## 4. Spectral techniques (mostly [JUDGMENT]; no source retrieved)

- Spectrogram splatter: broadband vertical streaks above ~10 kHz coincident with transients/low notes = clipping products. Compare HF (>10 kHz) band energy per frame, pre- vs post-stage.
- Residual spectral flatness (high = noise/impulse-like, as from hard clipping) and kurtosis of the residual or of the high-passed signal (impulsive clicks give high kurtosis).
- Crest factor per stem and per 50-400 ms window; flat-top detection by amplitude histogram.

## Suggested thresholds to adopt (flagged judgment unless cited)

| Check | Threshold | Basis |
|---|---|---|
| True peak (master) | <= -1 dBTP; <= -1.5 for share AAC clips | EBU R128 [SRC]; 1.5 is [JUDGMENT] |
| Runs of >=3 consecutive samples within 0.1 dB of peak | 0 on any stem/master | Sound Forge method [SRC]; N=3 [JUDGMENT] |
| Decoded AAC overs (samples >= 0 dBFS after decode) | 0 at 256k and 160k | iZotope [SRC] |
| Residual (hot vs reference) | report; investigate < -40 dB for bass (~1%) | 1% rule-of-thumb, weak [SRC secondary] |
| Limiter/clipper GR | report mean/p99/max, correlate with bass | [JUDGMENT] |
| PLR | track; flag big drop vs baseline | Shepherd/Katz [SRC], no hard number |
