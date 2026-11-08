import Foundation
import CoreGraphics

/// Caller-settable limits, clamped silently; the effective values are echoed back.
public struct UISnapshotLimits: Equatable, Sendable {
    public static let defaultDepth = 20, minDepth = 1, maxDepthCap = 50
    public static let defaultNodes = 300, minNodes = 1, maxNodesCap = 2000
    public static let defaultTimeoutMs = 3000, minTimeoutMs = 100, maxTimeoutMs = 10_000
    /// Per-element AX messaging timeout ceiling and floor, in seconds (not caller-settable).
    public static let messagingTimeout: Double = 0.5, messagingTimeoutFloor: Double = 0.05
    /// Characters kept of any string attribute before `…`.
    public static let stringCap = 200
    /// Characters of a value shown in the text rendering.
    public static let textValueCap = 80

    public let maxDepth: Int
    public let maxNodes: Int
    public let timeoutMs: Int

    public init(maxDepth: Int? = nil, maxNodes: Int? = nil, timeoutMs: Int? = nil) {
        self.maxDepth = min(max(maxDepth ?? Self.defaultDepth, Self.minDepth), Self.maxDepthCap)
        self.maxNodes = min(max(maxNodes ?? Self.defaultNodes, Self.minNodes), Self.maxNodesCap)
        self.timeoutMs = min(max(timeoutMs ?? Self.defaultTimeoutMs, Self.minTimeoutMs), Self.maxTimeoutMs)
    }

    var json: JSONValue {
        ["max_depth": .number(Double(maxDepth)), "max_nodes": .number(Double(maxNodes)),
         "timeout_ms": .number(Double(timeoutMs))]
    }
}

/// The app a snapshot was taken of.
public struct UIRunningApp: Equatable, Sendable {
    public let pid: Int32
    public let bundleID: String?
    public let name: String?
    /// A regular (Dock) app. Only used to keep "app not found" lists short.
    public let regular: Bool

    public init(pid: Int32, bundleID: String?, name: String?, regular: Bool = true) {
        self.pid = pid; self.bundleID = bundleID; self.name = name; self.regular = regular
    }

    var displayName: String { name ?? bundleID ?? "pid \(pid)" }

    var json: JSONValue {
        var o: [String: JSONValue] = ["pid": .number(Double(pid))]
        if let name { o["name"] = .string(name) }
        if let bundleID { o["bundle_id"] = .string(bundleID) }
        return .object(o)
    }
}

/// One element of the tree. Optional fields and false flags are omitted from JSON.
public struct UINode: Equatable, Sendable {
    public var ref = ""
    public var role: String?
    public var subrole: String?
    public var roleDescription: String?
    public var title: String?
    /// String, number or bool only. Never set for a secure node.
    public var value: UIAttrValue?
    public var valueTruncated = false
    /// A secure text field (or anything with a secure role/subrole): its value is never read.
    public var masked = false
    public var description: String?
    public var help: String?
    public var identifier: String?
    public var enabled = true
    public var focused = false
    public var selected = false
    /// Display-relative points, the space `screenshot` and `mouse` use.
    public var frame: CGRect?
    public var display: Int?
    public var offscreen = false
    /// Children that exist but were not walked (depth, node or time limit).
    public var childrenOmitted = 0
    public var children: [UINode] = []

    public init() {}

    /// Secure if the role or subrole is `AXSecureTextField` or mentions "secure".
    static func isSecure(role: String?, subrole: String?) -> Bool {
        [role, subrole].contains { s in
            guard let s else { return false }
            return s == "AXSecureTextField" || s.range(of: "secure", options: .caseInsensitive) != nil
        }
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["ref": .string(ref)]
        if let role { o["role"] = .string(role) }
        if let subrole { o["subrole"] = .string(subrole) }
        if let roleDescription { o["role_description"] = .string(roleDescription) }
        if let title { o["title"] = .string(title) }
        switch value {
        case .string(let s)?: o["value"] = .string(s)
        case .number(let n)?: o["value"] = .number(n)
        case .bool(let b)?: o["value"] = .bool(b)
        default: break
        }
        if valueTruncated { o["value_truncated"] = true }
        if masked { o["masked"] = true }
        if let description { o["description"] = .string(description) }
        if let help { o["help"] = .string(help) }
        if let identifier { o["identifier"] = .string(identifier) }
        if !enabled { o["enabled"] = false }
        if focused { o["focused"] = true }
        if selected { o["selected"] = true }
        if let f = frame {
            o["frame"] = ["x": .number(f.origin.x), "y": .number(f.origin.y),
                          "width": .number(f.width), "height": .number(f.height)]
        }
        if let display { o["display"] = .number(Double(display)) }
        if offscreen { o["offscreen"] = true }
        if childrenOmitted > 0 { o["children_omitted"] = .number(Double(childrenOmitted)) }
        if !children.isEmpty { o["children"] = .array(children.map(\.json)) }
        return .object(o)
    }
}

