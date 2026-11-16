// Displays. Everything here uses Accessibility/CoreGraphics coordinates: origin at the
// top-left of the main display, y growing down (NSScreen's are flipped, origin bottom-left).
import AppKit
import CoreGraphics

public func displayUUID(_ id: CGDirectDisplayID) -> String? {
    guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
    return CFUUIDCreateString(nil, u) as String
}

public func displayUUID(containing p: CGPoint) -> String? {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetDisplaysWithPoint(p, 16, &ids, &n)
    return n > 0 ? displayUUID(ids[0]) : nil
}

public func displayName(_ uuid: String) -> String {
    // with "Displays have separate Spaces" off, SkyLight reports every display as one, "Main"
    if uuid == sharedSpacesDisplay { return "All displays" }
    for s in NSScreen.screens where displayUUID(s.displayID) == uuid { return s.localizedName }
    return uuid
}

let sharedSpacesDisplay = "Main"

public func displayBounds(_ uuid: String) -> CGRect? {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).first { displayUUID($0) == uuid }.map { CGDisplayBounds($0) }
}

extension NSScreen {
    var displayID: CGDirectDisplayID { deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID }
}

// A display as the snap actions see it.
public struct Screen: Equatable {
    public let name: String
    public let frame: CGRect     // whole display
    public let visible: CGRect   // minus the menu bar and Dock
    public init(name: String, frame: CGRect, visible: CGRect) { self.name = name; self.frame = frame; self.visible = visible }
}

// Every display, top to bottom, then left to right (Rectangle's default order).
public func screens() -> [Screen] {
    // Without an NSApplication, visibleFrame leaves out the menu bar on displays other than
    // the main one (the Odyssey reports 2160 tall instead of 2130). Creating it is enough.
    _ = NSApplication.shared
    guard let mainHeight = NSScreen.screens.first?.frame.height else { return [] }
    func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height) }
    return NSScreen.screens
        .map { Screen(name: $0.localizedName, frame: flip($0.frame), visible: flip($0.visibleFrame)) }
        .sorted { a, b in
            if a.frame.maxY <= b.frame.minY { return true }
            if b.frame.maxY <= a.frame.minY { return false }
            return a.frame.minX < b.frame.minX
        }
}

// The display most of a window is on.
public func screen(for frame: CGRect, in all: [Screen]) -> Screen? {
    func overlap(_ s: Screen) -> CGFloat { let i = s.frame.intersection(frame); return i.isNull ? 0 : i.width * i.height }
    if let best = all.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 { return best }
    return all.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) } ?? all.first
}
