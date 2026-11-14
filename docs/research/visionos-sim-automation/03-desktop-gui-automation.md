# 03 - Desktop GUI Automation of Simulator.app (visionOS)

Researched 2026-11-14. Angle: drive the Simulator.app window as a Mac GUI (screen-level clicks) rather than via simulator-internal APIs.

Status legend: VERIFIED = checked locally or in primary docs; REPORTED = third party / secondary; UNTESTED = plausible but not exercised (brief forbade clicking).

## TL;DR

- The visionOS Simulator is designed to be driven by a Mac mouse: click = gaze+pinch tap. So screen-level synthetic clicks are the "native" input path, and this is the best fallback now that AXe fails. (Apple docs, VERIFIED.)
- Peekaboo is ALREADY installed locally (`/opt/homebrew/bin/peekaboo`, 3.0.0-beta3 built 2025-12-29), with Screen Recording and Accessibility both Granted (VERIFIED locally). It can list the Simulator window, capture it, and issue click/drag/hotkey/scroll commands by coordinate. Upstream is at 4.9.8 (repo page), so the local build is old; `brew upgrade` recommended (not done, per brief).
- Claude Code CLI has a built-in `computer-use` MCP server (research preview, macOS, Pro/Max/Ultra, v2.1.85+ reported). Anthropic's own docs name the iOS Simulator as a target use case. It is the zero-install option but is slow, hides other apps, and downscales screenshots.
- No `simctl` facility exists to send pointer/touch events (VERIFIED: `simctl io` only has enumerate/poll/recordVideo/screenshot; `simctl ui` only appearance/content size etc.).
- Key uncertainty: whether synthetic CGEvent clicks (Peekaboo/cliclick) actually register as pinch taps on SwiftUI content inside the visionOS canvas. Secondary reports say CGEvents sometimes hit simulator chrome but not content. UNTESTED. This needs a one-shot experiment before committing.
- Recommended experiment order: (1) Peekaboo `click` with coordinates on the Play button in the Simulator window; (2) if no effect, try Claude computer-use; (3) if still no effect, fall back to in-app test hooks / XCUITest / debug launch arguments.

## 1. How visionOS Simulator maps Mac input

Source: Apple, "Interacting with your visionOS app in Device Hub" (via sosumi.ai). Note this doc references Device Hub (Xcode 27 era) but the mapping matches the classic Simulator.app visionOS behavior.

Modes (segmented control at bottom of canvas):
- Select to interact: pointer position = where eyes look (hover); click/drag/swipe available.
- Drag to pan camera (left/right/up/down).
- Drag to dolly camera (forward/back).
- Drag to tilt camera (plain drag changes view angle; Control-drag does it from any mode).

Gesture map (interact mode):

| Visionos gesture | Mac input |
|---|---|
| Tap | Click |
| Pinch and hold | Click and hold |
| Pinch and drag L/R/U/D | Drag |
| Pinch and drag forward/back | Shift-drag up/down |
| Swipe | Click and swipe |

Implications for Liminal sliders: a slider is a pinch-and-drag, so a synthetic `mouseDown, mouseDragged..., mouseUp` sequence with realistic intermediate points is needed, not a single jump. Hover (gaze) must precede the click for gaze-targeted controls; a tool that teleports the cursor and clicks in the same instant may fail, so insert a short move + ~100-300 ms dwell before the press. (Inference, UNTESTED.)

Device controls: Home button bottom-left of canvas (or Controls > Home); Control Center via indicator top-center; volume via Device > Sound.

Moving the viewpoint (needed to look at the dome):

| Move | Keyboard | Trackpad |
|---|---|---|
| Forward | W / Up | pinch apart |
| Back | S / Down | pinch together |
| Left / Right | A,D / Left,Right | scroll |
| Up / Down | E / Q | scroll up/down |

