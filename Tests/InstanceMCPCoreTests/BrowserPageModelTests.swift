import Foundation
import XCTest
@testable import InstanceMCPCore

final class BrowserPageModelTests: XCTestCase {
    private let installed = PlaywrightInstallState.installed(id: "v1", updateAvailable: false, stale: false)
    private func fresh() -> BrowserPageModel { BrowserPageModel(installState: .notInstalled) }
    private func installing() -> BrowserPageModel {
        var m = fresh()
        XCTAssertEqual(m.continuePressed(), .startInstall)
        return m
    }

    // MARK: start

    func testThePlaywrightBoxIsPreCheckedAndContinueIsEnabled() {
        let m = fresh()
        XCTAssertTrue(m.checked)
        XCTAssertEqual(m.phase, .idle)
        XCTAssertTrue(m.footer.continueEnabled)
        XCTAssertFalse(m.footer.showsRetry)
        XCTAssertFalse(m.footer.showsContinueWithout, "Continue without exists only after a failure")
        XCTAssertFalse(m.footer.showsCancel)
        XCTAssertEqual(BrowserPageModel(installState: .invalid).phase, .idle)
        XCTAssertTrue(BrowserPageModel(installState: .invalid).checked)
    }

    func testAnInstalledPlaywrightStartsInstalledAndUnchecked() {
        let m = BrowserPageModel(installState: .installed(id: "a", updateAvailable: true, stale: false))
        XCTAssertEqual(m.phase, .installed(updateAvailable: true))
        XCTAssertFalse(m.checked)
        XCTAssertTrue(m.footer.showsSignIn)
        var n = m
        XCTAssertEqual(n.continuePressed(), .complete(.installed))
    }

    // MARK: install

    func testContinueWithTheBoxCheckedStartsTheInstallAndLocksTheFooter() {
        var m = fresh()
        XCTAssertEqual(m.continuePressed(), .startInstall)
        XCTAssertTrue(m.isInstalling)
        XCTAssertFalse(m.footer.continueEnabled)
        XCTAssertTrue(m.footer.showsCancel)
        XCTAssertFalse(m.footer.checkboxEnabled)
        XCTAssertFalse(m.footer.showsRetry)
        XCTAssertFalse(m.footer.showsContinueWithout)
        XCTAssertEqual(m.continuePressed(), .none, "a second press while installing does nothing")
        m.setChecked(false)
        XCTAssertTrue(m.checked, "the box is locked while installing")
    }

    func testProgressIsKeptOnlyWhileInstalling() {
        var m = installing()
        let p = PlaywrightInstallProgress(step: .downloadNode, fraction: 0.5)
        m.progress(p)
        XCTAssertEqual(m.phase, .installing(p))
        var idle = fresh()
        idle.progress(p)
        XCTAssertEqual(idle.phase, .idle)
    }

    func testASuccessfulInstallCompletesThePage() {
        var m = installing()
        let step = m.finished(.success(installed))
        XCTAssertEqual(step, .complete(.installed))
        XCTAssertEqual(m.phase, .installed(updateAvailable: false))
        XCTAssertFalse(m.checked)
    }

    func testUncheckingIsAnExplicitDeclineThatCompletesThePage() {
        var m = fresh()
        m.setChecked(false)
        XCTAssertTrue(m.footer.continueEnabled)
        XCTAssertEqual(m.continuePressed(), .complete(.declined))
        XCTAssertEqual(BrowserPageModel.offer(after: .declined), .declined)
        XCTAssertFalse(m.isInstalling)
    }

    // MARK: failure

    func testEveryFailureShowsRetryAndContinueWithoutOnlyNow() {
        let failures: [PlaywrightInstallFailure] = [
            .offline, .interrupted, .tls, .digestMismatch, .notEnoughDisk(needed: 5, available: 1),
            .archiveRejected, .nodeSignature, .launchRefused, .lockHeld, .healthCheckFailed, .other("x_y"),
        ]
        for f in failures {
            var m = installing()
            XCTAssertEqual(m.finished(.failure(f)), .none, "\(f)")
            XCTAssertEqual(m.failure, f)
            XCTAssertTrue(m.footer.showsRetry, "\(f)")
            XCTAssertTrue(m.footer.showsContinueWithout, "\(f)")
            XCTAssertFalse(m.footer.showsContinue, "\(f)")
            XCTAssertFalse(m.footer.showsCancel)
            XCTAssertFalse(WizardCopy.installFailure(f).isEmpty)
        }
    }

    func testContinueWithoutCompletesAfterAFailureAndNotBefore() {
        var m = fresh()
        XCTAssertEqual(m.continueWithoutPressed(), .none)
        _ = m.continuePressed()
        XCTAssertEqual(m.continueWithoutPressed(), .none, "not while installing")
        _ = m.finished(.failure(.offline))
        XCTAssertEqual(m.continueWithoutPressed(), .complete(.continuedWithout))
        XCTAssertEqual(BrowserPageModel.offer(after: .continuedWithout), .failed)
    }

