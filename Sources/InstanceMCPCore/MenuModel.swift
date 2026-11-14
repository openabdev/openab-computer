import Foundation

/// Whether this process is a launchd job, and what the menu says and does because of it.
public enum LaunchdJob {
    /// launchd sets `XPC_SERVICE_NAME` to the job label for the jobs it starts. The variable also exists elsewhere:
    /// it is "0" in a terminal session, and an app opened from Finder or `open` gets "application.<bundle id>.<n>.<n>".
    /// Neither of those is a job we can boot out, so only a real job label counts. The parent pid alone is no help:
    /// launchd is pid 1 and the parent of Finder launches too, so it is checked in addition to the label.
    ///
    /// The variable is inherited by every child of a job, so a shell inside another LaunchAgent (an Actions runner, a
    /// coding agent) carries that job's label. Only this app's own label counts: booting out any other would stop an
    /// unrelated service, and a restart would wait for a KeepAlive that does not exist.
    public static let ownLabel = "dev.openab.computer"

    /// A child of this app (a second copy started through the exec tool) inherits the label too, but its parent is the
    /// app, not launchd (pid 1), so the parent pid must be 1 as well.
    public static func jobLabel(environment: [String: String], parentPID: Int32 = getppid()) -> String? {
        guard parentPID == 1, let name = environment["XPC_SERVICE_NAME"], name == ownLabel else { return nil }
        return name
    }

    /// The environment for a process this app starts (the relaunch waiter, exec'd children). `XPC_SERVICE_NAME` is
    /// removed so an orphan of ours, reparented to launchd, cannot be mistaken for the launchd job.
    public static func childEnvironment(_ environment: [String: String]) -> [String: String] {
        var env = environment
        env.removeValue(forKey: "XPC_SERVICE_NAME")
        return env
    }

    public static func isRunByLaunchd(environment: [String: String], parentPID: Int32 = getppid()) -> Bool {
        jobLabel(environment: environment, parentPID: parentPID) != nil
    }
}

/// What "Restart Agent" does.
public enum RestartPlan: Equatable, Sendable {
    /// A launchd job with KeepAlive: exiting is the restart. launchctl is not involved.
    case exitForKeepAlive
    /// No launchd job: the relaunch coordinator starts the new instance after this one frees the port, then quits.
    case relaunchCoordinator
}

public struct SwitchboardMenuEnablement: Equatable, Sendable {
    public let configure: Bool
    public let reconnect: Bool
    public let forget: Bool
}

public enum TailnetMenuAction: Equatable, Sendable {
    case allow
    case turnOff
}

/// The extra action for a mapping that exists but was not set up through this app.
public enum TailnetManageAction: Equatable, Sendable {
    case manage
}

/// The tailnet lines of the menu bar item.
public struct TailnetMenu: Equatable, Sendable {
    /// "Tailnet access: On" or "Tailnet access: Off"; nil when the Mac has no detected login and it is not on.
    public let stateLine: String?
    public let actionTitle: String?
    public let action: TailnetMenuAction?
    /// Set only for an existing mapping that this app did not set up: records the opt-in when chosen.
    public var manageTitle: String? = nil
}

public enum MenuModel {
    public static func quitTitle(underLaunchd: Bool) -> String {
        underLaunchd ? "Quit Agent (stops launchd job)" : "Quit OpenAB Computer"
    }

    public static func restartPlan(underLaunchd: Bool) -> RestartPlan {
        underLaunchd ? .exitForKeepAlive : .relaunchCoordinator
    }

    /// With no config there is nothing to reconnect or forget. A process dialling from explicit flags cannot edit the
    /// saved files, so Configure and Forget are off there.
    public static func switchboardEnablement(_ status: SwitchboardStatus?) -> SwitchboardMenuEnablement {
        let hasConfig = status?.hasConfig ?? false
        let managesSaved = status?.managesSaved ?? false
        return SwitchboardMenuEnablement(configure: managesSaved, reconnect: hasConfig, forget: hasConfig && managesSaved)
    }

