import Foundation
import XCTest
@testable import InstanceMCPCore

final class NetworkSectionTests: XCTestCase {
    private let tailURL = "https://<host>.<tailnet>.ts.net:8444/mcp"

    private func section(host: String = "127.0.0.1", port: Int = 8795, upstreams: [NetworkUpstream] = [],
                         tailnet: NetworkTailnetState = .off, switchboard: String? = "Switchboard: not configured",
                         grants: Int? = 0, attach: Bool = true) -> NetworkSection {
        MenuModel.networkSection(bindHost: host, bindPort: port, path: "/mcp", upstreams: upstreams, tailnet: tailnet,
                                 switchboardTitle: switchboard, liveGrants: grants, attachEnabled: attach)
    }
    private func text(_ s: NetworkSection, _ kind: NetworkRow.Kind) -> String? { s.rows.first { $0.kind == kind }?.text }
    private func upstream(_ name: String, _ url: String) -> NetworkUpstream { NetworkUpstream(name: name, url: URL(string: url)!) }

    func testHeader() { XCTAssertEqual(section().header, "Network") }

    func testLoopbackHostTable() {
        for h in ["127.0.0.1", "127.1.2.3", "::1", "[::1]", "localhost", "LocalHost"] { XCTAssertTrue(MenuModel.isLoopbackHost(h), h) }
        for h in ["0.0.0.0", "::", "192.168.0.5", "", "127.0.0", "127.0.0.1.5", "128.0.0.1", "example.com", "127.0.0.300"] {
            XCTAssertFalse(MenuModel.isLoopbackHost(h), h)
        }
    }

    func testLocalMCPLoopbackAndNot() {
        let local = section(host: "127.0.0.1", port: 9000)
        XCTAssertEqual(text(local, .localMCP), "Local MCP: http://127.0.0.1:9000/mcp (this Mac only)")
        XCTAssertEqual(local.rows[0].copyValue, "http://127.0.0.1:9000/mcp")
        let open = section(host: "0.0.0.0")
        XCTAssertEqual(text(open, .localMCP), "Local MCP: http://0.0.0.0:8795/mcp ⚠ (reachable from other devices)")
        XCTAssertEqual(open.rows[0].copyValue, "http://0.0.0.0:8795/mcp")
        XCTAssertEqual(text(section(host: "::1"), .localMCP), "Local MCP: http://[::1]:8795/mcp (this Mac only)")
        XCTAssertTrue(text(section(host: "::"), .localMCP)!.contains("reachable from other devices"))
        XCTAssertFalse(text(section(host: "192.168.0.5"), .localMCP)!.contains("this Mac only"))
    }

    func testEachTailnetState() {
        XCTAssertEqual(text(section(tailnet: .off), .tailnet), "Tailnet: Off")
        XCTAssertNil(section(tailnet: .off).rows[1].copyValue)
        let on = section(tailnet: .on(url: tailURL))
        XCTAssertEqual(text(on, .tailnet), "Tailnet: On, \(tailURL) (your tailnet only)")
        XCTAssertEqual(on.rows[1].copyValue, tailURL)
        let existing = section(tailnet: .onExisting(url: tailURL))
        XCTAssertEqual(text(existing, .tailnet), "Tailnet: On (existing mapping, not managed by this app), \(tailURL)")
        XCTAssertEqual(existing.rows[1].copyValue, tailURL)
        XCTAssertEqual(text(section(tailnet: .optedInNotApplied), .tailnet), "Tailnet: opted in, not applied (see the log)")
        XCTAssertEqual(text(section(tailnet: .unknown), .tailnet), "Tailnet: unknown (Tailscale status unreadable)")
        XCTAssertNil(section(tailnet: .unknown).rows[1].copyValue)
    }

    func testTailnetStateMapping() {
        func s(_ offered: Bool, _ url: String?, _ opted: Bool, _ existing: Bool, _ uncertain: Bool) -> NetworkTailnetState {
            MenuModel.networkTailnetState(offered: offered, publicURL: url, optedIn: opted, existingMapping: existing, uncertain: uncertain)
        }
        XCTAssertEqual(s(true, tailURL, false, false, false), .on(url: tailURL))
        XCTAssertEqual(s(true, tailURL, false, true, false), .onExisting(url: tailURL))
        XCTAssertEqual(s(true, tailURL, true, true, false), .on(url: tailURL))
        XCTAssertEqual(s(true, nil, true, false, false), .optedInNotApplied)
        XCTAssertEqual(s(false, nil, false, false, true), .unknown)
        XCTAssertEqual(s(true, nil, false, false, true), .off)
        XCTAssertEqual(s(true, nil, false, false, false), .off)
        XCTAssertEqual(s(false, nil, false, false, false), .off)
    }

    func testBrowserRow() {
        XCTAssertNil(text(section(), .browser))
        XCTAssertNil(text(section(upstreams: [upstream("other", "http://127.0.0.1:9/mcp")]), .browser))
        XCTAssertEqual(text(section(upstreams: [upstream("browser", "http://127.0.0.1:8794/mcp")]), .browser),
                       "Browser tools: 127.0.0.1:8794 (separate process, this Mac only)")
        XCTAssertEqual(text(section(upstreams: [upstream("browser", "http://example.com:8794/mcp")]), .browser),
                       "Browser tools: example.com:8794 (remote)")
        XCTAssertEqual(text(section(upstreams: [upstream("browser", "http://192.168.0.9:8794/mcp")]), .browser),
                       "Browser tools: 192.168.0.9:8794 (remote)")
    }

    func testReverseAttachRow() {
        XCTAssertEqual(text(section(grants: 0), .reverseAttach), "Reverse attach: 0 live grants")
        XCTAssertEqual(text(section(grants: 1), .reverseAttach), "Reverse attach: 1 live grant")
        XCTAssertEqual(text(section(grants: 3), .reverseAttach), "Reverse attach: 3 live grants")
        XCTAssertEqual(text(section(grants: nil), .reverseAttach), "Reverse attach: on")
        XCTAssertEqual(text(section(grants: 3, attach: false), .reverseAttach), "Reverse attach: off")
    }

    func testSwitchboardRowIsTheStatusTitle() {
        XCTAssertEqual(text(section(switchboard: "Switchboard: not configured"), .switchboard), "Switchboard: not configured")
        XCTAssertEqual(text(section(switchboard: "Switchboard: connected as desktop · this Mac m"), .switchboard),
                       "Switchboard: connected as desktop · this Mac m")
        XCTAssertNil(text(section(switchboard: nil), .switchboard))
    }

    func testNoDuplicatesAndNoOldLines() {
        let s = section(upstreams: [upstream("browser", "http://127.0.0.1:8794/mcp")], tailnet: .on(url: tailURL))
        XCTAssertEqual(Set(s.rows.map(\.kind)).count, s.rows.count)
        XCTAssertEqual(Set(s.rows.map(\.text)).count, s.rows.count)
        XCTAssertEqual(s.rows.map(\.kind), [.localMCP, .tailnet, .browser, .switchboard, .reverseAttach])
        XCTAssertFalse(s.rows.contains { $0.text.contains("Tailnet access:") })
    }

    func testNoTokenOrLoginInTheOutput() {
        let s = section(upstreams: [upstream("browser", "http://127.0.0.1:8794/mcp")], tailnet: .on(url: tailURL))
        for row in s.rows {
            for bad in ["Bearer", "Token", "token", "@"] {
                XCTAssertFalse(row.text.contains(bad), row.text)
                XCTAssertFalse((row.copyValue ?? "").contains(bad), row.text)
            }
        }
    }
}
