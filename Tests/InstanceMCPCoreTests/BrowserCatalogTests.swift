import Foundation
import XCTest
@testable import InstanceMCPCore

final class BrowserToolCatalogTests: XCTestCase {
    func testThirtyTwoNamesMatchTheVectorFile() throws {
        let doc = try loadConformanceVector("profile_vectors.json")
        let fixture = try XCTUnwrap(doc["upstream_fixture"] as? [String])
        XCTAssertEqual(BrowserToolCatalog.allNames.count, 32)
        XCTAssertEqual(Set(BrowserToolCatalog.allNames).count, 32)
        XCTAssertEqual(Set(BrowserToolCatalog.allNames), Set(fixture))
        let unlisted = try XCTUnwrap(doc["unlisted_upstream"] as? [String])
        XCTAssertTrue(unlisted.contains("browser_something_new"))
        XCTAssertFalse(BrowserToolCatalog.allNameSet.contains("browser_something_new"))
    }

    func testTierASplitIsSixTenSixteen() {
        let counts = Dictionary(grouping: BrowserToolCatalog.tierA, by: \.support).mapValues(\.count)
        XCTAssertEqual(counts[.full], 6)
        XCTAssertEqual(counts[.limited], 10)
        XCTAssertEqual(counts[.no], 16)
        XCTAssertEqual(BrowserToolCatalog.tierASupport("browser_close"), .full)
        XCTAssertEqual(BrowserToolCatalog.tierASupport("browser_drag"), .no)
    }

    func testObserveAllowsNoBrowserTool() {
        for n in BrowserToolCatalog.allNames + ["browser_something_new"] {
            XCTAssertTrue(ToolProfile.owner.allows(n), n)
            XCTAssertFalse(ToolProfile.observe.allows(n), n)
        }
    }
}

final class BrowserUpstreamURLTests: XCTestCase {
    func testOnlyLiteralLoopbackIsAccepted() throws {
        XCTAssertNoThrow(try BrowserUpstreamURL.validate(URL(string: "http://127.0.0.1:8794/mcp")!))
        XCTAssertNoThrow(try BrowserUpstreamURL.validate(URL(string: "http://[::1]:8794/mcp")!))
        for bad in ["http://localhost:8794/mcp", "http://example.com:8794/mcp", "http://0.0.0.0:8794/mcp",
                    "http://192.168.0.5:8794/mcp", "https://127.0.0.1:8794/mcp"] {
            XCTAssertThrowsError(try BrowserUpstreamURL.validate(URL(string: bad)!), bad)
        }
    }
}

final class BrowserNoTailscaleTests: XCTestCase {
    func testNoFileUnderBrowserMentionsTailscale() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/InstanceMCPCore/Browser")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty)
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8).lowercased()
            XCTAssertFalse(text.contains("tailscale"), f.lastPathComponent)
        }
    }
}
