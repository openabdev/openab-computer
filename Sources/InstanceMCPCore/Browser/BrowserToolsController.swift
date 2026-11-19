import Foundation

/// The one place that runs Playwright install, update, removal and sign-in for the wizard page and the menu bar,
/// so both show the same state and only one install runs at a time. It calls only the public installer API;
/// the installer does every download, check and file operation (R7.1 to R7.7).
@MainActor
public final class BrowserToolsController {
    public let installer: PlaywrightInstaller
    private let store: BrowserToolsStore
    private let signInCall: @Sendable (String, JSONValue) async throws -> JSONValue
    private let log: @Sendable (String) -> Void
    public private(set) var model: BrowserPageModel
    /// The last install ended in a failure (menu line). Cleared by a success or a removal.
    public private(set) var lastFailed = false
    private var observers: [() -> Void] = []

    public init(installer: PlaywrightInstaller, store: BrowserToolsStore,
         signIn: @escaping @Sendable (String, JSONValue) async throws -> JSONValue,
         externalProvider: Bool = false,
         log: @escaping @Sendable (String) -> Void) {
        self.installer = installer
        self.store = store
        self.signInCall = signIn
        self.log = log
        self.model = BrowserPageModel(installState: installer.state(), externalProvider: externalProvider)
        syncChrome()
    }

    /// Chrome facts for the model: whether it is installed (a `stat`, no signature check) and whether the record uses it.
    private func syncChrome() {
        model.setChromeDetected(installer.installedChromeDetected())
        model.setUsesInstalledChrome(installer.selectedEngine() == .installedChrome)
    }

    public var plan: PlaywrightInstallPlan { installer.plan() }
    public var installState: PlaywrightInstallState { installer.state() }

    public func addObserver(_ f: @escaping () -> Void) { observers.append(f) }
    private func notify() { for f in observers { f() } }

    /// Re-reads `install.json` (no network, no process). Called when the page or the menu opens.
    public func refresh() {
        model.sync(installer.state())
        syncChrome()
        notify()
    }

    /// The wizard page was shown: record that it was offered.
    public func pageShown() {
        store.recordOfferedIfNew()
        refresh()
    }

    // MARK: install and update

    /// Starts an install or an update. `finished` runs on the main actor with the result. Returns false when one
    /// is already running. The caller has already shown the consent text (wizard row or menu sheet).
    @discardableResult
    public func startInstall(finished: @escaping (Result<PlaywrightInstallState, PlaywrightInstallFailure>, BrowserPageStep) -> Void) -> Bool {
        guard model.beginInstall() else { return false }
        runInstall(finished: finished)
        return true
    }

    /// The model is already in `.installing` (the page's Continue or Retry did it). `engine` is nil for an install
    /// or an update that keeps the browser already chosen: the installed Chrome stays the installed Chrome (and is
    /// checked again), anything else is the downloaded Chromium. The installed Chrome is never chosen here by default.
    public func runInstall(engine: BrowserEngine? = nil,
                           finished: @escaping (Result<PlaywrightInstallState, PlaywrightInstallFailure>, BrowserPageStep) -> Void) {
        let chosen = engine ?? installer.selectedEngine() ?? .downloadedChromium
        notify()
        let report: @Sendable (PlaywrightInstallProgress) -> Void = { [weak self] p in
            Task { @MainActor in self?.model.progress(p); self?.notify() }
        }
        Task { [weak self, installer] in
            let result = await installer.install(engine: chosen, progress: report)
            guard let self else { return }
            let step = self.model.finished(result)
            switch result {
            case .success:
                self.lastFailed = false
                self.store.record(.installed)
            case .failure(.cancelled):
                break
            case .failure:
                self.lastFailed = true
                self.store.record(.failed)
            }
            // A failed update leaves the old version serving: show what is on disk, not the failure.
            self.model.sync(installer.state())
            self.syncChrome()
            self.notify()
            finished(result, step)
        }
    }

    // MARK: the installed Google Chrome (ADR Q3 and Q5, R7.3)

