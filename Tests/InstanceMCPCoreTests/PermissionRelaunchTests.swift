import Foundation
import XCTest
@testable import InstanceMCPCore

private func freshStore() -> (SetupWizardStore, UserDefaults, String) {
    let suite = "PermissionRelaunchTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return (SetupWizardStore(defaults: defaults), defaults, suite)
}

final class RelaunchResumeStateTests: XCTestCase {
    func testResumeStateIsWrittenAndClearedAfterOneRead() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(store.consumeRelaunch(), "nothing written yet")

        store.recordRelaunch(page: .core)
        XCTAssertTrue(store.relaunchJustHappened)
        XCTAssertEqual(defaults.string(forKey: SetupWizardStore.resumePageKey), "core")

        XCTAssertEqual(store.consumeRelaunch(), SetupWizardStore.Resume(page: .core))
        XCTAssertFalse(store.relaunchJustHappened, "the flag is cleared after use")
        XCTAssertNil(defaults.string(forKey: SetupWizardStore.resumePageKey))
        XCTAssertNil(store.consumeRelaunch(), "the second read finds nothing")
        XCTAssertTrue(store.autoRelaunchSpent, "the spent flag outlives the resume state")
    }

    func testSilentRelaunchAfterFinishReopensNoPage() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.recordRelaunch(page: .optional)
        store.recordRelaunch(page: nil)
        XCTAssertNil(defaults.string(forKey: SetupWizardStore.resumePageKey))
        XCTAssertEqual(store.consumeRelaunch(), SetupWizardStore.Resume(page: nil), "the flag is there, the page is not")
        XCTAssertFalse(store.relaunchJustHappened)
    }

    func testResumeKeepsTheOptionalPage() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.recordRelaunch(page: .optional)
        XCTAssertEqual(store.consumeRelaunch()?.page, .optional)
    }
}

final class RelaunchCoordinatorTests: XCTestCase {
    func testRelaunchIsRequestedAtMostOncePerGrant() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        var launches = 0, terminations = 0
        func make() -> RelaunchCoordinator {
            RelaunchCoordinator(store: store, launch: { launches += 1; return true }, terminate: { terminations += 1 })
        }

        let first = make()
        XCTAssertTrue(first.requestRelaunch(page: nil, automatic: true))
        XCTAssertFalse(first.requestRelaunch(page: nil, automatic: true), "same process, second request")
        XCTAssertFalse(first.requestRelaunch(page: .core, automatic: false), "same process, manual request")

        // The new instance still reports off (stale again): it gets one extra attempt, and no more.
        let second = make()
        XCTAssertNotNil(store.consumeRelaunch())
        XCTAssertTrue(second.requestRelaunch(page: nil, automatic: true), "one extra attempt per launch")
        XCTAssertFalse(second.requestRelaunch(page: nil, automatic: true), "no second extra attempt in the same launch")
        XCTAssertFalse(second.requestRelaunch(page: .core, automatic: false), "the Restart button counts too")
        XCTAssertEqual(launches, 2)
        XCTAssertEqual(terminations, 2)

        // A process that sees the grant clears the spent flag, so a later revoke and re-grant can relaunch once.
        store.autoRelaunchSpent = false
        XCTAssertTrue(make().requestRelaunch(page: nil, automatic: true))
        XCTAssertEqual(launches, 3)
    }

    func testFailedLaunchLeavesTheAutomaticRelaunchUnspent() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        var ok = false
        let coordinator = RelaunchCoordinator(store: store, launch: { ok }, terminate: {})
        XCTAssertFalse(coordinator.requestRelaunch(page: nil, automatic: true))
        XCTAssertFalse(store.autoRelaunchSpent, "a failed launch must not spend the relaunch")
        ok = true
        XCTAssertTrue(coordinator.requestRelaunch(page: nil, automatic: true))
        XCTAssertTrue(store.autoRelaunchSpent)
    }

    func testManualRestartWorksAfterTheAutomaticOneWasSpent() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.recordRelaunch(page: nil)
        var launches = 0
        let coordinator = RelaunchCoordinator(store: store, launch: { launches += 1; return true }, terminate: {})
        XCTAssertTrue(coordinator.requestRelaunch(page: .core, automatic: false))
        XCTAssertEqual(launches, 1)
    }

    func testFailedLaunchKeepsTheOldInstanceAndClearsTheResumeState() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        var terminations = 0
        let coordinator = RelaunchCoordinator(store: store, launch: { false }, terminate: { terminations += 1 })
        XCTAssertFalse(coordinator.requestRelaunch(page: .core, automatic: true))
        XCTAssertEqual(terminations, 0, "the old instance must not quit when the new one did not start")
        XCTAssertFalse(store.relaunchJustHappened)
        XCTAssertNil(store.consumeRelaunch())
    }
}

