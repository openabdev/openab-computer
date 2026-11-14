import AppKit
import ApplicationServices
import CoreGraphics
import InstanceMCPCore

/// Permission setup wizard, two pages, or three when a Tailscale login was detected. Page 1 needs Screen Recording
/// and Accessibility, and Continue stays disabled until both are granted. Page 2 is optional Full Disk Access with a
/// Skip link. Page 3 is the opt-in "allow other devices on my tailnet" step (off unless the user turns it on).
///
/// Allow calls the system request API for that permission, re-tests, and opens the matching System Settings
/// pane when the permission is still not granted. The window never captures a screenshot. It re-tests on app
/// activation and on Check Again. While it is open, the menu bar's 30-second revocation watch also pushes the two
/// core results to it (`refreshCore`).
///
/// Screen Recording needs a restart on macOS before a running process sees the grant (design Q3). After Allow, and
/// while Screen Recording is not granted, the window asks a short-lived child process of this same executable
/// (`ChildPermissionCheck`, schedule in `ChildCheckSchedule`) whether it is granted. A fresh process reads the live
/// answer. When the child says granted, the row shows its check mark at once, with no relaunch, so the flow works
/// even if the user chose Later in the macOS "Quit & Reopen" dialog. The restart waits for Finish: if this process
/// still reports off then, the window closes and the app relaunches once, silently, so the backend starts after the
/// grant. If the child cannot answer, or the user presses Check Again and it still says off, the row offers a
/// Restart button that relaunches and reopens the wizard on the same page (`RelaunchCoordinator`).
@MainActor
final class PermissionSetupWindowController: NSWindowController {
    private let store: SetupWizardStore
    private let relaunch: RelaunchCoordinator
    private let adHoc: Bool
    /// Nil when there is no Tailscale login to rely on (no detected login, no allow list); the tailnet page is then never shown.
    private let exposure: TailnetExposure?
    private let tailnetPage = NSStackView()
    private let tailnetFooterButton = NSButton(title: "Skip", target: nil, action: nil)
    private var tailnetRow: PermissionRowView?
    private let tailnetNoticeLabel = NSTextField(wrappingLabelWithString: "")
    private var pagerLabels: [WizardPage: NSTextField] = [:]
    private var tailnetBusy = false
    /// The last failure or conflict message from turning access on or off. Cleared by the next attempt.
    private var tailnetMessage: String?
    private let corePage = NSStackView()
    private let optionalPage = NSStackView()
    private let revocationLabel = NSTextField(wrappingLabelWithString: "")
    private let adHocCoreLabel = NSTextField(wrappingLabelWithString: WizardCopy.adHocBanner)
    private let adHocOptionalLabel = NSTextField(wrappingLabelWithString: WizardCopy.adHocBanner)
    private let coreNoticeLabel = NSTextField(wrappingLabelWithString: "")
    private let optionalNoticeLabel = NSTextField(wrappingLabelWithString: "")
    /// Set when macOS refused a Settings deep link. Shows the manual path until the next successful open or return.
    private var paneNotice: String?
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let optionalFooterButton = NSButton(title: "Skip", target: nil, action: nil)
    private var rows: [PermissionKind: PermissionRowView] = [:]
    private var rowStates: [PermissionKind: RowState] = [:]
    /// Kinds whose Allow was clicked in this session.
    private var requested: Set<PermissionKind> = []
    /// Kinds whose app was returned to after Allow.
    private var returned: Set<PermissionKind> = []
    private var page: WizardPage = .core
    private var activationObserver: NSObjectProtocol?
    private var childCheckTimer: Timer?
    private var childCheckStartedAt: Date?
    private var lastChildCheckAt: Date?
    private var childCheckInFlight = false
    /// Shared with the menu bar item, so both read the same child result for Screen Recording.
    private let probeCache = ScreenRecordingProbeCache.shared
    /// The one child result both surfaces use: the shared cache (this window records its own checks into it).
    private var childForStatus: ChildCheckResult? { probeCache.latest }
    /// The user pressed Check Again for Screen Recording, which says the switch is on.
    private var userConfirmedScreenRecording = false
    /// What this process itself reports, before the child result is applied.
    private var rawSnapshot = PermissionSnapshot(screenRecording: .denied, accessibility: .denied, fullDiskAccess: .unknown)
    /// What the window shows: `rawSnapshot` with Screen Recording granted when the child check says so.
    private(set) var snapshot = PermissionSnapshot(screenRecording: .denied, accessibility: .denied,
                                                  fullDiskAccess: .unknown)

