import Foundation
import XCTest
@testable import TileSpaceCore

func raw(_ s: String) -> Data { Data(s.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

final class HTTPTests: XCTestCase {
    let post = "POST /mcp HTTP/1.1\nHost: 127.0.0.1:8453\nContent-Type: application/json\nContent-Length: 2\n\n{}"

    func testParsesARequest() {
        guard case .request(let r, let consumed) = parseRequest(raw(post)) else { return XCTFail() }
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/mcp")
        XCTAssertEqual(r.headers["content-type"], "application/json")
        XCTAssertEqual(r.body, Data("{}".utf8))
        XCTAssertEqual(consumed, raw(post).count)
    }

    func testWaitsForTheWholeBody() {
        guard case .incomplete = parseRequest(raw(String(post.dropLast()))) else { return XCTFail() }
    }

    func testParsesPipelinedRequestsOneAtATime() {
        var buffer = raw(post + post)
        guard case .request(_, let consumed) = parseRequest(buffer) else { return XCTFail() }
        buffer.removeFirst(consumed)   // leaves a Data that doesn't start at index 0
        guard case .request(let second, _) = parseRequest(buffer) else { return XCTFail() }
        XCTAssertEqual(second.body, Data("{}".utf8))
    }

    func testRejectsChunkedBodies() {
        guard case .bad(411) = parseRequest(raw("POST /mcp HTTP/1.1\nTransfer-Encoding: chunked\n\n")) else { return XCTFail() }
    }

    func request(_ headers: [String: String], method: String = "POST", path: String = "/mcp") -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: headers, body: Data())
    }

    let ok = ["host": "127.0.0.1:8453", "content-type": "application/json"]

    func testLetsLocalClientsIn() {
        XCTAssertNil(rejection(request(ok), port: 8453))
        XCTAssertNil(rejection(request(ok.merging(["host": "localhost:8453"]) { $1 }), port: 8453))
    }

    func testTurnsAwayBrowsers() {
        XCTAssertEqual(rejection(request(ok.merging(["origin": "https://example.com"]) { $1 }), port: 8453)?.status, 403)
        // DNS rebinding: a page at evil.example whose name resolves to 127.0.0.1
        XCTAssertEqual(rejection(request(ok.merging(["host": "evil.example:8453"]) { $1 }), port: 8453)?.status, 403)
        // a "simple" cross-site form post, which skips CORS preflight
        XCTAssertEqual(rejection(request(ok.merging(["content-type": "text/plain"]) { $1 }), port: 8453)?.status, 415)
    }

    func testOnlyPostToMCP() {
        XCTAssertEqual(rejection(request(ok, method: "GET"), port: 8453)?.status, 405)
        XCTAssertEqual(rejection(request(ok, path: "/"), port: 8453)?.status, 404)
    }
}

final class MCPTests: XCTestCase {
    var calls: [(Tool, [String: Any])] = []
    lazy var server = MCPServer { tool, args in
        self.calls.append((tool, args))
        return ToolResult("did \(tool.rawValue)")
    }

    func send(_ message: Any) -> Any? {
        let body = try! JSONSerialization.data(withJSONObject: message)
        return server.handle(body).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    func testInitializeAgreesOnAKnownVersion() {
        let r = send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]]) as! [String: Any]
        let result = r["result"] as! [String: Any]
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "tilespace")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
    }

    func testInitializeOffersItsOwnVersionForAnUnknownOne() {
        let r = send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]]) as! [String: Any]
        XCTAssertEqual((r["result"] as! [String: Any])["protocolVersion"] as? String, MCPServer.protocolVersions[0])
    }

    func testNotificationsGetNoReply() {
        XCTAssertNil(send(["jsonrpc": "2.0", "method": "notifications/initialized"]))
    }

    func testListsTheTools() {
        let r = send(["jsonrpc": "2.0", "id": "a", "method": "tools/list"]) as! [String: Any]
        XCTAssertEqual(r["id"] as? String, "a")
        let tools = (r["result"] as! [String: Any])["tools"] as! [[String: Any]]
        XCTAssertEqual(tools.map { $0["name"] as! String }, ["list_windows", "list_desktops", "snap_window", "move_window_to_desktop"])
        for t in tools { XCTAssertEqual((t["inputSchema"] as? [String: Any])?["type"] as? String, "object") }
    }

    func testCallsATool() {
        let r = send(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                      "params": ["name": "snap_window", "arguments": ["action": "left-half"]]]) as! [String: Any]
        let result = r["result"] as! [String: Any]
        XCTAssertEqual((result["content"] as! [[String: Any]])[0]["text"] as? String, "did snap_window")
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual(calls.first?.0, .snapWindow)
        XCTAssertEqual(calls.first?.1["action"] as? String, "left-half")
    }

    func testUnknownToolsAndMethodsAreErrors() {
        let tool = send(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "rm_rf"]]) as! [String: Any]
        XCTAssertEqual((tool["error"] as? [String: Any])?["code"] as? Int, -32602)
        let method = send(["jsonrpc": "2.0", "id": 4, "method": "resources/list"]) as! [String: Any]
        XCTAssertEqual((method["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertTrue(calls.isEmpty)
    }

    func testBadJSONIsAParseError() {
        let r = server.handle(Data("{".utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as! [String: Any]
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? Int, -32700)
    }

    func testBatches() {
        let r = send([["jsonrpc": "2.0", "id": 1, "method": "ping"], ["jsonrpc": "2.0", "method": "notifications/initialized"]]) as! [Any]
        XCTAssertEqual(r.count, 1)
    }
}

final class LocalServerTests: XCTestCase {
    func send(_ port: UInt16, _ body: String, headers: [String: String] = [:]) -> (Int, String) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let done = expectation(description: "reply")
        var out = (0, "")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            out = ((resp as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data ?? Data(), as: UTF8.self))
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return out
    }

    func testServesOverRealHTTP() {
        let port = UInt16.random(in: 30000..<50000)
        let mcp = MCPServer { _, _ in ToolResult("ok") }
        let server = LocalServer(port: port) { body, respond in respond(mcp.handle(body)) }
        let ready = expectation(description: "listening")
        server.start { error in XCTAssertNil(error); ready.fulfill() }
        wait(for: [ready], timeout: 5)

        let (status, body) = send(port, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.contains("snap_window"))
        // again, on the kept-alive connection
        XCTAssertEqual(send(port, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#).0, 200)
        XCTAssertEqual(send(port, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).0, 202)
        XCTAssertEqual(send(port, "{}", headers: ["Origin": "https://example.com"]).0, 403)
    }
}
