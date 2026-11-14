import Foundation
import XCTest
@testable import InstanceMCPCore

final class NetworkSectionTests: XCTestCase {
    private let tailURL = "https://<host>.<tailnet>.ts.net:8444/mcp"

    private func section(host: String = "127.0.0.1", port: Int = 8795, upstreams: [NetworkUpstream] = [],
                         tailnet: NetworkTailnetState = .off, switchboard: String? = "notConfigured",
                         grants: Int? = 0, attach: Bool = true) -> NetworkSection {
        MenuModel.networkSection(bindHost: host, bindPort: port, path: "/mcp", upstreams: upstreams, tailnet: tailnet,
                                 switchboard: sb(switchboard), liveGrants: grants, attachEnabled: attach)
    }
    private func sb(_ kind: String?) -> NetworkSwitchboard? {
        guard let kind else { return nil }
        if kind == "starting" { return NetworkSwitchboard(status: nil) { _ in "t" } }
        let state: ReverseAttachClient.State? = kind == "connected" ? .attached : nil
        let status = SwitchboardStatus.make(state: state, lastClose: nil, configured: kind == "connected",
                                            profile: .observe, computer: "m")
        return NetworkSwitchboard(status: status) { _ in "t" }
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
        XCTAssertEqual(text(section(tailnet: .notChecked), .tailnet), "Tailnet: unknown (not checked by this app)")
        XCTAssertNil(section(tailnet: .unknown).rows[1].copyValue)
    }

    func testTailnetStateMapping() {
        func s(_ offered: Bool, _ url: String?, _ opted: Bool, _ existing: Bool, _ uncertain: Bool) -> NetworkTailnetState {
            MenuModel.networkTailnetState(publicURL: url, optedIn: opted, existingMapping: existing, uncertain: uncertain)
        }
        XCTAssertEqual(s(true, tailURL, false, false, false), .on(url: tailURL))
        XCTAssertEqual(s(true, tailURL, false, true, false), .onExisting(url: tailURL))
        XCTAssertEqual(s(true, tailURL, true, true, false), .on(url: tailURL))
        XCTAssertEqual(s(true, nil, true, false, false), .optedInNotApplied)
        XCTAssertEqual(s(false, nil, false, false, true), .unknown)
        XCTAssertEqual(s(true, nil, false, false, true), .unknown)
        XCTAssertEqual(s(true, nil, false, false, false), .off)
        XCTAssertEqual(s(false, nil, false, false, false), .off)
    }

    func testUnreadableLoginWithAllowListIsUnknown() {
        let uncertain = MenuModel.tailnetStatusUnreadable(offered: false, tokenOnly: false)
        XCTAssertTrue(uncertain)
        XCTAssertFalse(MenuModel.tailnetStatusUnreadable(offered: false, tokenOnly: true))
        XCTAssertFalse(MenuModel.tailnetStatusUnreadable(offered: true, tokenOnly: false))
        XCTAssertEqual(MenuModel.networkTailnetState(publicURL: nil, optedIn: false, existingMapping: false, uncertain: uncertain), .unknown)
    }

    func testGenericPublicURLIsNotATailnetMapping() {
        let local = "http://127.0.0.1:8795/mcp"
        let generic = "https://example.com/mcp"
        XCTAssertNil(MenuModel.configuredPublicURL(publicURL: local, localURL: local))
        XCTAssertEqual(MenuModel.configuredPublicURL(publicURL: generic, localURL: local), generic)
        XCTAssertEqual(MenuModel.tailnetStateWithoutExposure(publicURL: generic), .notChecked)
        let s = MenuModel.networkSection(bindHost: "127.0.0.1", bindPort: 8795, path: "/mcp", upstreams: [],
                                         tailnet: MenuModel.tailnetStateWithoutExposure(publicURL: generic),
                                         switchboard: nil, liveGrants: 0, attachEnabled: true, publicURL: generic)
        XCTAssertEqual(text(s, .publicURL), "Public URL: https://example.com/mcp (as configured with --public-url, not checked)")
        XCTAssertEqual(text(s, .tailnet), "Tailnet: unknown (not checked by this app)")
        XCTAssertFalse(s.rows.contains { $0.text.contains("existing mapping") })
        XCTAssertFalse(s.rows.contains { $0.text.contains("Bearer") || $0.text.lowercased().contains("token") })
    }

    func testTailnetLookingPublicURLWithoutServeStateDoesNotClaimOn() {
        XCTAssertEqual(MenuModel.tailnetStateWithoutExposure(publicURL: "https://h.t.ts.net:9443/mcp"), .notChecked)
        XCTAssertEqual(MenuModel.tailnetStateWithoutExposure(publicURL: "https://evil.ts.net.example.com/mcp"), .notChecked)
        XCTAssertEqual(MenuModel.tailnetStateWithoutExposure(publicURL: nil), .notChecked)
    }

    func testConfirmingServeStateClaimsOn() {
        XCTAssertEqual(MenuModel.networkTailnetState(publicURL: tailURL, optedIn: false, existingMapping: false, uncertain: false),
                       .on(url: tailURL))
        XCTAssertEqual(MenuModel.networkTailnetState(publicURL: nil, optedIn: false, existingMapping: false, uncertain: true), .unknown)
    }

    func testCheckingStateNeverShowsADefiniteValue() {
        XCTAssertEqual(text(section(tailnet: .checking), .tailnet), "Tailnet: checking…")
        XCTAssertNil(section(tailnet: .checking).rows[1].copyValue)
        // Whatever else is known, a pending first read wins.
        for (url, opted, existing, unc) in [(nil, false, false, false), (tailURL, false, false, false), (tailURL, false, true, false),
                                            (nil, true, false, false), (nil, false, false, true)] as [(String?, Bool, Bool, Bool)] {
            XCTAssertEqual(MenuModel.networkTailnetState(publicURL: url, optedIn: opted, existingMapping: existing,
                                                         uncertain: unc, checking: true), .checking)
        }
    }

    func testTransitionFromCheckingToEachDefiniteState() {
        func state(_ url: String?, opted: Bool = false, existing: Bool = false, unc: Bool = false) -> NetworkTailnetState {
            MenuModel.networkTailnetState(publicURL: url, optedIn: opted, existingMapping: existing, uncertain: unc, checking: false)
        }
        XCTAssertEqual(state(nil), .off)
        XCTAssertEqual(state(tailURL), .on(url: tailURL))
        XCTAssertEqual(state(tailURL, existing: true), .onExisting(url: tailURL))
        XCTAssertEqual(state(nil, opted: true), .optedInNotApplied)
        XCTAssertEqual(state(nil, unc: true), .unknown)   // an unreadable or foreign-only read is never Off by guess
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
        XCTAssertEqual(text(section(switchboard: "notConfigured"), .switchboard), "Switchboard: not configured")
        XCTAssertEqual(text(section(switchboard: "connected"), .switchboard),
                       "Switchboard: connected as observe · this Mac m")
        XCTAssertEqual(text(section(switchboard: "starting"), .switchboard), "Switchboard: starting…")
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