    init(store: SetupWizardStore, relaunch: RelaunchCoordinator, exposure: TailnetExposure? = nil) {
        self.store = store
        self.relaunch = relaunch
        self.exposure = exposure
        let signing = SigningIdentity.lookup()
        if case let .failed(status) = signing {
            log("permission setup: could not read the code signature (OSStatus \(status)); ad-hoc banner hidden")
        }
        self.adHoc = WizardModel.adHocBannerVisible(signing: signing)
        let window = WizardWindowFactory.makeWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 620))
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
                self?.runChildCheckIfNeeded()
            }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        childCheckTimer?.invalidate()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    var isWindowVisible: Bool { window?.isVisible ?? false }

    private var tailnetOffered: Bool { exposure?.offersExposure ?? false }

    /// Opens on the core page while a core permission is missing, and on the optional page otherwise. After a
    /// relaunch, `resume` is the page the previous instance was on.
    func show(resume: WizardPage? = nil) {
        let shown = SharedPermissionStatus.resolve(process: PermissionProbe.current(), child: childForStatus).shown
        page = WizardModel.available(resume ?? (SetupGate.evaluate(snapshot: shown).blocksCore ? .core : .optional),
                                     tailnetOffered: tailnetOffered)
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        // The window is visible only now; a close earlier invalidated the timer, so start it again.
        updateChildCheckTimer()
    }

    func refresh() {
        refresh(with: PermissionProbe.current())
    }

    /// Called by the menu bar's revocation watch while the window is open. Takes only the two core results and keeps
    /// the last Full Disk Access value, so the watch never probes Full Disk Access.
    func refreshCore(_ core: PermissionSnapshot) {
        refresh(with: CoreWatch.merged(core, into: rawSnapshot))
    }

    private func refresh(with raw: PermissionSnapshot) {
        rawSnapshot = raw
        let current = SharedPermissionStatus.resolve(process: raw, child: childForStatus).shown
        snapshot = current
        // A process that sees Screen Recording granted has consumed the grant: a later revoke may relaunch once more.
        if raw.screenRecording.isGranted, store.autoRelaunchSpent { store.autoRelaunchSpent = false }

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
        page = WizardModel.available(page, tailnetOffered: tailnetOffered)

        for kind in PermissionKind.allCases { applyRow(kind, state: current[kind]) }
        applyFooters(current)
        applyTailnetRow()
        setLabel(coreNoticeLabel, paneNotice)
        setLabel(optionalNoticeLabel, paneNotice)

        corePage.isHidden = page != .core
        optionalPage.isHidden = page != .optional
        tailnetPage.isHidden = page != .tailnet
        updatePagers()
        updateChildCheckTimer()
        // A stale process may be waiting on the shared probe (for example right after a relaunch): ask for a fresh
        // one off the main thread, and redraw when it answers.
        if !raw.screenRecording.isGranted {
            probeCache.refreshIfStale { [weak self] value in
                guard value != nil else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
            }
        }
    }

    // MARK: Screen Recording child check

    private var relaunchAction: RelaunchAction {
        RelaunchPolicy.decide(child: childForStatus, processGranted: rawSnapshot.screenRecording.isGranted,
                              userConfirmedEnabled: userConfirmedScreenRecording,
                              autoRelaunchSpent: store.autoRelaunchSpent)
    }

    private var needsChildCheck: Bool {
        ChildCheckSchedule.shouldRun(
            requested: requested.contains(.screenRecording),
            granted: snapshot.screenRecording.isGranted,
            windowVisible: isWindowVisible)
    }

    private func updateChildCheckTimer() {
        if needsChildCheck {
            if childCheckTimer == nil {
                if childCheckStartedAt == nil { childCheckStartedAt = Date() }
                let timer = Timer(timeInterval: ChildCheckSchedule.fastInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.childCheckTick() }
                }
                RunLoop.main.add(timer, forMode: .common)
                childCheckTimer = timer
            }
        } else {
            childCheckTimer?.invalidate()
            childCheckTimer = nil
            if rawSnapshot.screenRecording.isGranted || !isWindowVisible { childCheckStartedAt = nil }
        }
    }

    private func childCheckTick() {
        guard needsChildCheck, let started = childCheckStartedAt else { updateChildCheckTimer(); return }
        guard let interval = ChildCheckSchedule.interval(elapsed: Date().timeIntervalSince(started)) else { return }
        if let last = lastChildCheckAt, Date().timeIntervalSince(last) < interval - 0.01 { return }
        runChildCheckIfNeeded()
    }

    /// Runs the child off the main thread. One check at a time. It never prompts or captures.
    private func runChildCheckIfNeeded() {
        guard needsChildCheck, !childCheckInFlight else { return }
        childCheckInFlight = true
        lastChildCheckAt = Date()
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = ChildPermissionCheck.run(executable: executable)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.childCheckFinished(result) }
            }
        }
    }

    private func childCheckFinished(_ result: ChildCheckResult) {
        childCheckInFlight = false
        // A confirmed grant is not undone by one check that could not answer.
        probeCache.record(result)
        refresh()
    }

    /// Opens one System Settings pane. When macOS refuses the URL, the window shows the manual path and logs it.
    private func openPane(_ kind: PermissionKind) {
        if NSWorkspace.shared.open(kind.settingsURL) {
            paneNotice = nil
        } else {
            paneNotice = WizardCopy.manualPaneNotice(pane: kind.rowTitle)
            log("permission setup: could not open \(kind.settingsURL.absoluteString)")
        }
        setLabel(coreNoticeLabel, paneNotice)
        setLabel(optionalNoticeLabel, paneNotice)
    }

    private func applyRow(_ kind: PermissionKind, state: PermissionState) {
        guard let rowView = rows[kind] else { return }
        var row = WizardModel.rowState(state: state, requested: requested.contains(kind),
                                       returnedSinceRequest: returned.contains(kind))
        if kind == .screenRecording { row = RelaunchPolicy.effectiveRow(base: row, action: relaunchAction) }
        rowStates[kind] = row
        let restart = row == .needsRestart
        let title: String
        switch WizardModel.rowButton(for: row) {
        case .allow: title = "Allow"
        case .openSettings: title = "Open Settings"
        case .restart: title = WizardCopy.restartButton
        case .allowed: title = "Allowed"
        }
        // Granted rows show only the green "✓ Allowed" label; the disabled button is hidden.
        rowView.update(detail: restart ? WizardCopy.restartExplanation : kind.detail,
                       status: row.statusText, statusColor: row.statusColor,
                       showCheckAgain: row == .waiting || row == .stillOff,
                       buttonTitle: title, buttonVisible: row != .allowed, buttonEnabled: row != .allowed,
                       wideButton: restart)
    }

    private func applyFooters(_ current: PermissionSnapshot) {
        if case let .continueToOptional(enabled) = WizardModel.footerAction(page: .core, snapshot: current) {
            continueButton.isEnabled = enabled
        }
        switch WizardModel.footerAction(page: .optional, snapshot: current, tailnetPage: tailnetOffered) {
        case .done: optionalFooterButton.title = "Done"
        case .continueToTailnet: optionalFooterButton.title = "Continue"
        case .skip, .skipToTailnet, .continueToOptional: optionalFooterButton.title = "Skip"
        }
        tailnetFooterButton.title = tailnetOn ? "Done" : "Skip"
        // While enable() runs, Skip would close the wizard as skipped and the mapping could still appear afterwards.
        tailnetFooterButton.isEnabled = !tailnetBusy
    }

    private var tailnetOn: Bool { exposure?.publicURL != nil }

    private func updatePagers() {
        let pages = WizardModel.pages(tailnetOffered: tailnetOffered)
        for (kind, label) in pagerLabels {
            label.stringValue = pages.map { $0 == kind ? "●" : "○" }.joined(separator: "  ")
        }
    }

    private func applyTailnetRow() {
        guard let row = tailnetRow else { return }
        let url = exposure?.publicURL
        let name = url.flatMap { URL(string: $0)?.host }
        let status: String
        let color: NSColor
        if tailnetBusy {
            status = "Working…"; color = .secondaryLabelColor
        } else if let message = tailnetMessage {
            status = message; color = .systemRed
        } else if url != nil {
            status = "✓ On"; color = .systemGreen
        } else {
            status = "Off"; color = .secondaryLabelColor
        }
        row.update(detail: WizardCopy.tailnetDetail(name: name), status: status, statusColor: color,
                   showCheckAgain: false, buttonTitle: url != nil ? "Turn Off" : "Allow",
                   buttonVisible: true, buttonEnabled: !tailnetBusy, wideButton: false)
        setLabel(tailnetNoticeLabel, nil)
    }

    /// Allow or Turn Off. The CLI runs off the main thread; the row shows "Working…" meanwhile.
    @objc private func tailnetTapped() {
        guard let exposure, !tailnetBusy else { return }
        let turningOff = exposure.publicURL != nil
        tailnetBusy = true
        tailnetMessage = nil
        applyTailnetRow()
        applyFooters(snapshot)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = turningOff ? exposure.disable() : exposure.enable()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.tailnetBusy = false
                    self.applyFooters(self.snapshot)
                    switch outcome {
                    case .on, .off: self.tailnetMessage = nil
                    default: self.tailnetMessage = outcome.message
                    }
                    self.refresh()
                }
            }
        }
    }

    @objc private func tailnetFooterTapped() {
        guard !tailnetBusy else { return }
        finish(tailnetOn ? .done : .skip)
    }

    private func markReturned() {
        returned.formUnion(requested)
        paneNotice = nil
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
        if kind == .screenRecording {
            // A new round of checks: the schedule restarts and the old child result no longer applies.
            childCheckStartedAt = nil
            lastChildCheckAt = nil
            probeCache.invalidate()
            userConfirmedScreenRecording = false
        }
        let current = PermissionProbe.current()
        refresh(with: current)
        if current[kind] != .granted {
            openPane(kind)
        }
        if kind == .screenRecording { runChildCheckIfNeeded() }
    }

    /// Skip or Done. The restart that Screen Recording needs happens here, not when the grant is detected: the window
    /// closes, then the app relaunches once without reopening the wizard. A process that already reports Screen
    /// Recording granted skips it.
    private func finish(_ event: WizardEvent) {
        if WizardModel.recordsCompletion(event) {
            store.hasShown = true
        }
        let relaunchNow = RelaunchPolicy.shouldRelaunchOnFinish(
            child: childForStatus, processGranted: rawSnapshot.screenRecording.isGranted)
        window?.close()
        if relaunchNow, !relaunch.requestRelaunch(page: nil, automatic: true) {
            log("permission setup: relaunch after Finish not started")
        }
    }

    @objc private func rowButtonTapped(_ sender: NSButton) {
        guard let kind = kind(for: sender) else { return }
        switch rowStates[kind].map(WizardModel.rowButton(for:)) {
        case .openSettings?:
            openPane(kind)
        case .restart?:
            if relaunch.requestRelaunch(page: page, automatic: false) { return }
            paneNotice = WizardCopy.restartFailed
            refresh()
        case .allowed?:
            break
        case .allow?, nil:
            allow(kind)
        }
    }

    @objc private func checkAgainTapped(_ sender: NSButton) {
        if kind(for: sender) == .screenRecording { userConfirmedScreenRecording = true }
        markReturned()
        refresh()
        runChildCheckIfNeeded()
    }

    @objc private func continueTapped() {
        guard WizardModel.footerAction(page: .core, snapshot: snapshot) == .continueToOptional(enabled: true) else { return }
        page = .optional
        refresh()
    }

    @objc private func optionalFooterTapped() {
        switch WizardModel.footerAction(page: .optional, snapshot: snapshot, tailnetPage: tailnetOffered) {
        case .continueToTailnet, .skipToTailnet:
            page = .tailnet
            refresh()
        case .done: finish(.done)
        default: finish(.skip)
        }
    }

    private func kind(for control: NSButton) -> PermissionKind? {
        PermissionKind.allCases.indices.contains(control.tag) ? PermissionKind.allCases[control.tag] : nil
    }

    // MARK: UI

    private func buildUI(in window: NSWindow) {
        guard let content = window.contentView else { return }
        for pageStack in [corePage, optionalPage, tailnetPage] {
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
        for kind in WizardModel.coreOrder { corePage.addArrangedSubview(row(for: kind)) }
        configureNotice(coreNoticeLabel)
        corePage.addArrangedSubview(coreNoticeLabel)
        corePage.addArrangedSubview(note(WizardCopy.corePageNote))

        continueButton.target = self
        continueButton.action = #selector(continueTapped)
        continueButton.keyEquivalent = "\r"
        corePage.addArrangedSubview(footer(buttons: [continueButton], pager: "●  ○", page: .core))

        // Page 2: optional Full Disk Access.
        adHocOptionalLabel.font = .systemFont(ofSize: 12)
        adHocOptionalLabel.textColor = .systemOrange
        adHocOptionalLabel.maximumNumberOfLines = 0
        adHocOptionalLabel.isHidden = !adHoc
        optionalPage.addArrangedSubview(adHocOptionalLabel)
        optionalPage.addArrangedSubview(headline(WizardCopy.optionalPageTitle, subtitle: WizardCopy.optionalPageSubtitle))
        optionalPage.addArrangedSubview(row(for: .fullDiskAccess))
        configureNotice(optionalNoticeLabel)
        optionalPage.addArrangedSubview(optionalNoticeLabel)
        optionalPage.addArrangedSubview(note(WizardCopy.optionalPageNote))

        optionalFooterButton.target = self
        optionalFooterButton.action = #selector(optionalFooterTapped)
        optionalPage.addArrangedSubview(footer(buttons: [optionalFooterButton], pager: "○  ●", page: .optional))

        // Page 3: opt-in tailnet access. Built always, shown only when a login was detected.
        tailnetPage.addArrangedSubview(headline(WizardCopy.tailnetPageTitle, subtitle: WizardCopy.tailnetPageSubtitle))
        let tailnet = PermissionRowView(title: WizardCopy.tailnetRowTitle, detail: WizardCopy.tailnetDetail(name: nil),
                                        symbolName: "network", tag: PermissionKind.allCases.count,
                                        target: self, actionSelector: #selector(tailnetTapped),
                                        checkAgainSelector: nil, checkAgainTitle: WizardCopy.checkAgain)
        tailnetRow = tailnet
        tailnetPage.addArrangedSubview(tailnet)
        configureNotice(tailnetNoticeLabel)
        tailnetPage.addArrangedSubview(tailnetNoticeLabel)
        tailnetPage.addArrangedSubview(note(WizardCopy.tailnetPageNote))
        tailnetFooterButton.target = self
        tailnetFooterButton.action = #selector(tailnetFooterTapped)
        tailnetPage.addArrangedSubview(footer(buttons: [tailnetFooterButton], pager: "○  ○  ●", page: .tailnet))

        optionalPage.isHidden = true
        tailnetPage.isHidden = true
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

    private func configureNotice(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .systemOrange
        label.maximumNumberOfLines = 0
        label.isHidden = true
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        return label
    }

    private func footer(buttons: [NSButton], pager: String, page: WizardPage) -> NSStackView {
        let pagerLabel = NSTextField(labelWithString: pager)
        pagerLabels[page] = pagerLabel
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
        let tag = PermissionKind.allCases.firstIndex(of: kind) ?? 0
        let view = PermissionRowView(title: kind.rowTitle, detail: kind.detail, symbolName: kind.symbolName, tag: tag,
                                     target: self, actionSelector: #selector(rowButtonTapped(_:)),
                                     checkAgainSelector: #selector(checkAgainTapped(_:)),
                                     checkAgainTitle: WizardCopy.checkAgain)
        rows[kind] = view
        return view
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
        case .needsRestart: return "Restart to finish."
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
