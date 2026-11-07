import Foundation
import XCTest
@testable import InstanceMCPCore

/// Runs `conformance/mcp_http_vectors.json` through `MCPHTTPEndpoint.handle`.
/// The Swift endpoint is the oracle, so every `expect` must hold here. The Rust
/// runner (`poc/reverse-attach-linux/src/http_conformance.rs`) reads the same
/// file and calls `http::mcp_route`, the Rust `/mcp` handler after auth.
final class HTTPConformanceTests: XCTestCase {
    private func load() throws -> JSONValue {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // InstanceMCPCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let data = try Data(contentsOf: root.appendingPathComponent("conformance/mcp_http_vectors.json"))
        return try JSONCoding.decoder.decode(JSONValue.self, from: data)
    }

    /// Subset match, same rules as the Rust runner. Unknown keys fail.
    static func matches(_ r: HTTPResponse, _ want: JSONValue) -> Bool {
        guard let w = want.objectValue else { return false }
        let body = try? JSONCoding.decoder.decode(JSONValue.self, from: r.body)
        let sessionHeader = r.headers.contains { $0.0.lowercased() == "mcp-session-id" }
        for (key, value) in w {
            switch key {
            case "status":
                if value.intValue != r.status { return false }
            case "session_header":
                if value.boolValue != sessionHeader { return false }
            case "error":
                if body?["error"]?["code"] != value { return false }
            case "result":
                if value.boolValue != (body?["result"] != nil) { return false }
            case "body_empty":
                if value.boolValue != r.body.isEmpty { return false }
            default:
                return false
            }
        }
        return true
    }

    func testEveryHTTPCaseMatchesTheSwiftOracle() async throws {
        let doc = try load()
        let cases = try XCTUnwrap(doc["cases"]?.arrayValue)
        XCTAssertGreaterThanOrEqual(cases.count, 18)
        for c in cases {
            let name = c["name"]?.stringValue ?? "?"
            // A fresh endpoint per case: sessions carry between steps, never between cases.
            let ep = MCPHTTPEndpoint(server: MCPServer(name: "t", version: "0", tools: [EchoTool()]),
                                     auth: AuthPolicy(allowedLogins: ["a@b"]))
            var issued: String?
            for (i, step) in try XCTUnwrap(c["steps"]?.arrayValue, name).enumerated() {
                var headers = ["tailscale-user-login": "a@b", "x-forwarded-for": "100.1.1.1"]
                if let ct = step["content_type"]?.stringValue { headers["content-type"] = ct }
                switch step["session"]?.stringValue {
                case "$issued"?: if let s = issued { headers["mcp-session-id"] = s }
                case let s?: headers["mcp-session-id"] = s
                case nil: break
                }
                let req = HTTPRequest(method: try XCTUnwrap(step["method"]?.stringValue, name), path: "/mcp",
                                      query: nil, headers: headers,
                                      body: Data((step["body"]?.stringValue ?? "").utf8))
                let r = await ep.handle(req, remoteIsLoopback: true)
                if let sid = r.headers.first(where: { $0.0.lowercased() == "mcp-session-id" })?.1 { issued = sid }
                let expect = try XCTUnwrap(step["expect"], name)
                XCTAssertTrue(Self.matches(r, expect),
                              "\(name) step \(i): got \(r.status) \(String(decoding: r.body, as: UTF8.self)), want \(expect)")
            }
        }
    }
}
