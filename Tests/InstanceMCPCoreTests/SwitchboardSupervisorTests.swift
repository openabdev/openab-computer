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

/// Collects every line the supervisor logs, for the no-secret-in-logs test.
final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock(); lines.append(line); lock.unlock()
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
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

    func testASecretOnlyChangeKeepsAnAttachedDialerAndSaysItAppliesOnTheNextDial() async throws {
        let sup = supervisor()
        try await configured(sup, secret: "old")
        await fakes.made[0].emit(.attached)
        try await waitFor(sup) { $0.kind == .connected }

        let outcome = try await sup.save(edit(secret: "rotated"))

        XCTAssertEqual(outcome, .nextDial)
        XCTAssertEqual(fakes.made.count, 1, "a secret change must not drop the attach")
        XCTAssertEqual(store.load()?.secret, "rotated")
    }

    func testASecretOnlyChangeRedialsWhenTheDialerHasEnded() async throws {
        // After a 4002 the dialer is terminal and never reads the secret again, so the
        // save must start a new dialer or the new secret would never be used.
        let sup = supervisor()
        try await configured(sup, secret: "old")
        await fakes.made[0].emit(.ended(.replaced))
        try await waitFor(sup) { $0.kind == .stopped }

        let outcome = try await sup.save(edit(secret: "rotated"))

        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(fakes.made.count, 2)
        let oldCancelled = await fakes.made[0].cancelled
        XCTAssertTrue(oldCancelled)
    }

    func testASecretOnlyChangeRedialsWhileBackingOff() async throws {
        let sup = supervisor()
        try await configured(sup, secret: "old")
        await fakes.made[0].emit(.waitingToRedial(seconds: 300))
        try await waitFor(sup) { $0.kind == .backingOff(seconds: 300) }

        let outcome = try await sup.save(edit(secret: "rotated"))

        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(fakes.made.count, 2)
    }

    func testTheBackoffCountdownRunsDownFromTheDialersDeadline() async throws {
        let sup = supervisor()
        try await configured(sup)
        await fakes.made[0].emit(.waitingToRedial(seconds: 300))
        try await waitFor(sup) { $0.kind == .backingOff(seconds: 300) }

        let s = await sup.status
        let deadline = try XCTUnwrap(s.redialAt)
        XCTAssertTrue(s.title(now: deadline.addingTimeInterval(-300)) { _ in "t" }.contains("retry in 300 s"))
        XCTAssertTrue(s.title(now: deadline.addingTimeInterval(-120)) { _ in "t" }.contains("retry in 120 s"))
    }

    func testAProfileWarningFromASavedFileReachesTheStatusNote() async throws {
        // A saved `desktop` runs as observe, and the menu must say so.
        try store.save(edit(secret: "s3cret"))
        try "desktop\n".write(to: store.profileFile, atomically: true, encoding: .utf8)
        try store.writeMarker()
        let sup = supervisor()
        let cfg = try XCTUnwrap(store.load())

        await sup.start(cfg)

        let s = await sup.status
        XCTAssertEqual(s.profile, .observe)
        XCTAssertEqual(s.note, ToolProfile.retiredWarning)
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

    func testNoLogLineStatusTitleOrNoteCarriesTheSecret() async throws {
        let first = "first-distinct-secret-7f3a9"
        let second = "second-distinct-secret-c81d0"
        let sink = LogSink()
        let sup = SwitchboardSupervisor(store: store, computer: "Test Mac", factory: fakes.factory,
                                        log: { sink.append($0) })

        _ = try await sup.save(edit(secret: first))
        await fakes.made[0].emit(.attached)
        try await waitFor(sup) { $0.kind == .connected }
        _ = try await sup.save(edit(secret: second))
        _ = try await sup.save(edit(url: "wss://other.example.test/vm/attach"))
        await sup.reconnect()
        try await sup.forget(confirmed: true)

        let status = await sup.status
        let shown = [status.title { _ in "t" }, status.note ?? ""]
        XCTAssertFalse(sink.all.isEmpty, "the capture must see the supervisor's lines")
        for text in sink.all + shown {
            XCTAssertFalse(text.contains(first), text)
            XCTAssertFalse(text.contains(second), text)
        }
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
        let flags = SwitchboardConfig(url: URL(string: "wss://flag.example.test/vm/attach")!, secret: "x", profile: .observe)
        await sup.applyStartup(SwitchboardStartup.resolve(saved: saved, flags: flags, flagsGiven: true))

        let note = await sup.status.note
        XCTAssertNotNil(note)
    }

    func testASaveAfterAnUnsealedStartupClearsTheStaleNote() async throws {
        try store.save(edit(secret: "s3cret"))
        try "owner\n".write(to: store.profileFile, atomically: true, encoding: .utf8)
        let sup = supervisor()
        await sup.applyStartup(SwitchboardStartup.resolve(saved: nil, flags: nil, flagsGiven: false,
                                                          unsealed: store.inspect().unsealed))
        let warned = await sup.status.note
        XCTAssertTrue(warned?.contains("changed outside the menu bar") == true)

        _ = try await sup.save(edit(profile: .observe))

        let note = await sup.status.note
        XCTAssertNil(note, "the startup note described the files before this save")
    }

    func testForgetAfterAnOverrideClearsTheNote() async throws {
        let sup = supervisor()
        try await configured(sup)
        let saved = try XCTUnwrap(store.load())
        let flags = SwitchboardConfig(url: URL(string: "wss://flag.example.test/vm/attach")!, secret: "x", profile: .observe)
        await sup.applyStartup(SwitchboardStartup.resolve(saved: saved, flags: flags, flagsGiven: true))
        let before = await sup.status.note
        XCTAssertNotNil(before)

        try await sup.forget(confirmed: true)

        let note = await sup.status.note
        XCTAssertNil(note)
    }

    func testAStartupNoteAndTheProfileWarningAreBothShown() async throws {
        try store.save(edit(secret: "s3cret"))
        try "desktop\n".write(to: store.profileFile, atomically: true, encoding: .utf8)
        try store.writeMarker()
        let sup = supervisor()
        let cfg = try XCTUnwrap(store.load())
        await sup.applyStartup(SwitchboardStartup(mode: .saved, config: cfg, warning: "override note"))
        await sup.start(cfg)

        let note = await sup.status.note
        XCTAssertTrue(note?.contains("override note") == true)
        XCTAssertTrue(note?.contains(ToolProfile.retiredWarning) == true)
    }

    func testAProcessDialingFromFlagsCannotEditOrForgetTheSavedFiles() async throws {
        try store.save(edit(secret: "saved-secret"))
        let flagged = SwitchboardSupervisor(store: store, computer: "Test Mac", managesSaved: false, factory: fakes.factory)
        await flagged.start(SwitchboardConfig(url: URL(string: goodURL)!, secret: "flag-secret", profile: .observe))

        let s = await flagged.status
        XCTAssertFalse(s.managesSaved)
        XCTAssertTrue(s.note?.contains("launch flags") == true)
        do {
            _ = try await flagged.save(edit(secret: "rotated"))
            XCTFail("a flagged process must not save the saved files")
        } catch {
            XCTAssertEqual(error as? SwitchboardConfigStore.Failure, .notManaged)
        }
        do {
            try await flagged.forget(confirmed: true)
            XCTFail("a flagged process must not forget the saved files")
        } catch {
            XCTAssertEqual(error as? SwitchboardConfigStore.Failure, .notManaged)
        }
        XCTAssertEqual(store.load()?.secret, "saved-secret")
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
        XCTAssertTrue(title.contains("this Mac Test Mac"), title)
    }

    func testTheTitleNamesTheProfileAndNeverCarriesASecret() {
        let title = make(.attached).title { _ in "t" }
        XCTAssertEqual(title, "Switchboard: connected as observe · this Mac Test Mac")
        XCTAssertFalse(title.lowercased().contains("secret"))
    }

    func testNotConfiguredHasNoComputerOrClose() {
        let title = make(nil, configured: false).title { _ in "t" }
        XCTAssertEqual(title, "Switchboard: not configured")
    }

    func testReconnectAndForgetNeedAConfigAndDisabledHasNone() {
        XCTAssertFalse(make(nil, configured: false).hasConfig)
        XCTAssertTrue(make(.attached).hasConfig)
        let disabled = SwitchboardStatus.make(state: nil, lastClose: nil, configured: false, profile: nil,
                                              computer: "Test Mac", disabledReason: "flag unreadable")
        XCTAssertEqual(disabled.kind, .disabled)
        XCTAssertFalse(disabled.hasConfig)
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
