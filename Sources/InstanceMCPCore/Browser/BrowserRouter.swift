import Foundation

/// Per-request connection context: a key that identifies the connection (MCP session id, or a
/// fixed key on the attach paths) and the optional `OAB-Browser-Backend` header override.
public struct BrowserConnection: Sendable, Equatable {
    public var key: String
    public var override: BrowserPreference?
    public init(key: String, override: BrowserPreference? = nil) { self.key = key; self.override = override }
}

/// Serves the `browser_*` tools from one active backend per connection (requirements R2).
/// Phase 1 fills only the Playwright slot; the Apple Events slot is left open.
public actor BrowserRouter {
    public static let guardWindow: TimeInterval = 30 * 60
    static let maxTracked = 1024
    public static let notSetUp = "Browser tools are not set up. Open OpenAB Computer, then Browser tools."

    private let appleEvents: (any BrowserBackend)?
    private let playwright: (any BrowserBackend)?
    private let store: any BrowserPreferenceStore
    private let clock: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private var last: [String: (id: BrowserBackendID, at: Date)] = [:]

    public init(appleEvents: (any BrowserBackend)? = nil, playwright: (any BrowserBackend)? = nil,
                store: any BrowserPreferenceStore, clock: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.appleEvents = appleEvents; self.playwright = playwright
        self.store = store; self.clock = clock; self.log = log
    }

    enum Selection {
        case active(any BrowserBackend)
        /// Auto mode, inside the guard window: the last backend is gone and the other one is
        /// ready but is not used by itself.
        case guarded(other: BrowserBackendID)
        case none
    }

    private func backend(_ id: BrowserBackendID) -> (any BrowserBackend)? {
        id == .appleEvents ? appleEvents : playwright
    }

    /// Statuses are asked lazily, in the order the rules need them, because asking a managed
    /// backend may start its child (R2, R2.1).
    func select(_ conn: BrowserConnection) async -> Selection {
        let pref = conn.override ?? store.load()
        func ready(_ id: BrowserBackendID) async -> Bool { await backend(id)?.status().isReady ?? false }
        switch pref {
        case .appleEvents: return await ready(.appleEvents) ? .active(appleEvents!) : .none
        case .playwright: return await ready(.playwright) ? .active(playwright!) : .none
        case .auto:
            if let l = last[conn.key], clock().timeIntervalSince(l.at) < Self.guardWindow {
                if await ready(l.id), let b = backend(l.id) { return .active(b) }
                let other: BrowserBackendID = l.id == .appleEvents ? .playwright : .appleEvents
                return await ready(other) ? .guarded(other: other) : .none
            }
            if await ready(.playwright) { return .active(playwright!) }
            if await ready(.appleEvents) { return .active(appleEvents!) }
            return .none
        }
    }

    private func prune() {
        let now = clock()
        last = last.filter { now.timeIntervalSince($0.value.at) < Self.guardWindow }
        if last.count > Self.maxTracked {
            for (k, _) in last.sorted(by: { $0.value.at < $1.value.at }).prefix(last.count - Self.maxTracked) { last[k] = nil }
        }
    }

    var trackedConnections: Int { last.count }

    /// The catalog names the active backend serves now. Empty with no ready backend.
    public func tools(_ conn: BrowserConnection) async -> [JSONValue] {
        guard case .active(let b) = await select(conn) else { return [] }
        return await b.tools().filter {
            guard let n = $0["name"]?.stringValue else { return false }
            return BrowserToolCatalog.allNameSet.contains(n)
        }
    }

    public func call(_ name: String, arguments: JSONValue, _ conn: BrowserConnection) async -> JSONValue {
        let backend: any BrowserBackend
        prune()
        switch await select(conn) {
        case .none:
            var text = Self.notSetUp
            if let p = playwright, case .needsSetup("playwright_not_installed")? = await p.peekStatus() {
                text += " Playwright is not installed."
            }
            return Self.errorResult(text, backend: nil)
        case .guarded(let other):
            return Self.errorResult("The browser backend used earlier in this conversation is no longer "
                + "ready. The \(other.rawValue) backend is ready but is not used automatically in the "
                + "middle of a task. Select it in OpenAB Computer, Browser tools, or send the "
                + "OAB-Browser-Backend header.", backend: nil)
        case .active(let b): backend = b
        }
        let served = await backend.tools().compactMap { $0["name"]?.stringValue }
        guard served.contains(name) else {
            return Self.errorResult("\(name) is not available with the \(backend.id.rawValue) backend. "
                + "Install Playwright or select it in OpenAB Computer, Browser tools.", backend: backend.id)
        }
        last[conn.key] = (backend.id, clock())
        do {
            let r = try await backend.call(name, arguments: arguments)
            return Self.tag(r, backend: backend.id)
        } catch let e as BrowserBackendError {
            if e.setupLost { log("browser backend \(backend.id.rawValue): setup lost (\(e.errorClass))") }
            return Self.errorResult("Browser call failed: \(e.errorClass)", backend: backend.id)
        } catch {
            return Self.errorResult("Browser call failed: backend_error", backend: backend.id)
        }
    }

    // MARK: result shaping

    static func errorResult(_ text: String, backend: BrowserBackendID?) -> JSONValue {
        tag(["content": [["type": "text", "text": .string(text)]], "isError": true], backend: backend)
    }

    /// Adds `structuredContent.backend`, merging into an existing object and keeping every
    /// content block.
    static func tag(_ result: JSONValue, backend: BrowserBackendID?) -> JSONValue {
        guard let backend, var o = result.objectValue else { return result }
        var sc = result["structuredContent"]?.objectValue ?? [:]
        sc["backend"] = .string(backend.rawValue)
        o["structuredContent"] = .object(sc)
        return .object(o)
    }
}

