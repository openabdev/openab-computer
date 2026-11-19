import Foundation

/// Copy for the installed Google Chrome route (ADR Q3 and Q5, R7.3). Nothing here says that Chrome is pinned or
/// checked against a digest: it is neither. What the app does check is named as exactly that.
extension WizardCopy {
    public static let browserUseChrome = "Use my installed Google Chrome"
    public static let browserUseChromeMenu = "Use my installed Google Chrome…"
    public static let browserUseChromeTip = "Offered because macOS would not run the downloaded Chromium. Asks first."
    public static let browserUseDownloadedMenu = "Use the downloaded Chromium instead…"
    public static let browserUseDownloadedTip = "Downloads and checks the pinned Chromium. Your Chrome is not touched."
    public static let chromeConsentTitle = "Use your installed Google Chrome?"
    public static let chromeConsentConfirm = "Use my installed Chrome"
    public static let chromeSwitchBackTitle = "Use the downloaded Chromium instead?"
    public static let chromeSwitchBackConfirm = "Download and switch"
    public static let browserChromeInstalledNote = "Playwright drives your installed Google Chrome with this app's own browser profile. This app does not pin its version or check a digest of it."

    /// The consent text. It states what changes, what is and is not checked, what is downloaded and what is never touched.
    public static func chromeConsent(plan: PlaywrightInstallPlan, chrome: InstalledChrome, home: String = NSHomeDirectory()) -> String {
        "macOS would not run the downloaded Chromium. Instead, Playwright can drive your own Google Chrome (version \(chrome.version), \(displayPath(chrome.appPath, home: home))). "
            + "Playwright then starts your Chrome program, but with this app's own separate browser profile in \(displayPath(plan.installPath, home: home))/profile. Your Chrome profile, bookmarks and sign-ins are never used or changed. "
            + "This app does not pin the version of your Chrome and does not check a digest of it. Whatever version is installed is what agents drive, including after Chrome updates itself. "
            + "Each time it starts, the app checks that it is Google Chrome in /Applications or ~/Applications, signed by Google LLC, and version \(InstalledChromePolicy.minimumMajor) or newer. If a check fails, the browser tools stop until it passes. "
            + "Downloads about \(megabytes(plan.chromeDownloadBytes)): Node.js and the Playwright MCP server, from \(joinNames(plan.chromeHosts)), checked against values built into this app. Chromium is not downloaded. "
            + "The app never copies, changes or deletes Chrome. Nothing is installed until you press the button below. You can switch back to the downloaded Chromium from the menu."
    }

    /// The update prompt when the installed Chrome is the chosen browser: it keeps that choice.
    public static func updatePromptChrome(installed: String, plan: PlaywrightInstallPlan, home: String = NSHomeDirectory()) -> String {
        "Playwright \(installed) is installed and drives your installed Google Chrome. This app carries \(plan.id). "
            + "The update downloads about \(megabytes(plan.chromeDownloadBytes)): Node.js and the Playwright MCP server, from \(joinNames(plan.chromeHosts)), checked against values built into this app. Chromium is not downloaded, and Chrome is not pinned or checked against a digest. "
            + "Chrome is checked again first. If the update fails, the installed version keeps working. Your browser profile and sign-ins are kept."
    }

    public static let switchBackConsent = "This downloads the pinned Chromium and checks it against values built into this app, then switches Playwright to it. Until that succeeds, Playwright keeps driving your installed Google Chrome. Your Chrome and its profile are not touched."

    /// The menu line for the installed-Chrome choice. The version is the one in the bundle now.
    public static func chromeStatusLine(version: String?) -> String {
        "Browser: your installed Google Chrome" + (version.map { " \($0)" } ?? "") + " (not pinned, no digest checked)"
    }

    /// Why a Chrome on this Mac cannot be used. Fixed text per class.
    public static func chromeProblem(_ p: InstalledChromeProblem) -> String {
        switch p {
        case .notFound:
            return "Google Chrome was not found in /Applications or ~/Applications. Nothing was changed."
        case .notGoogleChrome:
            return "The app named Google Chrome in /Applications or ~/Applications is not Google Chrome as this app recognizes it (a link, another build or a fork). It was not used."
        case .invalidSignature:
            return "Google Chrome did not pass the signature check for Google LLC, so it was not used. Reinstall Chrome from google.com/chrome and try again."
        case .tooOld(let found, let minimum):
            return "Google Chrome \(found) is older than the version \(minimum) this app requires. Update Chrome and try again."
        case .unreadable:
            return "Google Chrome could not be read (its version or program is missing). It was not used."
        }
    }

    /// The user-facing text for an install failure whose class is one of the Chrome classes; nil for any other class.
    static func chromeFailureMessage(_ c: String) -> String? {
        switch c {
        case "chrome_missing": return chromeProblem(.notFound)
        case "chrome_not_google": return chromeProblem(.notGoogleChrome)
        case "chrome_invalid_signature": return chromeProblem(.invalidSignature)
        case "chrome_too_old": return "Google Chrome is older than the version \(InstalledChromePolicy.minimumMajor) this app requires. Update Chrome and try again."
        case "chrome_unreadable": return chromeProblem(.unreadable)
        default: return nil
        }
    }
}
