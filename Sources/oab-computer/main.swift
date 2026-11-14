import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import InstanceMCPCore

let version = "0.12.0"

// Hidden child of the permission wizard (not in --help). Reads the Screen Recording preflight in this fresh process,
// prints nothing, and exits 0 (granted) or 1. It runs before any other setup: no window, no log, no token, no port.
if PermissionCheckCommand.isInvocation(Array(CommandLine.arguments.dropFirst())) {
    exit(PermissionCheckCommand.exitCode(reader: SystemCorePermissionReader()))
}

struct Options {
    var host = "127.0.0.1"
    var port: UInt16 = 8795
    var path = "/mcp"
    var allowLogins: Set<String> = []
    var token: String? = nil
    var tokenFile: String? = nil
    var insecureLocal = false
    var quiet = false
    var menuBar = false
    var publicURL: String? = nil
    var attach = true
    var persistGrants = true
    /// name=url pairs; each is a loopback MCP server whose tools are re-served.
    var upstreams: [(String, URL)] = []
    /// openab-sb `…/vm/attach` to dial, its secret file, and the profile served there.
    var switchboard: String? = nil
    var switchboardSecretFile: String? = nil
    var switchboardProfile: ToolProfile = .observe
    /// The name given to --switchboard-profile when it was mapped (`desktop`, #59).
    var switchboardRequestedProfile: String? = nil
    /// Let `ui_action` set secure fields through the switchboard (refused by default).
    var switchboardAllowSecureSetValue = false
}

func usage() -> Never {
    print("""
    oab-computer \(version) — MCP server exposing this Mac (exec / screenshot / ui_snapshot / ui_action / mouse / key / osascript / sys_info)

    USAGE: oab-computer [--host 127.0.0.1] [--port 8795] [--path /mcp]
                        [--allow-login <email>]... [--token <str> | --token-file <path>]
                        [--insecure-local] [--quiet] [--menu-bar] [--public-url <https://…/mcp>]

    With no arguments (a Finder launch): the menu bar app and the backend on 127.0.0.1:8795/mcp,
    with a bearer token at ~/.config/oab-computer/token (created on first run, or copied from the 0.11.0 token
    at ~/.config/oab-instance-mcp/token)
    and the Tailscale login when `tailscale status` reports one. It exits with a message if port 8795 is in use.

    Auth (at least one required unless --insecure-local):
      --allow-login   Tailscale login (from `tailscale serve`'s Tailscale-User-Login header). Repeatable.
      --token         Shared bearer token; clients send `Authorization: Bearer <token>`.
      --token-file    Read the token from a file (trailing newline stripped).
      --insecure-local  Allow unauthenticated requests that arrive on loopback *without*
                        Tailscale headers. For local debugging only.

      --upstream <name=url>  Re-serve the tools of a loopback MCP server (e.g. the Playwright MCP
                      at browser=http://127.0.0.1:8794/mcp) under this daemon, subject to the
                      connection's tool profile. Repeatable. Tools appear with the upstream's
                      own names; owner sees every upstream tool, observe none.
      --no-attach     Disable the reverse-attach plane (POST/GET /attach, DELETE /attach/{id}):
                      the human-credentialed endpoint through which Connect / Remote lends this
                      Mac to one openab-pty session (this Mac dials the pod; see the ADR).
      --no-grant-persistence
                      Keep reverse-attach grants in memory only. By default live grants are
                      saved (record: ~/Library/Application Support/oab-computer/grants.json,
                      mode 600; secret: login Keychain) and re-dialled after a restart.
      --switchboard <wss://host/vm/attach>
                      Dial an openab-sb switchboard and serve this computer's tools on that socket, so
                      the switchboard's callers can reach it (this Mac dials out; nothing listens).
                      Redials on its own for as long as the process runs. ws:// is loopback-only.
      --switchboard-secret-file <path>
                      The VM secret from `openab-sb gen-secret` (required with --switchboard). Re-read
                      on every dial, so rotating it is: update the file; the next retry picks it up.
      --switchboard-profile observe|owner
                      Tool profile served to the switchboard (default observe: sys_info + screenshot;
                      owner: every tool, including the shell and the browser). The switchboard's own
                      per-caller allowlist applies on top.
      --switchboard-allow-secure-set-value
                      Let ui_action set_value fill secure (password) fields through the switchboard.
                      Off by default: openab-sb writes call arguments to its audit log. Turn it on only
                      for a switchboard that does not record them (audit_args = false).
      --menu-bar      Show a status item in the menu bar (permissions, activity, restart/quit).
      --public-url    The URL clients use (shown/copied from the menu); defaults to the local one.

    Run it as a LaunchAgent in the logged-in user's GUI session (gui/<uid>), not a
    LaunchDaemon — screenshot and input tools need the Aqua session and TCC grants.
    """)
    exit(64)
}

