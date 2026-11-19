import Foundation

/// What a Remove really did. `remove()` succeeds while leaving items it does not own (a foreign or unreadable
/// `install.json`, the profile it points to), so success alone does not mean the folder is gone.
public enum PlaywrightRemovalOutcome: Equatable, Sendable {
    case removed
    /// The call succeeded but `install.json` still exists or the folder is not empty.
    case partial
    case failed

    /// `state` and `folderRemains` are read after the removal (`state()` and a directory check).
    public static func classify(result: Result<Void, PlaywrightInstallFailure>, state: PlaywrightInstallState,
                                folderRemains: Bool) -> PlaywrightRemovalOutcome {
        guard case .success = result else { return .failed }
        if case .notInstalled = state, !folderRemains { return .removed }
        return .partial
    }
}

/// When the wizard goes to the Browser tools page by itself.
public enum BrowserWizardPolicy {
    /// The automatic setup path with every permission already granted. The page is offered until it has been
    /// completed once (R5.1, R5.10); closing the window is not completion.
    public static func showsBrowserPageOnAutoSetup(allGranted: Bool, browserOffered: Bool, pageCompleted: Bool) -> Bool {
        allGranted && browserOffered && !pageCompleted
    }

    /// The page the automatic setup path opens when every permission is already granted: `.browser` while the page
    /// is offered and not yet completed, otherwise none. `StatusItemController.showPermissionSetupIfNeeded()` calls
    /// this, so the controller's own completion flag (not a copy of it) decides.
    @MainActor
    public static func pageOnAutoSetup(allGranted: Bool, browserTools: BrowserToolsController?) -> WizardPage? {
        showsBrowserPageOnAutoSetup(
            allGranted: allGranted, browserOffered: browserTools != nil,
            pageCompleted: browserTools?.pageIsCompleted ?? true) ? .browser : nil
    }
}

/// The parts of `main.swift`'s browser wiring that depend on `--upstream browser=`, as functions the tests call.
public enum BrowserWizardWiring {
    /// An operator-supplied external Playwright is configured (`--upstream browser=`).
    public static func isExternalProvider(_ upstreams: [(String, URL)]) -> Bool {
        upstreams.contains(where: { $0.0 == "browser" })
    }

    /// The post-switch serving check the installer runs after an install or an update. With an external provider
    /// the router serves that one, so the managed copy cannot be "serving" and the check is skipped (it returns true,
    /// so an update commits without it and the rollback path cannot run; the managed copy's own health check ran in
    /// staging). Without one, the managed backend must report ready.
    public static func verifyServing(upstreams: [(String, URL)], managedIsReady: () async -> Bool) async -> Bool {
        isExternalProvider(upstreams) ? true : await managedIsReady()
    }

    /// The controller behind the Browser tools page and the menu. It is created for every configuration, including
    /// `--upstream browser=`: the page is always offered and shows the external-provider note (R5.1).
    @MainActor
    public static func makeController(
        upstreams: [(String, URL)], installer: PlaywrightInstaller, store: BrowserToolsStore,
        signIn: @escaping @Sendable (String, JSONValue) async throws -> JSONValue,
        log: @escaping @Sendable (String) -> Void) -> BrowserToolsController {
        BrowserToolsController(installer: installer, store: store, signIn: signIn,
                               externalProvider: isExternalProvider(upstreams), log: log)
    }
}
