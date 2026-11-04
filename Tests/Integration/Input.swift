// Posts real mouse and key events, for the integration test.
//   input drag x1 y1 x2 y2 [esc]   press at x1,y1, drag to x2,y2, hold, release
//                                  (esc: press Escape while holding)
//   input key <code> [ctrl] [opt] [cmd] [shift]
// Coordinates have a top-left origin, like Accessibility.
import CoreGraphics
import Foundation

let a = Array(CommandLine.arguments.dropFirst())

func mouse(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap)
}

func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    var flags = flags
    // a real keyboard marks arrow keys as numeric-pad and Fn keys
    if (123...126).contains(code) { flags.formUnion([.maskNumericPad, .maskSecondaryFn]) }
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        e.flags = flags
        e.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}

switch a.first {
case "drag":
    let n = a[1...4].map { Double($0)! }
    let from = CGPoint(x: n[0], y: n[1]), to = CGPoint(x: n[2], y: n[3])
    mouse(.mouseMoved, from); usleep(100_000)
    mouse(.leftMouseDown, from); usleep(150_000)
    for i in 1...30 {
        let t = Double(i) / 30
        mouse(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        usleep(20_000)
    }
    usleep(400_000)   // hold at the edge, as a person would
    if a.count > 5, a[5] == "esc" { key(53); usleep(200_000) }
    mouse(.leftMouseUp, to)
case "key":
    var flags: CGEventFlags = []
    for m in a.dropFirst(2) {
        switch m {
        case "ctrl": flags.insert(.maskControl)
        case "opt": flags.insert(.maskAlternate)
        case "cmd": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        default: break
        }
    }
    key(CGKeyCode(a[1])!, flags)
default:
    print("usage: input drag x1 y1 x2 y2 [esc] | input key <code> [ctrl] [opt] [cmd] [shift]")
    exit(1)
}
