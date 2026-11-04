# TileSpace

Window management for macOS that works with SIP on and with macOS's own desktops (Spaces).

Early and changing fast. What works today:

- **`tilespace`, a command-line tool**, that moves a window to another desktop. macOS has no
  API for that, and macOS 27 ignores synthetic title-bar drags. But moving a window onto
  another display puts it on whatever desktop that display is showing. So `tilespace` parks the
  window on the other display, switches the window's home display to the target desktop, and
  moves the window back to its exact frame. It checks the result with the read-only SkyLight
  call `SLSCopySpacesForWindows`. Needs two displays for now.
- **A menu-bar app with Rectangle-style snapping**: halves, quarters, thirds, two-thirds,
  maximize, maximize height, center, larger/smaller, restore, and previous/next display, on
  Rectangle's Ctrl+Option shortcuts. Repeating Left or Right Half moves the window to the
  next display over. Repeating First or Last Third cycles through the thirds. Dragging a
  window to a screen edge or corner snaps it too.

Planned: moving a window to desktop N from the app;
opt-in tiling for chosen windows on a desktop (shared edges, drag to reorder), while
everything else floats; layouts saved per monitor setup; and a virtual display to park
windows on when there's only one screen.

## Install

Needs macOS 14 or later and Xcode's command-line tools.

```sh
scripts/build-app.sh --install   # ~/Applications/TileSpace.app and ~/.local/bin/tilespace
```

The app asks for Accessibility access the first time it runs. The build script signs with
your Apple Development certificate if you have one, so the permission survives rebuilds. With
an ad-hoc signature, you have to grant it again after every build.

If Rectangle is running, the app leaves snapping to it, because both apps would otherwise act
on every key press and drag. Its menu has a Quit Rectangle button.

## Use

| Shortcut | Action |
|---|---|
| ⌃⌥ ← → ↑ ↓ | Left, right, top, bottom half |
| ⌃⌥ U I J K | Top left, top right, bottom left, bottom right |
| ⌃⌥ D F G | First, center, last third |
| ⌃⌥ E R T | First, center, last two thirds |
| ⌃⌥ ↩ | Maximize |
| ⌃⌥⇧ ↑ | Maximize height |
| ⌃⌥ C | Center |
| ⌃⌥ = and − | Larger, smaller |
| ⌃⌥ ⌫ | Restore |
| ⌃⌥⌘ ← → | Previous, next display |

Or drag a window to a screen edge or corner. A preview shows where it will go, and Esc
cancels. Dragging a snapped window away gives it back its size from before.

| Drag to | Action |
|---|---|
| Left or right edge | Left or right half |
| Top edge | Maximize height |
| Top-left or top-right corner | First fourth, last three fourths |
| Bottom-left corner, bottom edge, bottom-right corner | First, center, last third |

Scripts and launchers can trigger the same actions:
`open -g "tilespace://execute-action?name=left-half"`.

```sh
tilespace list                               # every window, with its desktop and id
tilespace spaces                             # desktops per display (* = showing)
tilespace move <window> <desktop>            # move a window to desktop N on its display
tilespace move <window> <desktop> <display>  # ...or on another display
tilespace snap <action> [<window>]           # e.g. tilespace snap first-third
```

`<window>` is a window id from `tilespace list`, or text matched against the app name and
window title. `tilespace move` presses the "Switch to Desktop N" shortcuts. Turn
them on in System Settings > Keyboard > Keyboard Shortcuts > Mission Control.

## Caveats

Moving windows between desktops relies on private SkyLight calls (read-only ones) and on how
macOS treats windows moved between displays. A macOS update could break either, and it rules
out the Mac App Store.

## Development

```sh
swift build && swift test         # snap geometry is unit tested
Tests/Integration/run.sh          # snaps a real test window; meant for CI
```

CI runs both on GitHub's macOS runners.

## License

[AGPL-3.0](LICENSE). Copyright © 2026 Trevin Lee.
