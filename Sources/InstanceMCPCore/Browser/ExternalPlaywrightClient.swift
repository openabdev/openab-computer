import Foundation

/// A failure from the external Playwright path. `errorClass` is one of the fixed strings of
/// R7.5.4 and never carries upstream-supplied text.
public struct ExternalPlaywrightError: Error, Equatable, Sendable, CustomStringConvertible {
    public let errorClass: String
    public var description: String { errorClass }
}

/// What the Playwright backend needs from a transport. Phase 1 has the external HTTP client;
/// the managed stdio client arrives next.
public protocol PlaywrightTransport: Sendable {
    func healthCheck() async throws
    func listTools() async throws -> [JSONValue]
    func callTool(_ name: String, arguments: JSONValue) async throws -> JSONValue
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

    public init(url: URL, timeout: TimeInterval = 90) {
        self.url = url
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: cfg, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    public func healthCheck() async throws { try await initialize() }

    public func listTools() async throws -> [JSONValue] {
        let r = try await rpc("tools/list", params: [:])
        return r["tools"]?.arrayValue ?? []
    }

    public func callTool(_ name: String, arguments: JSONValue) async throws -> JSONValue {
        try await rpc("tools/call", params: ["name": .string(name), "arguments": arguments])
    }

    // MARK: wire

    private func rpc(_ method: String, params: JSONValue) async throws -> JSONValue {
        if sessionID == nil { try await initialize() }
        var (status, body, _) = try await post(Self.message(method, params))
        if status == 400 || status == 404 {
            sessionID = nil
            try await initialize()
            (status, body, _) = try await post(Self.message(method, params))
        }
        try Self.check(status)
        return try Self.result(body)
    }

    private func initialize() async throws {
        let (status, body, headers) = try await post(Self.message("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [:],
            "clientInfo": ["name": "oab-computer", "version": "browser"],
        ], id: 0))
        try Self.check(status)
        _ = try Self.result(body)
        sessionID = headers.first { $0.key.lowercased() == "mcp-session-id" }?.value
        _ = try? await post(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    private static func message(_ method: String, _ params: JSONValue, id: Int = Int.random(in: 1...1_000_000)) -> JSONValue {
        ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
    }

    private func post(_ msg: JSONValue) async throws -> (Int, Data, [String: String]) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONCoding.encoder.encode(msg)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        // Bare host: Playwright MCP's allowed-hosts list compares the header verbatim.
        if let h = url.host { req.setValue(h, forHTTPHeaderField: "Host") }
        if let sid = sessionID { req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id") }
        do {
            let (data, resp) = try await session.data(for: req)
            let http = resp as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (k, v) in http?.allHeaderFields ?? [:] { if let k = k as? String, let v = v as? String { headers[k] = v } }
            return (http?.statusCode ?? 0, data, headers)
        } catch let e as URLError where e.code == .timedOut {
            throw ExternalPlaywrightError(errorClass: "upstream_timeout")
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
