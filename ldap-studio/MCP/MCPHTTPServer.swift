//
//  MCPHTTPServer.swift
//  ldap-studio
//
//  A deliberately small HTTP/1.1 server for MCP's Streamable HTTP
//  transport: POST /mcp with a JSON body, answered with JSON. It listens
//  on 127.0.0.1 only and turns away anything that isn't
//
//    • from this Mac (loopback interface, loopback peer address),
//    • addressed to 127.0.0.1/localhost — a DNS-rebinding page in a
//      browser sends its own host name, and a browser's Origin header
//      would name the page's site,
//    • carrying the access token as a Bearer credential,
//
//  before the body is even looked at. One request per connection; bodies
//  and headers are size-capped, and a client that dawdles is dropped.
//

import Foundation
import Network

nonisolated final class MCPHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (Data) async -> MCPHTTPResponse

    enum State: Sendable, Equatable {
        case ready
        case failed(String)
    }

    static let path = "/mcp"
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 1024 * 1024
    static let maxConnections = 16
    /// To send a whole request in. A tool call that then takes a while is
    /// limited by MCPTools instead.
    static let requestTimeout: TimeInterval = 30

    let port: UInt16
    private let handler: Handler
    private let onStateChange: @Sendable (State) -> Void
    private let queue = DispatchQueue(label: "app.ldap-studio.mcp-server")

    private let tokenLock = NSLock()
    private var token: String

    // Only touched on `queue`.
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    init(port: UInt16, token: String, handler: @escaping Handler,
         onStateChange: @escaping @Sendable (State) -> Void) {
        self.port = port
        self.token = token
        self.handler = handler
        self.onStateChange = onStateChange
    }

    /// Takes effect for the next request; one already accepted still
    /// finishes.
    func setToken(_ token: String) {
        tokenLock.withLock { self.token = token }
    }

    private var currentToken: String { tokenLock.withLock { token } }

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            guard let nwPort = NWEndpoint.Port(rawValue: port), port != 0 else {
                onStateChange(.failed("\(port) isn't a usable port."))
                return
            }
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            parameters.acceptLocalOnly = true
            parameters.allowLocalEndpointReuse = true
            do {
                let listener = try NWListener(using: parameters)
                listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                self.listener = listener
                listener.start(queue: queue)
            } catch {
                onStateChange(.failed(describe(error)))
            }
        }
    }

    /// Stops listening and drops every open connection, cancelling the
    /// requests they were waiting on.
    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            connections.values.forEach { $0.close() }
            connections.removeAll()
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            onStateChange(.ready)
        case let .failed(error), let .waiting(error):
            listener?.cancel()
            listener = nil
            onStateChange(.failed(describe(error)))
        default:
            break
        }
    }

    private func describe(_ error: Error) -> String {
        if case let NWError.posix(code) = error {
            if code == .EADDRINUSE { return "Port \(port) is already in use by another app. Choose a different port." }
            if code == .EACCES { return "Not allowed to listen on port \(port). Choose a port above 1024." }
        }
        return "\(error.localizedDescription)"
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint), connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let http = HTTPConnection(connection, server: self, queue: queue)
        connections[ObjectIdentifier(http)] = http
        http.start()
    }

    fileprivate func closed(_ connection: HTTPConnection) {
        connections[ObjectIdentifier(connection)] = nil
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case let .ipv4(address): return address.isLoopback
        case let .ipv6(address): return address.isLoopback || address.asIPv4?.isLoopback == true
        default: return false
        }
    }

    // MARK: Requests

    fileprivate struct Request {
        let method: String
        let target: String
        let headers: [String: [String]]
        let body: Data

        func header(_ name: String) -> String? { headers[name]?.first }
    }

    /// What to do with a complete request: answer it straight away (it was
    /// turned away), or hand its body to the MCP endpoint.
    fileprivate enum Route {
        case respond(Int, extraHeaders: [(String, String)])
        case handle(Data)
    }

    fileprivate func route(_ request: Request) -> Route {
        let hosts = ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"]
        guard request.headers["host"]?.count == 1,
              let host = request.header("host")?.lowercased(), hosts.contains(host) else {
            return .respond(403, extraHeaders: [])
        }
        if let origins = request.headers["origin"] {
            guard origins.count == 1, hosts.map({ "http://\($0)" }).contains(origins[0].lowercased()) else {
                return .respond(403, extraHeaders: [])
            }
        }
        let path = request.target.prefix { $0 != "?" && $0 != "#" }
        guard path == Self.path || path == Self.path + "/" else { return .respond(404, extraHeaders: []) }
        guard request.headers["authorization"]?.count == 1,
              let credential = request.header("authorization"), isAuthorized(credential) else {
            return .respond(401, extraHeaders: [("WWW-Authenticate", "Bearer realm=\"LDAP Studio\"")])
        }
        guard request.method == "POST" else { return .respond(405, extraHeaders: [("Allow", "POST")]) }
        guard let type = request.header("content-type")?.lowercased(),
              type.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "application/json" else {
            return .respond(415, extraHeaders: [])
        }
        return .handle(request.body)
    }

    /// "Bearer <token>", compared in constant time.
    private func isAuthorized(_ credential: String) -> Bool {
        let parts = credential.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame else { return false }
        let expected = Array(currentToken.utf8)
        let given = Array(parts[1].trimmingCharacters(in: .whitespaces).utf8)
        guard !expected.isEmpty, given.count == expected.count else { return false }
        var difference: UInt8 = 0
        for index in expected.indices { difference |= expected[index] ^ given[index] }
        return difference == 0
    }

    fileprivate func respond(to body: Data) async -> MCPHTTPResponse {
        await handler(body)
    }
}

