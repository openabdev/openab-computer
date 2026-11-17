import Foundation
import XCTest
@testable import InstanceMCPCore

/// Tests for the production wiring of the Browser tools wizard (#129): the real `BrowserToolsController`, the
/// functions `main.swift` and `StatusItemController` call, and a guard that those call sites still call them.
/// Nothing here opens a window or launches an app; the installer runs against the local fake release.
@MainActor
final class BrowserWizardWiringTests: InstallerTestCase {
    private func store() -> BrowserToolsStore {
        let name = "oab-wiring-test-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return BrowserToolsStore(defaults: UserDefaults(suiteName: name)!)
    }

    private func hangingDownloader() -> ScriptedDownloader {
        ScriptedDownloader(
            inner: URLSessionArtifactDownloader(policy: DownloadPolicy(allowedHosts: [], allowLoopbackHTTP: true), requestTimeout: 10),
            hang: true)
    }

    private func controller(_ installer: PlaywrightInstaller, upstreams: [(String, URL)] = [],
                            store s: BrowserToolsStore? = nil) -> BrowserToolsController {
        BrowserWizardWiring.makeController(upstreams: upstreams, installer: installer, store: s ?? store(),
                                           signIn: { _, _ in .null }, log: { _ in })
    }

    private let external: [(String, URL)] = [("browser", URL(string: "http://127.0.0.1:8794/mcp")!)]
    private let otherUpstream: [(String, URL)] = [("docs", URL(string: "http://127.0.0.1:9000/mcp")!)]

    // MARK: BrowserToolsController.remove()

