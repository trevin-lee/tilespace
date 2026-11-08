// The window commands that the app runs for the CLI and MCP clients: listing windows and
// desktops, and moving a window to another desktop.
import AppKit
import ApplicationServices
import CoreGraphics

public struct TileSpaceError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

// Every titled window on every desktop, one per line:
//   <display> <desktop>  <id>  <app>  <x>,<y> <width>x<height>  <title>
public func listWindows() -> String {
    var label: [Int: String] = [:]
    for d in managedSpaces() { for (i, id) in d.spaces.enumerated() { label[id] = "\(displayName(d.uuid).prefix(10)) \(i + 1)" } }
    let l = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var rows: [String] = []
    for w in l where (w["kCGWindowLayer"] as? Int) == 0 {
        guard let b = w["kCGWindowBounds"] as? [String: Any], let r = CGRect(dictionaryRepresentation: b as CFDictionary),
              r.width > 100, r.height > 100, let t = w["kCGWindowName"] as? String, !t.isEmpty else { continue }
        let id = w["kCGWindowNumber"] as! Int
        let where_ = spaces(of: id).compactMap { label[$0] }.joined(separator: ",")
        if where_.isEmpty { continue }
        let frame = "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
        rows.append(String(format: "%-13@ %6d  %-18@ %-22@ %@", where_ as NSString, id,
                           String((w["kCGWindowOwnerName"] as? String ?? "?").prefix(18)) as NSString, frame as NSString, t as NSString))
    }
    return rows.sorted().joined(separator: "\n")
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

// Move a window to desktop `target` (1-based) on its own display, or on `display` (matched
// against display names). macOS has no API for this, but moving a window onto another display
// puts it on whichever desktop that display is showing. So: park the window on the other
// display, switch its home display to the target desktop, move it back to exactly where it
// was. Presses the "Switch to Desktop N" shortcuts, so it blocks for a couple of seconds.
public func moveWindow(_ query: String, toDesktop target: Int, display: String? = nil, follow: Bool = false) throws -> String {
    guard target >= 1 else { throw TileSpaceError("desktop must be a number starting at 1") }
    guard let w = find(query) else { throw TileSpaceError("no window on a showing desktop matches '\(query)'") }
    let all = managedSpaces()

    if let display {
        // to a desktop on another display: show that desktop there, then move the window onto it
        guard let d = all.first(where: { displayName($0.uuid).lowercased().contains(display.lowercased()) }),
              let dest = displayBounds(d.uuid) else { throw TileSpaceError("no display matches '\(display)'") }
        guard target <= d.spaces.count else { throw TileSpaceError("\(displayName(d.uuid)) only has \(d.spaces.count) desktops") }
        let offset = all.prefix(while: { $0.uuid != d.uuid }).reduce(0) { $0 + $1.spaces.count }
        guard let el = axWindow(w) else { throw TileSpaceError("can't reach \(w.app)'s window through Accessibility") }
        if d.current != d.spaces[target - 1] { switchTo(offset + target) }
        let size = CGSize(width: min(w.frame.width, dest.width - 80), height: min(w.frame.height, dest.height - 100))
        place(el, CGRect(x: dest.midX - size.width / 2, y: dest.midY - size.height / 2, width: size.width, height: size.height))
        usleep(300_000)
        guard spaces(of: w.id) == [d.spaces[target - 1]] else { throw TileSpaceError("\(w.app) didn't land on desktop \(target)") }
        return "moved \(w.app) — \(w.title) to desktop \(target) on \(displayName(d.uuid))"
    }

    // which display/desktop the window belongs to (by desktop membership, so it works even
    // for a window hanging off the edge of its screen)
    let mine = spaces(of: w.id)
    guard let d = all.first(where: { $0.spaces.contains { mine.contains($0) } }),
          let cur = d.spaces.firstIndex(where: { mine.contains($0) }), d.spaces[cur] == d.current
    else { throw TileSpaceError("couldn't work out which desktop the window is on, or that desktop isn't showing") }
    guard target <= d.spaces.count else { throw TileSpaceError("\(displayName(d.uuid)) only has \(d.spaces.count) desktops") }
    if target - 1 == cur { return "already on desktop \(target)" }
    let offset = all.prefix(while: { $0.uuid != d.uuid }).reduce(0) { $0 + $1.spaces.count }
    guard offset + target <= 16 else { throw TileSpaceError("macOS only has shortcuts for 16 desktops") }
    guard let other = all.first(where: { $0.uuid != d.uuid }), let park = displayBounds(other.uuid)
    else { throw TileSpaceError("needs a second display to park the window on") }
    guard let el = axWindow(w) else { throw TileSpaceError("can't reach \(w.app)'s window through Accessibility") }

    // 1. park it on the other display (it joins whatever desktop is showing there)
    place(el, CGRect(x: park.minX + 40, y: park.minY + 60,
                     width: min(w.frame.width, park.width - 80), height: min(w.frame.height, park.height - 100)))
    // 2. show the target desktop on the home display; 3. bring the window back
    switchTo(offset + target)
    place(el, w.frame)
    usleep(300_000)
    let arrived = spaces(of: w.id) == [d.spaces[target - 1]]
    if !follow { switchTo(offset + cur + 1) }
    guard arrived else { throw TileSpaceError("\(w.app) didn't land on desktop \(target)") }
    return "moved \(w.app) — \(w.title) to desktop \(target) on \(displayName(d.uuid))"
}
