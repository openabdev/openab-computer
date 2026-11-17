import Foundation
import XCTest
@testable import InstanceMCPCore

/// The installed Google Chrome route (#128, ADR Q3 and Q5, R7.3). Chrome here is a fake bundle in a temp folder and
/// the signature check is injected: nothing launches Chrome, opens a window or reads the real Chrome.

final class StubChromeVerifier: ChromeSignatureVerifying, @unchecked Sendable {
    let result: MutableBox<Bool>
    let calls = MutableBox(0)
    init(_ r: Bool = true) { result = MutableBox(r) }
    func verify(app: URL) -> Bool { calls.value += 1; return result.value }
}

/// `<root>/Applications/Google Chrome.app` with an Info.plist and a program that is never run.
final class FakeChromeBundle {
    let tmp = TempDir()
    let applications: URL
    var app: URL { applications.appendingPathComponent("Google Chrome.app", isDirectory: true) }
    var executable: URL { app.appendingPathComponent("Contents/MacOS/Google Chrome") }

    init(version: String = "157.0.8103.79", bundleID: String = "com.google.Chrome", executableName: String = "Google Chrome") throws {
        applications = tmp.dir("Applications")
        try write(version: version, bundleID: bundleID, executableName: executableName)
    }

    func write(version: String, bundleID: String = "com.google.Chrome", executableName: String = "Google Chrome") throws {
        let fm = FileManager.default
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": executableName,
                                    "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let exe = app.appendingPathComponent("Contents/MacOS/\(executableName)")
        try "#!/bin/sh\nexit 97\n".write(to: exe, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    }

    func checker(_ v: StubChromeVerifier = StubChromeVerifier(), minimumMajor: Int = 120) -> InstalledChromeChecker {
        InstalledChromeChecker(directories: [applications], verifier: v, minimumMajor: minimumMajor)
    }

    /// Names, sizes and bytes of every file: proves the app did not change the bundle.
    func snapshot() -> [String: Data] {
        var out: [String: Data] = [:]
        let e = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let u = e?.nextObject() as? URL {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            out[u.path] = isDir.boolValue ? Data("dir".utf8) : (try? Data(contentsOf: u))
        }
        return out
    }
}

final class InstalledChromeCheckerTests: XCTestCase {
    func testAGoogleChromeBundleIsAcceptedAndItsVersionComesFromTheBundle() throws {
        let b = try FakeChromeBundle(version: "157.0.8103.79")
        let v = StubChromeVerifier()
        guard case .success(let c) = b.checker(v).check() else { return XCTFail() }
        XCTAssertEqual(c.version, "157.0.8103.79")
        XCTAssertEqual(c.major, 157)
        XCTAssertEqual(c.executablePath, b.executable.path)
        XCTAssertEqual(v.calls.value, 1)
        XCTAssertTrue(b.checker().isInstalled())
    }

    func testMissingChromeIsNotInstalledAndNotFound() throws {
        let tmp = TempDir(); defer { tmp.remove() }
        let c = InstalledChromeChecker(directories: [tmp.dir("Applications")], verifier: StubChromeVerifier())
        XCTAssertFalse(c.isInstalled())
        XCTAssertEqual(c.check(), .failure(.notFound))
    }

    func testOnlyBothApplicationsFoldersAreLookedAt() throws {
        let b = try FakeChromeBundle()
        let elsewhere = TempDir(); defer { elsewhere.remove() }
        let c = InstalledChromeChecker(directories: [elsewhere.dir("Applications"), b.applications], verifier: StubChromeVerifier())
        XCTAssertEqual(try? c.check().get().appPath, b.app.path, "the second folder is searched when the first has none")
        // A recorded path outside the allowed folders is refused before any signature check.
        let v = StubChromeVerifier()
        let other = try FakeChromeBundle()
        XCTAssertEqual(InstalledChromeChecker(directories: [b.applications], verifier: v).check(appPath: other.app.path),
                       .failure(.notGoogleChrome))
        XCTAssertEqual(v.calls.value, 0)
    }

    func testChromiumForksAndOtherBuildsNamedChromeAreRefused() throws {
        for (id, exe) in [("org.chromium.Chromium", "Chromium"), ("com.google.Chrome.beta", "Google Chrome Beta"),
                          ("com.google.Chrome", "Chromium"), ("com.example.fork", "Google Chrome")] {
            let b = try FakeChromeBundle(bundleID: id, executableName: exe)
            let v = StubChromeVerifier()
            XCTAssertEqual(b.checker(v).check(), .failure(.notGoogleChrome), "\(id) / \(exe)")
            XCTAssertEqual(v.calls.value, 0, "an obvious non-Chrome never reaches the signature check")
        }
    }

