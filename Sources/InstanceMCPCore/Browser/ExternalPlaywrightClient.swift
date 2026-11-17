import Foundation

/// A failure from a Playwright transport, external or managed. `errorClass` is one of the fixed
/// strings (R7.5.4 for the external path) and never carries upstream-supplied text.
public struct PlaywrightTransportError: Error, Equatable, Sendable, CustomStringConvertible {
    public let errorClass: String
    public init(errorClass: String) { self.errorClass = errorClass }
    public var description: String { errorClass }
}
public typealias ExternalPlaywrightError = PlaywrightTransportError

/// What the Playwright backend needs from a transport. Phase 1 has the external HTTP client;
/// the managed stdio client arrives next.
public protocol PlaywrightTransport: Sendable {
    func healthCheck() async throws
    func listTools() async throws -> [JSONValue]
    func callTool(_ name: String, arguments: JSONValue) async throws -> JSONValue
    /// Stops anything the transport started. A no-op for an external listener.
    func shutdown() async
    /// True once a managed child failed too often and waits for Retry.
    var isLatched: Bool { get async }
}

extension PlaywrightTransport {
    public func shutdown() async {}
    public var isLatched: Bool { get async { false } }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)   // deliver the 3xx as the response; no second request
    }
}

/// Streamable-HTTP client for an operator-supplied loopback Playwright MCP (R7.5.3, R7.5.4).
/// Unlike `UpstreamMCP` it follows no redirects and turns every failure into a fixed class.
/// Successful tool results are returned verbatim.
public actor ExternalPlaywrightClient: PlaywrightTransport {
    public let url: URL
    private let session: URLSession
    private var sessionID: String?

    /// Health requests and the best-effort session DELETE (R2.1).
    public static let healthTimeout: TimeInterval = 2
    private let timeout: TimeInterval

    public init(url: URL, timeout: TimeInterval = 90) {
        self.url = url
        self.timeout = timeout
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: cfg, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    /// With a session: a `ping` (no new `initialize`, so the session id is not replaced). Without
    /// one, or when the upstream forgot it: one `initialize`. Always 2 s.
    public func healthCheck() async throws {
        guard sessionID != nil else { try await initialize(timeout: Self.healthTimeout); return }
        let (status, body, _) = try await post(Self.message("ping", [:]), timeout: Self.healthTimeout)
        if status == 400 || status == 404 {
            if status == 400 { await closeSession() } else { sessionID = nil }   // 404: already gone upstream
            try await initialize(timeout: Self.healthTimeout)
            return
        }
        try Self.check(status)
        _ = try Self.result(body)
    }

    public func listTools() async throws -> [JSONValue] {
        // The client timeout is the overall budget: one monotonic deadline covers initialize, a
        // session reset, the retry and every page. See ToolListPagination for the paging rules.
        try await ToolListPagination.collect(deadline: timeout) { params, deadline in
            try await self.rpc("tools/list", params: params, deadline: deadline)
        }
    }

    public func callTool(_ name: String, arguments: JSONValue) async throws -> JSONValue {
        try await rpc("tools/call", params: ["name": .string(name), "arguments": arguments])
    }

    // MARK: wire

    private func rpc(_ method: String, params: JSONValue, deadline: ContinuousClock.Instant? = nil) async throws -> JSONValue {
        if sessionID == nil { try await initialize(deadline: deadline) }
        var (status, body, _) = try await post(Self.message(method, params), deadline: deadline)
        if status == 400 || status == 404 {
            if status == 400 { await closeSession(deadline: deadline) } else { sessionID = nil }   // 404: already gone upstream
            try await initialize(deadline: deadline)
            (status, body, _) = try await post(Self.message(method, params), deadline: deadline)
        }
        try Self.check(status)
        return try Self.result(body)
    }

    private func initialize(timeout: TimeInterval? = nil, deadline: ContinuousClock.Instant? = nil) async throws {
        if sessionID != nil { await closeSession(deadline: deadline) }
        let (status, body, headers) = try await post(Self.message("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [:],
            "clientInfo": ["name": "oab-computer", "version": "browser"],
        ], id: 0), timeout: timeout, deadline: deadline)
        try Self.check(status)
        _ = try Self.result(body)
        sessionID = headers.first { $0.key.lowercased() == "mcp-session-id" }?.value
        _ = try? await post(["jsonrpc": "2.0", "method": "notifications/initialized"], timeout: timeout, deadline: deadline)
    }

    /// Best-effort `DELETE` of the current session; errors are ignored and the id is cleared.
    /// Inside a deadline it gets at most the time left and is skipped when none is.
    private func closeSession(deadline: ContinuousClock.Instant? = nil) async {
        guard let sid = sessionID else { return }
        sessionID = nil
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.timeoutInterval = Self.healthTimeout
        if let deadline {
            let left = ToolListPagination.remaining(until: deadline)
            guard left > 0 else { return }
            req.timeoutInterval = min(Self.healthTimeout, left)
        }
        req.setValue(hostHeader, forHTTPHeaderField: "Host")
        req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        _ = try? await fetch(req, deadline: deadline)
    }

    var hostHeaderForTests: String { hostHeader }

    /// No port, the same as the IPv4 form has always sent; the allowed-hosts list compares verbatim.
    private var hostHeader: String {
        let h = url.host ?? ""
        return h.contains(":") ? "[\(h)]" : h
    }

    private static func message(_ method: String, _ params: JSONValue, id: Int = Int.random(in: 1...1_000_000)) -> JSONValue {
        ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
    }

    /// `session.data(for:)`, and inside a deadline also raced against it, because the URLSession
    /// timeout is an idle timeout and a server that trickles bytes would otherwise outlive it.
    private func fetch(_ req: URLRequest, deadline: ContinuousClock.Instant?) async throws -> (Data, URLResponse) {
        guard let deadline else { return try await session.data(for: req) }
        let session = self.session
        return try await withThrowingTaskGroup(of: (Data, URLResponse)?.self) { group in
            group.addTask { try await session.data(for: req) }
            group.addTask { try await Task.sleep(until: deadline, clock: ContinuousClock()); return nil }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.timedOut) }
            guard let done = first else { throw ExternalPlaywrightError(errorClass: ToolListPagination.budgetExhausted) }
            return done
        }
    }

    private func post(_ msg: JSONValue, timeout: TimeInterval? = nil,
                      deadline: ContinuousClock.Instant? = nil) async throws -> (Int, Data, [String: String]) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONCoding.encoder.encode(msg)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        var requestTimeout = timeout ?? self.timeout
        var budgetBound = false   // the deadline, not the per-request timeout, is what limits this request
        if let deadline {
            let left = ToolListPagination.remaining(until: deadline)
            guard left > 0 else { throw ExternalPlaywrightError(errorClass: ToolListPagination.budgetExhausted) }
            if left <= requestTimeout { requestTimeout = left; budgetBound = true }
        }
        req.timeoutInterval = requestTimeout
        req.setValue(hostHeader, forHTTPHeaderField: "Host")
        if let sid = sessionID { req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id") }
        do {
            let (data, resp) = try await fetch(req, deadline: deadline)
            let http = resp as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (k, v) in http?.allHeaderFields ?? [:] { if let k = k as? String, let v = v as? String { headers[k] = v } }
            return (http?.statusCode ?? 0, data, headers)
        } catch let e as ExternalPlaywrightError {
            throw e
        } catch let e as URLError where e.code == .timedOut {
            throw ExternalPlaywrightError(errorClass: budgetBound ? ToolListPagination.budgetExhausted : "upstream_timeout")
        } catch {
            throw ExternalPlaywrightError(errorClass: "upstream_unreachable")
        }
    }

    private static func check(_ status: Int) throws {
        if (200..<300).contains(status) { return }
        if (300..<400).contains(status) { throw ExternalPlaywrightError(errorClass: "upstream_redirect") }
        throw ExternalPlaywrightError(errorClass: "upstream_http_\(status)")
    }

    /// The JSON-RPC `result`; a JSON-RPC `error` or an unreadable body becomes a fixed class.
    private static func result(_ data: Data) throws -> JSONValue {
        var parsed = try? JSONCoding.decoder.decode(JSONValue.self, from: data)
        if parsed == nil {
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("data:") {
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if let v = try? JSONCoding.decoder.decode(JSONValue.self, from: Data(payload.utf8)) { parsed = v; break }
            }
        }
        guard let v = parsed, v.objectValue != nil else { throw ExternalPlaywrightError(errorClass: "upstream_bad_body") }
        if v["error"] != nil { throw ExternalPlaywrightError(errorClass: "upstream_rpc_error") }
        return v["result"] ?? .null
    }
}
