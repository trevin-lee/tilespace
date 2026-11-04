#!/bin/zsh
# End-to-end checks on a real window: open a test window, then snap it with `tilespace snap`,
# by dragging it to screen edges with the app running, and with the app's shortcuts, checking
# where it lands each time. It takes over the mouse and keyboard, so it's meant for CI (a
# macOS runner), not a desk.
#
# Needs Accessibility access for whatever runs it (on a Mac: the terminal app).
set -euo pipefail
cd "${0:A:h}/../.."

swift build -c release
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
app=
trap 'kill $win $app 2>/dev/null' EXIT
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

echo "--- tilespace snap"
for action in left-half right-half top-half bottom-half top-left bottom-right \
              first-third center-third last-third first-two-thirds center-two-thirds last-two-thirds \
              maximize smaller larger center maximize-height; do
    # prints e.g. "left-half: 0,25 720x875"
    said=$($tilespace snap $action "tilespace test")
    want=(${(s: :)${${said#*: }/,/ }/x/ })
    check "snap $action" $want
done

echo "--- the app"
.build/release/TileSpaceApp & app=$!
sleep 3
if kill -0 $app 2>/dev/null; then echo "ok    menu-bar app runs"
else echo "FAIL  menu-bar app exited"; exit 1; fi

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
