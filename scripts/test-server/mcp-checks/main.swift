// Checks the MCP server end to end against the test server (see ../run.sh):
// the HTTP layer turning away anything that isn't an authorized local
// request, every tool, and that no secret or write gets through. Run with
// ../check.sh.
import Foundation

func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { failures += 1 } }
var failures = 0

func connection(_ name: String, _ bind: String, _ pw: String, base: String = "dc=example,dc=com",
                shared: Bool = true) -> SavedConnection {
    let c = SavedConnection(name: name, host: "127.0.0.1", port: 3389, useSSL: false, baseDN: base,
                            bindDN: bind, allowsMCP: shared)
    KeychainService.passwords[c.id] = pw
    return c
}

let port: UInt16 = 47_999
let token = "lds_test-token-0123456789abcdefghijklmnopqrstuv"

struct RawResponse {
    let status: Int
    let head: String
    let body: Data
}

/// Sends `request` as-is over a plain socket — so headers URLSession would
/// fix up (Host, Transfer-Encoding) can be sent wrong on purpose.
func raw(_ request: Data, host: String = "127.0.0.1") async -> RawResponse? {
    await Task.detached {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        _ = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            received.append(contentsOf: buffer[0..<n])
        }
        guard let split = received.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: received[..<split.lowerBound], as: UTF8.self)
        let status = Int(head.split(separator: " ")[1]) ?? 0
        return RawResponse(status: status, head: head, body: Data(received[split.upperBound...]))
    }.value
}

func post(_ body: String, auth: String? = "Bearer \(token)", host: String = "127.0.0.1:\(port)",
          path: String = "/mcp", method: String = "POST", extra: [String] = [],
          contentType: String = "application/json") async -> RawResponse? {
    var lines = ["\(method) \(path) HTTP/1.1", "Host: \(host)", "Content-Type: \(contentType)",
                 "Accept: application/json, text/event-stream", "Content-Length: \(body.utf8.count)"]
    if let auth { lines.append("Authorization: \(auth)") }
    lines += extra
    return await raw(Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8))
}

var nextID = 1
func rpc(_ method: String, _ params: JSONValue = [:]) async -> JSONValue? {
    nextID += 1
    let message: JSONValue = ["jsonrpc": "2.0", "id": .int(nextID), "method": .string(method), "params": params]
    guard let response = await post(message.encodedString), response.status == 200 else { return nil }
    return try? JSONValue.decode(response.body)
}

struct ToolResult {
    let text: String
    let isError: Bool
    var json: JSONValue? { try? JSONValue.decode(Data(text.utf8)) }
}

func tool(_ name: String, _ arguments: JSONValue = [:]) async -> ToolResult? {
    guard let reply = await rpc("tools/call", ["name": .string(name), "arguments": arguments]),
          case let .array(content)? = reply["result"]?["content"],
          let text = content.first?["text"]?.stringValue else { return nil }
    return ToolResult(text: text, isError: reply["result"]?["isError"] == true)
}

func count(_ value: JSONValue?, _ key: String) -> Int {
    if case let .array(items)? = value?[key] { return items.count }
    return -1
}

