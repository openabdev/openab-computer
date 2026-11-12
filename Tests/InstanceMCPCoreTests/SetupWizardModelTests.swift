import Foundation
import XCTest
@testable import InstanceMCPCore

final class SetupGateTests: XCTestCase {
    private func snap(_ sr: PermissionState, _ ax: PermissionState, _ fda: PermissionState) -> PermissionSnapshot {
        PermissionSnapshot(screenRecording: sr, accessibility: ax, fullDiskAccess: fda)
    }

    func testGateBlocksUntilBothCorePermissionsAreGranted() {
        let states: [PermissionState] = [.granted, .denied, .unknown]
        for sr in states {
            for ax in states {
                for fda in states {
                    let gate = SetupGate.evaluate(snapshot: snap(sr, ax, fda))
                    let missing = PermissionKind.coreKinds.filter { !snap(sr, ax, fda)[$0].isGranted }
                    if missing.isEmpty {
                        XCTAssertFalse(gate.blocksCore, "core granted must not block: \(sr) \(ax) \(fda)")
                    } else {
                        XCTAssertEqual(gate, .blockedOnCore(missing: missing), "\(sr) \(ax) \(fda)")
                    }
                }
            }
        }
    }

    func testOnlyFullDiskAccessMissingIsOptionalPending() {
        XCTAssertEqual(SetupGate.evaluate(snapshot: snap(.granted, .granted, .denied)), .optionalPending)
        XCTAssertEqual(SetupGate.evaluate(snapshot: snap(.granted, .granted, .unknown)), .optionalPending)
    }

    func testAllGrantedIsComplete() {
        XCTAssertEqual(SetupGate.evaluate(snapshot: snap(.granted, .granted, .granted)), .complete)
    }

    func testAdHocBuildUsesOnlyTheCoreGrants() {
        // The gate takes no signing input, so an ad-hoc build with both core grants passes just like a release build.
        let adHocGranted = snap(.granted, .granted, .unknown)
        XCTAssertFalse(SetupGate.evaluate(snapshot: adHocGranted).blocksCore)
        XCTAssertTrue(SetupGate.evaluate(snapshot: snap(.denied, .granted, .granted)).blocksCore)
    }
}

final class SetupWizardPageTests: XCTestCase {
    private let coreGranted = PermissionSnapshot(screenRecording: .granted, accessibility: .granted,
                                                 fullDiskAccess: .denied)
    private let coreMissing = PermissionSnapshot(screenRecording: .denied, accessibility: .granted,
                                                 fullDiskAccess: .denied)

    func testPageOneHasNoSkipForAnySnapshot() {
        let states: [PermissionState] = [.granted, .denied, .unknown]
        for sr in states {
            for ax in states {
                for fda in states {
                    let s = PermissionSnapshot(screenRecording: sr, accessibility: ax, fullDiskAccess: fda)
                    if case .skip = WizardModel.footerAction(page: .core, snapshot: s) {
                        XCTFail("page 1 must never show Skip: \(s)")
                    }
                }
            }
        }
    }

    func testPageTwoShowsSkipUntilFullDiskAccessIsGranted() {
        XCTAssertEqual(WizardModel.footerAction(page: .optional, snapshot: coreGranted), .skip)
        let unknown = PermissionSnapshot(screenRecording: .granted, accessibility: .granted, fullDiskAccess: .unknown)
        XCTAssertEqual(WizardModel.footerAction(page: .optional, snapshot: unknown), .skip)
        let fdaGranted = PermissionSnapshot(screenRecording: .granted, accessibility: .granted, fullDiskAccess: .granted)
        XCTAssertEqual(WizardModel.footerAction(page: .optional, snapshot: fdaGranted), .done)
    }

    func testContinueIsEnabledOnlyWhenBothCoreAreGranted() {
        XCTAssertEqual(WizardModel.footerAction(page: .core, snapshot: coreGranted),
                       .continueToOptional(enabled: true))
        XCTAssertEqual(WizardModel.footerAction(page: .core, snapshot: coreMissing),
                       .continueToOptional(enabled: false))
    }

    func testRowStateFollowsAllowAndReturn() {
        XCTAssertEqual(WizardModel.rowState(state: .denied, requested: false, returnedSinceRequest: false), .notAllowed)
        XCTAssertEqual(WizardModel.rowState(state: .denied, requested: true, returnedSinceRequest: false), .waiting)
        XCTAssertEqual(WizardModel.rowState(state: .denied, requested: true, returnedSinceRequest: true), .stillOff)
        XCTAssertEqual(WizardModel.rowState(state: .granted, requested: false, returnedSinceRequest: false), .allowed)
        XCTAssertEqual(WizardModel.rowState(state: .unknown, requested: false, returnedSinceRequest: false), .cantTest)
    }

