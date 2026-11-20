# Liminal Controller protocol v1 — implementation contract

Design baseline: Liminal 25592874bc614e1b481f68ff3651e2fac5c728ad. This specification is a target for both implementations, not a claim that any endpoint currently exists. No credentials, private addresses, drum assets or footage are part of the protocol/repository.

## Transport and ownership

Persistent outbound Python 3.10 TCP connection from Push to the configured Mac address and port 20808. Server uses Network.framework, macOS only in v1. Set TCP_NODELAY at both ends. No HTTP, audio streaming, SSH command dispatch, arbitrary file access, or external service. User-configured private LAN interface; refuse wildcard/public-interface configuration and public remote addresses. Loopback is valid for development. Do not expose the Drift gateway. Manual host/port configuration is sufficient; Bonjour is optional later. Configure the Liminal listener in app settings; controller disconnected at launch does not alter music. Add required sandbox incoming-network entitlement and local-network usage description if needed; retain signing settings.

UTF-8 newline-delimited JSON objects, maximum 65536 bytes INCLUDING newline per frame; incremental parser handles split UTF-8 and multiple frames per read; maximum buffered unframed bytes 65536; reject invalid UTF-8/JSON, non-object, non-finite numeric values and nesting beyond 12. Each frame has integer `v:1` and string `type`. Unknown version closes with error; unknown action gives negative acknowledgement. Integers represented below as string IDs are opaque decimal/UUID strings (avoid UInt64 precision loss).

One active controller lease. First valid hello obtains it; a second client gets `busy` and closes, never silently steals. Handshake deadline 3 seconds. Each connection gets a random `session` ID, each app launch a distinct `server_id`. Commands require matching session. Monotonic command `seq` starts at 1. Duplicate most recent sequences replay cached acknowledgements (last 256), never replay an onset. Older evicted sequences reject `stale_seq`. State snapshots have monotonic `revision`; full snapshots can supersede intermediate updates.

Client sends ping every 1 second; server replies pong; 3 seconds without valid incoming frame ends lease. EOF/write failure also releases it. On disconnect release all controller-held voices with their normal bounded release, cancel its pending manual launches, retain current mix and channel modes, keep Liminal's transport and automatic preparation running. In manual mode silence remains silence; disconnect must not unexpectedly re-enable music. Reconnect receives state, does not send cached settings or replay queued notes. App restart resets controller mix/FX overrides and every mode to auto. Stop/Play within the same app process retains overrides. `reset` explicitly restores defaults. Notes while transport is stopped reject `not_playing`; Play alone follows normal app startup/video gate.

Server connection queue parses/validates only, then sends typed commands to MainActor/controller coordinator; conductor mutations use its existing inbox/queue. Never do audio rendering, sample decoding, disk, network or JSON work in a render callback. Bounded queue 256 commands; coalesce continuous parameter edits by channel/parameter before sending (max 60 Hz). Never drop note-off/all-notes-off/stop to preserve a knob edit. On unresolvable queue overflow close lease and release notes. State max 10 Hz plus immediate acknowledgement and important bank/mode/transport transitions; socket output max 256 KiB, replace stale pending state, close stalled peer rather than grow memory.

## Handshake and messages

Client:
```json
{"v":1,"type":"hello","client":"liminal-controller","client_version":"0.1.0"}
```
Server:
```json
{"v":1,"type":"welcome","session":"uuid","server_id":"uuid","heartbeat_ms":1000,"max_frame_bytes":65536}
```
Server then sends a full `state` object. Heartbeat:
```json
{"v":1,"type":"ping","nonce":42}
{"v":1,"type":"pong","nonce":42}
```
Commands all use this envelope:
```json
{"v":1,"type":"command","session":"uuid","seq":1,"action":"parameter","channel":"lofi.bass","parameter":"gain","value":0.5}
```
Response:
```json
{"v":1,"type":"ack","seq":1,"ok":true,"revision":12}
```
Failure adds `error` (stable code), optional short human `message`. `ok:true` means accepted; asynchronous work adds `status:"pending"` and a `request_id`. State carries pending request and final applied/failed status. Success must not imply inaudible scheduling/preparation has completed. Error codes: bad_message, unsupported_version, busy, stale_session, stale_seq, invalid_channel, inactive_channel, invalid_parameter, out_of_range, wrong_mode, not_playing, stale_bank, stale_instrument, not_ready, unavailable, overloaded, preparation_failed.