    /// What the consent step shows, or why the Chrome on this Mac cannot be offered.
    public enum ChromeConsentOffer: Equatable, Sendable {
        case consent(title: String, text: String, chrome: InstalledChrome)
        case problem(InstalledChromeProblem)
    }

    /// **Use my installed Chrome** in the page or the menu. It checks Chrome (read-only) and returns the consent text; it
    /// downloads, launches and records nothing. nil when the button is not on offer. A problem closes the step.
    public func requestChromeConsent(home: String = NSHomeDirectory()) -> ChromeConsentOffer? {
        guard model.useInstalledChromePressed() else { return nil }
        switch installer.checkInstalledChrome() {
        case .success(let c):
            log("browser: chrome_consent_shown")
            return .consent(title: WizardCopy.chromeConsentTitle,
                            text: WizardCopy.chromeConsent(plan: plan, chrome: c, home: home), chrome: c)
        case .failure(let p):
            model.chromeConsentCancelled()
            log("browser: chrome_check_failed class=\(p.errorClass)")
            notify()
            return .problem(p)
        }
    }

    /// Cancel in the consent step. Nothing changes.
    public func cancelChromeConsent() {
        guard model.chromeConsentOpen else { return }
        model.chromeConsentCancelled()
        log("browser: chrome_consent_cancelled")
        notify()
    }

    /// Confirm in the consent step: only now is anything installed or recorded. False when no consent step is open.
    @discardableResult
    public func confirmChromeConsent(finished: @escaping (Result<PlaywrightInstallState, PlaywrightInstallFailure>, BrowserPageStep) -> Void) -> Bool {
        guard model.chromeConsentConfirmed() else { return false }
        log("browser: chrome_consent_confirmed")
        runInstall(engine: .installedChrome, finished: finished)
        return true
    }

    /// Menu: back to the downloaded Chromium. Downloads and checks it as a first install does; until that succeeds the
    /// installed-Chrome choice keeps working. The user's Chrome is not touched.
    @discardableResult
    public func useDownloadedChromium(finished: @escaping (Result<PlaywrightInstallState, PlaywrightInstallFailure>, BrowserPageStep) -> Void) -> Bool {
        guard installer.selectedEngine() == .installedChrome, model.beginInstall() else { return false }
        log("browser: chrome_switch_back")
        runInstall(engine: .downloadedChromium, finished: finished)
        return true
    }

    public func cancelInstall() {
        guard model.cancelPressed() else { return }
        Task { [installer] in await installer.cancel() }
    }

    // MARK: the page's buttons (pure model events)

    public func setChecked(_ value: Bool) { model.setChecked(value); notify() }
    public func pageContinue() -> BrowserPageStep { let s = model.continuePressed(); notify(); return s }
    public func pageRetry() -> BrowserPageStep { let s = model.retryPressed(); notify(); return s }
    public func pageContinueWithout() -> BrowserPageStep { let s = model.continueWithoutPressed(); notify(); return s }

    // MARK: page completion

    /// The page has been completed once (install, decline or continue without).
    public var pageIsCompleted: Bool { store.pageCompleted }

    /// Records how the Browser tools page ended.
    public func pageCompleted(_ completion: BrowserPageCompletion) {
        store.record(BrowserPageModel.offer(after: completion))
        store.setPageCompleted()
    }

    // MARK: removal and sign-in

    /// Removes what the installer owns, then re-reads the state and the folder: `remove()` succeeds while it
    /// leaves a foreign or unreadable `install.json` and the profile, so the outcome says what is really left.
    public func remove() async -> PlaywrightRemovalOutcome {
        if model.isInstalling { return .failed }
        let r = await installer.remove()
        if case .success = r { lastFailed = false }
        model.sync(installer.state())
        syncChrome()
        notify()
        return PlaywrightRemovalOutcome.classify(
            result: r, state: installer.state(),
            folderRemains: FileManager.default.fileExists(atPath: installer.plan().installPath))
    }

    public func signIn() async -> PlaywrightSignIn.Outcome {
        await PlaywrightSignIn.open(call: signInCall, log: log)
    }
}