final class RelaunchPolicyTests: XCTestCase {
    private func decide(_ child: ChildCheckResult?, processGranted: Bool = false,
                        confirmed: Bool = false) -> RelaunchAction {
        RelaunchPolicy.decide(child: child, processGranted: processGranted, userConfirmedEnabled: confirmed)
    }

    /// The Muse-style flow: the user turns it on and picks Later in the macOS dialog. The check mark appears and
    /// nothing relaunches at that moment.
    func testCheckMarkAppearsWhenTheChildSaysGrantedWithoutAnyRelaunch() {
        XCTAssertEqual(RelaunchPolicy.shownScreenRecording(process: .denied, child: .granted), .granted)
        XCTAssertEqual(decide(.granted), .none, "no restart button and no relaunch at detection")
        let row = WizardModel.rowState(state: RelaunchPolicy.shownScreenRecording(process: .denied, child: .granted),
                                       requested: true, returnedSinceRequest: false)
        XCTAssertEqual(row, .allowed)
        XCTAssertEqual(WizardModel.rowButton(for: RelaunchPolicy.effectiveRow(base: row, action: decide(.granted))), .allowed)
        // With both core granted the wizard can move on.
        let shown = PermissionSnapshot(screenRecording: RelaunchPolicy.shownScreenRecording(process: .denied, child: .granted),
                                       accessibility: .granted, fullDiskAccess: .denied)
        XCTAssertEqual(WizardModel.footerAction(page: .core, snapshot: shown), .continueToOptional(enabled: true))
    }

    func testShownStateIsTheProcessStateUnlessTheChildConfirmsTheGrant() {
        XCTAssertEqual(RelaunchPolicy.shownScreenRecording(process: .denied, child: nil), .denied)
        XCTAssertEqual(RelaunchPolicy.shownScreenRecording(process: .denied, child: .denied), .denied)
        XCTAssertEqual(RelaunchPolicy.shownScreenRecording(process: .denied, child: .failed), .denied)
        XCTAssertEqual(RelaunchPolicy.shownScreenRecording(process: .granted, child: .denied), .granted)
        XCTAssertEqual(RelaunchPolicy.shownScreenRecording(process: .unknown, child: .granted), .unknown)
    }

    func testRelaunchIsRequestedOnlyOnFinish() {
        // Child confirmed, process stale: Finish relaunches once.
        XCTAssertTrue(RelaunchPolicy.shouldRelaunchOnFinish(child: .granted, processGranted: false))
        // Finish with a process that already reports granted skips the relaunch.
        XCTAssertFalse(RelaunchPolicy.shouldRelaunchOnFinish(child: .granted, processGranted: true))
        XCTAssertFalse(RelaunchPolicy.shouldRelaunchOnFinish(child: nil, processGranted: true))
        // Nothing confirmed: no relaunch.
        XCTAssertFalse(RelaunchPolicy.shouldRelaunchOnFinish(child: .denied, processGranted: false))
        XCTAssertFalse(RelaunchPolicy.shouldRelaunchOnFinish(child: .failed, processGranted: false))
    }

    func testAfterASpentRelaunchAStaleProcessGetsTheRestartButtonBack() {
        // Child says granted, the new process still reports off, the earlier relaunch was spent.
        let action = RelaunchPolicy.decide(child: .granted, processGranted: false, userConfirmedEnabled: false,
                                           autoRelaunchSpent: true)
        XCTAssertEqual(action, .showRestartStale)
        let row = RelaunchPolicy.effectiveRow(base: .allowed, action: action)
        XCTAssertEqual(row, .needsRestart, "a check mark with no button is the bug")
        XCTAssertEqual(WizardModel.rowButton(for: row), .restart)
        // Not spent yet: the check mark stays and Finish does the relaunch.
        XCTAssertEqual(RelaunchPolicy.decide(child: .granted, processGranted: false, userConfirmedEnabled: false,
                                             autoRelaunchSpent: false), .none)
        // A process that sees the grant never shows it.
        XCTAssertEqual(RelaunchPolicy.decide(child: .granted, processGranted: true, userConfirmedEnabled: false,
                                             autoRelaunchSpent: true), .none)
    }

