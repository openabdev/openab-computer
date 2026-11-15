import AppKit
import InstanceMCPCore

/// The one place that runs Playwright install, update, removal and sign-in for the wizard page and the menu bar,
/// so both show the same state and only one install runs at a time. It calls only the public installer API;
/// the installer does every download, check and file operation (R7.1 to R7.7).
@MainActor
final class BrowserToolsController {
    let installer: PlaywrightInstaller
    private let store: BrowserToolsStore
    private let signInCall: @Sendable (String, JSONValue) async throws -> JSONValue
    private let log: @Sendable (String) -> Void
    private(set) var model: BrowserPageModel
    /// The last install ended in a failure (menu line). Cleared by a success or a removal.
    private(set) var lastFailed = false
    private var observers: [() -> Void] = []

    init(installer: PlaywrightInstaller, store: BrowserToolsStore,
         signIn: @escaping @Sendable (String, JSONValue) async throws -> JSONValue,
         log: @escaping @Sendable (String) -> Void) {
        self.installer = installer
        self.store = store
        self.signInCall = signIn
        self.log = log
        self.model = BrowserPageModel(installState: installer.state())
    }

    var plan: PlaywrightInstallPlan { installer.plan() }
    var installState: PlaywrightInstallState { installer.state() }

    func addObserver(_ f: @escaping () -> Void) { observers.append(f) }
    private func notify() { for f in observers { f() } }

    /// Re-reads `install.json` (no network, no process). Called when the page or the menu opens.
    func refresh() {
        model.sync(installer.state())
        notify()
    }

    /// The wizard page was shown: record that it was offered.
    func pageShown() {
        store.recordOfferedIfNew()
        refresh()
    }

    // MARK: install and update

    /// Starts an install or an update. `finished` runs on the main actor with the result. Returns false when one
    /// is already running. The caller has already shown the consent text (wizard row or menu sheet).
    @discardableResult
    func startInstall(finished: @escaping (Result<PlaywrightInstallState, PlaywrightInstallFailure>, BrowserPageStep) -> Void) -> Bool {
        if !model.isInstalling, !model.beginInstall() { return false }
        runInstall(finished: finished)
        return true
    }

    /// The model is already in `.installing` (the page's Continue or Retry did it).
    func runInstall(finished: @escaping (Result<PlaywrightInstallState, PlaywrightInstallFailure>, BrowserPageStep) -> Void) {
        notify()
        let report: @Sendable (PlaywrightInstallProgress) -> Void = { [weak self] p in
            Task { @MainActor in self?.model.progress(p); self?.notify() }
        }
        Task { [weak self, installer] in
            let result = await installer.install(progress: report)
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
            self.notify()
            finished(result, step)
        }
    }

    func cancelInstall() {
        guard model.cancelPressed() else { return }
        Task { [installer] in await installer.cancel() }
    }

    // MARK: the page's buttons (pure model events)

    func setChecked(_ value: Bool) { model.setChecked(value); notify() }
    func pageContinue() -> BrowserPageStep { let s = model.continuePressed(); notify(); return s }
    func pageRetry() -> BrowserPageStep { let s = model.retryPressed(); notify(); return s }
    func pageContinueWithout() -> BrowserPageStep { let s = model.continueWithoutPressed(); notify(); return s }

    // MARK: page completion

    /// Records how the Browser tools page ended.
    func pageCompleted(_ completion: BrowserPageCompletion) {
        store.record(BrowserPageModel.offer(after: completion))
        store.setPageCompleted()
    }

    // MARK: removal and sign-in

    func remove() async -> Result<Void, PlaywrightInstallFailure> {
        if model.isInstalling { return .failure(.lockHeld) }
        let r = await installer.remove()
        if case .success = r { lastFailed = false }
        model.sync(installer.state())
        notify()
        return r
    }

    func signIn() async -> PlaywrightSignIn.Outcome {
        await PlaywrightSignIn.open(call: signInCall, log: log)
    }
}
