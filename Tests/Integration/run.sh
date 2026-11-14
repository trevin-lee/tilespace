#!/bin/zsh
# End-to-end checks on a real window: start TileSpace.app (the core, with its MCP server) the
# way Finder does, open a test window, then snap it through the `tilespace` command (a client of
# the app's server), by dragging it to screen edges, and with the app's shortcuts, checking where
# it lands each time. It takes over the mouse and keyboard, so it's meant for CI (a macOS
# runner), not a desk.
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
if ! build/trusted; then
    echo "no Accessibility access: allow the app running this in System Settings > Privacy & Security > Accessibility"
    exit 1
fi

state=$(mktemp)
build/TestWindow $state & win=$!
trap 'kill $win 2>/dev/null; pkill -x TileSpace' EXIT
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

# any id from the list works as the window argument
ids=(${(s: :)${row#*\*}})
said=$($tilespace snap left-half $ids[1])
want=(${(s: :)${${said#*: }/,/ }/x/ })
check "snap left-half by window id $ids[1]" $want

for action in left-half right-half top-half bottom-half top-left bottom-right \
              first-third center-third last-third first-two-thirds center-two-thirds last-two-thirds \
              maximize smaller larger center maximize-height; do
    # prints e.g. "left-half: 0,25 720x875"
    said=$($tilespace snap $action "tilespace test")
    want=(${(s: :)${${said#*: }/,/ }/x/ })
    check "snap $action" $want
done

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

exit $failed
