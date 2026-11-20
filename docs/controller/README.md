# Push controller integration — staged development

The `push3` branch adds an opt-in macOS TCP listener, protocol foundation and partial channel routing. Live channel mix/FX and automatic gates are installed on the paths listed under Stage 2 below. Manual voices, drum switching and stretched chops are unavailable. Lo-Fi bass/lead/mids controls remain disabled pending native isolated-wet performance qualification. It advertises granular capabilities and per-control enabled flags; `capabilities.performance_audio:false` and channel `ready:false` remain truthful until actual manual assets exist. All new gates/gains start at Auto/unity, effects bypassed.

## Connecting locally

Open Storage & Settings → Push controller. Enter this Mac's literal private IPv4 address and port (default 20808), then enable the listener. It starts disabled on every app launch; the initial address is loopback for local development. To change addresses, disable first. The controller makes the outbound TCP connection. No device installation or takeover is performed by Liminal.

Only RFC1918 private IPv4 and 127/8 loopback addresses are accepted for binding and peers. IPv6 and hostnames are intentionally unsupported in this stage. Do not add port forwarding, public binds, tunnels or proxies. The protocol has no authentication or encryption: any device on the selected trusted LAN can attempt to acquire the lease, so enable it only on a trusted network. Incoming network sandbox permission and a local-network usage description are included; platform permission prompts still apply.

One valid hello acquires the lease. Other clients receive `busy`. A 3-second handshake/inactivity timeout, EOF, listener disable or socket error releases it. Reconnect gets a new session and fresh state. It never restores settings or replays notes. Current native transport remains independent of connections.

## Implemented commands

`transport` invokes the existing engine's idempotent start/stop methods and preserves the existing video-ready gate. `snapshot` requests full state. `note_off`, `pad_off`, `all_notes_off`, and reset are safe identity/lifecycle boundaries; this stage cannot have native manual voices. Unknown pressure IDs succeed harmlessly. Supported parameter and mode commands apply independent routing controls; unsupported channels/modes, pad-window and drum actions reject `unavailable`. Onsets reject `not_playing` while stopped/preparing, `wrong_mode` in Auto, and `not_ready` until a manual adapter exists. No unsupported control receives a success acknowledgement.

All sixteen fixed channel records are present. Film is unavailable until actual cue-bank publication exists. Harmony pitch classes are semitone intervals relative to the published tonic. Ambient has no beat transport and reports BPM/beat 0. Original music preparation and playback run as before.

## Developer boundaries

[Protocol v1](protocol-v1.md) defines the intended full contract, including functionality not yet implemented. [Golden messages](fixtures/messages.ndjson) are public-safe wire examples, not evidence that their audio actions are available. Optional `capabilities` reports installed adapters; clients must also honor per-channel readiness and per-parameter enabled flags.

- `ControllerProtocol`: bounded byte framing, strict JSON envelopes, typed command validation and sequence replay cache. Unknown actions reject rather than throw an onset into the graph.
- `ControllerServer`: Network.framework serial queue, TCP_NODELAY, one lease, max four pre-handshake sockets, 256 queued commands, 256 KiB socket output, one command crossing MainActor at a time, full-state coalescing. A stalled peer is disconnected. Clients coalesce continuous edits to 60 Hz; the server bounds queued work and disconnects on overflow rather than silently dropping release/stop commands.
- `ControllerCoordinator`: MainActor owner attached to the existing single `GenerativeEngine`; publishes at 10 Hz and on commands. Identity-based release on stop, route recovery and disconnect must call the eventual native voice adapter here.
- `ControllerState`: channel/parameter identities and unity defaults, bounded onset identity registry, and atomic pending/active bank revision guard. The bank guard requires the actual current cue and transport; it never activates prepared-next data automatically.

New Swift files are included by the project's existing filesystem-synchronized Liminal and LiminalTests groups. Signing settings are unchanged. Network implementation/UI are macOS-only; pure wire and identity helpers are shared.

## Remaining native audio stages

