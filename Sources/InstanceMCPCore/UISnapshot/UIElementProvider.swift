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
    /// never copied whole. `max == 0` only counts. Counting and copying are two IPCs;
    /// `rearm` runs between them and returns false (the call then fails with `.timeout`)
    /// once the budget is spent.
    func children(max: Int, rearm: () -> Bool) -> Result<(elements: [any UIElement], total: Int), UIAXError>
    /// The first `utf16Length` UTF-16 units of the element's text (`AXStringForRange`),
    /// so a long value is not copied whole. nil when the element does not support it.
    func stringPrefix(utf16Length: Int) -> Result<String?, UIAXError>
    /// Bound every later IPC to this element's app (`AXUIElementSetMessagingTimeout`).
    func setMessagingTimeout(_ seconds: Float)

    // `ui_action` (#67 phase 2). Each of these is one IPC, except `pid`.

    /// The pid of the app owning the element (`AXUIElementGetPid`, no IPC); nil if unknown.
    var pid: Int32? { get }
    /// The AX actions the element supports (`AXUIElementCopyActionNames`).
    func actionNames() -> Result<[String], UIAXError>
    /// Whether an attribute can be set (`AXUIElementIsAttributeSettable`).
    func isSettable(_ name: String) -> Result<Bool, UIAXError>
    /// Perform an AX action (`AXUIElementPerformAction`).
    func perform(_ action: String) -> Result<Void, UIAXError>
    /// Set a string, number or bool attribute (`AXUIElementSetAttributeValue`).
    func setValue(_ name: String, _ value: UIAttrValue) -> Result<Void, UIAXError>
}

extension UIAXError {
    /// The element does not support the attribute or action asked for (or rejects the
    /// argument): attributeUnsupported, actionUnsupported, notImplemented, illegalArgument.
    var isUnsupported: Bool {
        if case .other(let code) = self { return [-25205, -25206, -25208, -25201].contains(code) }
        return false
    }
}

/// Action names, as the AX API spells them (kAX…Action).
enum AXAction {
    static let press = "AXPress"
    static let showMenu = "AXShowMenu"
    static let confirm = "AXConfirm"
    static let cancel = "AXCancel"
    static let increment = "AXIncrement"
    static let decrement = "AXDecrement"
    /// Brings a window to the front of its app without activating the app.
    static let raise = "AXRaise"
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
    /// The window an element is in (absent for menu items and for the window itself).
    static let window = "AXWindow"
    static let menuBar = "AXMenuBar"
    /// On the application element: set to true to bring the app to the front.
    static let frontmost = "AXFrontmost"
    /// Text length in UTF-16 units; decides whether the value is read as a prefix.
    static let numberOfCharacters = "AXNumberOfCharacters"

    /// Everything read for a node in one batch. `AXValue` is deliberately not here:
    /// it is read in a second call, and only when the node is not secure.
    static let base = [role, subrole, roleDescription, title, description, help, identifier,
                       enabled, focused, selected, position, size, numberOfCharacters]
}
