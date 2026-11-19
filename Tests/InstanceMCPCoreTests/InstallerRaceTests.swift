import Foundation
import XCTest
@testable import InstanceMCPCore

/// Verifier that passes a set number of times and then refuses: a Chrome replaced during an install.
final class FlippingChromeVerifier: ChromeSignatureVerifying, @unchecked Sendable {
    let passes: Int
    let calls = MutableBox(0)
    init(passes: Int) { self.passes = passes }
    func verify(app: URL) -> Bool { calls.value += 1; return calls.value <= passes }
}

/// Races inside one install (#128 review): Chrome checked again right before it is launched, and rollback or
/// cleanup that never deletes a directory it did not create or move.
final class InstallerRaceTests: InstallerTestCase {
    private func chromeBundle() throws -> FakeChromeBundle {
        let b = try FakeChromeBundle()
        addTeardownBlock { b.tmp.remove() }
        return b
    }

    func testChromeThatFailsItsCheckJustBeforeTheLaunchIsNeverLaunched() async throws {
        let fx = try FakeInstallFixture()
        let chrome = try chromeBundle()
        let v = FlippingChromeVerifier(passes: 1)   // the early check passes, the one before launch refuses
        let flipping = InstalledChromeChecker(directories: [chrome.applications], verifier: v, minimumMajor: 120)
        let i2 = fx.installer(root: root, chromeChecker: flipping)
        let r = await i2.install(engine: .installedChrome) { _ in }
        XCTAssertEqual(r, .failure(.other("chrome_invalid_signature")))
        XCTAssertEqual(v.calls.value, 2, "checked early and again before the launch")
        XCTAssertEqual(i2.state(), .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("install.json").path))
    }

    private func installChromeThenSwitch(_ fx: FakeInstallFixture, _ chrome: FakeChromeBundle,
                                         hook: @escaping @Sendable (PlaywrightInstallProgress) -> Void) async -> Result<PlaywrightInstallState, PlaywrightInstallFailure> {
        let installer = fx.installer(root: root, chromeChecker: chrome.checker())
        let first = await installer.install(engine: .installedChrome) { _ in }
        guard case .success = first else { XCTFail("\(first)"); return first }
        return await installer.install(engine: .downloadedChromium, progress: hook)
    }

    private func foreign(_ u: URL) throws {
        try? FileManager.default.removeItem(at: u)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: u.appendingPathComponent("user-data"))
    }

    func testAReplacedBackupDirectoryIsNotDeletedAfterASuccessfulSwitch() async throws {
        let fx = try FakeInstallFixture()
        let chrome = try chromeBundle()
        let root = self.root!
        let swapped = MutableBox<URL?>(nil)
        let r = await installChromeThenSwitch(fx, chrome) { p in
            guard p.step == .switchOver else { return }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            if let n = names.first(where: { $0.contains(".prev-") }) {
                let u = root.appendingPathComponent(n)
                try? self.foreign(u)
                swapped.value = u
            }
        }
        guard case .success = r else { return XCTFail("\(r)") }
        let u = try XCTUnwrap(swapped.value, "the old install was set aside")
        XCTAssertEqual(try? String(contentsOf: u.appendingPathComponent("user-data")), "keep", "a directory that replaced the backup stays")
    }

    func testAReplacedTargetDirectoryIsNotDeletedByARollback() async throws {
        let fx = try FakeInstallFixture()
        let chrome = try chromeBundle()
        let root = self.root!
        let id = fx.manifest.id
        let r = await installChromeThenSwitch(fx, chrome) { p in
            guard p.step == .switchOver else { return }
            try? self.foreign(root.appendingPathComponent(id))
            // The record changes under the installer, so its write fails and the rollback runs.
            try? Data("{}".utf8).write(to: root.appendingPathComponent("install.json"))
        }
        guard case .failure = r else { return XCTFail("the switch should have failed: \(r)") }
        XCTAssertEqual(try? String(contentsOf: root.appendingPathComponent(id).appendingPathComponent("user-data")), "keep",
                       "a directory that replaced the new install stays")
    }
}
