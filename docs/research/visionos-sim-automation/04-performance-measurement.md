# 04 - Performance measurement for Liminal on visionOS (simulator and device), scriptable from a CLI agent

Researched 2026-11-14. Environment: Xcode 26.3, xctrace 26.0 (17C519), devicectl 506.7, visionOS 26.2 simulator
"Apple Vision Pro" 19A53057-4A6A-47EE-A627-33A845C5E7FF. A physical Vision Pro (visionOS 27.2.1) is paired and "available".

Legend: [VERIFIED-LOCAL] = I ran it on this machine. [DOC] = from Apple documentation. [UNTESTED] = plausible, not run
(the brief forbade touching the running simulator and installing anything, so no recording or HUD test was run against the sim).

## TL;DR recommendation

1. Primary, already working: in-app instrumentation. The app already logs an `fps=` PERF line. Keep it, and add
   `os_signpost` intervals plus `MTLCommandBuffer.gpuStartTime/gpuEndTime` (GPU time) to that line. Read via
   `xcrun simctl spawn <udid> log stream` (sim) or `devicectl ... --console` / `log collect` (device). Cheapest, most scriptable.
2. Cheap experiment worth trying first on the sim: `MTL_HUD_ENABLED=1 MTL_HUD_LOG_ENABLED=1` passed via
   `SIMCTL_CHILD_` env vars. If it works, the HUD prints `metal-HUD:` per-frame present interval + GPU time lines to the console
   and also draws an overlay visible in `simctl io screenshot`. Unverified on visionOS sim (see section 1).
3. Deep-dive: `xctrace record` with Metal System Trace / RealityKit Trace against the sim or device, then `xctrace export --xpath`.
   Works from CLI per man page; visionOS-specific schemas and reliability are UNTESTED and there are Xcode 26 export caveats (section 3).
4. Numbers from the simulator run on the Mac GPU through a different pipeline. Use them for relative A/B comparisons and regressions
   only. Use the real Vision Pro (paired, reachable over network) for absolute numbers (section 7).

## 1. Metal Performance HUD

Source: Apple, "Monitoring your Metal app's graphics performance" (fetched, copyright 2026).

Documented controls [DOC]:
- `MTL_HUD_ENABLED=1` enables the overlay.
- `MTL_HUD_LOG_ENABLED=1` logs per-frame stats to the console; requires `MTL_HUD_ENABLED=1`. (Note: a search-result summary
  quoted `MTL_HUD_LOGGING_ENABLED` from the Tech Talk; the current Xcode doc says `MTL_HUD_LOG_ENABLED`. Use the doc name.)
- `MTL_HUD_LOG_SHADER_ENABLED=1` logs shader compiles as signposts (subsystem `com.apple.metal.hud`, category `Logging`).
- `MTL_HUD_ENCODER_TIMING_ENABLED=1` per-encoder GPU time (only if the app does not use Metal counter sample buffers).
- `MTL_HUD_SHOW_VALUE_RANGE=1` shows avg(120 frames) / min / max(1200 frames).
- Alternatives: Info.plist key `MetalHudEnabled`, UserDefaults `MetalHUDForceEnabled=1`, Xcode scheme "Show Graphics Overview" +
  "Log Graphics Overview" (both needed for logging), Settings > Developer > Graphics HUD on iOS/iPadOS/tvOS devices.
- Log format, once per second: `metal-HUD: <first-frame-number>,<gfx-mem>,<proc-mem>,<present-interval>,<gpu-time>,...` (pairs per frame).
- HUD shows avg FPS, GPU time, frame interval, a 120-frame interval chart, memory, resolution.

visionOS: the doc lists on-device Settings only for iOS/iPadOS/tvOS, and does not mention visionOS or simulator at all. I found no source
confirming the HUD renders (or logs) in the visionOS simulator or on Vision Pro. RealityKit-composited content may not go through a
CAMetalLayer the HUD can hook; Liminal's offscreen 2048x2048 texture rendering (OffscreenEffectsRenderer) is a further reason the overlay
may not appear. Treat as UNTESTED. The `metal-HUD:` log line is the more likely thing to work than the visual overlay, since it hooks Metal
command buffer completion rather than a drawable.

