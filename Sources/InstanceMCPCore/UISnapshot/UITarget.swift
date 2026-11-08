import Foundation

/// Which app and which window(s) `ui_snapshot` reads. Pure over `UIRunningApp` and
/// `UIElement`, so every branch is unit-tested.
enum UITarget {
    enum WindowSelector: Equatable {
        case index(Int)
        case title(String)
    }

    /// `pid` exact; `app` = bundle id (case-insensitive), else exact app name
    /// (case-insensitive); neither = the frontmost app. Never this process.
    static func resolveApp(app: String?, pid: Int32?, frontmostPid: Int32?,
                           running: [UIRunningApp], selfPid: Int32) -> Result<UIRunningApp, ToolError> {
        let E = UISnapshotTool.Errors.self
        let found: UIRunningApp
        if let pid {
            guard let a = running.first(where: { $0.pid == pid }) else { return .failure(ToolError(E.noPid(pid))) }
            found = a
        } else if let app {
            let key = app.lowercased()
            var matches = running.filter { $0.bundleID?.lowercased() == key }
            if matches.isEmpty { matches = running.filter { $0.name?.lowercased() == key } }
            if matches.count > 1 { return .failure(ToolError(E.ambiguous(app, pids: matches.map(\.pid)))) }
            guard let a = matches.first else {
                let regular = running.filter(\.regular)
                let names = Set((regular.isEmpty ? running : regular).compactMap(\.name)).sorted()
                return .failure(ToolError(E.appNotFound(app, running: names)))
            }
            found = a
        } else {
            guard let front = frontmostPid else { return .failure(ToolError(E.noFrontmost)) }
            found = running.first { $0.pid == front } ?? UIRunningApp(pid: front, bundleID: nil, name: nil)
        }
        if found.pid == selfPid { return .failure(ToolError(E.selfApp)) }
        return .success(found)
    }

    /// The window roots to walk. Default: focused window, else main window, else the
    /// first of `AXWindows`. Every AX call runs under `deadline`; if the budget is spent
    /// before a window is chosen, the app counts as busy.
    static func windows(of app: any UIElement, appName: String, selector: WindowSelector?,
                        all: Bool, deadline: UIDeadline) throws -> [any UIElement] {
        let E = UISnapshotTool.Errors.self
        func call<T>(_ e: any UIElement, _ read: () -> Result<T, UIAXError>, fallback: T) throws -> T {
            guard deadline.arm(e) else { throw ToolError(E.appBusy(appName)) }
            switch read() {
            case .success(let v): return v
            case .failure(.apiDisabled): throw ToolError(E.notTrusted)
            case .failure(.timeout): throw ToolError(E.appBusy(appName))
            case .failure: return fallback
            }
        }
        let list = { try call(app, { app.elements(AXAttr.windows) }, fallback: []) }

        if all {
            let ws = try list()
            guard !ws.isEmpty else { throw ToolError(E.noWindows(appName)) }
            return ws
        }
        guard let selector else {
            if let w = try call(app, { app.element(AXAttr.focusedWindow) }, fallback: nil) { return [w] }
            if let w = try call(app, { app.element(AXAttr.mainWindow) }, fallback: nil) { return [w] }
            guard let w = try list().first else { throw ToolError(E.noWindows(appName)) }
            return [w]
        }
        let ws = try list()
        guard !ws.isEmpty else { throw ToolError(E.noWindows(appName)) }
        // One title read per window, each under the same deadline.
        func titles() throws -> [String] {
            try ws.map { w in
                let a = try call(w, { w.attributes([AXAttr.title]) }, fallback: [:])
                if case .string(let t)? = a[AXAttr.title] { return t }
                return ""
            }
        }
        switch selector {
        case .index(let i):
            if ws.indices.contains(i) { return [ws[i]] }
            throw ToolError(E.windowNotFound(String(i), app: appName, titles: try titles()))
        case .title(let t):
            let all = try titles()
            if let i = all.firstIndex(of: t) { return [ws[i]] }
            if let i = all.firstIndex(where: { $0.range(of: t, options: .caseInsensitive) != nil }) { return [ws[i]] }
            throw ToolError(E.windowNotFound(t, app: appName, titles: all))
        }
    }
}