var opts = Options()
var args = Array(CommandLine.arguments.dropFirst())
// A launch with no flags takes the first-run path below. Its arguments are cleared so the flag loop does nothing.
let firstRunLaunch = FirstRunSetup.isNoFlagLaunch(arguments: args)
if firstRunLaunch { args = [] }
func next(_ flag: String) -> String {
    guard !args.isEmpty else { fputs("missing value for \(flag)\n", stderr); usage() }
    return args.removeFirst()
}
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--host": opts.host = next(a)
    case "--port":
        guard let p = UInt16(next(a)) else { fputs("bad port\n", stderr); usage() }
        opts.port = p
    case "--path": opts.path = next(a)
    case "--allow-login": opts.allowLogins.insert(next(a))
    case "--token": opts.token = next(a)
    case "--token-file": opts.tokenFile = next(a)
    case "--insecure-local": opts.insecureLocal = true
    case "--quiet": opts.quiet = true
    case "--menu-bar": opts.menuBar = true
    case "--no-grant-persistence": opts.persistGrants = false
    case "--public-url": opts.publicURL = next(a)
    case "--no-attach": opts.attach = false
    case "--switchboard": opts.switchboard = next(a)
    case "--switchboard-secret-file": opts.switchboardSecretFile = next(a)
    case "--switchboard-allow-secure-set-value": opts.switchboardAllowSecureSetValue = true
    case "--switchboard-profile":
        let v = next(a)
        // The retired `desktop` (a 0.8.x plist flag) serves `observe` with a warning
        // rather than exiting: launchd would restart a refusing daemon forever and
        // take /mcp and /attach down with it (#59).
        guard let r = ToolProfile.resolve(requested: v) else {
            fputs("--switchboard-profile wants observe or owner\n", stderr); usage()
        }
        if let warning = r.warning {
            fputs("--switchboard-profile \(v): \(warning)\n", stderr)
            opts.switchboardRequestedProfile = v
        }
        opts.switchboardProfile = r.profile
    case "--upstream":
        let v = next(a)
        guard let eq = v.firstIndex(of: "="), let u = URL(string: String(v[v.index(after: eq)...])),
              u.host != nil else { fputs("--upstream wants name=http://host:port/path\n", stderr); usage() }
        opts.upstreams.append((String(v[..<eq]), u))
    case "--version": print(version); exit(0)
    case "-h", "--help": usage()
    default: fputs("unknown flag \(a)\n", stderr); usage()
    }
}

// No flags: the menu bar app with the bearer token file (~/.config/oab-computer/token), created on first
// run or copied from the 0.11.0 token, and the Tailscale login if one is detected. Without a login the launch
// continues with the token alone.
// Flag launches never reach this block, so their behavior and the installer's path are unchanged.
/// Writes the reason to stderr (the agent log, for a no-flag launch) and shows it in an alert, then the caller exits.
func showFirstRunAlert(_ message: String) {
    fputs(message + "\n", stderr)
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let alert = NSAlert()
        alert.messageText = "OpenAB Computer did not start"
        alert.informativeText = message
        alert.runModal()
    }
}

