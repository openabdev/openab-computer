import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// `UIElement` over a live `AXUIElement`. Not exercised in CI (no grant there);
/// covered by the walker tests through the fake and by a live check.
final class AXLiveElement: UIElement {
    let ax: AXUIElement
    init(_ ax: AXUIElement) { self.ax = ax }

    /// CFEqual/CFHash identity: two AXUIElement refs to the same UI object compare equal.
    private struct Identity: Hashable {
        let ax: AXUIElement
        static func == (a: Identity, b: Identity) -> Bool { CFEqual(a.ax, b.ax) }
        func hash(into h: inout Hasher) { h.combine(CFHash(ax)) }
    }

    var identity: AnyHashable { AnyHashable(Identity(ax: ax)) }

    private static func map(_ e: AXError) -> UIAXError {
        switch e {
        case .apiDisabled: return .apiDisabled
        case .cannotComplete: return .timeout
        case .invalidUIElement: return .invalidElement
        default: return .other(e.rawValue)
        }
    }

    private static func isAbsent(_ e: AXError) -> Bool {
        e == .noValue || e == .attributeUnsupported || e == .notImplemented
    }

    func attributes(_ names: [String]) -> Result<[String: UIAttrValue], UIAXError> {
        var out: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(ax, names as CFArray, [], &out)
        if err != .success { return Self.isAbsent(err) ? .success([:]) : .failure(Self.map(err)) }
        let arr = Self.list(out)
        var entries: [String: BatchEntry] = [:]
        for (i, name) in names.enumerated() where i < arr.count {
            switch Self.convert(arr[i]) {
            case .value(let v): entries[name] = .value(v)
            case .error(let e): entries[name] = .error(e)
            case .none: break
            }
        }
        return Self.reduceBatch(entries)
    }

    /// One entry of a multi-attribute read: a value, or a per-entry `AXValue(.axError)`.
    enum BatchEntry: Equatable {
        case value(UIAttrValue)
        case error(AXError)
    }

    /// Reduce a partial batch to the element's result. Pure, so it is unit-tested.
    ///
    /// A batch can mix values and per-entry errors. Absent and unsupported attributes
    /// are dropped. A grant, timeout or vanished-element error on any entry is the
    /// element's failure: otherwise a readable `AXRole` next to an unreadable
    /// `AXSubrole` would look like a known non-secure node, and the walker would ask
    /// for its value. Any other error on a role or subrole entry also fails the batch,
    /// so masking fails closed; on other entries it only drops that attribute.
    static func reduceBatch(_ entries: [String: BatchEntry]) -> Result<[String: UIAttrValue], UIAXError> {
        var result: [String: UIAttrValue] = [:]
        var errors: [(name: String, error: AXError)] = []
        for (name, entry) in entries {
            switch entry {
            case .value(let v): result[name] = v
            case .error(let e) where !isAbsent(e): errors.append((name, e))
            case .error: break
            }
        }
        for e in [AXError.apiDisabled, .invalidUIElement, .cannotComplete] where errors.contains(where: { $0.error == e }) {
            return .failure(map(e))
        }
        let maskingKeys: Set<String> = [AXAttr.role, AXAttr.subrole]
        if let e = errors.first(where: { maskingKeys.contains($0.name) }) { return .failure(map(e.error)) }
        return .success(result)
    }

    private enum Converted { case value(UIAttrValue), error(AXError), none }

    private static func convert(_ v: AnyObject) -> Converted {
        let cf = v as CFTypeRef
        let type = CFGetTypeID(cf)
        // CFBoolean before CFNumber: a CFBoolean also bridges to NSNumber.
        if type == CFBooleanGetTypeID() {
            return .value(.bool(CFBooleanGetValue(unsafeBitCast(cf, to: CFBoolean.self))))
        }
        if type == CFNumberGetTypeID() {
            var d: Double = 0
            CFNumberGetValue(unsafeBitCast(cf, to: CFNumber.self), .doubleType, &d)
            return .value(.number(d))
        }
        if type == CFStringGetTypeID() {
            return .value(.string(unsafeBitCast(cf, to: CFString.self) as String))
        }
        if type == AXValueGetTypeID() {
            let ax = unsafeBitCast(cf, to: AXValue.self)
            switch AXValueGetType(ax) {
            case .cgPoint:
                var p = CGPoint.zero
                return AXValueGetValue(ax, .cgPoint, &p) ? .value(.point(p)) : .none
            case .cgSize:
                var s = CGSize.zero
                return AXValueGetValue(ax, .cgSize, &s) ? .value(.size(s)) : .none
            case .axError:
                var raw: Int32 = 0
                guard AXValueGetValue(ax, .axError, &raw), let e = AXError(rawValue: raw) else { return .none }
                return .error(e)
            default:
                return .none
            }
        }
        return .none
    }

