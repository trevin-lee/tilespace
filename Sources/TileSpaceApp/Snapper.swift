// Runs snap actions on the focused window, remembering each window's last snap (so repeats
// cycle and cross displays) and its frame from before the first one (for Restore).
import AppKit
import Carbon
import TileSpaceCore

// Rectangle's Magnet-style defaults, the set in use before this app.
let shortcuts: [SnapAction: Shortcut] = {
    let co: NSEvent.ModifierFlags = [.control, .option]
    return [
        .leftHalf: Shortcut(key: UInt32(kVK_LeftArrow), mods: co),
        .rightHalf: Shortcut(key: UInt32(kVK_RightArrow), mods: co),
        .topHalf: Shortcut(key: UInt32(kVK_UpArrow), mods: co),
        .bottomHalf: Shortcut(key: UInt32(kVK_DownArrow), mods: co),
        .topLeft: Shortcut(key: UInt32(kVK_ANSI_U), mods: co),
        .topRight: Shortcut(key: UInt32(kVK_ANSI_I), mods: co),
        .bottomLeft: Shortcut(key: UInt32(kVK_ANSI_J), mods: co),
        .bottomRight: Shortcut(key: UInt32(kVK_ANSI_K), mods: co),
        .firstThird: Shortcut(key: UInt32(kVK_ANSI_D), mods: co),
        .centerThird: Shortcut(key: UInt32(kVK_ANSI_F), mods: co),
        .lastThird: Shortcut(key: UInt32(kVK_ANSI_G), mods: co),
        .firstTwoThirds: Shortcut(key: UInt32(kVK_ANSI_E), mods: co),
        .centerTwoThirds: Shortcut(key: UInt32(kVK_ANSI_R), mods: co),
        .lastTwoThirds: Shortcut(key: UInt32(kVK_ANSI_T), mods: co),
        .maximize: Shortcut(key: UInt32(kVK_Return), mods: co),
        .maximizeHeight: Shortcut(key: UInt32(kVK_UpArrow), mods: co.union(.shift)),
        .center: Shortcut(key: UInt32(kVK_ANSI_C), mods: co),
        .larger: Shortcut(key: UInt32(kVK_ANSI_Equal), mods: co),
        .smaller: Shortcut(key: UInt32(kVK_ANSI_Minus), mods: co),
        .restore: Shortcut(key: UInt32(kVK_Delete), mods: co),
        .previousDisplay: Shortcut(key: UInt32(kVK_LeftArrow), mods: co.union(.command)),
        .nextDisplay: Shortcut(key: UInt32(kVK_RightArrow), mods: co.union(.command)),
    ]
}()

final class Snapper {
    private struct Record { let last: LastSnap; let frame: CGRect; let restore: CGRect }
    private var records: [Int: Record] = [:]   // by window id

    // Snap a window (the focused one if nil); returns the action applied and the frame the
    // window ended up with, which is its own to decide: apps can round a size or refuse it.
    @discardableResult
    func run(_ action: SnapAction, on window: AXUIElement? = nil) throws -> SnapResult {
        guard let el = window ?? focusedWindow() else { throw TileSpaceError("the frontmost app has no focused window") }
        guard let id = windowID(of: el), let f = frame(of: el) else { throw TileSpaceError("can't read that window's frame") }
        let rec = records[id]
        if action == .restore {
            guard let rec else { throw TileSpaceError("that window hasn't been snapped, so there's nothing to restore") }
            setFrame(el, rec.restore)
            records[id] = nil
            return SnapResult(rect: frame(of: el) ?? rec.restore, result: .restore)
        }
        // the last snap only counts if the window is still where it put it
        let untouched = rec.map { close($0.frame, f) } ?? false
        let displays = screens()
        guard let r = snap(action, window: f, last: untouched ? rec!.last : nil, screens: displays) else {
            // nil for Previous and Next Display with only one display, and with no display at all
            throw TileSpaceError(displays.count == 1 ? "there's no other display to move this window to"
                                                     : "can't tell which display this window is on")
        }
        // where it actually went: apps can round the size (Terminal snaps to rows), or keep a
        // bigger one, and then the window is moved to fit on the display
        var went = settle(action, at: r.rect, from: f, screens: displays, set: { setFrame(el, $0) }, read: { frame(of: el) })
        func stuck() -> Bool { !took(action, asked: r.rect, from: f, now: went, screens: displays) }
        if stuck() {
            usleep(150_000)   // an app can be slow to apply a frame: look again before saying so
            went = frame(of: el) ?? went
            if stuck() {
                throw TileSpaceError("that window didn't move: it's still at \(describe(went)). A full-screen window can't be snapped.")
            }
        }
        records[id] = Record(last: LastSnap(pressed: action, result: r.result), frame: went,
                             restore: untouched ? rec!.restore : f)
        return SnapResult(rect: went, result: r.result)
    }

    // The frame from before a window's first snap, if it's still where its last snap put it.
    func restoreFrame(of id: Int, at frame: CGRect) -> CGRect? {
        guard let rec = records[id], close(rec.frame, frame) else { return nil }
        return rec.restore
    }

    func forget(_ id: Int) { records[id] = nil }

    // Snap a window dropped on a snap area; Restore will put it back at `restore`.
    func drop(_ el: AXUIElement, id: Int, on t: DropTarget, restore: CGRect) {
        let went = settle(t.action, at: t.rect, from: frame(of: el) ?? t.rect, screens: screens(),
                          set: { setFrame(el, $0) }, read: { frame(of: el) })
        records[id] = Record(last: LastSnap(pressed: t.action, result: t.action), frame: went, restore: restore)
    }

    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }
}
