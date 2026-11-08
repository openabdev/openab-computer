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
    /// first of `AXWindows`.
    static func windows(of app: any UIElement, appName: String, selector: WindowSelector?,
                        all: Bool) throws -> [any UIElement] {
        let E = UISnapshotTool.Errors.self
        func check<T>(_ r: Result<T, UIAXError>, fallback: T) throws -> T {
            switch r {
            case .success(let v): return v
            case .failure(.apiDisabled): throw ToolError(E.notTrusted)
            case .failure(.timeout): throw ToolError(E.appBusy(appName))
            case .failure: return fallback
            }
        }
        let list = { try check(app.elements(AXAttr.windows), fallback: []) }

        if all {
            let ws = try list()
            guard !ws.isEmpty else { throw ToolError(E.noWindows(appName)) }
            return ws
        }
        guard let selector else {
            if let w = try check(app.element(AXAttr.focusedWindow), fallback: nil) { return [w] }
            if let w = try check(app.element(AXAttr.mainWindow), fallback: nil) { return [w] }
            guard let w = try list().first else { throw ToolError(E.noWindows(appName)) }
            return [w]
        }
        let ws = try list()
        guard !ws.isEmpty else { throw ToolError(E.noWindows(appName)) }
        let titles: [String] = ws.map { w in
            if case .success(let a) = w.attributes([AXAttr.title]), case .string(let t)? = a[AXAttr.title] { return t }
            return ""
        }
        switch selector {
        case .index(let i) where ws.indices.contains(i):
            return [ws[i]]
        case .title(let t):
            if let i = titles.firstIndex(of: t) { return [ws[i]] }
            if let i = titles.firstIndex(where: { $0.range(of: t, options: .caseInsensitive) != nil }) { return [ws[i]] }
        default:
            break
        }
        let label: String
        switch selector {
        case .index(let i): label = String(i)
        case .title(let t): label = t
        }
        throw ToolError(E.windowNotFound(label, app: appName, titles: titles))
    }
}