    func testASymlinkedAppIsNeverAccepted() throws {
        let real = try FakeChromeBundle()
        let tmp = TempDir(); defer { tmp.remove() }
        let apps = tmp.dir("Applications")
        try FileManager.default.createSymbolicLink(at: apps.appendingPathComponent("Google Chrome.app"), withDestinationURL: real.app)
        let v = StubChromeVerifier()
        XCTAssertEqual(InstalledChromeChecker(directories: [apps], verifier: v).check(), .failure(.notGoogleChrome))
        XCTAssertEqual(v.calls.value, 0)
    }

    func testABundleThatFailsTheSignatureCheckIsRefused() throws {
        let b = try FakeChromeBundle()
        XCTAssertEqual(b.checker(StubChromeVerifier(false)).check(), .failure(.invalidSignature))
    }

    func testTooOldChromeIsRefusedWithTheNumbers() throws {
        let b = try FakeChromeBundle(version: "119.0.1")
        XCTAssertEqual(b.checker(minimumMajor: 120).check(), .failure(.tooOld(found: 119, minimum: 120)))
        let ok = try FakeChromeBundle(version: "120.0.1")
        XCTAssertNotNil(try? ok.checker(minimumMajor: 120).check().get())
        let junk = try FakeChromeBundle(version: "abc")
        XCTAssertEqual(junk.checker().check(), .failure(.unreadable))
    }

    func testTheSignatureIsCheckedOnEveryCallEvenForAnUnchangedBundle() throws {
        let b = try FakeChromeBundle()
        let v = StubChromeVerifier()
        let c = b.checker(v)
        _ = c.check(); _ = c.check()
        XCTAssertEqual(v.calls.value, 2, "no result is reused, so nested code changes are always seen")
        try b.write(version: "158.0.1")
        guard case .success(let updated) = c.check() else { return XCTFail() }
        XCTAssertEqual(updated.version, "158.0.1")
        XCTAssertEqual(v.calls.value, 3)
        // A mutation that touches neither Info.plist nor the program (nested code only) is caught by the next check.
        v.result.value = false
        XCTAssertEqual(c.check(), .failure(.invalidSignature))
        XCTAssertEqual(c.check(), .failure(.invalidSignature))
        XCTAssertEqual(v.calls.value, 5)
    }

    func testTheRequirementNamesGoogleLLCAndTheRealVerifierRefusesAnUnsignedBundle() throws {
        let r = InstalledChromePolicy.requirement
        XCTAssertTrue(r.contains("anchor apple generic"))
        XCTAssertTrue(r.contains("certificate leaf[subject.OU] = \"EQHXZ8M8AV\""))
        XCTAssertTrue(r.contains("identifier \"com.google.Chrome\""))
        XCTAssertTrue(r.contains("1.2.840.113635.100.6.1.13"), "a Developer ID Application leaf")
        let b = try FakeChromeBundle()
        XCTAssertFalse(SecurityFrameworkChromeVerifier().verify(app: b.app), "a bundle named Google Chrome is not enough")
    }
}

@MainActor
final class InstalledChromeFlowTests: InstallerTestCase {
    private lazy var chrome: FakeChromeBundle = {
        let b = try! FakeChromeBundle()
        addTeardownBlock { b.tmp.remove() }
        return b
    }()

    private func controller(_ installer: PlaywrightInstaller, logs: MutableBox<[String]> = MutableBox([])) -> BrowserToolsController {
        let name = "oab-chrome-test-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return BrowserToolsController(installer: installer, store: BrowserToolsStore(defaults: UserDefaults(suiteName: name)!),
                                      signIn: { _, _ in .null }, log: { logs.value += [$0] })
    }

    private func scriptedDownloader(_ fx: FakeInstallFixture) -> ScriptedDownloader {
        ScriptedDownloader(inner: URLSessionArtifactDownloader(policy: DownloadPolicy(allowedHosts: Set(fx.manifest.hosts), allowLoopbackHTTP: true), requestTimeout: 10))
    }

    private func refusingDownloader(_ fx: FakeInstallFixture) -> ScriptedDownloader {
        let d = scriptedDownloader(fx)
        d.failFirst.value = .launchRefused
        return d
    }