- Reset Camera button: bottom-right of canvas.
- Game controller also supported (sticks, R2/L2).
- Capture Pointer (bottom-right button) sends pointer input to the device and stops it moving the camera. Keyboard Capture: Device > Keyboard > Keyboard Capture. Press Escape to release. This matters for automation: while captured, scrolling/W-A-S-D will not move the camera, and Esc releases.
- Simulated Scenes (room layouts/lighting) selectable in the Settings inspector; useful for deterministic visual comparison. Passthrough background vs. scene affects screenshots of an immersive dome.

Not documented by Apple (gaps): keyboard shortcuts for Home/Control Center, pointer sensitivity, mouse button mapping beyond left click, how gaze is visualized.

## 2. Is there a simctl pointer facility? No.

Local check (Xcode 26.3):
- `xcrun simctl help` top-level verbs relevant: io, keychain, location, openurl, push, spawn, status_bar, ui. No tap/touch/click/key verbs.
- `simctl io <udid> enumerate` lists ports; the visionOS sim exposes `com.apple.framebuffer.display` at 3840x2160 BGRA, plus a capture-service port. These are output (display) ports only; no HID input port exposed.
- `simctl io` ops: enumerate, poll, recordVideo (hevc/h264), screenshot. Useful for FPS via video analysis (see section 7).
- `simctl ui` handles appearance/content size etc., not input.
- Private input route is via SimulatorKit / CoreSimulator HID (what idb and AXe use). That is exactly the path that AXe fails on for visionOS, per the shared context. Not part of this angle.

## 3. Candidate GUI-level tools

### 3.1 Peekaboo (steipete / now github.com/openclaw/Peekaboo)
- Installed locally: 3.0.0-beta3 (built 2025-12-29). Repo README shows 4.9.8 as latest and install via `brew install openclaw/tap/peekaboo` or `npx -y @steipete/peekaboo` (MCP, Node 22+). Search results disagree on tap name (steipete/tap vs openclaw/tap); repo appears to have moved orgs. Release date for 4.9.8 not confirmed.
- VERIFIED locally: `peekaboo permissions` -> Screen Recording Granted, Accessibility Granted.
- VERIFIED locally: `peekaboo list windows --app Simulator` returns the visionOS window: "Apple Vision Pro - visionOS 26.2", ID 1446, position (31,43), size 1448x866 (points) on Built-in Display (1512x982 pt logical). Four 1512x33 untitled windows are menu-bar-related strips.
- Commands available: see, image, capture, click, drag, move, hotkey, press, type, scroll, swipe, window, menu, app, run (scripts), agent, bridge, daemon, learn. Also an MCP mode.
- Targeting: `--window-id` pins input to an exact window; README mentions background delivery and that app-only key chords need foreground consent. Agent/MCP runs reportedly apply a background-only policy requiring a fresh exact non-dialog snapshot (REPORTED from README; may not apply to plain CLI use).
- `see` builds a UI map from the accessibility tree. For Simulator.app the AX tree exposes the chrome (window, toolbar, maybe the whole device screen as a single AXGroup/image). SwiftUI controls inside the visionOS framebuffer are NOT expected to appear as AX elements of the Mac app (the content is a rendered stream). So element-ID clicks will not work for in-app buttons; coordinate clicks are required. UNTESTED but strongly expected; this is the same reason `axe describe-ui` struggles.
- Menu clicks (`peekaboo menu click`) are the reliable semantic path for Simulator menu items such as Device > Keyboard > Keyboard Capture, Controls > Home, File > Save Screenshot.
- Verdict: best-fit tool. Already installed and permitted. Test coordinate click first.

