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
    /// What the menu shows and copies as the URL: the verified tailnet URL while access is on, else the local one.
    private var currentURL: String { exposure?.publicURL ?? url }
    /// The launchd job label when this process is a launchd job (`XPC_SERVICE_NAME`), nil for a Finder or terminal run.
    private let launchdJobLabel: String?
    private var underLaunchd: Bool { launchdJobLabel != nil }
    /// The tailnet exposure state and controls. Nil without a Tailscale login to rely on (no allow list, no detected login).
    private let exposure: TailnetExposure?
    private let logPath: String
    private let token: String?
    /// Shown in the menu when the no-flag launch found no Tailscale login (token-only auth).
    private let notice: String?
    private let defaults: UserDefaults
    private let store: SetupWizardStore
    private var permissionSetupWindow: PermissionSetupWindowController?
    /// Relaunches the app for Screen Recording (design Q3): the new instance is started first, then this one quits.
    private lazy var relaunchCoordinator = RelaunchCoordinator(
        store: store,
        launch: { [launchdJobLabel] in
            // Under this app's LaunchAgent, KeepAlive brings the app back after the exit. Otherwise a detached shell
            // waits for this pid to exit (which frees 127.0.0.1:8795) and then starts the same invocation again: the
            // bundle for a Finder launch, the same executable and arguments for a flag launch from a terminal.
            guard launchdJobLabel == nil else { return true }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            // Without the job label, so an orphaned waiter or the copy it starts is never taken for the launchd job.
            p.environment = LaunchdJob.childEnvironment(ProcessInfo.processInfo.environment)
            let wait = "i=0; while kill -0 \"$1\" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; if kill -0 \"$1\" 2>/dev/null; then echo \"relaunch: the old process (pid $1) still holds the port after 10 s; not starting a second copy\" >&2; exit 1; fi; shift; "
            if Bundle.main.bundlePath.hasSuffix(".app") {
                p.arguments = ["-c", wait + "exec /usr/bin/open -n \"$1\"", "sh", String(getpid()), Bundle.main.bundlePath]
            } else {
                let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
                p.arguments = ["-c", wait + "exec \"$@\"", "sh", String(getpid()), exe] + Array(CommandLine.arguments.dropFirst())
            }
            return (try? p.run()) != nil
        },
        terminate: { exit(0) })
    /// Revocation watch: 30 seconds, preflight reads only (`CoreWatch`). Runs for the life of the menu bar process.
    private var coreWatchTimer: Timer?
    private let coreReader = SystemCorePermissionReader()
    private let probeCache = ScreenRecordingProbeCache.shared
    /// The menu rows that show permission state, replaced in place when the shared status changes under an open menu.
    private var permissionItems: [NSMenuItem] = []
    private let attach: AttachManager?
    private let switchboardSupervisor: SwitchboardSupervisor?
    private lazy var switchboardMenu: SwitchboardMenu? = switchboardSupervisor.map { SwitchboardMenu(supervisor: $0) }
    /// Latest switchboard status, pushed from the supervisor. The menu is built synchronously, so it reads this.
    var switchboardStatus: SwitchboardStatus? {
        didSet { refreshSwitchboardTitle() }
    }
    private var switchboardTitleItem: NSMenuItem?
    /// The separator after the switchboard and grant rows; grant rows are inserted before it.
    private var grantAnchorItem: NSMenuItem?
    private var attachRowItem: NSMenuItem?
    private let bindHost: String
    private let bindPort: Int
    private let path: String
    private let upstreams: [NetworkUpstream]
    private let attachEnabled: Bool
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
         switchboard: SwitchboardSupervisor? = nil, notice: String? = nil,
         exposure: TailnetExposure? = nil,
         bindHost: String = "127.0.0.1", bindPort: Int = 8795, path: String = "/mcp",
         upstreams: [NetworkUpstream] = [], attachEnabled: Bool = true,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.exposure = exposure
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.path = path
        self.upstreams = upstreams
        self.attachEnabled = attachEnabled
        self.launchdJobLabel = LaunchdJob.jobLabel(environment: environment)
        self.version = version
        self.url = url
        self.logPath = logPath
        self.token = token
        self.notice = notice
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
        // Items set their own isEnabled. With auto-enabling on, AppKit validates each item by whether its target
        // answers the action and ignores isEnabled, so Reconnect and Disconnect & forget could not be grayed out.
        menu.autoenablesItems = false
        item.menu = menu
        startCoreWatch()
        refreshPermissionStatus()
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
        let snapshot = resolvedPermissions().shown
        clearSpentIfGranted(snapshot)
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

    /// "Allow tailnet access…": the wizard on its tailnet page (a missing core permission still shows page 1 first).
    @objc private func showTailnetSetup() {
        openPermissionSetup(page: .tailnet)
    }

    /// "Manage with this app": the user's explicit opt-in for a mapping that already existed. Reads only.
    @objc private func manageTailnet() {
        guard let exposure else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = exposure.manageExistingMapping()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.permissionSetupWindow?.refresh()
                    guard case .failed = outcome else { return }
                    self?.showAlert("Tailnet access", outcome.message)
                }
            }
        }
    }

    private func showAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// "Turn Off Tailnet Access": runs the CLI off the main thread and reports a failure in a dialog.
    @objc private func turnOffTailnet() {
        guard let exposure else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = exposure.disable()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.permissionSetupWindow?.refresh()   // an open wizard's tailnet row must not keep showing "On"
                    guard outcome != .off else { return }
                    let alert = NSAlert()
                    alert.messageText = "Tailnet access"
                    alert.informativeText = outcome.message
                    alert.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        }
    }

    private func openPermissionSetup(page: WizardPage?) {
        if permissionSetupWindow == nil {
            permissionSetupWindow = PermissionSetupWindowController(store: store, relaunch: relaunchCoordinator, exposure: exposure)
        }
        permissionSetupWindow?.show(resume: page)
    }

    /// A process that sees Screen Recording granted has consumed the grant, including after the silent Finish relaunch
    /// (which reopens no wizard). A later revoke and re-grant may then relaunch once more.
    private func clearSpentIfGranted(_ snap: PermissionSnapshot) {
        if snap.screenRecording.isGranted, store.autoRelaunchSpent { store.autoRelaunchSpent = false }
    }

    /// Reopens the wizard after the user closed it, while a core permission is still missing.
    private func reopenSetupIfCoreMissing() {
        let visible = permissionSetupWindow?.isWindowVisible ?? false
        if PermissionSetupPolicy.shouldReopenOnActivation(windowVisible: visible, snapshot: resolvedPermissions().shown) {
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
        startUncertainRecheck()
    }

    /// While tailscaled cannot be seen (no CLI, or not Running), a mapping could come alive: recheck every second for
    /// the first 60 seconds after launch, then every 5 seconds. The loop and the CLI calls run off the main thread;
    /// only the failure alert goes back to it. The 30 s tick above also rechecks.
    private let recheckQueue = DispatchQueue(label: "dev.openab.tailnet-recheck", qos: .utility)
    private func startUncertainRecheck() {
        guard let exposure, !exposure.loginDetected, exposure.tokenOnly else { return }
        Self.runRecheckLoop(exposure: exposure, queue: recheckQueue, launched: Date(), delay: 1)
    }

    nonisolated private static func runRecheckLoop(exposure: TailnetExposure, queue: DispatchQueue, launched: Date, delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) {
            if exposure.uncertain, case .failed(let why)? = exposure.withdrawWithoutLogin() {
                DispatchQueue.main.async { MainActor.assumeIsolated { quitForUnwithdrawnMapping(why) } }
                return
            }
            let next = TailnetExposure.recheckInterval(sinceLaunch: Date().timeIntervalSince(launched))
            runRecheckLoop(exposure: exposure, queue: queue, launched: launched, delay: next)
        }
    }

    private static var quitting = false
    private static func quitForUnwithdrawnMapping(_ why: String) {
        guard !quitting else { return }
        quitting = true
        let reason = "\(why) No Tailscale login was detected, so the token alone would guard it. Remove the mapping with: tailscale serve --https=8444 off"
        fputs("tailnet access: quitting: \(reason)\n", stderr)
        let alert = NSAlert()
        alert.messageText = "OpenAB Computer is quitting"
        alert.informativeText = reason
        alert.runModal()
        exit(3)
    }

    private func tickCoreWatch() {
        // Same timer: refresh the shared Screen Recording status so a grant made while the app runs reaches the menu.
        refreshPermissionStatus()
        let current = SharedPermissionStatus.resolve(process: CoreWatch.poll(coreReader), child: probeCache.latest).shown
        store.coreGrantedSeen = CoreWatch.seenAfter(previouslySeen: store.coreGrantedSeen, current: current)
        let revoked = CoreWatch.revoked(previouslySeen: store.coreGrantedSeen, current: current)
        item.button?.toolTip = revoked
            ? "OpenAB Computer \(version) · \(WizardCopy.setupIncomplete)"
            : "OpenAB Computer \(version)"
        if permissionSetupWindow?.isWindowVisible == true {
            permissionSetupWindow?.refreshCore(CoreWatch.poll(coreReader))
        }
        recheckWithoutLogin()
    }

    /// While this process has no Tailscale login, the token alone guards it. Every tick re-runs the no-login
    /// withdrawal off the main thread, so a mapping that appears after launch (or a daemon that starts late) is
    /// withdrawn. If it cannot be withdrawn or checked while the daemon runs, show the alert and quit.
    private var recheckInFlight = false
    private func recheckWithoutLogin() {
        guard let exposure, !exposure.loginDetected, exposure.tokenOnly, !recheckInFlight else { return }
        recheckInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = exposure.withdrawWithoutLogin()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.recheckInFlight = false
                    guard case .failed(let why)? = outcome else { return }
                    Self.quitForUnwithdrawnMapping(why)
                }
            }
        }
    }

    /// Asks the shared cache for a fresh child probe (off the main thread, at most one per few seconds) when this
    /// process reports Screen Recording off, then redraws the permission rows if the menu is built.
    private func refreshPermissionStatus() {
        guard !coreReader.screenRecordingGranted() else { renderPermissionItems(); return }
        probeCache.refreshIfStale { [weak self] value in
            guard value != nil else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.renderPermissionItems() } }
        }
    }

    private func resolvedPermissions() -> ResolvedPermissions {
        SharedPermissionStatus.resolve(process: PermissionProbe.current(), child: probeCache.latest)
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
        refreshPermissionStatus()

        menu.addItem(label("OpenAB Computer \(version)"))
        menu.addItem(label(currentURL, action: #selector(copyURL), tip: "Click to copy"))
        if let token, !token.isEmpty {
            menu.addItem(label("Token: \(Self.mask(token))", action: #selector(copyToken), tip: "Click to copy the bearer token"))
        }
        if let notice {
            menu.addItem(label(notice))
        }
        let tailnet = MenuModel.tailnetMenu(offered: exposure?.offersExposure ?? false, publicURL: exposure?.publicURL,
                                          optedIn: (exposure?.optedIn ?? false) || (exposure?.unconfirmed ?? false),
                                          existingMapping: exposure?.existingMapping ?? false)
        let tailnetState = MenuModel.networkTailnetState(
            publicURL: exposure?.publicURL ?? externalPublicURL,
            optedIn: (exposure?.optedIn ?? false) || (exposure?.unconfirmed ?? false),
            existingMapping: exposure?.existingMapping ?? (externalPublicURL != nil), uncertain: (exposure?.uncertain ?? false)
                || (exposure.map { !$0.offersExposure && !$0.tokenOnly } ?? false))
        let section = MenuModel.networkSection(
            bindHost: bindHost, bindPort: bindPort, path: path, upstreams: upstreams, tailnet: tailnetState,
            switchboard: switchboardSupervisor == nil ? nil : switchboardRowInput(),
            liveGrants: nil, attachEnabled: attachEnabled)
        menu.addItem(.separator())
        menu.addItem(label(section.header))
        switchboardTitleItem = nil
        attachRowItem = nil
        for row in section.rows {
            if row.kind == .reverseAttach && attachEnabled && attach == nil { continue }
            let item = label(row.text, action: row.copyValue == nil ? nil : #selector(copyRow(_:)),
                             tip: row.copyValue == nil ? nil : "Click to copy")
            item.representedObject = row.copyValue
            menu.addItem(item)
            switch row.kind {
            case .switchboard: switchboardTitleItem = item
            case .reverseAttach: attachRowItem = item
            case .tailnet: addTailnetActions(tailnet)
            default: break
            }
        }
        menu.addItem(.separator())

        permissionItems = permissionMenuItems(resolvedPermissions())
        for item in permissionItems { menu.addItem(item) }
        menu.addItem(.separator())

        addSwitchboardSection()
        addGrantSection()

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
        menu.addItem(label(MenuModel.quitTitle(underLaunchd: underLaunchd), action: #selector(quit)))
        startRefreshTimer()
    }

    /// The existing tailnet action rows, directly under the Tailnet row.
    private func addTailnetActions(_ tailnet: TailnetMenu) {
        if let manage = tailnet.manageTitle {
            menu.addItem(label(manage, action: #selector(manageTailnet),
                               tip: "Records that you want this app to manage the existing mapping on port \(TailnetExposure.httpsPort). Changes nothing in Tailscale."))
        }
        switch tailnet.action {
        case .allow?:
            menu.addItem(label(tailnet.actionTitle ?? "", action: #selector(showTailnetSetup),
                               tip: "Lets other devices on your tailnet reach this Mac. Off until you allow it."))
        case .turnOff?:
            menu.addItem(label(tailnet.actionTitle ?? "", action: #selector(turnOffTailnet),
                               tip: "Removes the tailscale serve mapping on port \(TailnetExposure.httpsPort)"))
        case nil:
            break
        }
    }

    /// An installer-owned `--public-url` (no exposure object) counts as a tailnet URL only when it is not the local one.
    private var externalPublicURL: String? {
        exposure == nil && url != "http://\(MenuModel.hostForURL(bindHost)):\(bindPort)\(path)" ? url : nil
    }

    private func permissionMenuItems(_ resolved: ResolvedPermissions) -> [NSMenuItem] {
        let permissions = resolved.shown
        var items = [label("Set Up Permissions…", action: #selector(showPermissionSetup))]
        if SetupGate.evaluate(snapshot: permissions).blocksCore {
            items.append(label(WizardCopy.setupIncomplete))
        }
        items.append(permissionMenuItem("Screen Recording", kind: .screenRecording,
                                        state: permissions.screenRecording, action: #selector(openScreenPane)))
        items.append(permissionMenuItem("Accessibility", kind: .accessibility,
                                        state: permissions.accessibility, action: #selector(openAXPane)))
        items.append(permissionMenuItem("Full Disk Access", kind: .fullDiskAccess,
                                        state: permissions.fullDiskAccess, action: #selector(openFDAPane)))
        if let line = SharedPermissionStatus.menuRestartLine(resolved) {
            items.append(label(line, action: #selector(restartToFinishSetup),
                               tip: "macOS applies Screen Recording to a running app only after it restarts"))
        }
        return items
    }

    /// Replaces the permission rows in place. A no-op while the menu is not built.
    private func renderPermissionItems() {
        guard let first = permissionItems.first, menu.index(of: first) >= 0 else { return }
        let index = menu.index(of: first)
        for item in permissionItems { menu.removeItem(item) }
        permissionItems = permissionMenuItems(resolvedPermissions())
        for (offset, item) in permissionItems.enumerated() { menu.insertItem(item, at: index + offset) }
    }

    /// The same coordinator as the wizard's Finish: one request per app launch, new instance first, then quit.
    @objc private func restartToFinishSetup() {
        if !relaunchCoordinator.requestRelaunch(page: nil, automatic: true) {
            log("menu: restart to finish setup not started")
            showAlert("OpenAB Computer", WizardCopy.restartFailed)
        }
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
        if let note = switchboardStatus?.note {
            menu.addItem(label(note))
        }
        // With no config there is nothing to reconnect or forget. A process dialling from
        // explicit flags cannot edit the saved files, so Configure and Forget are off there.
        let enabled = MenuModel.switchboardEnablement(switchboardStatus)
        let configure = label("Configure…", action: #selector(configureSwitchboard))
        configure.isEnabled = enabled.configure
        menu.addItem(configure)
        let reconnect = label("Reconnect", action: #selector(reconnectSwitchboard))
        reconnect.isEnabled = enabled.reconnect
        menu.addItem(reconnect)
        let forget = label("Disconnect & forget…", action: #selector(forgetSwitchboard))
        forget.isEnabled = enabled.forget
        menu.addItem(forget)
    }

    private func switchboardRowInput() -> NetworkSwitchboard {
        NetworkSwitchboard(status: switchboardStatus) { Self.timeFormatter.string(from: $0) }
    }

    private func refreshSwitchboardTitle() {
        switchboardTitleItem?.title = switchboardRowInput().text
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

    /// The anchor separator always ends the block; grant rows (with their header, when there are any) go before it.
    private func addGrantSection() {
        let anchor = NSMenuItem.separator()
        grantAnchorItem = anchor
        grantRowItems = []
        menu.addItem(anchor)
        if attach != nil { refreshGrants() }
    }

    private func refreshGrants() {
        guard let attach else { return }
        Task { renderGrants(await attach.liveGrants()) }
    }

    /// Replace the grant rows under the header. The menu may be open while this runs.
    private func renderGrants(_ grants: [AttachManager.Grant]) {
        guard let anchor = grantAnchorItem, menu.index(of: anchor) >= 0 else { return }
        for item in grantRowItems { menu.removeItem(item) }
        grantRowItems = []
        if attachEnabled {
            let section = MenuModel.networkSection(
                bindHost: bindHost, bindPort: bindPort, path: path, upstreams: [], tailnet: .off,
                switchboard: nil, liveGrants: grants.count, attachEnabled: true)
            if let text = section.rows.first(where: { $0.kind == .reverseAttach })?.text { attachRowItem?.title = text }
        }
        var index = menu.index(of: anchor)
        func insert(_ item: NSMenuItem) {
            menu.insertItem(item, at: index)
            grantRowItems.append(item)
            index += 1
        }
        if grants.isEmpty { return }
        insert(label("Reverse-attach grants"))
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
        NSPasteboard.general.setString(currentURL, forType: .string)
    }
    @objc private func copyRow(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
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
        let started = MenuModel.restart(
            underLaunchd: underLaunchd,
            relaunch: { relaunchCoordinator.requestRelaunch(page: nil, automatic: false) },
            exitProcess: { exit(0) })
        if !started {
            log("menu: restart not started")
            showAlert("OpenAB Computer", WizardCopy.restartFailed)
        }
    }
    @objc private func quit() {
        MenuModel.quit(jobLabel: launchdJobLabel, bootout: { label in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["bootout", "gui/\(getuid())/\(label)"]
            try? p.run()          // bootout SIGTERMs us; if it fails just exit
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
        }, exitProcess: { exit(0) })
    }
}
