# 06 - Local Environment Inventory (read-only)

Date: 2026-11-14. Machine: Darwin 27.2.0, Xcode 26.3 (17C519). Nothing was installed or modified; no apps launched.

## Summary
- Everything needed for build/install/launch/screenshot/log/video exists locally.
- Missing: a working UI-input path to the visionOS simulator. `simctl` has no tap/input command; AXe (the XcodeBuildMCP backend) does not work on visionOS (previously verified).
- Promising untested local candidates: `xcrun mcpbridge` (Xcode 26.3 MCP bridge), XCUITest via the existing `LiminalUITests` target, `peekaboo` 3.0.0-beta3 (macOS GUI automation of the Simulator window, i.e. click via screen coordinates), and `xctrace` (RealityKit Frames, Metal Application, Hitches, Core Animation FPS instruments are listed).

## Tooling versions
| Tool | Result |
|---|---|
| xcodebuildmcp | 2.3.2 (/opt/homebrew/bin) |
| axe | v1.2.1 (/opt/homebrew/bin) |
| peekaboo | brew installed, 3.0.0-beta3 (built 2025-12-29) |
| node / npx | v24.13.1 / 11.8.0 |
| python3 | 3.11.13 |
| xcodebuild | Xcode 26.3, build 17C519 |
| devicectl | 506.7 |
| brew: idb, maestro, appium, cliclick | NOT installed (only axe, peekaboo, xcodebuildmcp matched) |

## XcodeBuildMCP 2.3.2 CLI workflows
`xcodebuildmcp --help` lists: mcp, init, setup, tools, coverage, debugging, device, logging, macos, project-discovery, project-scaffolding, simulator ("iOS Simulator Development"), simulator-management, swift-package, ui-automation, utilities, xcode-ide, daemon.
- No visionOS-named workflow in the help text (grep for "vision" in `tools` output returned nothing).
- ui-automation commands: tap, touch, long-press, swipe, gesture, button, key-press, key-sequence, type-text, screenshot, snapshot-ui (all AXe-backed; AXe is known not to work on visionOS sim).
- xcode-ide: `list-tools`, `call-tool` - proxies to a remote Xcode IDE MCP (i.e. the Xcode 26.3 mcpbridge service). Described as: SwiftUI previews image capture, code snippet execution, issue navigator/build logs, window/tab context. Requires Xcode running; NOT tested (would be worth testing, but does not drive the simulator UI).
- `init` installs an agent skill.

## Xcode 26.3 MCP
- Found: /Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge (also resolvable as `xcrun mcpbridge`).
- Help: STDIO bridge between MCP clients and Xcode's MCP tool service; JSON-RPC 2.0 on stdin/stdout. Env vars: MCP_XCODE_PID (target Xcode instance; auto-detect if exactly one running, else xcode-select), MCP_XCODE_SESSION_ID (UUID).
- Requires Xcode running with the MCP service enabled (Xcode Settings; unverified here). Its tool list (build, test, preview render, etc.) was not enumerated - next researcher/step: run `xcodebuildmcp xcode-ide list-tools` with Xcode open. Whether it exposes simulator UI input is unknown/unlikely.

## simctl capabilities
Subcommands relevant: appinfo, diagnose, io, keychain, launch, listapps, location, openurl, pbcopy, privacy, push, runtime, spawn, status_bar, terminate, ui.
- `simctl io`: enumerate, poll, recordVideo (--codec h264|hevc, --display, --mask, --force; stop with SIGINT), screenshot (png/tiff/bmp/gif/jpeg, "-" for stdout).
- `simctl ui`: appearance (light/dark) etc. NO touch/tap/keyboard input command exists.
- `simctl privacy`, `openurl` (custom URL scheme/deep link can be a hook to toggle app state without UI taps), `spawn` (run processes in sim, used for log stream).
- Booted: Apple Vision Pro 19A53057-4A6A-47EE-A627-33A845C5E7FF (visionOS 26.2). Runtimes also listed for visionOS 2.3/2.4/2.5 (device-less).

## xctrace (performance)
Templates present include: Animation Hitches, Core Animation (via instruments), Game Performance, Game Performance Overview, Metal System Trace, RealityKit Trace, SwiftUI, Time Profiler, CPU Profiler, Power Profiler, Allocations, Logging.
Instruments list includes: Core Animation FPS, GPU, Hitches, Metal Application, Metal GPU Counters, Metal Performance Overview, Metal Resource Events, RealityKit Frames, RealityKit Metrics.
Devices: physical Apple Vision Pro (27.2.1, 00008112-001430AC34D8A01E) is visible/paired (so on-device profiling via xctrace is plausible); also iPhone and Watch; many iOS 26.2 sims plus "Apple Vision Pro Simulator (26.2)". Simulator traces are limited vs device (GPU counters mostly device-only; unverified for visionOS sim).
Practical FPS route: the app's own "fps=" PERF log line (already verified) for sim; xctrace RealityKit Trace/Metal System Trace against the real device.

## Claude Code MCP config (~/.claude.json, names/commands only)
- global: playwright (npx @playwright/mcp@latest)
- Per-project entries elsewhere: ryg (script), emojistatus (sse localhost), context7 (npx), xcodebuildmcp via smithery (reachy project), XcodeBuildMCP (`xcodebuildmcp mcp`, BirdWhere), mobile-mcp (npx @mobilenext/mobile-mcp@latest; in dailydefense, BirdWhere, FishLogger).
- None configured for Liminal. Note mobile-mcp is already used on other projects (iOS sim/device); its visionOS support is for other researchers to determine.

## Liminal project
- Schemes: Liminal, Liminal-Dev, SoundpipeAudioKit. Targets: Liminal, LiminalTests, LiminalUITests. Configs Debug/Release.
- Packages: AudioKit 5.6.5, SoundpipeAudioKit 5.7.3, KissFFT 1.0.0, Tonic 2.1.0, ShaderGraphCoder 2.0.0, AudioKitEX 5.6.2.
- LiminalUITests: only Xcode template stubs (LiminalUITests.swift 41 lines with testExample = `XCUIApplication().launch()` and testLaunchPerformance; LiminalUITestsLaunchTests.swift 33 lines). No real UI tests, no accessibility identifiers audited.
- Idea: XCUITest on visionOS sim runs through XCTest's own accessibility channel (not AXe/HID), so it may work where AXe fails - worth testing: write tests that tap Play/Enter dome/Spatial, use XCTAttachment screenshots, and `measure(metrics:)`. Needs `-destination 'platform=visionOS Simulator,name=Apple Vision Pro'`. Unverified.

## Candidate list (local)
1. XCUITest via xcodebuild test (likely best path; unverified on visionOS immersive space).
2. peekaboo 3.0.0-beta3 driving the macOS Simulator window (screen-level clicks; gaze/pinch mapping on visionOS sim is mouse-click based so plausible; unverified).
3. xcodebuildmcp xcode-ide / mcpbridge (build/preview, not UI input).
4. Deep-link/launch-argument debug hooks (`simctl openurl` / `launch` args) to toggle effects without taps.
5. xctrace for device perf; app PERF log for sim.

## Sources
- https://sosumi.ai/documentation/xcode/giving-external-agents-access-to-xcode (Xcode MCP agent access; not fetched in this angle, listed for follow-up)
- Local command outputs: `xcodebuildmcp --help`, `xcrun mcpbridge --help`, `xcrun simctl help`, `xcrun simctl io help`, `xcrun xctrace list templates|devices|instruments`, `xcodebuild -list`
