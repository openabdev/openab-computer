import Foundation

/// What the menu shows for the switchboard. A pure function of the dialer's state,
/// its last close, and whether a config exists, so it is tested without a socket.
public struct SwitchboardStatus: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case notConfigured
        case dialling
        case connected
        case backingOff(seconds: Int)
        case stopped
    }

    public let kind: Kind
    public let profile: ToolProfile?
    public let lastClose: ReverseAttachClient.CloseRecord?
    /// Why the link is backing off or stopped, in words. Nil when connected.
    public let reason: String?
    public let computer: String

    public static func make(state: ReverseAttachClient.State?, lastClose: ReverseAttachClient.CloseRecord?,
                            configured: Bool, profile: ToolProfile?, computer: String) -> SwitchboardStatus {
        func status(_ kind: Kind, _ reason: String? = nil) -> SwitchboardStatus {
            SwitchboardStatus(kind: kind, profile: profile, lastClose: lastClose, reason: reason, computer: computer)
        }
        guard configured else { return status(.notConfigured) }
        guard let state else { return status(.stopped, "not running") }
        switch state {
        case .idle, .dialing:
            return status(.dialling)
        case .attached:
            return status(.connected)
        case .waitingToRedial(let seconds):
            return status(.backingOff(seconds: Int(seconds.rounded())), backoffReason(lastClose))
        case .ended(let terminal):
            return status(.stopped, describe(terminal))
        }
    }

    static func backoffReason(_ close: ReverseAttachClient.CloseRecord?) -> String {
        if let s = close?.handshakeStatus, s == 401 || s == 403 {
            return "credentials refused (HTTP \(s)); retrying slowly"
        }
        if let s = close?.handshakeStatus { return "handshake failed (HTTP \(s))" }
        if let c = close?.code { return "closed with \(c)" }
        return "connection lost"
    }

    static func describe(_ t: ReverseAttachClient.Terminal) -> String {
        switch t {
        case .replaced: return "replaced by another daemon with this secret (4002)"
        case .secretRevoked: return "secret revoked or rotated (4003)"
        case .handshakeRejected(let s): return "handshake refused (HTTP \(s))"
        case .cancelled: return "stopped from the menu"
        case .grantExpired, .sessionEnded, .revoked, .deadline:
            return AttachManager.Grant.label(t)
        }
    }

    /// One line for the menu, e.g. `Switchboard: connected as observe · computer X`.
    /// `timeText` formats the last close time, so tests pin the clock.
    public func title(timeText: (Date) -> String) -> String {
        let head: String
        switch kind {
        case .notConfigured: head = "Switchboard: not configured"
        case .dialling: head = "Switchboard: dialling"
        case .connected: head = "Switchboard: connected as \(profile?.rawValue ?? "?")"
        case .backingOff(let s): head = "Switchboard: backing off, retry in \(s) s"
        case .stopped: head = "Switchboard: stopped"
        }
        var parts = [head]
        if let reason { parts.append(reason) }
        if let close = lastClose {
            let code = close.code.map(String.init) ?? (close.handshakeStatus.map { "HTTP \($0)" } ?? "error")
            parts.append("last close \(code) at \(timeText(close.at))")
        }
        if kind != .notConfigured { parts.append("computer \(computer)") }
        return parts.joined(separator: " · ")
    }
}

/// The part of `ReverseAttachClient` the supervisor drives. A fake stands in for
/// it in tests.
public protocol SwitchboardDialer: Sendable {
    func start() async
    func cancel() async
    func snapshot() async -> (state: ReverseAttachClient.State, lastClose: ReverseAttachClient.CloseRecord?)
}

extension ReverseAttachClient: SwitchboardDialer {
    public func snapshot() -> (state: ReverseAttachClient.State, lastClose: ReverseAttachClient.CloseRecord?) {
        (state, lastClose)
    }
}

