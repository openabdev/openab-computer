import Foundation
import CoreGraphics

/// A snapshot plus the element behind every ref. Phase 1 discards `elements`;
/// phase 2 (`ui_action`) keeps it so a `{snapshot_id, ref}` pair can be acted on.
struct UISnapshotResult {
    let snapshot: UISnapshot
    let elements: [String: any UIElement]
}

/// Walks accessibility elements into a `UISnapshot`. Pure over `UIElement`, so the
/// fake provider exercises every limit and error path without a GUI.
///
/// Breadth-first across all window roots, so the node budget cuts the deepest
/// elements first; refs are then assigned in pre-order of the resulting tree
/// (`e1`, `e2`, … across windows in window order).
struct UITreeWalker {
    let limits: UISnapshotLimits
    let now: () -> TimeInterval
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

    func walk(app: UIRunningApp, windows: [any UIElement], displays: UIDisplayMap) throws -> UISnapshotResult {
        let start = now()
        let deadline = start + Double(limits.timeoutMs) / 1000
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
            let remaining = deadline - now()
            if remaining <= 0 {
                snap.timedOut = true
                // Everything still queued was never read.
                for rest in queue[(i - 1)...] { rest.parent?.node.childrenOmitted += 1 }
                snap.omittedCount += queue.count - (i - 1)
                break
            }
            let pendingAfter = queue.count - i
            guard let built = try visit(item, remaining: remaining, displays: displays,
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
        snap.elapsedMs = max(0, Int(((now() - start) * 1000).rounded()))
        return UISnapshotResult(snapshot: snap, elements: elements)
    }

    /// Read one element. nil means drop it (it vanished). `budget` is how many more
    /// children may be queued under the node limit.
    private func visit(_ item: Pending, remaining: TimeInterval, displays: UIDisplayMap, budget: Int,
                       snap: inout UISnapshot, seen: inout Set<AnyHashable>,
                       queue: inout [Pending]) throws -> Building? {
        let e = item.element
        e.setMessagingTimeout(Float(min(UISnapshotLimits.messagingTimeout,
                                        max(UISnapshotLimits.messagingTimeoutFloor, remaining))))
        let b = Building(e)

        let attrs: [String: UIAttrValue]
        switch e.attributes(AXAttr.base) {
        case .success(let a): attrs = a
        case .failure(.apiDisabled): throw ToolError(UISnapshotTool.Errors.notTrusted)
        case .failure(.invalidElement): return nil
        case .failure(.timeout):
            snap.timedOut = true
            return b
        case .failure(.other): attrs = [:]
        }
        fill(&b.node, attrs, displays: displays)

        if UINode.isSecure(role: b.node.role, subrole: b.node.subrole) {
            // Never ask for the value of a secure field, even if the system would mask it.
            b.node.masked = true
        } else {
            switch e.attributes([AXAttr.value]) {
            case .success(let a): setValue(&b.node, a[AXAttr.value])
            case .failure(.apiDisabled): throw ToolError(UISnapshotTool.Errors.notTrusted)
            case .failure(.invalidElement): return nil
            case .failure(.timeout):
                snap.timedOut = true
                return b
            case .failure(.other): break
            }
        }

        let atDepthLimit = item.depth >= limits.maxDepth
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
        case .failure(.timeout): snap.timedOut = true
        case .failure(.invalidElement), .failure(.other): break
        }
        return b
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