// MARK: reporting (R1.6, R5.9)

/// A non-sensitive snapshot of the browser tiers: states and fixed classes, never a URL, tab
/// title or page text.
public struct BrowserReport: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let id: BrowserBackendID
        public let state: String          // ready | needs_setup | unavailable
        public let errorClass: String?
        public let mode: String?          // managed | external
        public let ownerSummary: String?
    }
    public let preference: BrowserPreference
    public let active: BrowserBackendID?
    public let backends: [Entry]

    /// One line for `sys_info` text.
    public var line: String {
        let parts = backends.map { e -> String in
            let name = e.id == .playwright ? "playwright" : "apple events"
            let m = e.mode.map { " (\($0))" } ?? ""
            switch e.state {
            case "ready": return "\(name)\(m) ready"
            case "needs_setup" where e.errorClass == "playwright_not_installed": return "\(name) not installed"
            default: return "\(name)\(m) \(e.state.replacingOccurrences(of: "_", with: " "))\(e.errorClass.map { " (\($0))" } ?? "")"
            }
        }
        return "browser tools: " + (parts.isEmpty ? "none" : parts.joined(separator: ", "))
    }

    public var json: JSONValue {
        [
            "preference": .string(preference.rawValue),
            "active": active.map { .string($0.rawValue) } ?? .null,
            "backends": .array(backends.map { e in
                var o: [String: JSONValue] = ["id": .string(e.id.rawValue), "state": .string(e.state)]
                if let c = e.errorClass { o["class"] = .string(c) }
                if let m = e.mode { o["mode"] = .string(m) }
                if let w = e.ownerSummary { o["owner"] = .string(w) }
                return .object(o)
            }),
        ]
    }
}

extension BrowserRouter {
    /// Built from `peekStatus`, so reading it never starts a child or probes a listener. The
    /// active backend is the one `auto` would pick from what is known.
    public func report(_ conn: BrowserConnection? = nil) async -> BrowserReport {
        let pref = conn?.override ?? store.load()
        var entries: [BrowserReport.Entry] = []
        var firstReady: BrowserBackendID?
        for b in [playwright, appleEvents].compactMap({ $0 }) {
            let st = await b.peekStatus() ?? .unavailable("not_checked")
            let (state, cls): (String, String?)
            switch st {
            case .ready: (state, cls) = ("ready", nil); if firstReady == nil { firstReady = b.id }
            case .needsSetup(let c): (state, cls) = ("needs_setup", c)
            case .unavailable(let c): (state, cls) = ("unavailable", c)
            }
            entries.append(.init(id: b.id, state: state, errorClass: cls, mode: await b.mode, ownerSummary: await b.ownerSummary))
        }
        var active: BrowserBackendID?
        switch pref {
        case .auto: active = firstReady
        case .appleEvents, .playwright:
            let want: BrowserBackendID = pref == .appleEvents ? .appleEvents : .playwright
            active = entries.first { $0.id == want && $0.state == "ready" }?.id
        }
        return BrowserReport(preference: pref, active: active, backends: entries)
    }
}
