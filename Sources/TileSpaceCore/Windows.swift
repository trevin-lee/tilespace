// Windows: CoreGraphics lists them, Accessibility moves them.
import AppKit
import ApplicationServices
import CoreGraphics

public struct Win {
    public let id: Int
    public let pid: pid_t
    public let app: String
    public let title: String
    public let frame: CGRect
}

public func onScreenWindows() -> [Win] {
    let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return l.compactMap { w in
        guard (w["kCGWindowLayer"] as? Int) == 0,
              let b = w["kCGWindowBounds"] as? [String: Any],
              let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.width > 100, r.height > 100
        else { return nil }
        return Win(id: w["kCGWindowNumber"] as! Int, pid: w["kCGWindowOwnerPID"] as! pid_t,
                   app: w["kCGWindowOwnerName"] as? String ?? "?", title: w["kCGWindowName"] as? String ?? "", frame: r)
    }
}

// A window id, or text matched against "<app> <title>" (case-insensitive, first match).
public func find(_ q: String) -> Win? {
    let wins = onScreenWindows()
    if let id = Int(q) { return wins.first { $0.id == id } }
    let ql = q.lowercased()
    return wins.first { "\($0.app) \($0.title)".lowercased().contains(ql) }
}

// The CoreGraphics window id of an accessibility element.
typealias GetWinFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
let getWin = unsafeBitCast(dlsym(dlopen(nil, RTLD_NOW), "_AXUIElementGetWindow"), to: GetWinFn.self)

public func windowID(of el: AXUIElement) -> Int? {
    var id: CGWindowID = 0
    return getWin(el, &id) == .success ? Int(id) : nil
}

// The accessibility element for a CoreGraphics window.
public func axWindow(_ w: Win) -> AXUIElement? {
    var v: CFTypeRef?
    let app = AXUIElementCreateApplication(w.pid)
    AXUIElementSetMessagingTimeout(app, 5)   // some apps (FreeCAD) answer slowly
    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v)
    return (v as? [AXUIElement] ?? []).first { windowID(of: $0) == w.id }
}

// The frontmost app's focused window.
public func focusedWindow() -> AXUIElement? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &v) == .success,
          let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}

// The window at a point on screen (whichever app's it is).
public func window(at p: CGPoint) -> AXUIElement? {
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.5)
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &hit) == .success, let hit else { return nil }
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &role)
    if (role as? String) == kAXWindowRole { return hit }
    var w: CFTypeRef?
    guard AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &w) == .success,
          let w, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
    return (w as! AXUIElement)
}

// A window's frame from the window server: cheaper than asking the app, so it suits
// checking on every mouse event of a drag.
public func windowFrame(_ id: Int) -> CGRect? {
    let l = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]]
    guard let b = l?.first?["kCGWindowBounds"] as? [String: Any] else { return nil }
    return CGRect(dictionaryRepresentation: b as CFDictionary)
}

public func frame(of el: AXUIElement) -> CGRect? {
    var p: CFTypeRef?, s: CFTypeRef?
    var origin = CGPoint.zero, size = CGSize.zero
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success,
          AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: origin, size: size)
}

public func setFrame(_ el: AXUIElement, _ r: CGRect) {
    var size = r.size, origin = r.origin
    // Apps with AXEnhancedUserInterface on (Chrome, Electron, anything when VoiceOver has been
    // used) animate each change and end up in the wrong place, so turn it off meanwhile.
    var app: AXUIElement?, pid: pid_t = 0
    if AXUIElementGetPid(el, &pid) == .success { app = AXUIElementCreateApplication(pid) }
    var enhanced: CFTypeRef?
    let wasEnhanced = app.map { AXUIElementCopyAttributeValue($0, "AXEnhancedUserInterface" as CFString, &enhanced) == .success
        && (enhanced as? Bool) == true } ?? false
    if wasEnhanced { AXUIElementSetAttributeValue(app!, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
    // size, then position, then size again: macOS clamps size to the display it's on
    AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
    AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    if wasEnhanced { AXUIElementSetAttributeValue(app!, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
}
