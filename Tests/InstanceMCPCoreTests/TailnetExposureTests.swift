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
    var statusFails = false
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
            guard !dnsFails, let dns else { return .finished(output: Data("The Tailscale GUI failed to start".utf8), status: 0) }
            return .finished(output: Data(#"{"Self":{"DNSName":"\#(dns)","UserID":7},"User":{"7":{"LoginName":"owner@example.com"}}}"#.utf8), status: 0)
        }
        if args == ["serve", "status", "--json"] {
            if statusFails || (statusFailsAfterMutation && mutated) { return .finished(output: Data(), status: 1) }
            return .finished(output: statusJSON(), status: 0)
        }
        guard args.first == "serve" else {
            XCTFail("unexpected tailscale arguments \(args)")
            return .finished(output: Data(), status: 2)
        }
        mutated = true
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
            webObj[hostPort] = ["Handlers": ["/": ["Proxy": proxy]]]
            if let port = hostPort.split(separator: ":").last { tcp[String(port)] = ["HTTPS": true] }
        }
        for (port, target) in tcpForward { tcp[String(port)] = ["TCPForward": target] }
        if !webObj.isEmpty { root["Web"] = webObj }
        if !tcp.isEmpty { root["TCP"] = tcp }
        if !funnel.isEmpty { root["AllowFunnel"] = Dictionary(uniqueKeysWithValues: funnel.map { ($0, true) }) }
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }
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

        // Status cannot be read after the change: ownership is unconfirmed, so 8444 is left alone and the choice stays off.
        let blind = FakeTailscale()
        blind.statusFailsAfterMutation = true
        let b = make(blind)
        guard case .failed = b.enable() else { return XCTFail("expected a failure") }
        XCTAssertEqual(blind.mutating, [onArgs], "an unconfirmed mapping is not removed")
        XCTAssertFalse(b.optedIn)
        XCTAssertNil(b.publicURL)
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

    func testWithoutALoginAForeignOrMissingMappingIsLeftAlone() {
        let foreign = FakeTailscale()
        foreign.serve(8444, to: "http://127.0.0.1:9000")
        XCTAssertNil(make(foreign, login: false).withdrawWithoutLogin())
        XCTAssertTrue(foreign.mutating.isEmpty)
        XCTAssertEqual(foreign.web["mac.tail1234.ts.net:8444"], "http://127.0.0.1:9000")

        let none = FakeTailscale()
        XCTAssertNil(make(none, login: false).withdrawWithoutLogin())
        XCTAssertTrue(none.mutating.isEmpty)

        let unreadable = FakeTailscale()
        unreadable.statusFails = true
        XCTAssertNil(make(unreadable, login: false).withdrawWithoutLogin(), "no opt-in: no mapping of ours can be live")
        XCTAssertTrue(unreadable.mutating.isEmpty)

        let optedIn = FakeTailscale()
        optedIn.statusFails = true
        defaults.set(true, forKey: TailnetExposure.optInKey)
        guard case .failed = make(optedIn, login: false).withdrawWithoutLogin() else { return XCTFail("opted in and unprovable fails closed") }
        XCTAssertTrue(optedIn.mutating.isEmpty)
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

    // MARK: parsing and the real runner

    func testServeStatusParsing() {
        let backend = "http://127.0.0.1:8795"
        func parse(_ s: String) -> TailnetExposure.ServeMapping? {
            TailnetExposure.mapping(serveStatusJSON: Data(s.utf8), httpsPort: 8444, backend: backend)
        }
        XCTAssertEqual(parse(""), .absent)
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
}