@MainActor func run() async {
    signal(SIGPIPE, SIG_IGN)
    let reader = connection("Reader", "cn=reader,ou=Service,dc=example,dc=com", "reader")
    let manager = connection("Manager", "cn=manager,ou=Service,dc=example,dc=com", "manager")
    let hidden = connection("Not Shared", "cn=manager,ou=Service,dc=example,dc=com", "manager", shared: false)
    let small = connection("Small", "cn=manager,dc=small,dc=test", "manager", base: "dc=small,dc=test")
    var connections = [reader, manager, hidden, small]

    var extraHidden = ["mail"]
    let tools = MCPTools(connections: { connections }, extraHidden: { extraHidden })
    let endpoint = MCPEndpoint(tools: tools, version: "test")
    let ready = AsyncStream<MCPHTTPServer.State>.makeStream()
    let server = MCPHTTPServer(port: port, token: token,
                               handler: { await endpoint.handle($0) },
                               onStateChange: { ready.continuation.yield($0) })
    server.start()
    var states = ready.stream.makeAsyncIterator()
    let state = await states.next()
    check(state == .ready, "server starts on 127.0.0.1:\(port): \(String(describing: state))")

    // A second server on the same port reports why it can't start.
    let clash = AsyncStream<MCPHTTPServer.State>.makeStream()
    let second = MCPHTTPServer(port: port, token: token, handler: { _ in MCPHTTPResponse(status: 500, body: nil) },
                               onStateChange: { clash.continuation.yield($0) })
    second.start()
    var clashStates = clash.stream.makeAsyncIterator()
    if case let .failed(message)? = await clashStates.next() {
        check(message.contains("already in use"), "port in use is reported: \(message)")
    } else {
        check(false, "a second server on the same port should fail")
    }
    second.stop()

    // MARK: HTTP layer
    let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"checks","version":"1"}}}"#
    check(await post(initialize, auth: nil)?.status == 401, "no token → 401")
    let unauthorized = await post(initialize, auth: "Bearer lds_wrong")
    check(unauthorized?.status == 401 && unauthorized?.head.contains("WWW-Authenticate: Bearer") == true, "wrong token → 401 with WWW-Authenticate")
    check(await post(initialize, auth: "Bearer \(token)x")?.status == 401, "token with an extra character → 401")
    check(await post(initialize, auth: "Basic \(token)")?.status == 401, "token without Bearer → 401")
    check(await post(initialize, auth: "Bearer \(token)", extra: ["Authorization: Bearer \(token)"])?.status == 401, "two Authorization headers → 401")
    check(await post(initialize, host: "evil.example:\(port)")?.status == 403, "foreign Host (DNS rebinding) → 403")
    check(await post(initialize, host: "127.0.0.1:1234")?.status == 403, "Host with the wrong port → 403")
    check(await post(initialize, extra: ["Origin: https://evil.example"])?.status == 403, "foreign Origin → 403")
    check(await post(initialize, extra: ["Origin: null"])?.status == 403, "Origin null → 403")
    check(await post(initialize, extra: ["Origin: http://localhost:\(port)"])?.status == 200, "local Origin → 200")
    check(await post(initialize, host: "localhost:\(port)")?.status == 200, "Host localhost → 200")
    check(await post(initialize, path: "/other")?.status == 404, "other path → 404")
    check(await post("", method: "GET")?.status == 405, "GET → 405 (no SSE stream)")
    check(await post("", method: "DELETE")?.status == 405, "DELETE → 405")
    check(await post(initialize, contentType: "text/plain")?.status == 415, "non-JSON content type → 415")
    func chunkedRequest(_ body: String, extra: String = "") -> Data {
        let first = String(body.prefix(10)), rest = String(body.dropFirst(10))
        let chunks = "\(String(first.utf8.count, radix: 16));ext=1\r\n\(first)\r\n\(String(rest.utf8.count, radix: 16))\r\n\(rest)\r\n0\r\nX-Trailer: 1\r\n\r\n"
        return Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\(extra)\r\n\(chunks)".utf8)
    }
    let chunkedReply = await raw(chunkedRequest(initialize))
    check(chunkedReply?.status == 200 && String(decoding: chunkedReply?.body ?? Data(), as: UTF8.self).contains("protocolVersion"),
          "chunked body (as .NET clients send) is decoded")
    check(await raw(chunkedRequest(initialize, extra: "Content-Length: 5\r\n"))?.status == 400, "chunked and Content-Length together → 400")
    let badChunk = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n-5\r\nhello\r\n0\r\n\r\n"
    check(await raw(Data(badChunk.utf8))?.status == 400, "malformed chunk size → 400")
    let hugeChunk = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n\(String(MCPHTTPServer.maxBodyBytes + 1, radix: 16))\r\n"
    check(await raw(Data(hugeChunk.utf8))?.status == 413, "chunk past 1 MB → 413")
    let huge = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(MCPHTTPServer.maxBodyBytes + 1)\r\n\r\n"
    check(await raw(Data(huge.utf8))?.status == 413, "body over 1 MB → 413, before it's sent")
    let bigHeader = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nX-Big: \(String(repeating: "a", count: 20_000))\r\n\r\n"
    check(await raw(Data(bigHeader.utf8))?.status == 431, "oversized headers → 431")
    check(await post("{not json")?.status == 400, "malformed JSON → 400")
    // Nesting is refused quickly rather than tying up the app.
    let clock = ContinuousClock()
    let deep = #"{"jsonrpc":"2.0","id":3,"method":"ping","params":{"x":"# + String(repeating: "[", count: 8000)
        + String(repeating: "]", count: 8000) + "}}"
    var started = clock.now
    check(await post(deep)?.status == 400 && clock.now - started < .seconds(2), "8,000-deep nesting → 400, quickly")
    let wide = #"{"jsonrpc":"2.0","id":4,"method":"ping","params":{"x":["# + Array(repeating: String(repeating: "[", count: 16) + "1" + String(repeating: "]", count: 16), count: 400).joined(separator: ",") + "]}}"
    started = clock.now
    check(await post(wide)?.status == 200 && clock.now - started < .seconds(2), "\(wide.utf8.count / 1024) KB of 16-deep arrays parses quickly")
    let continued = await post(initialize, extra: ["Expect: 100-continue"])
    check(continued?.status == 100 || continued?.status == 200, "Expect: 100-continue is answered")

    // Not reachable from the network, only from this Mac.
    if let lan = lanAddress() {
        let fromLAN = await raw(Data("GET / HTTP/1.1\r\n\r\n".utf8), host: lan)
        check(fromLAN == nil, "not reachable on the network address \(lan)")
    } else {
        print("SKIP network-address check (no IPv4 address besides loopback)")
    }

    // MARK: JSON-RPC
    let initReply = try? JSONValue.decode(await post(initialize)?.body ?? Data())
    check(initReply?["result"]?["protocolVersion"] == "2025-06-18", "initialize echoes a supported protocol version")
    check(initReply?["result"]?["capabilities"]?["tools"] != nil
          && initReply?["result"]?["capabilities"]?["resources"] == nil,
          "initialize offers tools only")
    let future = #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#
    let futureReply = try? JSONValue.decode(await post(future)?.body ?? Data())
    check(futureReply?["result"]?["protocolVersion"] == .string(MCPEndpoint.protocolVersions[0]), "unknown protocol version → the newest supported")
    check(await post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)?.status == 202, "notification → 202")
    check(await rpc("ping")?["result"] == [:], "ping")
    let unknownMethod = await rpc("resources/list")
    check(unknownMethod?["error"]?["code"] == -32601, "unoffered method → method not found")
    let batch = #"[{"jsonrpc":"2.0","id":7,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]"#
    if case let .array(replies)? = try? JSONValue.decode(await post(batch)?.body ?? Data()) {
        check(replies.count == 1 && replies[0]["id"] == 7, "batch answers its requests only")
    } else { check(false, "batch") }

    let list = await rpc("tools/list")
    var names: [String] = []
    var allReadOnly = true
    if case let .array(defs)? = list?["result"]?["tools"] {
        for def in defs {
            names.append(def["name"]?.stringValue ?? "")
            if def["annotations"]?["readOnlyHint"] != true || def["annotations"]?["destructiveHint"] != false {
                allReadOnly = false
            }
        }
    }
    check(Set(names) == ["list_connections", "get_server_info", "search", "get_entry", "list_children", "get_schema"],
          "tools/list offers the six read tools: \(names)")
    check(allReadOnly, "every tool is annotated read-only and non-destructive")
    for write in ["add_entry", "modify_entry", "delete_entry", "rename_entry"] {
        let reply = await rpc("tools/call", ["name": .string(write), "arguments": ["connection": "Manager", "dn": "ou=Empty,dc=example,dc=com"]])
        check(reply?["error"]?["code"] == -32602, "\(write) doesn't exist")
    }

    // MARK: Tools
    let listed = await tool("list_connections")
    let listedNames: [String] = {
        guard case let .array(items)? = listed?.json?["connections"] else { return [] }
        return items.compactMap { $0["name"]?.stringValue }
    }()
    check(listedNames == ["Manager", "Reader", "Small"], "list_connections shows only shared connections: \(listedNames)")
    check(listed?.text.contains("\"manager\"") == false && listed?.text.contains("password") == false,
          "list_connections carries no password")

    let notShared = await tool("search", ["connection": "Not Shared"])
    check(notShared?.isError == true && notShared?.text.contains("Shared connections") == true,
          "a connection that isn't shared is refused: \(notShared?.text ?? "nil")")
    check(await tool("search", [:])?.isError == true, "connection is required")
    let longName = await tool("search", ["connection": .string(String(repeating: "x", count: 900_000))])
    check(longName?.isError == true && (longName?.text.utf8.count ?? .max) < 5000, "errors don't echo huge arguments back")

    let info = await tool("get_server_info", ["connection": "Reader"])
    check(info?.text.contains("dc=example,dc=com") == true && info?.isError == false, "get_server_info lists the naming contexts")

    let people = await tool("search", ["connection": "Reader", "base_dn": "ou=People,dc=example,dc=com",
                                       "filter": "(objectClass=inetOrgPerson)", "limit": 5])
    check(count(people?.json, "entries") == 5 && people?.json?["complete"] == false
          && people?.json?["note"] != nil, "search stops at its limit and says so")
    let manyPeople = await tool("search", ["connection": "Reader", "base_dn": "ou=People,dc=example,dc=com",
                                           "filter": "(uid=user0*)", "limit": 500])
    check(count(manyPeople?.json, "entries") == 500, "search reads 500 entries over pages")
    let tooMany = await tool("search", ["connection": "Reader", "limit": 100_000])
    check(tooMany?.isError == true, "limit above the maximum is refused")

    let user = await tool("get_entry", ["connection": "Manager", "dn": "uid=user000000,ou=People,dc=example,dc=com"])
    let userAttributes = user?.json?["attributes"]?.objectValue ?? [:]
    check(userAttributes["cn"] == ["User 000000"], "get_entry reads an entry")
    check(userAttributes.keys.contains { $0.lowercased() == "userpassword" } == false
          && user?.text.contains("password\"]") == false,
          "userPassword is left out even though the bind may read it")
    check(user?.json?["hidden_attributes"] == ["mail", "userPassword"] || user?.json?["hidden_attributes"] == ["userPassword", "mail"],
          "…and named as hidden: \(user?.json?["hidden_attributes"]?.encodedString ?? "nil")")
    check(userAttributes["mail"] == nil, "a user-hidden attribute (mail) is left out")
    if case let .array(photo)? = userAttributes["jpegPhoto"], let first = photo.first?.stringValue {
        check(first.hasPrefix("(binary value,"), "binary values are described, not dumped: \(first)")
    } else { check(false, "jpegPhoto should be listed") }

    for (filter, label) in [("(userPassword=password)", "equality"), ("(&(uid=user000000)(userpassword=p*))", "nested, lowercased"),
                            ("(userPassword;binary=*)", "with options"), ("(2.5.4.35=*)", "by OID"),
                            ("(:caseExactMatch:=password)", "any-attribute extensible match"),
                            ("(mail=user*)", "user-hidden attribute"), ("(rfc822Mailbox=user*)", "alias of a hidden attribute"),
                            ("(anr=user)", "ambiguous name resolution"), ("(notAnAttribute=x)", "attribute the schema doesn't have"),
                            ("uid=user000000", "unparenthesized")] {
        let result = await tool("search", ["connection": "Manager", "filter": .string(filter)])
        check(result?.isError == true, "filter refused (\(label)): \(result?.text.prefix(90) ?? "nil")")
    }
    for attribute in ["userPassword", "USERPASSWORD", "2.5.4.35", "userPassword;binary", "cn)(objectClass=*"] {
        let result = await tool("get_entry", ["connection": "Manager", "dn": "uid=user000000,ou=People,dc=example,dc=com",
                                              "attributes": [.string(attribute)]])
        check(result?.isError == true, "attribute refused: \(attribute)")
    }
    let operational = await tool("get_entry", ["connection": "Manager", "dn": "uid=user000000,ou=People,dc=example,dc=com",
                                               "attributes": ["*", "+"], "include_operational": true])
    check(operational?.text.contains("\"password\"") == false && operational?.json?["attributes"]?["entryUUID"] != nil,
          "operational attributes come back, still without secrets")

    let missing = await tool("get_entry", ["connection": "Reader", "dn": "uid=nobody,ou=People,dc=example,dc=com"])
    check(missing?.isError == true, "a missing entry is a tool error")
    let restricted = await tool("list_children", ["connection": "Reader", "dn": "ou=Restricted,dc=example,dc=com"])
    check(restricted?.isError == true, "a branch the bind can't search reports the server's refusal")

    // Hiding a subtype also rules out filtering on its supertype, which
    // matches the subtype's values.
    extraHidden = ["sn", "objectClass"]
    for filter in ["(sn=000000)", "(name=000000)", "(2.5.4.41=000000)"] {
        let result = await tool("search", ["connection": "Reader", "base_dn": "ou=People,dc=example,dc=com", "filter": .string(filter)])
        check(result?.isError == true, "filter refused when sn is hidden: \(filter)")
    }
    let cnStillWorks = await tool("search", ["connection": "Reader", "base_dn": "ou=People,dc=example,dc=com", "filter": "(cn=User 000000)"])
    check(count(cnStillWorks?.json, "entries") == 1, "a sibling subtype (cn) can still be filtered on")
    let hiddenClasses = await tool("list_children", ["connection": "Reader", "dn": "ou=People,dc=example,dc=com", "limit": 3])
    check(count(hiddenClasses?.json, "children") == 3 && hiddenClasses?.text.contains("object_classes") == false
          && hiddenClasses?.text.contains("inetOrgPerson") == false, "list_children leaves out a hidden objectClass")
    extraHidden = ["mail"]

    // Without a schema, nothing but objectClass can be named.
    let blind = MCPAttributePolicy(schema: nil)
    check((try? blind.check(filter: "(&(objectClass=person)(!(objectClass=computer)))")) != nil, "no schema: objectClass filters still work")
    check((try? blind.check(filter: "(cn=Alice)")) == nil && (try? blind.check("cn")) == nil, "no schema: other names are refused")
    check(!blind.isShown("cn") && !blind.isShown("surname") && blind.isShown("objectClass"),
          "no schema: only objectClass values are shown, since aliases can't be told apart")
    check(MCPAttributePolicy(extraHidden: ["mail;lang-en"], schema: nil).isHidden("mail"),
          "hiding an attribute with options hides the whole attribute")
    check(MCPAttributePolicy(schema: nil).isHidden("olcDbPass") && MCPAttributePolicy(schema: nil).isHidden("olcSyncrepl"),
          "server configuration credentials are hidden")
    check(!MCPAttributePolicy(extraHidden: ["2.5.4.0"], schema: nil).isShown("objectClass"),
          "no schema: objectClass hidden by its OID stays hidden")
    let saslOID = "1.3.6.1.4.1.1466.101.120.14"
    check(!MCPAttributePolicy(extraHidden: [saslOID], schema: nil).isShownInRootDSE("supportedSASLMechanisms")
          && MCPAttributePolicy(schema: nil).isShownInRootDSE("supportedSASLMechanisms"),
          "root DSE: unknown names are withheld while a hidden OID can't be resolved")
    let emptySchema = MCPAttributePolicy(schema: LdapSchema(objectClasses: [], attributeTypes: []))
    check(!emptySchema.knowsSchema && (try? emptySchema.check("2.5.4.3")) == nil, "an empty schema counts as none")

    let top = await tool("list_children", ["connection": "Reader"])
    check(count(top?.json, "children") == 8, "list_children of the base DN: 8 children")
    let contexts = await tool("list_children", ["connection": "Reader", "dn": ""])
    check(contexts?.text.contains("dc=example,dc=com") == true, "list_children of \"\" lists naming contexts")
    let oneContext = await tool("list_children", ["connection": "Reader", "dn": "", "limit": 1])
    check(count(oneContext?.json, "children") == 1 && oneContext?.json?["complete"] == false, "naming contexts past the limit aren't reported complete")
    let someChildren = await tool("list_children", ["connection": "Reader", "dn": "ou=People,dc=example,dc=com", "limit": 10])
    check(count(someChildren?.json, "children") == 10 && someChildren?.json?["complete"] == false, "list_children respects its limit")

    let personClass = await tool("get_schema", ["connection": "Reader", "object_class": "inetOrgPerson"])
    if case let .array(must)? = personClass?.json?["must"], case let .array(may)? = personClass?.json?["may"] {
        check(must.contains("sn") && must.contains("cn") && may.contains("mail"), "get_schema resolves inherited MUST/MAY")
    } else { check(false, "get_schema object_class: \(personClass?.text.prefix(200) ?? "nil")") }
    let passwordType = await tool("get_schema", ["connection": "Reader", "attribute": "userPassword"])
    check(passwordType?.json?["note"] != nil, "get_schema flags hidden attribute types")
    let names2 = await tool("get_schema", ["connection": "Reader", "contains": "person"])
    check(names2?.text.contains("inetOrgPerson") == true, "get_schema lists names by substring")

    // The manager could write; nothing reachable through MCP does.
    let before = await tool("get_entry", ["connection": "Manager", "dn": "ou=Empty,dc=example,dc=com"])
    _ = await rpc("tools/call", ["name": "search", "arguments": ["connection": "Manager", "base_dn": "ou=Empty,dc=example,dc=com", "filter": "(objectClass=*)", "scope": "base", "attributes": ["description"], "add": ["description": "x"]]])
    let after = await tool("get_entry", ["connection": "Manager", "dn": "ou=Empty,dc=example,dc=com"])
    check(before?.text == after?.text, "unknown arguments don't change anything")

    // A queued call that's cancelled gives up its place without running.
    let limiter = MCPCallLimiter(limit: 1)
    try? await limiter.acquire()
    let queued = Task { @MainActor in
        do { try await limiter.acquire(); return "acquired" } catch { return "cancelled" }
    }
    try? await Task.sleep(for: .milliseconds(50))
    queued.cancel()
    check(await queued.value == "cancelled", "a cancelled waiter stops waiting")
    limiter.release()
    let next = Task { @MainActor in
        do { try await limiter.acquire(); return true } catch { return false }
    }
    try? await Task.sleep(for: .milliseconds(50))
    check(await next.value, "its slot isn't lost")

    // The Operation Log shows the agent's reads as such.
    check(OperationLog.shared.entries.contains { $0.summary.hasPrefix("[MCP] search") }, "Operation Log tags MCP reads")

    // Sharing turned off takes effect on the next call.
    connections[1].allowsMCP = false
    check(await tool("search", ["connection": "Manager"])?.isError == true, "unsharing a connection takes effect at once")

    // A new token locks out the old one.
    server.setToken("lds_new-token-abcdefghijklmnopqrstuvwxyz0123456789")
    check(await post(initialize)?.status == 401, "old token refused after a new one is set")
    check(await post(initialize, auth: "Bearer lds_new-token-abcdefghijklmnopqrstuvwxyz0123456789")?.status == 200, "new token accepted")

    server.stop()
    try? await Task.sleep(for: .milliseconds(300))
    check(await post(initialize) == nil, "stopped server refuses connections")

    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
}

/// This Mac's first non-loopback IPv4 address, if it has one.
func lanAddress() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard let address = pointer.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        let string = String(cString: host)
        if !string.hasPrefix("127.") { return string }
    }
    return nil
}

await run()
exit(failures == 0 ? 0 : 1)
