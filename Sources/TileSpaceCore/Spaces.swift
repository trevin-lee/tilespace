// Desktops (Spaces). macOS has no API to move a window to another desktop, but read-only
// SkyLight calls still work with SIP on, and the "Switch to Desktop N" shortcuts can be
// pressed with synthetic key events.
import AppKit
import CoreGraphics

typealias ConnFn = @convention(c) () -> Int32
typealias DisplaysFn = @convention(c) (Int32) -> CFArray
typealias SpacesForWinFn = @convention(c) (Int32, Int32, CFArray) -> CFArray

let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
let conn = unsafeBitCast(dlsym(sky, "SLSMainConnectionID"), to: ConnFn.self)()
let spacesForWindows = unsafeBitCast(dlsym(sky, "SLSCopySpacesForWindows"), to: SpacesForWinFn.self)

public struct DisplaySpaces {
    public let uuid: String
    public let spaces: [Int]   // ManagedSpaceIDs of the user desktops, in order
    public let current: Int    // the one showing
}

public func managedSpaces() -> [DisplaySpaces] {
    let fn = unsafeBitCast(dlsym(sky, "SLSCopyManagedDisplaySpaces"), to: DisplaysFn.self)
    let raw = fn(conn) as? [[String: Any]] ?? []
    return raw.map { d in
        let user = (d["Spaces"] as? [[String: Any]] ?? []).filter { ($0["type"] as? Int) == 0 }
        let cur = (d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int ?? -1
        return DisplaySpaces(uuid: d["Display Identifier"] as? String ?? "?",
                             spaces: user.compactMap { $0["ManagedSpaceID"] as? Int }, current: cur)
    }
}

// The desktop(s) a window belongs to (ManagedSpaceIDs), whether or not it's showing.
public func spaces(of windowID: Int) -> [Int] { spacesForWindows(conn, 7, [windowID] as CFArray) as? [Int] ?? [] }

// The "Switch to Desktop n" shortcuts (n counts across all displays, MacBook first). macOS has
// them for the first 16 desktops only, as symbolic hot keys 118-133. Each can be turned off or
// rebound in System Settings; out of the box they're Ctrl+1..9, Ctrl+0 = 10 and
// Ctrl+Option+1..6 = 11..16.
public let maxDesktopShortcut = 16

struct KeyCombo: Equatable {
    let key: CGKeyCode
    let flags: CGEventFlags
}

// The user's symbolic hot keys (what System Settings > Keyboard > Keyboard Shortcuts shows).
func symbolicHotKeys() -> [String: Any]? {
    let app = "com.apple.symbolichotkeys" as CFString
    CFPreferencesAppSynchronize(app)   // the app runs for days: don't keep a stale copy
    return CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, app) as? [String: Any]
}

// The keys that switch to desktop n, as the user has them set in `hotKeys`. macOS's default
// when they've never been changed, nil when the shortcut is off or n has none.
func desktopShortcut(_ n: Int, hotKeys: [String: Any]?) -> KeyCombo? {
    guard (1...maxDesktopShortcut).contains(n) else { return nil }
    let entry = hotKeys?["\(117 + n)"] as? [String: Any]
    if (entry?["enabled"] as? NSNumber)?.boolValue == false { return nil }
    // parameters: (character or 65535, key code or 65535 for none, modifier flags)
    guard let p = (entry?["value"] as? [String: Any])?["parameters"] as? [Int], p.count == 3 else {
        let digit: [CGKeyCode] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]   // 0-9
        return n <= 10 ? KeyCombo(key: digit[n % 10], flags: .maskControl)
                       : KeyCombo(key: digit[n - 10], flags: [.maskControl, .maskAlternate])
    }
    guard (0..<0xFFFF).contains(p[1]) else { return nil }   // on, but with no key
    // the device-independent modifier bits are the same in NSEvent and CGEvent flags
    return KeyCombo(key: CGKeyCode(p[1]), flags: CGEventFlags(rawValue: UInt64(p[2]) & 0xFE_0000))
}

// Press the shortcut for desktop n. Blocks until the switch has settled.
public func switchTo(_ n: Int) throws {
    guard (1...maxDesktopShortcut).contains(n) else {
        throw TileSpaceError("macOS only has shortcuts for the first \(maxDesktopShortcut) desktops")
    }
    guard let combo = desktopShortcut(n, hotKeys: symbolicHotKeys()) else { throw shortcutOff(n) }
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: combo.key, keyDown: down)!
        e.flags = combo.flags
        e.post(tap: .cghidEventTap)
        usleep(40_000)
    }
    usleep(800_000)
}

func shortcutOff(_ n: Int, _ more: String = "") -> TileSpaceError {
    TileSpaceError("\"Switch to Desktop \(n)\" is off. Turn it on in System Settings > Keyboard > Keyboard Shortcuts > Mission Control\(more).")
}

// Check that the shortcuts a move presses are on, before anything moves.
func checkShortcuts(_ plan: MovePlan, hotKeys: [String: Any]?) throws {
    if let n = plan.switchTo, desktopShortcut(n, hotKeys: hotKeys) == nil { throw shortcutOff(n) }
    if let n = plan.switchBack, desktopShortcut(n, hotKeys: hotKeys) == nil {
        throw shortcutOff(n, ", or use --follow to stay on the target desktop instead of switching back")
    }
}
