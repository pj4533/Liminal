# Gain staging / headroom research (for Liminal Lo-Fi mix)

Confidence: sources below were retrieved via web search summaries; the AES TD1008 PDF itself and Apple Digital Masters docs were NOT read directly. Items marked [unsourced] are background knowledge.

## 1. Nominal levels and why float still distorts
- -18 dBFS RMS ~ 0 VU (Avid, SOS, Vintage King say RMS ~-18, peaks ~-12 dBFS per track). Guideline, not law; purpose is headroom and keeping level-dependent plugins in their calibrated range.
  - https://www.avid.com/resource-center/gain-staging-guide
  - https://www.soundonsound.com/sound-advice/q-should-gain-stage-6dbfs-or-18dbfs
  - https://vintageking.com/blog/2018/03/gain-staging/
  - https://www.izotope.com/en/learn/audio-gain.html
- Float pipelines cannot clip between linear stages, but saturators/tanh drives/compressors/limiters are level-dependent: small input changes drastically change saturation amount (Nail The Mix, https://nailthemix.com/gain-staging). So the input level into each nonlinear stage is what matters, not the float headroom.

## 2. Bass as first victim; harmonic vs IMD
- Harmonic distortion adds integer multiples (110 Hz -> 220/330/440); IMD adds sum/difference products between simultaneous tones, is dissonant and far more objectionable; both come from the same nonlinearity (https://www.audioholics.com/loudspeaker-design/audibility-of-distortion-at-bass/intermodulation-distortion, https://www.prosoundweb.com/the-audio-expert-audio-fidelity-measurements-and-myths-part-1/3/).
- Sub saturation adds harmonics that help the fundamental be perceived, but too much changes timbre/removes weight (https://www.sageaudio.com/articles/top-5-mastering-tricks-for-amazing-sub-bass, https://www.musicradar.com/tuition/tech/how-to-process-bass-using-saturation-609229). Bass IS less audible as pure harmonic distortion (https://purifi-audio.com/blog/tech-notes-1/low-frequency-harmonic-distortion-is-almost-inaudible-so-whats-the-point-of-low-distortion-drivers-4, manufacturer, secondary) but the upper-harmonic and IMD products with the mids are what is heard.
- Bass dominates detectors: low-frequency energy triggers compressors/limiters; fast attack kinks LF waveforms (Mike Senior, SOS https://www.soundonsound.com/sound-advice/q-why-does-my-kick-lose-weight-when-compress-drum-bus; Splice https://splice.com/blog/?p=2629). Mitigation: sidechain HPF on detector, multiband/low-split limiting, mono sub, slower release (https://www.masteringthemix.com/blogs/learn/how-to-control-low-end-distortion, https://www.masteringthemix.com/blogs/learn/why-is-my-mix-distorting-find-out-and-fix-it-fast).
- Not found in sources: a numeric "safe drive" for sub tanh. [unsourced] Practical test: measure THD/IMD of the bass stem alone with a swept or two-tone test and compare harmonic levels vs level; keep 2nd/3rd harmonics intentional and no non-harmonic (IMD) products.

## 3. Master loudness and true peak
- Spotify: normalizes to -14 LUFS (ITU 1770); for masters louder than -14 LUFS keep true peak below -2 dBTP, otherwise -1 dBTP max; Spotify's limiter engages at -1 dB sample (https://support.spotify.com/ca-en/artists/article/loudness-normalization/). Premium levels: Loud -11, Normal -14, Quiet -19.
- AES TD1008 (via secondary quotes): max true peak not above -1 dBTP at the codec input of lossy streams; 256 kbps coders may work with -0.5 dBTP, lower bitrates need a threshold below -1 dBTP (https://raw.githubusercontent.com/M-Igashi/baken/main/docs/true-peak-ceiling.md). EBU R128 peak -1 dBTP per same page. BS.1770 true-peak meter error typically <0.6 dB.
- Limiter gain reduction: iZotope says an end-of-chain limiter typically applies no more than ~2 dB GR for commercial loudness (https://www.izotope.com/en/learn/an-introduction-to-limiters-and-how-to-use-them); pushing harder gives gritty/fizzy distortion (https://productionadvice.co.uk/brickwall-limiters/); Sonnox manual: more GR = more distortion artefacts (https://www.fullcompass.com/common/files/28618-SonnoxOxfordLimiterUserGuide.pdf).
- Lo-fi LUFS norms: no source found. [unsourced] lo-fi masters commonly -12 to -16 LUFS integrated; -14 is a safe target and avoids platform limiter engagement.

## 4. Lossy encoding
- Encoding raises peaks: iZotope reports +1.73 dB true-peak rise after MP3, pathological cases up to ~10 dB (https://www.izotope.com/community/blog/avoid-artifacts-with-clip-free-compression-in-rx-7). Overshoot grows as bitrate falls (TD1008 7B). 
- Implication: AAC 160k/256k m4a clips (what the user heard) can clip at the DAC if the source is above ~-1 dBTP, and audible "distortion" may come from codec overshoot/clipping of a master near 0 dBTP, especially with bass-heavy dense material. Test by decoding the m4a and measuring peak/true-peak and clipped sample count vs the source WAV.

## Numeric guidance summary
- Per-stem peaks ~-12 dBFS / RMS ~-18 dBFS as reference; check level into each nonlinear stage.
- Master ceiling -1 dBTP (use -1.5 to -2 dBTP if the master is louder than -14 LUFS or for 128-160k AAC); integrated ~-14 LUFS.
- Limiter GR typical <= 2-3 dB average, short peaks to ~4-6 dB; sustained >6 dB is a distortion risk.
- Detect: decode encoded file and compare true peak/clip counts; THD/IMD on solo bass; limiter GR trace correlated with bass peaks.
