import ApplicationServices
import CoreGraphics
import Foundation

/// Pure rules behind the permission setup wizard. The AppKit window and the menu bar only render these
/// values. Everything here is testable without a window or TCC.
public enum WizardPage: String, Equatable, Sendable {
    case core
    case optional
}

public enum RowState: Equatable, Sendable {
    case notAllowed
    /// Allow was clicked and System Settings has not been returned to yet.
    case waiting
    /// Returned to the app after Allow, and the permission is still denied.
    case stillOff
    /// Screen Recording is on in System Settings (or the user says so) and the running process still reports off.
    /// macOS applies it only after a restart (Q3, confirmed). The row offers the Restart button.
    case needsRestart
    case allowed
    case cantTest
}

public enum RowButton: Equatable, Sendable {
    case allow
    case openSettings
    case allowed
    case restart
}

public enum FooterAction: Equatable, Sendable {
    case continueToOptional(enabled: Bool)
    case skip
    case done
}

public enum WizardEvent: Equatable, Sendable {
    case skip
    case done
    case close
    case completeObserved
}

public enum WizardModel {
    public static func rowState(state: PermissionState, requested: Bool, returnedSinceRequest: Bool) -> RowState {
        switch state {
        case .granted: return .allowed
        case .unknown: return .cantTest
        case .denied:
            guard requested else { return .notAllowed }
            return returnedSinceRequest ? .stillOff : .waiting
        }
    }

    /// Accessibility first, then Screen Recording, so the restart that Screen Recording needs is the last permission action.
    public static let coreOrder: [PermissionKind] = PermissionKind.coreKinds

    public static func rowButton(for row: RowState) -> RowButton {
        switch row {
        case .notAllowed, .waiting: return .allow
        case .stillOff, .cantTest: return .openSettings
        case .needsRestart: return .restart
        case .allowed: return .allowed
        }
    }

    /// Core page: Continue, enabled only when both core permissions are granted. Optional page: Skip, or Done once
    /// Full Disk Access is granted. Skip never appears on the core page.
    public static func footerAction(page: WizardPage, snapshot: PermissionSnapshot) -> FooterAction {
        switch page {
        case .core:
            return .continueToOptional(enabled: !SetupGate.evaluate(snapshot: snapshot).blocksCore)
        case .optional:
            return snapshot.fullDiskAccess.isGranted ? .done : .skip
        }
    }

    /// Completion is recorded for Skip, Done, and an observed complete state. Closing the window is not completion.
    public static func recordsCompletion(_ event: WizardEvent) -> Bool {
        event != .close
    }

    /// The ad-hoc banner shows only when the signature was read and has no team. An ad-hoc build passes the gate
    /// on its own core grants, and the banner tells the developer that grants may not survive an update. A failed
    /// read keeps the banner off, because the build's signing is then unknown.
    public static func adHocBannerVisible(signing: SigningIdentity.Lookup) -> Bool {
        signing == .noTeam
    }

    /// Shown when a core permission that was granted before is now missing. Names the first missing one.
    public static func revocationBanner(previouslySeen: Bool, snapshot: PermissionSnapshot) -> String? {
        guard previouslySeen else { return nil }
        if !snapshot.screenRecording.isGranted { return WizardCopy.revokedScreenRecording }
        if !snapshot.accessibility.isGranted { return WizardCopy.revokedAccessibility }
        return nil
    }
}

/// The two core permission reads the revocation watch needs. There is no request or capture method on purpose:
/// the watch cannot prompt the user or capture a screenshot.
public protocol CorePermissionReading {
    func screenRecordingGranted() -> Bool
    func accessibilityGranted() -> Bool
}

public struct SystemCorePermissionReader: CorePermissionReading {
    public init() {}

    /// Preflight only. CGPreflightScreenCaptureAccess does not prompt and does not capture.
    public func screenRecordingGranted() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Read only. AXIsProcessTrusted does not prompt.
    public func accessibilityGranted() -> Bool { AXIsProcessTrusted() }
}

public enum CoreWatch {
    /// Reads Screen Recording and Accessibility and nothing else. Full Disk Access is reported as `.unknown`
    /// because this watch never probes it.
    public static func poll(_ reader: CorePermissionReading) -> PermissionSnapshot {
        PermissionSnapshot(
            screenRecording: reader.screenRecordingGranted() ? .granted : .denied,
            accessibility: reader.accessibilityGranted() ? .granted : .denied,
            fullDiskAccess: .unknown
        )
    }

    /// Replaces only the two core states in `last`, keeping its Full Disk Access value. The watch never reads
    /// Full Disk Access, so the window merges each core-only result into its last full snapshot.
    public static func merged(_ core: PermissionSnapshot, into last: PermissionSnapshot) -> PermissionSnapshot {
        var result = last
        result.screenRecording = core.screenRecording
        result.accessibility = core.accessibility
        return result
    }

    /// True when a core permission was granted before and is missing now.
    public static func revoked(previouslySeen: Bool, current: PermissionSnapshot) -> Bool {
        previouslySeen && SetupGate.evaluate(snapshot: current).blocksCore
    }

