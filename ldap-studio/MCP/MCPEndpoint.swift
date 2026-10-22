//
//  MCPEndpoint.swift
//  ldap-studio
//
//  The Model Context Protocol's JSON-RPC side: turns one HTTP request
//  body (a message, or a batch of them) into the response body. Stateless
//  — every request stands on its own, so there are no sessions to track
//  or expire. Only tools are offered, and every tool is a read.
//

import Foundation

nonisolated struct MCPHTTPResponse: Sendable {
    var status: Int
    var body: Data?
}

@MainActor
final class MCPEndpoint {
    /// Newest first; a client asking for one we don't know gets the newest.
    nonisolated static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    nonisolated static let instructions = """
        Read-only access to the LDAP directories the user has shared from LDAP Studio. \
        Start with list_connections, then use list_children to explore the tree, search to find \
        entries with an RFC 4515 filter, get_entry to read one, and get_schema to learn what \
        object classes and attributes mean. Nothing here can change a directory. Secrets such as \
        userPassword are never returned. Results are capped in size: prefer specific filters, a \
        narrower base_dn and only the attributes you need.
        """

    private let tools: MCPTools
    private let version: String

    init(tools: MCPTools, version: String) {
        self.tools = tools
        self.version = version
    }

    func handle(_ body: Data) async -> MCPHTTPResponse {
        // Parsed off the main actor: a megabyte of JSON shouldn't stall the UI.
        let parsed = await Task.detached(priority: .userInitiated) { try? JSONValue.decode(body) }.value
        guard let message = parsed else {
            return MCPHTTPResponse(status: 400, body: Self.error(id: .null, code: -32700, "Parse error").encoded())
        }
        if case let .array(batch) = message {
            guard !batch.isEmpty, batch.count <= 20 else {
                return MCPHTTPResponse(status: 400, body: Self.error(id: .null, code: -32600, "Invalid batch").encoded())
            }
            var replies: [JSONValue] = []
            for item in batch {
                if let reply = await handle(message: item) { replies.append(reply) }
            }
            return replies.isEmpty ? MCPHTTPResponse(status: 202, body: nil)
                                   : MCPHTTPResponse(status: 200, body: JSONValue.array(replies).encoded())
        }
        guard let reply = await handle(message: message) else { return MCPHTTPResponse(status: 202, body: nil) }
        return MCPHTTPResponse(status: 200, body: reply.encoded())
    }

    /// The reply to one message, or nil for a notification (or a client's
    /// response to us, which we never ask for).
    private func handle(message: JSONValue) async -> JSONValue? {
        guard let object = message.objectValue, object["jsonrpc"] == "2.0" else {
            return Self.error(id: message["id"] ?? .null, code: -32600, "Invalid request")
        }
        guard case let .string(method)? = object["method"] else {
            if object["result"] != nil || object["error"] != nil { return nil }
            return Self.error(id: object["id"] ?? .null, code: -32600, "Invalid request")
        }
        guard let id = object["id"] else { return nil }
        switch id {
        case .string, .int: break
        default: return Self.error(id: .null, code: -32600, "Invalid request id")
        }
        let params = object["params"]?.objectValue ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue
            let version = requested.flatMap { Self.protocolVersions.contains($0) ? $0 : nil }
                ?? Self.protocolVersions[0]
            return Self.result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": [
                    "name": "ldap-studio",
                    "title": "LDAP Studio (read-only)",
                    "version": .string(self.version),
                ],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": .array(MCPTools.definitions)])
        case "tools/call":
            guard case let .string(name)? = params["name"], MCPTools.toolNames.contains(name) else {
                return Self.error(id: id, code: -32602, "Unknown tool: \((params["name"]?.stringValue ?? "(none)").prefix(100))")
            }
            let arguments: [String: JSONValue]
            switch params["arguments"] {
            case nil, .null?: arguments = [:]
            case let .object(given)?: arguments = given
            default: return Self.error(id: id, code: -32602, "arguments must be an object")
            }
            let (text, isError) = await tools.call(name, arguments: arguments)
            return Self.result(id: id, [
                "content": [["type": "text", "text": .string(text)]],
                "isError": .bool(isError),
            ])
        default:
            return Self.error(id: id, code: -32601, "Method not found: \(method.prefix(100))")
        }
    }

    private static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(id: JSONValue, code: Int, _ message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }
}
