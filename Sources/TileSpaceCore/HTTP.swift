// A minimal HTTP/1.1 server on the loopback interface, for the MCP endpoint. Only what MCP
// clients need: POST with a Content-Length body, keep-alive, one request at a time per
// connection.
import Foundation
import Network

// TILE on a phone keypad. TILESPACE_PORT overrides it (for tests).
public let serverPort: UInt16 = ProcessInfo.processInfo.environment["TILESPACE_PORT"].flatMap(UInt16.init) ?? 8453
public var serverURL: String { "http://127.0.0.1:\(serverPort)/mcp" }

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]   // names lowercased
    public let body: Data
}

enum ParseResult {
    case incomplete
    case request(HTTPRequest, consumed: Int)
    case bad(status: Int)
}

let maxBody = 1 << 20

func parseRequest(_ data: Data) -> ParseResult {
    guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
        return data.count > 64 * 1024 ? .bad(status: 431) : .incomplete
    }
    guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .bad(status: 400) }
    let lines = head.components(separatedBy: "\r\n")
    let parts = lines[0].split(separator: " ")
    guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .bad(status: 400) }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { return .bad(status: 400) }
        headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    if headers["transfer-encoding"] != nil { return .bad(status: 411) }   // only Content-Length bodies
    let length = Int(headers["content-length"] ?? "0") ?? -1
    guard length >= 0 else { return .bad(status: 400) }
    guard length <= maxBody else { return .bad(status: 413) }
    let bodyStart = end.upperBound
    guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return .incomplete }
    let body = data[bodyStart..<data.index(bodyStart, offsetBy: length)]
    let path = String(parts[1].split(separator: "?", maxSplits: 1).first ?? "")
    return .request(HTTPRequest(method: String(parts[0]), path: path, headers: headers, body: Data(body)),
                    consumed: data.distance(from: data.startIndex, to: bodyStart) + length)
}

// Why a request should be turned away, if it should. Only local, non-browser clients get in:
// a web page can reach 127.0.0.1 too, but it can't hide its Origin header, and a Host check
// stops DNS rebinding (a page whose own hostname resolves to 127.0.0.1).
func rejection(_ r: HTTPRequest, port: UInt16) -> (status: Int, message: String)? {
    guard r.path == "/mcp" else { return (404, "not found; the MCP endpoint is /mcp") }
    let hosts = ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"]
    guard let host = r.headers["host"], hosts.contains(host.lowercased()) else { return (403, "unexpected Host header") }
    if r.headers["origin"] != nil { return (403, "browser requests aren't allowed") }
    guard r.method == "POST" else { return (405, "use POST") }
    guard r.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
        return (415, "Content-Type must be application/json")
    }
    return nil
}

func response(_ status: Int, _ body: Data = Data(), type: String = "application/json") -> Data {
    let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                  405: "Method Not Allowed", 411: "Length Required", 413: "Payload Too Large",
                  415: "Unsupported Media Type", 431: "Request Header Fields Too Large"][status] ?? "Error"
    var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\n"
    if !body.isEmpty { head += "Content-Type: \(type)\r\n" }
    if status == 405 { head += "Allow: POST\r\n" }
    head += "Connection: keep-alive\r\n\r\n"
    return Data(head.utf8) + body
}

public final class LocalServer {
    public typealias Handler = (_ body: Data, _ respond: @escaping (Data?) -> Void) -> Void
    private let port: UInt16
    private let handler: Handler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "tilespace.server")

    // `handler` gets each accepted request body and calls `respond` with the response body,
    // or nil for "202 Accepted, no body".
    public init(port: UInt16 = serverPort, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    // `ready` is called on the main queue: nil once listening, or why it couldn't.
    public func start(ready: @escaping (String?) -> Void) {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback   // never reachable from the network
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: DispatchQueue.main.async { ready(nil) }
                case .failed(let e): DispatchQueue.main.async { ready("\(e)") }
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self.map { Connection(c, server: $0).start() } }
            l.start(queue: queue)
            listener = l
        } catch {
            ready("\(error)")
        }
    }

    fileprivate func handle(_ r: HTTPRequest, respond: @escaping (Data) -> Void) {
        if let (status, message) = rejection(r, port: port) {
            return respond(response(status, Data(message.utf8), type: "text/plain"))
        }
        handler(r.body) { out in
            respond(out.map { response(200, $0) } ?? response(202))
        }
    }

    private final class Connection {
        let c: NWConnection
        let server: LocalServer
        var buffer = Data()
        var busy = false

        init(_ c: NWConnection, server: LocalServer) { self.c = c; self.server = server }

        func start() {
            c.start(queue: server.queue)
            receive()
        }

        func receive() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
                if let data { buffer.append(data); next() }
                if done || error != nil { c.cancel() } else { receive() }
            }
        }

        // handle the next buffered request, once the previous one has been answered
        func next() {
            guard !busy else { return }
            switch parseRequest(buffer) {
            case .incomplete:
                return
            case .bad(let status):
                c.send(content: response(status), completion: .contentProcessed { [c] _ in c.cancel() })
            case .request(let r, let consumed):
                buffer.removeFirst(consumed)
                busy = true
                server.handle(r) { [self] out in
                    c.send(content: out, completion: .contentProcessed { [self] _ in
                        server.queue.async { [self] in busy = false; next() }
                    })
                }
            }
        }
    }
}
