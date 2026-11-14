import Foundation
import XCTest
@testable import InstanceMCPCore

/// A scripted Tailscale CLI. It models `serve status --json` for one tailnet name and applies only `serve` commands,
/// so a test sees what the app would have changed. No test in this file starts a real CLI.
final class FakeTailscale: @unchecked Sendable {
    let host = "mac.tail1234.ts.net"
    var calls: [[String]] = []
    var dns: String? = "mac.tail1234.ts.net."
    /// "host:port" -> proxy target, one "/" handler each.
    var web: [String: String] = [:]
    var tcpForward: [Int: String] = [:]
    var funnel: Set<String> = []
    var dnsFails = false
    /// Added to the status JSON as "BackendState" when set.
    var backendState: String? = "Running"
    /// `serve status --json` answers with empty stdout and exit 0.
    var statusEmpty = false
    /// The first mutating serve command times out but is applied anyway.
    var firstServeTimesOutButApplies = false
    private var serveTimedOut = false
    var extraHandlers: [String: [String: String]] = [:]
    var statusFails = false
    /// `tailscale status --json` runs and exits non-zero (or times out) with this: (status, output) or a timeout.
    var statusExit: (status: Int32, output: String)?
    var statusTimesOut = false
    var serveFails = false
    var serveNoEffect = false
    var offNoEffect = false
    /// After a mutating command, `serve status` stops answering.
    var statusFailsAfterMutation = false
    private var mutated = false
    var timeoutFirstAttempt = false
    private var timedOut: Set<String> = []

    var mutating: [[String]] { calls.filter { $0.first == "serve" && $0.dropFirst().first != "status" } }

    func serve(_ port: Int, to proxy: String) { web["\(host):\(port)"] = proxy }

