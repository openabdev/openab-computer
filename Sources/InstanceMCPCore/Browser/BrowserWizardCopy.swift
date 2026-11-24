import Foundation

/// Copy for the Browser tools page, the Playwright menu items and their dialogs (R5.8, R5.11, R7.3, R7.7).
/// Every number and host name comes from the `PlaywrightInstallPlan`, which is built from the manifest embedded
/// in the app. None of this text calls the download safe.
extension WizardCopy {
    public static let browserPageTitle = "Let agents use a web browser?"
    public static let browserPageSubtitle = "Playwright gives agents a separate Chromium that they can drive. It is optional, and nothing is downloaded until you press Continue with the box checked."
    public static let browserRowTitle = "Install Playwright browser (recommended)"
    public static let browserPageNote = "You can install, update or remove it later from the menu bar. Closing this window does not install anything."

    public static let browserInstalledStatus = "✓ Installed"
    public static let browserNotInstalledStatus = "Not installed"
    public static let browserInstallingStatus = "Installing…"
    public static let browserContinue = "Continue"
    public static let browserInstall = "Install"
    public static let browserRetry = "Retry"
    public static let browserContinueWithout = "Continue without"
    public static let browserCancel = "Cancel"
    public static let browserSignInButton = "Open Playwright window to sign in…"
    public static let browserSetUpMenu = "Set up browser tools…"
    public static let browserInstallMenu = "Install Playwright…"
    public static let browserSignInMenu = "Open Playwright window to sign in…"
    public static let browserRemoveMenu = "Remove Playwright…"
    public static let browserCancelInstallMenu = "Cancel Playwright Install"

    /// Shown before the sign-in window opens, and on the page next to its button.
    public static let browserSignInNote = "A separate browser window opens with its own profile. Sign in to the sites you want agents to use. The login stays in that profile. Removing Playwright deletes the profile only when this app created it and its install record is readable. Some sites may refuse an automated browser."

    /// "about N MB", decimal megabytes rounded up so the figure is never lower than the download.
    public static func megabytes(_ bytes: Int64) -> String {
        let mb = (max(bytes, 0) + 999_999) / 1_000_000
        return "\(mb) MB"
    }

    /// The install path with the home directory shown as `~`.
    public static func displayPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        if !home.isEmpty, path == home { return "~" }
        if !home.isEmpty, path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// "a", "a and b", "a, b and c".
    static func joinNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// The consent text of R5.8. The wizard row and the menu's install sheet both show it.
    public static func playwrightConsent(plan: PlaywrightInstallPlan, home: String = NSHomeDirectory()) -> String {
        "Downloads about \(megabytes(plan.downloadBytes)): Node.js, the Playwright MCP server and a separate Chromium, from \(joinNames(plan.hosts)). "
            + "Installs to \(displayPath(plan.installPath, home: home)). "
            + "Each download is checked against values built into this app. "
            + "It uses its own browser profile, not your Chrome or Safari. "
            + "Needs an internet connection and about \(megabytes(plan.diskBytes)) of free disk. "
            + "Uncheck to skip it; you can install it later from the menu."
    }

    public static func installSheetTitle(update: Bool) -> String {
        update ? "Update Playwright?" : "Install Playwright browser?"
    }

    /// The update prompt (R7.7): never silent, it names the change and what is downloaded.
    public static func updatePrompt(installed: String, plan: PlaywrightInstallPlan, home: String = NSHomeDirectory()) -> String {
        "Playwright \(installed) is installed. This app carries \(plan.id). " + playwrightConsent(plan: plan, home: home)
            + " If the update fails, the installed version keeps working. Your browser profile and sign-ins are kept."
    }

    public static func updateMenuTitle(installed: String, plan: PlaywrightInstallPlan) -> String {
        "Update Playwright… (\(installed) → \(plan.id))"
    }

    public static let staleLine = "Playwright's Chromium is older than this app expects. Update to refresh it."

