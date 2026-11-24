// Adding and removing desktops. macOS has no API for it (SkyLight can only do it from inside the
// Dock, which needs SIP off), but Mission Control's own controls can be worked through
// Accessibility with SIP on: its "+" button adds a desktop to a display, and each desktop's
// button has a "remove desktop" action. So TileSpace shows Mission Control for a moment, uses
// those, and puts it away again. Its interface belongs to the Dock up to macOS 26 and to
// WindowManager from macOS 27 on, so both are searched.
import AppKit
import ApplicationServices

// Which display gets a new desktop: the one `display` names, or else `home` (the frontmost
// window's), or the only display there is.
func planAddDesktop(display: String?, home: String?, displays: [DisplaySpaces], name: (String) -> String) throws -> DisplaySpaces {
    guard let d = try findDisplay(display, displays: displays, name: name)
            ?? displays.first(where: { $0.uuid == home }) ?? (displays.count == 1 ? displays.first : nil) else {
        throw TileSpaceError("which display? There's no frontmost window to go by, so name one, e.g. --display built-in")
    }
    return d
}

// The refusal to remove a desktop with windows on it. Each caller says how to remove it anyway:
// the MCP tool names its move_windows parameter, and the command line its --move-windows option.
public struct WindowsOnDesktop: Error, CustomStringConvertible {
    public let description: String
}
public let moveWindowsHint = "Set move_windows to true to remove it anyway, and macOS moves the windows to another desktop."
public let moveWindowsOptionHint = "Add --move-windows to remove it anyway, and macOS moves the windows to another desktop."

struct RemovePlan: Equatable {
    let display: String
    let space: Int       // the desktop's ManagedSpaceID
    let button: Int      // its place in Mission Control's row of spaces, from 0
}

// Removing desktop `n` (from 1) of a display. Never the one showing, never a display's last, and
// not one with windows on it unless `moveWindows`: macOS would move them to another desktop.
func planRemoveDesktop(_ n: Int, display: String?, home: String?, displays: [DisplaySpaces], windows: [Win],
                       moveWindows: Bool, name: (String) -> String) throws -> RemovePlan {
    guard n >= 1 else { throw TileSpaceError("desktop must be a number starting at 1") }
    let d = try planAddDesktop(display: display, home: home, displays: displays, name: name)
    let dName = name(d.uuid)
    guard n <= d.spaces.count else {
        throw TileSpaceError("\(dName) has only \(d.spaces.count) desktop\(d.spaces.count == 1 ? "" : "s")")
    }
    guard d.spaces.count > 1 else { throw TileSpaceError("desktop 1 is \(dName)'s only desktop, and a display always keeps one") }
    let space = d.spaces[n - 1]
    guard space != d.current else {
        throw TileSpaceError("desktop \(n) of \(dName) is showing, and TileSpace doesn't remove the desktop you're on. Switch to another one first.")
    }
    let on = windows.filter { $0.display == d.uuid && $0.desktop == n }
    if !on.isEmpty && !moveWindows {
        let names = on.map { "\($0.label) (\($0.id))" }.joined(separator: ", ")
        throw WindowsOnDesktop(description: "desktop \(n) of \(dName) has \(on.count == 1 ? "a window" : "\(on.count) windows") on it: \(names).")
    }
    guard let button = (d.all ?? d.spaces).firstIndex(of: space) else { throw TileSpaceError("can't find desktop \(n) of \(dName) in Mission Control") }
    return RemovePlan(display: d.uuid, space: space, button: button)
}

// The desktop number a Mission Control button names ("Desktop 3"), if it names one.
func desktopNumber(in description: String) -> Int? {
    let parts = description.split(separator: " ")
    guard parts.count == 2, parts[0] == "Desktop" else { return nil }
    return Int(parts[1])
}

// Add a desktop to a display: the one `display` names, or else the frontmost window's.
public func addDesktop(display: String? = nil) throws -> String {
    let displays = managedSpaces()
    let home = display == nil ? (try? frontmostWindow())?.display : nil
    let d = try planAddDesktop(display: display, home: home, displays: displays, name: displayName)
    let dName = displayName(d.uuid)
    try inMissionControl(display: d.uuid) { spaces in
        guard let add = descendant(of: spaces, id: "mc.spaces.add") else {
            throw TileSpaceError("Mission Control shows no button to add a desktop to \(dName); it may already have as many as macOS allows")
        }
        guard AXUIElementPerformAction(add, kAXPressAction as CFString) == .success else {
            throw TileSpaceError("Mission Control didn't take the press of its add button")
        }
    }
    guard waitUntil({ (managedSpaces().first { $0.uuid == d.uuid }?.spaces.count ?? 0) > d.spaces.count }) else {
        throw TileSpaceError("Mission Control didn't add a desktop to \(dName)")
    }
    return "added desktop \(d.spaces.count + 1) to \(dName)"
}