### 3.2 Claude Code built-in computer use (CLI)
- Source: code.claude.com/docs/en/computer-use (VERIFIED, fetched 2026-11-14). Research preview, macOS only, Pro/Max/Ultra plans, not Team/Enterprise, not with `-p` non-interactive mode, not third-party providers (Bedrock etc.). Third-party articles put the launch at 2026-03-23 and require Claude Code v2.1.85+ (REPORTED).
- Enable via `/mcp` -> `computer-use` -> Enable (per project). Grants Accessibility + Screen Recording to the terminal host app.
- Per-app approval each session (Simulator would be "full control" tier; browsers view-only; terminals/IDEs click-only).
- Hides all other apps while working; terminal excluded from screenshots; Esc aborts; one session holds a lock at a time.
- Screenshots auto-downscaled (example: 3456x2234 -> ~1372x887, no setting to change). Model clicks in downscaled space and the harness maps back; this is handled for you, which removes the coordinate mapping burden, but small controls may be hard to hit.
- Anthropic docs explicitly list "iOS Simulator" as a target and show a "Test a simulator flow" example. visionOS is not named; it is still the Simulator.app window, so expected to work at the same level as Peekaboo for pointer input, UNTESTED.
- Claude Code Desktop has a separate "iOS Simulator pane" (public beta, Desktop v1.24012.0+) that drives iOS simulators directly via simctl-style tooling without computer-use permissions. Docs say "iOS", "simulated iPhone or iPad"; no visionOS mention. Not applicable to CLI. Treat visionOS support as NOT confirmed.
- Cost/latency: each action is a screenshot round trip through the model; fine for smoke tests, poor for repeated sweeps.

### 3.3 cliclick
- Not installed (`which cliclick` empty). `brew install cliclick`. Pure CGEvent: `c:x,y` click, `dd:`/`dm:`/`du:` for down/move/up (drag), `w:ms` waits, `kp:`, `kd/ku` keys. Good primitive for drag sequences with waits. Coordinates are in global screen points (not pixels). Same CGEvent risk as Peekaboo.

### 3.4 AppleScript / System Events (osascript present)
- `tell application "System Events"` can click menu items and read the Simulator window frame (position/size), and `keystroke`/`key code` to Simulator. Cannot click arbitrary points without `cliclick`-style helpers (System Events `click at {x,y}` is unreliable and often a no-op for non-AX content). Useful for: menu item triggering (Device > Keyboard Capture, Home), getting window bounds for coordinate math, bringing Simulator frontmost.
- Reported (Apple forums): CGEvent keyboard posted via postToPid reached the simulator while mouse CGEvents hit chrome but not content; one thread says a CGEvent click did nothing even on the main display (REPORTED, not visionOS-specific).

### 3.5 Hammerspoon
- Not installed. Lua `hs.eventtap.leftClick/event.newMouseEvent` over CGEvent; adds an IPC CLI (`hs`). No advantage over cliclick/Peekaboo for this; skip unless a long-lived scripted daemon is wanted.

### 3.6 Other MCPs
- macOS-automator MCP (steipete) runs AppleScript/JXA; equivalent to 3.4. Other "mac-use" MCPs are thin wrappers over CGEvent + screenshots; no evidence found of visionOS-specific handling. Not individually evaluated; low priority.
- skillsmp "visionos-ui-automation" skill (studiomeije/visionos-codex-plugin) states coordinate-based touch/swipe is the wrong abstraction for spatial UI and recommends XCUITest or in-app test hooks (REPORTED, secondary).
- Apple forums: a two-handed gesture workaround stopped working in visionOS 26 simulator (REPORTED); rotate/scale gestures hard to register. Not relevant to Liminal's simple taps/sliders.

## 4. Coordinate mapping (screenshot pixels <-> screen points)

Known numbers from this machine:
- Built-in display logical size: 1512x982 points (Retina 2x => 3024x1964 px).
- Simulator window: origin (31,43), size 1448x866 points. This includes title bar and bottom control strip. The visionOS canvas inside has 16:9 aspect; the device framebuffer is 3840x2160.
- Two distinct images:
  - `simctl io screenshot` (3840x2160): device framebuffer, no window chrome. Pixels do NOT map directly to screen points because the canvas is scaled and offset inside the window.
  - Window/screen screenshot (Peekaboo `image`/`see`, or computer-use): includes chrome; pixel = point x backing scale (2.0).

