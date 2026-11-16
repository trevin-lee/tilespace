#!/bin/zsh
# End-to-end checks on a real window: start TileSpace.app (the core, with its MCP server) the
# way Finder does, open a test window, then snap it through the `tilespace` command (a client of
# the app's server), by dragging it to screen edges, and with the app's shortcuts, checking where
# it lands each time. It takes over the mouse and keyboard, and starts and quits a stand-in
# for Rectangle, so it's meant for CI (a macOS runner), not a desk.
#
# Needs Accessibility access for whatever runs it (on a Mac: the terminal app) and for the app.
set -euo pipefail
cd "${0:A:h}/../.."

scripts/build-app.sh
tilespace=.build/release/tilespace
mkdir -p build
swiftc -O Tests/Integration/TestWindow.swift -o build/TestWindow
swiftc -O Tests/Integration/Input.swift -o build/input
cat > build/trusted.swift <<'EOF'
import ApplicationServices
exit(AXIsProcessTrusted() ? 0 : 1)
EOF
swiftc build/trusted.swift -o build/trusted
# a stand-in for Rectangle: an app with its bundle id and, like it, no Dock icon
rectangle=build/Rectangle.app
rm -rf $rectangle
mkdir -p $rectangle/Contents/MacOS
cat > build/rectangle.swift <<'EOF'
import AppKit
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
EOF
swiftc build/rectangle.swift -o $rectangle/Contents/MacOS/Rectangle
cat > $rectangle/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.knollsoft.Rectangle</string>
    <key>CFBundleName</key><string>Rectangle</string>
    <key>CFBundleExecutable</key><string>Rectangle</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - $rectangle
if ! build/trusted; then
    echo "no Accessibility access: allow the app running this in System Settings > Privacy & Security > Accessibility"
    exit 1
fi

state=$(mktemp)
build/TestWindow $state & win=$!
trap 'kill $win 2>/dev/null; pkill -x TileSpace; pkill -x Rectangle' EXIT
sleep 2

failed=0
# the test window's frame, the main display's frame, and its visible area
read_state() {
    s=(${(s: :)$(<$state)})
    wx=$s[1] wy=$s[2] ww=$s[3] wh=$s[4]
    sx=$s[5] sy=$s[6] sw=$s[7] sh=$s[8]
    vx=$s[9] vy=$s[10] vw=$s[11] vh=$s[12]
}
# check <label> <x> <y> <w> <h>: the window is there, give or take 2pt
check() {
    sleep 0.6
    read_state
    local want=($2 $3 $4 $5) got=($wx $wy $ww $wh) ok=1
    for i in 1 2 3 4; do (( want[i] - got[i] > 2 || got[i] - want[i] > 2 )) && ok=0; done
    if (( ok )); then echo "ok    $1: $wx,$wy ${ww}x$wh"
    else echo "FAIL  $1: wanted ${want[1]},${want[2]} ${want[3]}x${want[4]}, got $wx,$wy ${ww}x$wh"; failed=1; fi
}
# back to its starting frame; rw and rh are its size there (title bar included)
reset_window() { kill -USR1 $win; sleep 0.5; read_state; rw=$ww rh=$wh; }
# drag the window by a point inside it to x,y
drag_to() { read_state; build/input drag $(( wx + ww / 2 )) $(( wy + wh / 2 )) $1 $2 ${3:-}; }

pass() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; failed=1; }

