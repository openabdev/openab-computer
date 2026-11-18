import Foundation
import XCTest
@testable import InstanceMCPCore

/// An engine switch at the same manifest id (#128) never deletes the live install before the new one has served.
final class EngineSwitchSafetyTests: InstallerTestCase {
    private func setup(_ engine: BrowserEngine, serving: MutableBox<Bool>, stop: @escaping @Sendable () async -> Void = {})
        async throws -> (PlaywrightInstaller, FakeInstallFixture, FakeChromeBundle) {
        let fx = try FakeInstallFixture()
        let chrome = try FakeChromeBundle()
        addTeardownBlock { chrome.tmp.remove() }
        let i = fx.installer(root: root, stop: stop, serving: { serving.value },
                             chromeChecker: chrome.checker())
        _ = await i.install(engine: engine) { _ in }
        XCTAssertEqual(i.selectedEngine(), engine)
        try Data("live\n".utf8).write(to: root.appendingPathComponent(fx.manifest.id).appendingPathComponent("sentinel"))
        return (i, fx, chrome)
    }

    private func assertLiveIntact(_ i: PlaywrightInstaller, _ fx: FakeInstallFixture, _ engine: BrowserEngine,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(i.selectedEngine(), engine, file: file, line: line)
        let dir = root.appendingPathComponent(fx.manifest.id)
        XCTAssertEqual(try? String(contentsOf: dir.appendingPathComponent("sentinel")), "live\n", "the live folder is still there", file: file, line: line)
        XCTAssertTrue(i.hasOwnershipMarker(fx.manifest.id), file: file, line: line)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertFalse(names.contains { $0.contains(".prev-") || $0.hasPrefix(".staging-") }, "no leftovers: \(names)", file: file, line: line)
    }

    func testSwitchingToChromeThatDoesNotServeKeepsTheLiveChromiumInstall() async throws {
        let serving = MutableBox(true)
        let (i, fx, _) = try await setup(.downloadedChromium, serving: serving)
        serving.value = false
        let r = await i.install(engine: .installedChrome) { _ in }
        XCTAssertEqual(r, .failure(.healthCheckFailed))
        try assertLiveIntact(i, fx, .downloadedChromium)
    }

    func testSwitchingToChromiumThatDoesNotServeKeepsTheLiveChromeInstall() async throws {
        let serving = MutableBox(true)
        let (i, fx, _) = try await setup(.installedChrome, serving: serving)
        serving.value = false
        let r = await i.install(engine: .downloadedChromium) { _ in }
        XCTAssertEqual(r, .failure(.healthCheckFailed))
        try assertLiveIntact(i, fx, .installedChrome)
    }

    func testARecordWriteFailureAfterTheCommitKeepsTheLiveInstallInBothDirections() async throws {
        for (from, to) in [(BrowserEngine.downloadedChromium, BrowserEngine.installedChrome),
                           (.installedChrome, .downloadedChromium)] {
            let serving = MutableBox(true)
            let tamper = MutableBox(false)
            let rootURL: URL = root
            let (i, fx, _) = try await setup(from, serving: serving, stop: {
                // The record changes under the installer: its compare-and-swap refuses to replace it.
                if tamper.value { try? Data("{\"foreign\":true}".utf8).write(to: rootURL.appendingPathComponent("install.json")) }
            })
            tamper.value = true
            let r = await i.install(engine: to) { _ in }
            guard case .failure = r else { return XCTFail("expected a failure, got \(r)") }
            let dir = root.appendingPathComponent(fx.manifest.id)
            XCTAssertEqual(try? String(contentsOf: dir.appendingPathComponent("sentinel")), "live\n", "\(from) -> \(to)")
            XCTAssertTrue(i.hasOwnershipMarker(fx.manifest.id))
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            XCTAssertFalse(names.contains { $0.contains(".prev-") }, "\(names)")
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    func testASuccessfulSwitchLeavesNoBackupAndTheNewEngine() async throws {
        let serving = MutableBox(true)
        let (i, fx, _) = try await setup(.downloadedChromium, serving: serving)
        let r = await i.install(engine: .installedChrome) { _ in }
        guard case .success = r else { return XCTFail("\(r)") }
        XCTAssertEqual(i.selectedEngine(), .installedChrome)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertFalse(names.contains { $0.contains(".prev-") }, "\(names)")
        XCTAssertTrue(i.hasOwnershipMarker(fx.manifest.id))
    }
}
