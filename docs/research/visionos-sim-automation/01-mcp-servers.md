# 01 - MCP servers / CLI tools for driving the visionOS simulator

Researched 2026-11-14. Angle: survey of MCP servers and CLIs for Apple-simulator automation, and whether each handles visionOS for input, UI hierarchy and screenshots.

## Bottom line

- No general-purpose iOS-simulator MCP server was found that is documented to do visionOS taps or hierarchy. This matches the finding that AXe taps are no-ops on visionOS.
- The only credible, field-verified path for tap and hierarchy on the visionOS simulator is an XCUITest runner (xcodebuild test-without-building against a `platform=visionOS Simulator` destination). This is a minimal Swift UI-test bundle in the app, not an MCP. Screenshots must go through `xcrun simctl io <udid> screenshot`, because `XCUIScreen` returns a 1x1 image on visionOS.
- kaeawc/auto-mobile (MCP server) merged a visionOS window-app XCUITest runner on 2026-11-05 (`observe`, `tapOn`, `sendKeys`). It is the only MCP found with an explicit visionOS input path. It is very new, and its scope is window apps only.
- Xcode 27 "Device Hub" (the simulator window replacement) is new. XcodeBuildMCP 2.7.0 added Device Hub UI automation, but only for the simulators named in its changelog. Whether that covers visionOS is unverified.
- Immersive-space content visibility to XCUITest is unverified and probably poor. Liminal's dome content is Metal-rendered, so the hierarchy only matters for the 2D control window. `simctl screenshot` is the right way to see the dome.
- Gaze and pinch cannot be scripted via XCUITest. Apple's own mapping in the simulator is click = tap, click-and-hold = pinch-and-hold. Host-level mouse clicks on the Simulator window (osascript or CGEvent) are a possible fallback, unverified on visionOS here.

## Comparison table

Legend: Y = documented/verified, N = not supported or documented iOS-only, ? = unverified.