1. Qualify the new `LofiRenderer.render`/`Phrase.isolatedWet` and `LofiBus` lanes with native captures and preparation profiling before enabling source controls; preserve original combined wet at defaults.
2. `LofiPlayback.PlayingPhrase`: publish the actual audible program (including repeated fallback), prepare bounded current/next manual bass/lead/pad caches from the original generator helpers, add identity-safe held voices, releases and pressure. Expose complete octave windows atomically.
3. `LayerStrip` now has automatic gates before every dry/send fan-out and additive user processing. Add separate manual voice pools reusing the actual evolving layer timbres. Never stop automatic evolution to implement manual mode.
4. `DialogueCueCoordinator.Built.played`, `DialogueDirector`, motif source metadata and `ArchiveVoice`: publish actual source/bank at cue activation, reject stale epochs, prepare pitch-preserving beat-stretched pads off-thread, quantize manual launches and separate actual-manual duck windows from suppressed automatic hits. Film/return gate pads need real routing.
5. `LofiDrumLibrary`/`LofiDrumTake`/`LofiPlayback`: separately prepared, phase-preserving dual performance drum players and safe bar-boundary selection, including synthetic fallback. No private drum assets enter the wire or repository.
6. Extend the installed partial mix/gate adapters only as new actions apply changes. Mode state must represent effective ramps; preserve overrides across stop/play and disconnect, reset them on app launch. Add native capture evidence for no automatic audio leakage and default PCM parity.

## Validation

Native Swift tests cover framing, validation, lease sequence replay, identity release, bank activation epochs and loopback connection ownership. They require Xcode/macOS and have not been executed from Linux. Run:

```sh
xcodebuild -scheme Liminal -destination 'platform=macOS' build
xcodebuild test -scheme Liminal -destination 'platform=macOS' -only-testing:LiminalTests
xcodebuild -scheme Liminal -destination 'platform=visionOS Simulator,name=Apple Vision Pro' build
```

Use installed simulator destinations. A placeholder `Secrets.swift` from the template is sufficient for no-generation tests. Follow the repository's Peekaboo workflow for native settings UI verification and terminate/relaunch the rebuilt app first. Follow `docs/mix-verification.md` before any serialized baseline/candidate audio captures. Parser checks are not native builds, test execution, audio measurements or hardware validation.

## Stage 2 routing (native qualification pending)

The graph now contains separate controller-owned automatic gates and live user strips. No command writes the three ArchiveVoice music-duck faders. Ambient gates sit before each layer's dry/reverb/delay fan-out (including the lead answer). Automatic scheduling and timbre updates continue behind these gates. Drum and ambient source gates ramp in 30 ms without stopping players or the conductor. Mode snapshots retain the prior effective mode during the ramp and publish `pending_mode` with the request and applied status. Channel `ready` stays false until actual manual voice assets exist.

Implemented partial capabilities are `channel_mix`, `channel_effects`, and `automatic_gates`; `performance_audio` and `manual_notes` remain false. Honor each parameter's `enabled`, and channel `mix_ready`/`mode_ready` in addition to active status. Mixer/FX work for Lo-Fi drums, chops and space; all eight ambient sources and ambient space have mixer/FX. Source gates work for drums and the eight ambient sources. Film remains unavailable without actual cue publication. Chops mode remains unavailable until automatic duck windows and manual playback are separated. Film and both return modes reject unavailable. Onsets still reject not_ready.

Eight stable controls apply after original processing: gain (exact mute/unity to +6 dB), 12 dB/oct low/high cuts with bypass crossfades, 1.5 kHz high shelf, compensated equal-power tanh blend up to 12 dB pre-drive, dual 0.75-beat dark echoes with fixed 0.32 feedback and <=0.35 feed, dark short room with <=0.30 feed, and stereo balance with unity center. Parameters use 30 ms AU ramps. Untouched filters/effects are bypassed, feeds zero, automatic gates and user gains unity. New nodes require native graph overhead and audio verification; no such measurement is claimed here. Echo tempo banks retire the previous feed instead of moving its delay read point. Default Ambient echo timing is 0.8333 s per beat because Ambient has no clock; Lo-Fi updates from actual audible phrase tempo.