Concrete commands to try [UNTESTED]:

```sh
UDID=19A53057-4A6A-47EE-A627-33A845C5E7FF
# simctl forwards env vars that carry the SIMCTL_CHILD_ prefix (prefix stripped) to the launched app
SIMCTL_CHILD_MTL_HUD_ENABLED=1 SIMCTL_CHILD_MTL_HUD_LOG_ENABLED=1 \
  xcrun simctl launch --terminate-running-process $UDID com.saygoodnight.Liminal
# in another shell
xcrun simctl spawn $UDID log stream --style compact --predicate 'eventMessage CONTAINS "metal-HUD"'
```

Device (documented forum workaround, Apple forums thread 760649). devicectl help (verified locally) says env vars can be given either as
`-e '{"K":"V"}'` JSON or as `DEVICECTL_CHILD_`-prefixed vars in the caller's environment (the `-e` flag overrides the latter):

```sh
xcrun devicectl device process launch --device <VisionPro-CoreDevice-UUID> --console --terminate-existing \
  -e '{"MTL_HUD_ENABLED":"1","MTL_HUD_LOG_ENABLED":"1"}' com.saygoodnight.Liminal
```

On a device the Apple Staff comment says HUD is for developer-built apps, which Liminal is.

## 2. In-app instrumentation (recommended baseline)

Already in place: PERF log line with `fps=`. Suggested additions:

- GPU time: in the renderer's command buffer completion handler read `cb.gpuStartTime` / `cb.gpuEndTime` (seconds, CFTimeInterval;
  `GPUEndTime - GPUStartTime` = GPU busy time). Also `cb.kernelStartTime/kernelEndTime` for scheduling latency. On the simulator these
  reflect the host Mac GPU (Apple Silicon), not the Vision Pro R1/M2. Add `cb.error` logging.
- CPU frame time: measure with `CACurrentMediaTime()` around uniform computation + encode, and a rolling window (e.g. 120 frames) emitting
  avg / p95 / max, to catch hitches that avg fps hides.
- Signposts: `OSSignposter(subsystem: "com.saygoodnight.Liminal", category: "Render")`; `beginInterval("frame")`, `beginInterval("encode")`,
  and `emitEvent` for toggles (Spatial on/off, effect changes) so traces from xctrace/Instruments line up with UI actions. Apple staff
  (forum thread 855212) note OSSignposter times your own code but does not measure RealityKit renderer deadlines.
- Emit a single machine-parsable line, e.g. `PERF fps=59.8 cpu_ms=1.9 gpu_ms=4.2 p95_ms=17.1 max_ms=24.0 mode=spatial`, so the agent can
  `grep`/awk it. Keep the log rate to 1 Hz.
- MTLCounterSampleBuffer timestamps (stage boundaries) are available on Apple GPUs but support on the sim is uncertain; and note the HUD's
  encoder timing is disabled if the app uses counter sample buffers (conflict).

Reading logs:

```sh
# simulator, live
xcrun simctl spawn $UDID log stream --level info --predicate 'subsystem == "com.saygoodnight.Liminal"'
# simulator, post-hoc (works without a live stream)
xcrun simctl spawn $UDID log show --last 2m --predicate 'eventMessage CONTAINS "PERF"'
# device: stdout of the launched app (print/NSLog; os.Logger needs log stream/collect)
xcrun devicectl device process launch --device <UUID> --console --terminate-existing com.saygoodnight.Liminal
```

Note for Logger: os.Logger `.debug`/`.info` messages are not persisted by default, so use `log stream`, not `log show`, or log at `.notice`.

## 3. xctrace / Instruments from the CLI

Verified locally [VERIFIED-LOCAL]:

- `xcrun xctrace list templates` includes: Metal System Trace, RealityKit Trace, Game Performance, Game Performance Overview,
  Animation Hitches, Time Profiler, CPU Profiler, System Trace, Power Profiler, SwiftUI, Allocations, Leaks, Logging, Game Memory, etc.