    func testFinishAfterASpentRelaunchTriesOnceMoreAndDoesNotLoop() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        var launches = 0
        func launch() -> RelaunchCoordinator {
            RelaunchCoordinator(store: store, launch: { launches += 1; return true }, terminate: {})
        }
        // Launch 1: Finish relaunches (child granted, process stale).
        let first = launch()
        XCTAssertTrue(RelaunchPolicy.shouldRelaunchOnFinish(child: .granted, processGranted: false))
        XCTAssertTrue(first.requestRelaunch(page: nil, automatic: true))
        XCTAssertTrue(store.autoRelaunchSpent)
        // Launch 2 is stale again: Finish and the menu line may try once more...
        let second = launch()
        XCTAssertTrue(RelaunchPolicy.shouldRelaunchOnFinish(child: .granted, processGranted: false))
        XCTAssertTrue(second.requestRelaunch(page: nil, automatic: true))
        // ...but not twice in that launch, however many times the user presses.
        XCTAssertFalse(second.requestRelaunch(page: nil, automatic: true))
        XCTAssertFalse(second.requestRelaunch(page: .core, automatic: false))
        XCTAssertEqual(launches, 2)
    }

    func testDetectionNeverRequestsARelaunch() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        var launches = 0
        _ = RelaunchCoordinator(store: store, launch: { launches += 1; return true }, terminate: {})
        // The policy has no action that relaunches; only the coordinator does, and only Finish or the button call it.
        for child in [nil, .granted, .denied, .failed] as [ChildCheckResult?] {
            for confirmed in [false, true] {
                XCTAssertNotEqual(String(describing: decide(child, confirmed: confirmed)), "relaunch")
            }
        }
        XCTAssertEqual(launches, 0)
        XCTAssertFalse(store.relaunchJustHappened)
    }

    func testNothingHappensWhileTheProcessAlreadySeesTheGrant() {
        for child in [nil, .granted, .denied, .failed] as [ChildCheckResult?] {
            XCTAssertEqual(decide(child, processGranted: true), .none)
        }
    }

    func testFallbackButtonAppearsWhenTheChildCheckFails() {
        let action = decide(.failed)
        XCTAssertEqual(action, .showRestart)
        let row = RelaunchPolicy.effectiveRow(base: .waiting, action: action)
        XCTAssertEqual(row, .needsRestart)
        XCTAssertEqual(WizardModel.rowButton(for: row), .restart)
        XCTAssertEqual(WizardCopy.restartButton, "Restart OpenAB Computer")
        XCTAssertTrue(WizardCopy.restartExplanation.contains("restart"))
    }

    func testFallbackButtonAppearsWhenChildSaysOffButTheUserSaysItIsOn() {
        XCTAssertEqual(decide(.denied), .none, "still waiting for the user")
        XCTAssertEqual(decide(.denied, confirmed: true), .showRestart)
        XCTAssertEqual(decide(nil, confirmed: true), .none, "no child result yet")
    }

    func testAGrantedRowIsNeverOverridden() {
        XCTAssertEqual(RelaunchPolicy.effectiveRow(base: .allowed, action: .showRestart), .allowed)
        XCTAssertEqual(RelaunchPolicy.effectiveRow(base: .stillOff, action: .none), .stillOff)
    }

    func testAccessibilityComesFirstAndScreenRecordingIsLast() {
        XCTAssertEqual(WizardModel.coreOrder, [.accessibility, .screenRecording])
        XCTAssertEqual(PermissionKind.coreKinds, [.accessibility, .screenRecording])
    }

    func testChildCheckScheduleBacksOffAndStops() {
        XCTAssertEqual(ChildCheckSchedule.interval(elapsed: 0), 2)
        XCTAssertEqual(ChildCheckSchedule.interval(elapsed: 119), 2)
        XCTAssertEqual(ChildCheckSchedule.interval(elapsed: 120), 15)
        XCTAssertEqual(ChildCheckSchedule.interval(elapsed: 599), 15)
        XCTAssertNil(ChildCheckSchedule.interval(elapsed: 600))
    }
}

private final class FakeReader: CorePermissionReading {
    var screen: Bool
    var calls: [String] = []
    init(screen: Bool) { self.screen = screen }
    func screenRecordingGranted() -> Bool { calls.append("screenRecording"); return screen }
    func accessibilityGranted() -> Bool { calls.append("accessibility"); return true }
}