# snap_to <action> <window> <x> <y> <w> <h>: snap a window with the command. It has to land
# there, and the reply has to name the action and give the frame the window has.
snap_to() {
    local action=$1 window=$2 label="snap $1" said; shift 2
    [[ $window == "tilespace test" ]] || label+=" by window id $window"
    said=$($tilespace snap $action $window 2>&1) || { fail "$label: $said"; return; }
    check $label $@
    replied $label $action $said
}
# replied <label> <action> <reply>: the reply to a snap, e.g. "left-half: 0,25 720x875", names
# the action and gives the window's frame as it is now, give or take 2pt
replied() {
    read_state
    local -a match
    local got=($wx $wy $ww $wh) ok=0
    if [[ $3 =~ "^$2: (-?[0-9]+),(-?[0-9]+) ([0-9]+)x([0-9]+)\$" ]]; then
        ok=1
        for i in 1 2 3 4; do (( match[i] - got[i] > 2 || got[i] - match[i] > 2 )) && ok=0; done
    fi
    if (( ok )); then pass "$1: the reply is the window's frame: $3"
    else fail "$1: the reply should be '$2: $wx,$wy ${ww}x$wh', got: $3"; fi
}

echo "--- the app and its MCP server"
# with `open`, the app is its own process, as when started from Finder or at login, so it has
# only its own permissions: not the shell's (on the runner, the shell can record the screen)
open -g --stdout $PWD/build/app.log --stderr $PWD/build/app.log build/TileSpace.app
url=http://127.0.0.1:8453/mcp
mcp() { curl -s -o /dev/null -w '%{http_code}' -X POST $url -H 'Content-Type: application/json' "$@"; }
for i in {1..40}; do [[ $(mcp -d '{"jsonrpc":"2.0","id":0,"method":"ping"}') == 200 ]] && break; sleep 0.25; done
if pgrep -x TileSpace >/dev/null; then pass "menu-bar app runs"; else fail "menu-bar app exited: $(<build/app.log)"; exit 1; fi
init=$(curl -s -X POST $url -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ci","version":"1"}}}')
[[ $init == *'"name":"tilespace"'* ]] && pass "MCP initialize" || fail "MCP initialize: $init"
tools=$(curl -s -X POST $url -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
[[ $tools == *list_windows*list_desktops*snap_window*move_window_to_desktop* ]] && pass "MCP tools/list" || fail "MCP tools/list: $tools"
[[ $(mcp -H 'Origin: https://example.com' -d '{}') == 403 ]] && pass "MCP turns away browsers" || fail "MCP let a browser Origin in"

echo "--- tilespace (through the app)"
$tilespace --help | grep -q "usage: tilespace" && pass "tilespace --help" || fail "tilespace --help"
$tilespace --help | grep -q "needs a second display" && pass "tilespace --help says move needs a second display" || fail "tilespace --help doesn't say move needs a second display"
$tilespace --help | grep -q "Displays have separate Spaces" && pass "tilespace --help says move needs separate Spaces per display" || fail "tilespace --help doesn't say move needs separate Spaces per display"
$tilespace --help | grep -q '"Switch to Desktop N" shortcuts on' && pass "tilespace --help says move needs the desktop shortcuts on" || fail "tilespace --help doesn't say move needs the desktop shortcuts on"
$tilespace bogus 2>/dev/null && fail "tilespace bogus should fail" || pass "tilespace bogus fails"
# the window's title comes from Accessibility: the app has no Screen Recording access
windows=$($tilespace windows) || fail "tilespace windows: $windows"
row=${(M)${(f)windows}:#*tilespace test*}
[[ -n $row ]] && pass "tilespace windows shows the test window: $row" || fail "tilespace windows: no test window in: $windows"
[[ $row == *[0-9]\** ]] && pass "its desktop is marked showing" || fail "its desktop isn't marked showing: $row"
[[ $($tilespace list) == *"tilespace test"* ]] && pass "tilespace list (the old name)" || fail "tilespace list"
[[ $($tilespace desktops) == *1\** ]] && pass "tilespace desktops" || fail "tilespace desktops: $($tilespace desktops)"
[[ -n $($tilespace spaces) ]] && pass "tilespace spaces (the old name)" || fail "tilespace spaces printed nothing"
# moves that can't work have to say why, before anything moves
expect_error() {   # expect_error <label> <text the error has to contain> <args...>
    local label=$1 want=$2 err; shift 2
    if err=$($tilespace "$@" 2>&1); then fail "$label should fail: $err"
    elif [[ $err == *$want* ]]; then pass "$label fails: $err"
    else fail "$label: wanted an error about '$want', got: $err"; fi
}
expect_error "move on one display" "second display" move "tilespace test" 2
expect_error "move to desktop 0" "starting at 1" move "tilespace test" 0
expect_error "move to an unknown display" "no display matches" move "tilespace test" 2 nosuchdisplay
expect_error "snap an unknown window" "no window matches" snap left-half "no such window"

# Where each snap should put the window is worked out here, from the display's visible area: the
# command's reply is the window's own frame, so going by it would only compare the window with
# itself. Thirds run across, as on any landscape display (the runner's is). In this order every
# snap moves or resizes the window, so none passes by leaving it where the last one put it.
read_state
t="tilespace test"
hw=$(( vw / 2 )) hh=$(( vh / 2 ))             # the left and the top half
t1=$(( vw / 3 )) t2=$(( vw * 2 / 3 ))         # where the first and the center third end
# any id from the list works as the window argument
ids=(${(s: :)${row#*\*}})
snap_to left-half $ids[1]     $vx $vy $hw $vh
snap_to right-half $t         $(( vx + hw )) $vy $(( vw - hw )) $vh
snap_to left-half $t          $vx $vy $hw $vh
snap_to top-half $t           $vx $vy $vw $hh
snap_to bottom-half $t        $vx $(( vy + hh )) $vw $(( vh - hh ))
snap_to top-left $t           $vx $vy $hw $hh
snap_to bottom-right $t       $(( vx + hw )) $(( vy + hh )) $(( vw - hw )) $(( vh - hh ))
snap_to first-third $t        $vx $vy $t1 $vh
snap_to center-third $t       $(( vx + t1 )) $vy $(( t2 - t1 )) $vh
snap_to last-third $t         $(( vx + t2 )) $vy $(( vw - t2 )) $vh
snap_to first-two-thirds $t   $vx $vy $t2 $vh
snap_to center-two-thirds $t  $(( vx + vw / 6 )) $vy $(( vw * 5 / 6 - vw / 6 )) $vh
snap_to last-two-thirds $t    $(( vx + t1 )) $vy $(( vw - t1 )) $vh
snap_to maximize $t           $vx $vy $vw $vh
# Smaller takes 30pt off a maximized window's width and height, half from each side; Larger
# puts them back
snap_to smaller $t            $(( vx + 15 )) $(( vy + 15 )) $(( vw - 30 )) $(( vh - 30 ))
snap_to larger $t             $vx $vy $vw $vh
# Center keeps the window's size, and Maximize Height its column: a maximized window would stay
# put for both, so start from one that's neither centered nor full height
reset_window
cw=$(( rw < vw ? rw : vw )) ch=$(( rh < vh ? rh : vh ))
cx=$(( vx + (vw - cw) / 2 ))
snap_to center $t             $cx $(( vy + (vh - ch) / 2 )) $cw $ch
snap_to maximize-height $t    $cx $vy $cw $vh

echo "--- dragging"
reset_window
drag_to $(( sx + 1 )) $(( sy + sh / 2 ))
check "drag to the left edge: left half" $vx $vy $(( vw / 2 )) $vh

# dragging it away gives back its size from before; let go mid-screen, so no snap
drag_to $(( sx + sw / 2 )) $(( sy + sh / 2 ))
read_state
check "drag a snapped window away: old size" $wx $wy $rw $rh

drag_to $(( sx + sw / 2 )) $(( sy + sh - 1 ))
check "drag to the bottom edge: center third" $(( vx + vw / 3 )) $vy $(( vw * 2 / 3 - vw / 3 )) $vh

reset_window
drag_to $(( sx + 2 )) $(( sy + 2 ))
check "drag to the top-left corner: first fourth" $vx $vy $(( vw / 4 )) $vh

reset_window
drag_to $(( sx + sw - 1 )) $(( sy + sh / 2 )) esc
read_state
check "Esc during a drag: no snap" $wx $wy $rw $rh

echo "--- shortcuts"
reset_window
before=($wx $wy $ww $wh)
build/input key 124 ctrl opt          # Ctrl+Option+Right
check "Ctrl+Option+Right: right half" $(( vx + vw / 2 )) $vy $(( vw - vw / 2 )) $vh
build/input key 124 ctrl opt          # again: there's no other display, so it stays
check "Ctrl+Option+Right again, one display: stays" $(( vx + vw / 2 )) $vy $(( vw - vw / 2 )) $vh
build/input key 2 ctrl opt            # Ctrl+Option+D
check "Ctrl+Option+D: first third" $vx $vy $(( vw / 3 )) $vh
build/input key 2 ctrl opt
check "Ctrl+Option+D again: center third" $(( vx + vw / 3 )) $vy $(( vw * 2 / 3 - vw / 3 )) $vh
build/input key 51 ctrl opt           # Ctrl+Option+Delete
check "Ctrl+Option+Delete: restore" $before

echo "--- two windows of one app"
# the test app's other window is newer, and behind it: the list is front to back, and text
# that matches both means the one in front
reset_window
rows=$($tilespace windows | grep TestWindow || true)
[[ ${${(f)rows}[1]} == *"tilespace test" && ${${(f)rows}[2]} == *"tilespace behind" ]] &&
    pass "tilespace windows lists the window in front first" || fail "tilespace windows doesn't list the window in front first: $rows"
$tilespace snap left-half TestWindow >/dev/null
check "snap by app name: the window in front" $vx $vy $(( vw / 2 )) $vh

echo "--- a window that won't shrink"
# with a minimum size, 60% of the visible area each way, it can't get smaller, and it's too big
# for a half or a corner: it goes where the snap puts it, but slid back onto the display
reset_window
kill -USR2 $win; sleep 0.5; read_state; mw=$ww mh=$wh
at=($wx $wy)
$tilespace snap smaller "tilespace test" >/dev/null
check "smaller, already at its minimum size: stays where it is" $at $mw $mh
said=$($tilespace snap right-half "tilespace test")
check "right half, too wide for it: against the right edge" $(( vx + vw - mw )) $vy $mw $vh
# the reply is the frame the window took, not the half it was asked to take
replied "right half, too wide for it" right-half $said
$tilespace snap bottom-right "tilespace test" >/dev/null
check "bottom right, too big for it: in the corner" $(( vx + vw - mw )) $(( vy + vh - mh )) $mw $mh
drag_to $(( sx + sw - 1 )) $(( sy + sh / 2 ))
check "dragged to the right edge, too wide for the half: against the right edge" $(( vx + vw - mw )) $vy $mw $vh

echo "--- Rectangle"
# TileSpace leaves the shortcuts to Rectangle while it runs, and has to notice Rectangle starting
# or quitting after it did: macOS posts no launch or quit notifications for apps with no Dock icon
reset_window
before=($wx $wy $ww $wh)
open -g $rectangle
for i in {1..40}; do pgrep -x Rectangle >/dev/null && break; sleep 0.25; done
pgrep -x Rectangle >/dev/null && pass "the stand-in for Rectangle runs" || fail "the stand-in for Rectangle didn't start"
sleep 2
build/input key 124 ctrl opt          # Ctrl+Option+Right
check "Ctrl+Option+Right once Rectangle has started: left to Rectangle" $before
pkill -x Rectangle || true
while pgrep -x Rectangle >/dev/null; do sleep 0.1; done
sleep 2
build/input key 124 ctrl opt
check "Ctrl+Option+Right once Rectangle has quit: right half" $(( vx + vw / 2 )) $vy $(( vw - vw / 2 )) $vh

exit $failed