- `xcrun xctrace list instruments` includes: Metal Application, Metal GPU Counters, Metal Performance Overview, Metal Resource Events,
  RealityKit Frames, RealityKit Metrics, Core Animation FPS, Frame Lifetimes, GPU, Hitches, os_signpost.
- `xcrun xctrace list devices` shows the sim and the physical Vision Pro. Note the two ID spaces: xctrace uses the hardware UDID
  `00008112-001430AC34D8A01E`; devicectl uses the CoreDevice UUID `E52BB7CB-464E-5216-AB0F-2B97B1696AF8`.
- `xctrace record` flags (from `xctrace record` usage): `--template`, `--instrument` (repeatable), `--device <name|UDID>`,
  `--attach <pid|name>`, `--launch -- cmd`, `--all-processes`, `--time-limit 20s`, `--window`, `--output x.trace`, `--run-name`,
  `--append-run`, `--no-prompt`, `--notify-tracing-started <darwin-notif>`, `--env` and `--target-stdout` (launch mode only).
  Apple's own example: `xctrace record --template 'Metal System Trace' --device-name 'iPhone SE Simulator' --all-processes`.

Commands [UNTESTED against the visionOS sim]:

```sh
UDID=19A53057-4A6A-47EE-A627-33A845C5E7FF
OUT=/tmp/liminal-metal.trace
# Attach by process name to the already-running sim app (app must be running and the immersive space open)
xcrun xctrace record --template 'Metal System Trace' --device $UDID --attach Liminal \
  --time-limit 15s --no-prompt --output $OUT
# RealityKit Trace (render server stalls, per-frame CPU/GPU, RealityKit frame deadlines)
xcrun xctrace record --template 'RealityKit Trace' --device $UDID --attach Liminal --time-limit 15s --no-prompt --output /tmp/liminal-rk.trace
# Launch under the profiler instead of attaching (lets you inject env vars such as MTL_HUD_*)
xcrun xctrace record --template 'Metal System Trace' --device $UDID --env MTL_HUD_ENABLED=1 \
  --time-limit 15s --launch -- com.saygoodnight.Liminal
# Combine via instruments instead of a template (see caveat below)
xcrun xctrace record --device $UDID --attach Liminal --instrument 'Metal Application' --instrument 'os_signpost' --instrument 'Hitches' --time-limit 15s --output /tmp/x.trace
```

Export:

```sh
xcrun xctrace export --input /tmp/liminal-metal.trace --toc > toc.xml     # lists runs, tables and schemas
xcrun xctrace export --input /tmp/liminal-metal.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-driver-event-intervals"]' > gpu.xml
```

Schemas I would look for in the TOC (names from memory of Instruments, to be confirmed with `--toc`): `os-signpost`,
`os-signpost-interval`, `metal-application-intervals`, `metal-gpu-intervals`, `metal-driver-event-intervals`,
`display-surface-queue` / `hitches` / `hitches-frame-lifetimes`, and RealityKit's own tables. Only `metal-driver-event-intervals`
was seen in a cited forum post (Apple forums 700733); the rest are unverified.

Caveats:
- Apple staff (forums 855212): xctrace can record RealityKit Trace from CLI, but "the resulting .trace file is readable only in Instruments";
  no documented RealityKit schema. The RealityKit Trace "includes all running apps" so close other apps. A forum developer reported never
  getting a usable RealityKit timing trace (unresolved).
- Community skill reference (axiom-xctrace-ref, tested on Xcode 26.2, UNVERIFIED by me): `--template` recordings can fail on export
  ("Document Missing Template Error") on Xcode 26+; the workaround is `--instrument`. Check with `--toc` right after the first recording.
- Whether the Metal System Trace / RealityKit Trace works at all with the sim visionOS process is not documented. WWDC23 "Meet RealityKit
  Trace" says it works on device and simulator, but Apple also says sim performance data may be inaccurate.
- Interactive-only features: Game Performance Overview (WWDC26 session 388) is analyzed in Instruments; its new `metalperftrace` CLI
  (macOS 27, `.atrc` files, `overview --json`, built for AI-agent triage) targets macOS/iOS always-on recording and the session does not
  mention visionOS or simulator. Worth watching; not usable for Vision Pro today as far as sources show.
