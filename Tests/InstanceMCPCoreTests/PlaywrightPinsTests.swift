import Foundation
import XCTest
@testable import InstanceMCPCore

/// The manifest built into the app is the one the release check verified (Q4). These tests read
/// the embedded Swift constants, so the data cannot drift from the JSON even if the script is skipped.
final class PlaywrightPinsTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testEmbeddedManifestDecodesAndValidates() {
        let m = PlaywrightManifest.embedded
        XCTAssertEqual(m.validate(), [])
        XCTAssertEqual(m.validateEmbeddedFiles(), [])
        XCTAssertEqual(m.hosts.sorted(), ["nodejs.org", "registry.npmjs.org", m.chromium.host].sorted())
    }

    func testEmbeddedConstantsEqualTheTrackedFiles() throws {
        let dir = repoRoot.appendingPathComponent("release/playwright-pins")
        XCTAssertEqual(PlaywrightPins.pinsJSON, try String(contentsOf: dir.appendingPathComponent("pins.json")))
        XCTAssertEqual(PlaywrightPins.packageJSON, try String(contentsOf: dir.appendingPathComponent("package.json")))
        XCTAssertEqual(PlaywrightPins.lockfileJSON, try String(contentsOf: dir.appendingPathComponent("package-lock.json")))
    }

    func testLockfileIsPinnedToTheRegistryWithIntegrity() throws {
        let lock = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(PlaywrightPins.lockfileJSON.utf8)) as? [String: Any])
        XCTAssertEqual(lock["lockfileVersion"] as? Int, 3)
        let pkgs = try XCTUnwrap(lock["packages"] as? [String: [String: Any]])
        XCTAssertGreaterThan(pkgs.count, 1)
        for (path, p) in pkgs where path != "" {
            XCTAssertTrue((p["resolved"] as? String ?? "").hasPrefix("https://registry.npmjs.org/"), path)
            XCTAssertTrue((p["integrity"] as? String ?? "").hasPrefix("sha512-"), path)
        }
        let root = try XCTUnwrap(pkgs[""])
        let deps = try XCTUnwrap(root["dependencies"] as? [String: String])
        XCTAssertEqual(deps, ["@playwright/mcp": PlaywrightManifest.embedded.mcp.version])
        XCTAssertEqual(pkgs["node_modules/playwright-core"]?["version"] as? String, PlaywrightManifest.embedded.mcp.playwrightCoreVersion)
    }

    func testIdChangesWithTheLockfile() {
        let m = PlaywrightManifest.embedded
        XCTAssertTrue(m.id.hasSuffix(String(m.mcp.lockfileSHA256.prefix(8))))
        XCTAssertTrue(m.id.contains(m.node.version))
        XCTAssertTrue(m.id.contains("cr" + m.chromium.revision))
    }

    func testChromiumPinnedToAFinalURLOnTheAllowedHost() {
        let m = PlaywrightManifest.embedded
        for a in m.chromium.artifacts.values {
            XCTAssertEqual(URL(string: a.url)?.host, m.chromium.host, "no redirect hop is needed or allowed")
            XCTAssertTrue(a.url.contains(m.chromium.browserVersion))
        }
    }

    /// The README states what the app downloads (R9). Its numbers must be the manifest's.
    func testReadmeSizesMatchTheManifest() throws {
        let readme = try String(contentsOf: repoRoot.appendingPathComponent("README.md"))
        let m = PlaywrightManifest.embedded
        func mb(_ n: Int64) -> Int { Int((Double(n) / 1_000_000).rounded()) }
        func installed(_ a: Arch) -> Int64 {
            (m.nodeArtifact(a)?.expandedBytes ?? 0) + (m.chromiumArtifact(a)?.expandedBytes ?? 0) + m.mcp.npmInstalledBytes
        }
        let want = [
            "download: about \(mb(m.downloadBytes(.arm64))) MB (Apple silicon) or \(mb(m.downloadBytes(.x86_64))) MB (Intel)",
            "on disk once installed: about \(mb(installed(.arm64))) MB (Apple silicon) or \(mb(installed(.x86_64))) MB (Intel)",
        ]
        let lower = readme.lowercased()
        for w in want { XCTAssertTrue(lower.contains(w.lowercased()), "README must say: \(w)") }
        for h in m.hosts { XCTAssertTrue(readme.contains(h), "README must name \(h)") }
        XCTAssertTrue(readme.contains(m.node.version) && readme.contains(m.mcp.version) && readme.contains(m.chromium.browserVersion))
    }

    func testPlanNumbersComeFromTheManifest() {
        let m = PlaywrightManifest.embedded
        let p = PlaywrightInstallPlan(manifest: m, arch: .arm64, root: URL(fileURLWithPath: "/x/playwright"))
        XCTAssertEqual(p.downloadBytes, m.nodeArtifact(.arm64)!.size + m.chromiumArtifact(.arm64)!.size + m.mcp.npmDownloadBytes)
        XCTAssertEqual(p.hosts, ["nodejs.org", "registry.npmjs.org", m.chromium.host])
        XCTAssertEqual(p.installPath, "/x/playwright")
        XCTAssertGreaterThan(p.diskBytes, p.downloadBytes)
    }

    func testNothingUnderBrowserTouchesQuarantine() throws {
        let dir = repoRoot.appendingPathComponent("Sources/InstanceMCPCore/Browser")
        for f in try FileManager.default.contentsOfDirectory(atPath: dir.path) where f.hasSuffix(".swift") {
            let text = try String(contentsOfFile: dir.appendingPathComponent(f).path)
            for bad in ["setxattr", "removexattr", "/usr/bin/xattr", "\"xattr\"", "tailscale"] {
                XCTAssertFalse(text.contains(bad), "\(f) contains \(bad)")
            }
        }
    }
}