/// A finished snapshot: the tree plus what stopped the walk, if anything.
public struct UISnapshot: Equatable, Sendable {
    public var snapshotID: String
    public var app: UIRunningApp
    public var windows: [UINode]
    public var nodeCount: Int
    public var nodeLimitHit = false
    public var depthLimitHit = false
    /// Elements that exist but were not walked, summed over the tree (and over
    /// windows that did not fit the node budget).
    public var omittedCount = 0
    public var timedOut = false
    public var elapsedMs: Int
    public var limits: UISnapshotLimits
    public var displays: UIDisplayMap

    public var truncated: Bool { nodeLimitHit || depthLimitHit }

    public static let coordinates =
        "display points relative to the display's top-left, same space as screenshot and mouse"

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "snapshot_id": .string(snapshotID),
            "app": app.json,
            "windows": .array(windows.map(\.json)),
            "node_count": .number(Double(nodeCount)),
            "truncated": .bool(truncated),
            "timed_out": .bool(timedOut),
            "elapsed_ms": .number(Double(elapsedMs)),
            "limits": limits.json,
            "displays": displays.json,
            "coordinates": .string(Self.coordinates),
        ]
        if truncated {
            var by: [JSONValue] = []
            if nodeLimitHit { by.append("max_nodes") }
            if depthLimitHit { by.append("max_depth") }
            o["truncated_by"] = .array(by)
        }
        if omittedCount > 0 { o["omitted_count"] = .number(Double(omittedCount)) }
        return .object(o)
    }

    /// Compact indented rendering for models: `[ref] Role/Subrole "title" = value (x,y w×h) flags`.
    public func renderText() -> String {
        var lines: [String] = []
        var app = app.displayName
        let detail = [self.app.bundleID, "pid \(self.app.pid)"].compactMap { $0 }
        if self.app.name != nil { app += " (\(detail.joined(separator: ", ")))" }
        lines.append("ui_snapshot \(snapshotID) · \(app) · \(nodeCount) nodes · \(elapsedMs) ms")
        func walk(_ n: UINode, _ depth: Int) {
            lines.append(String(repeating: "  ", count: depth) + Self.line(n))
            for c in n.children { walk(c, depth + 1) }
        }
        for w in windows { walk(w, 0) }
        if windows.isEmpty { lines.append("(no elements)") }
        if truncated {
            var why: [String] = []
            if nodeLimitHit { why.append("node limit \(limits.maxNodes) reached (max_nodes up to \(UISnapshotLimits.maxNodesCap))") }
            if depthLimitHit { why.append("depth limit \(limits.maxDepth) reached (max_depth up to \(UISnapshotLimits.maxDepthCap))") }
            lines.append("truncated: " + why.joined(separator: "; ") + "; \(omittedCount) elements not walked")
        }
        if timedOut {
            lines.append("timed_out: walk stopped after \(elapsedMs) ms; the app may be busy — raise timeout_ms up to \(UISnapshotLimits.maxTimeoutMs) or retry")
        }
        return lines.joined(separator: "\n")
    }

    static func line(_ n: UINode) -> String {
        var s = "[\(n.ref)] \(n.role ?? "?")"
        if let sub = n.subrole { s += "/\(sub)" }
        if let t = n.title { s += " \"\(clip(t, UISnapshotLimits.textValueCap))\"" }
        if n.masked {
            s += " = ‹masked›"
        } else {
            switch n.value {
            case .string(let v)?: s += " = \"\(clip(v, UISnapshotLimits.textValueCap))\""
            case .number(let v)?: s += " = \(v.rounded() == v && abs(v) < 1e15 ? String(Int64(v)) : String(v))"
            case .bool(let v)?: s += " = \(v)"
            default: break
            }
        }
        if let d = n.description, d != n.title { s += " desc=\"\(clip(d, UISnapshotLimits.textValueCap))\"" }
        if let f = n.frame {
            let prefix = (n.display ?? 0) != 0 ? "d\(n.display!):" : ""
            s += " (\(prefix)\(int(f.origin.x)),\(int(f.origin.y)) \(int(f.width))×\(int(f.height)))"
        }
        if n.offscreen { s += " offscreen" }
        if !n.enabled { s += " disabled" }
        if n.focused { s += " focused" }
        if n.selected { s += " selected" }
        if n.childrenOmitted > 0 { s += " +\(n.childrenOmitted) more" }
        return s
    }

    private static func int(_ v: CGFloat) -> String { String(Int((Double(v)).rounded())) }

    /// One line, at most `cap` characters (then `…`); newlines shown as ⏎.
    static func clip(_ s: String, _ cap: Int) -> String {
        let flat = s.replacingOccurrences(of: "\r\n", with: "⏎").replacingOccurrences(of: "\n", with: "⏎")
            .replacingOccurrences(of: "\r", with: "⏎")
        return flat.count > cap ? String(flat.prefix(cap)) + "…" : flat
    }
}
