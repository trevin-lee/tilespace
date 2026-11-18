// What the app does from its menu and from tilespace:// links, apart from the shortcuts:
// worked out here so it can be tested without the app.
import Foundation

// A tilespace:// link, for scripts and launchers. Both act on the frontmost app's window:
//   tilespace://execute-action?name=left-half        (like Rectangle's rectangle:// links)
//   tilespace://move-to-desktop?desktop=3            (also &display=built-in and &follow=true)
public enum LinkCommand: Equatable {
    case snap(SnapAction)
    case move(desktop: Int, display: String?, follow: Bool)
}

public func linkCommand(_ link: String) -> LinkCommand? {
    guard let url = URLComponents(string: link), url.scheme == "tilespace" else { return nil }
    func value(_ name: String) -> String? { url.queryItems?.first { $0.name == name }?.value }
    switch url.host {
    case "execute-action":
        return value("name").flatMap(SnapAction.init(cliName:)).map(LinkCommand.snap)
    case "move-to-desktop":
        guard let desktop = value("desktop").flatMap(Int.init), desktop >= 1 else { return nil }
        let follow = value("follow") ?? "false"
        guard ["true", "false"].contains(follow) else { return nil }
        let display = value("display").flatMap { $0.isEmpty ? nil : $0 }
        return .move(desktop: desktop, display: display, follow: follow == "true")
    default:
        return nil
    }
}

// A row of the menu's Move to Desktop submenu: a desktop to move the frontmost window to, or
// (with no desktop) a display's name above its desktops, or the reason there's nothing to pick.
public struct MoveChoice: Equatable {
    public let title: String
    public let display: String?   // the display's identifier
    public let desktop: Int?      // from 1
}

public func moveChoices(displays: [DisplaySpaces], screenCount: Int, name: (String) -> String) -> [MoveChoice] {
    // a move goes through another display, so it needs two, each with its own desktops
    guard displays.count > 1 else {
        let why = screenCount > 1 ? "Needs “Displays have separate Spaces” on, in Desktop & Dock settings" : "Needs a second display"
        return [MoveChoice(title: why, display: nil, desktop: nil)]
    }
    return displays.flatMap { d in
        [MoveChoice(title: name(d.uuid), display: nil, desktop: nil)] + d.spaces.enumerated().map { i, space in
            MoveChoice(title: "Desktop \(i + 1)" + (space == d.current ? " (showing)" : ""), display: d.uuid, desktop: i + 1)
        }
    }
}
