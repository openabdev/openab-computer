import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The switchboard settings this daemon dials with. The secret is held in memory
/// for a dial and is never shown or logged.
public struct SwitchboardConfig: Equatable, Sendable {
    public var url: URL
    public var secret: String
    public var profile: ToolProfile
    /// The profile name as written (a flag or `switchboard.profile`), when it differs from `profile`.
    public var requestedProfile: String
    /// Set when the name was mapped or not recognised (`desktop` → `observe`, #59). Logged, audited and shown.
    public var profileWarning: String?

    public init(url: URL, secret: String, profile: ToolProfile,
                requestedProfile: String? = nil, profileWarning: String? = nil) {
        self.url = url; self.secret = secret; self.profile = profile
        self.requestedProfile = requestedProfile ?? profile.rawValue
        self.profileWarning = profileWarning
    }
}

/// Never prints the secret, so a config in a log line, a debugger or an assertion
/// message shows the URL and profile only.
extension SwitchboardConfig: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "SwitchboardConfig(url: \(url.absoluteString), secret: <redacted>, profile: \(profile.rawValue))"
    }
    public var debugDescription: String { description }
}

/// Which profiles the menu offers for a switchboard, and which need the
/// shell-equivalent confirmation. The profile model itself is `ToolProfile`.
public enum ProfileChoice {
    public static let choices: [ToolProfile] = [.observe, .owner]

    public static func needsConfirmation(_ profile: ToolProfile) -> Bool {
        profile.isShellEquivalent
    }
}

/// What the daemon does at startup with the switchboard settings, and what to log
/// about it. Saved files win over launch flags (#57); flags with an unreadable secret
/// and nothing saved leave the switchboard off rather than exiting (#57).
public struct SwitchboardStartup: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// The files saved by the menu (or by hand) replace the launch flags.
        case saved
        /// The launch flags, when no saved config exists.
        case flags
        /// Flags were given but their secret file cannot be read, and nothing is saved.
        case disabled
        /// No switchboard at all.
        case none
    }

    public let mode: Mode
    /// The config to dial, for `saved` and `flags`.
    public let config: SwitchboardConfig?
    /// One log line for the cases the operator must notice: a saved file overriding a
    /// flag, or the switchboard disabled. Never contains the secret.
    public let warning: String?

    public static func resolve(saved: SwitchboardConfig?, flags: SwitchboardConfig?,
                               flagsGiven: Bool) -> SwitchboardStartup {
        if let saved {
            let warning = flagsGiven
                ? "switchboard: saved switchboard files override the launch flags for this run; the LaunchAgent flags are not used"
                : nil
            return SwitchboardStartup(mode: .saved, config: saved, warning: warning)
        }
        if let flags {
            return SwitchboardStartup(mode: .flags, config: flags, warning: nil)
        }
        if flagsGiven {
            return SwitchboardStartup(mode: .disabled, config: nil,
                                      warning: "switchboard disabled: the flagged secret file is unreadable and no config is saved; the menu bar can configure it, or re-run the installer to clear the LaunchAgent flags")
        }
        return SwitchboardStartup(mode: .none, config: nil, warning: nil)
    }
}

/// The one reader and writer of the switchboard files that
/// `scripts/install-prebuilt.sh` also reads: `switchboard.url`, `switchboard.secret`
/// and `switchboard.profile`. `switchboard.secure-set-value` belongs to the installer
/// and is never written here.
///
/// Writes validate every field before the first file changes. Each file is written
/// to a `.tmp` sibling, moved into place, then set to mode 600. The store does not log.
public struct SwitchboardConfigStore: Sendable {
    public enum SecretState: Equatable, Sendable { case set, notSet }

    /// What the menu's Configure dialog submits.
    public struct Edit: Equatable, Sendable {
        public var url: String
        /// nil or blank keeps the saved secret. Never shown back.
        public var newSecret: String?
        public var profile: ToolProfile
        /// Must be true to save `owner`: the shell-equivalent confirmation.
        public var ownerConfirmed: Bool

        public init(url: String, newSecret: String?, profile: ToolProfile, ownerConfirmed: Bool) {
            self.url = url; self.newSecret = newSecret; self.profile = profile; self.ownerConfirmed = ownerConfirmed
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case url(Switchboard.ConfigError)
        case secretRequired
        case ownerNeedsConfirmation
        case forgetNeedsConfirmation
        case io(String)

        public var description: String {
            switch self {
            case .url(let e): return e.description
            case .secretRequired: return "no secret is saved; enter the switchboard secret"
            case .ownerNeedsConfirmation: return "owner is shell-equivalent; confirm it before saving"
            case .forgetNeedsConfirmation: return "forgetting the switchboard needs confirmation"
            case .io(let s): return "could not write the switchboard files: \(s)"
            }
        }
    }

