import Foundation
import CoreGraphics
import ApplicationServices

/// Shared plumbing for CGEvent-based input tools.
enum Input {
    /// Input injection needs the Accessibility grant; without it CGEvent posts are
    /// silently dropped. Fail loudly instead.
    static func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw ToolError("Accessibility not granted: input events would be silently dropped. " +
                            "Grant Accessibility to OpenAB Computer (oab-computer) in System Settings → Privacy & Security → Accessibility, then restart the agent.")
        }
    }

    static func post(_ e: CGEvent?) throws {
        guard let e else { throw ToolError("CGEvent creation failed") }
        e.post(tap: .cghidEventTap)
    }

    static func sleep(ms: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(max(ms, 0)) * 1_000_000)
    }

    /// Display-point → global CG point. `display` indexes the same ordering `screenshot`
    /// uses (main display first). Coordinates are relative to that display's top-left.
    static func globalPoint(x: Double, y: Double, display: Int) throws -> CGPoint {
        let list = DisplayOrder.activeDisplayIDs()
        guard display >= 0, display < list.count else {
            throw ToolError("display \(display) out of range; \(list.count) display(s)")
        }
        let b = CGDisplayBounds(list[display])
        guard x >= 0, y >= 0, x <= b.width, y <= b.height else {
            throw ToolError("point (\(x), \(y)) outside display \(display) bounds \(Int(b.width))×\(Int(b.height))")
        }
        return CGPoint(x: b.origin.x + x, y: b.origin.y + y)
    }

    static func currentMouse() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    // MARK: keys

    /// Virtual keycodes for a US ANSI layout (kVK_*). Letters/digits are here so key
    /// combos like `cmd+c` work regardless of the front app; free text goes through
    /// `type`, which uses unicode and is layout-independent.
    static let keycodes: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
        "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
        "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "backspace": 0x33,
        "escape": 0x35, "esc": 0x35, "forwarddelete": 0x75,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "capslock": 0x39, "volumeup": 0x48, "volumedown": 0x49, "mute": 0x4A,
    ]

    static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "meta": .maskCommand, "super": .maskCommand,
        "ctrl": .maskControl, "control": .maskControl,
        "alt": .maskAlternate, "opt": .maskAlternate, "option": .maskAlternate,
        "shift": .maskShift, "fn": .maskSecondaryFn,
    ]

    struct KeyCombo: Equatable {
        var code: CGKeyCode
        var flags: CGEventFlags
    }

    /// Parse `"cmd+shift+4"`, `"return"`, `"ctrl+c"`. Case-insensitive; `+` separates;
    /// the last token is the key, everything before must be a modifier.
    static func parseCombo(_ s: String) throws -> KeyCombo {
        let parts = s.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let keyName = parts.last, !keyName.isEmpty else { throw ToolError("empty key") }
        var flags = CGEventFlags()
        for m in parts.dropLast() {
            guard let f = modifiers[m] else { throw ToolError("unknown modifier '\(m)' in '\(s)'") }
            flags.insert(f)
        }
        // "plus" spelled out so "cmd+plus" is possible; "+" alone can't survive the split.
        let name = keyName == "plus" ? "=" : keyName
        guard let code = keycodes[name] else {
            throw ToolError("unknown key '\(keyName)' in '\(s)'; use a letter, digit, punctuation, or one of: " +
                            keycodes.keys.filter { $0.count > 1 }.sorted().joined(separator: " "))
        }
        return KeyCombo(code: code, flags: flags)
    }
}
