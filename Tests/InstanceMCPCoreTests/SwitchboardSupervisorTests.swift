import Foundation
import XCTest
@testable import InstanceMCPCore

// MARK: - Fakes: a dialer that records lifecycle and emits states on demand

actor FakeDialer: SwitchboardDialer {
    private(set) var started = 0
    private(set) var cancelled = false
    private var state: ReverseAttachClient.State = .idle
    private var lastClose: ReverseAttachClient.CloseRecord?
    private let onState: @Sendable (ReverseAttachClient.State) -> Void

    init(onState: @escaping @Sendable (ReverseAttachClient.State) -> Void) {
        self.onState = onState
    }

    func start() { started += 1 }
    func cancel() { cancelled = true }

    func snapshot() -> (state: ReverseAttachClient.State, lastClose: ReverseAttachClient.CloseRecord?) {
        (state, lastClose)
    }

    func emit(_ s: ReverseAttachClient.State, close: ReverseAttachClient.CloseRecord? = nil) {
        state = s
        if let close { lastClose = close }
        onState(s)
    }
}

/// Records every dialer the supervisor makes. The factory is synchronous, so the
/// list sits behind a lock.
final class FakeFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var dialers: [FakeDialer] = []

    func make(_ onState: @escaping @Sendable (ReverseAttachClient.State) -> Void) -> SwitchboardDialer {
        let d = FakeDialer(onState: onState)
        lock.lock(); dialers.append(d); lock.unlock()
        return d
    }

    var factory: SwitchboardSupervisor.Factory {
        { [self] _, onState in make(onState) }
    }

    var made: [FakeDialer] {
        lock.lock(); defer { lock.unlock() }
        return dialers
    }
}

final class SwitchboardSupervisorTests: XCTestCase {
    private var dir: URL!
    private var fakes: FakeFactory!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sbsup-\(UUID().uuidString)")
        fakes = FakeFactory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private var store: SwitchboardConfigStore { SwitchboardConfigStore(directory: dir) }
    private let goodURL = "wss://switchboard.example.test/vm/attach"

    private func supervisor() -> SwitchboardSupervisor {
        SwitchboardSupervisor(store: store, computer: "Test Mac", factory: fakes.factory)
    }

    private func edit(url: String? = nil, secret: String? = nil, profile: ToolProfile = .observe,
                      confirmed: Bool = false) -> SwitchboardConfigStore.Edit {
        .init(url: url ?? goodURL, newSecret: secret, profile: profile, ownerConfirmed: confirmed)
    }

    private func configured(_ sup: SwitchboardSupervisor, secret: String = "s3cret") async throws {
        _ = try await sup.save(edit(secret: secret))
    }

