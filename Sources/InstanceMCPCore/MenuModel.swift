import Foundation

/// Whether this process is a launchd job, and what the menu says and does because of it.
public enum LaunchdJob {
    /// launchd sets `XPC_SERVICE_NAME` to the job label for the jobs it starts. The variable also exists elsewhere:
    /// it is "0" in a terminal session, and an app opened from Finder or `open` gets "application.<bundle id>.<n>.<n>".
    /// Neither of those is a job we can boot out, so only a real job label counts. The parent pid is no help here:
    /// launchd is pid 1 and the parent of Finder launches too.
    ///
    /// The variable is inherited by every child of a job, so a shell inside another LaunchAgent (an Actions runner, a
    /// coding agent) carries that job's label. Only this app's own label counts: booting out any other would stop an
    /// unrelated service, and a restart would wait for a KeepAlive that does not exist.
    public static let ownLabel = "dev.openab.instance-mcp"

    public static func jobLabel(environment: [String: String]) -> String? {
        guard let name = environment["XPC_SERVICE_NAME"], name == ownLabel else { return nil }
        return name
    }

    public static func isRunByLaunchd(environment: [String: String]) -> Bool {
        jobLabel(environment: environment) != nil
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

/// The tailnet lines of the menu bar item.
public struct TailnetMenu: Equatable, Sendable {
    /// "Tailnet access: On" or "Tailnet access: Off"; nil when the Mac has no detected login and it is not on.
    public let stateLine: String?
    public let actionTitle: String?
    public let action: TailnetMenuAction?
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
    /// instead of a plain "Off", and the action stays "Allow…" so the user can retry from the wizard.
    public static func tailnetMenu(offered: Bool, publicURL: String?, optedIn: Bool = false) -> TailnetMenu {
        if publicURL != nil {
            return TailnetMenu(stateLine: "Tailnet access: On", actionTitle: "Turn Off Tailnet Access", action: .turnOff)
        }
        if offered {
            if optedIn {
                return TailnetMenu(stateLine: "Tailnet access: not applied (see the log)", actionTitle: "Allow tailnet access…", action: .allow)
            }
            return TailnetMenu(stateLine: "Tailnet access: Off", actionTitle: "Allow tailnet access…", action: .allow)
        }
        return TailnetMenu(stateLine: nil, actionTitle: nil, action: nil)
    }
}