    func run(_ cli: String, _ args: [String], _ timeout: TimeInterval) -> FirstRunSetup.TailscaleRun {
        calls.append(args)
        if timeoutFirstAttempt, !timedOut.contains(cli) { timedOut.insert(cli); return .timeout }
        if args == FirstRunSetup.tailscaleStatusArguments {
            if statusTimesOut { return .timeout }
            if let statusExit { return .finished(output: Data(statusExit.output.utf8), status: statusExit.status) }
            guard !dnsFails, let dns else { return .finished(output: Data("The Tailscale GUI failed to start".utf8), status: 0) }
            let state = backendState.map { #""BackendState":"\#($0)","# } ?? ""
            return .finished(output: Data(#"{\#(state)"Self":{"DNSName":"\#(dns)","UserID":7},"User":{"7":{"LoginName":"owner@example.com"}}}"#.utf8), status: 0)
        }
        if args == ["serve", "status", "--json"] {
            if statusFails || (statusFailsAfterMutation && mutated) { return .finished(output: Data(), status: 1) }
            if statusEmpty { return .finished(output: Data(), status: 0) }
            return .finished(output: statusJSON(), status: 0)
        }
        guard args.first == "serve" else {
            XCTFail("unexpected tailscale arguments \(args)")
            return .finished(output: Data(), status: 2)
        }
        mutated = true
        if firstServeTimesOutButApplies, !serveTimedOut, args.contains("--bg") {
            serveTimedOut = true
            serve(8444, to: "http://127.0.0.1:8795")
            return .timeout
        }
        if serveFails { return .finished(output: Data(), status: 1) }
        if args == ["serve", "--bg", "--https=8444", "http://127.0.0.1:8795"] {
            if !serveNoEffect { serve(8444, to: "http://127.0.0.1:8795") }
        } else if args == ["serve", "--https=8444", "off"] {
            if !offNoEffect { web.removeValue(forKey: "\(host):8444"); tcpForward.removeValue(forKey: 8444) }
        } else {
            XCTFail("a serve command other than the 8444 on/off pair ran: \(args)")
        }
        return .finished(output: Data(), status: 0)
    }

    private func statusJSON() -> Data {
        var root: [String: Any] = [:]
        var tcp: [String: Any] = [:]
        var webObj: [String: Any] = [:]
        for (hostPort, proxy) in web {
            var handlers: [String: Any] = ["/": ["Proxy": proxy]]
            for (path, target) in extraHandlers[hostPort] ?? [:] { handlers[path] = ["Proxy": target] }
            webObj[hostPort] = ["Handlers": handlers]
            if let port = hostPort.split(separator: ":").last { tcp[String(port)] = ["HTTPS": true] }
        }
        for (port, target) in tcpForward { tcp[String(port)] = ["TCPForward": target] }
        if !webObj.isEmpty { root["Web"] = webObj }
        if !tcp.isEmpty { root["TCP"] = tcp }
        if !funnel.isEmpty { root["AllowFunnel"] = Dictionary(uniqueKeysWithValues: funnel.map { ($0, true) }) }
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }
}

private extension TailnetExposure.Outcome {
    var urlIfOn: String? { if case .on(let u) = self { return u } else { return nil } }
}

final class TailnetExposureTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private let onArgs = ["serve", "--bg", "--https=8444", "http://127.0.0.1:8795"]
    private let offArgs = ["serve", "--https=8444", "off"]
    private let expectedURL = "https://mac.tail1234.ts.net:8444/mcp"

    override func setUp() {
        suite = "tailnet-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func make(_ fake: FakeTailscale, login: Bool = true, logs: LogBox = LogBox()) -> TailnetExposure {
        TailnetExposure(defaults: defaults, loginDetected: login, backendPort: 8795,
                        runner: { cli, args, t in fake.run(cli, args, t) },
                        candidates: { ["/fake/tailscale"] }, sleep: { _ in }, log: { logs.lines.append($0) })
    }

    final class LogBox: @unchecked Sendable { var lines: [String] = [] }

    // MARK: no login

    func testThePageIsHiddenWithoutADetectedLogin() {
        XCTAssertEqual(WizardModel.pages(tailnetOffered: false), [.core, .optional])
        XCTAssertEqual(WizardModel.pages(tailnetOffered: true), [.core, .optional, .tailnet])
        XCTAssertEqual(WizardModel.available(.tailnet, tailnetOffered: false), .optional)
        XCTAssertEqual(WizardModel.available(.tailnet, tailnetOffered: true), .tailnet)
        XCTAssertFalse(make(FakeTailscale(), login: false).offersExposure)
        XCTAssertTrue(make(FakeTailscale(), login: true).offersExposure)
        XCTAssertEqual(MenuModel.tailnetMenu(offered: false, publicURL: nil),
                       TailnetMenu(stateLine: nil, actionTitle: nil, action: nil))
    }

    func testExposureIsRefusedWithoutALoginAndRunsNothing() {
        let fake = FakeTailscale()
        let logs = LogBox()
        let exposure = make(fake, login: false, logs: logs)
        XCTAssertEqual(exposure.enable(), .refusedNoLogin)
        XCTAssertTrue(fake.calls.isEmpty, "a refusal must not even read Tailscale")
        XCTAssertFalse(exposure.optedIn)
        XCTAssertNil(exposure.publicURL)
        XCTAssertTrue(logs.lines.contains { $0.contains("refused") })
    }

    func testAStoredOptInIsNotReappliedWithoutALogin() {
        defaults.set(true, forKey: TailnetExposure.optInKey)
        let fake = FakeTailscale()
        let exposure = make(fake, login: false)
        XCTAssertEqual(exposure.reapplyAtLaunch(), .refusedNoLogin)
        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertNil(exposure.publicURL)
    }

    // MARK: turning on

    func testTurningOnRunsExactlyTheExpectedServeCommand() {
        let fake = FakeTailscale()
        fake.serve(443, to: "http://127.0.0.1:3000")
        let exposure = make(fake)
        XCTAssertEqual(exposure.enable(), .on(url: expectedURL))
        XCTAssertEqual(fake.mutating, [onArgs])
        XCTAssertEqual(fake.web["mac.tail1234.ts.net:8444"], "http://127.0.0.1:8795")
        XCTAssertEqual(fake.web["mac.tail1234.ts.net:443"], "http://127.0.0.1:3000", "another port's mapping is untouched")
        XCTAssertTrue(exposure.optedIn)
        XCTAssertEqual(exposure.publicURL, expectedURL)
        // Read the name, read the status, set it, verify it.
        XCTAssertEqual(fake.calls.first, FirstRunSetup.tailscaleStatusArguments)
        XCTAssertEqual(fake.calls.last, ["serve", "status", "--json"])
    }

    func testTheDefaultIsOffAndNothingRunsUntilAsked() {
        let fake = FakeTailscale()
        let exposure = make(fake)
        XCTAssertFalse(exposure.optedIn)
        XCTAssertNil(exposure.publicURL)
        XCTAssertNil(exposure.reapplyAtLaunch(), "no stored opt-in, so nothing is read or run")
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testAnExistingForeignMappingOn8444IsNotOverwritten() {
        let fake = FakeTailscale()
        fake.serve(8444, to: "http://127.0.0.1:9000")
        let logs = LogBox()
        let exposure = make(fake, logs: logs)
        let outcome = exposure.enable()
        XCTAssertEqual(outcome, .conflict(existing: "http://127.0.0.1:9000"))
        XCTAssertTrue(fake.mutating.isEmpty)
        XCTAssertEqual(fake.web["mac.tail1234.ts.net:8444"], "http://127.0.0.1:9000")
        XCTAssertFalse(exposure.optedIn)
        XCTAssertNil(exposure.publicURL)
        XCTAssertTrue(outcome.message.contains("http://127.0.0.1:9000"))
        XCTAssertTrue(outcome.message.contains("did not change"))
        XCTAssertTrue(logs.lines.contains { $0.contains("already mapped") })
    }

    func testATCPForwardOrAFunnelOn8444CountsAsForeign() {
        let tcp = FakeTailscale()
        tcp.tcpForward[8444] = "127.0.0.1:2222"
        XCTAssertEqual(make(tcp).enable(), .conflict(existing: "TCP forward to 127.0.0.1:2222"))
        XCTAssertTrue(tcp.mutating.isEmpty)

        let funnel = FakeTailscale()
        funnel.serve(8444, to: "http://127.0.0.1:8795")
        funnel.funnel = ["mac.tail1234.ts.net:8444"]
        guard case .conflict = make(funnel).enable() else { return XCTFail("a Funnel entry is not ours") }
        XCTAssertTrue(funnel.mutating.isEmpty)
    }

    func testAnOwnMappingAlreadyThereIsAdoptedWithoutRunningServe() {
        let fake = FakeTailscale()
        fake.serve(8444, to: "http://127.0.0.1:8795")
        XCTAssertEqual(make(fake).enable(), .on(url: expectedURL))
        XCTAssertTrue(fake.mutating.isEmpty)
    }

    func testAVerificationFailureShowsAnErrorAndLeavesTheChoiceOff() {
        // Serve reports success but the mapping is not there.
        let noEffect = FakeTailscale()
        noEffect.serveNoEffect = true
        let a = make(noEffect)
        guard case .failed(let message) = a.enable() else { return XCTFail("expected a failure") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(a.optedIn)
        XCTAssertNil(a.publicURL)

        // Status cannot be read after the change: ownership is unconfirmed, so 8444 is left alone. The mapping may be
        // active, so the state is "not confirmed" (stored choice kept, no verified URL), never a plain Off.
        let blind = FakeTailscale()
        blind.statusFailsAfterMutation = true
        let b = make(blind)
        guard case .failed = b.enable() else { return XCTFail("expected a failure") }
        XCTAssertEqual(blind.mutating, [onArgs], "an unconfirmed mapping is not removed")
        XCTAssertFalse(b.optedIn, "an unverified attempt never persists the opt-in")
        XCTAssertTrue(b.unconfirmed, "the in-memory state says the mapping may be active")
        XCTAssertNil(b.publicURL)
        XCTAssertEqual(MenuModel.tailnetMenu(offered: true, publicURL: b.publicURL, optedIn: b.optedIn || b.unconfirmed).stateLine,
                       "Tailnet access: not confirmed (see the log)")
    }

    func testAFailedMutatingServeIsNotRepeatedOnTheNextCli() {
        let fake = FakeTailscale()
        fake.serveFails = true
        let e = TailnetExposure(defaults: defaults, loginDetected: true, backendPort: 8795,
                                runner: { cli, args, t in fake.run(cli, args, t) },
                                candidates: { ["/fake/a", "/fake/b"] }, sleep: { _ in }, log: { _ in })
        guard case .failed = e.enable() else { return XCTFail("expected a failure") }
        XCTAssertFalse(e.optedIn)
        XCTAssertLessThanOrEqual(fake.mutating.count, 2, "one try plus the single re-read retry, never one per CLI")
    }

    func testServeAndStatusErrorsLeaveTheChoiceOff() {
        let serveFails = FakeTailscale()
        serveFails.serveFails = true
        let a = make(serveFails)
        guard case .failed = a.enable() else { return XCTFail() }
        XCTAssertFalse(a.optedIn)

        let noStatus = FakeTailscale()
        noStatus.statusFails = true
        let b = make(noStatus)
        guard case .failed = b.enable() else { return XCTFail() }
        XCTAssertTrue(noStatus.mutating.isEmpty, "never maps without having read what is there")
        XCTAssertFalse(b.optedIn)

        let noName = FakeTailscale()
        noName.dnsFails = true
        let c = make(noName)
        guard case .failed = c.enable() else { return XCTFail() }
        XCTAssertTrue(noName.mutating.isEmpty)
        XCTAssertFalse(c.optedIn)
    }

    func testARetryAfterATimeoutStillWorks() {
        let fake = FakeTailscale()
        fake.timeoutFirstAttempt = true
        XCTAssertEqual(make(fake).enable(), .on(url: expectedURL))
        XCTAssertEqual(fake.mutating, [onArgs])
    }

    // MARK: turning off

    func testTurningOffRunsTheExpectedArgumentsAndVerifies() {
        let fake = FakeTailscale()
        fake.serve(443, to: "http://127.0.0.1:3000")
        let exposure = make(fake)
        XCTAssertEqual(exposure.enable(), .on(url: expectedURL))
        fake.calls = []
        XCTAssertEqual(exposure.disable(), .off)
        XCTAssertEqual(fake.mutating, [offArgs])
        XCTAssertNil(fake.web["mac.tail1234.ts.net:8444"])
        XCTAssertEqual(fake.web["mac.tail1234.ts.net:443"], "http://127.0.0.1:3000")
        XCTAssertEqual(fake.calls.last, ["serve", "status", "--json"], "removal is verified")
        XCTAssertFalse(exposure.optedIn)
        XCTAssertNil(exposure.publicURL)
    }

    func testTurningOffKeepsTheChoiceWhenTheMappingIsStillThere() {
        let fake = FakeTailscale()
        let exposure = make(fake)
        _ = exposure.enable()
        fake.offNoEffect = true
        guard case .failed = exposure.disable() else { return XCTFail("expected a failure") }
        XCTAssertTrue(exposure.optedIn)
        XCTAssertEqual(exposure.publicURL, expectedURL)
    }

    func testTurningOffNeverRemovesAForeignMapping() {
        let fake = FakeTailscale()
        fake.serve(8444, to: "http://127.0.0.1:9000")
        defaults.set(true, forKey: TailnetExposure.optInKey)
        let exposure = make(fake)
        XCTAssertEqual(exposure.disable(), .conflict(existing: "http://127.0.0.1:9000"))
        XCTAssertTrue(fake.mutating.isEmpty)
        XCTAssertFalse(exposure.optedIn)
    }

    // MARK: launch re-apply

    func testAPersistedOptInIsReappliedOnlyWhenTheMappingIsMissing() {
        defaults.set(true, forKey: TailnetExposure.optInKey)

        let missing = FakeTailscale()
        let logs = LogBox()
        XCTAssertEqual(make(missing, logs: logs).reapplyAtLaunch(), .on(url: expectedURL))
        XCTAssertEqual(missing.mutating, [onArgs])
        XCTAssertTrue(logs.lines.contains { $0.contains("re-applying") })

        let present = FakeTailscale()
        present.serve(8444, to: "http://127.0.0.1:8795")
        let exposure = make(present)
        XCTAssertEqual(exposure.reapplyAtLaunch(), .on(url: expectedURL))
        XCTAssertTrue(present.mutating.isEmpty, "an existing mapping is left as it is")
        XCTAssertEqual(exposure.publicURL, expectedURL, "the menu still gets the URL")

        let foreign = FakeTailscale()
        foreign.serve(8444, to: "http://127.0.0.1:9000")
        XCTAssertEqual(make(foreign).reapplyAtLaunch(), .conflict(existing: "http://127.0.0.1:9000"))
        XCTAssertTrue(foreign.mutating.isEmpty)
    }

    // MARK: no login with a leftover mapping

    func testALeftoverOwnMappingIsRemovedAtLaunchWithoutALoginAndTheOptInIsKept() {
        defaults.set(true, forKey: TailnetExposure.optInKey)
        let fake = FakeTailscale()
        fake.serve(8444, to: "http://127.0.0.1:8795")
        fake.serve(443, to: "http://127.0.0.1:3000")
        let exposure = make(fake, login: false)
        XCTAssertEqual(exposure.withdrawWithoutLogin(), .off)
        XCTAssertEqual(fake.mutating, [offArgs])
        XCTAssertNil(fake.web["mac.tail1234.ts.net:8444"])
        XCTAssertEqual(fake.web["mac.tail1234.ts.net:443"], "http://127.0.0.1:3000", "other ports stay")
        XCTAssertTrue(exposure.optedIn, "kept for a later launch that detects the login")
    }

    // Decision of record rows A to D (no login at launch).

    func testRowAForeignOrAbsentMappingContinuesTokenOnly() {
        let foreign = FakeTailscale()
        foreign.serve(8444, to: "http://127.0.0.1:9000")
        XCTAssertNil(make(foreign, login: false).withdrawWithoutLogin())
        XCTAssertTrue(foreign.mutating.isEmpty)
        XCTAssertEqual(foreign.web["mac.tail1234.ts.net:8444"], "http://127.0.0.1:9000")

        let none = FakeTailscale()
        XCTAssertNil(make(none, login: false).withdrawWithoutLogin())
        XCTAssertTrue(none.mutating.isEmpty)
    }

    func testRowAMixedHandlerAndFunnelMappingsFailClosedWithoutTouchingThem() {
        let mixed = FakeTailscale()
        mixed.serve(8444, to: "http://127.0.0.1:8795")
        mixed.extraHandlers["mac.tail1234.ts.net:8444"] = ["/x": "http://127.0.0.1:1"]
        guard case .failed = make(mixed, login: false).withdrawWithoutLogin() else { return XCTFail("mixed handlers must fail closed") }
        XCTAssertTrue(mixed.mutating.isEmpty, "someone else's config is not edited")

        let funnel = FakeTailscale()
        funnel.serve(8444, to: "http://127.0.0.1:8795")
        funnel.funnel = ["mac.tail1234.ts.net:8444"]
        guard case .failed = make(funnel, login: false).withdrawWithoutLogin() else { return XCTFail("Funnel must fail closed") }
        XCTAssertTrue(funnel.mutating.isEmpty)

        let tcp = FakeTailscale()
        tcp.tcpForward[8444] = "127.0.0.1:8795"
        guard case .failed = make(tcp, login: false).withdrawWithoutLogin() else { return XCTFail("a TCP forward to this app must fail closed") }

        let other = FakeTailscale()
        other.serve(8444, to: "http://127.0.0.1:87950")
        XCTAssertNil(make(other, login: false).withdrawWithoutLogin(), "a different port that starts with the same digits is foreign")
    }

    func testRowALegacyOwnMappingWithoutAnOptInKeyIsWithdrawn() {
        XCTAssertFalse(defaults.bool(forKey: TailnetExposure.optInKey))
        let fake = FakeTailscale()
        fake.serve(8444, to: "http://127.0.0.1:8795")
        XCTAssertEqual(make(fake, login: false).withdrawWithoutLogin(), .off)
        XCTAssertEqual(fake.mutating, [offArgs])
    }

    func testRowBUnreadableStatusWithARunningDaemonFailsClosedOptInOrNot() {
        for optIn in [false, true] {
            defaults.set(optIn, forKey: TailnetExposure.optInKey)
            let failing = FakeTailscale()
            failing.statusFails = true
            guard case .failed = make(failing, login: false).withdrawWithoutLogin() else { return XCTFail("exit status failure, optIn \(optIn)") }
            XCTAssertTrue(failing.mutating.isEmpty)
            let empty = FakeTailscale()
            empty.statusEmpty = true
            guard case .failed = make(empty, login: false).withdrawWithoutLogin() else { return XCTFail("empty stdout, optIn \(optIn)") }
            XCTAssertTrue(empty.mutating.isEmpty)
        }
    }

    func testRowCADaemonThatReportsNotRunningContinuesTokenOnlyOptInOrNot() {
        for optIn in [false, true] {
            defaults.set(optIn, forKey: TailnetExposure.optInKey)
            for state in ["Stopped", "NeedsLogin", "Starting"] {
                let fake = FakeTailscale()
                fake.backendState = state
                fake.statusFails = true
                let e = make(fake, login: false)
                XCTAssertNil(e.withdrawWithoutLogin(), "a launch before tailscaled is Running is not blocked: \(state)")
                XCTAssertTrue(e.uncertain, "the caller must recheck on a short interval: \(state)")
                XCTAssertTrue(fake.mutating.isEmpty)
            }
        }
    }

    func testAnUnreadableTailscaleStatusIsNotADaemonDownFailsClosed() {
        for optIn in [false, true] {
            defaults.set(optIn, forKey: TailnetExposure.optInKey)
            let unparsable = FakeTailscale()   // status prints something that is not JSON
            unparsable.dnsFails = true
            unparsable.serve(8444, to: "http://127.0.0.1:8795")
            guard case .failed = make(unparsable, login: false).withdrawWithoutLogin() else { return XCTFail("unparsable status must fail closed") }
            XCTAssertTrue(unparsable.mutating.isEmpty)
            let noState = FakeTailscale()      // JSON without a BackendState
            noState.backendState = nil
            guard case .failed = make(noState, login: false).withdrawWithoutLogin() else { return XCTFail("missing BackendState must fail closed") }
            XCTAssertTrue(noState.mutating.isEmpty)
        }
    }

    func testDaemonStateEvidenceTable() {
        // (name, configure, expectation) with an own mapping live: only positive evidence of "down" continues.
        let cases: [(String, (FakeTailscale) -> Void, Bool)] = [
            ("timeout", { $0.statusTimesOut = true }, false),
            ("empty stdout, exit 0", { $0.statusExit = (0, "") }, false),
            ("garbage JSON", { $0.statusExit = (0, "not json {") }, false),
            ("unknown stderr, exit 1", { $0.statusExit = (1, "something odd happened") }, false),
            ("signal kill, no output", { $0.statusExit = (9, "") }, false),
            ("known stderr, exit 0 is not a CLI failure", { $0.statusExit = (0, "failed to connect to local tailscaled") }, false),
            ("known stderr: failed to connect", { $0.statusExit = (1, "failed to connect to local tailscaled; it doesn't appear to be running") }, true),
            ("known stderr: is Tailscale running?", { $0.statusExit = (1, "Is Tailscale running?") }, true),
            ("known stderr: stopped", { $0.statusExit = (1, "Tailscale is stopped.") }, true),
            ("known stderr: GUI failed to start", { $0.statusExit = (1, "The Tailscale GUI failed to start") }, true),
            ("BackendState Stopped", { $0.backendState = "Stopped" }, true),
            ("BackendState NeedsLogin", { $0.backendState = "NeedsLogin" }, true),
            ("BackendState NoState", { $0.backendState = "NoState" }, true),
        ]
        for (name, configure, continues) in cases {
            let fake = FakeTailscale()
            fake.serve(8444, to: "http://127.0.0.1:8795")
            configure(fake)
            let outcome = make(fake, login: false).withdrawWithoutLogin()
            if continues { XCTAssertNil(outcome, name) } else if case .failed = outcome {} else { XCTFail("must fail closed: \(name)") }
            XCTAssertTrue(fake.mutating.isEmpty, name)
        }
        // BackendState Running with an own mapping: withdrawn.
        let running = FakeTailscale()
        running.serve(8444, to: "http://127.0.0.1:8795")
        XCTAssertEqual(make(running, login: false).withdrawWithoutLogin(), .off)
    }

    func testTheKnownDaemonMessageListMatchesOnlyKnownText() {
        XCTAssertTrue(TailnetExposure.isDaemonUnreachable(output: Data("Is Tailscale running?".utf8)))
        XCTAssertFalse(TailnetExposure.isDaemonUnreachable(output: Data("permission denied".utf8)))
        XCTAssertFalse(TailnetExposure.isDaemonUnreachable(output: Data()))
    }

    func testAnAllowListLaunchWithAFailedLoginProbeNeverWithdrawsItsMapping() {
        let fake = FakeTailscale()
        fake.serve(8444, to: "http://127.0.0.1:8795")
        let exposure = TailnetExposure(defaults: defaults, loginDetected: false, tokenOnly: false, backendPort: 8795,
                                       runner: { cli, args, t in fake.run(cli, args, t) },
                                       sleep: { _ in }, log: { _ in })
        XCTAssertNil(exposure.withdrawWithoutLogin())
        XCTAssertTrue(fake.calls.isEmpty, "an allow list means the token is never alone: nothing is read or run")
        XCTAssertEqual(fake.web["mac.tail1234.ts.net:8444"], "http://127.0.0.1:8795")
    }

    func testReapplyWithAForeignMappingClearsTheOptInAndTouchesNothing() {
        defaults.set(true, forKey: TailnetExposure.optInKey)
        let fake = FakeTailscale()
        fake.serve(8444, to: "http://127.0.0.1:9000")
        let exposure = make(fake)
        guard case .conflict? = exposure.reapplyAtLaunch() else { return XCTFail("expected a conflict") }
        XCTAssertFalse(exposure.optedIn)
        XCTAssertTrue(fake.mutating.isEmpty)
    }

    func testRowDNoCLIContinuesTokenOnlyAndNothingRuns() {
        let fake = FakeTailscale()
        let exposure = TailnetExposure(defaults: defaults, loginDetected: false, backendPort: 8795,
                                       runner: { cli, args, t in fake.run(cli, args, t) },
                                       candidates: { [] }, sleep: { _ in }, log: { _ in })
        XCTAssertNil(exposure.withdrawWithoutLogin())
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testTheRecheckWithdrawsAMappingThatAppearsAfterLaunchAndLogsTransitionsOnce() {
        let fake = FakeTailscale()
        fake.backendState = "Stopped"   // daemon not running at launch
        let logs = LogBox()
        let exposure = make(fake, login: false, logs: logs)
        XCTAssertNil(exposure.withdrawWithoutLogin())
        XCTAssertNil(exposure.withdrawWithoutLogin())
        XCTAssertEqual(logs.lines.filter { $0.contains("reports it is not running") }.count, 1, "same state logs once")
        fake.backendState = "Running"   // the daemon starts, with a persisted mapping to this app
        fake.serve(8444, to: "http://127.0.0.1:8795")
        XCTAssertEqual(exposure.withdrawWithoutLogin(), .off)
        XCTAssertEqual(fake.mutating, [offArgs])
        // A later tick finds nothing and stays quiet about repeats.
        XCTAssertNil(exposure.withdrawWithoutLogin())
        XCTAssertNil(exposure.withdrawWithoutLogin())
        XCTAssertEqual(logs.lines.filter { $0.contains("nothing is mapped") }.count, 1)
        // A foreign-only mapping that later also reaches this app fails the recheck.
        fake.serve(8444, to: "http://127.0.0.1:8795")
        fake.offNoEffect = true
        guard case .failed = exposure.withdrawWithoutLogin() else { return XCTFail("an unremovable own mapping fails") }
    }

    func testEmptyServeStatusIsUnreadableForEnableAndNothingIsMapped() {
        let fake = FakeTailscale()
        fake.statusEmpty = true
        let exposure = make(fake)
        guard case .failed = exposure.enable() else { return XCTFail("empty stdout must refuse") }
        XCTAssertTrue(fake.mutating.isEmpty)
        XCTAssertFalse(exposure.optedIn)
    }

    func testATimedOutServeIsNotReissuedBlindly() {
        let fake = FakeTailscale()
        fake.firstServeTimesOutButApplies = true
        XCTAssertEqual(make(fake).enable(), .on(url: expectedURL))
        XCTAssertEqual(fake.mutating, [onArgs], "applied despite the timeout: re-read, no second serve")
    }

    func testTheReleaseBinaryDoesNotContainTheTestOverrideName() throws {
        let dir = Bundle(for: TailnetExposureTests.self).bundleURL.deletingLastPathComponent()
        // .../.build/<triple>/debug/ -> .../release/
        let release = dir.deletingLastPathComponent().appendingPathComponent("release/oab-computer")
        guard FileManager.default.fileExists(atPath: release.path) else { throw XCTSkip("no release binary built") }
        let data = try Data(contentsOf: release)
        XCTAssertNil(data.range(of: Data("OAB_COMPUTER_NO_TAILNET_EXPOSURE".utf8)))
    }

    func testWithdrawReportsAMappingThatWillNotGoAway() {
        let fake = FakeTailscale()
        fake.serve(8444, to: "http://127.0.0.1:8795")
        fake.offNoEffect = true
        guard case .failed = make(fake, login: false).withdrawWithoutLogin() else { return XCTFail("expected a failure") }
    }

    func testWithALoginTheWithdrawRunsNothing() {
        let fake = FakeTailscale()
        fake.serve(8444, to: "http://127.0.0.1:8795")
        XCTAssertNil(make(fake, login: true).withdrawWithoutLogin())
        XCTAssertTrue(fake.calls.isEmpty)
    }

    // MARK: launch re-apply failure and an existing own mapping

    func testAFailedLaunchReapplyKeepsTheStoredOptIn() {
        defaults.set(true, forKey: TailnetExposure.optInKey)
        let fake = FakeTailscale()
        fake.serveFails = true
        let exposure = make(fake)
        guard case .failed = exposure.reapplyAtLaunch() else { return XCTFail("expected a failure") }
        XCTAssertTrue(exposure.optedIn, "a transient failure at launch must not drop the choice")
        // A user-driven attempt that fails still leaves the choice off.
        guard case .failed = exposure.enable() else { return XCTFail("expected a failure") }
        XCTAssertFalse(exposure.optedIn)
    }

    func testAnExistingOwnMappingWithoutAnOptInIsShownAsOnWithoutRunningServe() {
        let fake = FakeTailscale()
        fake.serve(8444, to: "http://127.0.0.1:8795")
        let exposure = make(fake)
        XCTAssertEqual(exposure.adoptExistingMapping(), .on(url: expectedURL))
        XCTAssertEqual(exposure.publicURL, expectedURL)
        XCTAssertTrue(fake.mutating.isEmpty)
        XCTAssertFalse(exposure.optedIn, "observing a mapping is not consent")
        XCTAssertNil(defaults.object(forKey: TailnetExposure.optInKey))
        XCTAssertNil(exposure.reapplyAtLaunch(), "so a later launch never re-creates it")

        defaults.removeObject(forKey: TailnetExposure.optInKey)
        let foreign = FakeTailscale()
        foreign.serve(8444, to: "http://127.0.0.1:9000")
        let other = make(foreign)
        XCTAssertNil(other.adoptExistingMapping())
        XCTAssertNil(other.publicURL)
    }

    func testALoginLaunchWithNoOptInIsUnknownUntilTheServeStatusIsRead() {
        let fake = FakeTailscale()
        fake.serve(8444, to: "http://127.0.0.1:8795")
        let exposure = make(fake)
        XCTAssertTrue(exposure.uncertain, "an existing mapping may be live before the read finishes")
        exposure.adoptExistingMapping()
        XCTAssertFalse(exposure.uncertain)
        XCTAssertTrue(exposure.existingMapping)

        let none = make(FakeTailscale())
        XCTAssertTrue(none.uncertain)
        none.adoptExistingMapping()
        XCTAssertFalse(none.uncertain, "a status read that shows no mapping proves it Off")
    }

    func testCheckingLastsUntilTheFirstReadFinishes() {
        let fake = FakeTailscale()
        fake.serve(8444, to: "http://127.0.0.1:9000")   // a foreign mapping
        let exposure = make(fake)
        XCTAssertTrue(exposure.checking)
        XCTAssertNil(exposure.reapplyAtLaunch(), "no opt-in: nothing to re-apply")
        XCTAssertTrue(exposure.checking, "the adopt read has not run yet")
        XCTAssertNil(exposure.adoptExistingMapping())
        XCTAssertFalse(exposure.checking)
        XCTAssertFalse(exposure.uncertain, "a foreign mapping proves ours absent")
        XCTAssertTrue(fake.mutating.isEmpty)

        defaults.set(true, forKey: TailnetExposure.optInKey)
        let opted = make(FakeTailscale())
        XCTAssertTrue(opted.checking)
        opted.markLaunchReadDone()
        XCTAssertFalse(opted.checking)
    }

    func testAnExistingMappingIsFlaggedNotManagedAndManageRecordsTheOptInWithoutServe() {
        let fake = FakeTailscale()
        fake.serve(8444, to: "http://127.0.0.1:8795")
        let exposure = make(fake)
        XCTAssertNil(exposure.manageExistingMapping().urlIfOn, "nothing to manage before an existing mapping was seen")
        XCTAssertFalse(exposure.optedIn)
        XCTAssertTrue(fake.calls.isEmpty)
        exposure.adoptExistingMapping()
        XCTAssertTrue(exposure.existingMapping)
        XCTAssertFalse(exposure.optedIn)
        let menu = MenuModel.tailnetMenu(offered: true, publicURL: exposure.publicURL, optedIn: exposure.optedIn,
                                         existingMapping: exposure.existingMapping)
        XCTAssertEqual(menu.stateLine, "Tailnet access: On (existing mapping, not managed by this app)")
        XCTAssertEqual(menu.manageTitle, "Manage with this app")
        XCTAssertEqual(exposure.manageExistingMapping(), .on(url: expectedURL))
        XCTAssertTrue(exposure.optedIn)
        XCTAssertFalse(exposure.existingMapping)
        XCTAssertTrue(fake.mutating.isEmpty, "managing an existing mapping changes nothing in Tailscale")
        let after = MenuModel.tailnetMenu(offered: true, publicURL: exposure.publicURL, optedIn: exposure.optedIn,
                                          existingMapping: exposure.existingMapping)
        XCTAssertEqual(after.stateLine, "Tailnet access: On")
        XCTAssertNil(after.manageTitle)
    }

    func testManageFailsWithoutRecordingWhenTheMappingWentAway() {
        let fake = FakeTailscale()
        fake.serve(8444, to: "http://127.0.0.1:8795")
        let exposure = make(fake)
        exposure.adoptExistingMapping()
        fake.web.removeAll()
        guard case .failed = exposure.manageExistingMapping() else { return XCTFail("expected a failure") }
        XCTAssertFalse(exposure.optedIn)
        XCTAssertNil(exposure.publicURL)
        XCTAssertFalse(exposure.existingMapping)
    }

    func testAHeldPortRunsNoTailscaleCommandAtLaunchWhateverTheLaunchMode() {
        do {
            let fake = FakeTailscale()
            fake.serve(8444, to: "http://127.0.0.1:8795")   // the running instance's mapping
            let exposure = make(fake, login: false)
            XCTAssertEqual(exposure.withdrawAtLaunch(portHeld: { true }), .portHeld)
            XCTAssertTrue(fake.calls.isEmpty, "not even a read may run while the port is held")
            XCTAssertTrue(fake.mutating.isEmpty)
            XCTAssertEqual(fake.web["mac.tail1234.ts.net:8444"], "http://127.0.0.1:8795", "the other instance's mapping is untouched")
        }
        // A free port still withdraws the leftover mapping.
        let fake = FakeTailscale()
        fake.serve(8444, to: "http://127.0.0.1:8795")
        XCTAssertEqual(make(fake, login: false).withdrawAtLaunch(portHeld: { false }), .checked(.off))
        XCTAssertEqual(fake.mutating, [offArgs])
    }

    func testRecheckIntervalIsOneSecondForTheFirstMinuteThenFive() {
        XCTAssertEqual(TailnetExposure.recheckInterval(sinceLaunch: 0), 1)
        XCTAssertEqual(TailnetExposure.recheckInterval(sinceLaunch: 59.9), 1)
        XCTAssertEqual(TailnetExposure.recheckInterval(sinceLaunch: 60), 5)
        XCTAssertEqual(TailnetExposure.recheckInterval(sinceLaunch: 600), 5)
    }

    func testChildEnvironmentDropsTheLaunchdJobLabel() {
        let env = LaunchdJob.childEnvironment(["XPC_SERVICE_NAME": LaunchdJob.ownLabel, "PATH": "/usr/bin"])
        XCTAssertNil(env["XPC_SERVICE_NAME"])
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertNil(LaunchdJob.jobLabel(environment: env, parentPID: 1), "an orphan reparented to launchd is not the job")
    }

    func testExecStartEnvironmentNeverCarriesTheLaunchdJobLabel() {
        let env = resolveJobEnv(["env": ["XPC_SERVICE_NAME": .string(LaunchdJob.ownLabel), "FOO": .string("bar")]])
        XCTAssertNil(env["XPC_SERVICE_NAME"], "neither inherited nor caller-set")
        XCTAssertEqual(env["FOO"], "bar")
        XCTAssertNil(LaunchdJob.jobLabel(environment: env, parentPID: 1))
    }

    // MARK: parsing and the real runner

    func testServeStatusParsing() {
        let backend = "http://127.0.0.1:8795"
        func parse(_ s: String) -> TailnetExposure.ServeMapping? {
            TailnetExposure.mapping(serveStatusJSON: Data(s.utf8), httpsPort: 8444, backend: backend)
        }
        XCTAssertNil(parse(""), "empty stdout is unreadable, not proof of absence")
        XCTAssertEqual(parse("{}"), .absent)
        XCTAssertNil(parse("not json"))
        XCTAssertEqual(parse(#"{"Web":{"m.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}"#), .absent)
        XCTAssertEqual(parse(#"{"Web":{"m.ts.net:8444":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8795/"}}}}}"#), .ours)
        XCTAssertEqual(parse(#"{"Web":{"m.ts.net:8444":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8795"},"/x":{"Proxy":"http://127.0.0.1:1"}}}}}"#),
                       .foreign(description: "http://127.0.0.1:1 at /x, http://127.0.0.1:8795"))
        XCTAssertEqual(parse(#"{"Web":{"m.ts.net:84440":{"Handlers":{"/":{"Proxy":"http://x"}}}}}"#), .absent,
                       "a port that merely ends in the same digits is another port")
    }

    func testTheRealRunnerPassesArgumentsThroughTheSameCLIRunner() throws {
        let dir = NSTemporaryDirectory() + "tsargs-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = dir + "/echo-args"   // a stand-in script, not a Tailscale binary
        try "#!/bin/sh\necho \"$@\"\necho \"TERM_PROGRAM=$TERM_PROGRAM\"\n".write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        guard case let .finished(output, status) = FirstRunSetup.systemTailscaleCommandRunner(script, ["a", "--b=1", "c"], 5) else {
            return XCTFail("the script did not finish")
        }
        XCTAssertEqual(status, 0)
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("a --b=1 c\n"), text)
        XCTAssertFalse(text.contains("TERM_PROGRAM=\n"), "TERM_PROGRAM is always set for the CLI")
    }

    func testTheCopyNamesTheURLAndTheTokenRequirement() {
        let detail = WizardCopy.tailnetDetail(name: nil)
        XCTAssertTrue(detail.contains("https://<this Mac's tailnet name>:8444/mcp"))
        XCTAssertTrue(detail.contains("screenshot"))
        XCTAssertTrue(detail.contains("token"))
        XCTAssertTrue(WizardCopy.tailnetDetail(name: "mac.ts.net").contains("https://mac.ts.net:8444/mcp"))
    }

    func testInstallerPublicURLOnAnotherPortIsLeftToTheInstaller() {
        XCTAssertFalse(TailnetExposure.installerOwnsOtherPort(publicURL: nil))
        XCTAssertFalse(TailnetExposure.installerOwnsOtherPort(publicURL: "https://mac.tail1.ts.net:8444/mcp"))
        XCTAssertTrue(TailnetExposure.installerOwnsOtherPort(publicURL: "https://mac.tail1.ts.net:9443/mcp"))
        XCTAssertTrue(TailnetExposure.installerOwnsOtherPort(publicURL: "https://mac.tail1.ts.net/mcp"))
    }
}
