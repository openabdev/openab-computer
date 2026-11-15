import Foundation

/// Why an external Playwright may be used. There is no way to build an external backend
/// without one; nothing discovers port 8794 by itself (R7.8).
public enum BrowserTrust: Sendable, Equatable {
    /// The operator passed `--upstream browser=URL`.
    case operatorFlag
    /// Reserved for the Phase 2 "Use it" prompt.
    case userConsent
}

/// Tier P. Managed mode runs the installed `@playwright/mcp` as a stdio child of the app; with
/// nothing installed it reports `needsSetup("playwright_not_installed")`. External mode serves an
/// operator-supplied loopback listener and needs a `trust`.
public actor PlaywrightBackend: BrowserBackend {
    public nonisolated let id: BrowserBackendID = .playwright
    public static let healthTTL: TimeInterval = 30
    public static let toolsTTL: TimeInterval = 30
    public static let ownerTTL: TimeInterval = 2

    private struct External {
        let transport: any PlaywrightTransport
        let endpoint: BrowserUpstreamURL.Endpoint
        let probe: any PortOwnerProbe
        let trust: BrowserTrust
    }
    private struct Managed {
        let locator: ManagedPlaywrightLocator
        let makeTransport: @Sendable (ManagedLaunchSpec, @escaping @Sendable (String) -> Void) -> any PlaywrightTransport
    }
    private let external: External?
    private let managed: Managed?
    private let euid: UInt32
    private let clock: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private var health: (at: Date, status: BrowserBackendStatus)?
    private var toolCache: (at: Date, list: [JSONValue])?
    private var ownerOK: Date?
    private var managedTransport: (spec: ManagedLaunchSpec, transport: any PlaywrightTransport)?
    public private(set) var lastOwner: PortOwner?

    /// Managed mode: the child under `locator`'s root, started on demand.
    public init(managed locator: ManagedPlaywrightLocator,
                makeTransport: @escaping @Sendable (ManagedLaunchSpec, @escaping @Sendable (String) -> Void) -> any PlaywrightTransport
                    = { spec, log in ManagedPlaywrightTransport(spec: spec, log: log) },
                clock: @escaping @Sendable () -> Date = { Date() }, log: @escaping @Sendable (String) -> Void = { _ in }) {
        external = nil; managed = Managed(locator: locator, makeTransport: makeTransport)
        euid = geteuid(); self.clock = clock; self.log = log
    }

    /// External mode; `trust` is required.
    public init(external transport: any PlaywrightTransport, endpoint: BrowserUpstreamURL.Endpoint, probe: any PortOwnerProbe,
                trust: BrowserTrust, euid: UInt32 = geteuid(), clock: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        external = External(transport: transport, endpoint: endpoint, probe: probe, trust: trust)
        managed = nil
        self.euid = euid; self.clock = clock; self.log = log
    }

    public var mode: String? { external == nil ? "managed" : "external" }

    /// Process name and uid of the external listener, names only (R7.5.5).
    public var ownerSummary: String? { lastOwner.map { "\($0.name) (uid \($0.uid))" } }

    /// Stops the managed child, if one was started. Call on app quit.
    public func shutdown() async {
        health = nil; toolCache = nil   // a restarted child is judged afresh, never by the old one's cached status
        await managedTransport?.transport.shutdown(); managedTransport = nil
    }

    // MARK: external

    /// The owner check runs on every use, but a success is reused for `ownerTTL` so one tool call
    /// does not walk every process several times. A failure is never cached.
    private func ownerCheck(_ e: External) -> BrowserBackendStatus? {
        if let ok = ownerOK, clock().timeIntervalSince(ok) < Self.ownerTTL { return nil }
        ownerOK = nil
        guard let o = e.probe.owner(of: e.endpoint) else { return .unavailable("listener_owner_unknown") }
        lastOwner = o
        guard o.uid == euid else { return .unavailable("listener_owner_mismatch") }
        ownerOK = clock()
        return nil
    }

    // MARK: managed

    private func managedTransportFor() async -> Result<any PlaywrightTransport, PlaywrightTransportError> {
        guard let m = managed else { return .failure(.init(errorClass: "playwright_not_installed")) }
        switch m.locator.locate() {
        case .failure(let e):
            health = nil; toolCache = nil
            await shutdown()
            return .failure(e)
        case .success(let spec):
            if let t = managedTransport, t.spec == spec { return .success(t.transport) }
            // A changed install: the old child must be gone before the new transport exists, so
            // two children never share one profile.
            if let old = managedTransport {
                health = nil; toolCache = nil
                await old.transport.shutdown()
                if let cur = managedTransport, cur.spec == spec { return .success(cur.transport) }   // a concurrent call got there first
                managedTransport = nil
            }
            let t = m.makeTransport(spec, log)
            managedTransport = (spec, t)
            return .success(t)
        }
    }

    // MARK: BrowserBackend

    public func status() async -> BrowserBackendStatus {
        let transport: any PlaywrightTransport
        if let e = external {
            if let bad = ownerCheck(e) { health = nil; return bad }
            transport = e.transport
        } else {
            switch await managedTransportFor() {
            case .failure(let e): return .needsSetup(e.errorClass)
            case .success(let t): transport = t
            }
        }
        if let h = health, clock().timeIntervalSince(h.at) < Self.healthTTL { return h.status }
        let s: BrowserBackendStatus
        do { try await transport.healthCheck(); s = .ready }
        catch { s = .unavailable((error as? PlaywrightTransportError)?.errorClass ?? "upstream_unreachable") }
        // A restart gate is short; do not hold it for the whole TTL.
        if external != nil || s.isReady { health = (clock(), s) } else { health = nil }
        return s
    }

    public func peekStatus() async -> BrowserBackendStatus? {
        if external != nil { return health?.status }
        switch await managedTransportFor() {
        case .failure(let e): return .needsSetup(e.errorClass)
        case .success(let t):
            if await t.isLatched { return .unavailable("playwright_unavailable") }
            return health?.status ?? .ready
        }
    }

    public func tools() async -> [JSONValue] {
        let transport: any PlaywrightTransport
        if let e = external {
            guard ownerCheck(e) == nil else { return [] }   // every use, even with a cached list
            transport = e.transport
        } else {
            guard case .success(let t) = await managedTransportFor() else { return [] }
            transport = t
        }
        if let c = toolCache, clock().timeIntervalSince(c.at) < Self.toolsTTL { return c.list }
        if let list = try? await transport.listTools() {
            toolCache = (clock(), list)
            return list
        }
        return toolCache?.list ?? []   // a transient failure keeps the last known list
    }

    public func call(_ name: String, arguments: JSONValue) async throws -> JSONValue {
        let transport: any PlaywrightTransport
        if let e = external {
            if let bad = ownerCheck(e) {
                health = nil
                if case .unavailable(let c) = bad { throw BrowserBackendError(c, setupLost: true) }
                throw BrowserBackendError("listener_owner_unknown", setupLost: true)
            }
            transport = e.transport
        } else {
            switch await managedTransportFor() {
            case .failure(let e): throw BrowserBackendError(e.errorClass, setupLost: true)
            case .success(let t): transport = t
            }
        }
        do { return try await transport.callTool(name, arguments: arguments) }
        catch let err as PlaywrightTransportError {
            if err.errorClass == "playwright_unavailable" { health = nil; throw BrowserBackendError(err.errorClass, setupLost: true) }
            throw BrowserBackendError(err.errorClass)
        } catch { throw BrowserBackendError("upstream_unreachable") }
    }
}