Mapping formula for a click on a control seen in the `simctl` screenshot at (px, py):
1. Find canvas rect in screen points: canvas_origin = window_origin + (inset_left, titlebar_h); canvas_size = (w, w*9/16) approximately. Measure inset/titlebar by capturing a Peekaboo window screenshot once and locating the canvas edges (or by the AX frame of the content element if exposed).
2. screen_x = canvas_x + px * (canvas_w / 3840); screen_y = canvas_y + py * (canvas_h / 2160).
3. Pass screen_x/y (points) to cliclick or `peekaboo click --coords x,y`.
Safer alternative: take the screenshot of the window itself with Peekaboo (`peekaboo image --window-id 1446`), read positions in that image, divide by 2 for points, add window origin. Using one capture source for both finding and clicking avoids the canvas-offset math.

Caveats: window can be moved/scaled (Window > Physical Size / Point Accurate / Fit Screen; Simulator stores WindowScale in `com.apple.iphonesimulator` prefs). Re-query `peekaboo list windows` before every action batch. Display scaling changes between external monitors and built-in. The visionOS UI window is small inside a large 3D scene; the control window may only occupy a modest part of the canvas, so click precision of a few points matters; consider enlarging the Simulator window (`peekaboo window` resize) to improve target size.

## 5. Reliability assessment for clicking SwiftUI buttons

| Concern | Assessment |
|---|---|
| Does a mouse click map to tap? | Yes by Apple design, when in "Select to interact" mode (not camera pan/dolly mode). Must ensure mode is correct; a drag in camera mode moves the viewpoint instead. |
| Gaze requirement | Hover over target first; dwell briefly before pressing. |
| Synthetic CGEvents vs real HID | UNTESTED for visionOS. Simulator reads NSEvents from its window so CGEvent-posted events should arrive as normal mouse events (this is how computer-use works for iOS Sim per Anthropic docs). Some reports of content not responding. |
| Window must be frontmost/focused | Likely yes; first click may only focus the window. Click twice or focus first (`peekaboo app switch`). |
| Sliders | Need press, several incremental drag moves, release. |
| Immersive space | When dome is open the control window is still in the scene; camera may need Reset Camera to bring it into view; Home button dismisses. |
| Determinism | Moderate; hover/gaze timing and camera state add flake. Make a script that always: focus -> Reset Camera -> verify via screenshot -> act. |
| AX tree | SwiftUI elements inside the framebuffer are not visible to the Mac AX tree; verification must be visual (screenshot diff / OCR) or via app logs. |

Best verification loop for Liminal: action by GUI click, observation by app log (`log stream` PERF/fps line plus any state logs the app prints), and visuals by `simctl io screenshot`. Adding a DEBUG-only log line per button/slider action makes the GUI layer verifiable without OCR.

## 6. Experiments to run next (not run here; brief forbade clicking)

1. `peekaboo image --app Simulator --window-id 1446 --path /tmp/sim.png` and view it; locate Play button; compute points.
2. `peekaboo move x y` then wait 300 ms, `peekaboo click --coords x,y` (CLI flags to confirm via `peekaboo click --help`); check app log for a Play action.
3. If no effect: `brew install cliclick`, try `cliclick m:x,y w:300 dd:x,y w:80 du:x,y`.
4. If no effect: enable computer-use in `/mcp` and ask Claude to click Play in Simulator.
5. Menu-driven checks: `peekaboo menu click --app Simulator --path "Device > Keyboard > Keyboard Capture"` (flags to confirm), `peekaboo menu` for Controls > Home.
6. Slider drag test with `peekaboo drag` or cliclick dd/dm/du with 10+ intermediate points.

## 7. FPS / performance from the GUI layer