    /// Restart Agent. The launchd path exits and lets KeepAlive start the app; every other path goes through the
    /// relaunch coordinator (one request per launch, new instance started after this one frees the port). Neither
    /// path runs launchctl. Returns false when the coordinator refused or could not start the new instance.
    @discardableResult
    public static func restart(underLaunchd: Bool, relaunch: () -> Bool, exitProcess: () -> Void) -> Bool {
        switch restartPlan(underLaunchd: underLaunchd) {
        case .exitForKeepAlive:
            exitProcess()
            return true
        case .relaunchCoordinator:
            return relaunch()
        }
    }

    /// Quit. Only a launchd job is booted out (it would be restarted otherwise); anything else just exits.
    public static func quit(jobLabel: String?, bootout: (String) -> Void, exitProcess: () -> Void) {
        if let jobLabel { bootout(jobLabel) } else { exitProcess() }
    }

    /// `optedIn`: the stored choice is on but no verified mapping exists (a failed launch re-apply); the line says so
    /// instead of a plain "Off", and the action is "Turn Off" (it clears the choice and removes our own mapping if there is one).
    public static func tailnetMenu(offered: Bool, publicURL: String?, optedIn: Bool = false, existingMapping: Bool = false) -> TailnetMenu {
        if publicURL != nil, existingMapping, !optedIn {
            return TailnetMenu(stateLine: "Tailnet access: On (existing mapping, not managed by this app)",
                               actionTitle: "Turn Off Tailnet Access", action: .turnOff, manageTitle: "Manage with this app")
        }
        if publicURL != nil {
            return TailnetMenu(stateLine: "Tailnet access: On", actionTitle: "Turn Off Tailnet Access", action: .turnOff)
        }
        if offered {
            if optedIn {
                return TailnetMenu(stateLine: "Tailnet access: not confirmed (see the log)", actionTitle: "Turn Off Tailnet Access", action: .turnOff)
            }
            return TailnetMenu(stateLine: "Tailnet access: Off", actionTitle: "Allow tailnet access…", action: .allow)
        }
        return TailnetMenu(stateLine: nil, actionTitle: nil, action: nil)
    }
}

// MARK: Network section

/// How the Tailnet row sees the exposure. Built from the same inputs as `tailnetMenu`.
public enum NetworkTailnetState: Equatable, Sendable {
    case off
    case on(url: String)
    /// A mapping exists that this app did not set up.
    case onExisting(url: String)
    case optedInNotApplied
    /// The launch's first serve-status read has not finished: no definite value yet.
    case checking
    /// Tailscale status was read and could not be understood, so "Off" would be a guess.
    case unknown
    /// The app has no Tailscale state of its own (an installer owns another port); it checked nothing.
    case notChecked
}

public struct NetworkUpstream: Equatable, Sendable {
    public let name: String
    public let url: URL
    public init(name: String, url: URL) { self.name = name; self.url = url }
}

/// The Switchboard row's input: the supervisor's status (nil until it reports) and how to print a time.
public struct NetworkSwitchboard {
    public let status: SwitchboardStatus?
    public let now: Date
    public let timeText: (Date) -> String
    public init(status: SwitchboardStatus?, now: Date = Date(), timeText: @escaping (Date) -> String) {
        self.status = status; self.now = now; self.timeText = timeText
    }
    public var text: String {
        guard let status else { return "Switchboard: starting…" }
        return status.title(now: now, timeText: timeText)
    }
}

public struct NetworkRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case localMCP, tailnet, publicURL, browser, switchboard, reverseAttach }
    public let kind: Kind
    public let text: String
    /// Set for rows a click copies: the local URL, and the tailnet URL when there is one.
    public let copyValue: String?
}

public struct NetworkSection: Equatable, Sendable {
    public let header: String
    public let rows: [NetworkRow]
}

extension MenuModel {
    public static func networkTailnetState(publicURL: String?, optedIn: Bool,
                                           existingMapping: Bool, uncertain: Bool,
                                           checking: Bool = false) -> NetworkTailnetState {
        // Until the launch's first serve-status read finishes, nothing definite may be shown.
        if checking { return .checking }
        if let publicURL {
            return existingMapping && !optedIn ? .onExisting(url: publicURL) : .on(url: publicURL)
        }
        if optedIn { return .optedInNotApplied }
        if uncertain { return .unknown }
        return .off
    }

    /// The `--public-url` row input: the configured URL when it is not the local one. It is shown as configured
    /// and never feeds the Tailnet row, which comes only from Tailscale state.
    public static func configuredPublicURL(publicURL: String, localURL: String) -> String? {
        publicURL == localURL ? nil : publicURL
    }

