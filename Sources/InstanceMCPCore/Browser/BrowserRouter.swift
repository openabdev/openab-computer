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

    func select(_ conn: BrowserConnection) async -> Selection {
        let pref = conn.override ?? store.load()
        let aReady = await appleEvents?.status().isReady ?? false
        let pReady = await playwright?.status().isReady ?? false
        switch pref {
        case .appleEvents: return aReady ? .active(appleEvents!) : .none
        case .playwright: return pReady ? .active(playwright!) : .none
        case .auto:
            if let l = last[conn.key], clock().timeIntervalSince(l.at) < Self.guardWindow {
                let lastReady = l.id == .appleEvents ? aReady : pReady
                if lastReady, let b = backend(l.id) { return .active(b) }
                let other: BrowserBackendID = l.id == .appleEvents ? .playwright : .appleEvents
                if (other == .appleEvents ? aReady : pReady) { return .guarded(other: other) }
                return .none
            }
            if pReady { return .active(playwright!) }
            if aReady { return .active(appleEvents!) }
            return .none
        }
    }

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
        switch await select(conn) {
        case .none: return Self.errorResult(Self.notSetUp, backend: nil)
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