| Tool | Latest version seen | visionOS taps/input | visionOS UI hierarchy | visionOS screenshot | Notes |
|---|---|---|---|---|---|
| XcodeBuildMCP (getsentry; renamed MobileBuildMCP at 2.7.1) | 2.7.1 (2026-09-23); user has 2.3.2 | N (via AXe; confirmed no-op locally). 2.7.0 added Xcode 27 Device Hub UI automation, visionOS unknown | N/? (AXe `describe-ui` errors locally) | Y (simctl-based, works for any simulator) | Build/run/log/test tools platform-agnostic incl. visionOS since 1.9/1.10; `build_device` for visionOS in 2.5.0. No visionOS-titled issues found; 4 issues match "visionOS" body text, all closed and unrelated (setup wizard, clean). |
| AXe (cameroncooke) | 1.7.0 bundled in XcodeBuildMCP 2.5.2; user has 1.2.1 | N: README says iOS sims and connected iPhones/iPads only; no visionOS mention | N | Y (`screenshot` is simctl-like, untested for visionOS) | No issues matching visionOS/xrOS/Vision Pro found. Requires Xcode 26 or 27. Built on idb frameworks. |
| mobile-mcp (mobile-next) | npm `@mobilenext/mobile-mcp@latest`, 34 tools | N (iOS sim/device, Android only) | N | ? | No visionOS/xrOS issues found by GitHub search. |
| ios-simulator-mcp (joshuayoes) | 17 tools; uses idb | N/? (idb based; no visionOS mention) | N/? (`ui_describe_all` via idb) | Y likely (simctl) | No issues found mentioning visionOS. |
| ios-simulator-mcp (whitesmith / InditexTech idb variant) | not checked in depth | ? | ? | ? | Same idb dependency; no visionOS issues found. |
| simdrive (PyPI) | 1.0.0b14 (2026-09-21) | N (iOS only documented) | N | ? | 36 tools, annotated screenshots, perf tools (`perf`, `memory`), replay. Elastic License 2.0. Interesting perf tooling but iOS-only. |
| idb (facebook) | README: macOS 15+, Xcode 26+ | ? No visionOS/xrOS mention found in docs | ? | ? | Could not search issues (GitHub rate limit hit). Treat as unsupported. |
| Appium XCUITest driver | 11.x docs seen | N (2023 maintainer reply: no visionOS support, no plans) | N | N | Docs overview table might list visionOS; could not render checkmarks or fetch current page. Unresolved, likely stale answer from 2023. |
| Maestro | 2.x | N (docs list Android + iOS sim) | N | N | No visionOS in supported platforms. |
| kaeawc/auto-mobile (MCP) | no tagged release; main 2026-11 | Y (window apps): `tapOn` by text/id, `sendKeys` via XCUITest runner, merged PR #17128 (2026-11-05) | Y (`observe`, 32 elements incl. ornament in spike) | Y (simctl) | Spike #16851 on visionOS 26.5 / Xcode 26.6. Immersive, volumes, window move, gaze: not supported. Install: brew `kaeawc/tap/auto-mobile` or Claude Code plugin. Very new and fast moving. |
| serve-sim (Evan Bacon) | n/a | N (iOS/iPad/Watch/Duo only) | N | Y (framebuffer via simctl io) | Streams sim to browser, `ax`, `tap`, `record`. Xcode 27 input needs Device Hub frontmost. No visionOS. |
| Seiro MCP (karad) | n/a | N (build workflow only) | N | ? | visionOS build/diagnostic workflows targeting Vision Pro sim; page not fully read (403). |
| Xcode MCP bridge (`xcrun mcpbridge`, Xcode 26.3+) | Xcode 26.3 | N: a skill author reports its device-interaction tools refuse visionOS sessions | ? | Previews only | `claude mcp add --transport stdio xcode -- xcrun mcpbridge`. ~20 tools; build, previews, docs. |
| Raw XCUITest + simctl | Xcode 26.x | Y for window UI (tap, typeText); N for gaze/pinch/drag | Y (full tree, incl. ornaments) | Y via simctl only; `XCUIScreen` = 1x1 | Field-verified (auto-mobile spike; Jelly-Shark PR #341, 84s run). ~38s per test launch. |
| Xcode Device Hub (Xcode 27) | Xcode 27 | Y manually (pointer/trackpad mapping); scripting not documented | n/a | capture via UI | Apple docs mention a command-line article (`devicectl`), which does not cover simulator tap. |
| Host click via osascript/CGEvent on Simulator window | n/a | ? plausible (click = tap per Apple) | N | simctl | Unverified on visionOS. Fragile (window must be frontmost, coordinate mapping). |
| Testa (valewnrt) | n/a | ? iOS only claimed | ? | ? | Claims real HID events; page was blocked (403). |

## Per-tool detail

### XcodeBuildMCP (getsentry/XcodeBuildMCP)
- Repo has ~6.5k stars, last pushed 2026-11-13. Release history: 2.5.0 to 2.5.2 (May 2026), 2.6.0 to 2.6.2 (June 2026), 2.7.0 (2026-07-23), 2.7.1 (2026-09-23). Staging builds are published daily. The 2.7.1 release renamed the project to MobileBuildMCP (npm package, binaries, env vars), so the `xcodebuildmcp` command may change.
- visionOS in changelog: 1.9.0/1.10.0 made simulator and device tools platform-agnostic; 2.5.0 added visionOS to `build_device` and the setup wizard; 2.7.0 fixed simulator selection for projects supporting both iOS and visionOS.
- UI automation is AXe-based since 1.5.0 (2025-06-01). 2.6.0 added element refs, `wait_for_ui`, `batch`, `drag`. 2.7.0 added Xcode 27 Device Hub simulator UI automation.
- GitHub search for "visionOS" in the repo yields 19 results, none with visionOS in the title. No bug report about visionOS UI automation exists. This could be a good place to file one.
- Upgrade from 2.3.2 to 2.7.x may be worthwhile; whether it fixes visionOS taps is unverified.

### AXe (cameroncooke/AXe)
- README describes iOS simulators and connected iPhones/iPads, and lists `describe-ui`, `tap`, `swipe`, `touch`, `screenshot`, `record-video`, `batch`, `serve`. Needs Xcode 26 or 27. Every command requires `--udid`.
- No issues for visionOS, xrOS, Vision Pro. Its touch injection path is the iOS HID path, which is why taps silently succeed with no effect on visionOS.

### mobile-mcp, ios-simulator-mcp, idb
- All three are iOS/Android only in their docs. ios-simulator-mcp depends on idb_companion. facebook/idb docs never mention visionOS or xrOS (not exhaustively verified because issue search was rate limited).

### simdrive
- Good model of the feature set that would be ideal (observe with annotated screenshots, perf, perf_compare, memory, record/replay), but iOS only. Pre-release 1.0.0b14.

### Appium and Maestro
- Appium: a 2023 forum reply from a maintainer says XCUITest driver does not support visionOS and no plans exist. The linked GitHub issue was closed as unrelated. Current docs platform table not verified.
- Maestro: docs list Android and iOS simulators only.

### kaeawc/auto-mobile
- Issue #16851 (opened and closed 2026-11-04): probe on `Apple-Vision-Pro-4K` simulator, visionOS 26.5, Xcode 26.6. Host runs `xcodebuild build-for-testing` then `test-without-building` and talks to the runner over a loopback socket.
- Results: launch OK (~38s per test); hierarchy OK (32 elements, ornament found); tap on window and ornament buttons OK; `typeText` OK; window move not shown; gaze/pinch/drag none; `XCUIScreen` 1x1; `simctl io screenshot` OK (3840 px); immersive-space button tap completes but content was empty so visibility unknown; volumes not tried.
- PR #17128 (merged 2026-11-05) adds `observe`, `tapOn`, `sendKeys` for visionOS; everything else fails closed. Follow-ups #17166, #17182, #17517, #17762 merged. Author-reported verification only.
- Capability doc in repo: `docs/design-docs/plat/visionos/xcuitest-capabilities.md`.

### Other field reports
- jlipworth/Labstream PR #438: visionOS XCUITest lane for screenshot capture.
- axeslasher/Jelly-Shark PR #341: Claude Agent skill `sim-ui-check` drives visionOS via XCUITest (`UICheckTemplateVision.swift`) and takes screenshots with simctl; Xcode MCP device tools refused visionOS; hidden tab bar quirks; simulator can wedge in "Booted" state; 5s screenshot cap.

## Implications for Liminal

1. Add a small UI-test target (visionOS) that taps the control window by accessibility identifier. Drive it from Claude Code with `xcodebuild test-without-building`. Expect roughly 40s of startup per run. Alternatively, keep a long-running runner and talk over a socket as auto-mobile does.
2. Use `xcrun simctl io <udid> screenshot` for all images (already verified). The dome rendering will be captured as part of the full-frame screenshot if the immersive space is open.
3. FPS: simdrive-style perf tools do not apply; continue with the app's `fps=` PERF log line via `simctl spawn log stream`.
4. Test whether an XCUITest tap on "Enter dome" succeeds in opening the ImmersiveSpace. auto-mobile saw the tap complete but could not confirm content.
5. Consider evaluating auto-mobile directly (`brew install kaeawc/tap/auto-mobile`) before writing our own runner. Not installed per instructions.
6. Optionally upgrade XcodeBuildMCP and retest `snapshot_ui`/`tap` on visionOS; low probability of success.

## Uncertain / unverified

- GitHub issue searches for facebook/idb, Appium, Maestro and several others were blocked by the shared API rate limit; treat "no visionOS issues" as partial.
- Whether XcodeBuildMCP 2.7.x Device Hub UI automation works on visionOS.
- Xcode 27 version requirements for Device Hub were not stated in Apple docs fetched.
- Seiro MCP, Testa, and simctl-via-CGEvent clicks were not directly examined.
- Machine reports Xcode 26.3, so Xcode 27 features may not be available.

## Sources

- https://github.com/getsentry/XcodeBuildMCP
- https://raw.githubusercontent.com/getsentry/XcodeBuildMCP/main/CHANGELOG.md
- https://github.com/getsentry/XcodeBuildMCP/issues?q=visionOS
- https://raw.githubusercontent.com/cameroncooke/AXe/main/README.md
- https://raw.githubusercontent.com/mobile-next/mobile-mcp/main/README.md
- https://raw.githubusercontent.com/joshuayoes/ios-simulator-mcp/main/README.md
- https://pypi.org/project/simdrive/
- https://github.com/kaeawc/auto-mobile
- https://github.com/kaeawc/auto-mobile/issues/16851
- https://github.com/kaeawc/auto-mobile/pull/16883
- https://github.com/kaeawc/auto-mobile/pull/17128
- https://github.com/axeslasher/Jelly-Shark/pull/341
- https://github.com/jlipworth/Labstream/pull/438
- https://github.com/evanbacon/serve-sim
- https://discuss.appium.io/t/is-it-possible-to-automate-apple-vision-pro/40050
- https://docs.maestro.dev/platform-support/supported-platforms
- https://sosumi.ai/documentation/xcode/interacting-with-your-visionos-app-in-device-hub
- https://sosumi.ai/documentation/xcode/device-hub
- https://sosumi.ai/documentation/xcode/interacting-with-devices-using-the-command-line
- https://mcpservers.org/servers/karad/seiro-mcp
- https://dev.to/arshtechpro/xcode-263-use-ai-agents-from-cursor-claude-code-beyond-4dmi
- https://www.macrumors.com/2026/02/03/xcode-26-3-agentic-coding/
- https://fbidb.io/docs/idb/overview
