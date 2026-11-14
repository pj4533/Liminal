# Verifying Liminal on the visionOS Simulator from Claude Code

Synthesis of six research reports, 2026-11-14. Machine: Xcode 26.3 (17C519), macOS 27.2, visionOS 26.2 simulator "Apple Vision Pro" `19A53057-4A6A-47EE-A627-33A845C5E7FF`, physical Vision Pro paired (visionOS 27.2.1).

Status tags: **PROVEN** = already run on this machine. **FIELD** = others report it working, not yet run here. **UNVERIFIED** = plausible, nobody has confirmed it.

---

## 1. TL;DR recommendation

No off-the-shelf MCP drives the visionOS simulator today. The best stack is three parts: tools Apple already ships (`simctl`), a small DEBUG-only control channel inside Liminal, and an XCUITest runner for real button presses. Screen-level clicking is the fallback.

| Need | Primary | Fallback |
|---|---|---|
| **(a) UI input / state changes** | **DEBUG launch args, env vars and a `liminal://` URL scheme** that drive the app from inside: auto-Play, auto-open the dome, set effect parameters, freeze time. Driven with `simctl launch` / `simctl openurl`, which are PROVEN commands; the hooks themselves still have to be written. For tests that must press the real buttons, use **XCUITest in the existing `LiminalUITests` target** (FIELD: tap, typeText and the hierarchy work on the visionOS 26.5 sim, but see section 4). | **Host mouse clicks on the Simulator window.** Apple maps click to tap and click-and-hold to pinch-hold. Use Claude Code's built-in `computer-use` MCP, or Peekaboo (already installed and permitted) for scripted coordinate clicks. UNVERIFIED on visionOS. |
| **(b) Screenshots of immersive graphics** | `xcrun simctl io <udid> screenshot` (PROVEN, 3840x2160 framebuffer). Pair it with a DEBUG "freeze time / fixed seed" flag so frames are deterministic and can be diffed. | `simctl io recordVideo` and extract frames with ffmpeg (UNVERIFIED on visionOS), or a Peekaboo window capture. Note that `XCUIScreen` returns a 1x1 image on visionOS (FIELD), so do not use XCTest screenshots. |
| **(c) FPS / performance** | The in-app `PERF fps=` log line read via `simctl spawn <udid> log stream` (PROVEN). Extend it with GPU ms (`MTLCommandBuffer.gpuEndTime - gpuStartTime`), CPU encode ms, p95 and max frame time, plus `OSSignposter` intervals. | Metal HUD log (`SIMCTL_CHILD_MTL_HUD_ENABLED=1 SIMCTL_CHILD_MTL_HUD_LOG_ENABLED=1`, grep `metal-HUD:`), then `xctrace record` (Metal System Trace) and `xctrace export`. Both UNVERIFIED on the visionOS sim. For absolute numbers, run on the paired Vision Pro with `devicectl --console` and `xctrace`. |

Simulator FPS reflects the Mac GPU going through a different render pipeline. Apple says sim performance data "might not be accurate". Use sim numbers only for relative A/B comparisons and regression checks.

**Worth re-checking soon:** Xcode 27 (released 2026-09-14). Its `xcrun mcpbridge` adds `DeviceInteractionSynthesize`, which does taps and swipes and returns a screenshot plus the UI hierarchy. visionOS support is UNVERIFIED. Also watch kaeawc/auto-mobile, which merged visionOS window-app support on 2026-11-05.

---

## 2. Setup steps

### 2.1 Proven commands (nothing to install)

```sh
UDID=19A53057-4A6A-47EE-A627-33A845C5E7FF
xcodebuild -scheme Liminal -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -derivedDataPath build/dd build
xcrun simctl install $UDID build/dd/Build/Products/Debug-xrsimulator/Liminal.app
xcrun simctl launch --terminate-running-process $UDID com.saygoodnight.Liminal
xcrun simctl io $UDID screenshot /tmp/liminal.png
xcrun simctl spawn $UDID log stream --style compact --predicate 'eventMessage CONTAINS "PERF"'
```

### 2.2 Project change A: DEBUG control channel (highest value)

Today `EnvironmentService.swift` only reads `ProcessInfo` environment. The repo has no launch-arg handling and no `onOpenURL`, and the immersive spaces open from button actions in `ControlsView.swift` (lines 73 and 99). Add a `#if DEBUG` `TestHooks` type that:

- reads launch args or env vars: `-autoPlay`, `-autoEnterDome` / `-autoEnterDiorama`, `-param <name>=<value>`, `-freezeTime <t>` (fixed oscillator time so screenshots are deterministic), `-perfLogInterval 1`;
- registers a `liminal` URL scheme with `.onOpenURL` for runtime commands such as `liminal://play`, `liminal://enter-dome`, `liminal://exit-dome`, `liminal://set?param=hueShift&value=0.3`, `liminal://spatial?on=1`;
- calls `openImmersiveSpace(id: "liminalDome")` from a `.task` / `onOpenURL` in the control window's scene context, using the same code path as the button;
- logs one line per state change (`STATE dome=open spatial=1 ...`) so Claude can confirm each action from the logs without reading pixels.

Usage:

```sh
SIMCTL_CHILD_LIMINAL_AUTOPLAY=1 xcrun simctl launch --terminate-running-process $UDID com.saygoodnight.Liminal -autoEnterDome
xcrun simctl openurl $UDID 'liminal://set?param=hueShift&value=0.3'
sleep 3; xcrun simctl io $UDID screenshot /tmp/after.png
```

The same flags work on the device: `xcrun devicectl device process launch --device E52BB7CB-464E-5216-AB0F-2B97B1696AF8 --console --terminate-existing com.saygoodnight.Liminal -autoEnterDome`. This matters because UI on a physical Vision Pro cannot be automated.

### 2.3 Project change B: richer PERF line

Emit a 1 Hz line that is easy to parse, for example `PERF fps=59.8 cpu_ms=1.9 gpu_ms=4.2 p95_ms=17.1 max_ms=24.0 mode=dome`. Take GPU time from the command buffer's completion handler. Add `OSSignposter(subsystem: "com.saygoodnight.Liminal", category: "Render")` intervals so xctrace traces line up with actions. Log at `.notice` or higher so `log show` can read the lines after the fact.

### 2.4 Project change C: XCUITest for real taps (first validate, see section 5)

- Add `.accessibilityIdentifier("play")`, `"enterDome"`, `"spatial"`, `"settings"` and slider IDs in `ControlsView`.
- Replace the template in `LiminalUITests` with tests such as `app.buttons["enterDome"].tap()`. Take screenshots from the host with `simctl`, not `XCUIScreen`.
- Run:

```sh
xcodebuild build-for-testing -scheme Liminal -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -derivedDataPath build/dd
xcodebuild test-without-building -scheme Liminal -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -derivedDataPath build/dd -only-testing:LiminalUITests/LiminalUITests/testEnterDome
```

Expect about 40 s of runner startup per invocation.

### 2.5 Fallback clicking: Claude Code computer use / Peekaboo

- Computer use (built in, research preview, macOS, Pro/Max/Ultra, interactive sessions only): run `/mcp`, select `computer-use`, choose Enable, grant the terminal Accessibility and Screen Recording, then approve Simulator when prompted. No JSON config is needed.
- Peekaboo 3.0.0-beta3 is already installed with both permissions granted. Upstream is 4.9.8 at `brew install openclaw/tap/peekaboo`. To try it:

```sh
peekaboo list windows --app Simulator          # get window id/bounds
peekaboo image --app Simulator --path /tmp/simwin.png
peekaboo move --coords X,Y; peekaboo click --coords X,Y   # confirm flags with --help
```

  Optional MCP entry (`.mcp.json` in the repo root):

```json
{
  "mcpServers": {
    "peekaboo": { "command": "npx", "args": ["-y", "@steipete/peekaboo"] }
  }
}
```

- Optional build/docs helper, Apple's Xcode MCP (Xcode must be running, with Settings > Intelligence > Xcode Tools enabled): `claude mcp add --transport stdio xcode -- xcrun mcpbridge`. It does not provide simulator input on 26.3.

### 2.6 Performance experiments (cheap, run once)

```sh
SIMCTL_CHILD_MTL_HUD_ENABLED=1 SIMCTL_CHILD_MTL_HUD_LOG_ENABLED=1 xcrun simctl launch --terminate-running-process $UDID com.saygoodnight.Liminal
xcrun simctl spawn $UDID log stream --style compact --predicate 'eventMessage CONTAINS "metal-HUD"'
xcrun xctrace record --device $UDID --attach Liminal --instrument 'Metal Application' --instrument os_signpost --time-limit 15s --no-prompt --output /tmp/l.trace
xcrun xctrace export --input /tmp/l.trace --toc
```

---

## 3. Comparison of candidates