    func testRetryRestartsTheInstall() {
        var m = installing()
        _ = m.finished(.failure(.interrupted))
        XCTAssertEqual(m.retryPressed(), .startInstall)
        XCTAssertTrue(m.isInstalling)
        XCTAssertEqual(m.retryPressed(), .none)
    }

    func testCancelGoesBackToTheCheckedRowWithoutAFailure() {
        var m = installing()
        XCTAssertTrue(m.cancelPressed())
        XCTAssertEqual(m.finished(.failure(.cancelled)), .none)
        XCTAssertEqual(m.phase, .idle)
        XCTAssertTrue(m.checked)
        XCTAssertNil(m.failure)
        XCTAssertFalse(m.cancelPressed())
    }

    func testUncheckingAfterAFailureTurnsItIntoAPlainDecline() {
        var m = installing()
        _ = m.finished(.failure(.offline))
        m.setChecked(false)
        XCTAssertEqual(m.phase, .idle)
        XCTAssertFalse(m.footer.showsContinueWithout)
        XCTAssertEqual(m.continuePressed(), .complete(.declined))
    }

    func testAResultThatArrivesWithNoInstallRunningIsIgnored() {
        var m = fresh()
        XCTAssertEqual(m.finished(.success(installed)), .none)
        XCTAssertEqual(m.phase, .idle)
    }

    // MARK: menu-started installs and sync

    func testTheMenuCanStartAnInstallAndAnUpdateButNotTwo() {
        var m = fresh()
        XCTAssertTrue(m.beginInstall())
        XCTAssertFalse(m.beginInstall())
        var u = BrowserPageModel(installState: .installed(id: "a", updateAvailable: true, stale: false))
        XCTAssertTrue(u.beginInstall())
        _ = u.finished(.failure(.offline))
        u.sync(.installed(id: "a", updateAvailable: true, stale: false))
        XCTAssertEqual(u.phase, .installed(updateAvailable: true), "a failed update leaves the old install showing")
    }

    func testSyncFollowsTheDiskUnlessAnInstallRuns() {
        var m = installing()
        m.sync(.notInstalled)
        XCTAssertTrue(m.isInstalling)
        var r = BrowserPageModel(installState: .installed(id: "a", updateAvailable: false, stale: false))
        r.sync(.notInstalled)
        XCTAssertEqual(r.phase, .idle, "removed from the menu")
        XCTAssertTrue(r.checked)
        var f = fresh()
        f.sync(.installed(id: "a", updateAvailable: false, stale: false))
        XCTAssertEqual(f.phase, .installed(updateAvailable: false))
    }

    // MARK: stored values

    func testStoredValuesRoundTripAndUnknownValuesResetWithAKeyOnlyLog() {
        let suite = "oab.browser.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        final class Box: @unchecked Sendable { var lines: [String] = [] }
        let box = Box()
        let store = BrowserToolsStore(defaults: d, log: { box.lines.append($0) })
        XCTAssertNil(store.offer)
        store.recordOfferedIfNew()
        XCTAssertEqual(store.offer, .offered)
        store.record(.declined)
        store.recordOfferedIfNew()
        XCTAssertEqual(store.offer, .declined, "a later answer is not overwritten by offered")
        XCTAssertFalse(store.pageCompleted)
        store.setPageCompleted()
        XCTAssertTrue(store.pageCompleted)

        d.set("garbage-value", forKey: BrowserToolsStore.offerKey)
        XCTAssertNil(store.offer)
        XCTAssertNil(d.object(forKey: BrowserToolsStore.offerKey))
        d.set("nope", forKey: BrowserToolsStore.pageCompletedKey)
        XCTAssertFalse(store.pageCompleted)
        XCTAssertEqual(box.lines, ["browser: pref_reset key=browserTools.playwrightOffer.v1",
                                   "browser: pref_reset key=browserTools.pageCompleted.v1"])
        for l in box.lines { XCTAssertFalse(l.contains("garbage")); XCTAssertFalse(l.contains("nope")) }
    }

    // MARK: sign-in

    func testSignInCallsBrowserNavigateOnceToABlankPageAndLogsOnlyTheFact() async {
        final class Seen: @unchecked Sendable { var calls: [(String, JSONValue)] = []; var lines: [String] = [] }
        let seen = Seen()
        let outcome = await PlaywrightSignIn.open(call: { name, args in
            seen.calls.append((name, args)); return .object(["content": .array([])])
        }, log: { seen.lines.append($0) })
        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(seen.calls.count, 1)
        XCTAssertEqual(seen.calls[0].0, "browser_navigate")
        XCTAssertEqual(seen.calls[0].1, .object(["url": .string("about:blank")]))
        XCTAssertEqual(seen.lines, ["browser: signin_opened"])
    }

