// What a `tilespace` command line asks for, worked out before anything runs, so a mistyped
// command is refused instead of half understood.
import Foundation

public enum CLICommand: Equatable {
    case windows, desktops
    case snap(action: String, window: String?)
    case move(desktop: Int, window: String?, display: String?, follow: Bool)
    case mcp, mcpAdd, mcpRemove
    case help, version
}

public let snapUsage = "usage: tilespace snap <action> [<window>]"
public let moveUsage = "usage: tilespace move <desktop> [<window>] [--display <name>] [--follow]"

// `args` without the program name. The window comes last in both commands that take one, as
// text of any number of words, and leaving it out means the frontmost app's window. An option a
// command doesn't take is an error: silently dropping it would run something else than was asked.
public func parseCommand(_ args: [String]) throws -> CLICommand {
    guard let name = args.first else { return .help }
    var words: [String] = [], follow = false, display: String?
    var rest = args.dropFirst()
    while let a = rest.popFirst() {
        if a == "--follow" { follow = true }
        else if a == "--display" {
            guard let v = rest.popFirst() else { throw TileSpaceError("--display needs a display's name, e.g. --display built-in\n\(moveUsage)") }
            display = v
        }
        else if a.hasPrefix("--display=") { display = String(a.dropFirst("--display=".count)) }
        else if a.hasPrefix("--") { throw TileSpaceError("tilespace \(name) has no option \(a)") }
        else { words.append(a) }
    }
    if name != "move", follow || display != nil {
        throw TileSpaceError("tilespace \(name) has no option \(follow ? "--follow" : "--display"); only `tilespace move` does")
    }
    // the window, from the words left over: nil if there are none
    func window(_ w: ArraySlice<String>, _ usage: String) throws -> String? {
        if w.isEmpty { return nil }
        let text = w.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { throw TileSpaceError("the window is empty; leave it out for the frontmost app's window\n\(usage)") }
        return text
    }
    func none(_ c: CLICommand) throws -> CLICommand {
        guard words.isEmpty else { throw TileSpaceError("tilespace \(name) takes no arguments") }
        return c
    }

    switch name {
    case "windows", "list": return try none(.windows)
    case "desktops", "spaces": return try none(.desktops)
    case "help", "-h", "--help": return .help
    case "version", "--version": return try none(.version)
    case "snap":
        guard let action = words.first, SnapAction(cliName: action) != nil else {
            throw TileSpaceError("\(snapUsage)\nactions: " + SnapAction.allCases.map(\.cliName).joined(separator: " "))
        }
        return .snap(action: action, window: try window(words.dropFirst(), snapUsage))
    case "move":
        guard let first = words.first, let desktop = Int(first) else {
            throw TileSpaceError("\(moveUsage)\nthe desktop's number comes first, then the window: tilespace move 2 zen")
        }
        if display?.trimmingCharacters(in: .whitespaces).isEmpty == true { throw TileSpaceError("--display needs a display's name\n\(moveUsage)") }
        return .move(desktop: desktop, window: try window(words.dropFirst(), moveUsage), display: display, follow: follow)
    case "mcp":
        switch words {
        case []: return .mcp
        case ["add"]: return .mcpAdd
        case ["remove"]: return .mcpRemove
        default: throw TileSpaceError("usage: tilespace mcp [add | remove]")
        }
    default:
        throw TileSpaceError("unknown command: \(args.joined(separator: " "))")
    }
}
