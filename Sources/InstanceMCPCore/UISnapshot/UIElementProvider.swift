import Foundation
import CoreGraphics

/// The handful of Accessibility failures `ui_snapshot` tells apart. Everything else
/// is `.other(code)` and treated as "attribute not available".
public enum UIAXError: Error, Equatable, Sendable {
    /// kAXErrorAPIDisabled: this process has no Accessibility grant. Fails the whole call.
    case apiDisabled
    /// kAXErrorCannotComplete: the app did not answer within the messaging timeout
    /// (hung, busy or gone). The node is kept with what was read, and not descended.
    case timeout
    /// kAXErrorInvalidUIElement: the element vanished while we walked. The node is dropped.
    case invalidElement
    case other(Int32)
}

/// An attribute value as `ui_snapshot` sees it. Arrays, elements and other CF types
/// are not represented: the walker reads those through `element`/`elements`/`children`.
public enum UIAttrValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case point(CGPoint)
    case size(CGSize)
}

/// One accessibility element. The live implementation wraps `AXUIElement`
/// (`AXLiveElement`); tests use a fake, so the walker runs in `swift test` with no
/// GUI session and no Accessibility grant.
public protocol UIElement: AnyObject {
    /// Stable identity for cycle and duplicate detection.
    var identity: AnyHashable { get }
    /// Batch read. Missing, unsupported or empty attributes are absent from the map.
    func attributes(_ names: [String]) -> Result<[String: UIAttrValue], UIAXError>
    /// A single element-valued attribute (`AXFocusedWindow`, `AXMainWindow`); nil when absent.
    func element(_ name: String) -> Result<(any UIElement)?, UIAXError>
    /// An array-of-elements attribute (`AXWindows`); empty when absent.
    func elements(_ name: String) -> Result<[any UIElement], UIAXError>
    /// At most `max` children plus the total child count, so a 10 000-row table is
    /// never copied whole. `max == 0` only counts.
    func children(max: Int) -> Result<(elements: [any UIElement], total: Int), UIAXError>
    /// Bound every later IPC to this element's app (`AXUIElementSetMessagingTimeout`).
    func setMessagingTimeout(_ seconds: Float)
}

/// Attribute names, as the AX API spells them (kAX…Attribute).
enum AXAttr {
    static let role = "AXRole"
    static let subrole = "AXSubrole"
    static let roleDescription = "AXRoleDescription"
    static let title = "AXTitle"
    static let value = "AXValue"
    static let description = "AXDescription"
    static let help = "AXHelp"
    static let identifier = "AXIdentifier"
    static let enabled = "AXEnabled"
    static let focused = "AXFocused"
    static let selected = "AXSelected"
    static let position = "AXPosition"
    static let size = "AXSize"
    static let windows = "AXWindows"
    static let focusedWindow = "AXFocusedWindow"
    static let mainWindow = "AXMainWindow"

    /// Everything read for a node in one batch. `AXValue` is deliberately not here:
    /// it is read in a second call, and only when the node is not secure.
    static let base = [role, subrole, roleDescription, title, description, help, identifier,
                       enabled, focused, selected, position, size]
}
