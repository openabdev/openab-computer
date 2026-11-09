import Foundation

/// The actions `ui_action` offers, and the AX call behind each.
enum UIActionKind: String, CaseIterable, Sendable {
    case press
    case setValue = "set_value"
    case focus
    case showMenu = "show_menu"
    case confirm
    case cancel
    case increment
    case decrement

    /// The AX action performed, for the actions that are one. `set_value` and `focus`
    /// set an attribute instead (`AXValue`, `AXFocused`).
    var axAction: String? {
        switch self {
        case .press: return AXAction.press
        case .showMenu: return AXAction.showMenu
        case .confirm: return AXAction.confirm
        case .cancel: return AXAction.cancel
        case .increment: return AXAction.increment
        case .decrement: return AXAction.decrement
        case .setValue, .focus: return nil
        }
    }

    static var list: String { allCases.map(\.rawValue).joined(separator: ", ") }
}

/// Acts on one recorded ref. Pure over `UIElement`, so every check runs against the
/// fake provider in `swift test`.
///
/// Order: look the ref up, re-verify it (never guess a replacement), check that the
/// element supports the action, activate the app only if asked, perform, then read
/// back a little state if budget remains. Nothing is done unless every check before
/// the action passed. The input `value` is never put in an error, a log line or the
/// response.
struct UIActionEngine {
    let request: UIActionTool.Request
    let environment: UIActionTool.Environment
    let deadline: UIDeadline

    private var E: UIActionTool.Errors.Type { UIActionTool.Errors.self }

