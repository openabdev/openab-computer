import Foundation

public enum PlaywrightInstallStep: String, Sendable, Equatable {
    case preflight, downloadNode, downloadChromium, extract, signature, packages, healthCheck, commit, switchOver
}

public struct PlaywrightInstallProgress: Equatable, Sendable {
    public let step: PlaywrightInstallStep
    /// 0...1 for a download, nil for a step with no measure.
    public let fraction: Double?
    public init(step: PlaywrightInstallStep, fraction: Double?) { self.step = step; self.fraction = fraction }
}

/// Everything an install can end in. Values carry numbers or nothing, never text from the
/// network, an archive, a child process or an `Error`: `errorClass` is the only string that
/// reaches a log.
public enum PlaywrightInstallFailure: Error, Equatable, Sendable {
    case offline
    case interrupted
    case tls
    case digestMismatch
    case notEnoughDisk(needed: Int64, available: Int64)
    case archiveRejected
    case nodeSignature
    case launchRefused
    case lockHeld
    case cancelled
    case healthCheckFailed
    /// A fixed class chosen by the installer (never derived from external text).
    case other(String)

    public var errorClass: String {
        switch self {
        case .offline: return "offline"
        case .interrupted: return "interrupted"
        case .tls: return "tls"
        case .digestMismatch: return "digest_mismatch"
        case .notEnoughDisk: return "not_enough_disk"
        case .archiveRejected: return "archive_rejected"
        case .nodeSignature: return "node_signature"
        case .launchRefused: return "launch_refused"
        case .lockHeld: return "lock_held"
        case .cancelled: return "cancelled"
        case .healthCheckFailed: return "health_check_failed"
        case .other(let c): return c
        }
    }
}

public enum PlaywrightInstallState: Equatable, Sendable {
    case notInstalled
    case installed(id: String, updateAvailable: Bool, stale: Bool)
    /// `install.json` is present but unusable.
    case invalid
}

/// The only way the installer writes a log line: an event name and fixed-shape values, matching
/// `^browser: [a-z_]+( [a-z]+=[A-Za-z0-9_.-]+)*$` (R8.1).
enum InstallLogEvent {
    case installStart(id: String)
    case step(PlaywrightInstallStep)
    case installOK(id: String)
    case installFailed(String)
    /// The install drives the user's installed Google Chrome instead of downloading Chromium.
    case chromeInstall
    case updateRolledBack
    case removed
    case swept(Int)

    var line: String {
        switch self {
        case .installStart(let id): return "browser: playwright_install_start id=\(Self.safe(id))"
        case .step(let s): return "browser: playwright_install_step step=\(s.rawValue)"
        case .installOK(let id): return "browser: playwright_install_ok id=\(Self.safe(id))"
        case .chromeInstall: return "browser: playwright_install_engine engine=installed_chrome"
        case .installFailed(let c): return "browser: playwright_install_failed class=\(Self.safe(c))"
        case .updateRolledBack: return "browser: playwright_update_rolled_back"
        case .removed: return "browser: playwright_removed"
        case .swept(let n): return "browser: playwright_swept count=\(n)"
        }
    }

    /// Only characters the log pattern allows; anything else becomes `_`.
    private static func safe(_ s: String) -> String {
        String(s.unicodeScalars.prefix(96).map { c in
            (c.isASCII && (CharacterSet.alphanumerics.contains(c) || c == "_" || c == "." || c == "-")) ? Character(c) : "_"
        })
    }
}