// Remove desktop `n` (from 1) of a display: the one `display` names, or else the frontmost window's.
public func removeDesktop(_ n: Int, display: String? = nil, moveWindows: Bool = false) throws -> String {
    let displays = managedSpaces()
    let home = display == nil ? (try? frontmostWindow())?.display : nil
    let plan = try planRemoveDesktop(n, display: display, home: home, displays: displays, windows: allWindows(),
                                     moveWindows: moveWindows, name: displayName)
    let dName = displayName(plan.display)
    try inMissionControl(display: plan.display) { spaces in
        let buttons = children(of: descendant(of: spaces, id: "mc.spaces.list"))
        guard plan.button < buttons.count else { throw TileSpaceError("Mission Control doesn't show desktop \(n) of \(dName)") }
        let b = buttons[plan.button]
        // the button has to be the desktop meant: if it says which desktop it is, that has to agree
        if let said = string(b, kAXDescriptionAttribute).flatMap(desktopNumber), said != n {
            throw TileSpaceError("Mission Control's button there is for desktop \(said), not \(n), so nothing was removed")
        }
        guard actions(of: b).contains("AXRemoveDesktop") else {
            throw TileSpaceError("Mission Control offers no way to remove desktop \(n) of \(dName)")
        }
        guard AXUIElementPerformAction(b, "AXRemoveDesktop" as CFString) == .success else {
            throw TileSpaceError("Mission Control didn't take the removal of desktop \(n) of \(dName)")
        }
    }
    guard waitUntil({ !(managedSpaces().first { $0.uuid == plan.display }?.spaces.contains(plan.space) ?? true) }) else {
        throw TileSpaceError("Mission Control didn't remove desktop \(n) of \(dName)")
    }
    return "removed desktop \(n) of \(dName)"
}

// Remove the last desktop of the frontmost window's display, on the same terms.
public func removeLastDesktop() throws -> String {
    guard let w = try? frontmostWindow(), let d = managedSpaces().first(where: { $0.uuid == w.display }) else {
        throw TileSpaceError("there's no frontmost window to tell which display you mean")
    }
    return try removeDesktop(d.spaces.count, display: d.uuid)
}

// MARK: Mission Control through Accessibility

// Show Mission Control (unless it's showing), hand `act` the spaces bar of `display`, then put it
// away again if TileSpace showed it. It's shown and hidden as its own shortcut would, by asking
// the Dock, never by pressing Esc: a key press would go to whatever app is in front.
private func inMissionControl(display uuid: String, _ act: (AXUIElement) throws -> Void) throws {
    let wasShowing = !missionControlDisplays().isEmpty
    if !wasShowing { toggleMissionControl() }
    defer {
        if !wasShowing {
            toggleMissionControl()
            _ = waitUntil { missionControlDisplays().isEmpty }
        }
    }
    // the bar can be missing, or only some displays there, for a moment after it opens
    guard let spaces = waitFor({ spacesBar(of: uuid) }, timeout: 3) else {
        throw TileSpaceError("Mission Control didn't show \(displayName(uuid))'s desktops")
    }
    usleep(300_000)   // let it finish opening before pressing anything
    try act(spaces)
}

typealias DockNotifyFn = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Int32
private let dockNotify: DockNotifyFn? = dlsym(dlopen(nil, RTLD_NOW), "CoreDockSendNotification").map { unsafeBitCast($0, to: DockNotifyFn.self) }

private func toggleMissionControl() {
    if let dockNotify { _ = dockNotify("com.apple.expose.awake" as CFString, nil) }
    else { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Mission Control.app"), configuration: .init()) }
}

// Mission Control's display groups ("mc.display"), under the Dock or under WindowManager
private func missionControlDisplays() -> [AXUIElement] {
    let owners = ["com.apple.dock", "com.apple.WindowManager"].compactMap {
        NSRunningApplication.runningApplications(withBundleIdentifier: $0).first.map { AXUIElementCreateApplication($0.processIdentifier) }
    }
    return owners.flatMap { owner -> [AXUIElement] in
        AXUIElementSetMessagingTimeout(owner, 1)
        return descendants(of: owner, id: "mc.display", depth: 4)
    }
}

// the spaces bar ("mc.spaces") of a display, once Mission Control shows it with its desktops
private func spacesBar(of uuid: String) -> AXUIElement? {
    let groups = missionControlDisplays()
    let id = displayID(uuid)
    // with "Displays have separate Spaces" off there's one group for all displays
    let group = groups.first { number($0, "AXDisplayID") == id.map(Int.init) } ?? (groups.count == 1 && uuid == sharedSpacesDisplay ? groups.first : nil)
    guard let group, let bar = descendant(of: group, id: "mc.spaces"),
          !children(of: descendant(of: bar, id: "mc.spaces.list")).isEmpty else { return nil }
    return bar
}

private func displayID(_ uuid: String) -> CGDirectDisplayID? {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).first { displayUUID($0) == uuid }
}

private func children(of e: AXUIElement?) -> [AXUIElement] {
    guard let e else { return [] }
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v)
    return v as? [AXUIElement] ?? []
}

private func string(_ e: AXUIElement, _ attribute: String) -> String? {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(e, attribute as CFString, &v)
    return v as? String
}

private func number(_ e: AXUIElement, _ attribute: String) -> Int? {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(e, attribute as CFString, &v)
    return (v as? NSNumber)?.intValue
}

private func actions(of e: AXUIElement) -> [String] {
    var v: CFArray?
    AXUIElementCopyActionNames(e, &v)
    return v as? [String] ?? []
}

private func descendant(of e: AXUIElement, id: String, depth: Int = 3) -> AXUIElement? {
    descendants(of: e, id: id, depth: depth).first
}

private func descendants(of e: AXUIElement, id: String, depth: Int) -> [AXUIElement] {
    guard depth > 0 else { return [] }
    return children(of: e).flatMap { c in
        string(c, kAXIdentifierAttribute) == id ? [c] : descendants(of: c, id: id, depth: depth - 1)
    }
}

// `f`'s first non-nil (or true) answer, asked every 50ms for up to `timeout` seconds
private func waitFor<T>(_ f: () -> T?, timeout: Double = 2) -> T? {
    for _ in 0..<Int(timeout * 20) {
        if let v = f() { return v }
        usleep(50_000)
    }
    return f()
}

// whether `f` came true within `timeout` seconds
private func waitUntil(_ f: () -> Bool, timeout: Double = 2) -> Bool {
    waitFor({ f() ? true : nil }, timeout: timeout) != nil
}
