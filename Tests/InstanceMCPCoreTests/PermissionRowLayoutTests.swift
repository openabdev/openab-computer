import AppKit
import XCTest
@testable import InstanceMCPCore

/// Builds the wizard rows off screen and checks the layout the user reviewed on a real Mac:
/// aligned trailing column, one row height, no duplicate "Allowed", no clipped text, light appearance.
@MainActor
final class PermissionRowLayoutTests: XCTestCase {
    private let stillOff = "Still off. Turn it on in System Settings, then come back."

    private struct Built {
        let window: NSWindow
        let accessibility: PermissionRowView
        let screen: PermissionRowView
    }

    private func makeRow(_ title: String, _ detail: String, tag: Int) -> PermissionRowView {
        PermissionRowView(title: title, detail: detail, symbolName: "accessibility", tag: tag, target: nil,
                          actionSelector: nil, checkAgainSelector: nil, checkAgainTitle: WizardCopy.checkAgain)
    }

    private func build(granted: Bool) -> Built {
        let window = WizardWindowFactory.makeWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 620))
        let content = window.contentView!
        let a = makeRow("Accessibility", WizardCopy.accessibilityDetail, tag: 0)
        let s = makeRow("Screen Recording", WizardCopy.screenRecordingDetail, tag: 1)
        let stack = NSStackView(views: [a, s])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
        ])
        for row in [a, s] {
            if granted {
                row.update(detail: row === a ? WizardCopy.accessibilityDetail : WizardCopy.screenRecordingDetail,
                           status: "✓ Allowed", statusColor: .systemGreen, showCheckAgain: false,
                           buttonTitle: "Allowed", buttonVisible: false, buttonEnabled: false, wideButton: false)
            } else {
                row.update(detail: row === a ? WizardCopy.accessibilityDetail : WizardCopy.screenRecordingDetail,
                           status: row === a ? stillOff : "Not allowed", statusColor: .systemRed,
                           showCheckAgain: row === a, buttonTitle: row === a ? "Open Settings" : "Allow",
                           buttonVisible: true, buttonEnabled: true, wideButton: false)
            }
        }
        content.layoutSubtreeIfNeeded()
        return Built(window: window, accessibility: a, screen: s)
    }

    private func frame(_ view: NSView, in row: NSView) -> NSRect { row.convert(view.bounds, from: view) }

    private func assertAligned(_ b: Built, file: StaticString = #filePath, line: UInt = #line) {
        let a = b.accessibility, s = b.screen
        XCTAssertEqual(frame(a.statusLabel, in: a).minX, frame(s.statusLabel, in: s).minX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(a.statusLabel.frame.width, s.statusLabel.frame.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(frame(a.actionButton, in: a).minX, frame(s.actionButton, in: s).minX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(a.actionButton.frame.width, s.actionButton.frame.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(a.statusLabel.alignmentRect(forFrame: a.statusLabel.frame).width, PermissionRowView.trailingWidth, accuracy: 0.5, file: file, line: line)
    }

    func testTrailingColumnAlignedWhenGranted() {
        assertAligned(build(granted: true))
    }

    func testTrailingColumnAlignedWhenNotGranted() {
        assertAligned(build(granted: false))
    }

    func testRowsHaveSameHeightWhenGranted() {
        let b = build(granted: true)
        XCTAssertEqual(b.accessibility.frame.height, b.screen.frame.height, accuracy: 0.5)
        XCTAssertEqual(b.accessibility.frame.height, PermissionRowView.minHeight, accuracy: 0.5)
    }

    func testTextIsVerticallyCenteredWithoutReservedLine() {
        let b = build(granted: true)
        for row in [b.accessibility, b.screen] {
            // AppKit y grows upward: the title is the top line and the detail the bottom line.
            let below = frame(row.detailLabel, in: row).minY
            let above = row.bounds.height - frame(row.titleLabel, in: row).maxY
            XCTAssertEqual(below, above, accuracy: 3)
        }
    }

    func testNoSubviewClippedWhenNotGranted() {
        let b = build(granted: false)
        XCTAssertGreaterThan(b.accessibility.frame.height, PermissionRowView.minHeight - 0.5)
        for row in [b.accessibility, b.screen] {
            var stack: [NSView] = row.subviews
            while let view = stack.popLast() {
                stack.append(contentsOf: view.subviews)
                if view.isHidden { continue }
                let f = frame(view, in: row)
                XCTAssertTrue(row.bounds.insetBy(dx: -0.5, dy: -0.5).contains(f), "\(type(of: view)) \(f) outside \(row.bounds)")
            }
        }
        // The whole message fits: its height holds every line.
        let label = b.accessibility.statusLabel
        let needed = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: PermissionRowView.trailingWidth, height: 10_000)).height
        XCTAssertGreaterThanOrEqual(label.frame.height + 0.5, needed)
        XCTAssertEqual(label.maximumNumberOfLines, 0)
    }

    func testNoVisibleAllowedButtonWhenGranted() {
        let b = build(granted: true)
        for row in [b.accessibility, b.screen] {
            XCTAssertTrue(row.actionButton.isHidden)
            XCTAssertEqual(row.statusLabel.stringValue, "✓ Allowed")
        }
    }

    func testWindowIsAqua() {
        let b = build(granted: true)
        XCTAssertEqual(b.window.appearance?.name, .aqua)
        XCTAssertEqual(b.window.effectiveAppearance.name, .aqua)
        XCTAssertEqual(b.window.contentView?.effectiveAppearance.name, .aqua)
    }
}
