import Foundation
import XCTest
@testable import InstanceMCPCore

final class BrowserReportingTests: XCTestCase {
    private func report(state: String, cls: String?, mode: String = "managed", owner: String? = nil) -> BrowserReport {
        BrowserReport(preference: .auto, active: state == "ready" ? .playwright : nil,
                      backends: [.init(id: .playwright, state: state, errorClass: cls, mode: mode, ownerSummary: owner)])
    }
    private func section(upstreams: [NetworkUpstream] = [], browser: NetworkBrowser?) -> NetworkSection {
        MenuModel.networkSection(bindHost: "127.0.0.1", bindPort: 8795, path: "/mcp", upstreams: upstreams, tailnet: .off,
                                 switchboard: nil, liveGrants: 0, attachEnabled: true, browser: browser)
    }
    private func row(_ s: NetworkSection) -> String? { s.rows.first { $0.kind == .browser }?.text }

    func testSysInfoReportsManagedNotInstalled() async throws {
        let tool = SysInfoTool(agentVersion: "t", browser: { self.report(state: "needs_setup", cls: "playwright_not_installed") })
        let r = try await tool.call(arguments: [:])
        let b = try XCTUnwrap(r.structured?["browser"])
        XCTAssertEqual(b["backends"]?.arrayValue?.first?["state"]?.stringValue, "needs_setup")
        XCTAssertEqual(b["backends"]?.arrayValue?.first?["mode"]?.stringValue, "managed")
        XCTAssertEqual(b["backends"]?.arrayValue?.first?["class"]?.stringValue, "playwright_not_installed")
        let text = r.content.compactMap { c -> String? in if case .text(let t) = c { return t }; return nil }.joined()
        XCTAssertTrue(text.contains("browser tools: playwright not installed"), text)
        XCTAssertFalse(String(decoding: jsonBody(b), as: UTF8.self).contains("http"))
    }

    func testSysInfoWithoutARouterHasNoBrowserBlock() async throws {
        let r = try await SysInfoTool(agentVersion: "t").call(arguments: [:])
        XCTAssertNil(r.structured?["browser"])
    }

    func testMenuRowWording() {
        XCTAssertEqual(row(section(browser: NetworkBrowser(report: report(state: "ready", cls: nil)))), "Browser tools: Playwright ready")
        XCTAssertEqual(row(section(browser: NetworkBrowser(report: report(state: "needs_setup", cls: "playwright_not_installed")))),
                       "Browser tools: Playwright not installed")
        XCTAssertEqual(row(section(browser: NetworkBrowser(report: report(state: "unavailable", cls: "playwright_unavailable")))),
                       "Browser tools: Playwright unavailable (playwright_unavailable)")
        XCTAssertNil(row(section(browser: nil)), "no row until a report is known")
    }

    func testExternalRowKeepsTheAddressAndAppendsTheOwner() {
        let up = [NetworkUpstream(name: "browser", url: URL(string: "http://127.0.0.1:8794/mcp")!)]
        let plain = row(section(upstreams: up, browser: nil))
        XCTAssertEqual(plain, "Browser tools: 127.0.0.1:8794 (separate process, this Mac only)")
        let withOwner = row(section(upstreams: up, browser: NetworkBrowser(report: report(state: "ready", cls: nil, mode: "external", owner: "node (uid 501)"))))
        XCTAssertEqual(withOwner, plain! + " · Playwright external (node (uid 501))")
        let noOwner = row(section(upstreams: up, browser: NetworkBrowser(report: report(state: "unavailable", cls: "x", mode: "external"))))
        XCTAssertEqual(noOwner, plain)
    }
}
