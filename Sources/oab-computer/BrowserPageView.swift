import AppKit
import InstanceMCPCore

/// The Browser tools page: one Playwright row (R5.8), a progress bar, and the footer buttons the
/// `BrowserPageModel` allows. It holds no state of its own; `render` redraws it from the model.
@MainActor
final class BrowserPageView: NSStackView {
    let externalNote = NSTextField(wrappingLabelWithString: WizardCopy.browserExternalProviderNote)
    let checkbox = NSButton(checkboxWithTitle: WizardCopy.browserRowTitle, target: nil, action: nil)
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let failure = NSTextField(wrappingLabelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    let signInButton = NSButton(title: WizardCopy.browserSignInButton, target: nil, action: nil)
    let continueButton = NSButton(title: WizardCopy.browserContinue, target: nil, action: nil)
    let cancelButton = NSButton(title: WizardCopy.browserCancel, target: nil, action: nil)
    let retryButton = NSButton(title: WizardCopy.browserRetry, target: nil, action: nil)
    let continueWithoutButton = NSButton(title: WizardCopy.browserContinueWithout, target: nil, action: nil)
    let pagerLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 14
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        let title = NSTextField(wrappingLabelWithString: WizardCopy.browserPageTitle)
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.maximumNumberOfLines = 0
        let subtitle = NSTextField(wrappingLabelWithString: WizardCopy.browserPageSubtitle)
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 0
        let head = NSStackView(views: [title, subtitle])
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = 6
        addArrangedSubview(head)

        checkbox.font = .systemFont(ofSize: 14, weight: .semibold)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 0
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.maximumNumberOfLines = 0
        failure.font = .systemFont(ofSize: 12, weight: .medium)
        failure.textColor = .systemRed
        failure.maximumNumberOfLines = 0
        progressLabel.font = .systemFont(ofSize: 11)
        progressLabel.textColor = .secondaryLabelColor
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 560).isActive = true

        externalNote.font = .systemFont(ofSize: 12, weight: .medium)
        externalNote.maximumNumberOfLines = 0
        externalNote.preferredMaxLayoutWidth = 594
        externalNote.isHidden = true
        addArrangedSubview(externalNote)

        let card = NSStackView(views: [checkbox, detail, status, bar, progressLabel, failure, signInButton])
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 8
        card.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 594).isActive = true
        detail.preferredMaxLayoutWidth = 560
        failure.preferredMaxLayoutWidth = 560
        status.preferredMaxLayoutWidth = 560
        addArrangedSubview(card)

        let note = NSTextField(wrappingLabelWithString: WizardCopy.browserPageNote)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 0
        addArrangedSubview(note)

        continueButton.keyEquivalent = "\r"
        pagerLabel.font = .systemFont(ofSize: 11)
        pagerLabel.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [pagerLabel, spacer, cancelButton, continueWithoutButton, retryButton, continueButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.widthAnchor.constraint(equalToConstant: 594).isActive = true
        addArrangedSubview(footer)
    }

    func render(model: BrowserPageModel, plan: PlaywrightInstallPlan) {
        let f = model.footer
        checkbox.state = model.checked ? .on : .off
        checkbox.isEnabled = f.checkboxEnabled
        checkbox.isHidden = !f.showsCheckbox
        externalNote.isHidden = !model.externalProvider
        switch model.phase {
        case .installed(let update):
            detail.stringValue = WizardCopy.browserSignInNote
            status.stringValue = WizardCopy.browserInstalledStatus
                + (update ? " · an update is available, use the menu bar to update" : "")
            status.textColor = .systemGreen
        case .installing, .idle, .failed:
            detail.stringValue = WizardCopy.playwrightConsent(plan: plan)
            status.stringValue = model.isInstalling ? WizardCopy.browserInstallingStatus : ""
            status.textColor = .secondaryLabelColor
        }
        status.isHidden = status.stringValue.isEmpty
        if case .installing(let p) = model.phase {
            bar.isHidden = false
            progressLabel.isHidden = false
            progressLabel.stringValue = WizardCopy.stepText(p)
            if let frac = p?.fraction { bar.isIndeterminate = false; bar.doubleValue = frac }
            else { bar.isIndeterminate = true; bar.startAnimation(nil) }
        } else {
            bar.stopAnimation(nil)
            bar.isHidden = true
            progressLabel.isHidden = true
        }
        if let failureValue = model.failure {
            failure.stringValue = WizardCopy.installFailure(failureValue)
            failure.isHidden = false
        } else {
            failure.isHidden = true
        }
        signInButton.isHidden = !f.showsSignIn
        continueButton.isHidden = !f.showsContinue
        continueButton.isEnabled = f.continueEnabled
        cancelButton.isHidden = !f.showsCancel
        retryButton.isHidden = !f.showsRetry
        continueWithoutButton.isHidden = !f.showsContinueWithout
    }
}
