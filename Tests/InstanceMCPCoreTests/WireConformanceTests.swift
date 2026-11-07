import Foundation
import XCTest
@testable import InstanceMCPCore

/// Runs `conformance/mcp_wire_vectors.json` through `MCPServer.parse` and
/// `MCPServer.handle`. The Swift server is the oracle, so every `expect` must
/// hold here. The Rust runner (`poc/reverse-attach-linux/src/wire_conformance.rs`)
/// reads the same file and pins its own drift through `known_drift`.
final class WireConformanceTests: XCTestCase {
    private func load() throws -> JSONValue {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // InstanceMCPCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let data = try Data(contentsOf: root.appendingPathComponent("conformance/mcp_wire_vectors.json"))
        return try JSONCoding.decoder.decode(JSONValue.self, from: data)
    }

    /// What a client sees for one raw request, in the vocabulary `expect` uses.
    private func observe(_ server: MCPServer, _ raw: String) async -> JSONValue {
        let response: JSONRPCResponse?
        switch MCPServer.parse(Data(raw.utf8)) {
        case .failure(let e):
            response = JSONRPCResponse(id: .null, error: e)
        case .success(let req):
            response = await server.handle(req)
        }
        guard let r = response else { return .object(["response": .bool(false)]) }
        var o: [String: JSONValue] = ["response": .bool(true)]
        if let e = r.error { o["error"] = .number(Double(e.code)) }
        if let result = r.result { o["result"] = result }
        return .object(o)
    }

    /// Subset match: every key in `want` must hold in `obs`. Unknown keys fail,
    /// so a typo in the fixture cannot pass silently.
    static func matches(_ obs: JSONValue, _ want: JSONValue) -> Bool {
        guard let w = want.objectValue else { return false }
        for (key, value) in w {
            switch key {
            case "response", "error":
                if obs[key] != value { return false }
            case "result_subset":
                guard let sub = value.objectValue, let res = obs["result"]?.objectValue else { return false }
                for (k, v) in sub where res[k] != v { return false }
            case "result_tools_shape":
                guard let tools = obs["result"]?["tools"]?.arrayValue, !tools.isEmpty else { return false }
                let ok = tools.allSatisfy {
                    $0["name"]?.stringValue != nil && $0["description"]?.stringValue != nil
                        && $0["inputSchema"]?.objectValue != nil
                }
                if !ok { return false }
            default:
                return false
            }
        }
        return true
    }

    func testEveryWireCaseMatchesTheSwiftOracle() async throws {
        let doc = try load()
        let cases = try XCTUnwrap(doc["cases"]?.arrayValue)
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        // A `bash` tool exists so a profile-hidden case is refused by `scoped(to:)`,
        // not because the tool is absent: unscoped, the call would succeed.
        let base = MCPServer(name: "t", version: "0", tools: [EchoTool(), ShellStub()])
        for c in cases {
            let name = c["name"]?.stringValue ?? "?"
            let request = try XCTUnwrap(c["request"]?.stringValue, name)
            let expect = try XCTUnwrap(c["expect"], name)
            var server = base
            if let p = c["profile"]?.stringValue {
                server = base.scoped(to: try XCTUnwrap(ToolProfile(rawValue: p), "\(name): profile \(p)"))
            }
            let got = await observe(server, request)
            XCTAssertTrue(Self.matches(got, expect), "\(name): got \(got), want \(expect)")
        }
    }
}

/// Stands in for a shell-capable tool, so the `observe` vector exercises `scoped(to:)`.
private struct ShellStub: Tool {
    let name = "bash"
    let description = "stub"
    let inputSchema: JSONValue = ["type": "object"]
    func call(arguments: JSONValue) async throws -> ToolResult { .text("ran") }
}
