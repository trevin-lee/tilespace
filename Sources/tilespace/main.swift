// tilespace: the command-line client of TileSpace.app. Each command is one call to a tool on the
// app's MCP server (the same tools agents get), so the app does the work and remembers past
// snaps, just as it does for the shortcuts. Starts the app if it isn't running.
//
//   tilespace windows                     list_windows: every window, with its desktop and id
//   tilespace desktops                    list_desktops: desktops per display (* = showing)
//   tilespace snap <action> [<window>]    snap_window: e.g. left-half (no window = the frontmost app's)
//   tilespace move <window> <desktop> [<display>] [--follow]
//                                         move_window_to_desktop: desktop is from 1, on the
//                                         window's display or on <display> ("odyssey", "built-in")
//   tilespace mcp [install | uninstall]   the MCP server's address, or add it to / remove it from Claude Code
//
// `list` and `spaces` still work, as the old names of `windows` and `desktops`.
import Foundation
import TileSpaceCore

func die(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

let usage = """
    usage: tilespace windows                    every window, with its desktop and id
           tilespace desktops                   desktops per display (* = showing)
           tilespace snap <action> [<window>]   snap a window, or the frontmost app's
           tilespace move <window> <desktop> [<display>] [--follow]
                                                move a window to desktop N (from 1) on its display, or on <display>
           tilespace mcp [install | uninstall]  the MCP server's address; add it to or remove it from Claude Code

    <window> is a window id from `tilespace windows`, or text matched against the app name and
    window title. It has to be on a desktop that's showing (* in the list). A move switches
    desktops and back; --follow stays on the target desktop.

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

var args = Array(CommandLine.arguments.dropFirst())
let follow = args.contains("--follow"); args.removeAll { $0 == "--follow" }

switch args.first {
case "windows", "list":
    call(.listWindows)
case "desktops", "spaces":
    call(.listDesktops)
case "snap":
    guard args.count >= 2, SnapAction(cliName: args[1]) != nil else {
        die("usage: tilespace snap <action> [<window>]\nactions: " + SnapAction.allCases.map(\.cliName).joined(separator: " "))
    }
    var a: [String: Any] = ["action": args[1]]
    if args.count >= 3 { a["window"] = args[2...].joined(separator: " ") }
    call(.snapWindow, a)
case "move":
    guard args.count == 3 || args.count == 4 else {
        die("usage: tilespace move <window> <desktop> [<display>] [--follow]\n(quote a <window> or <display> of more than one word)")
    }
    guard let desktop = Int(args[2]) else { die("desktop must be a number starting at 1") }
    var a: [String: Any] = ["window": args[1], "desktop": desktop, "follow": follow]
    if args.count == 4 { a["display"] = args[3] }
    call(.moveWindowToDesktop, a)
case "mcp" where args.count == 1:
    print("""
        TileSpace's MCP server: \(serverURL) (Streamable HTTP, on while TileSpace runs)
        Add it to Claude Code with `tilespace mcp install`, or in another client as an HTTP server at that URL.
        """)
case "mcp" where args.count == 2 && ["install", "uninstall"].contains(args[1]):
    let (ok, output) = args[1] == "install" ? addToClaudeCodeConfig() : removeFromClaudeCodeConfig()
    if !ok { die(output) }
    print(output)
case nil, "help", "-h", "--help":
    print(usage)
default:
    die("unknown command: \(args.joined(separator: " "))\n\n\(usage)")
}
