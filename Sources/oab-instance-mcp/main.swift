import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import InstanceMCPCore

let version = "0.8.4"

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
}

func usage() -> Never {
    print("""
    oab-instance-mcp \(version) — MCP server exposing this Mac (exec / screenshot / ui_snapshot / mouse / key / osascript / sys_info)

    USAGE: oab-instance-mcp [--host 127.0.0.1] [--port 8795] [--path /mcp]
                        [--allow-login <email>]... [--token <str> | --token-file <path>]
                        [--insecure-local] [--quiet] [--menu-bar] [--public-url <https://…/mcp>]

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
                      saved (record: ~/Library/Application Support/oab-instance-mcp/grants.json,
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
      --menu-bar      Show a status item in the menu bar (permissions, activity, restart/quit).
      --public-url    The URL clients use (shown/copied from the menu); defaults to the local one.

    Run it as a LaunchAgent in the logged-in user's GUI session (gui/<uid>), not a
    LaunchDaemon — screenshot and input tools need the Aqua session and TCC grants.
    """)
    exit(64)
}

var opts = Options()
var args = Array(CommandLine.arguments.dropFirst())
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
    guard let s = try? String(contentsOf: file, encoding: .utf8),
          !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        fputs("cannot read --switchboard-secret-file \(f), or it is empty\n", stderr); exit(66)
    }
    switchboardTarget = (url, file, s.trimmingCharacters(in: .whitespacesAndNewlines))
} else if opts.switchboardSecretFile != nil {
    fputs("--switchboard-secret-file needs --switchboard\n", stderr); exit(64)
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
    name: "oab-instance-mcp",
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
        back to `screenshot` for custom-drawn content.\(opts.upstreams.isEmpty ? "" : """
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
if let requested = opts.switchboardRequestedProfile, switchboardTarget != nil {
    auditLog.append(ProfileAudit.mapped(source: "switchboard", requested: requested, profile: opts.switchboardProfile))
}
let attachManager: AttachManager? = opts.attach
    ? AttachManager(server: server,
                    store: opts.persistGrants ? FileGrantStore(log: log) : nil,
                    audit: auditLog,
                    log: log)
    : nil
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
log("oab-instance-mcp \(version) starting on http://\(opts.host):\(opts.port)\(opts.path) " +
    "auth=[logins:\(opts.allowLogins.sorted().joined(separator: ",")) token:\(opts.token != nil) insecure-local:\(opts.insecureLocal)] " +
    "attach=\(opts.attach) upstreams=[\(opts.upstreams.map { $0.0 }.joined(separator: ","))] " +
    "screen_recording=\(startupPermissions.screenRecording.isGranted) " +
    "accessibility=\(startupPermissions.accessibility.isGranted) " +
    "full_disk_access=\(startupPermissions.fullDiskAccess.isGranted)")
http.start()
if let attachManager {
    Task {
        let n = await attachManager.resume()
        if n > 0 { log("resumed \(n) reverse-attach grant(s) from the previous run") }
    }
}

// Global for the same reason as `http`: the client must outlive this scope.
let switchboardClient: ReverseAttachClient? = switchboardTarget.map { t in
    Switchboard.client(url: t.url, secretFile: t.file, secret: t.secret, profile: opts.switchboardProfile,
                       server: server, log: log)
}
if let switchboardClient, let t = switchboardTarget {
    log("switchboard: dialling \(t.url.absoluteString) as \(opts.switchboardProfile.rawValue)" +
        (opts.switchboardRequestedProfile.map { " (requested \($0))" } ?? ""))
    Task { await switchboardClient.start() }
}

signal(SIGPIPE, SIG_IGN)
let stop = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGTERM, SIG_IGN)
stop.setEventHandler { log("SIGTERM, exiting"); exit(0) }
stop.resume()

if opts.menuBar {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)     // no Dock icon, no main menu; status item only
    let logPath = NSHomeDirectory() + "/Library/Logs/oab-instance-mcp/agent.log"
    let publicURL = opts.publicURL ?? "http://\(opts.host):\(opts.port)\(opts.path)"
    statusItem = MainActor.assumeIsolated {
        StatusItemController(version: version, url: publicURL, logPath: logPath, token: opts.token)
    }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { statusItem?.showPermissionSetupIfNeeded() }
    }
    app.run()
} else {
    RunLoop.main.run()
}
