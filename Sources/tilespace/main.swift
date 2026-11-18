// tilespace: the command-line client of TileSpace.app. Each command is one call to a tool on the
// app's MCP server (the same tools agents get), so the app does the work and remembers past
// snaps, just as it does for the shortcuts. Starts the app if it isn't running.
//
//   tilespace windows                     list_windows: every window, with its desktop and id
//   tilespace desktops                    list_desktops: desktops per display (* = showing)
//   tilespace snap <action> [<window>]    snap_window: e.g. left-half; prints the frame the
//                                         window ended up with
//   tilespace move <desktop> [<window>] [--display <name>] [--follow]
//                                         move_window_to_desktop: desktop is from 1, on the
//                                         window's display or on the one named ("odyssey",
//                                         "built-in"); needs a second display, and "Displays
//                                         have separate Spaces" on
//   tilespace mcp [add | remove]          the MCP server's address, or add it to / remove it from Claude Code
//
// In both, the window comes last and no window means the frontmost app's. `list` and `spaces`
// still work, as the old names of `windows` and `desktops`.
import Foundation
import TileSpaceCore

func die(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

let usage = """
    usage: tilespace windows                    every window, with its desktop and id
           tilespace desktops                   desktops per display (* = showing)
           tilespace snap <action> [<window>]   snap a window
           tilespace move <desktop> [<window>] [--display <name>] [--follow]
                                                move a window to desktop N (from 1) on its display, or on the one
                                                named; needs a second display, "Displays have separate Spaces" on,
                                                and macOS's "Switch to Desktop N" shortcuts on (they ship off)
           tilespace mcp [add | remove]         the MCP server's address; add it to or remove it from Claude Code

    <window> comes last, and can be several words. It's a window id from `tilespace windows`, or
    text matched against the app name and window title. It has to be on a desktop that's showing
    (* in the list). Leave it out for the frontmost app's window. A move switches desktops and
    back; --follow stays on the target desktop. A snap prints the action applied and the frame
    the window ended up with: a window with a minimum or fixed size keeps it.

    actions: \(SnapAction.allCases.map(\.cliName).joined(separator: " "))
    """

func post(_ body: Data) -> Result<Data, Error> {
    var req = URLRequest(url: URL(string: serverURL)!, timeoutInterval: 30)   // moves take a few seconds
    req.httpMethod = "POST"
    req.httpBody = body
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    let done = DispatchSemaphore(value: 0)
    var out: Result<Data, Error> = .failure(TileSpaceError("no response"))
    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let err { out = .failure(err) }
        else if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            out = .failure(TileSpaceError("TileSpace answered \(http.statusCode): \(String(decoding: data ?? Data(), as: UTF8.self))"))
        } else { out = .success(data ?? Data()) }
        done.signal()
    }.resume()
    done.wait()
    return out
}

// Call a tool on the app, starting the app first if nothing is listening.
func call(_ tool: Tool, _ arguments: [String: Any] = [:]) -> Never {
    let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                  "params": ["name": tool.rawValue, "arguments": arguments]]
    let body = try! JSONSerialization.data(withJSONObject: request)
    var reply = post(body)
    if case .failure(let e as URLError) = reply, e.code == .cannotConnectToHost {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-b", "com.trevinlee.tilespace"]
        open.standardError = FileHandle.nullDevice
        try? open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else {
            die("TileSpace isn't running, and couldn't be started. Install it with scripts/build-app.sh --install.")
        }
        for _ in 0..<40 {   // up to 10 seconds for it to start listening
            usleep(250_000)
            reply = post(body)
            if case .failure(let e as URLError) = reply, e.code == .cannotConnectToHost { continue }
            break
        }
    }
    switch reply {
    case .failure(let e):
        die("couldn't reach TileSpace at \(serverURL): \(e.localizedDescription)")
    case .success(let data):
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let err = json?["error"] as? [String: Any] { die(err["message"] as? String ?? "error") }
        guard let result = json?["result"] as? [String: Any] else { die("unexpected reply from TileSpace") }
        let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        if result["isError"] as? Bool == true { die(text) }
        if !text.isEmpty { print(text) }
        exit(0)
    }
}

let command: CLICommand
do { command = try parseCommand(Array(CommandLine.arguments.dropFirst())) } catch {
    let message = "\(error)"
    die(message.hasPrefix("unknown command") ? "\(message)\n\n\(usage)" : message)
}

switch command {
case .windows:
    call(.listWindows)
case .desktops:
    call(.listDesktops)
case .snap(let action, let window):
    var a: [String: Any] = ["action": action]
    if let window { a["window"] = window }
    call(.snapWindow, a)
case .move(let desktop, let window, let display, let follow):
    var a: [String: Any] = ["desktop": desktop, "follow": follow]
    if let window { a["window"] = window }
    if let display { a["display"] = display }
    call(.moveWindowToDesktop, a)
case .mcp:
    print("""
        TileSpace's MCP server: \(serverURL) (Streamable HTTP, on while TileSpace runs)
        Add it to Claude Code with `tilespace mcp add`, or in another client as an HTTP server at that URL.
        """)
case .mcpAdd, .mcpRemove:
    let (ok, output) = command == .mcpAdd ? addToClaudeCodeConfig() : removeFromClaudeCodeConfig()
    if !ok { die(output) }
    print(output)
case .help:
    print(usage)
}
