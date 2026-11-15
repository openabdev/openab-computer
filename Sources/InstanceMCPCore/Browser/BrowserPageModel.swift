import Foundation

/// How the user last answered the Playwright offer (R5.10). Stored so a later launch can tell an explicit
/// decline from a page that was never shown. It is a hint for the wizard, never proof of what is installed:
/// `PlaywrightInstaller.state()` is the only authority for that.
public enum BrowserOffer: String, Equatable, Sendable {
    case offered, declined, failed, installed
}

/// What finishing the Browser tools page means.
public enum BrowserPageCompletion: Equatable, Sendable {
    case installed
    /// The box was unchecked: an explicit decline, nothing was downloaded.
    case declined
    /// An install failed and the user chose Continue without.
    case continuedWithout
}

/// What the AppKit layer must do after an event.
public enum BrowserPageStep: Equatable, Sendable {
    case none
    case startInstall
    case complete(BrowserPageCompletion)
}

/// Pure state machine behind the Playwright row of the Browser tools page (R5.6, R5.8). It holds no I/O: the
/// window starts the installer when told to and feeds progress and the result back in. Every footer rule is
/// here so it is tested without a window.
public struct BrowserPageModel: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case installing(PlaywrightInstallProgress?)
        case failed(PlaywrightInstallFailure)
        case installed(updateAvailable: Bool)
    }

    public private(set) var phase: Phase
    /// The Playwright box. Pre-checked unless Playwright is already installed (R5.8).
    public private(set) var checked: Bool

    /// An operator-supplied external browser provider (`--upstream browser=`) is configured. The page is still
    /// offered (R5.1); the view shows `WizardCopy.browserExternalProviderNote`.
    public let externalProvider: Bool

    public init(installState: PlaywrightInstallState, externalProvider: Bool = false) {
        self.externalProvider = externalProvider
        switch installState {
        case .installed(_, let update, _): phase = .installed(updateAvailable: update); checked = false
        case .notInstalled, .invalid: phase = .idle; checked = true
        }
    }

    public struct Footer: Equatable, Sendable {
        /// The primary button. It starts the install when the box is checked, so it is off while one runs.
        public let continueEnabled: Bool
        public let showsContinue: Bool
        public let showsCancel: Bool
        /// Retry and Continue without exist only after a failure (R5.6, R7.3).
        public let showsRetry: Bool
        public let showsContinueWithout: Bool
        public let checkboxEnabled: Bool
        /// Hidden once Playwright is installed: the "Installed" status replaces the box.
        public let showsCheckbox: Bool
        public let showsSignIn: Bool
    }

    public var footer: Footer {
        switch phase {
        case .idle:
            return Footer(continueEnabled: true, showsContinue: true, showsCancel: false, showsRetry: false,
                          showsContinueWithout: false, checkboxEnabled: true, showsCheckbox: true, showsSignIn: false)
        case .installing:
            return Footer(continueEnabled: false, showsContinue: true, showsCancel: true, showsRetry: false,
                          showsContinueWithout: false, checkboxEnabled: false, showsCheckbox: true, showsSignIn: false)
        case .failed:
            return Footer(continueEnabled: false, showsContinue: false, showsCancel: false, showsRetry: true,
                          showsContinueWithout: true, checkboxEnabled: true, showsCheckbox: true, showsSignIn: false)
        case .installed:
            return Footer(continueEnabled: true, showsContinue: true, showsCancel: false, showsRetry: false,
                          showsContinueWithout: false, checkboxEnabled: false, showsCheckbox: false, showsSignIn: true)
        }
    }

    public var isInstalling: Bool { if case .installing = phase { return true }; return false }

    /// The failure to show, if the last install failed.
    public var failure: PlaywrightInstallFailure? { if case .failed(let f) = phase { return f }; return nil }

    /// The checkbox. Ignored while an install runs or once Playwright is installed. Changing it after a failure
    /// clears the failure: unchecking is then a plain decline.
    public mutating func setChecked(_ value: Bool) {
        switch phase {
        case .idle: checked = value
        case .failed: checked = value; phase = .idle
        case .installing, .installed: break
        }
    }

    /// Continue. With the box checked and nothing installed it starts the install; unchecked it declines.
    public mutating func continuePressed() -> BrowserPageStep {
        switch phase {
        case .idle:
            if checked { phase = .installing(nil); return .startInstall }
            return .complete(.declined)
        case .installed: return .complete(.installed)
        case .installing, .failed: return .none
        }
    }

    /// Starts an install from outside the page (the menu): a first install, a retry or an update. False while one runs.
    public mutating func beginInstall() -> Bool {
        switch phase {
        case .idle, .failed, .installed: phase = .installing(nil); return true
        case .installing: return false
        }
    }

    public mutating func retryPressed() -> BrowserPageStep {
        guard case .failed = phase else { return .none }
        checked = true
        phase = .installing(nil)
        return .startInstall
    }

    public mutating func continueWithoutPressed() -> BrowserPageStep {
        guard case .failed = phase else { return .none }
        return .complete(.continuedWithout)
    }

    /// True when the caller should cancel the installer.
    public func cancelPressed() -> Bool { isInstalling }

    public mutating func progress(_ p: PlaywrightInstallProgress) {
        guard isInstalling else { return }
        phase = .installing(p)
    }

    /// The install ended. A success completes the page and the wizard advances (R5.6). A cancel goes back to the
    /// idle row with the box still checked. Any other failure shows its message with Retry and Continue without.
    public mutating func finished(_ result: Result<PlaywrightInstallState, PlaywrightInstallFailure>) -> BrowserPageStep {
        guard isInstalling else { return .none }
        switch result {
        case .success(let state):
            if case .installed(_, let update, _) = state { phase = .installed(updateAvailable: update); checked = false; return .complete(.installed) }
            phase = .failed(.other("install_not_visible"))
            return .none
        case .failure(.cancelled):
            phase = .idle; checked = true
            return .none
        case .failure(let f):
            phase = .failed(f)
            return .none
        }
    }

    /// Re-reads what is on disk when the page is shown or the menu changed something. It never touches a
    /// running install or a failure the user has not dismissed, except that an install that exists wins.
    public mutating func sync(_ state: PlaywrightInstallState) {
        switch (phase, state) {
        case (.installing, _): return
        case (_, .installed(_, let update, _)): phase = .installed(updateAvailable: update); checked = false
        case (.installed, _): phase = .idle; checked = true      // removed from the menu
        default: break
        }
    }

    /// What to store as the offer after this page ended.
    public static func offer(after completion: BrowserPageCompletion) -> BrowserOffer {
        switch completion {
        case .installed: return .installed
        case .declined: return .declined
        case .continuedWithout: return .failed
        }
    }
}

