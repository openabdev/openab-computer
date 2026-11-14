import Foundation
import Network

/// Streamable HTTP transport (MCP 2025-03-26+), request/response mode only:
/// every POST gets a plain `application/json` reply, never an SSE stream. Clients
/// must advertise `text/event-stream` in Accept per spec but we don't open one —
/// this daemon has no server-initiated messages. GET (client-opened stream) → 405.
///
/// Sessions: `Mcp-Session-Id` is issued on `initialize` and required afterwards.
/// State per session is nil today; the id exists so clients behave and so we can
/// attach per-session state (e.g. exec jobs) later.
public actor MCPHTTPEndpoint {
    public let path: String
    private let server: MCPServer
    private let auth: AuthPolicy
    private var sessions: Set<String> = []
    private let log: @Sendable (String) -> Void
    /// Reverse-attach grants (`/attach`). nil ⇒ the routes answer 404.
    private let attach: AttachManager?

    public init(path: String = "/mcp", server: MCPServer, auth: AuthPolicy, attach: AttachManager? = nil,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.path = path; self.server = server; self.auth = auth; self.attach = attach; self.log = log
    }

    public func handle(_ req: HTTPRequest, remoteIsLoopback: Bool) async -> HTTPResponse {
        if req.path == "/healthz" { return .text(200, "ok\n") }
        let isAttach = attach != nil && (req.path == "/attach" || req.path.hasPrefix("/attach/"))
        guard req.path == path || isAttach else { return .text(404, "not found\n") }

        switch auth.decide(headers: req.headers, remoteIsLoopback: remoteIsLoopback) {
        case .deny(let why):
            log("deny \(req.method) \(req.path) from \(req.headers["x-forwarded-for"] ?? "local"): \(why)")
            return .text(401, "unauthorized\n")
        case .allow(let who):
            if isAttach { return await attachRoute(req, principal: who) }
            switch req.method {
            case "POST": return await post(req, principal: who)
            case "DELETE":
                if let sid = req.header("mcp-session-id") { sessions.remove(sid) }
                return .init(status: 204)
            case "GET":
                return .text(405, "server-initiated streams not supported\n")
            default:
                return .text(405, "method not allowed\n")
            }
        }
    }

    private func post(_ req: HTTPRequest, principal: String) async -> HTTPResponse {
        guard req.header("content-type")?.lowercased().hasPrefix("application/json") == true else {
            return .text(415, "Content-Type must be application/json\n")
        }
        let parsed = MCPServer.parse(req.body)
        let rpc: JSONRPCRequest
        switch parsed {
        case .failure(let e): return .json(400, JSONRPCResponse(id: .null, error: e))
        case .success(let r): rpc = r
        }

        // Session handling.
        let sid = req.header("mcp-session-id")
        var extraHeaders: [(String, String)] = []
        if rpc.method == "initialize" {
            let newID = UUID().uuidString.lowercased()
            sessions.insert(newID)
            extraHeaders.append(("Mcp-Session-Id", newID))
            log("session \(newID) opened by \(principal) (\(rpc.params?["clientInfo"]?["name"]?.stringValue ?? "?"))")
        } else if let sid {
            guard sessions.contains(sid) else {
                // Spec: unknown session ⇒ 404 so the client re-initializes.
                return .text(404, "unknown session\n")
            }
        } else {
            // Be lenient: stateless clients (curl probes) still work; the daemon has no per-session state yet.
        }

        guard let response = await server.handle(rpc) else {
            return .init(status: 202, headers: extraHeaders)   // notification
        }
        if rpc.method == "tools/call" {
            let name = rpc.params?["name"]?.stringValue ?? "?"
            log("\(principal) tools/call \(name)\(response.error != nil ? " -> rpc error" : "")")
        }
        var resp = HTTPResponse.json(200, response)
        resp.headers.append(contentsOf: extraHeaders)
        return resp
    }
}

// MARK: - /attach (reverse attach grants)

