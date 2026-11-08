// tilespace: the command-line client of TileSpace.app. Each command is one call to a tool on the
// app's MCP server (the same tools agents get), so the app does the work and remembers past
// snaps, just as it does for the shortcuts. Starts the app if it isn't running.
//
//   tilespace list                          every window, with its desktop and id
//   tilespace spaces                        desktops per display (* = showing)
//   tilespace move <window> <desktop>       desktop is 1-based, on the window's display
//   tilespace move <window> <desktop> <display>   ...on another display ("odyssey", "built-in")
//   tilespace snap <action> [<window>]      a Rectangle-style snap, e.g. left-half (no window =
//                                           the frontmost app's)
//   tilespace mcp [install]                 the MCP server's address, or add it to Claude Code
//
// <window> is a window id from `tilespace list`, or text matched against "<app> <title>"
// (case-insensitive, first match). The window must be on a desktop that's showing. --follow
// stays on the target desktop instead of switching back.
import Foundation
import TileSpaceCore

func die(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

let usage = """
    usage: tilespace list
           tilespace spaces
           tilespace move <window id or text> <desktop> [<display>] [--follow]
           tilespace snap <action> [<window id or text>]
           tilespace mcp [install]
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
case "list":
    call(.listWindows)
case "spaces":
    call(.listDesktops)
case "snap":
    guard args.count >= 2, SnapAction(cliName: args[1]) != nil else {
        die("usage: tilespace snap <action> [<window>]\nactions: " + SnapAction.allCases.map(\.cliName).joined(separator: " "))
    }
    var a: [String: Any] = ["action": args[1]]
    if args.count >= 3 { a["window"] = args[2...].joined(separator: " ") }
    call(.snapWindow, a)
case "move" where args.count == 3 || args.count == 4:
    guard let desktop = Int(args[2]) else { die("desktop must be a number starting at 1") }
    var a: [String: Any] = ["window": args[1], "desktop": desktop, "follow": follow]
    if args.count == 4 { a["display"] = args[3] }
    call(.moveWindowToDesktop, a)
case "mcp" where args.count == 1:
    print("""
        TileSpace's MCP server: \(serverURL) (Streamable HTTP, on while TileSpace runs)
        Add it to Claude Code with `tilespace mcp install`, or in another client as an HTTP server at that URL.
        """)
case "mcp" where args.count == 2 && args[1] == "install":
    let (ok, output) = addToClaudeCodeConfig()
    if !ok { die(output) }
    print(output.isEmpty ? "added TileSpace to Claude Code" : output)
default:
    print(usage)
    exit(args.isEmpty ? 0 : 1)
}