    func testRemoveReReadsTheStateAfterRemovalAndReportsRemoved() async throws {
        let fx = try FakeInstallFixture()
        let installer = fx.installer(root: root)
        let installed = await installOK(installer)
        XCTAssertNotNil(installed)
        let c = controller(installer)
        XCTAssertEqual(c.model.phase, .installed(updateAvailable: false), "the controller starts from the installed state")

        let outcome = await c.remove()

        XCTAssertEqual(outcome, .removed, "state after removal is notInstalled and the folder is gone")
        XCTAssertEqual(c.installState, .notInstalled)
        XCTAssertEqual(c.model.phase, .idle, "the model is synced to the state read after removal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRemoveReportsPartialWhenSomethingItDoesNotOwnRemainsInTheFolder() async throws {
        let fx = try FakeInstallFixture()
        let installer = fx.installer(root: root)
        _ = await installOK(installer)
        let c = controller(installer)
        try Data("mine".utf8).write(to: root.appendingPathComponent("keep.txt"))

        let outcome = await c.remove()

        XCTAssertEqual(c.installState, .notInstalled, "install.json is gone")
        XCTAssertEqual(outcome, .partial, "the folder still exists, so the outcome is not .removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("keep.txt").path))
    }

    func testRemoveWhileAnInstallRunsReturnsFailedAndTouchesNothing() async throws {
        // Documents today's behavior (#129, "Remove during a running install shows the wrong reason"): `.failed`.
        let fx = try FakeInstallFixture()
        let dl = hangingDownloader()
        let installer = fx.installer(root: root, downloader: dl)
        let c = controller(installer)
        let finished = MutableBox(0)
        XCTAssertTrue(c.startInstall { _, _ in finished.value += 1 })
        let started = await waitFor { dl.calls.value >= 1 }
        XCTAssertTrue(started)

        let outcome = await c.remove()

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(c.model.isInstalling, "the install is still running")
        c.cancelInstall()
        let done = await waitFor { finished.value == 1 }
        XCTAssertTrue(done)
    }

    // MARK: BrowserToolsController.startInstall()

    func testStartInstallRefusesASecondInstallAndRunInstallIsNotStartedTwice() async throws {
        let fx = try FakeInstallFixture()
        let dl = hangingDownloader()
        let c = controller(fx.installer(root: root, downloader: dl))
        let finished = MutableBox<[String]>([])

        XCTAssertTrue(c.startInstall { _, _ in finished.value += ["first"] })
        let started = await waitFor { dl.calls.value >= 1 }
        XCTAssertTrue(started, "the first install reached the downloader")

        let second = c.startInstall { _, _ in finished.value += ["second"] }
        XCTAssertFalse(second, "the guard on model.beginInstall() refuses it")
        try await Task.sleep(nanoseconds: 300_000_000)
        // A second runInstall would end at once with `.lockHeld` and call its `finished`.
        XCTAssertEqual(finished.value, [], "no second runInstall ran and the first is still going")
        XCTAssertEqual(dl.calls.value, 1)

        c.cancelInstall()
        let done = await waitFor { finished.value.count == 1 }
        XCTAssertTrue(done)
        XCTAssertEqual(finished.value, ["first"])
    }

    // MARK: main.swift: the controller exists for every `--upstream` configuration

    func testControllerIsCreatedWithAnExternalProviderAndFlagsTheModel() throws {
        let fx = try FakeInstallFixture()
        let c = controller(fx.installer(root: root), upstreams: external)
        XCTAssertTrue(c.model.externalProvider, "the page shows the external-provider note")
        XCTAssertEqual(c.model.phase, .idle, "the Browser tools page is still offered, install box included")
        XCTAssertTrue(c.model.checked)
        XCTAssertEqual(c.plan.installPath, root.path)
    }

    func testControllerWithoutAnExternalProviderHasNoNote() throws {
        let fx = try FakeInstallFixture()
        XCTAssertFalse(controller(fx.installer(root: root), upstreams: []).model.externalProvider)
        XCTAssertFalse(controller(fx.installer(root: root), upstreams: otherUpstream).model.externalProvider,
                       "only the upstream named browser counts")
    }

    // MARK: main.swift: verifyServing in external-provider mode (documented behavior, not changed here)

    func testVerifyServingIsSkippedInExternalProviderMode() async {
        let asked = MutableBox(0)
        let ok = await BrowserWizardWiring.verifyServing(upstreams: external) { asked.value += 1; return false }
        XCTAssertTrue(ok, "an update commits without a serving check, so its rollback cannot run (#129, LOW)")
        XCTAssertEqual(asked.value, 0, "the managed backend is not even asked")
    }

    func testVerifyServingAsksTheManagedBackendOtherwise() async {
        let ready = await BrowserWizardWiring.verifyServing(upstreams: otherUpstream) { true }
        let notReady = await BrowserWizardWiring.verifyServing(upstreams: []) { false }
        XCTAssertTrue(ready)
        XCTAssertFalse(notReady)
    }

    // MARK: StatusItemController.showPermissionSetupIfNeeded(): the automatic setup path

    func testAutoSetupOpensTheBrowserPageUntilItIsCompleted() throws {
        let fx = try FakeInstallFixture()
        let c = controller(fx.installer(root: root))
        XCTAssertEqual(BrowserWizardPolicy.pageOnAutoSetup(allGranted: true, browserTools: c), .browser)

        c.pageCompleted(.declined)

        XCTAssertTrue(c.pageIsCompleted)
        XCTAssertNil(BrowserWizardPolicy.pageOnAutoSetup(allGranted: true, browserTools: c),
                     "the controller's own completion flag decides")
    }

    func testAutoSetupReadsCompletionFromTheStoreTheControllerUses() throws {
        let fx = try FakeInstallFixture()
        let s = store()
        let c = controller(fx.installer(root: root), store: s)
        s.setPageCompleted()
        XCTAssertNil(BrowserWizardPolicy.pageOnAutoSetup(allGranted: true, browserTools: c))
    }

    func testAutoSetupOpensNothingWithoutAControllerOrWithPermissionsMissing() throws {
        let fx = try FakeInstallFixture()
        let c = controller(fx.installer(root: root))
        XCTAssertNil(BrowserWizardPolicy.pageOnAutoSetup(allGranted: true, browserTools: nil))
        XCTAssertNil(BrowserWizardPolicy.pageOnAutoSetup(allGranted: false, browserTools: c))
    }

    func testClosingThePageWithoutCompletingItDoesNotCompleteIt() throws {
        // Documents R5.1/R5.10 as written (#129, LOW): offered again on every launch until completed.
        let fx = try FakeInstallFixture()
        let s = store()
        let c = controller(fx.installer(root: root), store: s)
        c.pageShown()
        XCTAssertEqual(s.offer, .offered)
        XCTAssertEqual(BrowserWizardPolicy.pageOnAutoSetup(allGranted: true, browserTools: c), .browser)
    }

    // MARK: the call sites still call what the tests above exercise

    /// `main.swift` is top-level code and `StatusItemController` is AppKit, so neither can be run here. This reads
    /// their source and fails if a call site stops using the tested function (the original R5.1 regression was a call
    /// site that omitted the controller).
    func testTheProductionCallSitesStillUseTheTestedFunctions() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ rel: String) throws -> String {
            try String(contentsOf: repo.appendingPathComponent(rel), encoding: .utf8)
        }
        let main = try source("Sources/oab-computer/main.swift")
        XCTAssertNotNil(
            main.range(of: #"let browserTools: BrowserToolsController\? = MainActor\.assumeIsolated \{\s*BrowserWizardWiring\.makeController\("#,
                       options: .regularExpression),
            "main.swift builds the controller unconditionally through the wiring")
        XCTAssertTrue(main.contains("upstreams: opts.upstreams, installer: playwrightInstaller"),
                      "the controller is built from every configured upstream, not only when browser= is absent")
        XCTAssertTrue(main.contains("BrowserWizardWiring.verifyServing(upstreams: opts.upstreams"))
        XCTAssertFalse(main.contains("BrowserToolsController("), "no second, unwired construction")
        XCTAssertFalse(main.contains("opts.upstreams.contains(where: { $0.0 == \"browser\" }) ? true"),
                       "the serving check goes through the tested function")
        let status = try source("Sources/oab-computer/StatusItemController.swift")
        XCTAssertNotNil(
            status.range(of: #"if let page = BrowserWizardPolicy\.pageOnAutoSetup\(allGranted: true, browserTools: browserTools\) \{\s*openPermissionSetup\(page: page\)\s*\}"#,
                         options: .regularExpression),
            "the automatic setup path asks the policy and opens the page it returns")
    }
}
