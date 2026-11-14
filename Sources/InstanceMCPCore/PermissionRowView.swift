import AppKit

/// One permission row of the setup wizard. Every row has the same width, the same minimum height and the same
/// fixed-width trailing column (status text above the action buttons), so rows line up whatever their state.
/// A row grows taller when its text needs more lines; it never clips.
@MainActor
public final class PermissionRowView: NSView {
    public static let width: CGFloat = 594
    public static let minHeight: CGFloat = 84
    public static let margin: CGFloat = 14
    public static let verticalPadding: CGFloat = 12
    public static let iconWidth: CGFloat = 30
    public static let gap: CGFloat = 12
    public static let trailingWidth: CGFloat = 240
    public static let buttonWidth: CGFloat = 140
    public static let wideButtonWidth: CGFloat = 240
    /// Width of the title and detail block, between the icon and the trailing column.
    public static let textWidth: CGFloat = width - 2 * margin - iconWidth - 2 * gap - trailingWidth

    public let titleLabel: NSTextField
    public let detailLabel: NSTextField
    public let statusLabel: NSTextField
    public let checkAgainButton: NSButton
    public let actionButton: NSButton

    private let buttonWidthConstraint: NSLayoutConstraint
    private let bottomToButton: NSLayoutConstraint
    private let bottomToStatus: NSLayoutConstraint

    public init(title: String, detail: String, symbolName: String, tag: Int,
                target: AnyObject?, actionSelector: Selector?, checkAgainSelector: Selector?, checkAgainTitle: String) {
        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 0
        detailLabel.preferredMaxLayoutWidth = Self.textWidth

        statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.maximumNumberOfLines = 0
        statusLabel.alignment = .right
        statusLabel.preferredMaxLayoutWidth = Self.trailingWidth

        checkAgainButton = NSButton(title: checkAgainTitle, target: target, action: checkAgainSelector)
        checkAgainButton.isBordered = false
        checkAgainButton.font = .systemFont(ofSize: 11)
        checkAgainButton.isHidden = true
        checkAgainButton.tag = tag

        actionButton = NSButton(title: "Allow", target: target, action: actionSelector)
        actionButton.tag = tag

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        icon.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        let background = NSBox()
        background.boxType = .custom
        background.cornerRadius = 8
        background.borderColor = .separatorColor
        background.borderWidth = 1
        background.fillColor = .controlBackgroundColor

        let texts = NSStackView(views: [titleLabel, detailLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

        let column = NSView()
        column.addSubview(statusLabel)
        column.addSubview(checkAgainButton)
        column.addSubview(actionButton)

        buttonWidthConstraint = actionButton.widthAnchor.constraint(equalToConstant: Self.buttonWidth)
        bottomToButton = column.bottomAnchor.constraint(equalTo: actionButton.bottomAnchor)
        bottomToStatus = column.bottomAnchor.constraint(equalTo: statusLabel.bottomAnchor)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for view in [background, icon, texts, column, statusLabel, checkAgainButton, actionButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(background)
        addSubview(icon)
        addSubview(texts)
        addSubview(column)

        let pad = Self.verticalPadding
        let pullDown = heightAnchor.constraint(equalToConstant: Self.minHeight)
        pullDown.priority = .defaultLow
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minHeight),
            pullDown,

            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.margin),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconWidth),

            texts.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Self.gap),
            texts.widthAnchor.constraint(equalToConstant: Self.textWidth),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
            texts.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: pad),
            texts.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -pad),
            detailLabel.widthAnchor.constraint(equalToConstant: Self.textWidth),

            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.margin),
            column.widthAnchor.constraint(equalToConstant: Self.trailingWidth),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: pad),
            column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -pad),

            statusLabel.topAnchor.constraint(equalTo: column.topAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: column.trailingAnchor),

            actionButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            actionButton.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            buttonWidthConstraint,
            checkAgainButton.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor),
            checkAgainButton.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -8),
            bottomToButton,
        ])
        bottomToStatus.isActive = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Sets what the row shows. A hidden action button also stops reserving space in the trailing column, so the
    /// status text of a granted row sits at the vertical centre of the row.
    public func update(detail: String, status: String, statusColor: NSColor, showCheckAgain: Bool,
                       buttonTitle: String, buttonVisible: Bool, buttonEnabled: Bool, wideButton: Bool) {
        detailLabel.stringValue = detail
        statusLabel.stringValue = status
        statusLabel.textColor = statusColor
        checkAgainButton.isHidden = !(showCheckAgain && buttonVisible)
        actionButton.title = buttonTitle
        actionButton.isEnabled = buttonEnabled
        actionButton.isHidden = !buttonVisible
        buttonWidthConstraint.constant = wideButton ? Self.wideButtonWidth : Self.buttonWidth
        bottomToButton.isActive = buttonVisible
        bottomToStatus.isActive = !buttonVisible
        needsLayout = true
    }
}

/// The wizard window. It is forced to the light (aqua) appearance whatever the system setting; no other window or the
/// menu bar item is touched.
@MainActor
public enum WizardWindowFactory {
    public static func makeWindow(contentRect: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: contentRect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        return window
    }
}