/// `browserTools.*` values in `UserDefaults` (R5.10). Nothing here is a secret. An unknown stored value is
/// removed and logged by key name only.
public struct BrowserToolsStore {
    public static let offerKey = "browserTools.playwrightOffer.v1"
    public static let pageCompletedKey = "browserTools.pageCompleted.v1"

    private let defaults: UserDefaults
    private let log: (String) -> Void

    public init(defaults: UserDefaults = .standard, log: @escaping (String) -> Void = { _ in }) {
        self.defaults = defaults; self.log = log
    }

    public var offer: BrowserOffer? {
        guard let obj = defaults.object(forKey: Self.offerKey) else { return nil }
        if let raw = obj as? String, let o = BrowserOffer(rawValue: raw) { return o }
        defaults.removeObject(forKey: Self.offerKey)
        log("browser: pref_reset key=\(Self.offerKey)")
        return nil
    }

    public func record(_ offer: BrowserOffer) { defaults.set(offer.rawValue, forKey: Self.offerKey) }

    /// The offer is "offered" once the page has been shown, unless a later answer is already stored.
    public func recordOfferedIfNew() { if offer == nil { record(.offered) } }

    public var pageCompleted: Bool {
        guard let obj = defaults.object(forKey: Self.pageCompletedKey) else { return false }
        if let n = obj as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        defaults.removeObject(forKey: Self.pageCompletedKey)
        log("browser: pref_reset key=\(Self.pageCompletedKey)")
        return false
    }

    public func setPageCompleted() { defaults.set(true, forKey: Self.pageCompletedKey) }
}

/// "Open Playwright window to sign in…": starts the managed browser if needed and calls `browser_navigate` once
/// to `about:blank`, so a headed window opens on the persistent profile. Nothing about the page, the URL or the
/// result is logged (R5.9), only that it opened or a fixed failure class.
public enum PlaywrightSignIn {
    public enum Outcome: Equatable, Sendable {
        case opened
        case failed(String)
    }

    public static func open(call: @Sendable (String, JSONValue) async throws -> JSONValue,
                            log: @Sendable (String) -> Void) async -> Outcome {
        do {
            let r = try await call("browser_navigate", .object(["url": .string("about:blank")]))
            if r["isError"]?.boolValue == true {
                log("browser: signin_failed class=playwright_tool_error")
                return .failed("playwright_tool_error")
            }
            log("browser: signin_opened")
            return .opened
        } catch let e as BrowserBackendError {
            let c = sanitize(e.errorClass)
            log("browser: signin_failed class=\(c)")
            return .failed(c)
        } catch {
            log("browser: signin_failed class=signin_failed")
            return .failed("signin_failed")
        }
    }

    /// Only the characters the log pattern allows; anything else becomes `_`.
    static func sanitize(_ s: String) -> String {
        let out = String(s.unicodeScalars.prefix(64).map { c in
            (c.isASCII && (CharacterSet.alphanumerics.contains(c) || c == "_")) ? Character(c) : "_"
        })
        return out.isEmpty ? "signin_failed" : out
    }
}
