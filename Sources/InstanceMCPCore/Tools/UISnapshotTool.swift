import Foundation

/// Read-only accessibility tree of a native app's window (#67 phase 1). Needs the
/// Accessibility grant (the one `mouse`/`key` use) and never prompts for it.
/// Owner-only: it can read field values and text outside the visible area.
public struct UISnapshotTool: Tool {
    public let name = "ui_snapshot"
    public let description = """
        Read the accessibility tree of a native macOS app window (read-only): roles, titles, values, \
        state and frames. Default target: the frontmost app's focused window; pass `app` (bundle id or \
        name) or `pid`, and `window` (title or index) or `all_windows`. Frames are display POINTS relative \
        to `display`, the same space `screenshot` and `mouse` use. Each node has a `ref` valid only within \
        this `snapshot_id`. Secure text fields are always masked. Prefer `browser_snapshot` for web pages; \
        use `screenshot` + `mouse` for custom-drawn content. Needs the Accessibility permission.
        """
    public let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "app": ["type": "string", "description": "Bundle id (com.apple.TextEdit) or app name (TextEdit). Default: frontmost app."],
            "pid": ["type": "integer", "description": "Process id. Use instead of app when several apps match."],
            "window": ["anyOf": [["type": "string"], ["type": "integer", "minimum": 0]],
                       "description": "Window title (exact, else case-insensitive substring) or index into the app's window list. Default: focused window."],
            "all_windows": ["type": "boolean", "description": "Walk every window of the app.", "default": false],
            "max_depth": ["type": "integer", "description": "Levels below the window.",
                          "default": .number(Double(UISnapshotLimits.defaultDepth)),
                          "minimum": .number(Double(UISnapshotLimits.minDepth)),
                          "maximum": .number(Double(UISnapshotLimits.maxDepthCap))],
            "max_nodes": ["type": "integer", "description": "Nodes across all windows.",
                          "default": .number(Double(UISnapshotLimits.defaultNodes)),
                          "minimum": .number(Double(UISnapshotLimits.minNodes)),
                          "maximum": .number(Double(UISnapshotLimits.maxNodesCap))],
            "timeout_ms": ["type": "integer", "description": "Total time budget for the whole call (app lookup, window selection and walk); partial results are flagged timed_out.",
                           "default": .number(Double(UISnapshotLimits.defaultTimeoutMs)),
                           "minimum": .number(Double(UISnapshotLimits.minTimeoutMs)),
                           "maximum": .number(Double(UISnapshotLimits.maxTimeoutMs))],
        ],
    ]

    /// Error texts, pinned by tests.
    public enum Errors {
        public static let notTrusted = "Accessibility not granted: ui_snapshot cannot read other apps' windows. Grant Accessibility to OpenAB Computer (oab-instance-mcp, bundle id dev.openab.instance-mcp) in System Settings → Privacy & Security → Accessibility, then restart the agent."
        public static let noFrontmost = "no frontmost app (the screen may be locked or at the login window); pass app or pid"
        public static let budgetSpent = "the timeout_ms budget ran out before the target app was chosen; raise timeout_ms, or pass app or pid"
        public static let selfApp = "ui_snapshot cannot read OpenAB Computer's own windows"
        public static func noPid(_ pid: Int32) -> String { "no running app with pid \(pid)" }
        public static func appNotFound(_ app: String, running: [String]) -> String {
            "app not found: no running app has bundle id or name '\(app)'. Running apps: " +
                (running.isEmpty ? "none" : running.prefix(20).joined(separator: ", "))
        }
        public static func ambiguous(_ app: String, pids: [Int32]) -> String {
            "app '\(app)' matches \(pids.count) running apps (pids \(pids.map(String.init).joined(separator: ", "))); pass pid instead"
        }
        public static func noWindows(_ app: String) -> String { "\(app) has no open windows" }
        public static func windowNotFound(_ w: String, app: String, titles: [String]) -> String {
            "window '\(w)' not found in \(app); windows: " +
                titles.enumerated().map { "[\($0.offset)] \"\($0.element)\"" }.joined(separator: ", ")
        }
        public static func appBusy(_ app: String) -> String {
            "\(app) did not answer the Accessibility request in time (it may be busy or hung); retry, or raise timeout_ms"
        }
    }

    /// Where the tool reads the world from. Live by default; a fake in tests.
    struct Environment: Sendable {
        var isTrusted: @Sendable () -> Bool
        var selfPid: Int32
        var runningApps: @Sendable () -> [UIRunningApp]
        /// The argument is the messaging timeout for the lookup, from the call's deadline.
        var frontmostPid: @Sendable (Float) -> Int32?
        /// Held around `frontmostPid`: its timeout is process-global.
        var frontmostGate: UIAXGate
        var appElement: @Sendable (Int32) -> any UIElement
        var displays: @Sendable () -> UIDisplayMap
        var now: @Sendable () -> TimeInterval
        var newSnapshotID: @Sendable () -> String

        static let live = Environment(
            isTrusted: { AXLive.isTrusted() },
            selfPid: ProcessInfo.processInfo.processIdentifier,
            runningApps: { AXLive.runningApps() },
            frontmostPid: { AXLive.frontmostPid(timeout: $0) },
            frontmostGate: .systemWide,
            appElement: { AXLive.appElement($0) },
            displays: { AXLive.displays() },
            now: { ProcessInfo.processInfo.systemUptime },
            newSnapshotID: { "snap-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased() }
        )
    }

    let environment: Environment

    public init() { environment = .live }
    init(environment: Environment) { self.environment = environment }

    struct Request {
        var app: String?
        var pid: Int32?
        var window: UITarget.WindowSelector?
        var allWindows = false
        var limits = UISnapshotLimits()
    }

    static func parse(_ a: JSONValue) throws -> Request {
        var r = Request()
        func int(_ key: String) throws -> Int? {
            guard let v = a[key], !v.isNull else { return nil }
            guard let i = v.intValue else { throw JSONRPCError.invalidParams("\(key) must be an integer") }
            return i
        }
        if let v = a["app"], !v.isNull {
            guard let s = v.stringValue, !s.isEmpty else { throw JSONRPCError.invalidParams("app must be a non-empty string") }
            r.app = s
        }
        if let p = try int("pid") {
            guard p > 0, p <= Int(Int32.max) else { throw JSONRPCError.invalidParams("pid must be a positive integer") }
            r.pid = Int32(p)
        }
        if let v = a["window"], !v.isNull {
            if let i = v.intValue, i >= 0 {
                r.window = .index(i)
            } else if let s = v.stringValue, !s.isEmpty {
                r.window = .title(s)
            } else {
                throw JSONRPCError.invalidParams("window must be a non-empty title or a window index ≥ 0")
            }
        }
        if let v = a["all_windows"], !v.isNull {
            guard let b = v.boolValue else { throw JSONRPCError.invalidParams("all_windows must be a boolean") }
            r.allWindows = b
        }
        if r.app != nil, r.pid != nil { throw JSONRPCError.invalidParams("pass app or pid, not both") }
        if r.window != nil, r.allWindows { throw JSONRPCError.invalidParams("pass window or all_windows, not both") }
        r.limits = UISnapshotLimits(maxDepth: try int("max_depth"), maxNodes: try int("max_nodes"),
                                    timeoutMs: try int("timeout_ms"))
        return r
    }

    public func call(arguments: JSONValue) async throws -> ToolResult {
        let req = try Self.parse(arguments)
        let env = environment
        guard env.isTrusted() else { throw ToolError(Errors.notTrusted) }
        // AX calls are synchronous IPC into another app: keep them off the cooperative pool.
        let snapshot: UISnapshot = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try Self.run(req, env: env).snapshot })
            }
        }
        return ToolResult(content: [.text(snapshot.renderText())], structured: snapshot.json)
    }

    static func run(_ req: Request, env: Environment) throws -> UISnapshotResult {
        // One budget for the whole call: frontmost lookup, window selection and walk.
        let deadline = UIDeadline(timeoutMs: req.limits.timeoutMs, now: env.now)
        let needsList = req.pid != nil || req.app != nil
        let running = env.runningApps()
        var front: Int32?
        if !needsList {
            // No AX request starts once the budget is spent, this one included. The gate
            // computes the timeout after any wait, so a queued call cannot use a stale one.
            guard let pid = env.frontmostGate.run(deadline, env.frontmostPid) else { throw ToolError(Errors.budgetSpent) }
            front = pid
        }
        let app = try UITarget.resolveApp(app: req.app, pid: req.pid, frontmostPid: front,
                                          running: running, selfPid: env.selfPid).get()
        let root = env.appElement(app.pid)
        let windows = try UITarget.windows(of: root, appName: app.displayName, selector: req.window,
                                           all: req.allWindows, deadline: deadline)
        let walker = UITreeWalker(limits: req.limits, newSnapshotID: env.newSnapshotID)
        return try walker.walk(app: app, windows: windows, displays: env.displays(), deadline: deadline)
    }
}