    private func finish(_ c: BrowserToolsController, _ start: (@escaping (Result<PlaywrightInstallState, PlaywrightInstallFailure>, BrowserPageStep) -> Void) -> Bool) async -> Result<PlaywrightInstallState, PlaywrightInstallFailure>? {
        let out = MutableBox<Result<PlaywrightInstallState, PlaywrightInstallFailure>?>(nil)
        XCTAssertTrue(start { r, _ in out.value = r })
        _ = await waitFor { out.value != nil }
        return out.value
    }

    /// A controller whose first install is refused by macOS (simulated at the downloader), with the fake Chrome present.
    private func refusedController(fx: FakeInstallFixture, verifier: StubChromeVerifier = StubChromeVerifier(),
                                   logs: MutableBox<[String]> = MutableBox([]), chromePresent: Bool = true)
        async -> (BrowserToolsController, PlaywrightInstaller)? {
        let dl = refusingDownloader(fx)
        let checker: any InstalledChromeChecking = chromePresent ? chrome.checker(verifier)
            : InstalledChromeChecker(directories: [chrome.tmp.dir("Empty")], verifier: verifier)
        let installer = fx.installer(root: root, logs: logs, downloader: dl, chromeChecker: checker)
        let c = controller(installer, logs: logs)
        let r = await finish(c) { c.startInstall(finished: $0) }
        guard case .failure(.launchRefused)? = r else { XCTFail("expected launchRefused, got \(String(describing: r))"); return nil }
        return (c, installer)
    }

    // MARK: the offer

    func testLaunchRefusedWithChromeOffersRetryContinueWithoutAndUseMyInstalledChrome() async throws {
        let fx = try FakeInstallFixture()
        guard let (c, _) = await refusedController(fx: fx) else { return }
        let f = c.model.footer
        XCTAssertTrue(f.showsRetry); XCTAssertTrue(f.showsContinueWithout); XCTAssertTrue(f.showsUseInstalledChrome)
        XCTAssertFalse(f.showsContinue); XCTAssertFalse(f.showsCancel); XCTAssertFalse(f.showsSignIn)
        XCTAssertEqual(c.model.failure, .launchRefused)
    }

    func testLaunchRefusedWithoutChromeOffersOnlyRetryAndContinueWithout() async throws {
        let fx = try FakeInstallFixture()
        guard let (c, _) = await refusedController(fx: fx, chromePresent: false) else { return }
        XCTAssertFalse(c.model.footer.showsUseInstalledChrome)
        XCTAssertTrue(c.model.footer.showsRetry); XCTAssertTrue(c.model.footer.showsContinueWithout)
        XCTAssertNil(c.requestChromeConsent(), "no button, no consent step")
    }

    func testNoOtherFailureEverOffersChrome() {
        let failures: [PlaywrightInstallFailure] = [
            .offline, .interrupted, .tls, .digestMismatch, .notEnoughDisk(needed: 2, available: 1), .archiveRejected, .nodeSignature,
            .lockHeld, .healthCheckFailed, .other("x_y"), .other("chrome_too_old"), .other("launch_refused")]
        for f in failures {
            var m = BrowserPageModel(installState: .notInstalled)
            m.setChromeDetected(true)
            XCTAssertTrue(m.continuePressed() == .startInstall)
            _ = m.finished(.failure(f))
            XCTAssertFalse(m.footer.showsUseInstalledChrome, "\(f)")
            XCTAssertFalse(m.useInstalledChromePressed(), "\(f)")
        }
        var m = BrowserPageModel(installState: .notInstalled)
        m.setChromeDetected(true)
        XCTAssertFalse(m.footer.showsUseInstalledChrome, "not offered before any failure")
        _ = m.continuePressed(); _ = m.finished(.failure(.launchRefused))
        XCTAssertTrue(m.footer.showsUseInstalledChrome)
    }

    // MARK: consent

    func testChoosingItOnlyShowsTheConsentAndCancelLeavesEverythingAsItWas() async throws {
        let fx = try FakeInstallFixture()
        let logs = MutableBox<[String]>([])
        guard let (c, installer) = await refusedController(fx: fx, logs: logs) else { return }
        let before = c.model
        let requestsBefore = fx.requested.value

        guard case .consent(let title, let text, let found)? = c.requestChromeConsent(home: "/Users/someone") else { return XCTFail() }
        XCTAssertEqual(title, "Use your installed Google Chrome?")
        XCTAssertEqual(found.appPath, chrome.app.path)
        XCTAssertTrue(c.model.chromeConsentOpen)
        // Nothing is launched, downloaded or recorded while the consent step shows.
        assertNothingInstalled()
        XCTAssertEqual(fx.requested.value, requestsBefore)
        XCTAssertEqual(installer.state(), .notInstalled)

        c.cancelChromeConsent()
        XCTAssertEqual(c.model, before, "cancel returns to the failure state unchanged")
        XCTAssertFalse(c.confirmChromeConsent { _, _ in }, "a confirm without an open consent step does nothing")
        assertNothingInstalled()
        XCTAssertTrue(text.contains("157.0.8103.79"))
        XCTAssertTrue(logs.value.contains("browser: chrome_consent_shown"))
        XCTAssertTrue(logs.value.contains("browser: chrome_consent_cancelled"))
    }

