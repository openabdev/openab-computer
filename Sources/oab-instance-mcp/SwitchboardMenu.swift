import AppKit
import Foundation
import InstanceMCPCore

/// The menu bar's switchboard actions: Configure, Reconnect, and Disconnect & forget.
/// Dialogs only. The rules (what is valid, what needs confirmation, what a save does
/// to the running dialer) live in `SwitchboardConfigStore` and `SwitchboardSupervisor`.
@MainActor
final class SwitchboardMenu {
    private let supervisor: SwitchboardSupervisor

    init(supervisor: SwitchboardSupervisor) {
        self.supervisor = supervisor
    }

    /// Configure…: URL, secret (never shown) and profile. Owner needs its own
    /// confirmation; cancelling that puts the profile back to what it was.
    func configure() async {
        let store = await supervisor.store
        let current = await supervisor.current
        let secretSaved = store.secretState() == .set
        var previous = current?.profile ?? .observe

        let urlField = NSTextField(string: current?.url.absoluteString ?? "")
        urlField.placeholderString = "wss://<switchboard>/vm/attach"
        let secretField = NSSecureTextField()
        secretField.placeholderString = secretSaved ? "A secret is saved. Leave blank to keep it." : "Required"
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for p in ProfileChoice.choices { popup.addItem(withTitle: p.rawValue) }
        popup.selectItem(withTitle: previous.rawValue)
        let note = NSTextField(wrappingLabelWithString:
            "Changing the URL or profile reconnects now and drops the current attach. " +
            "A new secret applies on the next dial. The secret is never shown.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let stack = NSStackView(views: [
            labeled("URL", urlField), labeled("Secret", secretField), labeled("Profile", popup), note,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for v in stack.arrangedSubviews { v.widthAnchor.constraint(equalToConstant: 380).isActive = true }
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 210)

        while true {
            let alert = NSAlert()
            alert.messageText = "Configure switchboard"
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.accessoryView = stack
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let chosen = ProfileChoice.choices[max(0, popup.indexOfSelectedItem)]
            var confirmed = false
            if ProfileChoice.needsConfirmation(chosen) {
                guard confirmOwner() else {
                    popup.selectItem(withTitle: previous.rawValue)
                    continue
                }
                confirmed = true
            }
            let edit = SwitchboardConfigStore.Edit(
                url: urlField.stringValue, newSecret: secretField.stringValue,
                profile: chosen, ownerConfirmed: confirmed)
            do {
                let outcome = try await supervisor.save(edit)
                previous = chosen
                info("Switchboard saved", Self.message(for: outcome))
                return
            } catch {
                info("Switchboard not saved", String(describing: error))
            }
        }
    }

    /// Reconnect: drops the current attach and dials again. After a 4002 the other
    /// daemon with this secret would be displaced again, so ask first.
    func reconnect() async {
        if await supervisor.status.lastClose?.code == 4002 {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Reconnect after replacement?"
            alert.informativeText = "Another daemon with this secret took the switchboard slot. Reconnecting will displace it again."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Reconnect")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        await supervisor.reconnect()
    }

    /// Disconnect & forget: stop dialling and delete the three files, after confirmation.
    /// The LaunchAgent plist keeps its flags until the installer is re-run.
    func forget() async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Disconnect and forget the switchboard?"
        alert.informativeText = "This deletes switchboard.url, switchboard.secret and switchboard.profile and stops dialling. " +
            "The LaunchAgent still has the switchboard flags, so re-run the installer to clear them. " +
            "Until then this Mac starts with the switchboard off; /mcp and /attach keep working."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Forget")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            try await supervisor.forget(confirmed: true)
            info("Switchboard forgotten",
                 "The switchboard files are deleted. Re-run the installer to clear the LaunchAgent flags.")
        } catch {
            info("Switchboard not forgotten", String(describing: error))
        }
    }

    // MARK: helpers

    private func confirmOwner() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow owner (shell-equivalent)?"
        alert.informativeText = "Owner lets the switchboard's callers run the desktop user's shell, drive the GUI and use the browser on this Mac. " +
            "The switchboard's own allowlist is then the only limit."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Use owner")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func info(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func message(for outcome: SwitchboardSupervisor.SaveOutcome) -> String {
        switch outcome {
        case .started: return "Dialling the switchboard now."
        case .reconnected: return "Reconnected with the new settings. The previous attach was dropped."
        case .nextDial: return "The new secret is used on the next dial. The current attach is unchanged."
        }
    }

    private func labeled(_ title: String, _ view: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        view.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let row = NSStackView(views: [label, view])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }
}