/// Owns the switchboard config files and the one live dialer. Every change to the
/// URL or profile replaces the dialer, which drops the current attach. A secret-only
/// change does not: the dialer re-reads the secret file on every dial.
public actor SwitchboardSupervisor {
    public typealias Factory = @Sendable (SwitchboardConfig, @escaping @Sendable (ReverseAttachClient.State) -> Void) -> SwitchboardDialer

    public enum SaveOutcome: Equatable, Sendable {
        /// Nothing was dialling before, so this started the switchboard.
        case started
        /// The URL or profile changed: the current attach was dropped and redialled.
        case reconnected
        /// Only the secret changed: the running dialer uses it on its next dial.
        case nextDial
    }

    public let store: SwitchboardConfigStore
    private let computer: String
    private let factory: Factory
    private let log: @Sendable (String) -> Void
    private var config: SwitchboardConfig?
    private var dialer: SwitchboardDialer?
    /// Bumped on every dialer change, so a late state callback from an old dialer is ignored.
    private var generation = 0
    private var state: ReverseAttachClient.State?
    private var lastClose: ReverseAttachClient.CloseRecord?
    private var onChange: (@Sendable (SwitchboardStatus) -> Void)?

    public init(store: SwitchboardConfigStore, computer: String, factory: @escaping Factory,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.store = store
        self.computer = computer
        self.factory = factory
        self.log = log
    }

    public func setOnChange(_ f: @escaping @Sendable (SwitchboardStatus) -> Void) {
        onChange = f
        f(status)
    }

    public var status: SwitchboardStatus {
        SwitchboardStatus.make(state: state, lastClose: lastClose, configured: config != nil,
                               profile: config?.profile, computer: computer)
    }

    /// The config the dialer is using, for the Configure dialog's defaults. Its secret
    /// is not for display.
    public var current: SwitchboardConfig? { config }

    /// Start dialling with `cfg`, replacing any running dialer.
    public func start(_ cfg: SwitchboardConfig) async {
        await stopDialer()
        config = cfg
        generation += 1
        let gen = generation
        let made = factory(cfg) { [self] _ in
            Task { await self.receive(gen) }
        }
        dialer = made
        state = .idle
        log("switchboard: dialling \(cfg.url.absoluteString) as \(cfg.profile.rawValue)")
        notify()
        await made.start()
    }

    /// Save the menu's edit and apply it. The store validates first, so a rejected
    /// edit changes nothing, including the running dialer.
    @discardableResult
    public func save(_ edit: SwitchboardConfigStore.Edit) async throws -> SaveOutcome {
        let before = config
        try store.save(edit)
        guard let after = store.load() else {
            throw SwitchboardConfigStore.Failure.io("saved files do not form a complete config")
        }
        guard let before, dialer != nil else {
            await start(after)
            return .started
        }
        if before.url == after.url && before.profile == after.profile {
            config = after
            log("switchboard: secret saved; the next dial uses it")
            notify()
            return .nextDial
        }
        await start(after)
        log("switchboard: settings saved; reconnected")
        return .reconnected
    }

    /// Dial again with the saved config. Drops the current attach. A fresh dialer
    /// is needed because a terminal client stays terminal.
    public func reconnect() async {
        guard let cfg = config else { return }
        log("switchboard: reconnect requested")
        await start(cfg)
    }

    /// Stop dialling and delete the switchboard files. The LaunchAgent plist keeps its
    /// flags until the installer is re-run, so the caller must say so.
    public func forget() async throws {
        await stopDialer()
        try store.forget()
        config = nil
        state = nil
        lastClose = nil
        log("switchboard: forgotten; the installer must be re-run to clear the launch flags")
        notify()
    }

    private func stopDialer() async {
        generation += 1
        let old = dialer
        dialer = nil
        state = nil
        if let old { await old.cancel() }
    }

    /// Reads the dialer's current state, not the one the callback named: callbacks can
    /// arrive out of order, and the snapshot is always the latest.
    private func receive(_ gen: Int) async {
        guard gen == generation, let d = dialer else { return }
        let snap = await d.snapshot()
        state = snap.state
        lastClose = snap.lastClose ?? lastClose
        notify()
    }

    private func notify() {
        onChange?(status)
    }
}
