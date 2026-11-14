import Foundation
import Network
import XCTest
@testable import InstanceMCPCore

// MARK: - Switchboard redial policy (openab-sb SOUTHBOUND-CONTRACT §2, §5)

final class SwitchboardPolicyTests: XCTestCase {
    func testStopsOnReplacedAndOnARevokedSecret() {
        XCTAssertEqual(ReverseAttachClient.disposition(closeCode: 4002, kind: .switchboard), .stop(.replaced))
        XCTAssertEqual(ReverseAttachClient.disposition(closeCode: 4003, kind: .switchboard), .stop(.secretRevoked))
    }

    func testRedialsOnHandshakeFailureRestartAndDrops() {
        // 4005 = our initialize reply failed; the openab-pty stop codes mean nothing here.
        for code in [4005, 1001, 1000, 1006, 1011, 4001, 4004, 4010] {
            XCTAssertEqual(ReverseAttachClient.disposition(closeCode: code, kind: .switchboard), .redial, "code \(code)")
        }
    }

    func testOpenabPtyPolicyIsUnchanged() {
        // 4003 is not an openab-pty tools-attach code: it still redials there.
        XCTAssertEqual(ReverseAttachClient.disposition(closeCode: 4003), .redial)
        XCTAssertEqual(ReverseAttachClient.disposition(closeCode: 4010), .stop(.revoked))
        XCTAssertEqual(ReverseAttachClient.disposition(handshakeStatus: 401), .stop(.handshakeRejected(401)))
    }

    func testCredentialRefusalWaitsAndEverythingElseRedials() {
        // §2: a wrong secret needs an operator, so never stop a long-lived daemon on it.
        XCTAssertEqual(ReverseAttachClient.disposition(handshakeStatus: 401, kind: .switchboard), .waitForCredentials)
        XCTAssertEqual(ReverseAttachClient.disposition(handshakeStatus: 403, kind: .switchboard), .waitForCredentials)
        for status in [404, 429, 500, 502, 503] {
            XCTAssertEqual(ReverseAttachClient.disposition(handshakeStatus: status, kind: .switchboard), .redial, "\(status)")
        }
    }

    func testSwitchboardConfigUsesTheURLAsIsAndNeverExpires() {
        let url = URL(string: "wss://host.tail.ts.net/vm/attach")!
        let c = ReverseAttachClient.Config.switchboard(url: url, secret: "s", profile: .observe)
        XCTAssertEqual(c.attachURL, url)
        XCTAssertEqual(c.kind, .switchboard)
        XCTAssertEqual(c.deadline, .distantFuture)
        XCTAssertEqual(c.maxBackoff, 60)
        XCTAssertEqual(c.credentialRetry, 300)
    }

    func testJitterStaysWithinTwentyPercent() {
        for _ in 0..<200 {
            let j = ReverseAttachClient.jitter(10)
            XCTAssertGreaterThanOrEqual(j, 8); XCTAssertLessThanOrEqual(j, 12)
        }
    }
}

// MARK: - URL validation and instructions

final class SwitchboardConfigTests: XCTestCase {
    func testAcceptsWssAndLoopbackWs() throws {
        XCTAssertEqual(try Switchboard.validate("wss://sb.tail.ts.net/vm/attach").host, "sb.tail.ts.net")
        XCTAssertEqual(try Switchboard.validate("ws://127.0.0.1:8790/vm/attach").port, 8790)
        XCTAssertNoThrow(try Switchboard.validate("ws://localhost:8790/vm/attach"))
        XCTAssertNoThrow(try Switchboard.validate("ws://[::1]:8790/vm/attach"))
        XCTAssertNoThrow(try Switchboard.validate("wss://sb.example/prefix/vm/attach"))
    }

    func testRefusesPlaintextAcrossTheNetwork() {
        XCTAssertThrowsError(try Switchboard.validate("ws://100.64.0.7:8790/vm/attach")) {
            XCTAssertEqual($0 as? Switchboard.ConfigError, .plaintextToRemote("100.64.0.7"))
        }
    }

    func testRefusesOtherSchemesAndPaths() {
        for bad in ["https://sb/vm/attach", "wss://sb/mcp", "wss:///vm/attach", "vm/attach", ""] {
            XCTAssertThrowsError(try Switchboard.validate(bad), bad)
        }
    }