var firstRunNotice: String? = nil
/// True when the no-flag launch found a Tailscale login. The tailnet access step is offered only then.
var firstRunLoginDetected = false
var firstRunLines: [String] = []
/// The home directory a no-flag launch writes under; nil for flag launches, which keep their defaults.
var firstRunHome: String? = nil
if firstRunLaunch {
    opts.menuBar = true
    let home = FirstRunSetup.homeDirectory()
    firstRunHome = home
    // Before anything else writes: a Finder launch's stderr would otherwise go to /dev/null.
    FirstRunSetup.redirectStderr(toLogAt: FirstRunSetup.logPath(home: home))
    #if DEBUG
    // Test seam, compiled into debug builds only (swift test). Release builds have no override and always use 8795.
    if let raw = ProcessInfo.processInfo.environment["OAB_COMPUTER_FIRST_RUN_PORT"] {
        if let p = Int(raw), (1...65535).contains(p) {
            opts.port = UInt16(p)
        } else {
            fputs("no-flag launch: OAB_COMPUTER_FIRST_RUN_PORT=\(raw) rejected (not 1 to 65535); using \(opts.port)\n", stderr)
        }
    }
    #endif
    // Checked before any token is touched: a taken port means the installed agent is already serving.
    // Right after a permission relaunch the old instance may still be quitting, so wait briefly for its port.
    // A genuinely separate copy keeps the port and still gets the alert and exit 75.
    if SetupWizardStore().relaunchJustHappened {
        _ = FirstRunSetup.waitForPortFree(host: opts.host, port: opts.port, timeout: 5)
    }
    if FirstRunSetup.isPortInUse(host: opts.host, port: opts.port) {
        showFirstRunAlert(FirstRunSetup.portInUseMessage(host: opts.host, port: opts.port))
        exit(75)
    }
    do {
        let plan = try FirstRunSetup.prepare(home: home)
        opts.tokenFile = plan.tokenPath
        if let login = plan.allowLogin { opts.allowLogins.insert(login); firstRunLoginDetected = true }
        firstRunNotice = plan.notice
        firstRunLines = plan.logLines
    } catch {
        showFirstRunAlert("Could not prepare the token file: \(error). Quit any other oab-computer that is running, " +
                          "remove \(FirstRunSetup.lockPath(for: FirstRunSetup.tokenPath(home: home))) if it is left over from a crash, " +
                          "then open the app again. Details are in \(FirstRunSetup.logPath(home: home)).")
        exit(73)
    }
}

if let f = opts.tokenFile {
    guard let s = try? String(contentsOfFile: (f as NSString).expandingTildeInPath, encoding: .utf8) else {
        fputs("cannot read --token-file \(f)\n", stderr); exit(66)
    }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { fputs("--token-file is empty\n", stderr); exit(66) }
    opts.token = t
}

// Validated before anything starts, so a typo fails the launch instead of a dial.
var switchboardTarget: (url: URL, file: URL, secret: String)? = nil
if let raw = opts.switchboard {
    let url: URL
    do { url = try Switchboard.validate(raw) } catch { fputs("\(error)\n", stderr); exit(64) }
    guard let f = opts.switchboardSecretFile else {
        fputs("--switchboard needs --switchboard-secret-file\n", stderr); exit(64)
    }
    let file = URL(fileURLWithPath: (f as NSString).expandingTildeInPath)
    // An unreadable secret file does not exit under the menu bar: launchd would restart a refusing
    // daemon forever and take /mcp and /attach down with it. The switchboard stays off unless
    // a saved config exists (SwitchboardStartup logs why). A headless process still exits 66.
    if let s = try? String(contentsOf: file, encoding: .utf8),
       !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        switchboardTarget = (url, file, s.trimmingCharacters(in: .whitespacesAndNewlines))
    } else if !opts.menuBar {
        fputs("cannot read --switchboard-secret-file \(f), or it is empty\n", stderr); exit(66)
    }
} else if opts.switchboardSecretFile != nil {
    fputs("--switchboard-secret-file needs --switchboard\n", stderr); exit(64)
} else if opts.switchboardAllowSecureSetValue {
    fputs("--switchboard-allow-secure-set-value needs --switchboard\n", stderr); exit(64)
}

let auth = AuthPolicy(allowedLogins: opts.allowLogins, bearerToken: opts.token, allowLocalUnauthenticated: opts.insecureLocal)
do { try auth.validate() } catch { fputs("\(error)\n", stderr); exit(64) }

let fmt = ISO8601DateFormatter()
nonisolated(unsafe) var statusItem: StatusItemController? = nil
let log: @Sendable (String) -> Void = { msg in
    if !opts.quiet {
        FileHandle.standardError.write(Data("\(fmt.string(from: Date())) \(msg)\n".utf8))
    }
    if statusItem != nil {
        DispatchQueue.main.async { MainActor.assumeIsolated { statusItem?.observe(msg) } }
    }
}

