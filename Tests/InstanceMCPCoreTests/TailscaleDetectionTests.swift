import Foundation
import XCTest
@testable import InstanceMCPCore

private let statusJSON = Data("""
{"BackendState":"Running","AuthURL":"https://login.tailscale.com/a/tskey-SECRET123",
 "Self":{"DNSName":"mac.tail1234.ts.net.","UserID":12345,"HostName":"mac"},
 "User":{"12345":{"LoginName":"owner@example.com","DisplayName":"Owner"}}}
""".utf8)

private final class TSClock: @unchecked Sendable {
    var t = Date(timeIntervalSince1970: 0)
    var slept: [TimeInterval] = []
    func now() -> Date { t }
    func sleep(_ d: TimeInterval) { slept.append(d); t.addTimeInterval(d) }
}

final class TailscaleDetectionTests: XCTestCase {
    private func detect(_ results: [FirstRunSetup.TailscaleRun], clock: TSClock = TSClock(),
                        candidates: [String] = ["/fake/tailscale"], runDuration: TimeInterval = 0,
                        notes: inout [String]) -> (String?, Int) {
        var calls = 0
        var collected: [String] = []
        let login = FirstRunSetup.detectTailscaleLogin(
            candidates: { candidates },
            runner: { _, _ in
                defer { calls += 1; clock.t.addTimeInterval(runDuration) }
                return calls < results.count ? results[calls] : results.last!
            },
            now: clock.now, sleep: clock.sleep, note: { collected.append($0) })
        notes = collected
        return (login, calls)
    }

    func testSucceedsOnTheSecondAttempt() {
        var notes: [String] = []
        let (login, calls) = detect([.finished(output: Data("The Tailscale GUI failed to start".utf8), status: 0),
                                     .finished(output: statusJSON, status: 0)], notes: &notes)
        XCTAssertEqual(login, "owner@example.com")
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(notes.contains { $0.contains("attempt 1") && $0.contains("parse returned nil") }, "\(notes)")
        XCTAssertTrue(notes.contains { $0.contains("found on attempt 2") })
    }

    func testAllAttemptsFailAndTheLaunchFallsBackToTheTokenWithTheNotice() throws {
        var notes: [String] = []
        let clock = TSClock()
        let (login, calls) = detect([.timeout, .finished(output: Data(), status: 1), .finished(output: Data(), status: 0)],
                                    clock: clock, notes: &notes)
        XCTAssertNil(login)
        XCTAssertEqual(calls, 3, "three attempts, no more")
        XCTAssertEqual(clock.slept, [0.5, 1.0], "short backoff between the tries")
        XCTAssertTrue(notes.contains { $0.contains("timeout") })
        XCTAssertTrue(notes.contains { $0.contains("exit status 1") })
        XCTAssertTrue(notes.contains { $0.contains("empty output") })

        let home = NSTemporaryDirectory() + "ts-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let plan = try FirstRunSetup.prepare(home: home, detectLogin: { note in
            _ = FirstRunSetup.detectTailscaleLogin(candidates: { ["/fake"] }, runner: { _, _ in .timeout },
                                                   sleep: { _ in }, note: note)
            return nil
        })
        XCTAssertNil(plan.allowLogin)
        XCTAssertEqual(plan.notice, FirstRunSetup.tokenOnlyNotice)
        XCTAssertTrue(plan.logLines.contains { $0.contains("attempt 1") && $0.contains("timeout") })
        XCTAssertTrue(plan.logLines.contains { $0.contains(FirstRunSetup.tokenOnlyNotice) })
    }

    func testASlowRunnerStopsAtTheBudget() {
        var notes: [String] = []
        let clock = TSClock()
        var timeouts: [TimeInterval] = []
        let login = FirstRunSetup.detectTailscaleLogin(
            timeout: 3, budget: 8, candidates: { ["/a", "/b"] },
            runner: { _, timeout in timeouts.append(timeout); clock.t.addTimeInterval(timeout); return .timeout },
            now: clock.now, sleep: clock.sleep, note: { notes.append($0) })
        XCTAssertNil(login)
        XCTAssertLessThanOrEqual(clock.t.timeIntervalSince1970, 8.001, "the whole search stays inside the budget")
        XCTAssertTrue(timeouts.allSatisfy { $0 <= 3 })
        XCTAssertTrue(notes.contains { $0.contains("budget") }, "\(notes)")
    }

    func testTheRealRunnerKillsAHungCLIAtTheTimeout() throws {
        let dir = NSTemporaryDirectory() + "tsrun-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = dir + "/slow"
        try "#!/bin/sh\nsleep 30\n".write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        let t0 = Date()
        XCTAssertEqual(FirstRunSetup.systemTailscaleRunner(script, 0.4), .timeout)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3)
    }

    func testTheRealRunnerReadsOutputAndStatus() throws {
        let dir = NSTemporaryDirectory() + "tsrun-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = dir + "/ok"
        try "#!/bin/sh\necho '{\"a\":1}'\nexit 3\n".write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        XCTAssertEqual(FirstRunSetup.systemTailscaleRunner(script, 5), .finished(output: Data("{\"a\":1}\n".utf8), status: 3))
        XCTAssertEqual(FirstRunSetup.systemTailscaleRunner(dir + "/missing", 5), .launchFailed)
    }

    func testTheCLIGetsTERM_PROGRAMBecauseTheAppBinaryNeedsItOutsideATerminal() {
        XCTAssertEqual(FirstRunSetup.tailscaleEnvironment([:])["TERM_PROGRAM"], "oab-computer")
        XCTAssertEqual(FirstRunSetup.tailscaleEnvironment(["TERM_PROGRAM": ""])["TERM_PROGRAM"], "oab-computer")
        XCTAssertEqual(FirstRunSetup.tailscaleEnvironment(["TERM_PROGRAM": "ghostty", "A": "b"]),
                       ["TERM_PROGRAM": "ghostty", "A": "b"], "an existing value is kept")
    }

    func testParserReadsAUserMapThatHoldsOnlyTheSelfUser() {
        // `--peers=false` leaves no Peer entries; the self user is the only User entry.
        XCTAssertEqual(FirstRunSetup.tailscaleLogin(statusJSON: statusJSON), "owner@example.com")
    }

    func testNoLogLineCarriesOutputOrTheLogin() {
        var notes: [String] = []
        let secretOutput = Data("tskey-SECRET123 owner@example.com".utf8)
        _ = detect([.finished(output: secretOutput, status: 0), .finished(output: secretOutput, status: 2),
                    .finished(output: statusJSON, status: 0)], notes: &notes)
        XCTAssertFalse(notes.isEmpty)
        for line in notes {
            XCTAssertFalse(line.contains("tskey"), line)
            XCTAssertFalse(line.contains("owner@example.com"), line)
        }
    }

    func testAFailingFirstCLIDoesNotHideALaterOne() {
        var notes: [String] = []
        let clock = TSClock()
        var seen: [String] = []
        let login = FirstRunSetup.detectTailscaleLogin(
            candidates: { ["/app", "/brew"] },
            runner: { cli, _ in seen.append(cli); let r: FirstRunSetup.TailscaleRun = cli == "/brew" ? .finished(output: statusJSON, status: 0) : .timeout; return r },
            now: clock.now, sleep: clock.sleep, note: { notes.append($0) })
        XCTAssertEqual(login, "owner@example.com")
        XCTAssertEqual(seen, ["/app", "/brew"])
    }
}
