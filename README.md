# TileSpace

Window management for macOS that works with SIP on and with macOS's own desktops (Spaces).

- **Rectangle-style snapping**: halves, corners, thirds, two-thirds, first fourth and last
  three fourths, maximize, maximize height, center, larger/smaller, restore, and
  previous/next display. It uses Rectangle's Ctrl+Option shortcuts, or you can drag a window
  to a screen edge or corner. Repeating Left or Right Half moves the window to the next
  display over. Repeating First or Last Third cycles through the thirds.
- **Moving a window to another desktop.** macOS has no API for that, and macOS 27 ignores
  synthetic title-bar drags. But moving a window onto another display puts it on whatever
  desktop that display is showing. So TileSpace parks the window on another display, switches
  its own display to the target desktop, and moves it back to its exact frame. It checks the
  result with the read-only SkyLight call `SLSCopySpacesForWindows`. Because it works through
  another display, it needs a second display, with "Displays have separate Spaces" on (the
  default): on a Mac with only one, it can't move windows.
- **An MCP server and a command line**, so agents and scripts can list, snap and move windows.

Everything runs in one menu-bar app, TileSpace.app, which starts at login. The `tilespace`
command and MCP clients both talk to it through its MCP server. So the shortcuts, the command
line and agents share one memory of past snaps, which Restore and repeated snaps rely on.

## Install

Needs macOS 14 or later and Xcode's command-line tools.

```sh
scripts/build-app.sh --install   # ~/Applications/TileSpace.app and ~/.local/bin/tilespace
```

The app asks for Accessibility access the first time it runs. The build script signs with
your Apple Development certificate if you have one, so the permission survives rebuilds.
Without one it signs ad hoc, and macOS stops trusting each new build even though System
Settings still shows TileSpace switched on. So `--install` clears that entry when it signs ad
hoc, and the new app asks for access again. If the menu ever asks for access while System
Settings shows it on, run `tccutil reset Accessibility com.trevinlee.tilespace`, quit and
reopen TileSpace, and allow it again.

The app turns on Launch at Login the first time it runs, so the MCP server is always there.
You can turn that off in its menu.

`~/.local/bin` isn't on macOS's default PATH. If `tilespace` isn't found, add it:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

If Rectangle is running, TileSpace leaves shortcuts and drag snapping to it, because both apps
would otherwise act on every key press and drag. TileSpace's menu has a Quit Rectangle button.
The menu, the command line and the MCP tools still work while Rectangle runs.

macOS 15 and later tile windows dragged to screen edges too, and that's on by default. Its
layouts differ from TileSpace's (the top edge fills the screen, corners are quarters), so a
drag shows two previews and the window can end up in either place. Turn off "Drag windows to
screen edges to tile" and "Drag windows to menu bar to fill screen" in System Settings >
Desktop & Dock, or TileSpace's Snap by Dragging to Screen Edges. While both apps snap by
dragging, TileSpace's menu says so and links to the setting.

**To update**, pull and run `scripts/build-app.sh --install` again. It quits the running app,
replaces it and starts the new one. With an ad-hoc signature, allow Accessibility access again
when the new app asks.

**To uninstall**, first turn off Launch at Login in TileSpace's menu, then:

```sh
tilespace mcp uninstall                         # if you added it to Claude Code
osascript -e 'quit app "TileSpace"'
rm -rf ~/Applications/TileSpace.app ~/.local/bin/tilespace
tccutil reset Accessibility com.trevinlee.tilespace
```

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

You can also drag a window to a screen edge or corner. A preview shows where it will go, and
Esc cancels. Dragging a snapped window away gives it back its size from before.

| Drag to | Action |
|---|---|
| Left or right edge | Left or right half |
| Top edge | Maximize height |
| Top-left or top-right corner | First fourth, last three fourths |
| Bottom-left corner, bottom edge, bottom-right corner | First, center, last third |

Some windows have a minimum or a fixed size. Snapped to a spot that's too small for it, such a
window keeps its own size and stays on the display, against the right or bottom edge if the
spot is there.

The menu has every action, and switches to turn off Keyboard Shortcuts or Snap by Dragging
to Screen Edges.

Scripts and launchers can run any action on the frontmost window with a link:
`open -g "tilespace://execute-action?name=left-half"`. The action names are `left-half`,
`right-half`, `top-half`, `bottom-half`, `top-left`, `top-right`, `bottom-left`,
`bottom-right`, `first-third`, `center-third`, `last-third`, `first-two-thirds`,
`center-two-thirds`, `last-two-thirds`, `first-fourth`, `last-three-fourths`, `maximize`,
`maximize-height`, `center`, `larger`, `smaller`, `restore`, `previous-display` and
`next-display`.

