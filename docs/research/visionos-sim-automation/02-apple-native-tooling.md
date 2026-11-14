# Apple-native tooling for automating the visionOS Simulator

Researched 2026-11-14. Local environment: Xcode 26.3 (17C519), macOS 27.2.1, visionOS 26.2 simulator.
Confidence tags: [VERIFIED-LOCAL] ran here; [DOC] Apple docs; [3P] third-party blog/forum; [UNVERIFIED].

## TL;DR

1. XCUITest does NOT work for native visionOS apps. Apple's XCUIAutomation docs: "UI testing isn't available to apps you build using the visionOS SDK." [DOC] Dead end for Liminal (it also cannot reach into immersive content).
2. Xcode 26.3 `xcrun mcpbridge` exists locally [VERIFIED-LOCAL] and exposes ~20 tools: build, tests, previews, file ops, docs search. It has NO simulator input (tap/click) and NO simulator screenshot tool. [3P] Useful for build/test/diagnostics only; `RenderPreview` renders SwiftUI previews, not the running app.
3. Xcode 27 (released 2026-09-14, build 27A266a; 27.1 in Oct) grew mcpbridge from ~21 to 48 tools, including `DeviceInteractionStartSession / EndSession / InstallAndRun / Synthesize` (taps, swipes, text, hardware buttons; returns screenshot + UI hierarchy), plus `RunProject`, `GetConsoleOutput`. [3P: redalemeden.com] Whether this works on the visionOS simulator is UNVERIFIED. It is the most promising "official" path; it requires upgrading to Xcode 27 (needs macOS Tahoe 26.6+; this machine is on 27.2.1, so fine).
4. Xcode 27 replaces the Simulator app with "Device Hub", which has documented visionOS interaction (click = tap, click-and-hold = pinch-hold, drag, keyboard nav). [DOC] Its CLI companion is `devicectl` (which can launch on simulators with env vars) plus `simctl`.
5. `simctl` (26.3) has no input injection at all. Useful: `io screenshot`, `io recordVideo`, `launch` (args + `SIMCTL_CHILD_*` env), `openurl`, `spawn`, `privacy`, `status_bar`, `ui appearance`. [VERIFIED-LOCAL help output]
6. Best immediate, zero-install pattern: make the app drive itself via launch arguments / env vars / URL scheme (auto Play, auto open immersive space, set param values), then use `simctl launch` + `io screenshot` + `log stream` for FPS. This sidesteps input injection. Caveat: `openImmersiveSpace` on visionOS must be called from a SwiftUI scene context (e.g. `.task` in the window view), which is fine.

## 1. XCUITest on visionOS

- Apple XCUIAutomation page states UI testing is unavailable for apps built with the visionOS SDK; only compatible iPad/iPhone apps running on visionOS can be UI tested. https://developer.apple.com/documentation/xcuiautomation (via sosumi.ai) [DOC]
- Appium forum: XCUITest driver does not support visionOS, no plans. [3P, old] A Tuist issue claims otherwise but is unverified. [3P]
- Repo state: `LiminalUITests/` contains only the Xcode template (`testExample`, launch tests), no real automation.
- Even where XCUITest works, immersive content has no accessibility tree; gaze/hand input cannot be simulated. [3P: helpmetest.com]
- Conclusion: do not invest. Single-test CLI form for reference (works on macOS target only): `xcodebuild test -scheme Liminal -destination 'platform=macOS' -only-testing:LiminalUITests/LiminalUITests/testExample`.
- XCTest unit tests (logic, `EffectsUniformsComputer`) do run on visionOS simulator: `xcodebuild test -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -only-testing:LiminalTests/...`.

## 2. Xcode MCP bridge

### Xcode 26.3 (installed)
- `xcrun mcpbridge` present at /Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge [VERIFIED-LOCAL]. STDIO JSON-RPC bridge; env `MCP_XCODE_PID` selects which Xcode instance; `MCP_XCODE_SESSION_ID` optional. [VERIFIED-LOCAL --help]
- Connect: `claude mcp add --transport stdio xcode -- xcrun mcpbridge`. Requires Xcode running with the project open, and Xcode > Settings > Intelligence > Model Context Protocol > "Xcode Tools" on. Xcode shows a connection indicator/permission prompt. [3P: dev.to/arshtechpro]
- Tools (20, 26.3): XcodeRead/Write/Update/Glob/Grep/LS/MakeDir/RM/MV, BuildProject, GetBuildLog, RunAllTests, RunSomeTests, GetTestList, XcodeListNavigatorIssues, XcodeRefreshCodeIssuesInFile, ExecuteSnippet, RenderPreview, DocumentationSearch, XcodeListWindows. [3P]
- Known issue: returns `content` but not `structuredContent`; Cursor rejects, Claude Code and Codex tolerate. [3P]
- Gap: no run-on-simulator, no tap, no screenshot of the running app. Not sufficient for our goal. I did not start Xcode or invoke it (brief said not to touch things).