final class HiddenPermissionCheckTests: XCTestCase {
    func testOnlyTheExactHiddenArgumentIsAnInvocation() {
        XCTAssertTrue(PermissionCheckCommand.isInvocation([PermissionCheckCommand.argument]))
        XCTAssertFalse(PermissionCheckCommand.isInvocation([]))
        XCTAssertFalse(PermissionCheckCommand.isInvocation([PermissionCheckCommand.argument, "--port", "1"]))
    }

    func testExitCodeIsZeroWhenGrantedAndOneWhenNotAndReadsOnlyScreenRecording() {
        let granted = FakeReader(screen: true)
        XCTAssertEqual(PermissionCheckCommand.exitCode(reader: granted), 0)
        XCTAssertEqual(granted.calls, ["screenRecording"])
        XCTAssertEqual(PermissionCheckCommand.exitCode(reader: FakeReader(screen: false)), 1)
    }

    /// Runs the real built executable. Needs the executable target built next to the test bundle.
    func testBuiltExecutableExitsZeroOrOneWithoutOutput() throws {
        let dir = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let exe = dir.appendingPathComponent("oab-computer")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: exe.path), "executable not built beside the tests")
        let p = Process()
        p.executableURL = exe
        p.arguments = [PermissionCheckCommand.argument]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertTrue([0, 1].contains(p.terminationStatus), "exit \(p.terminationStatus)")
        XCTAssertEqual(p.terminationReason, .exit)
        XCTAssertTrue(out.fileHandleForReading.readDataToEndOfFile().isEmpty, "prints nothing")
        XCTAssertTrue(err.fileHandleForReading.readDataToEndOfFile().isEmpty, "prints nothing")
    }
}

final class ChildPermissionCheckTests: XCTestCase {
    private func sh(_ script: String, timeout: TimeInterval = 3) -> ChildCheckResult {
        ChildPermissionCheck.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: timeout)
    }

    func testExitStatusMapsToGrantedDeniedOrFailed() {
        XCTAssertEqual(sh("exit 0"), .granted)
        XCTAssertEqual(sh("exit 1"), .denied)
        XCTAssertEqual(sh("exit 7"), .failed)
        XCTAssertEqual(sh("kill -9 $$"), .failed, "a signal is not an answer")
    }

    func testMissingExecutableFails() {
        XCTAssertEqual(ChildPermissionCheck.run(executable: URL(fileURLWithPath: "/nonexistent/oab")), .failed)
    }

    func testTimeoutKillsTheChildAndFails() {
        let start = Date()
        XCTAssertEqual(sh("sleep 30", timeout: 0.3), .failed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testChildOutputIsDiscarded() {
        // The child writes to stdout; the check neither fails nor blocks on it.
        XCTAssertEqual(sh("yes | head -c 200000; exit 0"), .granted)
    }
}

final class PortReleaseWaitTests: XCTestCase {
    func testWaitReturnsTrueForAFreePortAndFalseWhileAnotherProcessListens() {
        var port: UInt16 = 40_000
        for _ in 0..<100 {
            port = UInt16(40_000 + Int.random(in: 0..<20_000))
            if !FirstRunSetup.isPortInUse(host: "127.0.0.1", port: port) { break }
        }
        XCTAssertTrue(FirstRunSetup.waitForPortFree(host: "127.0.0.1", port: port, timeout: 0.2))

        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var on: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        XCTAssertFalse(FirstRunSetup.waitForPortFree(host: "127.0.0.1", port: port, timeout: 0.3),
                       "a genuinely separate copy keeps the port")
    }

    func testChildCheckTimerRunsAgainWhenWindowReopens() {
        XCTAssertTrue(ChildCheckSchedule.shouldRun(requested: true, granted: false, windowVisible: true))
        // Closed: the timer stops.
        XCTAssertFalse(ChildCheckSchedule.shouldRun(requested: true, granted: false, windowVisible: false))
        // Reopened with the request still pending: it runs again.
        XCTAssertTrue(ChildCheckSchedule.shouldRun(requested: true, granted: false, windowVisible: true))
        XCTAssertFalse(ChildCheckSchedule.shouldRun(requested: true, granted: true, windowVisible: true))
        XCTAssertFalse(ChildCheckSchedule.shouldRun(requested: false, granted: false, windowVisible: true))
    }
}