    func run() throws -> ToolResult {
        let req = request, env = environment
        guard let snap = env.cache.lookup(req.snapshotID, at: env.now()) else {
            throw ToolError(E.staleSnapshot(req.snapshotID))
        }
        guard let rec = snap.records[req.ref] else {
            throw ToolError(E.unknownRef(req.ref, snapshot: snap.id, count: snap.records.count))
        }
        let app = snap.app
        let appName = app.displayName
        if app.pid == env.selfPid { throw ToolError(E.selfApp) }
        guard let role = rec.role else { throw ToolError(E.unverifiable(req.ref)) }
        let e = rec.element

        /// One armed read. The budget running out, or the app not answering, is "busy,
        /// nothing was done"; a missing grant fails the call.
        func read<T>(_ target: any UIElement, _ body: () -> Result<T, UIAXError>) throws -> Result<T, UIAXError> {
            guard deadline.arm(target) else { throw ToolError(E.appBusy(appName)) }
            let r = body()
            switch r {
            case .failure(.apiDisabled): throw ToolError(E.notTrusted)
            case .failure(.timeout): throw ToolError(E.appBusy(appName))
            default: return r
            }
        }
        func stale(_ why: String) -> ToolError { ToolError(E.stale(req.ref, why)) }

        // 1. Still the element the caller saw: same process, role and subrole, same window.
        guard let pid = e.pid, pid == app.pid else { throw stale("no longer belongs to \(appName)") }
        let now: [String: UIAttrValue]
        switch try read(e, { e.attributes([AXAttr.role, AXAttr.subrole]) }) {
        case .success(let a): now = a
        case .failure(.invalidElement): throw stale("no longer exists")
        case .failure: throw stale("could not be re-read")
        }
        let nowRole = Self.str(now[AXAttr.role]), nowSubrole = Self.str(now[AXAttr.subrole])
        guard nowRole == role, nowSubrole == rec.subrole else {
            func kind(_ r: String?, _ s: String?) -> String { (r ?? "unreadable") + (s.map { "/\($0)" } ?? "") }
            throw stale("is now \(kind(nowRole, nowSubrole)), not the \(kind(role, rec.subrole)) it was")
        }
        if e.identity != rec.root.identity {
            switch try read(e, { e.element(AXAttr.window) }) {
            case .success(let w?):
                // Its window, or a sheet inside it, must be one it was walked under.
                guard rec.path.contains(w.identity) else { throw stale("has left its window") }
            case .success(nil):
                // Only menu items have no AXWindow: an element walked under a window that
                // no longer names one has left it.
                guard rec.rootRole == "AXMenuBar" else { throw stale("has left its window") }
                // The menu bar it came from must still be there.
                if case .failure(.invalidElement) = try read(rec.root, { rec.root.attributes([AXAttr.role]) }) {
                    throw stale("its menu bar is gone")
                }
            case .failure(.invalidElement): throw stale("no longer exists")
            case .failure: throw stale("could not be re-read")
            }
        }
        let secure = rec.masked || UINode.isSecure(role: nowRole, subrole: nowSubrole)
        if secure, req.action == .setValue, !env.allowSecureSetValue {
            throw ToolError(E.secureOverSwitchboard)
        }

        // 2. Supported here, before anything is done.
        func names() throws -> [String] {
            switch try read(e, { e.actionNames() }) {
            case .success(let n): return n
            case .failure(.invalidElement): throw stale("no longer exists")
            case .failure: return []
            }
        }
        func settable(_ attr: String) throws -> Bool {
            switch try read(e, { e.isSettable(attr) }) {
            case .success(let b): return b
            case .failure(.invalidElement): throw stale("no longer exists")
            case .failure: return false
            }
        }
        func supports(_ kind: UIActionKind, names: () throws -> [String]) throws -> Bool {
            switch kind {
            case .setValue: return try settable(AXAttr.value)
            case .focus: return try settable(AXAttr.focused)
            default: return try names().contains(kind.axAction!)
            }
        }
        func supportedList() throws -> [String] {
            var cached: [String]?
            let lazyNames: () throws -> [String] = {
                if let cached { return cached }
                let n = try names()
                cached = n
                return n
            }
            return try UIActionKind.allCases.filter { try supports($0, names: lazyNames) }.map(\.rawValue)
        }
        /// Building the list can itself find the element stale or the budget spent;
        /// those errors win over a misleading "nothing is supported".
        func unsupported() throws -> ToolError {
            ToolError(E.unsupported(action: req.action.rawValue, ref: req.ref, role: role,
                                    supported: try supportedList()))
        }
        guard try supports(req.action, names: names) else { throw try unsupported() }

        // 3. Activate only when asked; fail closed if the app did not come to the front.
        var activated = false
        if req.activate {
            guard !deadline.expired else { throw ToolError(E.appBusy(appName)) }
            guard env.activateApp(app.pid, deadline) else { throw ToolError(E.activationFailed(appName)) }
            activated = true
            // Bring the ref's window to the front within the app, when it is a window.
            if rec.rootRole == "AXWindow", case .success(let n)? = try? read(rec.root, { rec.root.actionNames() }),
               n.contains(AXAction.raise), deadline.arm(rec.root) {
                _ = rec.root.perform(AXAction.raise)
            }
        }

        // 4. The action. It gets the whole remaining budget: apps answer an AXPress only
        // after handling it.
        guard deadline.armAll(e) else { throw ToolError(E.appBusy(appName)) }
        let done: Result<Void, UIAXError>
        switch req.action {
        case .setValue:
            guard let v = req.value else { throw ToolError(E.unsupported(action: req.action.rawValue, ref: req.ref, role: role, supported: [])) }
            done = e.setValue(AXAttr.value, v)
        case .focus:
            done = e.setValue(AXAttr.focused, .bool(true))
        default:
            done = e.perform(req.action.axAction!)
        }
        switch done {
        case .success: break
        case .failure(.timeout): throw ToolError(E.unconfirmed(action: req.action.rawValue, ref: req.ref, app: appName))
        case .failure(.invalidElement): throw stale("vanished before the action ran")
        case .failure(.apiDisabled): throw ToolError(E.notTrusted)
        case .failure(let err) where err.isUnsupported: throw try unsupported()
        case .failure(.other(let code)): throw ToolError(E.failed(action: req.action.rawValue, ref: req.ref, code: code))
        }

        // 5. Post-action state, only while budget remains. Never a secure value.
        var post: [String: JSONValue]?
        var gone = false
        if deadline.arm(e) {
            switch e.attributes([AXAttr.focused, AXAttr.enabled, AXAttr.selected, AXAttr.numberOfCharacters]) {
            case .success(let a):
                var p: [String: JSONValue] = ["focused": .bool(Self.flag(a[AXAttr.focused]) ?? false)]
                if Self.flag(a[AXAttr.enabled]) == false { p["enabled"] = false }
                if Self.flag(a[AXAttr.selected]) == true { p["selected"] = true }
                if secure {
                    p["masked"] = true
                } else {
                    switch readValue(e, count: a[AXAttr.numberOfCharacters]) {
                    case .some(.value(let v, let truncated)):
                        p["value"] = v
                        if truncated { p["value_truncated"] = true }
                    case .some(.gone): gone = true
                    case .none: break
                    }
                }
                if !gone { post = p }
            case .failure(.invalidElement): gone = true
            case .failure: break
            }
        }

        // 6. The result.
        var target: [String: JSONValue] = ["role": .string(role)]
        if let s = rec.subrole { target["subrole"] = .string(s) }
        if let t = rec.title { target["title"] = .string(t) }
        if secure { target["masked"] = true }
        var o: [String: JSONValue] = [
            "action": .string(req.action.rawValue),
            "snapshot_id": .string(snap.id),
            "ref": .string(req.ref),
            "app": app.json,
            "target": .object(target),
            "success": true,
            "activated": .bool(activated),
            "elapsed_ms": .number(Double(deadline.elapsedMs)),
        ]
        if let post { o["post_state"] = .object(post) }
        if gone { o["element_gone"] = true }

        var label = "[\(req.ref)] \(role)"
        if let s = rec.subrole { label += "/\(s)" }
        if let t = rec.title { label += " \"\(UISnapshot.clip(t, UISnapshotLimits.textValueCap))\"" }
        let what = req.action == .setValue ? "value set (not shown)" : "done"
        var text = "ui_action \(req.action.rawValue) \(label) in \(appName) (pid \(app.pid)): \(what)."
        if gone { text += " The element is gone now (a menu or dialog closed)." }
        text += " Take a new ui_snapshot to confirm."
        return ToolResult(content: [.text(text)], structured: .object(o))
    }

