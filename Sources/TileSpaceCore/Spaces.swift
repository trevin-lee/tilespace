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

// The "Switch to Desktop n" shortcut (n counts across all displays, MacBook first):
// Ctrl+1..9, Ctrl+0 = 10, Ctrl+Option+1..6 = 11..16. macOS has none past 16.
public let maxDesktopShortcut = 16

func desktopShortcut(_ n: Int) -> (key: CGKeyCode, flags: CGEventFlags)? {
    let digit: [CGKeyCode] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]   // 0-9
    switch n {
    case 1...9: return (digit[n], .maskControl)
    case 10: return (digit[0], .maskControl)
    case 11...maxDesktopShortcut: return (digit[n - 10], [.maskControl, .maskAlternate])
    default: return nil
    }
}

// Press the shortcut for desktop n. Blocks until the switch has settled.
public func switchTo(_ n: Int) throws {
    guard let (key, flags) = desktopShortcut(n) else {
        throw TileSpaceError("macOS only has shortcuts for the first \(maxDesktopShortcut) desktops")
    }
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
        e.flags = flags
        e.post(tap: .cghidEventTap)
        usleep(40_000)
    }
    usleep(800_000)
}
