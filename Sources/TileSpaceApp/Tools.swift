// The app's MCP endpoint: the always-on server that the `tilespace` command and agents use.
// Everything runs on the main thread, where the shortcuts and drags run too, so all of them
// share one memory of past snaps.
import AppKit
import TileSpaceCore

final class Tools {
    private let snapper: Snapper
    private lazy var mcp = MCPServer { [unowned self] tool, args in call(tool, args) }
    private lazy var server = LocalServer { [unowned self] body, respond in
        DispatchQueue.main.async { respond(self.mcp.handle(body)) }
    }
    private(set) var status = "starting…"   // for the menu

    init(snapper: Snapper) { self.snapper = snapper }

    func start() {
        server.start { [weak self] error in
            self?.status = error.map { "couldn't start: \($0)" } ?? "on at \(serverURL)"
            if let error { NSLog("MCP server couldn't start on port %d: %@", serverPort, error) }
        }
    }

    private func call(_ tool: Tool, _ args: [String: Any]) -> ToolResult {
        do {
            switch tool {
            case .listWindows:
                return ToolResult(listWindows())
            case .listDesktops:
                return ToolResult(listDesktops())
            case .snapWindow:
                guard let name = args["action"] as? String, let action = SnapAction(cliName: name) else {
                    throw TileSpaceError("unknown action \(args["action"] ?? "(none)"); use one of: "
                                         + SnapAction.allCases.map(\.cliName).joined(separator: " "))
                }
                var el: AXUIElement?
                if let q = window(args) {
                    guard let w = find(q) else { throw TileSpaceError("no window on a showing desktop matches '\(q)'") }
                    guard let e = axWindow(w) else { throw TileSpaceError("can't reach \(w.app)'s window through Accessibility") }
                    el = e
                }
                let r = try snapper.run(action, on: el)
                return ToolResult("\(r.result.cliName): \(Int(r.rect.minX)),\(Int(r.rect.minY)) \(Int(r.rect.width))x\(Int(r.rect.height))")
            case .moveWindowToDesktop:
                guard let q = window(args) else { throw TileSpaceError("which window? pass `window`") }
                guard let desktop = (args["desktop"] as? NSNumber)?.intValue ?? (args["desktop"] as? String).flatMap(Int.init) else {
                    throw TileSpaceError("`desktop` must be a number starting at 1")
                }
                return ToolResult(try moveWindow(q, toDesktop: desktop, display: args["display"] as? String,
                                                 follow: args["follow"] as? Bool ?? false))
            }
        } catch {
            return ToolResult("\(error)", isError: true)
        }
    }

    // `window` as text, accepting a bare number too
    private func window(_ args: [String: Any]) -> String? {
        if let s = args["window"] as? String, !s.isEmpty { return s }
        return (args["window"] as? NSNumber).map { "\($0.intValue)" }
    }
}