extension MCPHTTPEndpoint {
    /// `POST /attach` create · `GET /attach` list · `DELETE /attach/{id}` revoke.
    /// Same `AuthPolicy` as `/mcp`: the human's credential, never the sandbox's.
    private func attachRoute(_ req: HTTPRequest, principal: String) async -> HTTPResponse {
        guard let attach else { return .text(404, "not found\n") }
        await attach.sweep()
        let sub = req.path.dropFirst("/attach".count)
        switch (req.method, sub.isEmpty) {
        case ("GET", true):
            let grants = await attach.list()
            return .json(200, JSONValue.object(["grants": .array(grants.map(\.json))]))
        case ("POST", true):
            guard req.header("content-type")?.lowercased().hasPrefix("application/json") == true,
                  let body = try? JSONCoding.decoder.decode(JSONValue.self, from: req.body) else {
                return .json(400, JSONValue.object(["error": "body must be a JSON object"]))
            }
            guard let runtimeStr = body["runtime"]?.stringValue, let runtime = URL(string: runtimeStr) else {
                return .json(400, JSONValue.object(["error": "runtime (ws:// or wss:// URL) is required"]))
            }
            guard let session = body["session"]?.stringValue else {
                return .json(400, JSONValue.object(["error": "session is required"]))
            }
            // No profile (or a non-string one) ⇒ the fail-closed default. A retired
            // `desktop` resolves to `observe` with a warning; anything else unknown is
            // refused (#59).
            let profileStr = body["profile"]?.stringValue ?? ToolProfile.defaultProfile.rawValue
            guard let resolved = ToolProfile.resolve(requested: profileStr) else {
                return .json(400, JSONValue.object(["error": .string(ToolProfile.rejectionMessage)]))
            }
            let ttl = TimeInterval(body["ttl_secs"]?.intValue ?? Int(AttachManager.defaultTTL))
            let request = AttachManager.Request(runtime: runtime, session: session, profile: resolved.profile, ttl: ttl,
                                                secret: body["secret"]?.stringValue,
                                                adminCredential: body["admin_credential"]?.stringValue,
                                                requestedProfile: resolved.requested)
            do {
                let grant = try await attach.create(request, principal: principal)
                return .json(202, grant.json)
            } catch let f as AttachManager.Failure {
                switch f {
                case .badRequest: return .json(400, JSONValue.object(["error": .string(f.description)]))
                case .mintFailed: return .json(502, JSONValue.object(["error": .string(f.description)]))
                case .notFound: return .json(404, JSONValue.object(["error": .string(f.description)]))
                }
            } catch {
                return .json(500, JSONValue.object(["error": .string("\(error)")]))
            }
        case ("DELETE", false):
            let id = String(sub.dropFirst())   // strip "/"
            guard await attach.revokeIfPresent(id) else { return .json(404, JSONValue.object(["error": "no such grant"])) }
            return .init(status: 204)
        case ("GET", false):
            let id = String(sub.dropFirst())
            guard let g = await attach.get(id) else { return .json(404, JSONValue.object(["error": "no such grant"])) }
            return .json(200, g.json)
        default:
            return .text(405, "method not allowed\n")
        }
    }
}

// MARK: - Network.framework listener

/// Loopback HTTP/1.1 server driving an `MCPHTTPEndpoint`. One `NWConnection` per
/// client; keep-alive honoured; requests on a connection are processed serially.
public final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let endpoint: MCPHTTPEndpoint
    private let queue = DispatchQueue(label: "oab-computer.http", qos: .userInitiated)
    private let log: @Sendable (String) -> Void

    public init(host: String, port: UInt16, endpoint: MCPHTTPEndpoint, log: @escaping @Sendable (String) -> Void) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        self.listener = try NWListener(using: params)
        self.endpoint = endpoint
        self.log = log
    }

    public func start() {
        listener.stateUpdateHandler = { [log] state in
            switch state {
            case .ready: log("listening")
            case .failed(let e): log("listener failed: \(e)"); exit(2)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
    }

    private func accept(_ conn: NWConnection) {
        let isLoopback: Bool
        if case .hostPort(let host, _) = conn.endpoint {
            switch host {
            case .ipv4(let a): isLoopback = a == .loopback
            case .ipv6(let a): isLoopback = a == .loopback
            case .name(let n, _): isLoopback = n == "localhost"
            @unknown default: isLoopback = false
            }
        } else { isLoopback = false }

        conn.stateUpdateHandler = { [weak self] st in
            if case .ready = st { self?.readLoop(conn, buffer: Data(), isLoopback: isLoopback) }
            if case .failed = st { conn.cancel() }
        }
        conn.start(queue: queue)
    }

    private func readLoop(_ conn: NWConnection, buffer: Data, isLoopback: Bool) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil { conn.cancel(); return }

            switch HTTPParser.parse(buf) {
            case .incomplete:
                if isComplete { conn.cancel() } else { self.readLoop(conn, buffer: buf, isLoopback: isLoopback) }
            case .invalid(let why):
                let resp = HTTPResponse.text(400, why + "\n").serialize(keepAlive: false)
                conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
            case .request(let req, let consumed):
                let rest = Data(buf.dropFirst(consumed))
                let keepAlive = req.header("connection")?.lowercased() != "close"
                Task {
                    let resp = await self.endpoint.handle(req, remoteIsLoopback: isLoopback)
                    conn.send(content: resp.serialize(keepAlive: keepAlive), completion: .contentProcessed { _ in
                        if keepAlive && !isComplete {
                            self.readLoop(conn, buffer: rest, isLoopback: isLoopback)
                        } else {
                            conn.cancel()
                        }
                    })
                }
            }
        }
    }
}