- Sandbox/privileges: recording the Mac's kernel-level data can require approval/sudo prompts; `--no-prompt` skips privacy prompts.
- Time Profiler for CPU hot spots: `xcrun xctrace record --template 'Time Profiler' --device $UDID --attach Liminal --time-limit 10s`
  then `xctrace export --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'`.

## 4. XCTest performance metrics on visionOS

Not researched deeply; no authoritative source found. Facts: `XCTClockMetric`, `XCTOSSignpostMetric` (with `measure(metrics:)` and signposts
in app code via the `OSSignposter` / `os_signpost` API, category `"...Performance"` conventions), `XCTCPUMetric`, `XCTMemoryMetric` exist in
XCTest on Apple platforms; visionOS XCTest unit tests run on the simulator via `xcodebuild test -destination 'platform=visionOS Simulator,name=Apple Vision Pro'`.
UI tests (`XCUIApplication`) on visionOS are reportedly supported only in the simulator and are limited (a third-party guide says physical
Vision Pro UI testing is not supported) and immersive-space interaction is weak. UNVERIFIED. Value for Liminal: low; a signpost metric
around a rendering call in a unit test only measures CPU encode time, not GPU or display rate. In-app logging (section 2) is better.

## 5. Display-rate / hitch measurement

- Instruments "Animation Hitches" and "Core Animation FPS" cover the Mac/iOS window system; for visionOS immersive content the compositor
  render server is what matters, which RealityKit Trace covers. The sim does not model the compositor timing of the headset.
- Apple's visionOS performance doc, "Creating a performance plan for visionOS app", recommends the RealityKit Trace template and profiling
  on a physical device; mentions thermal throttling (not visible in short sim runs).

## 6. Screenshots as part of verification (already verified)

`xcrun simctl io $UDID screenshot out.png` works at 3840x2160. If `MTL_HUD_ENABLED` renders in the sim, the HUD would appear in these
screenshots. Combined with a shader effect-state log line, an agent can correlate screenshot and PERF line.

## 7. Simulator vs device representativeness

- Apple (Creating a performance plan for visionOS app; WWDC23 10100 render pipeline session): Simulator uses a different rendering
  pipeline on macOS; its rendering characteristics differ; it lacks some hardware features; performance data "might not be accurate".
  Always profile on device. Thermals only show on device.
