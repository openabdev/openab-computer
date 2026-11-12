import AppKit
import ApplicationServices
import CoreGraphics
import InstanceMCPCore

/// Permission setup wizard, two pages. Page 1 needs Screen Recording and Accessibility, and Continue stays
/// disabled until both are granted. Page 2 is optional Full Disk Access with a Skip link.
///
/// Allow calls the system request API for that permission, re-tests, and opens the matching System Settings
/// pane when the permission is still not granted. The window never captures a screenshot and never polls on
/// its own. It re-tests on app activation, on Check Again, and on the menu bar's revocation watch.
@MainActor
final class PermissionSetupWindowController: NSWindowController {
    private final class RowControls {
        let box: NSBox
        let status: NSTextField
        let button: NSButton
        let checkAgain: NSButton

        init(box: NSBox, status: NSTextField, button: NSButton, checkAgain: NSButton) {
            self.box = box
            self.status = status
            self.button = button
            self.checkAgain = checkAgain
        }
    }

    private let store: SetupWizardStore
    private let adHoc: Bool
    private let corePage = NSStackView()
    private let optionalPage = NSStackView()
    private let revocationLabel = NSTextField(wrappingLabelWithString: "")
    private let adHocCoreLabel = NSTextField(wrappingLabelWithString: WizardCopy.adHocBanner)
    private let adHocOptionalLabel = NSTextField(wrappingLabelWithString: WizardCopy.adHocBanner)
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let optionalFooterButton = NSButton(title: "Skip", target: nil, action: nil)
    private var rows: [PermissionKind: RowControls] = [:]
    private var rowStates: [PermissionKind: RowState] = [:]
    /// Kinds whose Allow was clicked in this session.
    private var requested: Set<PermissionKind> = []
    /// Kinds whose app was returned to after Allow.
    private var returned: Set<PermissionKind> = []
    private var page: WizardPage = .core
    private var activationObserver: NSObjectProtocol?
    private(set) var snapshot = PermissionSnapshot(screenRecording: .denied, accessibility: .denied,
                                                  fullDiskAccess: .unknown)

    init(store: SetupWizardStore) {
        self.store = store
        self.adHoc = WizardModel.adHocBannerVisible(teamIdentifier: SigningIdentity.teamIdentifier())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up Mac Permissions"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI(in: window)
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.markReturned()
                self?.refresh()
            }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    var isWindowVisible: Bool { window?.isVisible ?? false }

    /// Opens on the core page while a core permission is missing, and on the optional page otherwise.
    func show() {
        page = SetupGate.evaluate(snapshot: PermissionProbe.current()).blocksCore ? .core : .optional
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        refresh(with: PermissionProbe.current())
    }

    private func refresh(with current: PermissionSnapshot) {
        snapshot = current

        // Read the stored flag before this refresh updates it, so a grant made now is not shown as a revocation.
        let previouslySeen = store.coreGrantedSeen
        setLabel(revocationLabel, WizardModel.revocationBanner(previouslySeen: previouslySeen, snapshot: current))
        let seen = CoreWatch.seenAfter(previouslySeen: previouslySeen, current: current)
        if seen != previouslySeen { store.coreGrantedSeen = seen }
        if current.allGranted, WizardModel.recordsCompletion(.completeObserved) {
            store.hasShown = true
        }

        // A missing core permission always returns the window to page 1.
        if SetupGate.evaluate(snapshot: current).blocksCore { page = .core }

        for kind in PermissionKind.allCases { applyRow(kind, state: current[kind]) }
        applyFooters(current)

        corePage.isHidden = page != .core
        optionalPage.isHidden = page != .optional
    }

    private func applyRow(_ kind: PermissionKind, state: PermissionState) {
        guard let controls = rows[kind] else { return }
        let row = WizardModel.rowState(state: state, requested: requested.contains(kind),
                                       returnedSinceRequest: returned.contains(kind))
        rowStates[kind] = row
        controls.status.stringValue = row.statusText
        controls.status.textColor = row.statusColor
        controls.checkAgain.isHidden = !(row == .waiting || row == .stillOff)

        switch WizardModel.rowButton(for: row) {
        case .allow:
            controls.button.title = "Allow"
            controls.button.isEnabled = true
        case .openSettings:
            controls.button.title = "Open Settings"
            controls.button.isEnabled = true
        case .restart:
            // TODO(Q3): unreachable until needsRestart is produced. Exit lets KeepAlive restart the agent.
            controls.button.title = "Restart"
            controls.button.isEnabled = true
        case .allowed:
            controls.button.title = "Allowed"
            controls.button.isEnabled = false
        }
    }