Lo-Fi bass/lead/mids source controls remain disabled: `LofiBus.isolatedPreparationQualified` is deliberately false. The default renderer does no extra wet rendering. Explicit `prepareIsolatedWet:true` reuses the already-rendered score/instrument/send arrays to prepare lead, mids and bass wet lanes. Each has independent nonlinear feedback, wet tone, source-filtered sampled grain anchors, self-return replay, bounded output, carry and fallback. It does not subtract a residual from the original rack or claim sum equality. Legacy PCM is retained and selected at untouched auto/unity defaults. Once qualified, the bus queues all lanes on the existing origin, mirrors source gain/FX/gates to the attributable wet, then applies common space processing and the original duck fader. Independent control crossfades away from legacy wet in 30 ms. Late phrase fallback carries each source tail once; subsequent repeats use silence. No mode setter stops/reschedules a source or resets transport/seed.

Before changing qualification, run native Debug and Release preparation budgets (including existing 1.5 s test), current/next phrase memory, baseline/isolated captures, and sustained playback with no misses. The scheduler keeps the existing bounded queued phrase list and one prepared-next request; no mode-mask cache or extra whole-score render is added. Linux source checks and tree-sitter syntax checks are not native Swift type checking.

### Entry points for the next audio stages

- `GenerativeEngine.controllerStrips(_:)` returns the persistent per-channel strips. `ControllerChannelStrip.manualInput` is the manual voice input upstream of the same user FX/gain. The ambient lead's first strip is the primary manual destination; extra strips receive mirrored controller settings/gates, so automatic answers cannot leak. Original layer activation/pan/send owners remain unchanged. `automaticGate` is automatic-only. Manual pools must use original generator/timbre helpers and bounded off-thread caches.
- `GenerativeEngine.lofi.bus` exposes the Lo-Fi graph. `.strips[.bass/.lead/.mids/.drums/.chops/.lofiSpace]` holds persistent user strips. Manual lead/mids/bass must also feed their attributable space path as appropriate; do not put new automatic audio into legacy wet. `LofiRenderer.Phrase.isolatedWet` order is lead, mids, bass. `LofiPhraseBank.prepare(...isolatedCarry:)` receives source-owned tails, including repeated-fallback handling. Do not enable these controls until actual budget qualification.
- `LofiPlayback.PlayingPhrase` still owns actual audible score/take metadata. Publish that metadata for manual caches; do not infer it from the advancing request on repeated fallback. Player clock/origin and queued frames remain unchanged by controller operations.
- `ArchiveVoice.chopOutput` feeds the added chops strip after its existing owned cue fader. Automatic/manual chop source separation, suppression of automatic duck windows, actual played-bank publication and pitch-preserving stretching remain to implement in ArchiveVoice/DialogueDirector; no manual chop support is advertised.
- Drum performance selection needs its own phase-aligned dual players feeding `.strips[.drums].manualInput`; ordinary automatic drums remain advancing behind the existing gate. Current stage does not expose drum selection.
- `ControllerCoordinator.execute`, `snapshot`, and `GenerativeEngine.controllerMixReady/controllerModeReady` are the truthful capability seam. Install actual manual onset/release/pressure adapters there before enabling notes, pad banks or ready. Reset and disconnect must release voices with their original ownership, while retaining channel overrides on disconnect and stop/play.

Validation added: six `ControllerAudioRoutingTests` (native, not executed here) cover unity default, continuous player time through gates, common manual input/mute, duck-fader ownership, independent dry/wet exclusion, sampled grain exclusion, default wet parity and carry independence (some tests cover multiple assertions). Linux source contracts run with `python3 -m unittest discover -s scripts/tests -p 'test_controller_audio_contract.py' -v` (five checks). Required native builds, all native tests, captured PCM/peaks, latency, mix matrix, preparation profiling and hardware review remain unverified.
