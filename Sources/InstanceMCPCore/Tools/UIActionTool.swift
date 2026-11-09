import Foundation

/// Act on a `ui_snapshot` node by `{snapshot_id, ref}` through the Accessibility API
/// (#67 phase 2): press, set a value, focus, open a context menu, confirm, cancel,
/// step. The pointer never moves and the app is not activated unless asked. Owner
/// only, classified `shell`: it can type into a terminal or press a button that runs
/// something, like `mouse` and `key`.
public struct UIActionTool: Tool {
    public let name = "ui_action"
    public let description = """
        Act on a node from `ui_snapshot` by `{snapshot_id, ref}` through the macOS Accessibility API, \
        without moving the pointer. Actions: press, set_value (with `value`; replaces the whole value), \
        focus, show_menu, confirm, cancel, increment, decrement. The app is NOT activated or raised \
        unless `activate: true`; set it for show_menu, for pressing a menu-bar item of an app in the \
        background, and for focus before typing with `key`. A ref from a snapshot that is gone (the last \
        4 are kept for 5 minutes) or an element that changed is refused as stale: take a new \
        ui_snapshot. Take a new ui_snapshot after acting to confirm the result. Secure fields can be \
        set; this daemon never logs or returns their value. Through an OpenAB Switchboard, set_value on a \
        secure field is refused unless the operator opted in, because the switchboard audits call \
        arguments. Drags, gestures and custom-drawn content stay on `screenshot` + `mouse`. Needs the \
        Accessibility permission.
        """
    public let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "snapshot_id": ["type": "string", "description": "The snapshot_id of the ui_snapshot the ref came from."],
            "ref": ["type": "string", "pattern": .string(UIActionTool.refPattern), "description": "A node ref from that snapshot (e1, e2, …)."],
            "action": ["type": "string", "enum": .array(UIActionKind.allCases.map { .string($0.rawValue) })],
            "value": ["anyOf": [["type": "string", "maxLength": .number(Double(UIActionTool.maxValueLength))],
                                ["type": "number"], ["type": "boolean"]],
                      "description": "The new value; set_value only. Never logged or echoed."],
            "activate": ["type": "boolean", "default": false,
                         "description": "Bring the app to the front first (and raise the ref's window). Default false: no focus stealing."],
            "timeout_ms": ["type": "integer", "description": "Total time budget for the call; the action itself gets what is left after the checks.",
                           "default": .number(Double(UIActionTool.defaultTimeoutMs)),
                           "minimum": .number(Double(UIActionTool.minTimeoutMs)),
                           "maximum": .number(Double(UIActionTool.maxTimeoutMs))],
        ],
        "required": ["snapshot_id", "ref", "action"],
    ]

    public static let defaultTimeoutMs = 2000, minTimeoutMs = 100, maxTimeoutMs = 10_000
    public static let maxValueLength = 65_536
    public static let maxSnapshotIDLength = 64
    /// One pattern for the schema and the parser.
    public static let refPattern = "^e[1-9][0-9]{0,8}$"

    /// Error texts, pinned by tests. None of them ever contains the input `value`.
    public enum Errors {
        public static let notTrusted = "Accessibility not granted: ui_action cannot act on other apps' windows. Grant Accessibility to OpenAB Computer (oab-instance-mcp, bundle id dev.openab.instance-mcp) in System Settings → Privacy & Security → Accessibility, then restart the agent."
        public static let selfApp = "ui_action cannot act on OpenAB Computer's own windows"
        public static let busy = "another ui_action is still running and the timeout_ms budget ran out waiting for it; nothing was done. Retry"
        public static func staleSnapshot(_ id: String) -> String {
            "stale ref: snapshot \(id) is gone (ui_action keeps the last \(UISnapshotCache.defaultCapacity) snapshots for \(Int(UISnapshotCache.defaultTTL / 60)) minutes); take a new ui_snapshot"
        }
        public static func stale(_ ref: String, _ why: String) -> String {
            "stale ref: \(ref) \(why); take a new ui_snapshot and use its refs"
        }
        public static func unknownRef(_ ref: String, snapshot: String, count: Int) -> String {
            "unknown ref: \(ref) is not in snapshot \(snapshot) (" + (count == 0 ? "it has no refs" : "refs e1–e\(count)") + "); take a new ui_snapshot"
        }
        public static func unverifiable(_ ref: String) -> String {
            "ref \(ref) cannot be acted on: its role could not be read when the snapshot was taken, so it cannot be verified; take a new ui_snapshot, or use screenshot + mouse"
        }
        public static func appBusy(_ app: String) -> String {
            "\(app) did not answer the Accessibility request in time (it may be busy or hung); nothing was done. Retry, or raise timeout_ms"
        }
        public static func activationFailed(_ app: String) -> String {
            "could not bring \(app) to the front; nothing was done"
        }
        public static func unsupported(action: String, ref: String, role: String, supported: [String]) -> String {
            "\(ref) (\(role)) does not support \(action). " +
                (supported.isEmpty ? "No ui_action action is supported on it; use screenshot + mouse"
                                   : "Supported on it: \(supported.joined(separator: ", "))")
        }
        public static func unconfirmed(action: String, ref: String, app: String) -> String {
            "ui_action \(action) [\(ref)]: \(app) did not confirm in time. The action may have happened (a press that opens a dialog or menu often answers late); take a new ui_snapshot to check, and do not repeat it blindly"
        }
        /// `set_value` on a secure field through a switchboard that has not opted in.
        /// Points at a direct connection or at turning argument auditing off, never at
        /// `key` typing: its `text` is audited the same way.
        public static let secureOverSwitchboard = "set_value on a secure field is refused through the OpenAB Switchboard: the switchboard writes tool-call arguments to its audit log (redaction is pending in openabdev/openab-sb#16), so the value would be stored there. Nothing was done. Use a direct connection to this computer's /mcp, or have the operator set audit_args = false on the switchboard and start this agent with --switchboard-allow-secure-set-value"
        public static func failed(action: String, ref: String, code: Int32) -> String {
            "ui_action \(action) [\(ref)] failed (AX error \(code)); take a new ui_snapshot"
        }
    }

    /// Where the tool reads the world from. Live by default; a fake in tests.
    struct Environment: Sendable {
        var isTrusted: @Sendable () -> Bool
        var selfPid: Int32
        var cache: UISnapshotCache
        var now: @Sendable () -> TimeInterval
        /// Only called for `activate: true`.
        var activateApp: @Sendable (Int32, UIDeadline) -> Bool
        /// One action at a time: they change UI state, and a messaging timeout is set
        /// on the shared cached element.
        var gate: UIAXGate
        /// false on a switchboard socket unless the operator opted in: `set_value` on a
        /// secure field is then refused before anything is done.
        var allowSecureSetValue = true

        static let live = Environment(
            isTrusted: { AXLive.isTrusted() },
            selfPid: ProcessInfo.processInfo.processIdentifier,
            cache: .shared,
            now: { UIClock.now() },
            activateApp: { AXLive.activate(pid: $0, deadline: $1) },
            gate: UIAXGate()
        )
    }

    let environment: Environment

    public init() { environment = .live }
    init(environment: Environment) { self.environment = environment }

    /// This tool with secure `set_value` allowed or refused; everything else unchanged.
    public func allowingSecureSetValue(_ allowed: Bool) -> UIActionTool {
        var env = environment
        env.allowSecureSetValue = allowed
        return UIActionTool(environment: env)
    }

    struct Request {
        var snapshotID = ""
        var ref = ""
        var action = UIActionKind.press
        var value: UIAttrValue?
        var activate = false
        var timeoutMs = UIActionTool.defaultTimeoutMs
    }

    /// Argument errors are invalid params. None of them quotes `value`.
    static func parse(_ a: JSONValue) throws -> Request {
        var r = Request()
        guard let id = a["snapshot_id"]?.stringValue, !id.isEmpty else {
            throw JSONRPCError.invalidParams("snapshot_id is required")
        }
        guard id.count <= maxSnapshotIDLength else {
            throw JSONRPCError.invalidParams("snapshot_id must be at most \(maxSnapshotIDLength) characters")
        }
        r.snapshotID = id
        guard let ref = a["ref"]?.stringValue, ref.range(of: refPattern, options: .regularExpression) != nil else {
            throw JSONRPCError.invalidParams("ref must look like e1, e2, …")
        }
        r.ref = ref
        guard let name = a["action"]?.stringValue, let kind = UIActionKind(rawValue: name) else {
            throw JSONRPCError.invalidParams("action must be one of \(UIActionKind.list)")
        }
        r.action = kind
        if let v = a["value"], !v.isNull {
            guard kind == .setValue else { throw JSONRPCError.invalidParams("value is only accepted with set_value") }
            switch v {
            case .string(let s):
                guard s.count <= maxValueLength else {
                    throw JSONRPCError.invalidParams("value is longer than \(maxValueLength) characters")
                }
                r.value = .string(s)
            case .number(let d) where d.isFinite: r.value = .number(d)
            case .bool(let b): r.value = .bool(b)
            default: throw JSONRPCError.invalidParams("value must be a string, number or boolean")
            }
        } else if kind == .setValue {
            throw JSONRPCError.invalidParams("value is required for set_value")
        }
        if let v = a["activate"], !v.isNull {
            guard let b = v.boolValue else { throw JSONRPCError.invalidParams("activate must be a boolean") }
            r.activate = b
        }
        if let v = a["timeout_ms"], !v.isNull {
            guard let t = v.intValue else { throw JSONRPCError.invalidParams("timeout_ms must be an integer") }
            r.timeoutMs = min(max(t, minTimeoutMs), maxTimeoutMs)
        }
        return r
    }

    public func call(arguments: JSONValue) async throws -> ToolResult {
        let req = try Self.parse(arguments)
        let env = environment
        guard env.isTrusted() else { throw ToolError(Errors.notTrusted) }
        // AX calls are synchronous IPC into another app: keep them off the cooperative pool.
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try Self.run(req, env: env) })
            }
        }
    }

    static func run(_ req: Request, env: Environment) throws -> ToolResult {
        let deadline = UIDeadline(timeoutMs: req.timeoutMs, now: env.now)
        // Waiting for another action counts against this call's budget.
        guard let result = env.gate.run(deadline, { _ in
            Result { try UIActionEngine(request: req, environment: env, deadline: deadline).run() }
        }) else { throw ToolError(Errors.busy) }
        return try result.get()
    }
}
