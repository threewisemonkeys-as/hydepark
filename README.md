# HydePark

Blackens every part of the screen that the active window isn't using, so you can
focus on one window on a big monitor without resizing anything. Menu bar app, no
permissions required.

## Build & run

    ./build.sh
    open HydePark.app

A small circle icon appears in the menu bar. To launch at login, add
`HydePark.app` under System Settings → General → Login Items.

## Toggle the mask

- **⌃⌥⌘F** (global hotkey, works from any app)
- Menu bar icon → *Toggle Mask*
- `open -a HydePark` from a shell / Raycast / Shortcuts (re-launching toggles)
- `kill -USR1 $(pgrep -x HydePark)`

While on, the cutout (rounded to match window corners) follows the frontmost window: switch apps or move the
window and the hole moves with it. Clicks pass through the black area. The menu
bar and Dock stay visible and usable.

The mask is a separate overlay per Space, created the first time you visit a Space
while the mask is on. Because each overlay belongs to its Space, macOS slides it
together with that Space's windows, so the cutout stays glued to the window during
the transition instead of jumping into place afterwards.

## Options

- Menu bar → *Opacity* slider (10–100 %). It soft-snaps to 25 / 50 / 75 / 90 / 100 %; tick marks show the detents.
- `main.swift` top: change the hotkey (`hotKeyCode`, `hotKeyModifiers`),
  the tracking rate (`refreshInterval`) add margin around the cutout (`holePadding`) or adjust the cutout's
  corner rounding (`holeCornerRadius`, default 16 to match macOS windows), or the fade used when an
  overlay first appears (`revealFadeDuration`).