    func testSignInFailuresAreFixedClassesWithNoUpstreamText() async {
        final class Lines: @unchecked Sendable { var l: [String] = [] }
        let lines = Lines()
        let a = await PlaywrightSignIn.open(call: { _, _ in throw BrowserBackendError("playwright_not_installed", setupLost: true) },
                                            log: { lines.l.append($0) })
        XCTAssertEqual(a, .failed("playwright_not_installed"))
        let b = await PlaywrightSignIn.open(call: { _, _ in .object(["isError": .bool(true), "content": .string("secret page text")]) },
                                            log: { lines.l.append($0) })
        XCTAssertEqual(b, .failed("playwright_tool_error"))
        struct Boom: Error, CustomStringConvertible { var description: String { "https://x.example/?token=SECRET" } }
        let c = await PlaywrightSignIn.open(call: { _, _ in throw Boom() }, log: { lines.l.append($0) })
        XCTAssertEqual(c, .failed("signin_failed"))
        let pattern = try! NSRegularExpression(pattern: "^browser: [a-z_]+( [a-z]+=[A-Za-z0-9_.-]+)*$")
        for l in lines.l {
            XCTAssertNotNil(pattern.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), l)
            XCTAssertFalse(l.contains("SECRET")); XCTAssertFalse(l.contains("secret"))
        }
    }
}

final class BrowserCopyAndMenuTests: XCTestCase {
    private func plan() -> PlaywrightInstallPlan {
        PlaywrightInstallPlan(manifest: .embedded, arch: .arm64, root: URL(fileURLWithPath: "/Users/someone/Library/Application Support/oab-computer/playwright"))
    }

    func testTheConsentTextCarriesThePlansNumbersHostsAndPathAndNeverCallsItSafe() {
        let p = plan()
        let text = WizardCopy.playwrightConsent(plan: p, home: "/Users/someone")
        XCTAssertTrue(text.contains(WizardCopy.megabytes(p.downloadBytes)), text)
        XCTAssertTrue(text.contains(WizardCopy.megabytes(p.diskBytes)), text)
        for h in p.hosts { XCTAssertTrue(text.contains(h), "\(h) in \(text)") }
        XCTAssertTrue(text.contains("~/Library/Application Support/oab-computer/playwright"), text)
        XCTAssertTrue(text.contains("Uncheck to skip it"), "says where to uncheck")
        XCTAssertTrue(text.contains("checked against values built into this app"))
        XCTAssertTrue(text.contains("not your Chrome or Safari"))
        XCTAssertNil(text.range(of: "\\bsafe(ly)?\\b", options: [.regularExpression, .caseInsensitive]), "never calls the result safe")
        XCTAssertGreaterThan(p.downloadBytes, 0)
    }

    func testMegabytesRoundUpAndTheHomeDirectoryIsShortened() {
        XCTAssertEqual(WizardCopy.megabytes(1), "1 MB")
        XCTAssertEqual(WizardCopy.megabytes(1_000_000), "1 MB")
        XCTAssertEqual(WizardCopy.megabytes(1_000_001), "2 MB")
        XCTAssertEqual(WizardCopy.megabytes(0), "0 MB")
        XCTAssertEqual(WizardCopy.displayPath("/Users/a/x", home: "/Users/a"), "~/x")
        XCTAssertEqual(WizardCopy.displayPath("/Users/ab/x", home: "/Users/a"), "/Users/ab/x")
        XCTAssertEqual(WizardCopy.joinNames(["a", "b", "c"]), "a, b and c")
    }

    func testEveryFailureHasItsR73Message() {
        XCTAssertEqual(WizardCopy.installFailure(.offline), "No internet connection. Playwright was not installed. Connect and press Retry, or Continue without it and install later from the menu.")
        XCTAssertEqual(WizardCopy.installFailure(.digestMismatch), "A download did not match what this app expects. Nothing was installed.")
        XCTAssertEqual(WizardCopy.installFailure(.archiveRejected), "An archive had unsafe contents. Nothing was installed.")
        XCTAssertTrue(WizardCopy.installFailure(.nodeSignature).hasPrefix("The downloaded Node.js failed its signature check."))
        XCTAssertTrue(WizardCopy.installFailure(.launchRefused).hasPrefix("macOS would not run the downloaded browser."))
        XCTAssertEqual(WizardCopy.installFailure(.lockHeld), "Another install is running.")
        XCTAssertTrue(WizardCopy.installFailure(.tls).hasPrefix("A secure connection could not be made."))
        XCTAssertEqual(WizardCopy.installFailure(.notEnoughDisk(needed: 3_000_000_000, available: 1_500_000_000)),
                       "Not enough free space: needs 3000 MB, has 1500 MB.")
        XCTAssertTrue(WizardCopy.installFailure(.other("bad_class")).contains("bad_class"))
        XCTAssertTrue(WizardCopy.installFailure(.other("https://evil/?t=1")).contains("unknown"), "free text never reaches the user")
    }

