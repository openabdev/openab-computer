import Foundation
import XCTest
@testable import InstanceMCPCore

// MARK: - Switchboard config files (the installer's layout, written by the menu)

final class SwitchboardFilesTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sbcfg-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private var store: SwitchboardConfigStore { SwitchboardConfigStore(directory: dir) }
    private let goodURL = "wss://switchboard.example.test/vm/attach"

    private func edit(url: String? = nil, secret: String? = "s3cret-value", profile: ToolProfile = .observe,
                      confirmed: Bool = false) -> SwitchboardConfigStore.Edit {
        .init(url: url ?? goodURL, newSecret: secret, profile: profile, ownerConfirmed: confirmed)
    }

    private func mode(_ file: URL) -> Int {
        let attrs = try! FileManager.default.attributesOfItem(atPath: file.path)
        return (attrs[.posixPermissions] as! NSNumber).intValue
    }

    private func filesInDir() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    func testSaveWritesTheInstallerLayoutAtMode600AndRoundTrips() throws {
        try store.save(edit(profile: .observe))

        XCTAssertEqual(mode(store.urlFile), 0o600)
        XCTAssertEqual(mode(store.secretFile), 0o600)
        XCTAssertEqual(mode(store.profileFile), 0o600)
        XCTAssertEqual(mode(store.markerFile), 0o600)
        XCTAssertEqual(mode(dir), 0o700)
        XCTAssertEqual(try String(contentsOf: store.urlFile, encoding: .utf8).trimmingCharacters(in: .newlines), goodURL)
        XCTAssertEqual(try String(contentsOf: store.profileFile, encoding: .utf8).trimmingCharacters(in: .newlines), "observe")
        XCTAssertFalse(filesInDir().contains { $0.hasSuffix(".tmp") }, "no temp files left behind")

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.url.absoluteString, goodURL)
        XCTAssertEqual(loaded.secret, "s3cret-value")
        XCTAssertEqual(loaded.profile, .observe)
    }

    func testAnExistingFileWithLooseModeIsTightenedTo600() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "old\n".write(to: store.secretFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.secretFile.path)

        try store.save(edit(secret: "new-secret"))

        XCTAssertEqual(mode(store.secretFile), 0o600)
        XCTAssertEqual(store.load()?.secret, "new-secret")
    }

    func testSecretIsNeverPartOfAnErrorMessage() {
        let secret = "HUNTER2-DO-NOT-SHOW"
        XCTAssertThrowsError(try store.save(edit(url: "ws://remote.example.test/vm/attach", secret: secret))) { error in
            XCTAssertFalse(String(describing: error).contains(secret))
            XCTAssertFalse((error as? CustomStringConvertible)?.description.contains(secret) ?? true)
        }
        XCTAssertEqual(store.secretState(), .notSet)
    }

    func testSecretStateReportsPresenceOnly() throws {
        XCTAssertEqual(store.secretState(), .notSet)
        try store.save(edit(secret: "present"))
        XCTAssertEqual(store.secretState(), .set)
    }

    func testAnInvalidURLWritesNothing() {
        XCTAssertThrowsError(try store.save(edit(url: "https://example.test/mcp"))) { error in
            XCTAssertEqual(error as? SwitchboardConfigStore.Failure, .url(.badURL("https://example.test/mcp")))
        }
        XCTAssertEqual(filesInDir(), [], "a rejected edit must not leave the secret behind")
    }

    func testPlaintextToARemoteHostIsRejectedBeforeAnyWrite() {
        XCTAssertThrowsError(try store.save(edit(url: "ws://remote.example.test/vm/attach"))) { error in
            guard case .url(.plaintextToRemote) = error as? SwitchboardConfigStore.Failure else {
                return XCTFail("wanted plaintextToRemote, got \(error)")
            }
        }
        XCTAssertEqual(filesInDir(), [])
    }

    func testBlankSecretKeepsTheSavedOne() throws {
        try store.save(edit(secret: "first-secret"))
        try store.save(edit(secret: "   ", profile: .observe))
        XCTAssertEqual(store.load()?.secret, "first-secret")
    }

    func testBlankSecretWithNothingSavedIsRejectedAndWritesNothing() {
        XCTAssertThrowsError(try store.save(edit(secret: ""))) { error in
            XCTAssertEqual(error as? SwitchboardConfigStore.Failure, .secretRequired)
        }
        XCTAssertEqual(filesInDir(), [])
    }

    func testOwnerIsRefusedWithoutTheShellEquivalentConfirmation() throws {
        XCTAssertThrowsError(try store.save(edit(profile: .owner, confirmed: false))) { error in
            XCTAssertEqual(error as? SwitchboardConfigStore.Failure, .ownerNeedsConfirmation)
        }
        XCTAssertEqual(filesInDir(), [], "nothing is written when owner is not confirmed")

        try store.save(edit(profile: .owner, confirmed: true))
        XCTAssertEqual(store.load()?.profile, .owner)
    }

    func testProfileChoiceOffersOnlyObserveAndOwnerAndConfirmsOwnerOnly() {
        XCTAssertEqual(ProfileChoice.choices, [.observe, .owner])
        XCTAssertTrue(ProfileChoice.needsConfirmation(.owner))
        XCTAssertFalse(ProfileChoice.needsConfirmation(.observe))
    }

    func testRetiredDesktopProfileFileLoadsAsObserveWithItsWarning() throws {
        try store.save(edit(profile: .observe))
        try "desktop\n".write(to: store.profileFile, atomically: true, encoding: .utf8)
        try store.writeMarker()
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.profile, .observe)
        XCTAssertEqual(loaded.requestedProfile, "desktop")
        XCTAssertEqual(loaded.profileWarning, ToolProfile.retiredWarning)
    }

    func testAnUnrecognisedProfileFileServesObserveAndSaysSo() throws {
        try store.save(edit(profile: .observe))
        try "owner-ish\n".write(to: store.profileFile, atomically: true, encoding: .utf8)
        try store.writeMarker()
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.profile, .observe, "an unknown name must not widen to owner")
        XCTAssertEqual(loaded.requestedProfile, "owner-ish")
        XCTAssertTrue(loaded.profileWarning?.contains("owner-ish") == true)
    }

    func testAConfigDescriptionNeverPrintsTheSecret() {
        let cfg = SwitchboardConfig(url: URL(string: goodURL)!, secret: "HUNTER2-DO-NOT-SHOW", profile: .observe)
        XCTAssertFalse(String(describing: cfg).contains("HUNTER2"))
        XCTAssertFalse(String(reflecting: cfg).contains("HUNTER2"))
        XCTAssertTrue(String(describing: cfg).contains("<redacted>"))
    }

    func testAnExistingDirectoryIsTightenedTo700() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)

        try store.save(edit())

        XCTAssertEqual(mode(dir), 0o700)
    }

    func testHandEditedFilesAreIgnoredUntilTheMenuSavesAgain() throws {
        try store.save(edit(profile: .observe))
        try "wss://hand-edited.example.test/vm/attach\n".write(to: store.urlFile, atomically: true, encoding: .utf8)

        XCTAssertNil(store.load(), "a file changed after the menu saved it must not be dialled")

        try store.save(edit(url: "wss://hand-edited.example.test/vm/attach", profile: .observe))
        XCTAssertEqual(store.load()?.url.host, "hand-edited.example.test")
    }

    func testFilesWithoutAMarkerAreIgnored() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (goodURL + "\n").write(to: store.urlFile, atomically: true, encoding: .utf8)
        try "s3cret\n".write(to: store.secretFile, atomically: true, encoding: .utf8)
        XCTAssertNil(store.load(), "files the menu bar did not write are not trusted")
    }

    func testRotatingTheSecretByHandKeepsTheSavedURLAndProfile() throws {
        try store.save(edit(profile: .observe))
        try "rotated-by-hand\n".write(to: store.secretFile, atomically: true, encoding: .utf8)

        let loaded = try XCTUnwrap(store.load(), "a hand secret rotation must not drop the saved config")
        XCTAssertEqual(loaded.url.host, "switchboard.example.test")
        XCTAssertEqual(loaded.profile, .observe)
        XCTAssertEqual(loaded.secret, "rotated-by-hand")
    }

    func testAHandEditedProfileIsUnsealedAndStartupSaysSo() throws {
        try store.save(edit(profile: .observe))
        try "owner\n".write(to: store.profileFile, atomically: true, encoding: .utf8)

        let inspected = store.inspect()
        XCTAssertTrue(inspected.isUnsealed)
        XCTAssertEqual(inspected.unsealed, .init(url: goodURL, profile: "owner"))

        let alone = SwitchboardStartup.resolve(saved: nil, flags: nil, flagsGiven: false, unsealed: inspected.unsealed)
        XCTAssertEqual(alone.mode, .none, "an unsealed file is never dialled")
        XCTAssertTrue(alone.warning?.contains("changed outside the menu bar") == true)

        let flagged = SwitchboardConfig(url: URL(string: goodURL)!, secret: "b", profile: .observe)
        let withFlags = SwitchboardStartup.resolve(saved: nil, flags: flagged, flagsGiven: true, unsealed: inspected.unsealed)
        XCTAssertEqual(withFlags.mode, .flags, "the launch flags apply while the saved files are ignored")
        XCTAssertTrue(withFlags.warning?.contains("changed outside the menu bar") == true)
    }

    func testAbsentFilesAreNotReportedAsUnsealed() {
        XCTAssertEqual(store.inspect(), .absent)
        XCTAssertNil(SwitchboardStartup.resolve(saved: nil, flags: nil, flagsGiven: false, unsealed: nil).warning)
    }

    func testInstallerLayoutWithoutAMarkerIsAbsentAndSilent() throws {
        // The installer's files, written by hand, with the flags carrying the same values.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (goodURL + "\n").write(to: store.urlFile, atomically: true, encoding: .utf8)
        try "observe\n".write(to: store.profileFile, atomically: true, encoding: .utf8)
        try "s3cret\n".write(to: store.secretFile, atomically: true, encoding: .utf8)

        XCTAssertEqual(store.inspect(), .absent)
        let flagged = SwitchboardConfig(url: URL(string: goodURL)!, secret: "s3cret", profile: .observe)
        let s = SwitchboardStartup.resolve(saved: nil, flags: flagged, flagsGiven: true, unsealed: store.inspect().unsealed)
        XCTAssertEqual(s.mode, .flags)
        XCTAssertNil(s.warning, "no marker means no false 'changed outside the menu bar' warning")
    }

    func testMismatchedMarkerWhoseValuesMatchTheFlagsIsSilent() throws {
        // A hand edit that names the flagged settings again: `desktop` maps to observe, the same as the flag.
        try store.save(edit(profile: .observe))
        try "desktop\n".write(to: store.profileFile, atomically: true, encoding: .utf8)
        let inspected = store.inspect()
        XCTAssertTrue(inspected.isUnsealed)

        let flagged = SwitchboardConfig(url: URL(string: goodURL)!, secret: "b", profile: .observe,
                                        requestedProfile: "desktop", profileWarning: ToolProfile.retiredWarning)
        let s = SwitchboardStartup.resolve(saved: nil, flags: flagged, flagsGiven: true, unsealed: inspected.unsealed)
        XCTAssertEqual(s.mode, .flags)
        XCTAssertNil(s.warning, "equal values are not reported; the profile warning stays on the flagged config")
        XCTAssertEqual(s.config?.profileWarning, ToolProfile.retiredWarning)
    }

    func testMalformedURLHandEditIsReportedNotSilentlyIgnored() throws {
        try store.save(edit(profile: .observe))
        try "not a websocket url\n".write(to: store.urlFile, atomically: true, encoding: .utf8)

        let inspected = store.inspect()
        XCTAssertTrue(inspected.isUnsealed, "the digest is checked before the URL is parsed")
        XCTAssertEqual(inspected.unsealed?.url, "not a websocket url")

        let flagged = SwitchboardConfig(url: URL(string: goodURL)!, secret: "b", profile: .observe)
        let s = SwitchboardStartup.resolve(saved: nil, flags: flagged, flagsGiven: true, unsealed: inspected.unsealed)
        XCTAssertEqual(s.mode, .flags)
        XCTAssertTrue(s.warning?.contains("changed outside the menu bar") == true)
    }

    func testSavedFilesApplyOnlyForTheInstallerLayoutOrAMenuBarWithNoFlags() {
        let store = self.store
        // Headless, no flags: never dials from saved files.
        XCTAssertFalse(SwitchboardStartup.savedFilesApply(flagSecretFile: nil, menuBar: false, store: store))
        XCTAssertEqual(SwitchboardStartup.resolve(saved: nil, flags: nil, flagsGiven: false).mode, .none)
        // Menu bar, no flags: uses saved files.
        XCTAssertTrue(SwitchboardStartup.savedFilesApply(flagSecretFile: nil, menuBar: true, store: store))
        // Installer layout: the flag names the installer's switchboard.secret.
        XCTAssertTrue(SwitchboardStartup.savedFilesApply(flagSecretFile: store.secretFile, menuBar: true, store: store))
        XCTAssertTrue(SwitchboardStartup.savedFilesApply(flagSecretFile: store.secretFile, menuBar: false, store: store))
    }

    func testASecondInstanceWithExplicitFlagsDialsItsFlagsAndNotTheSavedFiles() throws {
        try store.save(edit(profile: .observe))
        let other = dir.appendingPathComponent("other.secret")
        let flags = SwitchboardConfig(url: URL(string: "wss://flag.example.test/vm/attach")!, secret: "b", profile: .owner)

        XCTAssertFalse(SwitchboardStartup.savedFilesApply(flagSecretFile: other, menuBar: false, store: store))
        XCTAssertFalse(SwitchboardStartup.savedFilesApply(flagSecretFile: other, menuBar: true, store: store))

        let s = SwitchboardStartup.resolve(saved: nil, flags: flags, flagsGiven: true)
        XCTAssertEqual(s.mode, .flags)
        XCTAssertEqual(s.config, flags)
    }

    func testLoadNeedsBothTheURLAndTheSecret() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (goodURL + "\n").write(to: store.urlFile, atomically: true, encoding: .utf8)
        XCTAssertNil(store.load())
        XCTAssertEqual(store.secretState(), .notSet)
    }

    func testForgetRemovesTheThreeFilesAndKeepsTheInstallersSecureSetValue() throws {
        try store.save(edit())
        try "allow\n".write(to: dir.appendingPathComponent("switchboard.secure-set-value"),
                            atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try store.forget(confirmed: false)) { error in
            XCTAssertEqual(error as? SwitchboardConfigStore.Failure, .forgetNeedsConfirmation)
        }
        XCTAssertNotNil(store.load(), "a refused forget removes nothing")
        try store.forget(confirmed: true)

        XCTAssertNil(store.load())
        XCTAssertEqual(filesInDir(), ["switchboard.secure-set-value"])
    }

    func testASavedFileWinsOverALaunchFlagAndSaysSo() {
        let saved = SwitchboardConfig(url: URL(string: goodURL)!, secret: "a", profile: .observe)
        let flags = SwitchboardConfig(url: URL(string: "wss://flag.example.test/vm/attach")!, secret: "b", profile: .owner)

        let s = SwitchboardStartup.resolve(saved: saved, flags: flags, flagsGiven: true)

        XCTAssertEqual(s.mode, .saved)
        XCTAssertEqual(s.config, saved)
        XCTAssertNotNil(s.warning, "an overridden flag must be logged")
        XCTAssertFalse(s.warning?.contains("secret") == true, "the warning must not carry secret material")
    }

    func testAnUnreadableFlaggedSecretWithNothingSavedStartsWithTheSwitchboardOff() {
        // The forget case: the plist still has flags, their secret file is gone, nothing is saved.
        // The daemon keeps /mcp and /attach up, so this must not be an exit.
        let s = SwitchboardStartup.resolve(saved: nil, flags: nil, flagsGiven: true)

        XCTAssertEqual(s.mode, .disabled)
        XCTAssertNil(s.config)
        XCTAssertTrue(s.warning?.contains("disabled") == true)
    }

    func testFlagsAloneDialAndNothingGivenIsSilent() {
        let flags = SwitchboardConfig(url: URL(string: goodURL)!, secret: "b", profile: .owner)
        XCTAssertEqual(SwitchboardStartup.resolve(saved: nil, flags: flags, flagsGiven: true).mode, .flags)
        let none = SwitchboardStartup.resolve(saved: nil, flags: nil, flagsGiven: false)
        XCTAssertEqual(none.mode, .none)
        XCTAssertNil(none.warning)
    }
}