    private static func list(_ a: CFArray?) -> [AnyObject] {
        guard let a else { return [] }
        return (a as NSArray) as [AnyObject]
    }

    private static func asElement(_ v: CFTypeRef?) -> AXLiveElement? {
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return AXLiveElement(unsafeBitCast(v, to: AXUIElement.self))
    }

    func element(_ name: String) -> Result<(any UIElement)?, UIAXError> {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(ax, name as CFString, &v)
        if err != .success { return Self.isAbsent(err) ? .success(nil) : .failure(Self.map(err)) }
        return .success(Self.asElement(v))
    }

    func elements(_ name: String) -> Result<[any UIElement], UIAXError> {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(ax, name as CFString, &v)
        if err != .success { return Self.isAbsent(err) ? .success([]) : .failure(Self.map(err)) }
        guard let arr = v as? [AnyObject] else { return .success([]) }
        return .success(arr.compactMap { Self.asElement($0 as CFTypeRef) })
    }

    func children(max: Int, rearm: () -> Bool) -> Result<(elements: [any UIElement], total: Int), UIAXError> {
        let attr = kAXChildrenAttribute as CFString
        var count: CFIndex = 0
        let err = AXUIElementGetAttributeValueCount(ax, attr, &count)
        if err != .success { return Self.isAbsent(err) ? .success(([], 0)) : .failure(Self.map(err)) }
        let want = Swift.min(Swift.max(max, 0), count)
        guard want > 0 else { return .success(([], count)) }
        // Second IPC: re-armed, so it gets only what is left of the budget.
        guard rearm() else { return .failure(.timeout) }
        var out: CFArray?
        let err2 = AXUIElementCopyAttributeValues(ax, attr, 0, want, &out)
        if err2 != .success { return Self.isAbsent(err2) ? .success(([], 0)) : .failure(Self.map(err2)) }
        let arr = Self.list(out)
        return .success((arr.compactMap { Self.asElement($0 as CFTypeRef) }, count))
    }

    func stringPrefix(utf16Length: Int) -> Result<String?, UIAXError> {
        var range = CFRange(location: 0, length: utf16Length)
        guard let param = AXValueCreate(.cfRange, &range) else { return .success(nil) }
        var v: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            ax, kAXStringForRangeParameterizedAttribute as CFString, param, &v)
        if err != .success {
            let unsupported = Self.isAbsent(err) || err == .parameterizedAttributeUnsupported || err == .illegalArgument
            return unsupported ? .success(nil) : .failure(Self.map(err))
        }
        guard let v, CFGetTypeID(v) == CFStringGetTypeID() else { return .success(nil) }
        return .success(unsafeBitCast(v, to: CFString.self) as String)
    }

    func setMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(ax, seconds)
    }
}

/// The live sources `UISnapshotTool` reads from. All non-prompting.
enum AXLive {
    static func isTrusted() -> Bool { AXIsProcessTrusted() }

    static func appElement(_ pid: Int32) -> any UIElement {
        AXLiveElement(AXUIElementCreateApplication(pid))
    }

    /// The app owning keyboard focus, from the system-wide element; NSWorkspace as fallback.
    ///
    /// Setting the messaging timeout on the system-wide element sets the process-global
    /// AX timeout. That is intended: no other tool makes AX messaging calls, and every
    /// element `ui_snapshot` touches gets its own timeout through `UIDeadline.arm`.
    static func frontmostPid(timeout: Float) -> Int32? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, timeout)
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(sys, kAXFocusedApplicationAttribute as CFString, &v) == .success,
           let v, CFGetTypeID(v) == AXUIElementGetTypeID() {
            var pid: pid_t = 0
            if AXUIElementGetPid(unsafeBitCast(v, to: AXUIElement.self), &pid) == .success, pid > 0 { return pid }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    static func runningApps() -> [UIRunningApp] {
        NSWorkspace.shared.runningApplications.map {
            UIRunningApp(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, name: $0.localizedName,
                         regular: $0.activationPolicy == .regular)
        }
    }

    static func displays() -> UIDisplayMap {
        let list = DisplayOrder.activeDisplayIDs().map { (id: UInt32($0), bounds: CGDisplayBounds($0)) }
        return UIDisplayMap(displays: list, mainID: CGMainDisplayID())
    }
}