### Xcode 27 (released 2026-09-14; 27.1 RC Oct 5)
- mcpbridge 21 -> 48 tools. New: RunProject, StopProject, InvokeDebuggerCommand, GetConsoleOutput, RunCodeSnippet; DeviceInteractionStartSession, DeviceInteractionEndSession, DeviceInteractionInstallAndRun, DeviceInteractionSynthesize; crash/field-performance tools; build settings; schemes/run destinations (XcodeSwitchRunDestination); GetCodeCoverage (27.2 beta). [3P: https://redalemeden.com/derived-data/2026/what-new-in-xcode-27-mcp-bridge/]
- `DeviceInteractionSynthesize`: taps, swipes, text, hardware buttons, orientation; returns screenshot + UI hierarchy. Advice: base coordinates on hierarchy dump, not screenshot. Session is costly, end it when done. [3P]
- Xcode 27 also ships Apple "agent skills" incl. a `device-interaction` skill, exportable with `xcrun agent skills export --output-dir <dir>` (read its SKILL.md to learn the exact mechanism). [3P: dev.to/arshtechpro WWDC26 post] `xcrun agent` does not exist on 26.3 [VERIFIED-LOCAL].
- Access control: Settings > Intelligence > "Allow external agents to use Xcode tools"; ACP (Agent Client Protocol) governs agent connections. [3P]
- UNVERIFIED: visionOS support in DeviceInteraction*. A search for it found nothing. Hierarchy dump on visionOS would likely only show the window (control panel), not immersive content, but screenshots may work. Needs a hands-on test after installing Xcode 27.
- Requirements: macOS Tahoe 26.6+, Apple silicon. Breaking changes include ld64 removal, PreviewProvider deprecation, `@State` init source break. visionOS 27.0 simulator has reported bugs (multi-part MeshResource crash, HLG purple cast), which could affect a RealityKit dome app; visionOS 26.5 runtime still usable under Xcode 27. [3P: blakecrosley.com, Apple forums]

## 3. Device Hub (Xcode 27) and devicectl

- Device Hub replaces Simulator.app; auto-launches on Run to a simulator. visionOS interaction: select "interact with visionOS content"; mouse = gaze; click = tap; click-and-hold = pinch-hold; drag = pinch-drag; Shift-drag = forward/back; WASD/arrows/QE move camera; Home button; Control Center; Reset Camera; Simulated Scenes. Immersive spaces not explicitly addressed. Physical devices cannot be controlled. https://developer.apple.com/documentation/xcode/interacting-with-your-visionos-app-in-device-hub [DOC]
- Screenshots in Device Hub: https://developer.apple.com/documentation/xcode/capturing-screenshots-and-videos-from-devices (note: visionOS simulator captures may differ in size/aspect from device).
- CLI: `devicectl` ("without running Xcode"); `devicectl device process launch --device <id> <bundle-id> --environment-variables ...` works for simulators and physical devices; `--json-output` for scripting. Simulators booted via `xcrun simctl`. https://developer.apple.com/documentation/xcode/interacting-with-devices-using-the-command-line [DOC]. No documented devicectl input-injection command. WWDC26 session 260 covers it. https://developer.apple.com/videos/play/wwdc2026/260
- Xcode 27 adds `simctl reboot`. [3P]

## 4. simctl capabilities (Xcode 26.3, verified from local help)

| Command | Use for Liminal |
|---|---|
| `simctl io <udid> screenshot [--type=png] <file or ->` | Frame capture (already works, 3840x2160). `-` writes to stdout. |
| `simctl io <udid> recordVideo [--codec h264/hevc] <file>` | Video; SIGINT to stop. Can extract frames with ffmpeg for visual diffing/fps estimate. Display flags are iOS/tvOS/watchOS-oriented; visionOS behavior with recordVideo is UNVERIFIED. |
| `simctl launch --console / --stdout --terminate-running-process <udid> <bundle> [args...]` | Pass launch arguments; env via `SIMCTL_CHILD_FOO=bar` in caller env. |
| `simctl openurl <udid> <url>` | Deliver URL scheme / universal link to app. |
| `simctl spawn <udid> log stream --predicate ...` | FPS PERF line (already works). |
| `simctl privacy`, `status_bar`, `ui appearance`, `push`, `keychain`, `pbcopy/pbpaste`, `addmedia`, `location` | Setup only; no input. |
| `simctl io enumerate/poll` | Lists IO ports; no HID injection. |

No `simctl` command exists for tap/click/keypress/gesture. Input must come from Xcode 27 DeviceInteraction, a GUI-level driver (CGEvent/AppleScript/computer-use on the Simulator window; other angles' reports), or in-app hooks.

## 5. Launch args / URL schemes / env as the automation path (recommended now)

- Current code: `EnvironmentService.swift` already reads `ProcessInfo.processInfo.environment`. No `onOpenURL`, no launch-argument handling found. `ControlsView.swift` calls `openImmersiveSpace(id: "liminalDome")` (line 73) and `"liminalDiorama"` (line 99) from button actions.
- Proposal (not implemented; brief forbids source edits): add a DEBUG-only test hook that reads `-autoPlay`, `-autoEnterDome`, `-effect <name>=<value>`, `-perfDumpSeconds N` (via `CommandLine.arguments`/`UserDefaults` argument domain, or `SIMCTL_CHILD_LIMINAL_*` env) and a `liminal://` URL scheme (`onOpenURL`) with commands like `liminal://enter-dome`, `liminal://set?param=value`. Trigger the same `openImmersiveSpace` call from the root view's `.task`.
- Workflow: `xcodebuild build` -> `simctl install` -> `SIMCTL_CHILD_LIMINAL_AUTOENTER=1 simctl launch --terminate-running-process` -> sleep -> `simctl io screenshot` -> read `fps=` from `log stream`. Per-effect verification = relaunch with different args or `simctl openurl` at runtime.
- Caveats: immersive-space open on visionOS may need the user-visible window scene to be active; the system may show a first-run permission prompt (cannot be dismissed without input). If a prompt appears, test with DeviceInteraction (Xcode 27) or a GUI-level click.
- A debug overlay in-app (FPS, frame-time, effect state) rendered into the dome would also appear in screenshots.

## Recommendation

1. Now (no installs): implement the launch-arg/URL-scheme test hooks; verify via simctl screenshot + log stream. Covers most "verify my work" needs.
2. Next: install Xcode 27 side by side (do not replace 26.3 until validated; note visionOS 27 sim bugs), export the `device-interaction` skill, test `DeviceInteractionSynthesize` against the visionOS sim. If it works, `claude mcp add --transport stdio xcode -- xcrun mcpbridge` gives native click/screenshot.
3. Skip XCUITest; skip Xcode 26.3 mcpbridge except for build/test convenience.

## Sources

- https://developer.apple.com/documentation/xcuiautomation (visionOS UI testing unavailable)
- https://developer.apple.com/documentation/xcode/interacting-with-your-visionos-app-in-device-hub
- https://developer.apple.com/documentation/xcode/interacting-with-devices-using-the-command-line
- https://developer.apple.com/documentation/xcode/capturing-screenshots-and-videos-from-devices
- https://developer.apple.com/documentation/xcode/device-hub
- https://developer.apple.com/videos/play/wwdc2026/260 (Get the most out of Device Hub)
- https://developer.apple.com/videos/play/wwdc2026/259 (agents in Xcode; no simulator detail)
- https://dev.to/arshtechpro/xcode-263-use-ai-agents-from-cursor-claude-code-beyond-4dmi (26.3 mcpbridge tools, claude mcp add)
- https://redalemeden.com/derived-data/2026/what-new-in-xcode-27-mcp-bridge/ (Xcode 27 tool list)
- https://dev.to/arshtechpro/wwdc-2026-xcode-27-ships-with-apples-own-agent-skills-what-they-are-and-how-to-use-them-3g2
- https://blakecrosley.com/blog/xcode-27-release (27.0 release, requirements, breakages)
- https://www.mactech.com/2026/09/10/app-store-submissions-now-open-for-the-latest-os-releases/
- https://infoq.com/news/2026/02/xcode-26-3-agentic-coding
- https://swiftwithmajid.com/2026/02/10/agentic-coding-in-xcode/
- https://helpmetest.com/blog/apple-vision-pro-testing-guide/
- https://discuss.appium.io/t/is-it-possible-to-automate-apple-vision-pro/40050
- https://developer.apple.com/forums/thread/767490 and https://developer.apple.com/forums/thread/839939 (Xcode 27 / visionOS sim issues)
- Local: `xcrun mcpbridge --help`, `xcrun simctl help`, `xcrun simctl io help` on Xcode 26.3.
