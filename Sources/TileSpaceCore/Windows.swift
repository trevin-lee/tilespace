// Windows: CoreGraphics lists them, Accessibility moves them.
import AppKit
import ApplicationServices
import CoreGraphics

public struct Win: Equatable {
    public let id: Int
    public let pid: pid_t
    public let app: String
    public let title: String
    public let frame: CGRect
    public let display: String       // UUID of the display whose desktop it's on
    public let displayName: String
    public let desktop: Int          // which desktop of that display, from 1
    public let showing: Bool         // its desktop is showing, so it can be snapped or moved

    public init(id: Int, pid: pid_t, app: String, title: String, frame: CGRect,
                display: String, displayName: String, desktop: Int, showing: Bool) {
        self.id = id; self.pid = pid; self.app = app; self.title = title; self.frame = frame
        self.display = display; self.displayName = displayName; self.desktop = desktop; self.showing = showing
    }

    // "Zen — GitHub", or just "Zen" when the title isn't known
    public var label: String { title.isEmpty ? app : "\(app) — \(title)" }
}

// Every window on every desktop (Space), frontmost first: normal windows at least 100pt each
// way, on one of the user's desktops (so not full-screen apps' windows). The window list
// and the window argument of every command both go by this, so any id from the list works.
//
// macOS only gives out other apps' window titles with Screen Recording access, which TileSpace
// doesn't ask for, so titles come from Accessibility instead. That only reaches windows on
// desktops that are showing; the rest have no title (unless the app does have Screen Recording).
//
// Apps keep invisible windows around too (closed to the menu bar, or helper processes'), and
// with no titles to go by, they have to be told apart some other way. On a showing desktop,
// a real window is one Accessibility knows about (or, if the app doesn't answer, one that's
// on screen). On other desktops nothing can tell, so only regular apps' windows are listed.
public func allWindows() -> [Win] {
    let displays = managedSpaces()
    var desktopOf: [Int: (display: DisplaySpaces, index: Int)] = [:]
    for d in displays { for (i, s) in d.spaces.enumerated() { desktopOf[s] = (d, i + 1) } }
    var names: [String: String] = [:]
    for d in displays { names[d.uuid] = displayName(d.uuid) }
    var axTitles: [pid_t: [Int: String]?] = [:]   // nil for an app that didn't answer
    var regular: [pid_t: Bool] = [:]

    let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return info.compactMap { w in
        guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.width >= 100, r.height >= 100,
              let id = w[kCGWindowNumber as String] as? Int, let pid = w[kCGWindowOwnerPID as String] as? pid_t
        else { return nil }
        let on = spaces(of: id).compactMap { desktopOf[$0] }
        guard let first = on.first else { return nil }
        let shown = on.first { $0.display.current == $0.display.spaces[$0.index - 1] }
        let at = shown ?? first
        var title = w[kCGWindowName as String] as? String ?? ""
        if shown != nil {
            if axTitles[pid] == nil { axTitles[pid] = .some(windowTitles(of: pid)) }
            if let titles = axTitles[pid]! {
                guard let t = titles[id] else { return nil }
                if title.isEmpty { title = t }
            } else if w[kCGWindowIsOnscreen as String] as? Bool != true { return nil }
        } else {
            if regular[pid] == nil { regular[pid] = NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular }
            if regular[pid] != true { return nil }
        }
        return Win(id: id, pid: pid, app: w[kCGWindowOwnerName as String] as? String ?? "?", title: title, frame: r,
                   display: at.display.uuid, displayName: names[at.display.uuid] ?? at.display.uuid,
                   desktop: at.index, showing: shown != nil)
    }
}

// An app's window titles by window id, for its windows on desktops that are showing ("" for
// an untitled one); nil if the app doesn't answer.
func windowTitles(of pid: pid_t) -> [Int: String]? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1)   // don't let one hung app stall the list for long
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success,
          let els = v as? [AXUIElement] else { return nil }
    var out: [Int: String] = [:]
    for el in els {
        guard let id = windowID(of: el) else { continue }
        var t: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &t)
        out[id] = t as? String ?? ""
    }
    return out
}

// The window a command names: a window id, or text matched case-insensitively against
// "<app> <title>". Windows on a showing desktop come first, frontmost first; one on a desktop
// that isn't showing can't be reached through Accessibility, so that's an error saying where it is.
public func findWindow(_ q: String, in wins: [Win]? = nil) throws -> Win {
    let wins = wins ?? allWindows()
    let ql = q.lowercased()
    let matches = Int(q).map { id in wins.filter { $0.id == id } }
        ?? wins.filter { "\($0.app) \($0.title)".lowercased().contains(ql) }
    if let w = matches.first(where: \.showing) { return w }
    guard let w = matches.first else {
        throw TileSpaceError("no window matches '\(q)'; `tilespace windows` lists them")
    }
    throw TileSpaceError("\(w.label) is on desktop \(w.desktop) of \(w.displayName), which isn't showing. Switch to that desktop first.")
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