    func testRowButtonsMatchRowState() {
        XCTAssertEqual(WizardModel.rowButton(for: .notAllowed), .allow)
        XCTAssertEqual(WizardModel.rowButton(for: .waiting), .allow)
        XCTAssertEqual(WizardModel.rowButton(for: .stillOff), .openSettings)
        XCTAssertEqual(WizardModel.rowButton(for: .cantTest), .openSettings)
        XCTAssertEqual(WizardModel.rowButton(for: .allowed), .allowed)
    }

    func testClosingTheWindowDoesNotRecordCompletion() {
        XCTAssertFalse(WizardModel.recordsCompletion(.close))
        XCTAssertTrue(WizardModel.recordsCompletion(.skip))
        XCTAssertTrue(WizardModel.recordsCompletion(.done))
        XCTAssertTrue(WizardModel.recordsCompletion(.completeObserved))
    }

    func testCloseWhileCoreMissingReopensOnActivation() {
        XCTAssertTrue(PermissionSetupPolicy.shouldReopenOnActivation(windowVisible: false, snapshot: coreMissing))
    }
}

/// Records every call. It has no request or capture method, so a revocation check cannot prompt.
private final class RecordingReader: CorePermissionReading {
    var calls: [String] = []
    var screen = true
    var accessibility = true

    func screenRecordingGranted() -> Bool { calls.append("screenRecording"); return screen }
    func accessibilityGranted() -> Bool { calls.append("accessibility"); return accessibility }
}

final class RevocationWatchTests: XCTestCase {
    func testWatchReadsOnlyTheTwoCorePermissions() {
        let reader = RecordingReader()
        let snapshot = CoreWatch.poll(reader)
        XCTAssertEqual(reader.calls, ["screenRecording", "accessibility"])
        XCTAssertEqual(snapshot.fullDiskAccess, .unknown, "Full Disk Access is never probed by the watch")
    }

    func testWatchReportsRevocationOnlyAfterCoreWasSeen() {
        let granted = PermissionSnapshot(screenRecording: .granted, accessibility: .granted, fullDiskAccess: .unknown)
        let revokedSR = PermissionSnapshot(screenRecording: .denied, accessibility: .granted, fullDiskAccess: .unknown)
        XCTAssertFalse(CoreWatch.revoked(previouslySeen: false, current: revokedSR))
        XCTAssertTrue(CoreWatch.revoked(previouslySeen: true, current: revokedSR))
        XCTAssertFalse(CoreWatch.revoked(previouslySeen: true, current: granted))
    }

    func testSeenBecomesTrueOnlyWhenBothCoreAreGranted() {
        let srOnly = PermissionSnapshot(screenRecording: .granted, accessibility: .denied, fullDiskAccess: .unknown)
        let both = PermissionSnapshot(screenRecording: .granted, accessibility: .granted, fullDiskAccess: .unknown)
        XCTAssertFalse(CoreWatch.seenAfter(previouslySeen: false, current: srOnly))
        XCTAssertTrue(CoreWatch.seenAfter(previouslySeen: false, current: both))
        XCTAssertTrue(CoreWatch.seenAfter(previouslySeen: true, current: srOnly))
    }

    func testRevocationBannerNamesTheMissingCorePermission() {
        let srMissing = PermissionSnapshot(screenRecording: .denied, accessibility: .granted, fullDiskAccess: .unknown)
        let axMissing = PermissionSnapshot(screenRecording: .granted, accessibility: .denied, fullDiskAccess: .unknown)
        XCTAssertNil(WizardModel.revocationBanner(previouslySeen: false, snapshot: srMissing))
        XCTAssertEqual(WizardModel.revocationBanner(previouslySeen: true, snapshot: srMissing),
                       WizardCopy.revokedScreenRecording)
        XCTAssertEqual(WizardModel.revocationBanner(previouslySeen: true, snapshot: axMissing),
                       WizardCopy.revokedAccessibility)
    }
}

final class WizardBannerAndStoreTests: XCTestCase {
    func testAdHocBannerShowsOnlyWithoutATeamIdentifier() {
        XCTAssertTrue(WizardModel.adHocBannerVisible(teamIdentifier: nil))
        XCTAssertTrue(WizardModel.adHocBannerVisible(teamIdentifier: ""))
        XCTAssertFalse(WizardModel.adHocBannerVisible(teamIdentifier: "6LPQNY95AQ"))
    }

    func testStoreRoundTripsBothFlags() {
        let suite = "wizard-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SetupWizardStore(defaults: defaults)
        XCTAssertFalse(store.hasShown)
        XCTAssertFalse(store.coreGrantedSeen)
        store.hasShown = true
        store.coreGrantedSeen = true
        XCTAssertTrue(SetupWizardStore(defaults: defaults).hasShown)
        XCTAssertTrue(SetupWizardStore(defaults: defaults).coreGrantedSeen)
    }

    func testSettingsURLsKeepTheExistingPaneForEachPermission() {
        XCTAssertEqual(PermissionKind.screenRecording.settingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        XCTAssertEqual(PermissionKind.accessibility.settingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        XCTAssertEqual(PermissionKind.fullDiskAccess.settingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }
}
