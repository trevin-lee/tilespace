// The window commands that the app runs for the CLI and MCP clients: listing windows and
// desktops, and moving a window to another desktop.
import AppKit
import ApplicationServices
import CoreGraphics

public struct TileSpaceError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

// Every window on every desktop, one per line, by display and desktop, frontmost first:
//   <display> <desktop>[*]  <id>  <app>  <x>,<y> <width>x<height>  <title>
// where * marks a desktop that's showing (only those windows can be snapped or moved).
public func listWindows() -> String {
    let out = formatWindows(allWindows(), displayOrder: managedSpaces().map(\.uuid))
    return out.isEmpty ? "no windows" : out
}

func formatWindows(_ wins: [Win], displayOrder: [String]) -> String {
    var rank: [String: Int] = [:]
    for (i, uuid) in displayOrder.enumerated() where rank[uuid] == nil { rank[uuid] = i }
    return wins.enumerated()
        .sorted { a, b in
            (rank[a.element.display] ?? .max, a.element.desktop, a.offset) < (rank[b.element.display] ?? .max, b.element.desktop, b.offset)
        }
        .map { _, w in
            let at = "\(w.displayName.prefix(10)) \(w.desktop)\(w.showing ? "*" : "")"
            let frame = "\(Int(w.frame.minX)),\(Int(w.frame.minY)) \(Int(w.frame.width))x\(Int(w.frame.height))"
            let row = String(format: "%-13@ %6d  %-18@ %-22@ %@", at as NSString, w.id, String(w.app.prefix(18)) as NSString,
                             frame as NSString, w.title as NSString)
            return row.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        .joined(separator: "\n")
}

// Desktops per display, with * on the one showing: "Odyssey G95NC: 1 2 3* 4"
public func listDesktops() -> String {
    managedSpaces().map { d in
        "\(displayName(d.uuid)): " + d.spaces.enumerated().map { "\($0.offset + 1)\($0.element == d.current ? "*" : "")" }.joined(separator: " ")
    }.joined(separator: "\n")
}

// set a frame and give the app time to apply it, for the steps of a move
private func place(_ el: AXUIElement, _ r: CGRect) {
    setFrame(el, r)
    usleep(250_000)
}

// How a move goes, worked out before anything moves.
struct MovePlan: Equatable {
    let display: String     // the display the window ends up on
    let park: String?       // for a move between desktops of one display: the display to park it on meanwhile
    let target: Int         // the target desktop's ManagedSpaceID
    let switchTo: Int?      // the desktop shortcut that shows the target desktop (nil if it's showing already)
    let switchBack: Int?    // the shortcut that switches back afterwards (nil when following)
}

// Plan moving a window that's on desktop `desktop` of display `home` (showing) to desktop
// `target` of the display matching `display`, or of its own display. nil if it's there already.
func planMove(from home: String, desktop: Int, to target: Int, display: String?, follow: Bool,
              displays: [DisplaySpaces], name: (String) -> String) throws -> MovePlan? {
    guard target >= 1 else { throw TileSpaceError("desktop must be a number starting at 1") }
    let dest: DisplaySpaces
    if let display {
        guard let d = displays.first(where: { name($0.uuid).lowercased().contains(display.lowercased()) }) else {
            throw TileSpaceError("no display matches '\(display)'; `tilespace desktops` lists them")
        }
        dest = d
    } else {
        guard let d = displays.first(where: { $0.uuid == home }) else { throw TileSpaceError("can't tell which display the window is on") }
        dest = d
    }
    let destName = name(dest.uuid)
    let park = dest.uuid == home ? displays.first { $0.uuid != home } : nil
    if dest.uuid == home && park == nil {
        throw TileSpaceError("moving a window to another desktop of the same display needs a second display to park it on meanwhile")
    }
    guard target <= dest.spaces.count else {
        throw TileSpaceError("\(destName) has only \(dest.spaces.count) desktop\(dest.spaces.count == 1 ? "" : "s")")
    }
    if dest.uuid == home && target == desktop { return nil }

    // the shortcuts number desktops across all displays, in this order
    let offset = displays.prefix(while: { $0.uuid != dest.uuid }).reduce(0) { $0 + $1.spaces.count }
    func shortcut(_ n: Int) throws -> Int {
        guard offset + n <= maxDesktopShortcut else {
            throw TileSpaceError("desktop \(n) of \(destName) is desktop \(offset + n) counting across displays, and macOS only has shortcuts for the first \(maxDesktopShortcut)")
        }
        return offset + n
    }
    let showing = dest.spaces.firstIndex(of: dest.current).map { $0 + 1 }   // nil if a full-screen app is showing
    let to = showing == target ? nil : try shortcut(target)
    let back = to == nil || follow ? nil : try showing.map(shortcut)
    return MovePlan(display: dest.uuid, park: park?.uuid, target: dest.spaces[target - 1], switchTo: to, switchBack: back)
}

// Move a window to desktop `target` (from 1) on its own display, or on `display` (matched
// against display names). macOS has no API for this, but moving a window onto another display
// puts it on whichever desktop that display is showing. So, within one display: park the
// window on another display, switch its own display to the target desktop, and move it back
// to exactly where it was. To another display: show the target desktop there and move the
// window over. Either way it switches back afterwards unless `follow`. Presses the "Switch to
// Desktop N" shortcuts, so it blocks for a couple of seconds.
public func moveWindow(_ query: String, toDesktop target: Int, display: String? = nil, follow: Bool = false) throws -> String {
    guard target >= 1 else { throw TileSpaceError("desktop must be a number starting at 1") }
    let w = try findWindow(query)
    guard let plan = try planMove(from: w.display, desktop: w.desktop, to: target, display: display, follow: follow,
                                  displays: managedSpaces(), name: displayName)
    else { return "\(w.label) is already on desktop \(target)" }
    guard let el = axWindow(w) else { throw TileSpaceError("can't reach \(w.app)'s window through Accessibility") }
    let destName = displayName(plan.display)

    if let park = plan.park {
        guard let p = displayBounds(park) else { throw TileSpaceError("can't find the display to park the window on") }
        // 1. park it on the other display (it joins whatever desktop is showing there)
        place(el, CGRect(x: p.minX + 40, y: p.minY + 60, width: min(w.frame.width, p.width - 80), height: min(w.frame.height, p.height - 100)))
        // 2. show the target desktop on its own display (if that fails, its old desktop is still showing: go back)
        do { try show(plan) } catch { place(el, w.frame); throw error }
        // 3. bring it back
        place(el, w.frame)
    } else {
        guard let dest = displayBounds(plan.display) else { throw TileSpaceError("can't find \(destName)") }
        try show(plan)
        let size = CGSize(width: min(w.frame.width, dest.width - 80), height: min(w.frame.height, dest.height - 100))
        place(el, CGRect(x: dest.midX - size.width / 2, y: dest.midY - size.height / 2, width: size.width, height: size.height))
    }
    usleep(300_000)
    let arrived = spaces(of: w.id) == [plan.target]
    if let back = plan.switchBack { try? switchTo(back) }
    guard arrived else { throw TileSpaceError("\(w.label) didn't land on desktop \(target)") }
    return "moved \(w.label) to desktop \(target) on \(destName)"
}

// Press the shortcut that shows the plan's target desktop, and check that macOS switched.
private func show(_ plan: MovePlan) throws {
    guard let n = plan.switchTo else { return }
    try switchTo(n)
    guard managedSpaces().first(where: { $0.uuid == plan.display })?.current == plan.target else {
        throw TileSpaceError("macOS didn't switch desktops. Turn on \"Switch to Desktop \(n)\" in System Settings > Keyboard > Keyboard Shortcuts > Mission Control.")
    }
}