    /// Becomes true once both core permissions have been granted at least once.
    public static func seenAfter(previouslySeen: Bool, current: PermissionSnapshot) -> Bool {
        previouslySeen || (current.screenRecording.isGranted && current.accessibility.isGranted)
    }
}

/// Persisted wizard state. Closing the window never sets `hasShown`.
public struct SetupWizardStore {
    public static let hasShownKey = "permissionSetupWizard.hasShown.v1"
    public static let resumePageKey = "permissionSetupWizard.resumePage.v1"
    public static let relaunchJustHappenedKey = "permissionSetupWizard.relaunchJustHappened.v1"
    public static let autoRelaunchSpentKey = "permissionSetupWizard.autoRelaunchSpent.v1"
    public static let coreGrantedSeenKey = "permissionSetupWizard.coreGrantedSeen.v2"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var hasShown: Bool {
        get { defaults.bool(forKey: Self.hasShownKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.hasShownKey) }
    }

    public var coreGrantedSeen: Bool {
        get { defaults.bool(forKey: Self.coreGrantedSeenKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.coreGrantedSeenKey) }
    }

    /// True between a relaunch request and the new instance reading the resume state.
    public var relaunchJustHappened: Bool { defaults.bool(forKey: Self.relaunchJustHappenedKey) }

    /// An automatic relaunch was spent for the current grant. Cleared when a process sees Screen Recording granted,
    /// so a later revoke and re-grant can relaunch once more. This is what stops a relaunch loop.
    public var autoRelaunchSpent: Bool {
        get { defaults.bool(forKey: Self.autoRelaunchSpentKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.autoRelaunchSpentKey) }
    }

    /// Written before the old instance quits. `page` is the wizard page to reopen on; nil is a silent relaunch (after
    /// Finish) that reopens nothing. The spent flag is set either way.
    public func recordRelaunch(page: WizardPage?) {
        if let page {
            defaults.set(page.rawValue, forKey: Self.resumePageKey)
        } else {
            defaults.removeObject(forKey: Self.resumePageKey)
        }
        defaults.set(true, forKey: Self.relaunchJustHappenedKey)
        defaults.set(true, forKey: Self.autoRelaunchSpentKey)
    }

    /// Drops the resume page and the just-relaunched flag. The spent flag stays.
    public func clearResume() {
        defaults.removeObject(forKey: Self.resumePageKey)
        defaults.removeObject(forKey: Self.relaunchJustHappenedKey)
    }

    /// What a launch that follows a relaunch finds. Clears the resume state, so it answers once.
    public struct Resume: Equatable {
        /// The page to reopen the wizard on, or nil for a silent relaunch.
        public let page: WizardPage?
    }

    public func consumeRelaunch() -> Resume? {
        guard relaunchJustHappened else { return nil }
        let page = defaults.string(forKey: Self.resumePageKey).flatMap(WizardPage.init(rawValue:))
        clearResume()
        return Resume(page: page)
    }
}

/// Wizard copy. "Screen Recording" is the app-facing name. "Screen & System Audio Recording" appears only
/// in text that points the user to System Settings.
public enum WizardCopy {
    public static let corePageTitle = "Allow OpenAB Computer to use your computer?"
    public static let corePageSubtitle = "Agents can see this Mac and act on it only after both permissions are on."
    public static let corePageNote = "Both permissions are required. Without them, the screenshot, mouse, keyboard, and window-reading tools return an error instead of working. macOS requires you to turn each one on yourself in System Settings → Privacy & Security. For Screen Recording, turn on Screen & System Audio Recording. OpenAB Computer cannot turn them on for you."

    public static let optionalPageTitle = "Allow OpenAB Computer to access your files and local apps?"
    public static let optionalPageSubtitle = "Needed only for protected app data and for folders on external drives. Screenshots, mouse, keyboard, and browser tools do not need it."
    public static let optionalPageNote = "Optional. You can turn Full Disk Access on or off in System Settings → Privacy & Security at any time."

    public static let screenRecordingDetail = "Lets agents take screenshots of this Mac."
    public static let accessibilityDetail = "Lets agents click, type, and read the controls in app windows."
    public static let fullDiskAccessDetail = "Lets commands read Mail, Messages, Safari, and projects on external volumes such as /Volumes."

    public static let revokedScreenRecording = "Screen Recording is off. Agents can't take screenshots until you turn it back on."
    public static let revokedAccessibility = "Accessibility is off. Agents can't click, type, or read windows until you turn it back on."

    public static let adHocBanner = "This build is not signed with the release certificate. macOS may drop these permissions after an update, and you will need to allow them again."

    public static let restartButton = "Restart OpenAB Computer"
    public static let restartExplanation = "macOS needs a restart for Screen Recording to take effect."
    public static let restartFailed = "Could not restart automatically. Quit OpenAB Computer from the menu bar, then open it again."

    public static let checkAgain = "Check Again"
    public static let setupIncomplete = "Setup incomplete"

    /// Shown when macOS refuses a Settings deep link. `pane` is the row title, for example "Screen Recording".
    public static func manualPaneNotice(pane: String) -> String {
        "Could not open System Settings. Open it yourself: System Settings → Privacy & Security → \(pane)."
    }
}
