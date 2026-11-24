# Control UI cleanup (macOS + visionOS)

User request: "the text doesn't wrap properly and the labels all have the ... in them, so that all should be cleaned up too... change the UI as much as necessary."

## What was wrong (before screenshots)

visionOS (320x560 window):
- Top row showed "▶ …", "↗ E", "▣ S": Play and the two immersive modes squeezed into three ~100 pt buttons.
- Segmented pickers truncated their labels.
- Status line in tiny caption type ("Stopped · 326 · Queue: 0") with an unlabelled number.
- Settings sheet: both explanation captions truncated, the API status was hidden behind the large navigation title, and "Reset All to Defaults" was clipped at the bottom of the sheet. Red destructive text on glass was hard to read.

macOS:
- Slider labels without values; icon-only slider ends.
- Settings sheet captions truncated ("…will be ge…", "…to their def…").
- "Sync visuals to music" sat under another toggle's explanation, so the caption seemed to describe it.

## Decisions

**U1. Shared components in `Liminal/ControlComponents.swift`.** `ControlSection` (titled card), `ValueSlider` ("Effect intensity 50%"), `ScalePicker`, `PlaybackStatus`, `CollectionsStatusRow`, `ExplainedToggle`, `DestructiveLabel` and a `.wrapping()` modifier (`lineLimit(nil)` plus `fixedSize(horizontal: false, vertical: true)`). Both platforms use them, so they look the same and every caption wraps instead of truncating. Per-platform spacing and type sizes live in `ControlMetrics`.

**U2. Sections everywhere:** Playback; Music (Tempo and Scale only); Visuals; Archive Footage; Images & Storage (collections status, the credit line for the picture on screen, Clear Curated Pictures, and on visionOS Reset All Settings). There is no mode, style or image-source picker and no generation setting: Lo-Fi and curated pictures are the only options.

**U3. visionOS: one window, no settings sheet.** All controls now fit in the window. The window opens at 1240x960 (`defaultSize`; 1280x720 is the visionOS default), which fits three columns: Playback + Visuals | Music + Images & Storage | Archive Footage (the tallest section, so it stands alone). `ViewThatFits` falls back to two columns, then to one scrolling column, when the window is narrowed. Columns set an `idealWidth`, because otherwise the wrapping captions report their one-line width and `ViewThatFits` always picks the single column. The settings sheet is gone, so the gear button and the clipped sheet went with it. Its items moved into the Visuals and Images & Storage cards.

**U4. visionOS hit targets.** Play/Stop, Enter/Exit Liminal, Clear Curated Pictures and Reset All Settings are each at least 60 pt tall (HIG). They are full width or sized to their full label. Play is tinted blue and turns red when it becomes Stop. I did not use ornaments: the actions fit in the window, and ornament positions are harder to drive with `sim-tap.sh`.

**U5. Destructive buttons on visionOS** use a red icon with primary-colored text and no destructive role, because the system's red title was unreadable on glass. Clear Curated Pictures still asks for confirmation, and the dialog's "Delete Curated Pictures" button keeps `role: .destructive`. macOS keeps the destructive role.

**U6. macOS panel** is 320 pt wide (was 280). `SquareVisualWindowDelegate.controlPanelWidth` is derived from `ContentView.panelWidth`, so the 3:2 visual area stays exact. The panel scrolls when the window is short. The window minimum height went from 450 to 560, and the first-launch default size is 960x640 visual plus the panel. "Sync visuals to music" and "Debug effect" are now in the panel's Visuals card, as trailing switches with captions. Clear Curated Pictures and Reset live in the "Storage & Settings" sheet, opened from a full-label button (Cmd-, also opens it). The collections status appears once, in the panel.

**U7. Status text** reads "Playing" / "Stopped" with a colored dot, then "36 curated pictures saved, 2 in queue". It wraps. The macOS video overlay's cached-count badge is unchanged.

**U8. Scale** (the Music section's only other control besides Tempo) gets its own line with the menu below it, so long names like "Natural Minor (Aeolian)" never truncate. A caption states whether the scale is auto-evolving or pinned.

## Simulator tap coordinates (changed)

These apply to the 1240x960 window at its default position after a fresh launch, in screenshot pixels:

| Control | x | y |
|---|---|---|
| Play / Stop | 1371 | 826 |
| Enter / Exit Liminal | 1371 | 930 |
| Clear Curated Pictures | 1294 | 1288 (opens popover; tap 1350 1400 to dismiss) |

Updated in `scripts/sim-tap.sh` (header), `scripts/perf-run.sh` (fallback taps) and `docs/research/visionos-sim-automation/README.md`.

## Verified

- Both platforms build.
- visionOS sim: Play toggles to Stop and the status reads "Playing"; Enter Liminal opens the immersive space and the button turns into Exit Liminal; Exit Liminal works. Clear Curated Pictures opens the confirmation, which was dismissed without deleting anything.
- macOS: the panel scrolls, the Storage & Settings sheet opens, and all text wraps with no truncation.

## Widescreen playback and recording (2026-11-23)

On macOS the 16:9 canvas fits beside the 320 pt scrollable panel. `VisualWindowDelegate` handles the window size and the layout requires at least 520 pt of height, so controls stay accessible as the canvas shrinks.

On Vision Pro, Record becomes available once Liminal has submitted the first immersive frame and playback audio is ready. Exit Liminal finishes an active recording. [Recording guide](../recording.md)
