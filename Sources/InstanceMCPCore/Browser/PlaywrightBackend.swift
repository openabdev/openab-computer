import Foundation

/// Why an external Playwright may be used. There is no way to build an external backend
/// without one; nothing discovers port 8794 by itself (R7.8).
public enum BrowserTrust: Sendable, Equatable {
    /// The operator passed `--upstream browser=URL`.
    case operatorFlag
    /// Reserved for the Phase 2 "Use it" prompt.
    case userConsent
}

/// Tier P. Phase 1 serves an external Playwright MCP; the managed stdio child is the next step
/// and reports `needsSetup("playwright_not_installed")` until then.
public actor PlaywrightBackend: BrowserBackend {
    public nonisolated let id: BrowserBackendID = .playwright
    public static let healthTTL: TimeInterval = 30

    private struct External {
        let transport: any PlaywrightTransport
        let port: UInt16
        let probe: any PortOwnerProbe
        let trust: BrowserTrust
    }
    private let external: External?
    private let euid: UInt32
    private let clock: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private var health: (at: Date, status: BrowserBackendStatus)?
    public private(set) var lastOwner: PortOwner?

    /// Managed mode. Nothing is installed yet, so it is never ready.
    public init(log: @escaping @Sendable (String) -> Void = { _ in }) {
        external = nil; euid = geteuid(); clock = { Date() }; self.log = log
    }

    /// External mode; `trust` is required.
    public init(external transport: any PlaywrightTransport, port: UInt16, probe: any PortOwnerProbe,
                trust: BrowserTrust, euid: UInt32 = geteuid(), clock: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        external = External(transport: transport, port: port, probe: probe, trust: trust)
        self.euid = euid; self.clock = clock; self.log = log
    }

    public var mode: String { external == nil ? "managed" : "external" }

    /// Process name and uid of the external listener, names only (R7.5.5).
    public var ownerSummary: String? { lastOwner.map { "\($0.name) (uid \($0.uid))" } }

    private func ownerCheck(_ e: External) -> BrowserBackendStatus? {
        guard let o = e.probe.owner(ofLoopbackPort: e.port) else { return .unavailable("listener_owner_unknown") }
        lastOwner = o
        return o.uid == euid ? nil : .unavailable("listener_owner_mismatch")
    }

    public func status() async -> BrowserBackendStatus {
        guard let e = external else { return .needsSetup("playwright_not_installed") }
        if let bad = ownerCheck(e) { health = nil; return bad }
        if let h = health, clock().timeIntervalSince(h.at) < Self.healthTTL { return h.status }
        let s: BrowserBackendStatus
        do { try await e.transport.healthCheck(); s = .ready }
        catch { s = .unavailable((error as? ExternalPlaywrightError)?.errorClass ?? "upstream_unreachable") }
        health = (clock(), s)
        return s
    }

    public func tools() async -> [JSONValue] {
        guard let e = external, ownerCheck(e) == nil else { return [] }
        return (try? await e.transport.listTools()) ?? []
    }

    public func call(_ name: String, arguments: JSONValue) async throws -> JSONValue {
        guard let e = external else { throw BrowserBackendError("playwright_not_installed", setupLost: true) }
        if let bad = ownerCheck(e) {
            health = nil
            if case .unavailable(let c) = bad { throw BrowserBackendError(c, setupLost: true) }
            throw BrowserBackendError("listener_owner_unknown", setupLost: true)
        }
        do { return try await e.transport.callTool(name, arguments: arguments) }
        catch let err as ExternalPlaywrightError { throw BrowserBackendError(err.errorClass) }
        catch { throw BrowserBackendError("upstream_unreachable") }
    }
}
