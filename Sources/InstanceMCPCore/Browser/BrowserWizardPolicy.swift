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
}