// MARK: - One connection

nonisolated private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private weak var server: MCPHTTPServer?
    private let queue: DispatchQueue

    // Only touched on `queue`.
    private var buffer = Data()
    private var sentContinue = false
    private var isClosed = false
    private var timeout: DispatchWorkItem?
    private var task: Task<Void, Never>?

    init(_ connection: NWConnection, server: MCPHTTPServer, queue: DispatchQueue) {
        self.connection = connection
        self.server = server
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { [weak self] in self?.send(status: 408) }
        self.timeout = timeout
        queue.asyncAfter(deadline: .now() + MCPHTTPServer.requestTimeout, execute: timeout)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data { self.buffer.append(data) }
            switch self.parse() {
            case .incomplete:
                if isComplete || error != nil { self.close() } else { self.receive() }
            case let .invalid(status):
                self.send(status: status)
            case let .complete(request):
                self.timeout?.cancel()
                self.dispatch(request)
            }
        }
    }

    private enum Parse {
        case incomplete
        case invalid(Int)
        case complete(MCPHTTPServer.Request)
    }

    private func parse() -> Parse {
        // Chunked framing can take a few times the body's size.
        guard buffer.count <= MCPHTTPServer.maxHeaderBytes + 2 * MCPHTTPServer.maxBodyBytes else { return .invalid(413) }
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else {
            return buffer.count > MCPHTTPServer.maxHeaderBytes ? .invalid(431) : .incomplete
        }
        guard headerEnd.lowerBound - buffer.startIndex <= MCPHTTPServer.maxHeaderBytes,
              let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid(431)
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0" else {
            return .invalid(400)
        }
        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(400) }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, !name.contains(" "), !name.contains("\t") else { return .invalid(400) }
            headers[name, default: []].append(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        let bodyStart = headerEnd.upperBound
        let body: Data
        if let encodings = headers["transfer-encoding"] {
            // Chunked, and nothing else: a request framed two ways at once
            // is how request smuggling starts.
            guard headers["content-length"] == nil, encodings.count == 1,
                  encodings[0].lowercased() == "chunked" else { return .invalid(400) }
            switch Self.decodeChunked(buffer[bodyStart...]) {
            case .incomplete:
                sendContinueIfExpected(headers)
                return .incomplete
            case let .invalid(status):
                return .invalid(status)
            case let .complete(decoded):
                body = decoded
            }
        } else {
            var length = 0
            if let lengths = headers["content-length"] {
                guard Set(lengths).count == 1, lengths[0].allSatisfy(\.isASCII), lengths[0].allSatisfy(\.isNumber),
                      let value = Int(lengths[0]) else { return .invalid(400) }
                length = value
            }
            guard length <= MCPHTTPServer.maxBodyBytes else { return .invalid(413) }
            guard buffer.endIndex - bodyStart >= length else {
                sendContinueIfExpected(headers)
                return .incomplete
            }
            body = Data(buffer[bodyStart..<bodyStart + length])
        }
        return .complete(MCPHTTPServer.Request(
            method: String(requestLine[0]), target: String(requestLine[1]),
            headers: headers, body: body
        ))
    }

    /// curl and others wait for this before sending a large body.
    private func sendContinueIfExpected(_ headers: [String: [String]]) {
        guard !sentContinue, headers["expect"]?.first?.lowercased() == "100-continue" else { return }
        sentContinue = true
        connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
    }

    private enum Chunked {
        case incomplete
        case invalid(Int)
        case complete(Data)
    }

    /// A chunked body (RFC 9112 §7.1) — what .NET's HttpClient, among
    /// others, sends when it doesn't know the length up front. Chunk
    /// extensions and trailers are read past and ignored.
    private static func decodeChunked(_ data: Data.SubSequence) -> Chunked {
        let crlf = Data("\r\n".utf8)
        let maxLine = 1024
        var body = Data()
        var index = data.startIndex
        while true {
            guard let lineEnd = data[index...].range(of: crlf) else {
                return data.endIndex - index > maxLine ? .invalid(400) : .incomplete
            }
            guard lineEnd.lowerBound - index <= maxLine,
                  let line = String(data: data[index..<lineEnd.lowerBound], encoding: .ascii) else { return .invalid(400) }
            let sizeText = line.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
            guard !sizeText.isEmpty, sizeText.count <= 8, sizeText.allSatisfy(\.isHexDigit),
                  let size = Int(sizeText, radix: 16) else { return .invalid(400) }
            index = lineEnd.upperBound
            if size == 0 {
                // Trailer lines, then an empty line.
                while true {
                    guard let end = data[index...].range(of: crlf) else {
                        return data.endIndex - index > MCPHTTPServer.maxHeaderBytes ? .invalid(431) : .incomplete
                    }
                    if end.lowerBound == index { return .complete(body) }
                    index = end.upperBound
                }
            }
            guard body.count + size <= MCPHTTPServer.maxBodyBytes else { return .invalid(413) }
            guard data.endIndex - index >= size + 2 else { return .incomplete }
            body.append(data[index..<index + size])
            index += size
            guard data[index..<index + 2] == crlf else { return .invalid(400) }
            index += 2
        }
    }

    private func dispatch(_ request: MCPHTTPServer.Request) {
        guard let server else { return close() }
        switch server.route(request) {
        case let .respond(status, extraHeaders):
            send(status: status, extraHeaders: extraHeaders)
        case let .handle(body):
            task = Task { [weak self, server] in
                let response = await server.respond(to: body)
                guard !Task.isCancelled else { return }
                self?.queue.async { self?.send(status: response.status, body: response.body) }
            }
        }
    }

    private func send(status: Int, body: Data? = nil, extraHeaders: [(String, String)] = []) {
        guard !isClosed else { return }
        timeout?.cancel()
        let body = body ?? Data()
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var headers = extraHeaders + [
            ("Content-Length", "\(body.count)"),
            ("Cache-Control", "no-store"),
            ("X-Content-Type-Options", "nosniff"),
            ("Connection", "close"),
        ]
        if !body.isEmpty { headers.append(("Content-Type", "application/json")) }
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        timeout?.cancel()
        task?.cancel()
        connection.cancel()
        server?.closed(self)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 431: "Request Header Fields Too Large"
        default: "Error"
        }
    }
}