- In-app PERF log (`fps=` line) via `simctl spawn log stream` is the primary metric (already working).
- `simctl io recordVideo` (hevc/h264, SIGINT to stop) can capture the display; frame cadence can be analyzed with ffmpeg (installed via Homebrew: `ffmpeg -i x.mov -vf mpdecimate ...` or `ffprobe -show_frames`) but only reflects simulator's composited output, not true device FPS. Simulator performance is host Mac GPU-bound and not representative of Vision Pro hardware.
- Peekaboo `capture` can also record/extract frames (mentions video ingest/frame extraction).

## 8. Recommendation from this angle

1. Try Peekaboo coordinate click first because it is installed and permissioned. Upgrade to current (4.x) with Homebrew only if 3.0.0-beta3 lacks flags.
2. Keep Claude Code computer-use as the fallback because it handles coordinate scaling automatically, but expect it to be slow and to hide other apps.
3. Treat screen-level clicking as a smoke-test layer; for robust automation add a DEBUG in-app control channel (launch arguments / URL scheme / debug menu) so Claude can toggle effects and enter the dome without precise gaze-clicks. That is covered by other research angles.
4. Always confirm results by log + `simctl io screenshot`, never by assuming the click landed.

## Uncertain / unverified list
- Whether synthetic CGEvent clicks register as taps on visionOS Simulator canvas (UNTESTED).
- Peekaboo 4.9.8 release date, correct Homebrew tap, whether local beta3 CLI flags match the docs.
- Claude Code computer-use minimum version (v2.1.85) and March 2026 launch date come from third-party articles; the official page confirmed feature, plans and behavior but not those numbers.
- One article said background computer use arrived "September 2"; year/timeline not reconciled.
- visionOS support in the Desktop iOS Simulator pane: not mentioned by docs; assume unsupported.
- Apple's Device Hub article is Xcode 27-oriented; the local machine has Xcode 26.3 with classic Simulator.app, so UI placement of controls may differ slightly.

## Sources
- Apple, Interacting with your visionOS app in Device Hub: https://sosumi.ai/documentation/xcode/interacting-with-your-visionos-app-in-device-hub (original: https://developer.apple.com/documentation/xcode/interacting-with-your-visionos-app-in-device-hub)
- Claude Code docs, computer use (CLI): https://code.claude.com/docs/en/computer-use
- Claude Code docs, iOS Simulator pane (Desktop): https://code.claude.com/docs/en/desktop-ios-simulator.md
- Peekaboo repo: https://github.com/openclaw/Peekaboo
- Peekaboo MCP post: https://steipete.me/posts/2025/peekaboo-mcp-lightning-fast-macos-screenshots-for-ai-agents
- Peekaboo listing: https://glama.ai/mcp/servers/@steipete/Peekaboo
- Claude Code computer use coverage: https://www.mindstudio.ai/blog/claude-code-computer-use-mac-setup-guide , https://apidog.com/blog/claude-code-computer-use , https://www.igeeksblog.com/claude-code-computer-use-background-mac/
- visionOS UI automation skill (secondary): https://skillsmp.com/creators/studiomeije/visionos-codex-plugin/plugins-build-visionos-apps-skills-visionos-ui-automation
- Apple forums, emulate mouse click: https://developer.apple.com/forums/thread/685618?page=2
- Apple forums, visionOS Simulator rotate/scale gestures: https://developer.apple.com/forums/thread/767490
- Unity forum, in-game controls in visionOS simulator: https://discussions.unity.com/t/in-game-controls-in-visionos-simulator/332481
- Kodeco, visionOS Simulators: https://www.kodeco.com/ios/paths/introduction-to-visionos/49756480-visionos-an-introduction/01-getting-started-with-visionos/03
- Local checks: `which cliclick peekaboo`, `peekaboo --version/permissions/list windows --app Simulator`, `xcrun simctl help`, `xcrun simctl io <udid> enumerate`.