## Commands

| action | Additional fields | Meaning |
| --- | --- | --- |
| `transport` | `state:"playing"` or `"stopped"` | Idempotent app start/stop, never a client-side toggle. |
| `mode` | `channel`, `mode:"auto"` or `"manual"` | Ramp that channel's auto source gate in 30 ms; preserve phase, preparation, score, RNG, instrument and bank evolution. |
| `parameter` | `channel`, `parameter`, `value` | Finite normalized 0...1; acknowledged applied canonical value. |
| `pad_window` | `channel`, `base_midi` 0...127 | Request complete melodic 8x8 scale window; prepare unique pitches off-thread, acknowledge pending, publish new ready instrument_revision atomically. Old window remains usable until ready. Refuse windows exceeding MIDI bounds. |
| `note_on` | `channel`, `note_id` string <=64 chars, `midi` 0...127 integer, `velocity` 1...127, `instrument_revision` integer | Immediate melodic/texture onset in manual mode. Onset identity is connection + note_id; duplicate held ID rejects. |
| `pressure` | `note_id`, `value` 0...1 | Bounded amplitude modulation of captured onset; never retarget another channel/program. Unknown ID is harmless success. |
| `note_off` | `note_id` | Releases the captured onset regardless of currently selected channel, octave, scale, mode, instrument or bank. Unknown ID is harmless success. |
| `pad_on` | `channel`, `note_id`, `pad` 0...63, `velocity`, `bank_revision` integer | Trigger a prepared sample/loop/return pad. Server knows mapping. |
| `pad_off` | `note_id` | Same identity semantics as note_off; see pad mode below. |
| `all_notes_off` | optional `channel` | Release manual held voices, cancel manual pending onsets; preserve automatic playback. |
| `drum_select` | `choice_id` string | Select prepared drum choice at next safe bar boundary; auto or manual allowed, does not itself unmute manual channel. |
| `drum_next` | none | Next distinct prepared candidate (fallback generated drums supported), same boundary behavior. |
| `reset` | `scope:"channel"`, `channel`, or `scope:"all"` | Release manual voices for affected channels, reset overrides and auto mode with ramp, preserve transport. |
| `snapshot` | none | Ask for full state. |

Changing auto/manual closes/releases the previous manual voices on return to auto (normal release capped at 0.85 s), ramps automatic signal; no transport stop, queue reset or new RNG seed. Automatic mode rejects new manual notes. Original effect tails may finish briefly; after defined transition/tail interval no new automatic source may remain audible. Mode completion state must reflect actual effective gate, not just request. Selection changes on Push never release notes; hardware disconnection does.

`note_on` exact midi mapping uses current scale, but the server plays that explicit MIDI pitch, never silently quantizes it. `pad_window` changes are connection-owned and preserve held notes. Controller waits for published ready base_midi before remapping pads. `instrument_revision` prevents stale UI presses after a new program; existing notes retain the program captured at onset. The canonical melodic layout follows Stillwater: row 0 is the bottom, column 0 the left, one scale degree per column and three per row; duplicate pitches are intentional. `harmony.root_midi` is always `60 + tonic`. Default `octave_offset` is -1 for bass and 0 for other melodic/texture channels. `base_midi = root_midi - 24 + 12 * octave_offset` is the actual bottom-left tonic, not a register to snap to another tonic. For scale intervals `I` of length `N`, use `d = column + 3 * row`, then `midi = base_midi + 12 * floor(d / N) + I[d mod N]`. The complete window covers degrees 0...28 (64 pads, intentional duplicates), four octaves for a seven-note scale. This is Stillwater's `-14 + 7 * octave_offset + column + 3 * row` generalized to `-2*N + N*octave_offset + column + 3*row` for scales with other degree counts: the bottom-left remains a tonic two octaves below the root. Use mathematical floor division if computing the equivalent negative degrees.

