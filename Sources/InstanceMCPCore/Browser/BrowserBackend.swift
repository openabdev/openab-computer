import Foundation

public enum BrowserBackendID: String, Sendable, Equatable {
    case appleEvents
    case playwright
}

/// `needsSetup` and `unavailable` carry a fixed class string, never upstream or page text.
public enum BrowserBackendStatus: Equatable, Sendable {
    case ready
    case needsSetup(String)
    case unavailable(String)

    public var isReady: Bool { if case .ready = self { return true }; return false }
}

/// A backend failure with a fixed class. `setupLost` means the backend stopped being usable;
/// anything else fails that call only (R2.5).
public struct BrowserBackendError: Error, Equatable, Sendable {
    public let errorClass: String
    public let setupLost: Bool
    public init(_ errorClass: String, setupLost: Bool = false) {
        self.errorClass = errorClass; self.setupLost = setupLost
    }
}

/// What serves the `browser_*` tools. Implemented by the Playwright tier now and by the Apple
/// Events tier in Phase 2; the CDP tier stays reserved and is never selected by `auto` (R2.7).
public protocol BrowserBackend: Sendable {
    var id: BrowserBackendID { get }
    /// Never prompts. A managed backend may start its child here (and the first call after an
    /// install does), so callers must not poll it; the router asks only the backends it needs.
    func status() async -> BrowserBackendStatus
    /// The last known state without starting or probing anything, for menus and `sys_info`.
    /// `nil` means nothing is known.
    func peekStatus() async -> BrowserBackendStatus?
    /// `managed` or `external`, no URLs. `nil` for a backend with no such notion.
    var mode: String? { get async }
    /// Process name and uid of an external listener, names only.
    var ownerSummary: String? { get async }
    /// Descriptors of the tools this backend serves right now.
    func tools() async -> [JSONValue]
    /// A `tools/call` result, relayed as the backend produced it.
    func call(_ name: String, arguments: JSONValue) async throws -> JSONValue
}

extension BrowserBackend {
    public func peekStatus() async -> BrowserBackendStatus? { nil }
    public var mode: String? { get async { nil } }
    public var ownerSummary: String? { get async { nil } }
}

public enum BrowserPreference: String, Sendable, CaseIterable {
    case auto, appleEvents, playwright
}

public protocol BrowserPreferenceStore: Sendable {
    func load() -> BrowserPreference
    func save(_ p: BrowserPreference)
}

/// `UserDefaults` key `browserTools.backend.v1` (R5.10). An unknown stored value resets to
/// `auto` with one log line naming the key.
public struct UserDefaultsBrowserPreferenceStore: BrowserPreferenceStore, @unchecked Sendable {
    public static let key = "browserTools.backend.v1"
    private let defaults: UserDefaults
    private let log: @Sendable (String) -> Void

    public init(defaults: UserDefaults = .standard, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.defaults = defaults; self.log = log
    }

    public func load() -> BrowserPreference {
        guard let raw = defaults.string(forKey: Self.key) else { return .auto }
        if let p = BrowserPreference(rawValue: raw) { return p }
        log("\(Self.key): unknown value, reset to auto")
        defaults.removeObject(forKey: Self.key)
        return .auto
    }

    public func save(_ p: BrowserPreference) { defaults.set(p.rawValue, forKey: Self.key) }
}
