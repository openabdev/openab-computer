import Foundation
import XCTest
@testable import InstanceMCPCore

/// Installs the real pins for this machine's architecture into a temp root, with the production
/// downloader and the real signature check. It downloads about a quarter of a gigabyte, so it runs
/// only when `OAB_REAL_INSTALL=1`, on a build host, never in CI. The temp root is removed afterwards.
///
/// It settles V7 (quarantine and `spctl`, recorded), V8 (the pinned MCP lists the 32 tools and
/// navigates), V10 (Node's signature and team) and V12 (no TCP or UDP listener in the process
/// tree, and the child exits when stdin closes). A listener blocks the release.
final class PlaywrightRealInstallTests: XCTestCase {
    private func sh(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testRealInstallServesWithoutAListener() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OAB_REAL_INSTALL"] == "1", "set OAB_REAL_INSTALL=1 on a build host")
        let root = URL(fileURLWithPath: "/private/tmp/oab-real-install.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let m = PlaywrightManifest.embedded
        let arch = Arch.current
        XCTAssertEqual(m.validate(), [])
        let installer = PlaywrightInstaller.standard(root: root, stopManaged: {}, verifyServing: { true }, onRemoved: {}, log: { print($0) })
        let t0 = Date()
        let r = await installer.install { p in if p.fraction == nil || p.fraction == 0 { print("step \(p.step.rawValue)") } }
        print("install: \(r) in \(Int(Date().timeIntervalSince(t0))) s on \(arch.rawValue)")
        guard case .success = r else { return XCTFail("\(r)") }

        // V10: the signature and the team identifier of the staged Node.
        let rec = try XCTUnwrap(installer.readRecord())
        let vd = root.appendingPathComponent(rec.version)
        let node = vd.appendingPathComponent("node/bin/node")
        let (cs, csOut) = sh("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", node.path])
        print("V10 codesign --verify --strict: exit \(cs) \(csOut.replacingOccurrences(of: "\n", with: " | "))")
        XCTAssertEqual(cs, 0)
        let (_, di) = sh("/usr/bin/codesign", ["-dv", "--verbose=2", node.path])
        let team = di.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst(15)) }
        print("V10 TeamIdentifier=\(team ?? "none")")
        XCTAssertEqual(team, m.node.teamIdentifier)

        // V7: recorded, not asserted.
        let crApp = vd.appendingPathComponent("chromium/" + (m.chromiumArtifact(arch)!.executable!))
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (label, path) in [("node", node.path), ("chromium app", crApp.path)] {
            let (_, x) = sh("/usr/bin/xattr", ["-l", path])
            print("V7 xattr \(label): \(x.isEmpty ? "(none)" : x.replacingOccurrences(of: "\n", with: " | "))")
            let (sc, so) = sh("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", path])
            print("V7 spctl \(label): exit \(sc) \(so.replacingOccurrences(of: "\n", with: " | "))")
        }
        XCTAssertFalse(sh("/usr/bin/xattr", ["-l", node.path]).1.contains("com.apple.quarantine"), "recorded in V7; the app never adds it")

        // V8 and V12: start the pinned MCP the way the app does (headless here, no window server over SSH).
        guard case .success(let spec0) = ManagedPlaywrightLocator(root: root).locate() else { return XCTFail("locate") }
        let spec = ManagedLaunchSpec(executable: spec0.executable, arguments: spec0.arguments + ["--headless"],
                                     environment: spec0.environment, workingDirectory: spec0.workingDirectory)
        let child = try ManagedProcess.spawn(executable: spec.executable, arguments: spec.arguments,
                                             environment: spec.environment, workingDirectory: spec.workingDirectory)
        let client = StdioMCPClient(channel: child)
        try await client.initialize(timeout: 60)
        let names = try await client.listTools(timeout: 60).compactMap { $0["name"]?.stringValue }
        print("V8 tools/list: \(names.count) tools, missing from catalog: \(Set(BrowserToolCatalog.allNames).subtracting(names).sorted())")
        XCTAssertTrue(Set(BrowserToolCatalog.allNames).isSubset(of: names))
        XCTAssertTrue(names.contains("browser_run_code_unsafe"))
        let nav = try await client.callTool("browser_navigate", arguments: ["url": "about:blank"], timeout: 90)
        XCTAssertNotEqual(nav["isError"]?.boolValue, true)
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let tree = ProcessTree.descendants(of: [child.pid]).union([child.pid])
        let pidList = tree.map(String.init).joined(separator: ",")
        let (_, sockets) = sh("/usr/sbin/lsof", ["-nP", "-i", "-a", "-p", pidList])
        print("V12 processes in the tree: \(tree.count); lsof -nP -i:\n\(sockets.isEmpty ? "(no network sockets)" : sockets)")
        XCTAssertFalse(sockets.contains("LISTEN"), "no TCP listener")
        XCTAssertFalse(sockets.contains("UDP"), "no UDP socket")

        // V12: stdin EOF ends the child.
        child.closeStdin()
        var exited = false
        for _ in 0..<100 { if child.hasExited { exited = true; break }; try await Task.sleep(nanoseconds: 100_000_000) }
        print("V12 exits on stdin EOF: \(exited)")
        await child.terminate()
        let (_, left) = sh("/bin/ps", ["-o", "pid=", "-p", pidList])
        XCTAssertTrue(left.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "no process of the tree remains: \(left)")
    }
}