`pad_window.base_midi` must be an exact tonic MIDI value for the current harmony, and every pitch in the complete window must fit 0...127; otherwise reject `out_of_range`. Never clamp or wrap notes. The server publishes canonical `base_midi`, `octave_offset`, and `root_midi` per channel. `pending_window` carries request ID, target base and preparing/applied/failed status; the old ready window remains usable until the whole new window is prepared. An instrument change invalidates readiness until its actual complete PCM bank is present. `instrument_revision` changes with program/harmony/window changes; held notes retain their captured program. Controller remembers note_id-to-original-channel bindings. Disconnect releases onsets and returns connection-owned windows to defaults, while retaining mix and channel modes.

## State schema

```json
{"v":1,"type":"state","session":"uuid","revision":12,"transport":{"state":"playing","ready":true,"music_mode":"lofi","bpm":72.0,"beat":23.1,"take_index":0,"transport_revision":4},"harmony":{"root_midi":62,"tonic":2,"scale_name":"Dorian","pitch_classes":[0,2,4,5,7,9,11]},"channels":[{"id":"lofi.bass","label":"Bass","active":true,"kind":"melodic","mode":"auto","ready":true,"instrument":"Round","instrument_revision":3,"base_midi":26,"root_midi":62,"octave_offset":-1,"pending_window":null,"parameters":[{"id":"gain","label":"Level","value":0.5,"default":0.5,"display":"0.0 dB"}],"pad_bank":null}],"drums":{"choices":[],"current_id":null,"pending":null}}
```

`channels` has all 16 channel records, fixed order below; inactive records remain visible but reject sound/control actions except reset. Controller banks active channels first and supports scrolling, no eight-channel assumption. `ready` false means audible mode and controls are still represented but manual assets are preparing. Use `status` optional string for short reason. Each channel parameter object uses exact metadata above; controller uses server labels/values, never invents unsupported controls. Pad bank either null or `{revision:int, bank_id:string, cue_token:string|null, pads:[{index:int,label:string,kind:string,ready:bool,play_mode:"gate"|"one_shot"|"latch",beats:number|null}], effective_beat:number|null}`. All existing pad roles appear; empty/unready pads unlit, ready pads colored by role. Bank atomic replacement, not per-pad streaming. Bank IDs and revisions stay distinct.

Drum choices `[ {id:string,label:string,ready:bool,bpm:number} ]` max 64; opaque IDs, no private filesystem paths. Never transmit PCM or entire transcript. `drums.pending` null or `{request_id:string,choice_id:string,status:"preparing"|"selected"|"queued"|"applied"|"failed",effective_beat:number|null}`. The current phrase's actual playing instrument and bank determine state, not prepared-next assets. Bank/change state updates are sent at audible activation; optional `pending_bank` may preview but cannot be triggered.

## Channels and encoders

Fixed IDs (order): `lofi.drums`, `lofi.bass`, `lofi.lead`, `lofi.mids`, `lofi.space`, `lofi.chops`, `film.bed`, `ambient.drone`, `ambient.pad`, `ambient.lead`, `ambient.keys`, `ambient.drips`, `ambient.air`, `ambient.grains`, `ambient.pluck`, `ambient.space`.

Lo-Fi channels active only in Lo-Fi; ambient channels active only in ambient; film bed active in either when footage audio exists. Film unavailable/empty is explicit. Space is a return channel, not a pretend pitched instrument. Each channel has auto/manual: space manual closes automatic return and offers held return pads for current live sources; film manual opens current continuously advancing bed only while gate pad is held. Preparation and film phase continue muted.

Eight encoders same stable slots across channels: `gain`, `low_cut`, `high_cut`, `tone`, `drive`, `echo`, `room`, `pan`. Defaults preserve existing signal. These are live additive performance controls AFTER original processing, not writes into parameters owned by generative automation. UI labels emphasize current values; 0...100 percent indicator always bounded, gain display may additionally show dB. `gain` is mixer control as well as encoder 1; duplicate mapping intentional.