    /// Tailnet state when the app has no Tailscale state of its own (an installer owns another port). Nothing
    /// confirms or rules out a mapping to this app, so it is unknown, never Off. A --public-url stays on its
    /// own unchecked Public URL row.
    public static func tailnetStateWithoutExposure(publicURL: String?) -> NetworkTailnetState {
        .notChecked
    }

    /// An installer launch (allow list, so not token-only) whose Tailscale login could not be read: the tailnet
    /// state is unknown, not off.
    public static func tailnetStatusUnreadable(offered: Bool, tokenOnly: Bool) -> Bool {
        !offered && !tokenOnly
    }

    /// True only for 127.0.0.0/8, ::1 and localhost. Anything else, including a host that does not parse, is not
    /// loopback: the safer reading for a row that says who can reach the port.
    public static func isLoopbackHost(_ host: String) -> Bool {
        var h = host.trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if h == "localhost" || h == "::1" { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && Int($0) != nil && Int($0)! <= 255 })
        else { return false }
        return parts[0] == "127"
    }

    public static func hostForURL(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    public static func networkSection(bindHost: String, bindPort: Int, path: String,
                                      upstreams: [NetworkUpstream], tailnet: NetworkTailnetState,
                                      switchboard: NetworkSwitchboard?, liveGrants: Int?, attachEnabled: Bool,
                                      publicURL: String? = nil) -> NetworkSection {
        var rows: [NetworkRow] = []

        let localURL = "http://\(hostForURL(bindHost)):\(bindPort)\(path)"
        let reach = isLoopbackHost(bindHost) ? "(this Mac only)" : "⚠ (reachable from other devices)"
        rows.append(NetworkRow(kind: .localMCP, text: "Local MCP: \(localURL) \(reach)", copyValue: localURL))

        switch tailnet {
        case .off:
            rows.append(NetworkRow(kind: .tailnet, text: "Tailnet: Off", copyValue: nil))
        case .on(let url):
            rows.append(NetworkRow(kind: .tailnet, text: "Tailnet: On, \(url) (your tailnet only)", copyValue: url))
        case .onExisting(let url):
            rows.append(NetworkRow(kind: .tailnet, text: "Tailnet: On (existing mapping, not managed by this app), \(url)", copyValue: url))
        case .optedInNotApplied:
            rows.append(NetworkRow(kind: .tailnet, text: "Tailnet: opted in, not applied (see the log)", copyValue: nil))
        case .unknown:
            rows.append(NetworkRow(kind: .tailnet, text: "Tailnet: unknown (Tailscale status unreadable)", copyValue: nil))
        case .notChecked:
            rows.append(NetworkRow(kind: .tailnet, text: "Tailnet: unknown (not checked by this app)", copyValue: nil))
        case .checking:
            rows.append(NetworkRow(kind: .tailnet, text: "Tailnet: checking…", copyValue: nil))
        }

        if let publicURL {
            rows.append(NetworkRow(kind: .publicURL, text: "Public URL: \(publicURL) (as configured with --public-url, not checked)",
                                   copyValue: publicURL))
        }

        if let browser = upstreams.first(where: { $0.name == "browser" }) {
            let host = browser.url.host ?? ""
            let address = browser.url.port.map { "\(hostForURL(host)):\($0)" } ?? hostForURL(host)
            let who = isLoopbackHost(host) ? "(separate process, this Mac only)" : "(remote)"
            rows.append(NetworkRow(kind: .browser, text: "Browser tools: \(address) \(who)", copyValue: nil))
        }

        if let switchboard {
            rows.append(NetworkRow(kind: .switchboard, text: switchboard.text, copyValue: nil))
        }

        if !attachEnabled {
            rows.append(NetworkRow(kind: .reverseAttach, text: "Reverse attach: off", copyValue: nil))
        } else if let n = liveGrants {
            rows.append(NetworkRow(kind: .reverseAttach, text: "Reverse attach: \(n) live grant\(n == 1 ? "" : "s")", copyValue: nil))
        } else {
            rows.append(NetworkRow(kind: .reverseAttach, text: "Reverse attach: on", copyValue: nil))
        }
        return NetworkSection(header: "Network", rows: rows)
    }
}
