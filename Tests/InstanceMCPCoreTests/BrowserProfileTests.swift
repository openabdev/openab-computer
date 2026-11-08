import Foundation
import XCTest
@testable import InstanceMCPCore

/// #59: the browser is owner-level. Against an upstream that serves the full
/// `browser_*` fixture from `conformance/profile_vectors.json` (plus tools that are
/// not in it), `owner` lists and reaches every one through the real `tools/list` /
/// `tools/call` path, and `observe` lists none and reaches none.
final class BrowserProfileTests: XCTestCase {
    private func fixture() throws -> (listed: [String], unlisted: [String]) {
        let doc = try loadConformanceVector("profile_vectors.json")
        return (try XCTUnwrap(doc["upstream_fixture"] as? [String]),
                try XCTUnwrap(doc["unlisted_upstream"] as? [String]))
    }

    private func server(_ up: FakeUpstream, _ profile: ToolProfile) -> MCPServer {
        let u = UpstreamMCP(name: "browser", url: URL(string: "http://127.0.0.1:\(up.port)/mcp")!)
        return MCPServer(name: "t", version: "0", tools: ToolCatalog.local(agentVersion: "test"), upstreams: [u])
            .scoped(to: profile)
    }

    private func list(_ s: MCPServer) async throws -> [String] {
        let r = await s.handle(try JSONCoding.decoder.decode(JSONRPCRequest.self, from: rpc("tools/list")))
        return r?.result?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    }

    private func call(_ s: MCPServer, _ name: String) async throws -> JSONRPCResponse? {
        await s.handle(try JSONCoding.decoder.decode(JSONRPCRequest.self,
            from: rpc("tools/call", params: ["name": .string(name), "arguments": [:]])))
    }

    func testOwnerListsAndReachesEveryUpstreamTool() async throws {
        let (listed, unlisted) = try fixture()
        let up = try FakeUpstream(toolNames: listed + unlisted); defer { up.stop() }
        let s = server(up, .owner)
        let names = try await list(s)
        let missing = Set(listed + unlisted).subtracting(names)
        XCTAssertTrue(missing.isEmpty, "owner skips \(missing.sorted())")
        for local in ToolCatalog.local(agentVersion: "test").map(\.name) {
            XCTAssertTrue(names.contains(local), "owner hides local \(local)")
        }
        for tool in ["browser_run_code_unsafe", "browser_evaluate", "browser_something_new"] {
            let r = try await call(s, tool)
            XCTAssertNil(r?.error, "\(tool): \(String(describing: r?.error))")
            XCTAssertEqual(up.calls.last?["name"]?.stringValue, tool, "owner's call reached the upstream")
        }
    }

    func testObserveListsAndReachesNoUpstreamTool() async throws {
        let (listed, unlisted) = try fixture()
        let up = try FakeUpstream(toolNames: listed + unlisted); defer { up.stop() }
        let s = server(up, .observe)
        let names = try await list(s)
        XCTAssertEqual(Set(names), ["sys_info", "screenshot"])
        for tool in listed + unlisted {
            let r = try await call(s, tool)
            XCTAssertEqual(r?.error?.code, JSONRPCError.invalidParams, tool)
            XCTAssertTrue(r?.error?.message.contains("unknown tool") == true, tool)
        }
        XCTAssertTrue(up.calls.isEmpty, "no observe call reached the upstream: \(up.calls)")
    }
}
