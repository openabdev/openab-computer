import Foundation

// Screen Recording relaunch (design Q3). macOS keeps reporting Screen Recording as off to a running process until the
// app is quit and reopened, even after the user turns it on. A fresh child process of the same executable reads the
// live answer, so the wizard can see the grant and relaunch the app by itself, then resume on the same page.

/// The hidden, non-public argument the wizard's child process runs. It is not listed in `--help`.
public enum PermissionCheckCommand {
    public static let argument = "--internal-check-screen-recording"

    /// True when the whole argument list (after the executable name) is exactly the hidden argument.
    public static func isInvocation(_ arguments: [String]) -> Bool {
        arguments == [argument]
    }

    /// 0 when Screen Recording is granted, 1 when it is not. The reader has no request or capture method, so this
    /// cannot prompt or capture. It prints nothing.
    public static func exitCode(reader: CorePermissionReading) -> Int32 {
        reader.screenRecordingGranted() ? 0 : 1
    }
}

public enum ChildCheckResult: Equatable, Sendable {
    case granted
    /// The child ran and reported Screen Recording off.
    case denied
    /// Spawn error, timeout, a signal, or an exit code other than 0 and 1.
    case failed
}

/// Runs the executable with the hidden argument and maps its exit status. Output is discarded and never read.
public enum ChildPermissionCheck {
    public static func run(executable: URL, arguments: [String] = [PermissionCheckCommand.argument],
                           timeout: TimeInterval = 3) -> ChildCheckResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .failed }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                // Give SIGTERM a moment, then make sure the child is gone.
                let grace = Date().addingTimeInterval(0.5)
                while process.isRunning && Date() < grace { usleep(10_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                return .failed
            }
            usleep(10_000)
        }
        guard process.terminationReason == .exit else { return .failed }
        switch process.terminationStatus {
        case 0: return .granted
        case 1: return .denied
        default: return .failed
        }
    }
}

/// When the wizard runs the child check: every 2 seconds for about 2 minutes after Allow, then every 15 seconds,
/// and not at all after 10 minutes (the next Allow, Check Again, or app activation starts a new window of checks).
public enum ChildCheckSchedule {
    public static let fastInterval: TimeInterval = 2
    public static let slowInterval: TimeInterval = 15
    public static let backoffAfter: TimeInterval = 120
    public static let hardCap: TimeInterval = 600

    /// The timer runs only while Screen Recording was requested, is not yet granted, and the window is visible.
    /// The window must call this again after it becomes visible, because a close invalidates the timer.
    public static func shouldRun(requested: Bool, granted: Bool, windowVisible: Bool) -> Bool {
        requested && !granted && windowVisible
    }

    public static func interval(elapsed: TimeInterval) -> TimeInterval? {
        if elapsed < backoffAfter { return fastInterval }
        if elapsed < hardCap { return slowInterval }
        return nil
    }
}

public enum RelaunchAction: Equatable, Sendable {
    case none
    /// Show the "Restart OpenAB Computer" button on the Screen Recording row.
    case showRestart
}

public enum RelaunchPolicy {
    /// What the Screen Recording row does about the restart. A child that reports granted is not handled here: the
    /// row shows its check mark at once (no relaunch), and the restart waits for Finish (`shouldRelaunchOnFinish`).
    /// - child: the latest child check, nil before the first one.
    /// - processGranted: what the running process reports.
    /// - userConfirmedEnabled: the user pressed Check Again, which says the switch is on.
    public static func decide(child: ChildCheckResult?, processGranted: Bool,
                              userConfirmedEnabled: Bool) -> RelaunchAction {
        if processGranted { return .none }
        switch child {
        case nil, .granted?: return .none
        case .failed?: return .showRestart
        case .denied?: return userConfirmedEnabled ? .showRestart : .none
        }
    }

    /// The row shows the restart state when the policy asks for the button. A granted row is never overridden.
    public static func effectiveRow(base: RowState, action: RelaunchAction) -> RowState {
        guard action == .showRestart, base != .allowed else { return base }
        return .needsRestart
    }

    /// The Screen Recording state the wizard shows: granted when this process says so, or when a fresh child process
    /// does. The check mark never waits for a restart, so the flow still works if the user chose Later in the macOS
    /// "Quit & Reopen" dialog.
    public static func shownScreenRecording(process: PermissionState, child: ChildCheckResult?) -> PermissionState {
        process == .denied && child == .granted ? .granted : process
    }

    /// At Finish: relaunch once, silently, when the child confirmed the grant and this process still reports off, so
    /// the backend that captures the screen starts after the grant. A process that already reports granted skips it,
    /// and so does a grant whose automatic relaunch was already spent.
    public static func shouldRelaunchOnFinish(child: ChildCheckResult?, processGranted: Bool,
                                              autoRelaunchSpent: Bool) -> Bool {
        !processGranted && child == .granted && !autoRelaunchSpent
    }
}

/// Requests one relaunch (at Finish, or from the fallback button). It writes the resume state first, starts the new instance, and only then quits.
/// `launch` returns false when the new instance could not be started; the old one then keeps running.
public final class RelaunchCoordinator {
    private let store: SetupWizardStore
    private let launch: () -> Bool
    private let terminate: () -> Void
    private var requested = false

    public init(store: SetupWizardStore, launch: @escaping () -> Bool, terminate: @escaping () -> Void) {
        self.store = store
        self.launch = launch
        self.terminate = terminate
    }

    /// An automatic request is refused when one was already spent for this grant, so a grant that the new
    /// instance still reports as off cannot loop. Either kind is refused once this process has requested one.
    @discardableResult
    public func requestRelaunch(page: WizardPage?, automatic: Bool) -> Bool {
        guard !requested else { return false }
        if automatic && store.autoRelaunchSpent { return false }
        store.recordRelaunch(page: page)
        requested = true
        guard launch() else {
            store.clearResume()
            requested = false
            return false
        }
        terminate()
        return true
    }
}

public extension FirstRunSetup {
    /// Polls until nothing listens on host:port, or the timeout passes. Returns whether the port is free.
    static func waitForPortFree(host: String, port: UInt16, timeout: TimeInterval,
                                pollInterval: TimeInterval = 0.1) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isPortInUse(host: host, port: port) {
            if Date() >= deadline { return false }
            usleep(UInt32(pollInterval * 1_000_000))
        }
        return true
    }
}
