# Push controller integration — staged development

The `push3` branch adds an opt-in macOS TCP listener and protocol foundation. This is not the complete playable Push integration. The native performance audio adapters have not been installed: pads, manual mode, channel mix/FX, drum switching and stretched chops are unavailable. The listener does not alter the existing audio graph. It advertises `capabilities.performance_audio:false`, all channel controls disabled, and channel `ready:false`.

## Connecting locally

Open Storage & Settings → Push controller. Enter this Mac's literal private IPv4 address and port (default 20808), then enable the listener. It starts disabled on every app launch; the initial address is loopback for local development. To change addresses, disable first. The controller makes the outbound TCP connection. No device installation or takeover is performed by Liminal.

Only RFC1918 private IPv4 and 127/8 loopback addresses are accepted for binding and peers. IPv6 and hostnames are intentionally unsupported in this stage. Do not add port forwarding, public binds, tunnels or proxies. The protocol has no authentication or encryption: any device on the selected trusted LAN can attempt to acquire the lease, so enable it only on a trusted network. Incoming network sandbox permission and a local-network usage description are included; platform permission prompts still apply.

One valid hello acquires the lease. Other clients receive `busy`. A 3-second handshake/inactivity timeout, EOF, listener disable or socket error releases it. Reconnect gets a new session and fresh state. It never restores settings or replays notes. Current native transport remains independent of connections.

## Implemented commands

`transport` invokes the existing engine's idempotent start/stop methods and preserves the existing video-ready gate. `snapshot` requests full state. `note_off`, `pad_off`, `all_notes_off`, and reset are safe identity/lifecycle boundaries; this stage cannot have native manual voices. Unknown pressure IDs succeed harmlessly. Valid but unsupported mode, parameter, pad-window and drum actions reject `unavailable`. Onsets reject `not_playing` while stopped/preparing and `not_ready` while running. No unsupported control receives a success acknowledgement.

All sixteen fixed channel records are present. Film is unavailable until actual cue-bank publication exists. Harmony pitch classes are semitone intervals relative to the published tonic. Ambient has no beat transport and reports BPM/beat 0. Original music preparation and playback run as before.

## Developer boundaries

[Protocol v1](protocol-v1.md) defines the intended full contract, including functionality not yet implemented. [Golden messages](fixtures/messages.ndjson) are public-safe wire examples, not evidence that their audio actions are available. Optional `capabilities` reports installed adapters; clients must also honor per-channel readiness and per-parameter enabled flags.

- `ControllerProtocol`: bounded byte framing, strict JSON envelopes, typed command validation and sequence replay cache. Unknown actions reject rather than throw an onset into the graph.
- `ControllerServer`: Network.framework serial queue, TCP_NODELAY, one lease, max four pre-handshake sockets, 256 queued commands, 256 KiB socket output, one command crossing MainActor at a time, full-state coalescing. A stalled peer is disconnected. Clients coalesce continuous edits to 60 Hz; the server bounds queued work and disconnects on overflow rather than silently dropping release/stop commands.
- `ControllerCoordinator`: MainActor owner attached to the existing single `GenerativeEngine`; publishes at 10 Hz and on commands. Identity-based release on stop, route recovery and disconnect must call the eventual native voice adapter here.
- `ControllerState`: channel/parameter identities and unity defaults, bounded onset identity registry, and atomic pending/active bank revision guard. The bank guard requires the actual current cue and transport; it never activates prepared-next data automatically.

New Swift files are included by the project's existing filesystem-synchronized Liminal and LiminalTests groups. Signing settings are unchanged. Network implementation/UI are macOS-only; pure wire and identity helpers are shared.

## Remaining native audio stages

1. `LofiRenderer.render`/`Tail`/`Phrase` and `LofiBus`: preserve original combined wet at defaults; prepare source-isolated nonlinear wet with separate carries and phase-aligned always-running players. Add independent source gates and performance strips without touching dialogue-owned duck faders. Native preparation profiling is an acceptance gate before advertising ready.
2. `LofiPlayback.PlayingPhrase`: publish the actual audible program (including repeated fallback), prepare bounded current/next manual bass/lead/pad caches from the original generator helpers, add identity-safe held voices, releases and pressure. Expose complete octave windows atomically.
3. `LayerStrip`, `MusicConductor` and all eight layers: automatic source gates before every dry/send fan-out; separate manual voice pools reusing the actual evolving layer timbres. Add live channel effects after generation-owned processing. Never stop automatic evolution to implement manual mode.
4. `DialogueCueCoordinator.Built.played`, `DialogueDirector`, motif source metadata and `ArchiveVoice`: publish actual source/bank at cue activation, reject stale epochs, prepare pitch-preserving beat-stretched pads off-thread, quantize manual launches and separate actual-manual duck windows from suppressed automatic hits. Film/return gate pads need real routing.
5. `LofiDrumLibrary`/`LofiDrumTake`/`LofiPlayback`: separately prepared, phase-preserving dual performance drum players and safe bar-boundary selection, including synthetic fallback. No private drum assets enter the wire or repository.
6. Replace unavailable acknowledgements only as these adapters apply changes. Mode state must represent effective ramps; preserve overrides across stop/play and disconnect, reset them on app launch. Add native capture evidence for no automatic audio leakage and default PCM parity.

## Validation

Native Swift tests cover framing, validation, lease sequence replay, identity release, bank activation epochs and loopback connection ownership. They require Xcode/macOS and have not been executed from Linux. Run:

```sh
xcodebuild -scheme Liminal -destination 'platform=macOS' build
xcodebuild test -scheme Liminal -destination 'platform=macOS' -only-testing:LiminalTests
xcodebuild -scheme Liminal -destination 'platform=visionOS Simulator,name=Apple Vision Pro' build
```

Use installed simulator destinations. A placeholder `Secrets.swift` from the template is sufficient for no-generation tests. Follow the repository's Peekaboo workflow for native settings UI verification and terminate/relaunch the rebuilt app first. Follow `docs/mix-verification.md` before any serialized baseline/candidate audio captures. Parser checks are not native builds, test execution, audio measurements or hardware validation.