let server = MCPServer(
    name: "oab-computer",
    version: version,
    instructions: """
        You are operating a real Mac (\(Host.current().localizedName ?? "unknown")) through its logged-in \
        desktop session; a human may be watching the screen. Work in a see→act→see loop: `screenshot`, \
        decide, `mouse`/`key`/`osascript`, then `screenshot` again to confirm — never assume an action landed.
        Coordinates: `screenshot` at the default scale 1.0 returns one pixel per display point, and `mouse` \
        takes display points, so image pixel (x,y) is the click target. To read small text (menu bar, dialogs) \
        pass `region: {x,y,width,height}` with `scale: 2`; the crop's pixel (px,py) is point \
        (region.x + px/2, region.y + py/2). Prefer `osascript` over pixel-hunting for scriptable apps \
        (activate, quit, window titles, Safari URLs). If `osascript` times out, a permission dialog is \
        probably showing: screenshot it and click Allow. `exec` is a plain `zsh -f` shell as the desktop user \
        (add `/opt/homebrew/bin` to PATH via `env` if needed) and is the right tool for files and commands; \
        for long jobs (builds) that outlive one request use `exec_start` then `exec_poll`/`exec_cancel`. \
        Call `sys_info` when unsure which permissions or displays exist. If `ui_snapshot` is available, \
        use it for native apps: it returns the window's accessibility tree (roles, titles, values, frames \
        in the same display points `mouse` takes), cheaper and more exact than reading a screenshot; fall \
        back to `screenshot` for custom-drawn content. To act on a node, call `ui_action` with its \
        `snapshot_id`, `ref` and `action` (press, set_value, focus, …): no pointer movement, no focus \
        stealing; then take a new `ui_snapshot` to confirm. Use `mouse` for drags and custom-drawn \
        content.\(opts.upstreams.isEmpty ? "" : """
         A browser is available through the `browser_*` tools (Playwright, a real window on this Mac's \
        desktop): prefer `browser_navigate` + `browser_snapshot` (accessibility tree as text) to read a \
        page, and `browser_click` / `browser_type` / `browser_fill_form` to act — they are exact and need \
        no screenshots. Fall back to `screenshot` only for things outside the browser.
        """)
        """,
    tools: ToolCatalog.local(agentVersion: version),
    upstreams: opts.upstreams.map { UpstreamMCP(name: $0.0, url: $0.1, log: log) }
)
/// Every `desktop` → `observe` mapping is recorded here as well as in the log (#59).
let auditLog = FileAuditLog(log: log)
let attachManager: AttachManager? = opts.attach
    ? AttachManager(server: server,
                    store: opts.persistGrants ? FileGrantStore(url: firstRunHome.map { FirstRunSetup.grantsURL(home: $0) }
                                                                 ?? FileGrantStore.defaultURL, log: log) : nil,
                    audit: auditLog,
                    log: log)
    : nil
// Tailnet exposure state and controls. A no-flag launch gets the opt-in page (off by default). A menu-bar launch
// with flags and a login allow list (the installer's LaunchAgent) gets the same state line and Turn Off control, and
// shows the installer's mapping as on; nothing here turns exposure on by itself in that mode either.
// First run: the login was read from Tailscale just now. Flag launch: an allow list must be configured AND a login must
// be read from Tailscale now; a configured allow list alone is not proof that a login exists at this launch.
// (Skipped under the debug-only test switch below, so test-launched binaries never run the Tailscale CLI.)
#if DEBUG
let exposureProbeSkipped = ProcessInfo.processInfo.environment["OAB_COMPUTER_NO_TAILNET_EXPOSURE"] != nil
#else
let exposureProbeSkipped = false
#endif
let exposureLoginDetected: Bool
if firstRunLaunch {
    exposureLoginDetected = firstRunLoginDetected
} else if opts.allowLogins.isEmpty || exposureProbeSkipped || !opts.menuBar {
    exposureLoginDetected = false
} else {
    exposureLoginDetected = FirstRunSetup.detectTailscaleLogin(note: { log("tailnet access: \($0)") }) != nil
    if !exposureLoginDetected { log("tailnet access: an allow list is configured but no Tailscale login could be read now; tailnet access is not offered this launch") }
}
// An installer --public-url on a port other than 8444 means the installer owns a mapping this code does not manage: leave it alone.
let installerOwnsOtherPort = !firstRunLaunch && TailnetExposure.installerOwnsOtherPort(publicURL: opts.publicURL)
// Debug builds only: the process tests set an environment variable so a test-launched binary never touches Tailscale.
// A release build has no such switch, so nothing in the environment can skip the no-login withdrawal below.
#if DEBUG
let tailnetExposureDisabledForTests = ProcessInfo.processInfo.environment["OAB_COMPUTER_NO_TAILNET_EXPOSURE"] != nil
#else
let tailnetExposureDisabledForTests = false
#endif
// Flag launches without an allow list also get the object (no login: it only withdraws a leftover mapping).
let tailnetExposure: TailnetExposure? = (firstRunLaunch || ((opts.menuBar || opts.allowLogins.isEmpty) && !installerOwnsOtherPort))
    && !tailnetExposureDisabledForTests
    ? TailnetExposure(defaults: .standard, loginDetected: exposureLoginDetected, tokenOnly: opts.allowLogins.isEmpty, backendPort: opts.port,
                      runner: FirstRunSetup.systemTailscaleCommandRunner, log: log)
    : nil
// Without a detected login this launch accepts the token alone. A leftover app-owned 8444 mapping would expose that
// to the tailnet, so it is removed before the listener starts. If it is there and cannot be removed, fail closed.
// Note: with a hung Tailscale daemon this check can delay startup by several seconds (bounded timeouts); it fails closed.
// A token-only launch also removes a mapping on 8444 that is exactly this app's own (decision of record, see design.md).
// The port-in-use check comes first, in every launch mode: a held port means another instance is serving, and the
// 8444 mapping may be its. Nothing is withdrawn or run in that case.
switch tailnetExposure?.withdrawAtLaunch(portHeld: { FirstRunSetup.isPortInUse(host: opts.host, port: opts.port) }) {
case .portHeld?:
    if firstRunLaunch {
        showFirstRunAlert(FirstRunSetup.portInUseMessage(host: opts.host, port: opts.port)); exit(75)
    }
    fputs("failed to start listener: port \(opts.port) is already in use\n", stderr); exit(2)
case .checked(.failed(let why)?)?:
    let reason = "\(why) No Tailscale login was detected, so the token alone would guard it. Start Tailscale and open OpenAB Computer again, or remove the mapping with: tailscale serve --https=8444 off"
    log("refusing to start: \(reason)")
    showFirstRunAlert("OpenAB Computer will not start: \(reason)"); exit(3)
default:
    break
}
let endpoint = MCPHTTPEndpoint(path: opts.path, server: server, auth: auth, attach: attachManager, log: log)

// Must be a global: a `let` inside `do {}` is released after the block and the
// listener's [weak self] handlers silently stop accepting connections.
let http: LoopbackHTTPServer
do {
    http = try LoopbackHTTPServer(host: opts.host, port: opts.port, endpoint: endpoint, log: log)
} catch {
    fputs("failed to start listener: \(error)\n", stderr); exit(2)
}
let startupPermissions = PermissionProbe.current()
log("oab-computer \(version) starting on http://\(opts.host):\(opts.port)\(opts.path) " +
    "auth=[logins:\(opts.allowLogins.sorted().joined(separator: ",")) token:\(opts.token != nil) insecure-local:\(opts.insecureLocal)] " +
    "attach=\(opts.attach) upstreams=[\(opts.upstreams.map { $0.0 }.joined(separator: ","))] " +
    "screen_recording=\(startupPermissions.screenRecording.isGranted) " +
    "accessibility=\(startupPermissions.accessibility.isGranted) " +
    "full_disk_access=\(startupPermissions.fullDiskAccess.isGranted)")
for line in firstRunLines { log(line) }
http.start()
if let attachManager {
    Task {
        let n = await attachManager.resume()
        if n > 0 { log("resumed \(n) reverse-attach grant(s) from the previous run") }
    }
}

// The switchboard supervisor owns the config files and the one live dialer. Saved files
// win over flags (SwitchboardStartup); the menu bar edits the saved files.
let switchboardStore = SwitchboardConfigStore(
    directory: firstRunHome.map { URL(fileURLWithPath: FirstRunSetup.configDirectory(home: $0)) }
        ?? SwitchboardConfigStore.defaultDirectory)
let switchboardAllowSecure = opts.switchboardAllowSecureSetValue
// The secret file named by the flags, readable or not. Saved files apply only when the
// flags name the installer's file, or when this is a menu bar process with no flags.
let switchboardFlagFile: URL? = opts.switchboardSecretFile.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
let switchboardSavedApply = SwitchboardStartup.savedFilesApply(
    flagSecretFile: switchboardFlagFile, menuBar: opts.menuBar, store: switchboardStore)
let switchboardSaved: SwitchboardConfigStore.Loaded = switchboardSavedApply ? switchboardStore.inspect() : .absent
let switchboardStartup = SwitchboardStartup.resolve(
    saved: switchboardSaved.config,
    flags: switchboardTarget.map {
        SwitchboardConfig(url: $0.url, secret: $0.secret, profile: opts.switchboardProfile,
                          requestedProfile: opts.switchboardRequestedProfile,
                          profileWarning: opts.switchboardRequestedProfile == nil ? nil : ToolProfile.retiredWarning)
    },
    flagsGiven: opts.switchboard != nil,
    unsealed: switchboardSaved.unsealed)
if let warning = switchboardStartup.warning { log(warning) }
// The profile mapping is logged and audited for whichever source won (#59).
if let cfg = switchboardStartup.config, let warning = cfg.profileWarning {
    log("switchboard: \(warning)")
    auditLog.append(ProfileAudit.mapped(source: switchboardStartup.mode == .saved ? "switchboard-saved" : "switchboard",
                                        requested: cfg.requestedProfile, profile: cfg.profile))
}
let switchboardSupervisor = SwitchboardSupervisor(
    store: switchboardStore,
    computer: Host.current().localizedName ?? "this Mac",
    managesSaved: switchboardSavedApply,
    factory: { cfg, onState in
        // The secret file is re-read on every dial: the installer's saved file when saved files
        // apply, otherwise the file the flags name.
        let secretFile = switchboardSavedApply ? switchboardStore.secretFile : (switchboardFlagFile ?? switchboardStore.secretFile)
        return Switchboard.client(url: cfg.url, secretFile: secretFile, secret: cfg.secret, profile: cfg.profile,
                                  server: server, allowSecureSetValue: switchboardAllowSecure,
                                  onStateChange: onState, log: log)
    },
    log: log)
if let cfg = switchboardStartup.config {
    log("switchboard: \(switchboardStartup.mode == .saved ? "saved" : "flagged") config, profile \(cfg.profile.rawValue)" +
        (cfg.requestedProfile != cfg.profile.rawValue ? " (requested \(cfg.requestedProfile))" : "") +
        (cfg.profile.allows("ui_action")
            ? " secure_set_value=\(switchboardAllowSecure ? "allowed" : "refused")" : ""))
}
Task {
    await switchboardSupervisor.applyStartup(switchboardStartup)
    if let cfg = switchboardStartup.config { await switchboardSupervisor.start(cfg) }
}

signal(SIGPIPE, SIG_IGN)
let stop = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGTERM, SIG_IGN)
stop.setEventHandler { log("SIGTERM, exiting"); exit(0) }
stop.resume()

