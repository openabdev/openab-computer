import Foundation
import XCTest
@testable import InstanceMCPCore

private func snap(_ sr: PermissionState, ax: PermissionState = .granted,
                  fda: PermissionState = .unknown) -> PermissionSnapshot {
    PermissionSnapshot(screenRecording: sr, accessibility: ax, fullDiskAccess: fda)
}

final class SharedPermissionStatusTests: XCTestCase {
    func testGrantedWhenOnlyTheChildProbeSaysGranted() {
        let r = SharedPermissionStatus.resolve(process: snap(.denied), child: .granted)
        XCTAssertEqual(r.shown.screenRecording, .granted)
        XCTAssertEqual(r.processScreenRecording, .denied)
        XCTAssertTrue(r.screenRecordingStale)
    }

    func testGrantedWhenOnlyTheProcessSaysGranted() {
        for child in [nil, .denied, .failed] as [ChildCheckResult?] {
            let r = SharedPermissionStatus.resolve(process: snap(.granted), child: child)
            XCTAssertEqual(r.shown.screenRecording, .granted)
            XCTAssertFalse(r.screenRecordingStale)
        }
    }

    func testDeniedWhenNeitherSaysGranted() {
        for child in [nil, .denied, .failed] as [ChildCheckResult?] {
            let r = SharedPermissionStatus.resolve(process: snap(.denied), child: child)
            XCTAssertEqual(r.shown.screenRecording, .denied)
            XCTAssertFalse(r.screenRecordingStale)
        }
    }

    func testAccessibilityAndFullDiskAccessKeepTheProcessAnswer() {
        let r = SharedPermissionStatus.resolve(process: snap(.denied, ax: .denied, fda: .granted), child: .granted)
        XCTAssertEqual(r.shown.accessibility, .denied, "the child probe says nothing about Accessibility")
        XCTAssertEqual(r.shown.fullDiskAccess, .granted)
    }

    func testRestartLineAppearsExactlyInTheStaleState() {
        for process in [PermissionState.granted, .denied, .unknown] {
            for child in [nil, .granted, .denied, .failed] as [ChildCheckResult?] {
                let line = SharedPermissionStatus.menuRestartLine(SharedPermissionStatus.resolve(process: snap(process), child: child))
                if process == .denied && child == .granted {
                    XCTAssertEqual(line, "Restart to finish setup")
                } else {
                    XCTAssertNil(line, "process \(process), child \(String(describing: child))")
                }
            }
        }
    }

    func testMenuAndWizardShowTheSameStatusForTheSameInputs() {
        for process in [PermissionState.granted, .denied, .unknown] {
            for child in [nil, .granted, .denied, .failed] as [ChildCheckResult?] {
                // The menu resolves the whole snapshot; the wizard uses the Screen Recording helper.
                let menu = SharedPermissionStatus.resolve(process: snap(process), child: child).shown.screenRecording
                let wizard = RelaunchPolicy.shownScreenRecording(process: process, child: child)
                XCTAssertEqual(menu, wizard)
                // Same mark text for both: row state and menu mark derive from the same state.
                XCTAssertEqual(WizardModel.rowState(state: menu, requested: false, returnedSinceRequest: false),
                               WizardModel.rowState(state: wizard, requested: false, returnedSinceRequest: false))
            }
        }
    }
}

final class ScreenRecordingProbeCacheTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var t = Date(timeIntervalSince1970: 1_000)
        func now() -> Date { t }
    }
    private final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
        var ranOnMain: [Bool] = []
        func note() { lock.lock(); count += 1; ranOnMain.append(Thread.isMainThread); lock.unlock() }
    }

    private func refresh(_ cache: ScreenRecordingProbeCache) -> ChildCheckResult? {
        let done = expectation(description: "probe")
        nonisolated(unsafe) var out: ChildCheckResult?
        var fired = false
        cache.refreshIfStale { value in out = value; fired = true; done.fulfill() }
        if !fired { wait(for: [done], timeout: 5) }
        return out
    }

    func testTheProbeRunsOffTheMainThreadAndCachesForTheTTL() {
        let clock = Clock(), calls = Calls()
        let cache = ScreenRecordingProbeCache(ttl: 5, now: { clock.now() }, probe: { calls.note(); return .granted })
        XCTAssertTrue(Thread.isMainThread, "the test calls from the main thread")
        XCTAssertNil(cache.latest)
        XCTAssertEqual(refresh(cache), .granted)
        XCTAssertEqual(cache.latest, .granted)
        XCTAssertEqual(calls.ranOnMain, [false], "never on the main thread")

        // Inside the TTL: served from the cache, no second probe.
        clock.t.addTimeInterval(4)
        cache.refreshIfStale()
        XCTAssertEqual(calls.count, 1)

        // Past the TTL: probes again.
        clock.t.addTimeInterval(2)
        XCTAssertEqual(refresh(cache), .granted)
        XCTAssertEqual(calls.count, 2)
    }

    func testAProbeIsNeverRunOnTheMainQueue() {
        let calls = Calls()
        let cache = ScreenRecordingProbeCache(queue: .main, probe: { calls.note(); return .granted })
        let done = expectation(description: "completion")
        nonisolated(unsafe) var out: ChildCheckResult? = .denied
        cache.refreshIfStale { value in out = value; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertNil(out)
        XCTAssertEqual(calls.count, 0, "a main-thread queue gets no probe")
        XCTAssertNil(cache.latest)
    }

    func testAFailedProbeDoesNotUndoAConfirmedGrant() {
        let clock = Clock()
        let cache = ScreenRecordingProbeCache(ttl: 5, now: { clock.now() }, probe: { .failed })
        cache.record(.granted)
        clock.t.addTimeInterval(10)
        XCTAssertEqual(refresh(cache), .failed)
        XCTAssertEqual(cache.latest, .granted)
        cache.invalidate()
        XCTAssertNil(cache.latest)
    }

    func testTwoCallersJoinOneChildRunAndBothGetTheirCallback() {
        let gate = DispatchSemaphore(value: 0)
        let calls = Calls()
        let cache = ScreenRecordingProbeCache(ttl: 5, probe: { calls.note(); gate.wait(); return .granted })
        let first = expectation(description: "first"), second = expectation(description: "second")
        nonisolated(unsafe) var a: ChildCheckResult?, b: ChildCheckResult?
        cache.refreshIfStale { a = $0; first.fulfill() }
        cache.refreshIfStale { b = $0; second.fulfill() }
        gate.signal()
        wait(for: [first, second], timeout: 5)
        XCTAssertEqual(calls.count, 1, "one child run for both callers")
        XCTAssertEqual(a, .granted)
        XCTAssertEqual(b, .granted)
    }

    func testWizardChecksRecordedInTheCacheAreWhatTheMenuReads() {
        // The wizard records its own check into the cache and reads the cache back; the menu reads the same cache.
        let cache = ScreenRecordingProbeCache(probe: { .failed })
        let process = PermissionSnapshot(screenRecording: .denied, accessibility: .granted, fullDiskAccess: .unknown)
        cache.record(.granted)
        XCTAssertEqual(SharedPermissionStatus.resolve(process: process, child: cache.latest).shown.screenRecording, .granted)
        // A later revoke reported by the child replaces the old grant for both surfaces.
        cache.record(.denied)
        XCTAssertEqual(SharedPermissionStatus.resolve(process: process, child: cache.latest).shown.screenRecording, .denied)
    }
}
