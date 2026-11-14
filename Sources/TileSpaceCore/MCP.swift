// The MCP side of the server: JSON-RPC over Streamable HTTP, with plain JSON responses and no
// sessions. The CLI uses the same tools, so both go through the app.
import Foundation

public let tileSpaceVersion = "0.1.0"

public struct ToolResult {
    public let text: String
    public let isError: Bool
    public init(_ text: String, isError: Bool = false) { self.text = text; self.isError = isError }
}

public enum Tool: String, CaseIterable {
    case listWindows = "list_windows"
    case listDesktops = "list_desktops"
    case snapWindow = "snap_window"
    case moveWindowToDesktop = "move_window_to_desktop"

    static let windowArg: [String: Any] = [
        "type": "string",
        "description": "A window id from list_windows (e.g. \"4144\"), or text matched case-insensitively against \"<app> <title>\" (first match wins). Only windows on a desktop that's showing can be matched.",
    ]

    var definition: [String: Any] {
        switch self {
        case .listWindows:
            return [
                "name": rawValue, "title": "List windows",
                "description": "Every titled window on every desktop (Space), one per line: display and desktop number, window id, app, frame (x,y widthxheight, top-left origin), title.",
                "inputSchema": ["type": "object", "properties": [String: Any]()],
                "annotations": ["readOnlyHint": true],
            ]
        case .listDesktops:
            return [
                "name": rawValue, "title": "List desktops",
                "description": "The desktops (Spaces) on each display, numbered from 1; * marks the one showing.",
                "inputSchema": ["type": "object", "properties": [String: Any]()],
                "annotations": ["readOnlyHint": true],
            ]
        case .snapWindow:
            return [
                "name": rawValue, "title": "Snap a window",
                "description": "Snap a window into place on its display, like Rectangle. Repeating left-half or right-half moves the window to the next display over; repeating first-third or last-third cycles through the thirds; restore puts it back where it was before it was first snapped. Returns the action applied and the frame it set.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": SnapAction.allCases.map(\.cliName)],
                        "window": Tool.windowArg.merging(["description": "\(Tool.windowArg["description"]!) Leave out for the focused window."]) { $1 },
                    ],
                    "required": ["action"],
                ],
                "annotations": ["readOnlyHint": false, "destructiveHint": false],
            ]
        case .moveWindowToDesktop:
            return [
                "name": rawValue, "title": "Move a window to another desktop",
                "description": "Move a window to desktop N (from 1, as in list_desktops) on its own display, or on another display if `display` is given. Needs a second display to park the window on, and macOS's \"Switch to Desktop N\" shortcuts turned on. The screen visibly switches desktops for a moment, and it takes a couple of seconds.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "window": Tool.windowArg,
                        "desktop": ["type": "integer", "minimum": 1],
                        "display": ["type": "string", "description": "Part of a display's name, e.g. \"built-in\". Leave out for the window's own display."],
                        "follow": ["type": "boolean", "description": "Stay on the target desktop afterwards instead of switching back. Default false."],
                    ],
                    "required": ["window", "desktop"],
                ],
                "annotations": ["readOnlyHint": false, "destructiveHint": false],
            ]
        }
    }
}

public final class MCPServer {
    public typealias Call = (Tool, [String: Any]) -> ToolResult
    private let call: Call

    public init(call: @escaping Call) { self.call = call }

    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    // A request body in, a response body out (nil when it was only notifications).
    public func handle(_ body: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: body) else {
            return encode(error(nil, -32700, "parse error"))
        }
        if let batch = json as? [Any] {
            let out = batch.compactMap(handleMessage)
            return out.isEmpty ? nil : encode(out)
        }
        return handleMessage(json).map(encode)
    }

    private func handleMessage(_ m: Any) -> [String: Any]? {
        guard let m = m as? [String: Any], let method = m["method"] as? String else {
            return error(nil, -32600, "invalid request")
        }
        guard let id = m["id"] else { return nil }   // a notification: nothing to answer
        let params = m["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return result(id, [
                "protocolVersion": Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "tilespace", "title": "TileSpace", "version": tileSpaceVersion],
                "instructions": "Arrange the windows on this Mac: list windows and desktops (Spaces), snap windows into halves, thirds and so on, and move windows between desktops. Coordinates have a top-left origin.",
            ])
        case "ping":
            return result(id, [String: Any]())
        case "tools/list":
            return result(id, ["tools": Tool.allCases.map(\.definition)])
        case "tools/call":
            guard let name = params["name"] as? String, let tool = Tool(rawValue: name) else {
                return error(id, -32602, "unknown tool: \(params["name"] ?? "none")")
            }
            let r = call(tool, params["arguments"] as? [String: Any] ?? [:])
            return result(id, ["content": [["type": "text", "text": r.text]], "isError": r.isError])
        default:
            return error(id, -32601, "method not found: \(method)")
        }
    }

    private func result(_ id: Any, _ r: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": r] }

    private func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    private func encode(_ v: Any) -> Data { (try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])) ?? Data() }
}

// Register the server with Claude Code (user scope, so every project gets it), or remove it,
// by running `claude mcp` in a login shell, where `claude` is on the PATH much as in Terminal
// (plus the usual install folders, in case only .zshrc adds them).
public func addToClaudeCodeConfig() -> (ok: Bool, output: String) {
    let (status, out) = claudeMCP("add --scope user --transport http tilespace \(serverURL)")
    if out.contains("already exists") { return (true, "TileSpace is already set up in Claude Code") }
    return (status == 0, status == 0 ? "added TileSpace to Claude Code (user scope)" : out)
}

public func removeFromClaudeCodeConfig() -> (ok: Bool, output: String) {
    let (status, out) = claudeMCP("remove --scope user tilespace")
    if out.contains("No MCP server named") { return (true, "TileSpace isn't set up in Claude Code") }
    return (status == 0, status == 0 ? "removed TileSpace from Claude Code" : out)
}

private func claudeMCP(_ args: String) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", "PATH=\"$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin\" claude mcp \(args)"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    if p.terminationStatus == 127 || out.contains("command not found") {
        return (127, "Claude Code's `claude` command isn't installed, or isn't on your shell's PATH. Use this MCP server URL by hand: \(serverURL)")
    }
    return (p.terminationStatus, out)
}
