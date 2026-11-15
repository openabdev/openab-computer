import AppKit
import XCTest
@testable import InstanceMCPCore

/// The Browser tools card must stay readable. Its colours are resolved under both appearances, and the card is
/// drawn in the forced-light wizard window under a dark system setting.
@MainActor
final class WizardCardContrastTests: XCTestCase {
    private func rgb(_ color: NSColor, _ appearance: NSAppearance, over: (CGFloat, CGFloat, CGFloat)? = nil) -> (CGFloat, CGFloat, CGFloat) {
        var out: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        appearance.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            let bg = over ?? (1, 1, 1)
            out = (c.redComponent * c.alphaComponent + bg.0 * (1 - c.alphaComponent),
                   c.greenComponent * c.alphaComponent + bg.1 * (1 - c.alphaComponent),
                   c.blueComponent * c.alphaComponent + bg.2 * (1 - c.alphaComponent))
        }
        return out
    }

    private func luminance(_ c: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
    }

    private func contrast(_ fg: NSColor, _ bg: NSColor, _ appearance: NSAppearance) -> CGFloat {
        let b = rgb(bg, appearance)
        let a = luminance(rgb(fg, appearance, over: b)), l = luminance(b)
        return (max(a, l) + 0.05) / (min(a, l) + 0.05)
    }

    /// Body text states on the card: title/checkbox, detail, progress and failure text.
    func testBodyTextContrastUnderBothAppearances() {
        let states: [(String, NSColor, CGFloat)] = [
            ("title/checkbox (idle, installing, installed)", .labelColor, 4.5),
            ("detail and progress (idle, installing, installed)", .labelColor, 4.5),
            ("failure", .systemRed, 3.0),
        ]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            for (state, color, minimum) in states {
                let ratio = contrast(color, WizardCardStackView.fill, appearance)
                XCTAssertGreaterThanOrEqual(ratio, minimum, "\(state) under \(name.rawValue): \(ratio)")
            }
        }
    }

    /// The bug: the card fill must be light inside the forced-light window even when the system is dark, and it
    /// must follow a later appearance change.
    func testCardFillResolvesAgainstTheViewAppearance() {
        let window = WizardWindowFactory.makeWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 620))
        let card = WizardCardStackView(views: [NSTextField(labelWithString: "x")])
        window.contentView!.addSubview(card)
        card.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        card.updateLayer()
        func fillLuminance() -> CGFloat {
            luminance(rgb(NSColor(cgColor: card.layer!.backgroundColor!)!, NSAppearance(named: .aqua)!))
        }
        XCTAssertEqual(card.effectiveAppearance.name, .aqua)
        XCTAssertGreaterThan(fillLuminance(), 0.8)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView?.appearance = NSAppearance(named: .darkAqua)
        card.updateLayer()
        XCTAssertLessThan(fillLuminance(), 0.2)
    }
}
