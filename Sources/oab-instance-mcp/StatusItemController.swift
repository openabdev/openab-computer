import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import InstanceMCPCore

/// Menu bar presence for the daemon: at-a-glance health (permissions, activity) and the
/// handful of actions a human at the Mac actually needs. Everything else stays CLI/MCP.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let version: String
    private let url: String
    private let launchdLabel = "dev.openab.instance-mcp"
    private let logPath: String
    private let token: String?
    /// Shown in the menu when the no-flag launch found no Tailscale login (token-only auth).
    private let notice: String?
    /// True for a no-flag (Finder) launch, which has no LaunchAgent to restart it after an exit.
    private let relaunchesOnRestart: Bool
    private let defaults: UserDefaults
    private let store: SetupWizardStore
    private var permissionSetupWindow: PermissionSetupWindowController?
    /// Relaunches the app for Screen Recording (design Q3): the new instance is started first, then this one quits.
    private lazy var relaunchCoordinator = RelaunchCoordinator(
        store: store,
        launch: { [relaunchesOnRestart] in
            // Under a LaunchAgent, KeepAlive brings the app back after the exit. A Finder launch has no agent, so a
            // detached shell waits for this pid to exit (which frees 127.0.0.1:8795) and then opens the bundle.
            guard relaunchesOnRestart, Bundle.main.bundlePath.hasSuffix(".app") else { return true }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "i=0; while kill -0 \"$1\" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; exec /usr/bin/open -n \"$2\"",
                           "sh", String(getpid()), Bundle.main.bundlePath]
            return (try? p.run()) != nil
        },
        terminate: { exit(0) })
    /// Revocation watch: 30 seconds, preflight reads only (`CoreWatch`). Runs for the life of the menu bar process.
    private var coreWatchTimer: Timer?
    private let coreReader = SystemCorePermissionReader()
    private let attach: AttachManager?
    private let switchboardSupervisor: SwitchboardSupervisor?
    private lazy var switchboardMenu: SwitchboardMenu? = switchboardSupervisor.map { SwitchboardMenu(supervisor: $0) }
    /// Latest switchboard status, pushed from the supervisor. The menu is built synchronously, so it reads this.
    var switchboardStatus: SwitchboardStatus? {
        didSet { refreshSwitchboardTitle() }
    }
    private var switchboardTitleItem: NSMenuItem?
    private var grantHeaderItem: NSMenuItem?
    private var grantRowItems: [NSMenuItem] = []
    private var grantTimer: Timer?
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private var sessions = 0
    private var calls = 0
    private var denies = 0
    private var lastCall: (tool: String, who: String, at: Date)?
    private var flashWork: DispatchWorkItem?

    init(version: String, url: String, logPath: String, token: String? = nil,
         defaults: UserDefaults = .standard, attach: AttachManager? = nil,
         switchboard: SwitchboardSupervisor? = nil, notice: String? = nil, relaunchesOnRestart: Bool = false) {
        self.version = version
        self.url = url
        self.logPath = logPath
        self.token = token
        self.notice = notice
        self.relaunchesOnRestart = relaunchesOnRestart
        self.defaults = defaults
        self.store = SetupWizardStore(defaults: defaults)
        self.attach = attach
        self.switchboardSupervisor = switchboard
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.image = Self.icon(active: false)
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "OpenAB Computer \(version)"
        menu.delegate = self
        item.menu = menu
        startCoreWatch()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reopenSetupIfCoreMissing() }
        }
    }

    /// Show on the first launch that has anything missing. A machine that already has every grant is marked
    /// complete without a window. Missing core permissions show the wizard regardless of earlier closes.
    func showPermissionSetupIfNeeded() {
        // Right after a relaunch from the Restart button: reopen on the page the previous instance was on, even when
        // everything is granted. A silent relaunch after Finish has no page and falls through to the normal rules.
        if let page = store.consumeRelaunch()?.page {
            openPermissionSetup(page: page)
            return
        }
        let snapshot = PermissionProbe.current()
        if snapshot.allGranted {
            store.hasShown = true
            return
        }
        if PermissionSetupPolicy.shouldAutoShow(hasShown: store.hasShown, snapshot: snapshot) {
            showPermissionSetup()
        }
    }

    @objc func showPermissionSetup() {
        openPermissionSetup(page: nil)
    }

    private func openPermissionSetup(page: WizardPage?) {
        if permissionSetupWindow == nil {
            permissionSetupWindow = PermissionSetupWindowController(store: store, relaunch: relaunchCoordinator)
        }
        permissionSetupWindow?.show(resume: page)
    }

    /// Reopens the wizard after the user closed it, while a core permission is still missing.
    private func reopenSetupIfCoreMissing() {
        let visible = permissionSetupWindow?.isWindowVisible ?? false
        if PermissionSetupPolicy.shouldReopenOnActivation(windowVisible: visible, snapshot: PermissionProbe.current()) {
            showPermissionSetup()
        }
    }

    /// Every 30 seconds: read Screen Recording and Accessibility with preflight calls only (no prompt, no
    /// capture, no Full Disk Access probe). Records that core was once granted, flags a later revocation in the
    /// status item tooltip, and pushes the two core results to the wizard if it is open. It never opens the window.
    /// With the window closed, the menu shows "Setup incomplete" on next open.
    private func startCoreWatch() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickCoreWatch() }
        }
        RunLoop.main.add(timer, forMode: .common)
        coreWatchTimer = timer
    }

    private func tickCoreWatch() {
        let current = CoreWatch.poll(coreReader)
        store.coreGrantedSeen = CoreWatch.seenAfter(previouslySeen: store.coreGrantedSeen, current: current)
        let revoked = CoreWatch.revoked(previouslySeen: store.coreGrantedSeen, current: current)
        item.button?.toolTip = revoked
            ? "OpenAB Computer \(version) · \(WizardCopy.setupIncomplete)"
            : "OpenAB Computer \(version)"
        if permissionSetupWindow?.isWindowVisible == true {
            permissionSetupWindow?.refreshCore(current)
        }
    }
    private static func icon(active: Bool) -> NSImage? {
        let name = active ? "desktopcomputer.and.arrow.down.fill" : "desktopcomputer.and.arrow.down"
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: "OpenAB Computer")?.withSymbolConfiguration(cfg)
    }

    /// Fed every server log line; cheap string matching keeps the coupling to one closure.
    func observe(_ line: String) {
        if line.contains(" tools/call ") {
            calls += 1
            // "<principal> tools/call <tool>"
            let parts = line.split(separator: " ")
            if let i = parts.firstIndex(of: "tools/call"), i + 1 < parts.count {
                lastCall = (String(parts[i + 1]), i > 0 ? String(parts[i - 1]) : "?", Date())
            }
            flash()
        } else if line.contains(" opened by ") {
            sessions += 1
        } else if line.hasPrefix("deny ") || line.contains(" deny ") {
            denies += 1
        }
    }

    private func flash() {
        item.button?.image = Self.icon(active: true)
        flashWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.item.button?.image = Self.icon(active: false) }
        flashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    // MARK: menu

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let permissions = PermissionProbe.current()

        menu.addItem(label("OpenAB Computer \(version)"))
        menu.addItem(label(url, action: #selector(copyURL), tip: "Click to copy"))
        if let token, !token.isEmpty {
            menu.addItem(label("Token: \(Self.mask(token))", action: #selector(copyToken), tip: "Click to copy the bearer token"))
        }
        if let notice {
            menu.addItem(label(notice))
        }
        menu.addItem(.separator())

        menu.addItem(label("Set Up Permissions…", action: #selector(showPermissionSetup)))
        if SetupGate.evaluate(snapshot: permissions).blocksCore {
            menu.addItem(label(WizardCopy.setupIncomplete))
        }
        menu.addItem(permissionMenuItem("Screen Recording", kind: .screenRecording,
                                        state: permissions.screenRecording, action: #selector(openScreenPane)))
        menu.addItem(permissionMenuItem("Accessibility", kind: .accessibility,
                                        state: permissions.accessibility, action: #selector(openAXPane)))
        menu.addItem(permissionMenuItem("Full Disk Access", kind: .fullDiskAccess,
                                        state: permissions.fullDiskAccess, action: #selector(openFDAPane)))
        menu.addItem(.separator())

        addSwitchboardSection()
        addGrantSection()
        menu.addItem(.separator())

        menu.addItem(label("Sessions \(sessions) · Calls \(calls)" + (denies > 0 ? " · Denied \(denies)" : "")))
        if let l = lastCall {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            menu.addItem(label("Last: \(l.tool) by \(l.who) at \(f.string(from: l.at))"))
        } else {
            menu.addItem(label("No tool calls yet"))
        }
        menu.addItem(.separator())

        menu.addItem(label("Open Log", action: #selector(openLog)))
        menu.addItem(label("Restart Agent", action: #selector(restart)))
        menu.addItem(label("Quit Agent (stops launchd job)", action: #selector(quit)))
        startRefreshTimer()
    }

    func menuDidClose(_ menu: NSMenu) {
        grantTimer?.invalidate()
        grantTimer = nil
    }

    /// Refreshes the grant rows and the backoff countdown while the menu is open. Added in
    /// `.common` mode: a `.default` timer does not fire while the menu tracks the mouse.
    private func startRefreshTimer() {
        grantTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshGrants()
                self?.refreshSwitchboardTitle()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        grantTimer = timer
    }

    // MARK: switchboard

    private func addSwitchboardSection() {
        guard switchboardSupervisor != nil else { return }
        let title = label("")
        switchboardTitleItem = title
        menu.addItem(title)
        refreshSwitchboardTitle()
        if let note = switchboardStatus?.note {
            menu.addItem(label(note))
        }
        // With no config there is nothing to reconnect or forget. A process dialling from
        // explicit flags cannot edit the saved files, so Configure and Forget are off there.
        let hasConfig = switchboardStatus?.hasConfig ?? false
        let managesSaved = switchboardStatus?.managesSaved ?? false
        let configure = label("Configure…", action: #selector(configureSwitchboard))
        configure.isEnabled = managesSaved
        menu.addItem(configure)
        let reconnect = label("Reconnect", action: #selector(reconnectSwitchboard))
        reconnect.isEnabled = hasConfig
        menu.addItem(reconnect)
        let forget = label("Disconnect & forget…", action: #selector(forgetSwitchboard))
        forget.isEnabled = hasConfig && managesSaved
        menu.addItem(forget)
        menu.addItem(.separator())
    }

    private func refreshSwitchboardTitle() {
        guard let status = switchboardStatus else {
            switchboardTitleItem?.title = "Switchboard: starting…"
            return
        }
        switchboardTitleItem?.title = status.title { Self.timeFormatter.string(from: $0) }
    }

    @objc private func configureSwitchboard() {
        Task { await switchboardMenu?.configure() }
    }

    @objc private func reconnectSwitchboard() {
        Task { await switchboardMenu?.reconnect() }
    }

    @objc private func forgetSwitchboard() {
        Task { await switchboardMenu?.forget() }
    }

    // MARK: reverse-attach grants

    private func addGrantSection() {
        guard attach != nil else { return }
        let header = label("Reverse-attach grants")
        grantHeaderItem = header
        grantRowItems = []
        menu.addItem(header)
        refreshGrants()
    }

    private func refreshGrants() {
        guard let attach else { return }
        Task { renderGrants(await attach.liveGrants()) }
    }

    /// Replace the grant rows under the header. The menu may be open while this runs.
    private func renderGrants(_ grants: [AttachManager.Grant]) {
        guard let header = grantHeaderItem, menu.index(of: header) >= 0 else { return }
        for item in grantRowItems { menu.removeItem(item) }
        grantRowItems = []
        var index = menu.index(of: header) + 1
        func insert(_ item: NSMenuItem) {
            menu.insertItem(item, at: index)
            grantRowItems.append(item)
            index += 1
        }
        if grants.isEmpty {
            insert(label("No live grants"))
            return
        }
        let now = Date()
        for grant in grants {
            let row = GrantRowModel.make(grant, now: now)
            let shell = row.shellEquivalent ? " · shell-equivalent" : ""
            insert(label("\(row.session) · \(row.profile)\(shell) · \(row.stateLabel) · \(row.expiresText)"))
            if let requested = row.requestedProfile {
                insert(label("   requested \(requested), served as \(row.profile)"))
            }
            if let warning = row.warning {
                insert(label("   ⚠︎ \(warning)"))
            }
            let revoke = label("   Revoke \(row.session)…", action: #selector(revokeGrant(_:)))
            revoke.representedObject = row.id
            insert(revoke)
        }
    }

    @objc private func revokeGrant(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let attach else { return }
        Task {
            guard confirmRevoke() else { return }
            await attach.revokeIfPresent(id, reason: "revoked from the menu bar")
            renderGrants(await attach.liveGrants())
        }
    }

    /// Revoking closes the reverse-attach session, and the runtime's agent loses it.
    private func confirmRevoke() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Revoke this grant?"
        alert.informativeText = "The reverse-attach session closes now. Granting it again needs a new attach request."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Revoke")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func label(_ title: String, action: Selector? = nil, tip: String? = nil) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: action, keyEquivalent: "")
        m.target = self
        m.isEnabled = action != nil
        m.toolTip = tip
        return m
    }

    private func permissionMenuItem(_ title: String, kind: PermissionKind,
                                    state: PermissionState, action: Selector) -> NSMenuItem {
        let mark: String
        switch state {
        case .granted: mark = "✓"
        case .denied: mark = "✗"
        case .unknown: mark = "?"
        }
        let item = label("\(mark) \(title)", action: state.isGranted ? nil : action)
        if kind == .fullDiskAccess && state == .unknown {
            item.toolTip = "No protected probe database was found; open settings to verify manually"
        }
        return item
    }

    @objc private func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
    @objc private func copyToken() {
        guard let token else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
    }
    /// Show only the ends so the menu confirms which token is loaded without exposing it.
    private static func mask(_ t: String) -> String {
        guard t.count > 12 else { return String(repeating: "•", count: t.count) }
        return t.prefix(6) + "…" + t.suffix(4)
    }
    @objc private func openScreenPane() {
        NSWorkspace.shared.open(PermissionKind.screenRecording.settingsURL)
    }
    @objc private func openAXPane() {
        NSWorkspace.shared.open(PermissionKind.accessibility.settingsURL)
    }
    @objc private func openFDAPane() {
        NSWorkspace.shared.open(PermissionKind.fullDiskAccess.settingsURL)
    }
    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }
    @objc private func restart() {
        // Under a LaunchAgent, KeepAlive brings us straight back; exiting is the restart.
        guard relaunchesOnRestart, Bundle.main.bundlePath.hasSuffix(".app") else { exit(0) }
        // A Finder launch has no LaunchAgent. A detached shell reopens the bundle once this process has exited.
        // If the shell cannot start, keep running rather than quit with nothing to bring the app back.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; exec /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        guard (try? p.run()) != nil else { return }
        exit(0)
    }
    @objc private func quit() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/\(launchdLabel)"]
        try? p.run()          // bootout SIGTERMs us; if it fails (not under launchd) just exit
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
    }
}
