# 05 - Claude Code + visionOS: community and official workflows (as of 2026-11-14)

Angle: how developers drive Apple-platform (especially visionOS) work with AI coding agents, and what is credible for "agent can see and click the simulator". Research was done with web search plus fetches of primary docs. Confidence flags: [HIGH] primary doc read directly, [MED] secondary blog or search summary, [LOW] directory listing / unverified.

## Bottom line

1. There is NO documented, proven path of Claude Code driving the visionOS simulator through an MCP/CLI tool. Every agent-simulator workflow found (XcodeBuildMCP, AXe, Claude Code Desktop simulator pane, Apple's Xcode MCP) is iOS-centric. The visionOS evidence is thin: one Codex-plugin skill listing and generic skill directories. [MED]
2. The one first-party mechanism that does not depend on iOS-only tooling is Claude Code CLI **computer use** (built-in `computer-use` MCP server, research preview, macOS, Pro/Max/Ultra only). It controls the Simulator.app window like a mouse user. Anthropic's own docs name "the iOS Simulator" as a target; visionOS Simulator is the same kind of macOS window, and Apple's visionOS sim maps mouse click to pinch, so this is the most plausible "obvious solution" - but it is untested for visionOS by any source found. [HIGH for doc, UNVERIFIED for visionOS]
3. Claude Code Desktop's integrated "iOS Simulator pane" (public beta, 2026-07-21) is iOS/iPadOS only; the docs do not mention visionOS. [HIGH]
4. Apple's Xcode 26.3 built-in MCP (`xcrun mcpbridge`, 20 tools) has SwiftUI `RenderPreview` screenshots but NO simulator interaction tool, and no immersive-space support. Not useful for the Metal dome view. [MED]
5. For FPS: all sources agree simulator frame stats are not device-representative. Use app-side logging (Liminal already logs `fps=`) read via `simctl spawn log stream`. Claude Code's pane FPS setting is only the video stream rate. [HIGH]

## 1. Official Anthropic mechanisms

### 1a. CLI computer use (most relevant to Liminal)
Source: https://code.claude.com/docs/en/computer-use.md [HIGH]
- Built-in MCP server `computer-use`, off by default. Enable via `/mcp` -> select `computer-use` -> Enable (persists per project).
- Requires macOS, Pro/Max/Ultra plan (NOT Team/Enterprise), claude.ai auth (not Bedrock/Vertex/Foundry), interactive session (not `-p`).
- Needs macOS Accessibility + Screen Recording permission for the terminal app; may need Claude Code restart.
- Per-session app approval prompt (approve Simulator.app). Other apps get hidden while Claude works; terminal excluded from screenshots. Esc aborts.
- One session at a time holds a lock.
- Screenshots are downscaled (e.g. 3456x2234 -> ~1372x887). Small UI text in the sim may be hard to read; enlarge in the app rather than changing display res. Relevant: the visionOS sim window is large/low-density, so check legibility of the control window.
- Tool-priority: Claude prefers MCP server > Bash > Claude in Chrome > computer use. So give it Bash recipes (simctl screenshot, log stream) for everything non-clickable and reserve computer use for clicking.
- Docs include a "Test a simulator flow" example prompt (iOS) and explicitly list "the iOS Simulator" under things only screen control can reach.
- Caveat: slow and broad; no hard assertions; model-judged.

### 1b. Claude Code Desktop iOS Simulator pane
Sources: https://code.claude.com/docs/en/desktop-ios-simulator.md [HIGH]; https://www.macrumors.com/2026/07/21/claude-code-ios-simulator/ ; https://9to5mac.com/2026/07/21/claude-code-brings-live-ios-app-testing-into-its-mac-app/ [MED]
- Public beta announced 2026-07-21. Needs Claude Desktop >= v1.24012.0, local sessions only, Xcode 26.x or 27.
- Drives the simulator directly (not computer use) - taps, typing, screenshots, with per-device consent.
- Docs describe iPhone/iPad only; "Claude drives simulated devices only". No visionOS mention. Not available with third-party providers. 
- Its frame-rate/resolution settings affect only the stream, not app perf. Third-party guide (https://agentpedia.codes/blog/claude-code-ios-simulator-guide.md) restates Apple's advice to use Instruments on a physical device for perf.
- Mentions Device Hub on Xcode 27 as an alternative simulator host (see section 3).

### 1c. Claude Agent in Xcode 26.3
Source: https://www.anthropic.com/news/apple-xcode-claude-agent-sdk (via secondary mirror, [MED]); https://www.techradar.com/pro/apple-launches-xcode-26-3-brings-even-more-ai-power-to-coding-on-mac
- Xcode 26.3 (Feb 2026) embeds Claude Agent (Agent SDK) and Codex, and exposes Xcode as an MCP server so external agents (Claude Code, Cursor) can use it.
- Claimed capability: Claude can capture Xcode Previews to verify UI. Previews = SwiftUI only.

## 2. Apple's Xcode MCP bridge (xcrun mcpbridge)
Sources: https://dev.to/arshtechpro/xcode-263-use-ai-agents-from-cursor-claude-code-beyond-4dmi ; https://charleswiltgen.github.io/Axiom/skills/xcode-mcp [MED]
- Setup: Xcode > Settings > Intelligence > enable Xcode Tools (MCP); `claude mcp add --transport stdio xcode -- xcrun mcpbridge`. Xcode must be running with the project open.
- 20 tools: 9 file ops (XcodeRead/Write/Update/Glob/Grep/LS/MakeDir/RM/MV), 5 build/test (BuildProject, GetBuildLog, RunAllTests, RunSomeTests, GetTestList), 2 diagnostics, 3 intelligence (ExecuteSnippet, RenderPreview, DocumentationSearch), 1 workspace (XcodeListWindows).
- No simulator tap/screenshot tool. Useful extras: DocumentationSearch (Apple docs + WWDC), ExecuteSnippet. Cursor needs a structuredContent workaround; Claude Code does not.
- One directory page hints at an "Xcode 27 gate" for external agents - unconfirmed.
- Practitioner recommendation (shimo4228, below): install BOTH Apple's MCP and XcodeBuildMCP; they are complementary.

## 3. Apple-native: Device Hub / XCUITest / simctl
- Device Hub (Xcode window for simulators; docs say Xcode 27-era, user has 26.3 so may be unavailable) - https://sosumi.ai/documentation/xcode/interacting-with-your-visionos-app-in-device-hub [HIGH for doc content]. Mouse maps to gaze+pinch: click=tap, click-and-hold=pinch-hold, drag=pinch-drag, Shift-drag for forward/back; WASD/arrow movement, Reset Camera; Simulated Scenes. Confirms that plain mouse clicks are the supported way to "tap" in the visionOS simulator, which is what computer use would do. The page does not cover automation; it links to "Interacting with devices using the command line" (https://sosumi.ai/documentation/xcode/interacting-with-devices-using-the-command-line), which covers simctl boot and devicectl for physical devices only - no tap/screenshot commands.
- XCUITest on visionOS: third-party guides (https://helpmetest.com/blog/apple-vision-pro-testing-guide/, https://helpmetest.com/blog/visionos-realitykit-testing/) [LOW/MED] say pointer-click-reachable SwiftUI controls are testable, eye gaze/hand gestures are not simulated, and nothing concrete for immersive spaces. XCUIDevice `rotateDigitalCrown(delta:)` is the suggested workaround for the missing crown UI (https://developer.apple.com/forums/thread/732458). Apple's UI automation docs: https://developer.apple.com/documentation/xcuiautomation . Forum threads report visionOS 26 sim gesture quirks (Option-key two-hand gestures: https://developer.apple.com/forums/thread/767490).
- Practical consequence for Liminal: an XCUITest UI-test target that taps Play / "Enter dome" (ordinary SwiftUI window buttons with accessibility identifiers) is the deterministic, scriptable route via `xcodebuild test -destination 'platform=visionOS Simulator,name=Apple Vision Pro'`. Screenshots can be attached (XCTAttachment) and extracted from the .xcresult. Whether XCUITest can keep running while an ImmersiveSpace is open and capture it is UNVERIFIED.

## 4. XcodeBuildMCP and AXe (and why AXe fails on visionOS)
Sources: https://skills.cat/skills/getsentry/xcodebuildmcp/xcodebuildmcp ; https://mcpservers.org/agent-skills/sentry/xcodebuildmcp ; https://glama.ai/mcp/servers/getsentry/XcodeBuildMCP/tools/tap [MED]
- Official getsentry skill lists visionOS among supported targets for build/test/run/debug/log/UI automation. UI tools: snapshot_ui (view hierarchy + coords), tap, swipe, long press, screenshot, gesture presets, key press, hardware buttons. Simulator workflow only by default; UI automation must be enabled in `.xcodebuildmcp/config.yaml`. Call `session_show_defaults` first.
- No source shows snapshot_ui/tap working on visionOS. A skill doc (axiom-axe-ref, https://skills.cat/skills/charleswiltgen/axiom/axiom-axe-ref) says AXe tap/swipe/gesture are meant for iOS sims and visionOS behavior is "undefined at best", and routes spatial UI to XCUITest or in-app hooks. This matches the user's verified failure (AXe tap no-op, describe-ui error). [MED]
- XcodeBuildMCP is still valuable for build/run/log/screenshot on visionOS even if its UI tools are not.

## 5. Community practices (most credible, concrete)
1. shimo4228, "I gave Claude Code a simulator..." (https://dev.to/shimo4228/i-gave-claude-code-a-simulator-and-it-started-tapping-and-taking-screenshots-on-its-own-57bj) [MED, iOS only, anecdotal]: XcodeBuildMCP (59 tools) + Apple Xcode MCP together; `session_set_defaults`, `build_run_sim`, screenshot, `snapshot_ui`, `tap`, screenshot after every step. Config via `.xcodebuildmcp/config.yaml` enabling `simulator` + `ui-automation`, `SENTRY_DISABLED=true`. Lessons: set accessibility identifiers (coordinate taps are brittle), verification is model-judged so good for exploratory checks not regression, each MCP call adds latency vs XCUITest.
2. Agentpedia guide (https://agentpedia.codes/blog/claude-code-ios-simulator-guide) [MED]: summarizes Anthropic's simulator pane; caveat that stream FPS is not app FPS.
3. studiomeije `visionos-codex-plugin` (https://skillsmp.com/creators/studiomeije/visionos-codex-plugin) [LOW]: 16 skills, ~11 stars at snapshot; includes `realitykit-visionos-developer` (2026-06-04; build/run/test visionOS packages and Reality Composer Pro assets) and `visionos-ui-automation` (2026-04-23; flow: build-run-debug, confirm output names the intended Apple Vision Pro sim, then choose a screenshot or interaction path; also refers to AXe for screenshot/video/keyboard/hardware buttons/a11y tree). The skill page returned HTTP 403 to fetch, so its actual tap mechanism is UNKNOWN - worth `gh repo clone`/reading the repo directly (not done; instructed not to install). Codex-targeted but SKILL.md files are portable to Claude Code.
4. Generic visionOS/RealityKit skill packs (tomkrikorian/visionOSAgents https://agent-skills.md/skills/tomkrikorian/visionOSAgents/realitykit-visionos-developer ; dpearson2699/swift-ios-skills realitykit ; fusengine/agents visionos https://skills.sh/fusengine/agents/visionos) [LOW]: API knowledge/pattern skills, not verification tooling.
5. Axiom skills (https://charleswiltgen.github.io/Axiom/skills/xcode-mcp) [MED]: Xcode MCP usage guide for agents.
6. Gap: no credible source found for visual-regression / screenshot-diff on visionOS or RealityKit immersive content, and none for an agent reading a Vision Pro sim's immersive render. Closest is XCTAttachment screenshots or `simctl io screenshot` plus self-built pixel comparison.

## 6. How to verify RealityKit/Metal immersive content (synthesis)
- Visual: `xcrun simctl io <udid> screenshot` (already verified, 3840x2160 includes the whole stereo-sim window view). Claude reads PNGs directly. For regression, compare against saved baselines with a script (e.g. ImageMagick `compare`, or Python with PIL) using tolerance since shaders are time-animated: better to add a deterministic debug flag (fixed time seed / frozen oscillator) in-app and launch args via `simctl launch ... -args`.
- Perf: rely on the in-app `fps=` PERF log via `simctl spawn <udid> log stream --predicate ...`. Sim fps reflects Mac GPU, not Vision Pro; use relative before/after comparisons only. Instruments / on-device for absolute numbers (Apple's guidance).
- State driving without clicks (robust, community-recommended in the AXe doc): launch arguments / URL scheme / debug hooks to auto-press Play, open the immersive space, set sliders and effect toggles, so the agent needs UI clicking only occasionally. Opening ImmersiveSpace requires a user gesture-initiated or scene-phase call in-app, so a debug auto-open on launch is the simplest hook (note: system permission alerts for immersive spaces were historically not presentable in sim - https://developer.apple.com/forums/thread/760165).
- Clicking: computer use on Simulator.app (mouse click = pinch) is the only documented-plausible agent path; combine with simctl screenshots for exact pixels (computer-use screenshots are downscaled).

## 7. Suggested sample CLAUDE.md snippets (assembled from the above, not a copied community template)
- "Build: `xcodebuild -scheme Liminal -destination 'platform=visionOS Simulator,name=Apple Vision Pro'`. Install/launch with simctl. Screenshot: `xcrun simctl io 19A53057-... screenshot out.png`. Perf: grep `fps=` from `simctl spawn ... log stream`."
- "Never assume a tap worked; take a screenshot after each UI action."
- "Prefer launch-arg debug hooks over coordinate clicking; use computer use on Simulator.app only for pinch/click needs."
- No community CLAUDE.md for visionOS was found to cite.

## 8. Recommended next steps (for the decision)
1. Cheapest test: enable `computer-use` in `/mcp` (needs Pro/Max/Ultra plan, claude.ai auth), approve Simulator, ask Claude to click Play / Enter dome in the visionOS sim, and confirm via `simctl io screenshot`. If it works this satisfies the goal with zero new installs.
2. Add debug launch-argument hooks (auto-play, auto-enter-dome, effect toggles) in Liminal for deterministic automation; pairs with simctl screenshot + log stream.
3. Optionally add an XCUITest target for the 2D control window.
4. Read the studiomeije repo's `visionos-ui-automation` SKILL.md directly (403 via fetch) to see what tap mechanism it relies on.

## Uncertainties
- Whether Simulator.app computer-use clicks register as pinches in visionOS 26.2 on this machine (forum notes some gesture regressions in visionOS 26).
- Whether Device Hub exists in Xcode 26.3 (docs/Anthropic page tie it to Xcode 27).
- Anthropic's docs said plan availability differs: desktop sim pane includes Team/Enterprise, CLI computer use excludes Team/Enterprise.
- Several sources are SEO/aggregator blogs; dates for skill listings come from directory snapshots.

## Sources
- https://code.claude.com/docs/en/computer-use.md
- https://code.claude.com/docs/en/desktop-ios-simulator.md
- https://www.macrumors.com/2026/07/21/claude-code-ios-simulator/
- https://9to5mac.com/2026/07/21/claude-code-brings-live-ios-app-testing-into-its-mac-app/
- https://agentpedia.codes/blog/claude-code-ios-simulator-guide.md
- https://dev.to/shimo4228/i-gave-claude-code-a-simulator-and-it-started-tapping-and-taking-screenshots-on-its-own-57bj
- https://dev.to/arshtechpro/xcode-263-use-ai-agents-from-cursor-claude-code-beyond-4dmi
- https://charleswiltgen.github.io/Axiom/skills/xcode-mcp
- https://www.techradar.com/pro/apple-launches-xcode-26-3-brings-even-more-ai-power-to-coding-on-mac
- https://sosumi.ai/documentation/xcode/interacting-with-your-visionos-app-in-device-hub
- https://sosumi.ai/documentation/xcode/interacting-with-devices-using-the-command-line
- https://skillsmp.com/creators/studiomeije/visionos-codex-plugin
- https://skillsmp.com/creators/studiomeije/visionos-codex-plugin/plugins-build-visionos-apps-skills-visionos-ui-automation (403 on fetch)
- https://skills.cat/skills/getsentry/xcodebuildmcp/xcodebuildmcp
- https://mcpservers.org/agent-skills/sentry/xcodebuildmcp
- https://glama.ai/mcp/servers/getsentry/XcodeBuildMCP/tools/tap
- https://skills.cat/skills/charleswiltgen/axiom/axiom-axe-ref
- https://agent-skills.md/skills/tomkrikorian/visionOSAgents/realitykit-visionos-developer
- https://skills.sh/fusengine/agents/visionos
- https://helpmetest.com/blog/apple-vision-pro-testing-guide/
- https://helpmetest.com/blog/visionos-realitykit-testing/
- https://developer.apple.com/forums/thread/732458
- https://developer.apple.com/forums/thread/767490
- https://developer.apple.com/forums/thread/760165
- https://developer.apple.com/documentation/xcuiautomation