    func testInstructionsSayHowTheCallerArrived() {
        for p in [ToolProfile.observe] {
            let text = Switchboard.instructions(profile: p, base: "base") ?? ""
            XCTAssertTrue(text.hasPrefix("base\n\n"), p.rawValue)
            XCTAssertTrue(text.contains("OpenAB Switchboard"), p.rawValue)
            XCTAssertTrue(text.contains("`\(p.rawValue)` profile"), p.rawValue)
            XCTAssertFalse(text.contains("Connect"), "not a Connect-lent session: \(p.rawValue)")
        }
        XCTAssertEqual(Switchboard.instructions(profile: .owner, base: "base"), "base")
    }

    func testSecretFileIsReReadOnEveryDial() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-secret-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try "first\n".write(to: file, atomically: true, encoding: .utf8)
        let client = Switchboard.client(url: URL(string: "ws://127.0.0.1:1/vm/attach")!, secretFile: file,
                                        secret: "first", profile: .observe, server: fullServer())
        func bearer() async -> String? {
            await client.attachRequest().value(forHTTPHeaderField: "Authorization")
        }
        let a = await bearer()
        XCTAssertEqual(a, "Bearer first")
        try "rotated\n".write(to: file, atomically: true, encoding: .utf8)
        let b = await bearer()
        XCTAssertEqual(b, "Bearer rotated", "the dial must present the file's current secret")
        // An emptied file keeps the start-up secret rather than sending none.
        try "".write(to: file, atomically: true, encoding: .utf8)
        let c = await bearer()
        XCTAssertEqual(c, "Bearer first")
        let url = await client.attachRequest().url
        XCTAssertEqual(url?.absoluteString, "ws://127.0.0.1:1/vm/attach")
    }
}

// MARK: - End to end against a fake switchboard

final class SwitchboardEndToEndTests: XCTestCase {
    /// FakeRuntime plays the switchboard here: same wire (plain MCP, it sends
    /// `initialize` first), different close codes.
    private func run(closeWith code: UInt16, for seconds: Double) async throws
        -> (FakeRuntime, ReverseAttachClient, StateSink) {
        let sb = try FakeRuntime(secret: "s", closeWith: .privateCode(code))
        let states = StateSink()
        var cfg = ReverseAttachClient.Config.switchboard(
            url: URL(string: "ws://127.0.0.1:\(sb.port)/vm/attach")!, secret: "s", profile: .observe)
        cfg.initialBackoff = 0.2
        let server = fullServer()
        let client = ReverseAttachClient(
            config: cfg,
            server: server.scoped(to: .observe,
                                  instructions: Switchboard.instructions(profile: .observe, base: server.instructions)),
            onStateChange: { states.push($0) })
        await client.start()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return (sb, client, states)
    }

    func testServesTheSwitchboardThenStopsOnARevokedSecret() async throws {
        let (sb, client, states) = try await run(closeWith: 4003, for: 2)
        defer { sb.stop() }
        XCTAssertEqual(sb.received.count, 4, "\(sb.received)")
        XCTAssertTrue(sb.received[0]["result"]?["instructions"]?.stringValue?.contains("OpenAB Switchboard") == true)
        let names = sb.received[1]["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(names, ["screenshot"], "observe profile: look only")
        XCTAssertNotNil(sb.received[2]["error"], "exec under observe is refused")
        let final_ = await client.state
        XCTAssertEqual(final_, .ended(.secretRevoked), "\(states.all)")
        XCTAssertEqual(sb.upgradeAttempts, 1, "4003 must not redial")
    }

    func testStopsWhenReplacedByAnotherDaemon() async throws {
        let (sb, client, states) = try await run(closeWith: 4002, for: 2)
        defer { sb.stop() }
        let final_ = await client.state
        XCTAssertEqual(final_, .ended(.replaced), "\(states.all)")
        XCTAssertEqual(sb.upgradeAttempts, 1)
    }

    func testRedialsAfterAFailedHandshakeAndNeverHitsADeadline() async throws {
        let (sb, client, states) = try await run(closeWith: 4005, for: 2.5)
        defer { sb.stop() }
        XCTAssertGreaterThanOrEqual(sb.upgradeAttempts, 2, "4005 must redial: \(states.all)")
        let now = await client.state
        if case .ended = now { XCTFail("a switchboard attach has no deadline: \(states.all)") }
        await client.cancel()
    }
}