final class PlaywrightManifestTests: XCTestCase {
    private func mutated(_ from: String, _ to: String) throws -> [String] {
        let text = PlaywrightPins.pinsJSON
        XCTAssertTrue(text.contains(from), from)
        return try PlaywrightManifest.decode(text.replacingOccurrences(of: from, with: to)).validate()
    }

    func testRulesRejectBadData() throws {
        XCTAssertFalse(try mutated("\"https://nodejs.org/dist", "\"http://nodejs.org/dist").isEmpty, "http url")
        XCTAssertFalse(try mutated("\"https://nodejs.org/dist", "\"https://evil.example/dist").isEmpty, "host outside the list")
        XCTAssertFalse(try mutated("\"https://nodejs.org/dist/v", "\"https://nodejs.org/../dist/v").isEmpty, "path traversal")
        XCTAssertFalse(try mutated("\"id\": \"mcp", "\"id\": \"../mcp").isEmpty, "unsafe id")
        XCTAssertFalse(try mutated("\"id\": \"mcp", "\"id\": \".mcp").isEmpty, "leading dot id")
        XCTAssertFalse(try mutated("\"freeDiskFactor\": 3", "\"freeDiskFactor\": 2").isEmpty)
        XCTAssertFalse(try mutated("\"teamIdentifier\": \"HX7739G8FX\"", "\"teamIdentifier\": \"x\\\" or true\"").isEmpty, "team id shape")
        XCTAssertFalse(try mutated("\"schema\": 2", "\"schema\": 1").isEmpty)
        XCTAssertFalse(try mutated("\"nodejs.org\",\n    \"registry", "\"nodejs.org\",\n    \"extra.example\",\n    \"registry").isEmpty, "extra host")
        XCTAssertFalse(try mutated("\"executable\": \"chrome-mac-arm64/", "\"executable\": \"../chrome-mac-arm64/").isEmpty, "executable escapes")
        XCTAssertFalse(try mutated("\"format\": \"tar.gz\"", "\"format\": \"zip\"").isEmpty, "format")
    }

    func testMissingArchitectureIsRejected() throws {
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(PlaywrightPins.pinsJSON.utf8)) as? [String: Any])
        var node = obj["node"] as! [String: Any]
        var arts = node["artifacts"] as! [String: Any]
        arts.removeValue(forKey: "darwin-x64")
        node["artifacts"] = arts
        obj["node"] = node
        let data = try JSONSerialization.data(withJSONObject: obj)
        let m = try PlaywrightManifest.decode(String(decoding: data, as: UTF8.self))
        XCTAssertTrue(m.validate().contains("node platforms"))
    }

    func testEmbeddedFilesCheckedAgainstTheirDigests() {
        let m = PlaywrightManifest.embedded
        XCTAssertEqual(m.validateEmbeddedFiles(packageJSON: PlaywrightPins.packageJSON + " ", lockfileJSON: PlaywrightPins.lockfileJSON), ["package.json digest"])
        XCTAssertEqual(m.validateEmbeddedFiles(packageJSON: PlaywrightPins.packageJSON, lockfileJSON: "{}"), ["lockfile digest"])
    }

    func testStaleness() {
        XCTAssertNotNil(PlaywrightManifest.parseDay("2026-09-01"))
        XCTAssertNil(PlaywrightManifest.parseDay("tomorrow"))
    }
}

final class NodeSignatureTests: XCTestCase {
    private var tmp: TempDir!
    override func setUp() { tmp = TempDir() }
    override func tearDown() { tmp.remove() }

    private func run(_ exe: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }

    private func copyOfTrue(_ name: String) throws -> URL {
        let u = tmp.url.appendingPathComponent(name)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: u.path)
        return u
    }

    private let v = SecurityFrameworkNodeVerifier()

    func testUnsignedScriptIsRefused() throws {
        let f = tmp.file("node", Data("#!/bin/sh\nexit 0\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        XCTAssertFalse(v.verify(executable: f, teamIdentifier: "HX7739G8FX"))
    }

    func testAdHocSignedCopyIsRefused() throws {
        let u = try copyOfTrue("adhoc")
        run("/usr/bin/codesign", ["--force", "-s", "-", u.path])
        XCTAssertFalse(v.verify(executable: u, teamIdentifier: "HX7739G8FX"))
    }

    func testTamperedAfterSigningIsRefused() throws {
        let u = try copyOfTrue("tampered")
        run("/usr/bin/codesign", ["--force", "-s", "-", u.path])
        let h = try FileHandle(forWritingTo: u)
        try h.seekToEnd(); try h.write(contentsOf: Data([0, 1, 2, 3])); try h.close()
        XCTAssertFalse(v.verify(executable: u, teamIdentifier: "HX7739G8FX"))
    }

    func testPlatformBinaryIsNotNodeForTheTeam() throws {
        XCTAssertFalse(v.verify(executable: URL(fileURLWithPath: "/usr/bin/true"), teamIdentifier: "HX7739G8FX"))
    }

    func testTeamIdentifierIsNeverInterpolatedUnchecked() throws {
        let u = try copyOfTrue("inj")
        for bad in ["\" or true or \"", "HX7739G8F", "hx7739g8fx", "", "HX7739G8FX\""] {
            XCTAssertFalse(v.verify(executable: u, teamIdentifier: bad), bad)
        }
    }

    func testMissingFileIsRefused() {
        XCTAssertFalse(v.verify(executable: tmp.url.appendingPathComponent("nope"), teamIdentifier: "HX7739G8FX"))
    }
}