    func testTheWizardPagesAreOrderedAndTheBrowserPageResumes() {
        XCTAssertEqual(WizardModel.available(.browser, tailnetOffered: false), .browser)
        XCTAssertEqual(WizardModel.available(.browser, tailnetOffered: true), .browser)
        XCTAssertEqual(WizardModel.available(.browser, tailnetOffered: false, browserPage: false), .optional)
        XCTAssertEqual(WizardPage(rawValue: "browser"), .browser)
        let suite = "oab.resume.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let store = SetupWizardStore(defaults: d)
        store.recordRelaunch(page: .browser)
        XCTAssertEqual(store.consumeRelaunch()?.page, .browser)
    }

    func testTheMenuItemsFollowTheInstallState() {
        let p = plan()
        func kinds(_ s: PlaywrightInstallState, installing: PlaywrightInstallProgress?? = nil, failed: Bool = false) -> [PlaywrightMenuItem.Kind] {
            MenuModel.playwrightMenu(state: s, plan: p, installing: installing, lastFailed: failed).map(\.kind)
        }
        XCTAssertEqual(kinds(.notInstalled), [.setUp, .install])
        XCTAssertEqual(kinds(.notInstalled, failed: true), [.setUp, .line, .install])
        XCTAssertEqual(kinds(.invalid), [.setUp, .line, .install, .remove])
        XCTAssertEqual(kinds(.installed(id: "a", updateAvailable: false, stale: false)), [.setUp, .signIn, .remove])
        XCTAssertEqual(kinds(.installed(id: "a", updateAvailable: true, stale: true)), [.setUp, .signIn, .update, .line, .remove])
        XCTAssertEqual(kinds(.installed(id: "a", updateAvailable: true, stale: false), installing: .some(nil)), [.setUp, .line, .cancelInstall],
                       "while installing only Cancel is an action")
    }

    func testTheUpdateItemNamesTheChangeAndTheMenuNeverCarriesAUrlOrPageText() {
        let p = plan()
        let items = MenuModel.playwrightMenu(state: .installed(id: "old-1", updateAvailable: true, stale: true), plan: p,
                                             installing: nil, lastFailed: false)
        let update = items.first { $0.kind == .update }
        XCTAssertEqual(update?.title, "Update Playwright… (old-1 → \(p.id))")
        XCTAssertEqual(items.first { $0.kind == .signIn }?.title, "Open Playwright window to sign in…")
        for i in items { XCTAssertFalse((i.title + (i.tip ?? "")).contains("http"), i.title) }
        let progress = MenuModel.playwrightMenu(state: .notInstalled, plan: p,
                                                installing: .some(PlaywrightInstallProgress(step: .downloadNode, fraction: 0.42)), lastFailed: false)
        XCTAssertTrue(progress.contains { $0.title == "Playwright: installing… 42%" })
    }

    func testTheUpdatePromptIsNeverSilentAndNamesWhatIsDownloaded() {
        let p = plan()
        let text = WizardCopy.updatePrompt(installed: "old-1", plan: p, home: "/Users/someone")
        XCTAssertTrue(text.contains("old-1")); XCTAssertTrue(text.contains(p.id))
        XCTAssertTrue(text.contains(WizardCopy.megabytes(p.downloadBytes)))
        XCTAssertTrue(text.contains("keeps working"))
    }

    func testRemovalNamesTheProfileAndWhatItDoesNotTouch() {
        let t = WizardCopy.removalConfirmation(path: "/Users/someone/x/playwright", home: "/Users/someone")
        XCTAssertTrue(t.contains("browser profile")); XCTAssertTrue(t.contains("cookies"))
        XCTAssertTrue(t.contains("does not touch Chrome, Safari or ~/.local/oab-computer/"))
        XCTAssertTrue(t.contains("~/x/playwright"))
    }

    func testProgressTextCoversEveryStep() {
        let steps: [PlaywrightInstallStep] = [.preflight, .downloadNode, .downloadChromium, .extract, .signature, .packages, .healthCheck, .commit, .switchOver]
        for s in steps { XCTAssertFalse(WizardCopy.stepText(PlaywrightInstallProgress(step: s, fraction: nil)).isEmpty) }
        XCTAssertEqual(WizardCopy.stepText(PlaywrightInstallProgress(step: .downloadNode, fraction: 1.7)), "Downloading Node.js… 100%")
    }
}
