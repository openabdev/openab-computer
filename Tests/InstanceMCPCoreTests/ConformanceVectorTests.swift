import Foundation
import XCTest
@testable import InstanceMCPCore

/// Shared conformance vectors in `conformance/` (repo root). The Swift
/// implementation is the behavioural oracle; the Linux Rust port
/// (`poc/reverse-attach-linux`) runs the same files in its `cargo test`, so a
/// change to either side that alters behaviour fails one of the two suites.
/// Edit a vector only when the behaviour change is intended on **both** sides.
/// Load `conformance/<name>` from the repo root as a JSON object.
func loadConformanceVector(_ name: String) throws -> [String: Any] {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // InstanceMCPCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
    let data = try Data(contentsOf: root.appendingPathComponent("conformance/\(name)"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

final class ConformanceVectorTests: XCTestCase {
    private func load(_ name: String) throws -> [String: Any] { try loadConformanceVector(name) }

    func testAuthPolicyVectors() throws {
        let doc = try load("auth_vectors.json")
        let cases = try XCTUnwrap(doc["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 16)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let config = c["config"] as? [String: Any] ?? [:]
            let policy = AuthPolicy(
                allowedLogins: Set(config["allowedLogins"] as? [String] ?? []),
                bearerToken: config["bearerToken"] as? String,
                allowLocalUnauthenticated: config["allowLocalUnauthenticated"] as? Bool ?? false)
            if c["validate"] as? String == "error" {
                XCTAssertThrowsError(try policy.validate(), name)
                continue
            }
            var headers: [String: String] = [:]
            for (k, v) in c["headers"] as? [String: String] ?? [:] { headers[k.lowercased()] = v }
            let got = policy.decide(headers: headers,
                                    remoteIsLoopback: c["remoteIsLoopback"] as? Bool ?? false)
            let expect = c["expect"] as? [String: String] ?? [:]
            if let principal = expect["allow"] {
                XCTAssertEqual(got, .allow(principal: principal), name)
            } else if let reason = expect["deny"] {
                XCTAssertEqual(got, .deny(reason: reason), name)
            } else {
                XCTFail("\(name): vector has no expect")
            }
        }
    }

    func testReverseAttachVectors() throws {
        let doc = try load("reverse_attach_vectors.json")
        let terminals: [String: ReverseAttachClient.Terminal] = [
            "grantExpired": .grantExpired, "replaced": .replaced,
            "sessionEnded": .sessionEnded, "revoked": .revoked,
        ]
        var n = 0
        for c in try XCTUnwrap(doc["close_code"] as? [[String: Any]]) {
            n += 1
            let code = try XCTUnwrap(c["code"] as? Int)
            let expect = c["expect"] as? [String: Any] ?? [:]
            let want: ReverseAttachClient.Disposition =
                (expect["stop"] as? String).map { .stop(terminals[$0]!) } ?? .redial
            XCTAssertEqual(ReverseAttachClient.disposition(closeCode: code), want, "close \(code)")
        }
        for c in try XCTUnwrap(doc["handshake_status"] as? [[String: Any]]) {
            n += 1
            let status = try XCTUnwrap(c["status"] as? Int)
            let expect = c["expect"] as? [String: Any] ?? [:]
            let want: ReverseAttachClient.Disposition =
                (expect["stop_rejected"] as? Int).map { .stop(.handshakeRejected($0)) } ?? .redial
            XCTAssertEqual(ReverseAttachClient.disposition(handshakeStatus: status), want,
                           "handshake \(status)")
        }
        for c in try XCTUnwrap(doc["attach_url"] as? [[String: String]]) {
            n += 1
            let config = ReverseAttachClient.Config(
                runtime: URL(string: c["runtime"]!)!, session: c["session"]!, secret: "x",
                profile: .observe, deadline: Date())
            XCTAssertEqual(config.attachURL.absoluteString, c["expect"])
        }
        XCTAssertGreaterThanOrEqual(n, 23)
    }

    /// `profile_vectors.json` (#59): names, default, mapping, rejection, persisted-grant
    /// resolution, membership and classes. The upstream half against a live fake is in
    /// `BrowserProfileTests`.
    func testProfileVectors() async throws {
        let doc = try load("profile_vectors.json")
        XCTAssertEqual(doc["profiles"] as? [String], ToolProfile.allCases.map(\.rawValue))
        XCTAssertEqual(doc["default_profile"] as? String, ToolProfile.defaultProfile.rawValue)
        XCTAssertEqual(doc["rejection_message"] as? String, ToolProfile.rejectionMessage)
        let retired = try XCTUnwrap(doc["retired_warning"] as? String)
        XCTAssertEqual(retired, ToolProfile.retiredWarning)

        // Classes and the served catalog.
        let served = ToolCatalog.local(agentVersion: "test").map(\.name)
        let local = try XCTUnwrap((doc["local_tools"] as? [String: [String]])?["macos"])
        XCTAssertEqual(Set(served), Set(local))
        XCTAssertEqual(served.count, local.count)
        let classes = try XCTUnwrap((doc["tool_class"] as? [String: [String: [String]]])?["macos"])
        var want: [String: ToolProfile.ToolClass] = [:]
        for (cls, tools) in classes {
            let c = try XCTUnwrap(ToolProfile.ToolClass(rawValue: cls), cls)
            for t in tools { want[t] = c }
        }
        XCTAssertEqual(ToolProfile.localToolClass, want)

        // Membership.
        let fixture = try XCTUnwrap(doc["upstream_fixture"] as? [String])
        let unlisted = try XCTUnwrap(doc["unlisted_upstream"] as? [String])
        XCTAssertEqual(fixture.count, 32)
        let servedSpec = try XCTUnwrap(doc["served"] as? [String: [String: Any]])
        XCTAssertEqual(Set(servedSpec.keys), Set(ToolProfile.allCases.map(\.rawValue)))
        for profile in ToolProfile.allCases {
            let spec = try XCTUnwrap(servedSpec[profile.rawValue])
            let wantLocal = spec["local"] as? String == "all" ? local : (spec["local"] as? [String] ?? [])
            XCTAssertEqual(Set(local.filter(profile.allows)), Set(wantLocal), profile.rawValue)
            let upstream = fixture + unlisted
            let wantUp = spec["upstream"] as? String == "all" ? upstream : (spec["upstream"] as? [String] ?? [])
            XCTAssertEqual(Set(upstream.filter(profile.allows)), Set(wantUp), profile.rawValue)
            XCTAssertEqual(profile.isShellEquivalent, spec["shell_equivalent"] as? Bool, profile.rawValue)
        }

        // Attach requests through the real endpoint.
        let cases = try XCTUnwrap(doc["attach_requests"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 14)
        for (i, c) in cases.enumerated() {
            let name = c["name"] as? String ?? "?"
            let mgr = AttachManager(server: fullServer())
            let ep = MCPHTTPEndpoint(server: fullServer(), auth: AuthPolicy(allowedLogins: ["a@b"]), attach: mgr)
            var body = c["body"] as? [String: Any] ?? [:]
            body["runtime"] = "ws://127.0.0.1:9"; body["session"] = "v\(i)"; body["secret"] = "s"
            let data = try JSONSerialization.data(withJSONObject: body)
            let r = await ep.handle(HTTPRequest(method: "POST", path: "/attach", query: nil,
                headers: ["content-type": "application/json", "tailscale-user-login": "a@b", "x-forwarded-for": "100.1.1.1"],
                body: data), remoteIsLoopback: true)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
            XCTAssertEqual(Int(r.status), expect["status"] as? Int, name)
            let got = decodeJSON(r.body)
            if expect["status"] as? Int == 400 {
                XCTAssertEqual(got["error"]?.stringValue, ToolProfile.rejectionMessage, name)
                continue
            }
            XCTAssertEqual(got["profile"]?.stringValue, expect["profile"] as? String, name)
            XCTAssertEqual(got["requested_profile"]?.stringValue, expect["requested_profile"] as? String, name)
            if expect["warning"] as? Bool == true {
                XCTAssertEqual(got["warning"]?.stringValue, retired, name)
            } else {
                XCTAssertNil(got["warning"], name)
            }
            if let id = got["id"]?.stringValue { await mgr.revoke(id) }
        }

        // Persisted rows.
        for c in try XCTUnwrap(doc["persisted_grants"] as? [[String: Any]]) {
            let name = c["name"] as? String ?? "?"
            let stored = try XCTUnwrap(c["stored"] as? [String: String], name)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
            let r = ToolProfile.resolve(stored: stored["profile"]!, requested: stored["requested_profile"])
            if expect["outcome"] as? String == "drop" {
                XCTAssertNil(r, name)
                continue
            }
            let got = try XCTUnwrap(r, name)
            XCTAssertEqual(got.profile.rawValue, expect["profile"] as? String, name)
            XCTAssertEqual(got.requested, expect["requested_profile"] as? String, name)
            XCTAssertEqual(got.warning, expect["warning"] as? Bool == true ? retired : nil, name)
        }
    }
}
