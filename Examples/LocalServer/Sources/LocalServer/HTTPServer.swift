import Foundation
import Network

/// The smallest HTTP/1.1 server that can carry the engine's wire protocols on
/// loopback: one request per connection, `Content-Length` bodies, no TLS, no
/// keep-alive. Example code for a local companion process, not a web server.
struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]   // lowercased names
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: body)
    }

    static func text(_ text: String, status: Int = 200, type: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": type], body: Data(text.utf8))
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }

    static let reasons: [Int: String] = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
                                        405: "Method Not Allowed", 413: "Payload Too Large", 415: "Unsupported Media Type",
                                        429: "Too Many Requests", 500: "Internal Server Error", 501: "Not Implemented",
                                        503: "Service Unavailable", 504: "Gateway Timeout"]

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        all["Cache-Control"] = "no-store"
        all["X-Content-Type-Options"] = "nosniff"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

final class HTTPServer {
    typealias Handler = (HTTPRequest) async -> HTTPResponse

    private let listener: NWListener
    private let queue = DispatchQueue(label: "pomvox.local-server")
    private let handler: Handler
    private let maxBody: Int

    /// Binds to 127.0.0.1 only. Port 0 picks a free port; `start()` returns the actual one.
    init(port: UInt16, maxBody: Int, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        listener = try NWListener(using: parameters)
        self.handler = handler
        self.maxBody = maxBody
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [listener] state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error): resumed = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return connection.cancel() }
                Connection(connection, queue: self.queue, maxBody: self.maxBody, handler: self.handler).start()
            }
            listener.start(queue: queue)
        }
    }

    private final class Connection {
        private let connection: NWConnection
        private let queue: DispatchQueue
        private let maxBody: Int
        private let handler: Handler
        private var buffer = Data()
        private var request: (method: String, path: String, query: [String: String], headers: [String: String], length: Int)?
        private var continued = false

        init(_ connection: NWConnection, queue: DispatchQueue, maxBody: Int, handler: @escaping Handler) {
            self.connection = connection; self.queue = queue; self.maxBody = maxBody; self.handler = handler
        }

        func start() {
            connection.start(queue: queue)
            receive()
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [self] data, _, complete, error in
                if let data { buffer.append(data) }
                if error != nil { return connection.cancel() }
                if request == nil {
                    guard let headersEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                        if buffer.count > 64 * 1024 { return respond(.error(400, "headers too large")) }
                        return complete ? connection.cancel() : receive()
                    }
                    guard let parsed = parseHead(buffer[..<headersEnd.lowerBound]) else { return respond(.error(400, "malformed request")) }
                    buffer.removeSubrange(..<headersEnd.upperBound)
                    request = parsed
                    if parsed.length > maxBody { return respond(.error(413, "body exceeds \(maxBody) bytes")) }
                    if parsed.headers["expect"]?.lowercased() == "100-continue", !continued {
                        continued = true
                        connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
                    }
                }
                guard let head = request else { return }
                if buffer.count >= head.length {
                    let body = buffer.prefix(head.length)
                    let req = HTTPRequest(method: head.method, path: head.path, query: head.query, headers: head.headers, body: Data(body))
                    Task { [self] in respond(await handler(req)) }
                } else if complete {
                    respond(.error(400, "body shorter than Content-Length"))
                } else {
                    receive()
                }
            }
        }

        private func parseHead(_ data: Data) -> (method: String, path: String, query: [String: String], headers: [String: String], length: Int)? {
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            var lines = text.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ")
            guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return nil }
            var headers: [String: String] = [:]
            for line in lines where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":") else { return nil }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let target = String(requestLine[1])
            let pathAndQuery = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            var query: [String: String] = [:]
            if pathAndQuery.count == 2 {
                for pair in pathAndQuery[1].split(separator: "&") {
                    let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                    query[parts[0]] = parts.count > 1 ? parts[1] : ""
                }
            }
            let length = Int(headers["content-length"] ?? "0") ?? -1
            guard length >= 0 else { return nil }
            return (String(requestLine[0]), String(pathAndQuery[0]), query, headers, length)
        }

        private func respond(_ response: HTTPResponse) {
            connection.send(content: response.serialized(), completion: .contentProcessed { [connection] _ in
                connection.cancel()
            })
        }
    }
}