    func testTheConsentTextSaysWhatChangesAndNeverClaimsPinningOrADigestForChrome() {
        let p = PlaywrightInstallPlan(manifest: .embedded, arch: .arm64, root: URL(fileURLWithPath: "/Users/someone/Library/Application Support/oab-computer/playwright"))
        let c = InstalledChrome(appPath: "/Applications/Google Chrome.app", executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", version: "157.0.1", major: 157)
        let t = WizardCopy.chromeConsent(plan: p, chrome: c, home: "/Users/someone")
        XCTAssertTrue(t.contains("does not pin the version of your Chrome and does not check a digest of it"), t)
        XCTAssertTrue(t.contains("own separate browser profile"), t)
        XCTAssertTrue(t.contains("~/Library/Application Support/oab-computer/playwright/profile"), t)
        XCTAssertTrue(t.contains("Your Chrome profile, bookmarks and sign-ins are never used or changed"), t)
        XCTAssertTrue(t.contains("signed by Google LLC"), t)
        XCTAssertTrue(t.contains("Chromium is not downloaded"), t)
        XCTAssertTrue(t.contains(WizardCopy.megabytes(p.chromeDownloadBytes)), t)
        XCTAssertTrue(t.contains("never copies, changes or deletes Chrome"), t)
        XCTAssertTrue(t.contains("Nothing is installed until you press the button below"), t)
        XCTAssertTrue(t.contains("157.0.1"), t)
        XCTAssertLessThan(p.chromeDownloadBytes, p.downloadBytes, "the Chromium archive is not part of this download")
        for line in [t, WizardCopy.chromeStatusLine(version: "157.0.1"), WizardCopy.browserChromeInstalledNote,
                     WizardCopy.updatePromptChrome(installed: "a", plan: p, home: "/Users/someone")] {
            XCTAssertFalse(line.lowercased().contains("pinned and"), line)
            XCTAssertFalse(line.lowercased().contains("verified chrome"), line)
        }
        XCTAssertTrue(WizardCopy.chromeStatusLine(version: "157.0.1").contains("not pinned, no digest checked"))
    }

    func testEveryChromeProblemHasItsOwnMessageAndNothingIsConsentedWhenCheckingFails() async throws {
        let problems: [InstalledChromeProblem] = [.notFound, .notGoogleChrome, .invalidSignature, .tooOld(found: 1, minimum: 120), .unreadable]
        for p in problems {
            XCTAssertFalse(WizardCopy.chromeProblem(p).isEmpty)
            XCTAssertNotNil(WizardCopy.chromeFailureMessage(p.errorClass), p.errorClass)
            XCTAssertTrue(InstalledChromeProblem.classes.contains(p.errorClass))
        }
        let fx = try FakeInstallFixture()
        let v = StubChromeVerifier()
        guard let (c, installer) = await refusedController(fx: fx, verifier: v) else { return }
        v.result.value = false
        guard case .problem(let p)? = c.requestChromeConsent() else { return XCTFail() }
        XCTAssertEqual(p, .invalidSignature)
        XCTAssertFalse(c.model.chromeConsentOpen, "no consent step for a Chrome that failed its check")
        XCTAssertEqual(c.model.failure, .launchRefused, "the failure state is unchanged")
        XCTAssertEqual(installer.state(), .notInstalled)
        assertNothingInstalled()
    }

    // MARK: after consent

    func testAfterConsentThePinnedPartsAreInstalledNoChromiumIsDownloadedAndTheChoiceIsRecorded() async throws {
        let fx = try FakeInstallFixture()
        let logs = MutableBox<[String]>([])
        guard let (c, installer) = await refusedController(fx: fx, logs: logs) else { return }
        XCTAssertNotNil(c.requestChromeConsent())
        let out = MutableBox<Result<PlaywrightInstallState, PlaywrightInstallFailure>?>(nil)
        XCTAssertTrue(c.confirmChromeConsent { r, _ in out.value = r })
        _ = await waitFor { out.value != nil }
        guard case .success(.installed(let id, _, _))? = out.value else { return XCTFail("\(String(describing: out.value))") }
        XCTAssertEqual(id, fx.manifest.id)

        XCTAssertFalse(fx.requested.value.contains("/chromium.zip"), "the Chromium archive is not downloaded: \(fx.requested.value)")
        XCTAssertTrue(fx.requested.value.contains("/node.tgz"))
        XCTAssertEqual(installer.selectedEngine(), .installedChrome)
        XCTAssertEqual(installer.installedChromeSelection()?.appPath, chrome.app.path)
        XCTAssertEqual(installer.installedChromeSelection()?.versionAtConsent, "157.0.8103.79")
        XCTAssertTrue(c.model.usesInstalledChrome)
        XCTAssertEqual(c.model.phase, .installed(updateAvailable: false))
        // The installer's own ownership rules are unchanged: its record, its marked version folder, its data markers.
        let rec = try XCTUnwrap(installer.readRecord())
        XCTAssertTrue(installer.recordIsOurs(rec))
        XCTAssertTrue(installer.hasOwnershipMarker(rec.version))
        XCTAssertNil(rec.digests?.chromium, "no digest of Chrome is recorded: there is none")
        XCTAssertNil(rec.chromiumRevision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(rec.version).appendingPathComponent("chromium").path))
        XCTAssertTrue(installer.hasDataMarker("profile"))
        XCTAssertTrue(logs.value.contains("browser: chrome_consent_confirmed"))
        XCTAssertTrue(logs.value.contains("browser: playwright_install_engine engine=installed_chrome"))
        let pattern = try NSRegularExpression(pattern: "^browser: [a-z_]+( [a-z]+=[A-Za-z0-9_.-]+)*$")
        for l in logs.value where l.hasPrefix("browser: ") {
            XCTAssertNotNil(pattern.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), l)
            XCTAssertFalse(l.contains("/"), "no paths or URLs in a log line: \(l)")
        }
    }

    func testTheChoiceSurvivesARestart() async throws {
        let fx = try FakeInstallFixture()
        guard let (c, _) = await refusedController(fx: fx) else { return }
        XCTAssertNotNil(c.requestChromeConsent())
        let r = await finish(c) { c.confirmChromeConsent(finished: $0) }
        guard case .success? = r else { return XCTFail() }
        // A new installer and a new controller on the same folder, as after a restart.
        let again = fx.installer(root: root, chromeChecker: chrome.checker())
        XCTAssertEqual(again.selectedEngine(), .installedChrome)
        let c2 = controller(again)
        XCTAssertTrue(c2.model.usesInstalledChrome)
        XCTAssertEqual(c2.model.phase, .installed(updateAvailable: false))
        let loc = ManagedPlaywrightLocator(root: root, chrome: chrome.checker())
        XCTAssertEqual(loc.systemChromeSummary(), .systemChrome(version: "157.0.8103.79"))
    }

    func testConsentIsNeverInferredAPlainRetryOrASecondFailureStaysOnTheDownloadedChromium() async throws {
        let fx = try FakeInstallFixture()
        guard let (c, installer) = await refusedController(fx: fx) else { return }
        // Retry is the downloaded Chromium, not Chrome.
        XCTAssertEqual(c.pageRetry(), .startInstall)
        let out = MutableBox<Result<PlaywrightInstallState, PlaywrightInstallFailure>?>(nil)
        c.runInstall { r, _ in out.value = r }
        _ = await waitFor { out.value != nil }
        guard case .success? = out.value else { return XCTFail() }
        XCTAssertEqual(installer.selectedEngine(), .downloadedChromium)
        XCTAssertNil(installer.installedChromeSelection())
        XCTAssertNil(installer.readRecord()?.systemChrome)
        XCTAssertTrue(fx.requested.value.contains("/chromium.zip"))
    }

    func testAnInstallThatDrivesChromeStopsBeforeAnyDownloadWhenChromeFailsItsCheck() async throws {
        let fx = try FakeInstallFixture()
        let v = StubChromeVerifier(false)
        let installer = fx.installer(root: root, chromeChecker: chrome.checker(v))
        let r = await installer.install(engine: .installedChrome) { _ in }
        XCTAssertEqual(r, .failure(.other("chrome_invalid_signature")))
        XCTAssertEqual(fx.requested.value, [], "nothing was downloaded")
        assertNothingInstalled()
        XCTAssertTrue(WizardCopy.installFailure(.other("chrome_invalid_signature")).contains("Google LLC"))
    }

    // MARK: ownership, remove, turn off

    func testRemoveDeletesOnlyWhatTheInstallerOwnsAndLeavesChromeByteForByte() async throws {
        let fx = try FakeInstallFixture()
        guard let (c, _) = await refusedController(fx: fx) else { return }
        XCTAssertNotNil(c.requestChromeConsent())
        _ = await finish(c) { c.confirmChromeConsent(finished: $0) }
        let before = chrome.snapshot()
        try Data("mine".utf8).write(to: root.appendingPathComponent("keep.txt"))

        let outcome = await c.remove()

        XCTAssertEqual(outcome, .partial, "a file the installer did not create stays, and the outcome says so")
        XCTAssertEqual(c.installState, .notInstalled)
        XCTAssertNil(c.installer.selectedEngine(), "the choice was only a setting in install.json and is gone with it")
        XCTAssertFalse(c.model.usesInstalledChrome)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("keep.txt").path))
        XCTAssertEqual(chrome.snapshot(), before, "Chrome is untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: chrome.executable.path))
    }

    func testRemoveWithNothingElseInTheFolderIsFullAndChromeStays() async throws {
        let fx = try FakeInstallFixture()
        guard let (c, _) = await refusedController(fx: fx) else { return }
        XCTAssertNotNil(c.requestChromeConsent())
        _ = await finish(c) { c.confirmChromeConsent(finished: $0) }
        let before = chrome.snapshot()
        let outcome = await c.remove()
        XCTAssertEqual(outcome, .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(chrome.snapshot(), before)
    }

    func testAForeignInstallJSONIsStillNeverReplacedByTheChromeInstall() async throws {
        let fx = try FakeInstallFixture()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mine = Data("{\"version\":\"x\",\"chromiumExecutable\":\"y\"}".utf8)
        try mine.write(to: root.appendingPathComponent("install.json"))
        let installer = fx.installer(root: root, chromeChecker: chrome.checker())
        let r = await installer.install(engine: .installedChrome) { _ in }
        XCTAssertEqual(r, .failure(.other("foreign_install")))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("install.json")), mine)
    }

    func testTurningItOffGoesBackToTheDownloadedChromiumAndAFailedSwitchKeepsChrome() async throws {
        let fx = try FakeInstallFixture()
        let dl = refusingDownloader(fx)
        let installer = fx.installer(root: root, downloader: dl, chromeChecker: chrome.checker())
        let c = controller(installer)
        _ = await finish(c) { c.startInstall(finished: $0) }
        XCTAssertNotNil(c.requestChromeConsent())
        _ = await finish(c) { c.confirmChromeConsent(finished: $0) }
        XCTAssertEqual(installer.selectedEngine(), .installedChrome)
        let before = chrome.snapshot()

        // A failed switch (offline) leaves the installed-Chrome choice working.
        dl.failFirst.value = .offline
        let failed = await finish(c) { c.useDownloadedChromium(finished: $0) }
        XCTAssertEqual(failed, .failure(.offline))
        XCTAssertEqual(installer.selectedEngine(), .installedChrome)
        XCTAssertEqual(c.model.phase, .installed(updateAvailable: false))
        XCTAssertTrue(c.model.usesInstalledChrome)

        let ok = await finish(c) { c.useDownloadedChromium(finished: $0) }
        guard case .success? = ok else { return XCTFail("\(String(describing: ok))") }
        XCTAssertEqual(installer.selectedEngine(), .downloadedChromium)
        XCTAssertNil(installer.readRecord()?.systemChrome)
        XCTAssertFalse(c.model.usesInstalledChrome)
        XCTAssertTrue(fx.requested.value.contains("/chromium.zip"))
        XCTAssertEqual(chrome.snapshot(), before, "Chrome is untouched by turning it off")
        XCTAssertFalse(c.useDownloadedChromium { _, _ in }, "nothing to switch back from")
    }

    func testAnUpdateKeepsTheChosenBrowserAndDownloadsNoChromium() async throws {
        let fx = try FakeInstallFixture()
        guard let (c, _) = await refusedController(fx: fx) else { return }
        XCTAssertNotNil(c.requestChromeConsent())
        _ = await finish(c) { c.confirmChromeConsent(finished: $0) }
        fx.requested.value = []
        // The app now carries a newer manifest.
        let newer = fx.installer(root: root, manifest: try fx.manifest(id: "mcpfixture-2"), chromeChecker: chrome.checker())
        let c2 = controller(newer)
        XCTAssertEqual(c2.model.phase, .installed(updateAvailable: true))
        let r = await finish(c2) { c2.startInstall(finished: $0) }
        guard case .success(.installed(let id, _, _))? = r else { return XCTFail("\(String(describing: r))") }
        XCTAssertEqual(id, "mcpfixture-2")
        XCTAssertEqual(newer.selectedEngine(), .installedChrome)
        XCTAssertFalse(fx.requested.value.contains("/chromium.zip"))
        XCTAssertEqual(newer.installedChromeSelection()?.appPath, chrome.app.path)
    }

    // MARK: every start

    func testTheLauncherReChecksChromeOnEveryStartAndNeverDowngradesTheCheck() async throws {
        let fx = try FakeInstallFixture()
        let v = StubChromeVerifier()
        guard let (c, installer) = await refusedController(fx: fx, verifier: v) else { return }
        XCTAssertNotNil(c.requestChromeConsent())
        _ = await finish(c) { c.confirmChromeConsent(finished: $0) }
        XCTAssertEqual(installer.selectedEngine(), .installedChrome)

        let loc = ManagedPlaywrightLocator(root: root, chrome: chrome.checker(v))
        let base = v.calls.value
        guard case .success(let spec) = loc.locate() else { return XCTFail() }
        XCTAssertEqual(v.calls.value, base + 1, "each start is checked")
        XCTAssertTrue(spec.arguments.contains(chrome.executable.path))

        // Signature no longer valid: the browser tools stop until it passes again. There is no fall back to unchecked use.
        v.result.value = false
        guard case .failure(let e) = loc.locate() else { return XCTFail() }
        XCTAssertEqual(e.errorClass, "chrome_invalid_signature")
        v.result.value = true
        XCTAssertNotNil(try? loc.locate().get())

        // A Chrome update: the new version is picked up and shown, the check ran again.
        try chrome.write(version: "158.0.9")
        XCTAssertEqual(loc.systemChromeSummary(), .systemChrome(version: "158.0.9"))
        let b2 = v.calls.value
        XCTAssertNotNil(try? loc.locate().get())
        XCTAssertEqual(v.calls.value, b2 + 1)

        // Too old, and gone.
        try chrome.write(version: "100.0.1")
        guard case .failure(let old) = loc.locate() else { return XCTFail() }
        XCTAssertEqual(old.errorClass, "chrome_too_old")
        try FileManager.default.removeItem(at: chrome.app)
        guard case .failure(let gone) = loc.locate() else { return XCTFail() }
        XCTAssertEqual(gone.errorClass, "chrome_missing")
    }

    func testTheManagedChildReceivesTheChromeExecutableAndTheAppsOwnProfileNeverChromes() async throws {
        let fx = try FakeInstallFixture()
        guard let (c, _) = await refusedController(fx: fx) else { return }
        XCTAssertNotNil(c.requestChromeConsent())
        _ = await finish(c) { c.confirmChromeConsent(finished: $0) }

        let loc = ManagedPlaywrightLocator(root: root, chrome: chrome.checker())
        guard case .success(let spec) = loc.locate() else { return XCTFail() }
        let a = spec.arguments
        XCTAssertEqual(a[a.firstIndex(of: "--executable-path")! + 1], chrome.executable.path)
        XCTAssertEqual(a[a.firstIndex(of: "--browser")! + 1], "chromium")
        let profile = a[a.firstIndex(of: "--user-data-dir")! + 1]
        XCTAssertEqual(URL(fileURLWithPath: profile).standardizedFileURL.path, root.appendingPathComponent("profile").standardizedFileURL.path)
        for arg in a + Array(spec.environment.values) {
            XCTAssertFalse(arg.contains("Google/Chrome"), "the user's Chrome profile never reaches the child: \(arg)")
            XCTAssertFalse(arg.contains("Application Support/Google"), arg)
        }
        for banned in ["--port", "--host", "--allowed-hosts"] { XCTAssertFalse(a.contains(banned)) }
        XCTAssertFalse(a.contains("--headless"))
        // The same launch vector is built for the downloaded Chromium: only the executable differs.
        XCTAssertEqual(Array(a.dropFirst()).filter { $0.hasPrefix("--") },
                       ["--user-data-dir", "--output-dir", "--idle-timeout", "--browser", "--executable-path", "--shared-browser-context", "--caps"])
    }

    func testAHandEditedRecordCannotPointTheAppAtAnotherProgram() async throws {
        let fx = try FakeInstallFixture()
        guard let (c, _) = await refusedController(fx: fx) else { return }
        XCTAssertNotNil(c.requestChromeConsent())
        _ = await finish(c) { c.confirmChromeConsent(finished: $0) }
        let url = root.appendingPathComponent("install.json")
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        obj["systemChrome"] = ["appPath": "/tmp/evil.app", "versionAtConsent": "1"]
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        let v = StubChromeVerifier()
        guard case .failure(let e) = ManagedPlaywrightLocator(root: root, chrome: chrome.checker(v)).locate() else { return XCTFail() }
        XCTAssertEqual(e.errorClass, "chrome_not_google")
        XCTAssertEqual(v.calls.value, 0)
    }

    // MARK: status

    func testTheBackendAndTheReportSayChromeSystemWithTheBundleVersion() async throws {
        let fx = try FakeInstallFixture()
        guard let (c, _) = await refusedController(fx: fx) else { return }
        XCTAssertNotNil(c.requestChromeConsent())
        _ = await finish(c) { c.confirmChromeConsent(finished: $0) }
        let backend = PlaywrightBackend(managed: ManagedPlaywrightLocator(root: root, chrome: chrome.checker()))
        let summary = await backend.engineSummary
        XCTAssertEqual(summary?.text, "chrome: system 157.0.8103.79")
        let router = BrowserRouter(playwright: backend, store: MemoryPreferenceStore(), log: { _ in })
        let report = await router.report()
        XCTAssertEqual(report.backends.first?.engine, "chrome: system 157.0.8103.79")
        XCTAssertTrue(report.line.contains("chrome: system 157.0.8103.79"), report.line)
        XCTAssertEqual(report.json["backends"]?.arrayValue?.first?["engine"]?.stringValue, "chrome: system 157.0.8103.79")
        let text = NetworkBrowser(report: report).playwrightText
        XCTAssertTrue(text?.contains("chrome: system 157.0.8103.79") == true, text ?? "")
        await backend.shutdown()
    }

    func testTheDownloadedChromiumReportsNoEngineAndAFailingChromeSaysSo() async throws {
        let fx = try FakeInstallFixture()
        let installer = fx.installer(root: root)
        _ = await installOK(installer)
        let backend = PlaywrightBackend(managed: ManagedPlaywrightLocator(root: root, chrome: chrome.checker()))
        let none = await backend.engineSummary
        XCTAssertNil(none)
        let r = BrowserReport(preference: .auto, active: nil, backends: [.init(id: .playwright, state: "needs_setup", errorClass: "chrome_too_old", mode: "managed", ownerSummary: nil)])
        XCTAssertEqual(NetworkBrowser(report: r).playwrightText, "Playwright cannot use your Chrome (chrome_too_old)")
    }

    func testTheMenuOffersChromeOnlyAfterARefusalAndTheWayBackWhileItIsInUse() {
        let p = PlaywrightInstallPlan(manifest: .embedded, arch: .arm64, root: URL(fileURLWithPath: "/Users/someone/x/playwright"))
        func kinds(_ s: PlaywrightInstallState, offered: Bool = false, engine: BrowserEngine? = nil) -> [PlaywrightMenuItem.Kind] {
            MenuModel.playwrightMenu(state: s, plan: p, installing: nil, lastFailed: true, chromeOffered: offered, engine: engine, chromeVersion: "157.0.1").map(\.kind)
        }
        XCTAssertEqual(kinds(.notInstalled), [.setUp, .line, .install])
        XCTAssertEqual(kinds(.notInstalled, offered: true), [.setUp, .line, .install, .useChrome])
        let installed = PlaywrightInstallState.installed(id: "a", updateAvailable: false, stale: false)
        XCTAssertEqual(kinds(installed), [.setUp, .signIn, .remove])
        XCTAssertEqual(kinds(installed, engine: .installedChrome), [.setUp, .line, .useDownloaded, .signIn, .remove])
        let items = MenuModel.playwrightMenu(state: installed, plan: p, installing: nil, lastFailed: false, engine: .installedChrome, chromeVersion: "157.0.1")
        XCTAssertEqual(items.first { $0.kind == .line }?.title, "Browser: your installed Google Chrome 157.0.1 (not pinned, no digest checked)")
        XCTAssertEqual(items.first { $0.kind == .useDownloaded }?.title, "Use the downloaded Chromium instead…")
    }
}