| Candidate | visionOS sim input | Screenshots | Perf | Confidence | Notes |
|---|---|---|---|---|---|
| `simctl` (io screenshot, launch, openurl, log stream) | No input verbs | **Yes (PROVEN)** | via logs (PROVEN) | High | Foundation of the stack |
| In-app DEBUG hooks (args, env, URL scheme) | Yes, indirectly | n/a | n/a | High | Needs a small code change. Deterministic. Also works on device |
| XCUITest (`LiminalUITests`) | **FIELD**: tap and typeText on window and ornament buttons, visionOS 26.5 | `XCUIScreen` is 1x1, so use simctl | low value | Medium | Apple docs say "UI testing isn't available to apps you build using the visionOS SDK", but field reports show it working in the sim. See section 4 |
| kaeawc/auto-mobile MCP | FIELD (author-verified): observe, tapOn, sendKeys; window apps only | simctl | no | Medium-low | Merged 2026-11-05, no tagged release. Built on XCUITest |
| Claude Code `computer-use` | UNVERIFIED (click = tap by Apple design) | downscaled | no | Medium | Zero install. Slow, hides other apps, interactive only |
| Peekaboo 3.0.0-beta3 (installed) | UNVERIFIED coordinate clicks | window capture | no | Medium-low | Mac AX tree does not see SwiftUI inside the sim. Coordinate math needed |
| cliclick / osascript / Hammerspoon | UNVERIFIED (osascript is reliable only for Simulator menus) | no | no | Low | Same CGEvent risk as Peekaboo |
| Xcode 27 mcpbridge `DeviceInteraction*` | UNVERIFIED for visionOS | yes (per 3P) | no | Low | Needs Xcode 27. Most promising "official" path |
| Xcode 26.3 mcpbridge | No | previews only | no | High | Build, test and docs only. One report says its device tools refuse visionOS |
| XcodeBuildMCP 2.3.2 (latest 2.7.1, renamed MobileBuildMCP) | **No** (AXe) | yes | no | High | Still fine for build, run and logs |
| AXe 1.2.1 | **No (PROVEN no-op)** | yes | no | High | README covers iOS only |
| mobile-mcp, ios-simulator-mcp, idb, simdrive, Appium, Maestro, serve-sim | No / undocumented | n/a | simdrive is iOS-only | Medium | All iOS/Android |
| Claude Desktop iOS Simulator pane | No (docs cover iPhone/iPad only) | n/a | stream FPS only | High | Desktop app only |
| Metal HUD env vars | n/a | overlay maybe | UNVERIFIED | Low | One-minute experiment |
| xctrace (Metal System Trace, RealityKit Trace) | n/a | n/a | UNVERIFIED on sim; device supported | Medium | RealityKit traces are practically Instruments-only |
| metalperftrace (WWDC26) | n/a | n/a | macOS/iOS only | Low | Watch |

---

## 4. What does NOT work, and why

- **AXe / XcodeBuildMCP UI tools.** AXe injects touches through the iOS HID path. On visionOS, `tap` reports success but does nothing, and `describe-ui` errors (PROVEN). Upgrading to 2.7.x is unlikely to help, and no upstream issue tracks it.
- **`simctl` input.** There are no tap, key or gesture verbs. The visionOS IO ports are output-only.
- **Other iOS MCPs** (mobile-mcp, ios-simulator-mcp/idb, simdrive, Appium, Maestro) document only iOS and Android.
- **Xcode 26.3 mcpbridge.** Its tools cover build, test, previews, file ops and docs. It has no running-app input or screenshots.
- **Claude Desktop simulator pane** supports iPhone and iPad only.
- **`XCUIScreen.main.screenshot()`** returns a 1x1 image on visionOS (FIELD).
- **Gaze, pinch, drag and Digital Crown** cannot be scripted through XCUITest (`XCUIDevice.rotateDigitalCrown` exists but is untested).
- **Accessibility-tree clicking from the Mac side** (Peekaboo `see` element IDs, System Events). SwiftUI inside the simulator framebuffer does not appear in the Mac AX tree.
- **Absolute FPS from the simulator** is not representative of device performance. There is no published sim-vs-device ratio.
- **UI automation on the physical Vision Pro** does not exist. Use launch flags instead.

**Contradiction resolved: XCUITest.** Report 02 cites Apple's XCUIAutomation page, which I re-fetched. It does say "UI testing isn't available to apps you build using the visionOS SDK." Report 01 cites auto-mobile issue #16851, which I also re-fetched. On visionOS 26.5, `tap()` on window and ornament buttons worked and typeText worked, but immersive content visibility is unknown. Two other projects (Jelly-Shark PR #341, Labstream PR #438) report the same result. Conclusion: XCUITest is officially unsupported but works in practice on the simulator. It is UNVERIFIED on the 26.2 runtime with Xcode 26.3 used here, so it needs one smoke test before we invest in it. That is why the DEBUG hooks, not XCUITest, are the primary input path.

---

## 5. Open questions to verify hands-on (in order)