- No published sim-vs-device FPS ratio found. Expect the sim to run the Mac GPU (M-series, usually much faster than the Vision Pro for this
  shader) at its own display cadence (not the headset's 90/96/100 Hz stereo path); a stereo/dual-eye render is not modeled the same way.
  Useful for: detecting crashes, regressions in relative cost (A/B effect on vs off), shader compile errors, relative GPU-time deltas.
  Not useful for: absolute FPS targets, thermal behavior, foveation, stereo cost, memory pressure.

## 8. Measuring on the real Vision Pro from the CLI

The Vision Pro is already paired and `available (paired)` over network [VERIFIED-LOCAL via `devicectl list devices` and `xctrace list devices`].

```sh
# Deploy and launch with console output and HUD env vars
xcodebuild -scheme Liminal -destination 'platform=visionOS,name=Apple Vision Pro' build   # or id=00008112-001430AC34D8A01E
xcrun devicectl device install app --device E52BB7CB-464E-5216-AB0F-2B97B1696AF8 path/to/Liminal.app
xcrun devicectl device process launch --device E52BB7CB-464E-5216-AB0F-2B97B1696AF8 --console --terminate-existing \
  -e '{"MTL_HUD_ENABLED":"1","MTL_HUD_LOG_ENABLED":"1"}' com.saygoodnight.Liminal
# Profile
xcrun xctrace record --template 'RealityKit Trace' --device 00008112-001430AC34D8A01E --attach Liminal --time-limit 20s --no-prompt --output /tmp/avp-rk.trace
xcrun xctrace record --template 'Metal System Trace' --device 00008112-001430AC34D8A01E --attach Liminal --time-limit 20s --no-prompt --output /tmp/avp-metal.trace
```

Constraints: the headset must be worn/awake (and the app focused) for the immersive space to render; user must be wearing it to tap
buttons. The agent cannot click UI on device (no automation), so launch-time flags are the way to start in a measured state (add a launch
argument or debug URL that auto-opens the dome, e.g. `devicectl ... com.saygoodnight.Liminal --autostart-dome`, requires app support).
Developer Strap is for wired Instruments/tethered use; wireless works for most things (Apple forum 751687 discusses; unverified).
`devicectl device process launch` also supports `--start-stopped` for debugger attach.
Visual capture of the headset view: Xcode > Window > Devices > screenshot, or Vision Pro Capture; a CLI path is not established here.

## 9. Suggested plan for the agent (ordered)

1. Add `gpu_ms`, `cpu_ms`, `p95`, `max` and os_signpost to the PERF line (cheap, no new tooling).
2. Try the `SIMCTL_CHILD_MTL_HUD_*` launch and grep `metal-HUD` in `log stream`; record result in docs.
3. Try one 10s `xctrace record --template 'Metal System Trace' --device $UDID --attach Liminal` and `xctrace export --toc`; record whether the
   trace is non-empty and which schemas exist. Then try RealityKit Trace.
4. For absolute numbers, run steps on the real device via devicectl, on request.

## Open questions (unverified)

- Does the HUD (overlay and `metal-HUD:` log) function in the visionOS 26.2 simulator and on device for RealityKit/offscreen rendering?
- Does xctrace attach to a visionOS simulator process and produce Metal/RealityKit tables? Does `--template` export break on Xcode 26.3?
- Does `SIMCTL_CHILD_` env passing work as expected for `simctl launch` on the visionOS runtime (it is the standard mechanism, so likely)?

## Sources

- Apple, Monitoring your Metal app's graphics performance: https://developer.apple.com/documentation/xcode/monitoring-your-metal-apps-graphics-performance (fetched via https://developer.apple.com/tutorials/data/documentation/xcode/monitoring-your-metal-apps-graphics-performance.md)
- Apple, Understanding Metal Performance HUD metrics: https://developer.apple.com/documentation/xcode/understanding-metal-performance-hud-metrics.md
- Apple Tech Talk 110339 (Metal Performance HUD): https://developer.apple.com/videos/play/tech-talks/110339
- Apple forums, Enable Metal Performance HUD on iPhone & iPad (devicectl -e): https://developer.apple.com/forums/thread/760649
- Apple forums, visionOS Performance Trace / RealityKit frame deadlines without Instruments: https://developer.apple.com/forums/thread/855212
- Apple forums, Retrieving the xpath of a timeline: https://developer.apple.com/forums/thread/700733
- Apple forums, Developer Strap and Xcode Instruments: https://developer.apple.com/forums/thread/751687
- xctrace man page: https://keith.github.io/xcode-man-pages/xctrace.1.html
- WWDC26 session 388, Find and fix performance issues in your Metal games (metalperftrace): https://developer.apple.com/videos/play/wwdc2026/388/
- WWDC23 10099 Meet RealityKit Trace: https://wwdcnotes.com/documentation/wwdc23-10099-meet-realitykit-trace/
- WWDC23 10100 visionOS render pipeline: https://developer.apple.com/videos/play/wwdc2023/10100/
- Apple, Creating a performance plan for visionOS app: https://developer.apple.com/documentation/visionos/creating-a-performance-plan-for-visionos-app.md
- Community xctrace reference (Xcode 26 export caveat, unverified): https://playbooks.com/skills/charleswiltgen/axiom/axiom-xctrace-ref
- Unity PolySpatial FAQ (sim limits, secondary): https://docs.unity3d.com/Packages/com.unity.polyspatial.visionos@1.3/manual/FAQ.html
- Local: `xcrun xctrace record` usage, `xcrun xctrace list templates|instruments|devices`, `xcrun devicectl device process launch --help`, `xcrun devicectl list devices` (run 2026-11-14)
