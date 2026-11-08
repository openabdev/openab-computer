import Foundation
import CoreGraphics

/// A snapshot plus the element behind every ref. Phase 1 discards `elements`;
/// phase 2 (`ui_action`) keeps it so a `{snapshot_id, ref}` pair can be acted on.
struct UISnapshotResult {
    let snapshot: UISnapshot
    let elements: [String: any UIElement]
}

/// One time budget for a whole `ui_snapshot` call: frontmost-app lookup, window
/// selection and the walk. Every synchronous AX call is armed through `arm` first,
/// so no call starts after the budget is spent, and each call's messaging timeout is
/// at most what is left. The overrun is bounded by one call of at most
/// `messagingTimeoutFloor` (0 would mean "system default", about 6 s).
struct UIDeadline {
    let start: TimeInterval
    let end: TimeInterval
    let now: () -> TimeInterval

    init(timeoutMs: Int, now: @escaping () -> TimeInterval) {
        self.now = now
        start = now()
        end = start + Double(timeoutMs) / 1000
    }

    var expired: Bool { now() >= end }

    /// The messaging timeout for the next AX call: min(0.5 s, remaining), floored at
    /// 0.05 s. nil once the budget is spent.
    func callTimeout() -> Float? {
        let remaining = end - now()
        guard remaining > 0 else { return nil }
        return Float(min(UISnapshotLimits.messagingTimeout, max(UISnapshotLimits.messagingTimeoutFloor, remaining)))
    }

    /// Bound the next call to `e`. false: the budget is spent, do not make the call.
    func arm(_ e: any UIElement) -> Bool {
        guard let t = callTimeout() else { return false }
        e.setMessagingTimeout(t)
        return true
    }

    var elapsedMs: Int { max(0, Int(((now() - start) * 1000).rounded())) }
}

/// Walks accessibility elements into a `UISnapshot`. Pure over `UIElement`, so the
/// fake provider exercises every limit and error path without a GUI.
///
/// Breadth-first across all window roots, so the node budget cuts the deepest
/// elements first; refs are then assigned in pre-order of the resulting tree
/// (`e1`, `e2`, … across windows in window order).
struct UITreeWalker {
    let limits: UISnapshotLimits
    let newSnapshotID: () -> String

    /// The tree while it is being built; converted to `UINode` at the end.
    private final class Building {
        var node = UINode()
        var children: [Building] = []
        let element: any UIElement
        init(_ e: any UIElement) { element = e }
    }

    private struct Pending {
        let element: any UIElement
        let depth: Int
        let parent: Building?
    }

    func walk(app: UIRunningApp, windows: [any UIElement], displays: UIDisplayMap,
              deadline: UIDeadline) throws -> UISnapshotResult {
        var snap = UISnapshot(snapshotID: newSnapshotID(), app: app, windows: [], nodeCount: 0,
                              elapsedMs: 0, limits: limits, displays: displays)
        var roots: [Building] = []
        var seen = Set<AnyHashable>()
        var queue: [Pending] = []
        for w in windows where seen.insert(w.identity).inserted {
            if queue.count < limits.maxNodes {
                queue.append(Pending(element: w, depth: 0, parent: nil))
            } else {
                snap.nodeLimitHit = true
                snap.omittedCount += 1
            }
        }

        var i = 0
        while i < queue.count {
            let item = queue[i]
            i += 1
            if deadline.expired {
                snap.timedOut = true
                // Everything still queued was never read.
                for rest in queue[(i - 1)...] { rest.parent?.node.childrenOmitted += 1 }
                snap.omittedCount += queue.count - (i - 1)
                break
            }
            let pendingAfter = queue.count - i
            guard let built = try visit(item, deadline: deadline, displays: displays,
                                        budget: limits.maxNodes - snap.nodeCount - 1 - pendingAfter,
                                        snap: &snap, seen: &seen, queue: &queue) else { continue }
            snap.nodeCount += 1
            if let parent = item.parent { parent.children.append(built) } else { roots.append(built) }
        }

        var elements: [String: any UIElement] = [:]
        var counter = 0
        func finish(_ b: Building) -> UINode {
            counter += 1
            var n = b.node
            n.ref = "e\(counter)"
            elements[n.ref] = b.element
            n.children = b.children.map(finish)
            return n
        }
        snap.windows = roots.map(finish)
        snap.elapsedMs = deadline.elapsedMs
        return UISnapshotResult(snapshot: snap, elements: elements)
    }