    /// `~/.config/oab-instance-mcp`, the directory the installer reads.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/oab-instance-mcp")
    }

    public let directory: URL

    public init(directory: URL = SwitchboardConfigStore.defaultDirectory) {
        self.directory = directory
    }

    public var urlFile: URL { directory.appendingPathComponent("switchboard.url") }
    public var secretFile: URL { directory.appendingPathComponent("switchboard.secret") }
    public var profileFile: URL { directory.appendingPathComponent("switchboard.profile") }

    /// The saved config, or nil unless both the URL and the secret are usable.
    public func load() -> SwitchboardConfig? {
        guard let text = firstLine(urlFile), let url = try? Switchboard.validate(text),
              let secret = readSecret() else { return nil }
        let p = savedProfile()
        return SwitchboardConfig(url: url, secret: secret, profile: p.profile,
                                 requestedProfile: p.requested, profileWarning: p.warning)
    }

    public func secretState() -> SecretState {
        readSecret() == nil ? .notSet : .set
    }

    /// Validate the whole edit, then write. Nothing is written when any check fails.
    public func save(_ edit: Edit) throws {
        let urlText = edit.url.trimmingCharacters(in: .whitespacesAndNewlines)
        do { _ = try Switchboard.validate(urlText) } catch let e as Switchboard.ConfigError {
            throw Failure.url(e)
        }
        if ProfileChoice.needsConfirmation(edit.profile) && !edit.ownerConfirmed {
            throw Failure.ownerNeedsConfirmation
        }
        let typed = edit.newSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let secret: String
        if !typed.isEmpty {
            secret = typed
        } else if let saved = readSecret() {
            secret = saved
        } else {
            throw Failure.secretRequired
        }

        do {
            try ensureDirectory()
            // The secret goes first and the URL last, so a URL file exists only once
            // the other two are in place.
            try writeSecure(secret, to: secretFile)
            try writeSecure(edit.profile.rawValue, to: profileFile)
            try writeSecure(urlText, to: urlFile)
        } catch let f as Failure {
            throw f
        } catch {
            throw Failure.io(error.localizedDescription)
        }
    }

    /// Remove the URL, secret and profile files. The installer's secure-set-value file
    /// stays. The LaunchAgent plist still has the flags until the installer is re-run.
    /// Refused unless the caller confirms, so a stray call cannot delete the config.
    public func forget(confirmed: Bool) throws {
        guard confirmed else { throw Failure.forgetNeedsConfirmation }
        for file in [urlFile, secretFile, profileFile] where FileManager.default.fileExists(atPath: file.path) {
            do { try FileManager.default.removeItem(at: file) } catch {
                throw Failure.io(error.localizedDescription)
            }
        }
    }

    // MARK: helpers

    private func readSecret() -> String? {
        guard let text = try? String(contentsOf: secretFile, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func savedProfile() -> (profile: ToolProfile, requested: String, warning: String?) {
        guard let name = firstLine(profileFile) else {
            return (ToolProfile.defaultProfile, ToolProfile.defaultProfile.rawValue, nil)
        }
        // `desktop` resolves to observe with the retired warning, as the installer and the flag do.
        // An unrecognised name also serves observe (the least privilege), and says so.
        guard let r = ToolProfile.resolve(requested: name) else {
            return (ToolProfile.defaultProfile, name,
                    "switchboard.profile says '\(name)', which is not a profile; serving observe. Write observe or owner.")
        }
        return (r.profile, r.requested, r.warning)
    }

    private func firstLine(_ file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func ensureDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        // createDirectory does not change the mode of a directory that already exists.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func writeSecure(_ text: String, to file: URL) throws {
        let fm = FileManager.default
        let tmp = file.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmp)
        // O_EXCL at 0600: the secret is never on disk at a wider mode, even briefly.
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw Failure.io("cannot create \(tmp.lastPathComponent)") }
        let data = Data((text + "\n").utf8)
        let written = data.withUnsafeBytes { buf in write(fd, buf.baseAddress, buf.count) == buf.count }
        close(fd)
        guard written else {
            try? fm.removeItem(at: tmp)
            throw Failure.io("cannot write \(tmp.lastPathComponent)")
        }
        if fm.fileExists(atPath: file.path) {
            _ = try fm.replaceItemAt(file, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: file)
        }
        // replaceItemAt may keep the old file's mode, so set it on the final file explicitly.
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