    /// Poll until the supervisor reaches a status. Callbacks hop through Tasks, so
    /// a test cannot read the result on the same turn.
    private func waitFor(_ sup: SwitchboardSupervisor, file: StaticString = #filePath, line: UInt = #line,
                         _ predicate: (SwitchboardStatus) -> Bool) async throws {
        for _ in 0..<200 {
            if predicate(await sup.status) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("status never matched; last \(await sup.status)", file: file, line: line)
    }

    func testStartDialsWithTheSavedConfigAndShowsDialling() async throws {
        let sup = supervisor()
        try store.save(edit(secret: "s3cret"))
        let cfg = try XCTUnwrap(store.load())

        await sup.start(cfg)

        XCTAssertEqual(fakes.made.count, 1)
        let started = await fakes.made[0].started
        XCTAssertEqual(started, 1)
        let kind = await sup.status.kind
        XCTAssertEqual(kind, .dialling)
    }

    func testAFirstSaveStartsTheSwitchboard() async throws {
        let sup = supervisor()
        let initial = await sup.status.kind
        XCTAssertEqual(initial, .notConfigured)

        let outcome = try await sup.save(edit(secret: "s3cret"))

        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(fakes.made.count, 1)
    }

    func testASecretOnlyChangeKeepsTheDialerAndSaysItAppliesOnTheNextDial() async throws {
        let sup = supervisor()
        try await configured(sup, secret: "old")

        let outcome = try await sup.save(edit(secret: "rotated"))

        XCTAssertEqual(outcome, .nextDial)
        XCTAssertEqual(fakes.made.count, 1, "a secret change must not drop the attach")
        XCTAssertEqual(store.load()?.secret, "rotated")
    }

    func testAURLOrProfileChangeReconnectsAndCancelsTheOldDialer() async throws {
        let sup = supervisor()
        try await configured(sup)

        let outcome = try await sup.save(edit(url: "wss://other.example.test/vm/attach"))

        XCTAssertEqual(outcome, .reconnected)
        XCTAssertEqual(fakes.made.count, 2)
        let oldCancelled = await fakes.made[0].cancelled
        XCTAssertTrue(oldCancelled)
    }

    func testOwnerIsRefusedWithoutConfirmationAndTheRunningDialerIsUntouched() async throws {
        let sup = supervisor()
        try await configured(sup)

        do {
            _ = try await sup.save(edit(profile: .owner, confirmed: false))
            XCTFail("owner without confirmation must be refused")
        } catch {
            XCTAssertEqual(error as? SwitchboardConfigStore.Failure, .ownerNeedsConfirmation)
        }
        XCTAssertEqual(fakes.made.count, 1)
        let cancelled = await fakes.made[0].cancelled
        XCTAssertFalse(cancelled)
        XCTAssertEqual(store.load()?.profile, .observe)
    }

    func testReconnectMakesAFreshDialerFromTheSavedConfig() async throws {
        let sup = supervisor()
        try await configured(sup)

        await sup.reconnect()

        XCTAssertEqual(fakes.made.count, 2)
        let url = await sup.current?.url.absoluteString
        XCTAssertEqual(url, goodURL)
    }

    func testForgetStopsDialingDeletesTheFilesAndReportsNotConfigured() async throws {
        let sup = supervisor()
        try await configured(sup)

        try await sup.forget(confirmed: true)

        let cancelled = await fakes.made[0].cancelled
        XCTAssertTrue(cancelled)
        let kind = await sup.status.kind
        XCTAssertEqual(kind, .notConfigured)
        XCTAssertNil(store.load())
        XCTAssertEqual(store.secretState(), .notSet)
    }

    func testDialerStateReachesTheStatusAndTheCloseCodeAndComputerAreShown() async throws {
        let sup = supervisor()
        try await configured(sup)
        let changed = expectation(description: "connected")
        changed.assertForOverFulfill = false
        await sup.setOnChange { s in if s.kind == .connected { changed.fulfill() } }

        await fakes.made[0].emit(.attached)
        await fulfillment(of: [changed], timeout: 3)

        let status = await sup.status
        XCTAssertEqual(status.kind, .connected)
        XCTAssertEqual(status.profile, .observe)
        XCTAssertEqual(status.computer, "Test Mac")

        let close = ReverseAttachClient.CloseRecord(code: 4005, handshakeStatus: nil, at: Date())
        await fakes.made[0].emit(.waitingToRedial(seconds: 6), close: close)
        try await waitFor(sup) { $0.kind == .backingOff(seconds: 6) }
        let code = await sup.status.lastClose?.code
        XCTAssertEqual(code, 4005)
    }

    func testForgetWithoutConfirmationChangesNothing() async throws {
        let sup = supervisor()
        try await configured(sup)

        do {
            try await sup.forget(confirmed: false)
            XCTFail("forget without confirmation must be refused")
        } catch {
            XCTAssertEqual(error as? SwitchboardConfigStore.Failure, .forgetNeedsConfirmation)
        }
        XCTAssertEqual(fakes.made.count, 1)
        let cancelled = await fakes.made[0].cancelled
        XCTAssertFalse(cancelled)
        XCTAssertNotNil(store.load())
    }

    func testADisabledStartupShowsAsDisabledWithItsReason() async throws {
        let sup = supervisor()
        await sup.applyStartup(SwitchboardStartup.resolve(saved: nil, flags: nil, flagsGiven: true))

        let s = await sup.status
        XCTAssertEqual(s.kind, .disabled)
        XCTAssertTrue(s.title { _ in "t" }.contains("disabled"))
        XCTAssertEqual(fakes.made.count, 0, "a disabled switchboard dials nothing")
    }

    func testASavedOverrideIsShownAsANote() async throws {
        let sup = supervisor()
        try await configured(sup)
        let saved = try XCTUnwrap(store.load())
        await sup.applyStartup(SwitchboardStartup.resolve(saved: saved, flags: saved, flagsGiven: true))

        let note = await sup.status.note
        XCTAssertNotNil(note)
    }

    func testAStaleCallbackFromAReplacedDialerIsIgnored() async throws {
        let sup = supervisor()
        try await configured(sup)
        await sup.reconnect()

        await fakes.made[0].emit(.attached)
        // Let the old dialer's callback land; the status must not follow it.
        try await Task.sleep(nanoseconds: 100_000_000)

        let kind = await sup.status.kind
        XCTAssertEqual(kind, .dialling)
    }
}

// MARK: - Status model: a pure function of state, last close and config

final class SwitchboardStatusTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func make(_ state: ReverseAttachClient.State?, close: ReverseAttachClient.CloseRecord? = nil,
                      configured: Bool = true) -> SwitchboardStatus {
        SwitchboardStatus.make(state: state, lastClose: close, configured: configured, profile: .observe,
                               computer: "Test Mac")
    }