1. **XCUITest smoke test** on visionOS 26.2 / Xcode 26.3: does `XCUIApplication().launch()` plus `buttons["enterDome"].tap()` open the dome? Confirm with simctl screenshot and logs.
2. **Opening the immersive space from a DEBUG hook** without a user gesture: does `openImmersiveSpace` from `.task` / `onOpenURL` succeed, and does a first-run permission prompt block it in the sim?
3. **Do host clicks register?** Run a Peekaboo coordinate click (move, dwell about 300 ms, click) on Play. If that fails, try computer-use. Check that the Simulator is in "Select to interact" mode, not camera pan.
4. **Metal HUD** in the visionOS sim: does a `metal-HUD:` log line appear with Liminal's offscreen 2048x2048 render?
5. **xctrace** attach to the sim process: are the traces non-empty, which schemas does `--toc` show, and does the reported Xcode 26 `--template` export bug apply?
6. **`simctl io recordVideo`** on visionOS, for frame-cadence analysis.
7. **Xcode 27 `DeviceInteractionSynthesize`** on the visionOS sim: install Xcode 27 side by side and export the `device-interaction` skill with `xcrun agent skills export`. Watch for the reported visionOS 27.0 sim RealityKit bugs.
8. **kaeawc/auto-mobile** as a ready-made MCP alternative to a hand-written XCUITest runner.
9. **studiomeije/visionos-codex-plugin** `visionos-ui-automation` SKILL.md (the fetch returned 403). What mechanism does it use?

---

## 6. Index of per-angle reports

1. [01-mcp-servers.md](01-mcp-servers.md): MCP and CLI survey (XcodeBuildMCP, AXe, mobile-mcp, auto-mobile, idb, Appium, Maestro, simdrive)
2. [02-apple-native-tooling.md](02-apple-native-tooling.md): XCUITest, Xcode 26.3 and 27 mcpbridge, Device Hub, devicectl, simctl, launch-arg hooks
3. [03-desktop-gui-automation.md](03-desktop-gui-automation.md): Simulator input mapping, Peekaboo, computer use, cliclick, coordinate mapping
4. [04-performance-measurement.md](04-performance-measurement.md): Metal HUD, in-app instrumentation, xctrace, device profiling, sim vs device
5. [05-claude-code-visionos-workflows.md](05-claude-code-visionos-workflows.md): Anthropic mechanisms, community practice, verifying immersive content
6. [06-local-environment-inventory.md](06-local-environment-inventory.md): installed tool versions, MCP config, Liminal targets and schemes

---

## Hands-on result (2026-11-14) — PROVEN on this machine

**Peekaboo 3.0.0-beta3 clicks work on the visionOS 26.2 simulator.** Clicking the macOS Simulator window registers as a gaze+pinch tap in visionOS.

Verified end-to-end with no code changes to the app:
1. `scripts/sim-tap.sh 1371 935` → Play button toggled to Stop, status "Playing".
2. `scripts/sim-tap.sh 1371 1041` → "Enter Dome" opened the ImmersiveSpace.

(Coordinates updated for the redesigned 1240x800 control window, docs/decisions/ui.md. The original run used 1795 937 / 1918 937 on the old 320x560 window.)
3. `xcrun simctl io <udid> screenshot` captured the rendered dome shader output (3840x2160).
4. `log stream` produced `📊 visionOS PERF: fps=72.5 | render avg=0.2ms max=0.9ms | dropped=20`.

`scripts/sim-tap.sh <x> <y>` takes coordinates in **simulator-screenshot pixels**. It reads the Simulator window bounds through Peekaboo and maps them to screen points. The display is 16:9 at window width, and the remaining space above it is window chrome. Workflow: screenshot → find the element's pixel position → `sim-tap.sh`.

Sliders do not respond to a tap, and they ignore `peekaboo drag`. To move them, use `scripts/sim-drag.sh <x0> <y0> <x1> <y1>`, which takes the same pixel coordinates. It posts CGEvent drags through `scripts/sim-drag.swift`, and the Simulator only responds when those events carry `mouseEventDeltaX/Y`. The slider moves less than the pointer, so overshoot and check the screenshot: dragging +160 px moved the value by 11 to 22 points in testing. Picker menus such as Scale open with a tap, and a second tap picks an item.

Caveats:
- The Simulator window must stay visible and on-screen. The window is resizable, and the script re-reads its bounds on every tap.
- The PERF line's `render` time is CPU encode time, not GPU time. For shader optimization work, add GPU timing (`MTLCommandBuffer.gpuStartTime/gpuEndTime`) to the PERF line (see 04-performance-measurement.md).
- Debug launch-arg hooks are still worth adding later for deterministic setup (e.g. freeze time for screenshot comparison). They are not needed to drive the UI.