    private func applyFooters(_ current: PermissionSnapshot) {
        if case let .continueToOptional(enabled) = WizardModel.footerAction(page: .core, snapshot: current) {
            continueButton.isEnabled = enabled
        }
        switch WizardModel.footerAction(page: .optional, snapshot: current) {
        case .done: optionalFooterButton.title = "Done"
        case .skip, .continueToOptional: optionalFooterButton.title = "Skip"
        }
    }

    private func markReturned() {
        returned.formUnion(requested)
    }

    private func setLabel(_ label: NSTextField, _ text: String?) {
        label.stringValue = text ?? ""
        label.isHidden = text == nil
    }

    // MARK: actions

    /// Allow: request, re-test, and open the pane only when the permission is still not granted.
    private func allow(_ kind: PermissionKind) {
        switch kind {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .fullDiskAccess:
            break // macOS has no request API for Full Disk Access; the pane is the only path.
        }
        requested.insert(kind)
        returned.remove(kind)
        let current = PermissionProbe.current()
        refresh(with: current)
        if current[kind] != .granted {
            NSWorkspace.shared.open(kind.settingsURL)
        }
    }

    private func finish(_ event: WizardEvent) {
        if WizardModel.recordsCompletion(event) {
            store.hasShown = true
        }
        window?.close()
    }

    @objc private func rowButtonTapped(_ sender: NSButton) {
        guard let kind = kind(for: sender) else { return }
        switch rowStates[kind].map(WizardModel.rowButton(for:)) {
        case .openSettings?:
            NSWorkspace.shared.open(kind.settingsURL)
        case .restart?:
            exit(0) // TODO(Q3): KeepAlive restarts the agent. Confirm that restarting clears a stale denial on macOS 15 and 26.
        case .allowed?:
            break
        case .allow?, nil:
            allow(kind)
        }
    }

    @objc private func checkAgainTapped(_ sender: NSButton) {
        markReturned()
        refresh()
    }

    @objc private func continueTapped() {
        guard WizardModel.footerAction(page: .core, snapshot: snapshot) == .continueToOptional(enabled: true) else { return }
        page = .optional
        refresh()
    }

    @objc private func optionalFooterTapped() {
        if case .done = WizardModel.footerAction(page: .optional, snapshot: snapshot) {
            finish(.done)
        } else {
            finish(.skip)
        }
    }

    private func kind(for control: NSButton) -> PermissionKind? {
        PermissionKind.allCases.indices.contains(control.tag) ? PermissionKind.allCases[control.tag] : nil
    }

    // MARK: UI

    private func buildUI(in window: NSWindow) {
        guard let content = window.contentView else { return }
        for pageStack in [corePage, optionalPage] {
            pageStack.orientation = .vertical
            pageStack.alignment = .leading
            pageStack.spacing = 14
            pageStack.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(pageStack)
            NSLayoutConstraint.activate([
                pageStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
                pageStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
                pageStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                pageStack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -22),
            ])
        }

        // Page 1: core permissions.
        revocationLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        revocationLabel.textColor = .systemRed
        revocationLabel.maximumNumberOfLines = 0
        adHocCoreLabel.font = .systemFont(ofSize: 12)
        adHocCoreLabel.textColor = .systemOrange
        adHocCoreLabel.maximumNumberOfLines = 0
        adHocCoreLabel.isHidden = !adHoc
        corePage.addArrangedSubview(revocationLabel)
        corePage.addArrangedSubview(adHocCoreLabel)
        corePage.addArrangedSubview(headline(WizardCopy.corePageTitle, subtitle: WizardCopy.corePageSubtitle))
        corePage.addArrangedSubview(row(for: .screenRecording))
        corePage.addArrangedSubview(row(for: .accessibility))
        corePage.addArrangedSubview(note(WizardCopy.corePageNote))

        continueButton.target = self
        continueButton.action = #selector(continueTapped)
        continueButton.keyEquivalent = "\r"
        corePage.addArrangedSubview(footer(buttons: [continueButton], pager: "●  ○"))

