import Foundation
import XCTest
@testable import InstanceMCPCore

/// Schema 2 added the Linux platforms (ADR linux-browser-tier D1). macOS must install exactly what
/// schema 1 pinned, so these literals are the schema 1 values, copied before the migration.
final class MacOSPinsUnchangedTests: XCTestCase {
    private struct Golden {
        let label: String
        let platform: PlatformID
        let url: String
        let format: String
        let size: Int64
        let sha256: String
        let strip: Int
        let expanded: Int64
        let entries: Int
        let maxEntry: Int64
        let executable: String?

        init(_ label: String, _ platform: PlatformID, _ url: String, _ format: String, _ size: Int64, _ sha256: String,
             _ strip: Int, _ expanded: Int64, _ entries: Int, _ maxEntry: Int64, _ executable: String?) {
            self.label = label; self.platform = platform; self.url = url; self.format = format; self.size = size
            self.sha256 = sha256; self.strip = strip; self.expanded = expanded; self.entries = entries
            self.maxEntry = maxEntry; self.executable = executable
        }
    }

    private let golden: [Golden] = [
            Golden("node", .darwinArm64, "https://nodejs.org/dist/v24.22.3/node-v24.22.3-darwin-arm64.tar.gz",
                   "tar.gz", 53084299,
                   "ff6e17d4874b76d272212b908cc020d6e815fba5a6c7eaaa06add725840307fd", 1, 197472599, 5888, 122586000, nil),
            Golden("node", .darwinX64, "https://nodejs.org/dist/v24.22.3/node-v24.22.3-darwin-x64.tar.gz",
                   "tar.gz", 54395976,
                   "977614af0504c81045e7fd85596dbca0e5f951b96681516dadafedcca8c447f7", 1, 200641924, 5888, 125755312, nil),
            Golden("chromium", .darwinArm64, "https://storage.googleapis.com/chrome-for-testing-public/154.0.8037.0/mac-arm64/chrome-mac-arm64.zip",
                   "zip", 191396177,
                   "087abf7d9405bde17889b4ccbe7d12f4a4d12a0164cc087fedd3bfe46817baa7", 0, 376747548, 673, 247230480, "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"),
            Golden("chromium", .darwinX64, "https://storage.googleapis.com/chrome-for-testing-public/154.0.8037.0/mac-x64/chrome-mac-x64.zip",
                   "zip", 201605834,
                   "9187f275918cdfdeeed6e41b9b90e8f54d3eee9e9d08b74d975a89c633d68876", 0, 387158652, 673, 267098208, "chrome-mac-x64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"),
    ]

    func testEveryMacOSArtifactEqualsItsSchema1Value() throws {
        let m = PlaywrightManifest.embedded
        XCTAssertEqual(golden.count, 4)
        for g in golden {
            let a = try XCTUnwrap(g.label == "node" ? m.nodeArtifact(platform: g.platform) : m.chromiumArtifact(platform: g.platform),
                                  "\(g.label)/\(g.platform.rawValue)")
            XCTAssertEqual(a.url, g.url)
            XCTAssertEqual(a.format, g.format)
            XCTAssertEqual(a.size, g.size)
            XCTAssertEqual(a.sha256, g.sha256)
            XCTAssertEqual(a.stripComponents, g.strip)
            XCTAssertEqual(a.expandedBytes, g.expanded)
            XCTAssertEqual(a.entryCount, g.entries)
            XCTAssertEqual(a.maxEntryBytes, g.maxEntry)
            XCTAssertEqual(a.executable, g.executable)
            XCTAssertNil(a.minGlibc); XCTAssertNil(a.needed); XCTAssertNil(a.packageHints)
        }
    }

    func testTheArchLookupsReturnTheDarwinPins() throws {
        let m = PlaywrightManifest.embedded
        XCTAssertEqual(m.nodeArtifact(.arm64), m.nodeArtifact(platform: .darwinArm64))
        XCTAssertEqual(m.nodeArtifact(.x86_64), m.nodeArtifact(platform: .darwinX64))
        XCTAssertEqual(m.chromiumArtifact(.arm64), m.chromiumArtifact(platform: .darwinArm64))
        XCTAssertEqual(m.chromiumArtifact(.x86_64), m.chromiumArtifact(platform: .darwinX64))
        XCTAssertEqual(Arch.arm64.platformID, .darwinArm64)
        XCTAssertEqual(Arch.x86_64.platformID, .darwinX64)
    }

    func testSharedFieldsAndTheInstallIdentityEqualSchema1() {
        let m = PlaywrightManifest.embedded
        XCTAssertEqual(m.id, "mcp0.0.82-node24.22.3-cr1246-ae3053ed")
        XCTAssertEqual(m.mcp.package, "@playwright/mcp")
        XCTAssertEqual(m.mcp.version, "0.0.82")
        XCTAssertEqual(m.mcp.playwrightCoreVersion, "1.64.0-alpha-1789764292000")
        XCTAssertEqual(m.mcp.packageJsonSHA256, "6925aed01f4b8468eaec160083d616a33b47141bb9836c8f1bfb81086eb8b13c")
        XCTAssertEqual(m.mcp.lockfileSHA256, "ae3053ed31c6e9623636f43d9c5622c1dd07d0fe3b18cf6e583412791ab7442b")
        XCTAssertEqual(m.mcp.npmDownloadBytes, 4076324)
        XCTAssertEqual(m.mcp.npmInstalledBytes, 18687294)
        XCTAssertEqual(m.mcp.npmPackageCount, 3)
        XCTAssertEqual(m.node.version, "24.22.3")
        XCTAssertEqual(m.node.teamIdentifier, "HX7739G8FX")
        XCTAssertEqual(m.chromium.revision, "1246")
        XCTAssertEqual(m.chromium.browserVersion, "154.0.8037.0")
        XCTAssertEqual(m.chromium.releasedAt, "2026-09-01")
        XCTAssertEqual(m.chromium.host, "storage.googleapis.com")
        XCTAssertEqual(m.hosts, ["nodejs.org", "registry.npmjs.org", "storage.googleapis.com"])
        XCTAssertEqual(m.staleAfterDays, 180)
        XCTAssertEqual(m.freeDiskFactor, 3)
    }

    func testTheConsentNumbersAreWhatSchema1Produced() {
        let m = PlaywrightManifest.embedded
        for (arch, node, chromium) in [(Arch.arm64, 53084299 as Int64, 191396177 as Int64), (Arch.x86_64, 54395976, 201605834)] {
            let npmDL = m.mcp.npmDownloadBytes
            XCTAssertEqual(m.downloadBytes(arch), node + chromium + npmDL)
        }
        XCTAssertEqual(m.diskBytes(.arm64), 841464241)
        XCTAssertEqual(m.diskBytes(.x86_64), 866566004)
        let plan = PlaywrightInstallPlan(manifest: m, arch: .arm64, root: URL(fileURLWithPath: "/x/playwright"))
        XCTAssertEqual(plan.hosts, ["nodejs.org", "registry.npmjs.org", "storage.googleapis.com"])
    }
}
