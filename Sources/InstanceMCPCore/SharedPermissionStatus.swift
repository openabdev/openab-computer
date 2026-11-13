import Foundation

// One permission status for the menu bar item and the setup wizard. macOS keeps reporting Screen Recording as off to an
// already-running process until it restarts (design Q3), while a fresh child process of the same executable reads the
// live answer. Both surfaces resolve through `SharedPermissionStatus`, so they cannot show different text for the same
// inputs.

/// The permissions as shown to the user, plus whether Screen Recording is in the stale state.
public struct ResolvedPermissions: Equatable, Sendable {
    /// What both surfaces display.
    public var shown: PermissionSnapshot
    /// What the running process itself reports for Screen Recording.
    public var processScreenRecording: PermissionState

    public init(shown: PermissionSnapshot, processScreenRecording: PermissionState) {
        self.shown = shown
        self.processScreenRecording = processScreenRecording
    }

    /// Shown as granted although the running process still reports off: only a restart applies the grant.
    public var screenRecordingStale: Bool {
        processScreenRecording == .denied && shown.screenRecording == .granted
    }
}

public enum SharedPermissionStatus {
    /// Screen Recording counts as granted when this process says so OR a fresh child probe does. Any other process
    /// answer (denied without a granted child, unknown) is kept as it is.
    public static func screenRecording(process: PermissionState, child: ChildCheckResult?) -> PermissionState {
        process == .denied && child == .granted ? .granted : process
    }

    /// Accessibility and Full Disk Access keep the process's own answer; they pass through here so every caller reads
    /// the one function.
    public static func resolve(process: PermissionSnapshot, child: ChildCheckResult?) -> ResolvedPermissions {
        var shown = process
        shown.screenRecording = screenRecording(process: process.screenRecording, child: child)
        return ResolvedPermissions(shown: shown, processScreenRecording: process.screenRecording)
    }

    /// The extra menu line, present exactly in the stale state.
    public static func menuRestartLine(_ resolved: ResolvedPermissions) -> String? {
        resolved.screenRecordingStale ? WizardCopy.menuRestartLine : nil
    }
}

/// Caches the latest child-probe result for a few seconds so opening the menu stays fast. The probe never runs on the
/// calling thread and never on the main thread: it is dispatched to `queue`, and skipped if that queue is the main
/// thread. The probe itself cannot prompt or capture (`PermissionCheckCommand` has no request or capture path).
public final class ScreenRecordingProbeCache: @unchecked Sendable {
    public static let defaultTTL: TimeInterval = 5

    /// The app-wide cache, probing the running executable.
    public static let shared = ScreenRecordingProbeCache(probe: {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return ChildPermissionCheck.run(executable: executable)
    })

    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let queue: DispatchQueue
    private let probe: @Sendable () -> ChildCheckResult
    private let lock = NSLock()
    private var result: ChildCheckResult?
    private var checkedAt: Date?
    private var inFlight = false

    public init(ttl: TimeInterval = ScreenRecordingProbeCache.defaultTTL,
                now: @escaping @Sendable () -> Date = { Date() },
                queue: DispatchQueue = DispatchQueue(label: "dev.openab.permission-probe", qos: .utility),
                probe: @escaping @Sendable () -> ChildCheckResult) {
        self.ttl = ttl
        self.now = now
        self.queue = queue
        self.probe = probe
    }

    /// The latest result, nil before the first probe. Never blocks on a probe.
    public var latest: ChildCheckResult? {
        lock.lock(); defer { lock.unlock() }
        return result
    }

    /// Stores a result obtained elsewhere (the wizard's own scheduled check) and restarts the freshness window.
    public func record(_ value: ChildCheckResult) {
        lock.lock(); defer { lock.unlock() }
        store(value)
    }

    /// Forgets the result, for example when the user starts a new Allow round.
    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        result = nil
        checkedAt = nil
    }

    /// Starts a probe off the main thread unless a result younger than the TTL exists or one is already running.
    /// `completion` runs on the probe queue.
    public func refreshIfStale(completion: (@Sendable (ChildCheckResult?) -> Void)? = nil) {
        lock.lock()
        if inFlight || (checkedAt.map { now().timeIntervalSince($0) < ttl } ?? false) {
            lock.unlock()
            return
        }
        inFlight = true
        lock.unlock()
        queue.async { [self] in
            // A probe on the main thread would block the UI: report nothing instead.
            let value: ChildCheckResult? = Thread.isMainThread ? nil : probe()
            lock.lock()
            if let value { store(value) }
            inFlight = false
            lock.unlock()
            completion?(value)
        }
    }

    /// A confirmed grant is not undone by one probe that could not answer. Caller holds the lock.
    private func store(_ value: ChildCheckResult) {
        if !(value == .failed && result == .granted) { result = value }
        checkedAt = now()
    }
}