    private enum PostValue { case value(JSONValue, truncated: Bool), gone }

    /// The element's value after the action, as `ui_snapshot` would show it: a long
    /// text is read as a prefix. nil when unavailable or out of budget.
    private func readValue(_ e: any UIElement, count: UIAttrValue?) -> PostValue? {
        let cap = UISnapshotLimits.stringCap
        if case .number(let n)? = count, n > Double(cap) {
            guard deadline.arm(e) else { return nil }
            switch e.stringPrefix(utf16Length: cap) {
            case .success(let s?):
                var text = s
                if text.hasSuffix("\u{FFFD}") { text.removeLast() }
                return .value(.string(text + "…"), truncated: true)
            case .failure(.invalidElement): return .gone
            case .success(nil), .failure: break
            }
        }
        guard deadline.arm(e) else { return nil }
        switch e.attributes([AXAttr.value]) {
        case .success(let a):
            switch a[AXAttr.value] {
            case .string(let s)?:
                let c = UITreeWalker.cap(s)
                return .value(.string(c.text), truncated: c.truncated)
            case .number(let d)? where d.isFinite: return .value(.number(d), truncated: false)
            case .bool(let b)?: return .value(.bool(b), truncated: false)
            default: return nil
            }
        case .failure(.invalidElement): return .gone
        case .failure: return nil
        }
    }

    static func str(_ v: UIAttrValue?) -> String? {
        guard case .string(let s)? = v, !s.isEmpty else { return nil }
        return UITreeWalker.cap(s).text
    }

    static func flag(_ v: UIAttrValue?) -> Bool? {
        switch v {
        case .bool(let b)?: return b
        case .number(let n)?: return n != 0
        default: return nil
        }
    }
}