    /// Read one element. nil means drop it (it vanished). `budget` is how many more
    /// children may be queued under the node limit. A node whose read stopped early
    /// (budget spent, or the app did not answer) is kept with what was read and not
    /// descended.
    private func visit(_ item: Pending, deadline: UIDeadline, displays: UIDisplayMap, budget: Int,
                       snap: inout UISnapshot, seen: inout Set<AnyHashable>,
                       queue: inout [Pending]) throws -> Building? {
        let e = item.element
        let b = Building(e)

        /// Arm the next call; false (and `timed_out`) once the budget is spent.
        func armed() -> Bool {
            if deadline.arm(e) { return true }
            snap.timedOut = true
            return false
        }
        /// A call that did not complete: the budget ran out under it, or the app is slow.
        func noAnswer() {
            if deadline.expired {
                snap.timedOut = true
            } else {
                b.node.unresponsive = true
                snap.unresponsiveCount += 1
            }
        }

        guard armed() else { return b }
        let attrs: [String: UIAttrValue]
        switch e.attributes(AXAttr.base) {
        case .success(let a): attrs = a
        case .failure(.apiDisabled): throw ToolError(UISnapshotTool.Errors.notTrusted)
        case .failure(.invalidElement): return nil
        case .failure(.timeout):
            noAnswer()
            return b
        case .failure(.other): attrs = [:]
        }
        fill(&b.node, attrs, displays: displays)

        if UINode.isSecure(role: b.node.role, subrole: b.node.subrole) {
            // Never ask for the value of a secure field, even if the system would mask
            // it, and do not walk into one.
            b.node.masked = true
            return b
        }
        // An unknown role cannot be ruled out as a secure field: fail closed and leave
        // the value unread.
        if b.node.role != nil {
            switch try readValue(e, attrs: attrs, into: &b.node, armed: armed) {
            case .done: break
            case .stop: return b
            case .noAnswer:
                noAnswer()
                return b
            case .vanished: return nil
            }
        }

        let atDepthLimit = item.depth >= limits.maxDepth
        guard armed() else { return b }
        switch e.children(max: atDepthLimit ? 0 : max(budget, 0)) {
        case .success(let c):
            let omitted = max(0, c.total - c.elements.count)
            if omitted > 0 {
                b.node.childrenOmitted = omitted
                snap.omittedCount += omitted
                if atDepthLimit { snap.depthLimitHit = true } else { snap.nodeLimitHit = true }
            }
            // A child already seen (a cycle, or an element reachable twice) is walked once.
            for child in c.elements where seen.insert(child.identity).inserted {
                queue.append(Pending(element: child, depth: item.depth + 1, parent: b))
            }
        case .failure(.apiDisabled): throw ToolError(UISnapshotTool.Errors.notTrusted)
        case .failure(.timeout): noAnswer()
        case .failure(.invalidElement), .failure(.other): break
        }
        return b
    }

    private enum ValueRead { case done, stop, noAnswer, vanished }

    /// The value of a non-secure node. A text longer than the cap (Terminal scrollback,
    /// a large document) is read as a prefix through `AXStringForRange`, so it is not
    /// copied whole over IPC; elements without that support fall back to `AXValue`.
    private func readValue(_ e: any UIElement, attrs: [String: UIAttrValue], into n: inout UINode,
                           armed: () -> Bool) throws -> ValueRead {
        if case .number(let count)? = attrs[AXAttr.numberOfCharacters], count > Double(UISnapshotLimits.stringCap) {
            guard armed() else { return .stop }
            switch e.stringPrefix(utf16Length: UISnapshotLimits.stringCap) {
            case .success(let s?):
                var text = s
                // A cut through a surrogate pair decodes as U+FFFD; drop it.
                if text.hasSuffix("\u{FFFD}") { text.removeLast() }
                n.value = .string(text + "…")
                n.valueTruncated = true
                return .done
            case .success(nil), .failure(.other): break
            case .failure(.apiDisabled): throw ToolError(UISnapshotTool.Errors.notTrusted)
            case .failure(.invalidElement): return .vanished
            case .failure(.timeout): return .noAnswer
            }
        }
        guard armed() else { return .stop }
        switch e.attributes([AXAttr.value]) {
        case .success(let a): setValue(&n, a[AXAttr.value])
        case .failure(.apiDisabled): throw ToolError(UISnapshotTool.Errors.notTrusted)
        case .failure(.invalidElement): return .vanished
        case .failure(.timeout): return .noAnswer
        case .failure(.other): break
        }
        return .done
    }

    private func fill(_ n: inout UINode, _ a: [String: UIAttrValue], displays: UIDisplayMap) {
        func str(_ key: String) -> String? {
            guard case .string(let s)? = a[key], !s.isEmpty else { return nil }
            return Self.cap(s).text
        }
        func flag(_ key: String) -> Bool? {
            switch a[key] {
            case .bool(let b)?: return b
            case .number(let v)?: return v != 0
            default: return nil
            }
        }
        n.role = str(AXAttr.role)
        n.subrole = str(AXAttr.subrole)
        n.roleDescription = str(AXAttr.roleDescription)
        n.title = str(AXAttr.title)
        n.description = str(AXAttr.description)
        n.help = str(AXAttr.help)
        n.identifier = str(AXAttr.identifier)
        n.enabled = flag(AXAttr.enabled) ?? true
        n.focused = flag(AXAttr.focused) ?? false
        n.selected = flag(AXAttr.selected) ?? false
        if case .point(let p)? = a[AXAttr.position], case .size(let s)? = a[AXAttr.size],
           [p.x, p.y, s.width, s.height].allSatisfy({ $0.isFinite }) {
            let global = CGRect(origin: p, size: s)
            if let hit = displays.locate(global) {
                n.frame = Self.round(hit.frame)
                n.display = hit.display
            } else {
                n.frame = Self.round(displays.relative(global, to: 0))
                n.offscreen = true
            }
        }
    }

    private func setValue(_ n: inout UINode, _ v: UIAttrValue?) {
        switch v {
        case .string(let s)? where !s.isEmpty:
            let c = Self.cap(s)
            n.value = .string(c.text)
            n.valueTruncated = c.truncated
        case .number(let d)? where d.isFinite: n.value = .number(d)
        case .bool(let b)?: n.value = .bool(b)
        default: break   // points, sizes, empty strings: not a value
        }
    }

    static func cap(_ s: String) -> (text: String, truncated: Bool) {
        s.count > UISnapshotLimits.stringCap ? (String(s.prefix(UISnapshotLimits.stringCap)) + "…", true) : (s, false)
    }

    static func round(_ r: CGRect) -> CGRect {
        func r1(_ v: CGFloat) -> CGFloat { (v * 10).rounded() / 10 }
        return CGRect(x: r1(r.origin.x), y: r1(r.origin.y), width: r1(r.width), height: r1(r.height))
    }
}