    /// What Remove deletes (R7.7). It names what the installer removes and what it leaves, in the terms of
    /// `PlaywrightInstaller.remove()`: only items that carry the installer's marker, or that an `install.json`
    /// written by the installer owns. A foreign or unreadable `install.json`, and the profile, stay.
    public static func removalConfirmation(path: String, home: String = NSHomeDirectory()) -> String {
        "This removes what this app installed in \(displayPath(path, home: home)). Version folders that carry this app's marker (Node.js, the Playwright MCP server and the downloaded Chromium) are removed even if install.json is unreadable, invalid or made by hand. The browser profile with its cookies and sign-ins, the output folder and install.json are removed only when a readable install.json written by this app confirms it created them. Anything else stays, and it does not touch Chrome, Safari or ~/.local/oab-computer/. Agents lose the browser tools until you install it again. If you had chosen your installed Google Chrome, that choice is removed too when install.json is removed, and Chrome itself is left as it is."
    }

    public static let removalDone = "Playwright was removed."
    public static func removalPartial(path: String, home: String = NSHomeDirectory()) -> String {
        "Playwright was only partly removed. Some items in \(displayPath(path, home: home)) could not be confirmed as created by this app (for example an install.json that is unreadable, invalid or made by hand, and the profile it points to), so they were left in place. Delete them by hand if you want them gone."
    }
    public static let installReady = "Playwright is ready."
    public static let removalFailed = "Playwright could not be removed completely. Quit any open Playwright browser window and try again."

    /// The truthful message for what a Remove left behind.
    public static func removalMessage(_ outcome: PlaywrightRemovalOutcome, path: String, home: String = NSHomeDirectory()) -> String {
        switch outcome {
        case .removed: return removalDone
        case .partial: return removalPartial(path: path, home: home)
        case .failed: return removalFailed
        }
    }

    /// Shown on the Browser tools page when `--upstream browser=` is set (R5.1: the page is always offered).
    public static let browserExternalProviderNote = "An external browser provider is configured for this app (--upstream browser=). In Automatic mode agents use it first, ahead of Chrome or Safari through Apple Events. Installing Playwright here does not change that while the option is set; it only prepares the managed copy for when the option is removed."

    public static func signInFailed(_ errorClass: String) -> String {
        "The Playwright window could not be opened (\(errorClass)). Check that Playwright is installed, then try again."
    }

    /// The progress line under the bar. `fraction` is shown only for a download.
    public static func stepText(_ p: PlaywrightInstallProgress?) -> String {
        guard let p else { return "Starting…" }
        let pct = p.fraction.map { " \(Int(min(max($0, 0), 1) * 100))%" } ?? ""
        switch p.step {
        case .preflight: return "Checking free space…"
        case .downloadNode: return "Downloading Node.js…\(pct)"
        case .downloadChromium: return "Downloading Chromium…\(pct)"
        case .extract: return "Unpacking…"
        case .signature: return "Checking Node.js signature…"
        case .packages: return "Installing the Playwright MCP server…"
        case .healthCheck: return "Checking that it starts…"
        case .commit, .switchOver: return "Finishing…"
        }
    }

    /// The message for each failure, R7.3. `.other` shows only a fixed lowercase class.
    public static func installFailure(_ f: PlaywrightInstallFailure) -> String {
        switch f {
        case .offline:
            return "No internet connection. Playwright was not installed. Connect and press Retry, or Continue without it and install later from the menu."
        case .interrupted:
            return "The download was interrupted. Press Retry to start it again, or Continue without Playwright and install later from the menu."
        case .tls:
            return "A secure connection could not be made. Playwright was not installed."
        case .digestMismatch:
            return "A download did not match what this app expects. Nothing was installed."
        case .notEnoughDisk(let needed, let available):
            return "Not enough free space: needs \(megabytes(needed)), has \(megabytes(max(available, 0) / 1_000_000 * 1_000_000))."
        case .archiveRejected:
            return "An archive had unsafe contents. Nothing was installed."
        case .nodeSignature:
            return "The downloaded Node.js failed its signature check. Nothing was installed."
        case .launchRefused:
            return "macOS would not run the downloaded browser. Nothing was installed."
        case .lockHeld:
            return "Another install is running."
        case .cancelled:
            return "The install was cancelled."
        case .healthCheckFailed:
            return "The downloaded browser tools did not start. Nothing was installed."
        case .other(let c):
            if let chrome = chromeFailureMessage(c) { return chrome }
            let safe = c.unicodeScalars.allSatisfy { ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) || $0 == "_" }
            return "Playwright could not be installed (\(safe && !c.isEmpty && c.count <= 64 ? c : "unknown"))."
        }
    }
}