        // Page 2: optional Full Disk Access.
        adHocOptionalLabel.font = .systemFont(ofSize: 12)
        adHocOptionalLabel.textColor = .systemOrange
        adHocOptionalLabel.maximumNumberOfLines = 0
        adHocOptionalLabel.isHidden = !adHoc
        optionalPage.addArrangedSubview(adHocOptionalLabel)
        optionalPage.addArrangedSubview(headline(WizardCopy.optionalPageTitle, subtitle: WizardCopy.optionalPageSubtitle))
        optionalPage.addArrangedSubview(row(for: .fullDiskAccess))
        optionalPage.addArrangedSubview(note(WizardCopy.optionalPageNote))

        optionalFooterButton.target = self
        optionalFooterButton.action = #selector(optionalFooterTapped)
        optionalPage.addArrangedSubview(footer(buttons: [optionalFooterButton], pager: "○  ●"))

        optionalPage.isHidden = true
    }

    private func headline(_ title: String, subtitle: String) -> NSStackView {
        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.maximumNumberOfLines = 0
        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 0
        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        return label
    }

    private func footer(buttons: [NSButton], pager: String) -> NSStackView {
        let pagerLabel = NSTextField(labelWithString: pager)
        pagerLabel.font = .systemFont(ofSize: 11)
        pagerLabel.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [pagerLabel, spacer] + buttons)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 594).isActive = true
        return stack
    }

    private func row(for kind: PermissionKind) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = NSSize(width: 14, height: 10)
        box.translatesAutoresizingMaskIntoConstraints = false
        // NSBox does not derive an intrinsic height from an assigned contentView; without these an NSStackView
        // collapses all rows onto one line.
        box.widthAnchor.constraint(equalToConstant: 594).isActive = true
        box.heightAnchor.constraint(equalToConstant: 84).isActive = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: kind.rowTitle)
        icon.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 30).isActive = true

        let title = NSTextField(labelWithString: kind.rowTitle)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: kind.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 0
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let status = NSTextField(wrappingLabelWithString: "")
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.maximumNumberOfLines = 2
        status.alignment = .right
        status.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let checkAgain = NSButton(title: WizardCopy.checkAgain, target: self, action: #selector(checkAgainTapped(_:)))
        checkAgain.isBordered = false
        checkAgain.font = .systemFont(ofSize: 11)
        checkAgain.isHidden = true
        checkAgain.tag = PermissionKind.allCases.firstIndex(of: kind) ?? 0

        let button = NSButton(title: "Allow", target: self, action: #selector(rowButtonTapped(_:)))
        button.tag = PermissionKind.allCases.firstIndex(of: kind) ?? 0
        button.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let content = NSStackView(views: [icon, labels, status, checkAgain, button])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalToConstant: 566).isActive = true
        box.contentView = content

        rows[kind] = RowControls(box: box, status: status, button: button, checkAgain: checkAgain)
        return box
    }
}

private extension PermissionKind {
    var rowTitle: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .fullDiskAccess: return "Full Disk Access"
        }
    }

    var detail: String {
        switch self {
        case .screenRecording: return WizardCopy.screenRecordingDetail
        case .accessibility: return WizardCopy.accessibilityDetail
        case .fullDiskAccess: return WizardCopy.fullDiskAccessDetail
        }
    }

    var symbolName: String {
        switch self {
        case .screenRecording: return "rectangle.inset.filled.and.person.filled"
        case .accessibility: return "accessibility"
        case .fullDiskAccess: return "internaldrive"
        }
    }
}

private extension RowState {
    var statusText: String {
        switch self {
        case .notAllowed: return "Not allowed"
        case .waiting: return "Waiting for System Settings"
        case .stillOff: return "Still off. Turn it on in System Settings, then come back."
        case .needsRestart: return "Turned on. Restart OpenAB Computer to finish."
        case .allowed: return "✓ Allowed"
        case .cantTest: return "Can't test. Check System Settings."
        }
    }

    var statusColor: NSColor {
        switch self {
        case .notAllowed, .stillOff: return .systemRed
        case .waiting: return .secondaryLabelColor
        case .needsRestart, .cantTest: return .systemOrange
        case .allowed: return .systemGreen
        }
    }
}