| id | default normalized | DSP mapping |
| --- | --- | --- |
| gain | 0.5 | v=0 exact mute; 0<v<=0.5 => -60+120v dB; v>0.5 =>12(v-0.5) dB. Unity at0.5, maximum+6dB. |
| low_cut | 0 | zero bypass; otherwise 20*100^v Hz (20...2000); 12 dB/oct, smooth activation |
| high_cut | 1 | one bypass; otherwise 200*100^v Hz (200...20000); 12 dB/oct |
| tone | 0.5 | high shelf at 1500 Hz, gain 12(v-0.5) dB |
| drive | 0 | zero bypass; added saturator with input drive up to 12 dB, equal-power wet blend v; bounded output, no hard volume boost |
| echo | 0 | additional tempo-linked 0.75-beat delay; send up to 0.35, feedback fixed 0.32; preserve old tails across tempo changes |
| room | 0 | additional dark room, send up to 0.30; leave existing original room unchanged |
| pan | 0.5 | stereo balance -1...1 with exact-unity center (not equal-power -3 dB center on existing stereo) |

Use independent unity gain and bypass states for exact baseline. Original preset effects remain active at defaults. New echo/room sends start zero, not original effects zeroed. Ambient original sends retain generation-owned values multiplied by user channel gate/gain before common returns; live added FX on its separate performance strip. Space channel can use tone/filter/drive/gain/pan; echo and room may be absent/disabled to avoid recursive returns. Per-channel descriptors indicate unsupported slots as `enabled:false` and keep labels stable. Low/high-cut crossing clamps low cutoff <= high cutoff/1.2 with returned canonical values. Knob writes use ramps >=20 ms and never rebuild audio graph.

Pad behaviors: melodic channels gate with actual instrument envelopes; keys/pluck/drips can report one-shot but note-off still cancels a pending onset and releases sustained tails normally. Chops slots 0..N-1 actual bank pads (max 63), slot 63 whole anchor line (one-shot); duplicate anchor in normal bank is acceptable. Film pad 0 gate; Space pads 0/1/2 gate returns from currently sounding bass/lead/mids in Lo-Fi, current dry mix in Ambient; labels explicit, no invented note keyboard. Drums pads enumerate prepared choices; press requests launch, release does not stop; in manual mode selected loop latches until next pad or all_notes_off/return-auto/stop. No command pads occupy melodic 8x8 layout.


## Stage 4 capability and selection details

`manual_pads` reports active prepared drum/chop assets; `drum_selection` reports the installed Lo-Fi selection adapter; `film_mix` follows an actual available film cue. `performance_audio` is true for ready manual notes or pads; `manual_notes` remains melodic-only. Film and Space Manual/pads remain unavailable in this implementation despite the target behaviors above. Their mixer controls remain independent of generative automation.

Drum `selected` means a Manual choice was processed and selected silently, without launching a loop. A Manual `pad_on` launches/latches a ready choice; a selection while a loop is latched replaces it on a safe bar. Ready flags describe the bounded current-tempo PCM cache; other catalog choices can be prepared through `drum_select`/`drum_next`. `drums.current_label` and `bpm` identify the audible source, while `current_id` is a choice ID or `automatic-silence` when the original automatic source has no recording. `pending.effective_beat` is take-relative to the published transport origin; `applied` means the boundary transition began. Manual stop cancels the latch without altering the automatic transport.

Chop banks additionally expose `plan_revision` and `transport_revision`. A stale `bank_revision` rejects; an unprepared or retired bank never queues a later surprise onset. An accepted chop launch acknowledgement adds `status:"pending"` and `effective_beat` (take-relative), scheduled at the next sixteenth after the route/render margin. The published bank clears at an announced bank activation if replacement PCM is not ready, so the old bank is never offered as the newly audible bank. Slot 63 is the real contiguous played-bank anchor and may remain unready if it cannot meet stretch or memory bounds. Native timing/pitch qualification is still required.