## Command line

```sh
tilespace windows                                # every window, with its desktop and id
tilespace desktops                               # desktops per display (* = showing)
tilespace snap <action> [<window>]               # e.g. tilespace snap first-third
tilespace move <window> <desktop>                # move a window to desktop N on its display
tilespace move <window> <desktop> <display>      # ...or on another display, e.g. built-in
tilespace move <window> <desktop> --follow       # ...and stay on that desktop
```

`tilespace windows` prints one window per line: display and desktop number, window id, app,
frame and title. It lists normal windows at least 100pt each way, on every desktop. A `*`
after the desktop number means that desktop is showing. Only those windows can be snapped or
moved, because macOS's Accessibility API can't reach the others. Windows on the other desktops
have no title. macOS only shows another app's window titles to apps with Screen Recording
access, which TileSpace doesn't ask for. Windows of full-screen apps aren't listed.

`<window>` is a window id from `tilespace windows`, or text matched against the app name and
window title, such as `zen` or `"zen github"`. Quote text that's more than one word in
`move`. Leave out the window in `snap` to act on the frontmost app's window.

`tilespace snap` prints the action applied and the frame the window ended up with, such as
`left-half: 0,33 864x1084`. That's the window's real frame, so for a window that kept its own
size it differs from the spot you asked for. If the window didn't move at all, as a
full-screen window doesn't, `snap` fails and says so.

`tilespace move` switches desktops by pressing macOS's "Switch to Desktop N" shortcuts. macOS
ships them off: turn them on in System Settings > Keyboard > Keyboard Shortcuts > Mission
Control. They can have any keys: TileSpace presses the ones you've set. If a shortcut a move
needs is off, `move` says which one before anything moves. macOS only has these shortcuts
for the first 16 desktops, counting across displays. Every move needs a second display: a
move within one display parks the window on another display meanwhile, so with a single
display (a laptop on its own) `move` can't work. Each display also needs its own
desktops: leave "Displays have separate Spaces" on (the default) in System Settings > Desktop &
Dock. With it off, all displays share one set of desktops, `tilespace desktops` shows them as
"All displays", and `move` can't work. The screen switches to the target desktop and back,
unless you pass `--follow`. If macOS doesn't switch back, the window still moves and `move`
says which shortcut to check.

The command starts TileSpace.app if it isn't running. `list` and `spaces` still work as the
old names of `windows` and `desktops`.

## MCP

The app serves MCP (Streamable HTTP) at `http://127.0.0.1:8453/mcp` while it runs. To add it
to Claude Code, choose **Add to Claude Code** in the app's menu, or run:

```sh
tilespace mcp install     # claude mcp add --scope user --transport http tilespace http://127.0.0.1:8453/mcp
tilespace mcp uninstall   # claude mcp remove --scope user tilespace
```

For another client, add an HTTP MCP server at that URL. Each command above is one call to a
tool:

| Tool | Command | Does |
|---|---|---|
| `list_windows` | `tilespace windows` | Every window on every desktop, with its id, app, frame and title |
| `list_desktops` | `tilespace desktops` | The desktops on each display, and which one is showing |
| `snap_window` | `tilespace snap` | Any snap action, on a window or the focused one; returns the frame the window ended up with |
| `move_window_to_desktop` | `tilespace move` | Move a window to desktop N, on its own display or another |

The server listens only on 127.0.0.1, so nothing else on the network can reach it. Any
program running as you can use it, the same as it could use Accessibility directly, but web
pages can't. TileSpace refuses requests with an `Origin` header, which browsers always send
from a page, and requests with an unexpected `Host`, which is how DNS rebinding works.

## Caveats

Moving windows between desktops relies on private SkyLight calls (read-only ones) and on how
macOS treats windows moved between displays. A macOS update could break either, and it rules
out the Mac App Store.

## Development

```sh
swift build && swift test         # snap geometry, move planning, HTTP and MCP are unit tested
Tests/Integration/run.sh          # snaps a real test window, through the app; meant for CI
```

CI runs both on GitHub's macOS runners. Plans and ideas are in the
[issues](https://github.com/trevin-lee/tilespace/issues).

## License

[AGPL-3.0](LICENSE). Copyright © 2026 Trevin Lee.