    func testStateMapsToTheFourVisibleStatuses() {
        XCTAssertEqual(make(nil, configured: false).kind, .notConfigured)
        XCTAssertEqual(make(.idle).kind, .dialling)
        XCTAssertEqual(make(.dialing).kind, .dialling)
        XCTAssertEqual(make(.attached).kind, .connected)
        XCTAssertEqual(make(.waitingToRedial(seconds: 2.4)).kind, .backingOff(seconds: 2))
        XCTAssertEqual(make(.ended(.replaced)).kind, .stopped)
    }

    func testACredentialRefusalIsBackingOffNotStopped() {
        let close = ReverseAttachClient.CloseRecord(code: nil, handshakeStatus: 401, at: when)
        let s = make(.waitingToRedial(seconds: 300), close: close)
        XCTAssertEqual(s.kind, .backingOff(seconds: 300))
        XCTAssertEqual(s.reason, "credentials refused (HTTP 401); retrying slowly")
    }

    func testReplacedStopsWithItsCodeInTheTitle() {
        let close = ReverseAttachClient.CloseRecord(code: 4002, handshakeStatus: nil, at: when)
        let s = make(.ended(.replaced), close: close)
        XCTAssertEqual(s.kind, .stopped)
        let title = s.title { _ in "09:13:20" }
        XCTAssertTrue(title.contains("replaced by another daemon"), title)
        XCTAssertTrue(title.contains("last close 4002 at 09:13:20"), title)
        XCTAssertTrue(title.contains("computer Test Mac"), title)
    }

    func testTheTitleNamesTheProfileAndNeverCarriesASecret() {
        let title = make(.attached).title { _ in "t" }
        XCTAssertEqual(title, "Switchboard: connected as observe · computer Test Mac")
        XCTAssertFalse(title.lowercased().contains("secret"))
    }

    func testNotConfiguredHasNoComputerOrClose() {
        let title = make(nil, configured: false).title { _ in "t" }
        XCTAssertEqual(title, "Switchboard: not configured")
    }
}

// MARK: - The client records its last close

final class ReverseAttachLastCloseTests: XCTestCase {
    func testLastCloseIsNilBeforeTheFirstDial() async {
        let client = ReverseAttachClient(
            config: .switchboard(url: URL(string: "ws://localhost:9/vm/attach")!, secret: "x", profile: .observe),
            server: MCPServer(name: "t", version: "0", tools: []))
        let last = await client.lastClose
        XCTAssertNil(last)
    }
}