if opts.menuBar {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)     // no Dock icon, no main menu; status item only
    let logPath = FirstRunSetup.logPath(home: firstRunHome ?? NSHomeDirectory())
    let exposure = tailnetExposure
    // With the exposure object the menu takes the tailnet URL from it (verified), so the base line is the local one.
    let publicURL = (exposure == nil ? opts.publicURL : nil) ?? "http://\(opts.host):\(opts.port)\(opts.path)"
    statusItem = MainActor.assumeIsolated {
        StatusItemController(version: version, url: publicURL, logPath: logPath, token: opts.token,
                             attach: attachManager, switchboard: switchboardSupervisor, notice: firstRunNotice,
                             exposure: exposure, bindHost: opts.host, bindPort: Int(opts.port), path: opts.path,
                             upstreams: opts.upstreams.map { NetworkUpstream(name: $0.0, url: $0.1) },
                             attachEnabled: opts.attach)
    }
    // A stored opt-in is re-applied once per launch, off the main thread, and only when the mapping is missing.
    if let exposure {
        DispatchQueue.global(qos: .utility).async {
            defer { exposure.markLaunchReadDone() }
            if exposure.reapplyAtLaunch() == nil { exposure.adoptExistingMapping() }
        }
    }
    Task {
        await switchboardSupervisor.setOnChange { s in
            DispatchQueue.main.async { MainActor.assumeIsolated { statusItem?.switchboardStatus = s } }
        }
    }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { statusItem?.showPermissionSetupIfNeeded() }
    }
    app.run()
} else {
    RunLoop.main.run()
}
