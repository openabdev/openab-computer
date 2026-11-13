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
        XCTAssertNil(store.consumeResume(), "nothing written yet")

        store.recordRelaunch(page: .core)
        XCTAssertTrue(store.relaunchJustHappened)
        XCTAssertEqual(defaults.string(forKey: SetupWizardStore.resumePageKey), "core")

        XCTAssertEqual(store.consumeResume(), .core)
        XCTAssertFalse(store.relaunchJustHappened, "the flag is cleared after use")
        XCTAssertNil(defaults.string(forKey: SetupWizardStore.resumePageKey))
        XCTAssertNil(store.consumeResume(), "the second read finds nothing")
        XCTAssertTrue(store.autoRelaunchSpent, "the spent flag outlives the resume state")
    }

    func testResumeKeepsTheOptionalPage() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.recordRelaunch(page: .optional)
        XCTAssertEqual(store.consumeResume(), .optional)
    }
}

final class RelaunchCoordinatorTests: XCTestCase {
    func testAutomaticRelaunchIsRequestedAtMostOncePerGrant() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        var launches = 0, terminations = 0
        func make() -> RelaunchCoordinator {
            RelaunchCoordinator(store: store, launch: { launches += 1; return true }, terminate: { terminations += 1 })
        }

        let first = make()
        XCTAssertTrue(first.requestRelaunch(page: .core, automatic: true))
        XCTAssertFalse(first.requestRelaunch(page: .core, automatic: true), "same process, second request")
        XCTAssertFalse(first.requestRelaunch(page: .core, automatic: false), "same process, manual request")

        // The new instance still reports off and its child check says granted: no second automatic relaunch.
        let second = make()
        XCTAssertEqual(store.consumeResume(), .core)
        XCTAssertFalse(second.requestRelaunch(page: .core, automatic: true), "no relaunch loop")
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(terminations, 1)

        // A process that sees the grant clears the spent flag, so a later revoke and re-grant can relaunch once.
        store.autoRelaunchSpent = false
        XCTAssertTrue(make().requestRelaunch(page: .core, automatic: true))
        XCTAssertEqual(launches, 2)
    }

    func testManualRestartWorksAfterTheAutomaticOneWasSpent() {
        let (store, defaults, suite) = freshStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.recordRelaunch(page: .core)
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
        XCTAssertNil(store.consumeResume())
        XCTAssertTrue(store.autoRelaunchSpent, "so the row falls back to the Restart button")
        XCTAssertEqual(RelaunchPolicy.decide(child: .granted, processGranted: false, autoRelaunchSpent: store.autoRelaunchSpent,
                                             userConfirmedEnabled: false), .showRestart)
        XCTAssertTrue(coordinator.requestRelaunch(page: .core, automatic: false) == false)
    }
}

final class RelaunchPolicyTests: XCTestCase {
    private func decide(_ child: ChildCheckResult?, processGranted: Bool = false, spent: Bool = false,
                        confirmed: Bool = false) -> RelaunchAction {
        RelaunchPolicy.decide(child: child, processGranted: processGranted, autoRelaunchSpent: spent,
                              userConfirmedEnabled: confirmed)
    }

    func testChildGrantedWhileProcessStillOffRelaunchesOnce() {
        XCTAssertEqual(decide(.granted), .relaunch)
        XCTAssertEqual(decide(.granted, spent: true), .showRestart)
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
        let exe = dir.appendingPathComponent("oab-instance-mcp")
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
