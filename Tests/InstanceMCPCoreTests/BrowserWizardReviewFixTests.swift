import Foundation
import XCTest
@testable import InstanceMCPCore

final class BrowserWizardReviewFixTests: XCTestCase {
    private let installed = PlaywrightInstallState.installed(id: "v1", updateAvailable: false, stale: false)
    private func fresh() -> BrowserPageModel { BrowserPageModel(installState: .notInstalled) }
    private func installing() -> BrowserPageModel {
        var m = fresh()
        XCTAssertEqual(m.continuePressed(), .startInstall)
        return m
    }

    // MARK: review fixes (PR 127)

    func testRemovalOutcomeIsTruthfulAboutWhatIsLeft() {
        typealias O = PlaywrightRemovalOutcome
        XCTAssertEqual(O.classify(result: .success(()), state: .notInstalled, folderRemains: false), .removed)
        XCTAssertEqual(O.classify(result: .success(()), state: .invalid, folderRemains: true), .partial, "a foreign install.json stays")
        XCTAssertEqual(O.classify(result: .success(()), state: .notInstalled, folderRemains: true), .partial, "a foreign profile stays")
        XCTAssertEqual(O.classify(result: .success(()), state: installed, folderRemains: true), .partial)
        XCTAssertEqual(O.classify(result: .failure(.lockHeld), state: .notInstalled, folderRemains: false), .failed)
        let home = "/Users/someone"
        XCTAssertEqual(WizardCopy.removalMessage(.removed, path: "/Users/someone/p", home: home), WizardCopy.removalDone)
        XCTAssertEqual(WizardCopy.removalMessage(.failed, path: "/Users/someone/p", home: home), WizardCopy.removalFailed)
        let partial = WizardCopy.removalMessage(.partial, path: "/Users/someone/p", home: home)
        XCTAssertTrue(partial.contains("partly")); XCTAssertTrue(partial.contains("~/p"))
        XCTAssertNotEqual(partial, WizardCopy.removalDone)
    }

    func testTheExternalProviderFlagIsKeptAndTheNoteNamesThePreferredTier() {
        XCTAssertFalse(fresh().externalProvider)
        let m = BrowserPageModel(installState: .notInstalled, externalProvider: true)
        XCTAssertTrue(m.externalProvider)
        XCTAssertEqual(m.phase, .idle, "the page still offers the install")
        XCTAssertTrue(m.footer.continueEnabled)
        let note = WizardCopy.browserExternalProviderNote
        XCTAssertTrue(note.contains("--upstream browser=")); XCTAssertTrue(note.contains("use it first"))
        XCTAssertTrue(note.contains("Apple Events"))
    }

    func testSignInIsHiddenWhileAnExternalProviderIsConfigured() {
        let installed = PlaywrightInstallState.installed(id: "a", updateAvailable: false, stale: false)
        XCTAssertTrue(BrowserPageModel(installState: installed).footer.showsSignIn)
        XCTAssertFalse(BrowserPageModel(installState: installed, externalProvider: true).footer.showsSignIn)
        let plan = PlaywrightInstallPlan(manifest: .embedded, arch: .arm64, root: URL(fileURLWithPath: "/Users/someone/Library/Application Support/oab-computer/playwright"))
        func kinds(_ ext: Bool) -> [PlaywrightMenuItem.Kind] {
            MenuModel.playwrightMenu(state: installed, plan: plan, installing: nil, lastFailed: false,
                                     externalProvider: ext).map(\.kind)
        }
        XCTAssertTrue(kinds(false).contains(.signIn))
        XCTAssertFalse(kinds(true).contains(.signIn))
        XCTAssertTrue(kinds(true).contains(.remove))
    }

    func testTheBrowserPageIsOfferedWhenPermissionsAreAlreadyGrantedUntilCompleted() {
        let f = BrowserWizardPolicy.showsBrowserPageOnAutoSetup
        XCTAssertTrue(f(true, true, false))
        XCTAssertFalse(f(true, true, true), "completed once: no repeat")
        XCTAssertFalse(f(true, false, false), "no browser tools controller")
        XCTAssertFalse(f(false, true, false), "missing permissions use the normal path")
    }

    func testPageCompletedFlagDrivesTheAutoSetupDecision() {
        let d = UserDefaults(suiteName: "browser-auto-\(UUID().uuidString)")!
        let store = BrowserToolsStore(defaults: d)
        XCTAssertTrue(BrowserWizardPolicy.showsBrowserPageOnAutoSetup(allGranted: true, browserOffered: true, pageCompleted: store.pageCompleted))
        store.setPageCompleted()
        XCTAssertFalse(BrowserWizardPolicy.showsBrowserPageOnAutoSetup(allGranted: true, browserOffered: true, pageCompleted: store.pageCompleted))
    }

    func testBeginInstallRefusesASecondInstallSoNothingFallsThroughToRun() {
        var m = fresh()
        XCTAssertTrue(m.beginInstall())
        XCTAssertFalse(m.beginInstall(), "startInstall guards on this and returns before runInstall")
        XCTAssertTrue(m.isInstalling)
    }

    func testTheCheckboxIsHiddenOnceInstalled() {
        XCTAssertFalse(BrowserPageModel(installState: installed).footer.showsCheckbox)
        XCTAssertTrue(fresh().footer.showsCheckbox)
        XCTAssertTrue(installing().footer.showsCheckbox)
        var f = installing()
        _ = f.finished(.failure(.offline))
        XCTAssertTrue(f.footer.showsCheckbox)
    }
}
