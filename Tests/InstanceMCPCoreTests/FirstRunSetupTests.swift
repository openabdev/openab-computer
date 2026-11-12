import Foundation
import XCTest
@testable import InstanceMCPCore

final class FirstRunSetupTests: XCTestCase {
    private var home: String!

    override func setUpWithError() throws {
        home = (FileManager.default.temporaryDirectory
            .appendingPathComponent("first-run-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    private func mode(of path: String) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testNoArgumentsIsTheFirstRunLaunchAndFlagsAreNot() {
        XCTAssertTrue(FirstRunSetup.isNoFlagLaunch(arguments: []))
        XCTAssertTrue(FirstRunSetup.isNoFlagLaunch(arguments: ["-psn_0_12345"]))
        XCTAssertFalse(FirstRunSetup.isNoFlagLaunch(arguments: ["--menu-bar"]))
        XCTAssertFalse(FirstRunSetup.isNoFlagLaunch(arguments: ["--port", "8796"]))
        XCTAssertFalse(FirstRunSetup.isNoFlagLaunch(arguments: ["--token-file", "/tmp/t", "--menu-bar"]))
    }

    func testTokenPathIsInApplicationSupport() {
        XCTAssertEqual(FirstRunSetup.tokenPath(home: "/Users/x"),
                       "/Users/x/Library/Application Support/oab-instance-mcp/token")
    }

    func testFirstRunCreatesTokenWithMode600AndLaterRunReusesIt() throws {
        let path = FirstRunSetup.tokenPath(home: home)

        let first = try FirstRunSetup.loadOrCreateToken(at: path)
        XCTAssertTrue(first.created)
        XCTAssertEqual(first.token.count, 64)
        XCTAssertTrue(first.token.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try mode(of: path), 0o600)
        let onDisk = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(onDisk, first.token + "\n", "same format as `openssl rand -hex 32` written by the installer")

        let second = try FirstRunSetup.loadOrCreateToken(at: path)
        XCTAssertFalse(second.created)
        XCTAssertEqual(second.token, first.token, "a later launch reuses the stored token")
        XCTAssertEqual(try mode(of: path), 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent + "/.token.\(getpid()).tmp"))
    }

    func testExistingTokenIsReusedEvenWhenItsModeWasLoosened() throws {
        let path = FirstRunSetup.tokenPath(home: home)
        let first = try FirstRunSetup.loadOrCreateToken(at: path)
        XCTAssertEqual(chmod(path, 0o644), 0)

        let again = try FirstRunSetup.loadOrCreateToken(at: path)
        XCTAssertEqual(again.token, first.token)
        XCTAssertEqual(try mode(of: path), 0o600, "every launch restores mode 600, as the installer does")
    }

    func testEmptyTokenFileIsReplacedNotReused() throws {
        let path = FirstRunSetup.tokenPath(home: home)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try "  \n".write(toFile: path, atomically: false, encoding: .utf8)

        let result = try FirstRunSetup.loadOrCreateToken(at: path)
        XCTAssertTrue(result.created)
        XCTAssertEqual(result.token.count, 64)
    }

    func testTailscaleLoginIsReadTheSameWayTheInstallerReadsIt() {
        let json = """
        {"Self":{"DNSName":"mac.tailb836bb.ts.net.","UserID":12345},
         "User":{"12345":{"LoginName":"owner@example.com"}}}
        """
        XCTAssertEqual(FirstRunSetup.tailscaleLogin(statusJSON: Data(json.utf8)), "owner@example.com")
    }

    func testTailscaleLoginIsNilWhenAnyInstallerFieldIsMissing() {
        let noDNS = #"{"Self":{"DNSName":"","UserID":1},"User":{"1":{"LoginName":"a@b.c"}}}"#
        let badUID = #"{"Self":{"DNSName":"m.ts.net.","UserID":"abc"},"User":{"abc":{"LoginName":"a@b.c"}}}"#
        let noUser = #"{"Self":{"DNSName":"m.ts.net.","UserID":1},"User":{"2":{"LoginName":"a@b.c"}}}"#
        let emptyLogin = #"{"Self":{"DNSName":"m.ts.net.","UserID":1},"User":{"1":{"LoginName":""}}}"#
        let notJSON = "Logged out"
        for case let body in [noDNS, badUID, noUser, emptyLogin, notJSON] {
            XCTAssertNil(FirstRunSetup.tailscaleLogin(statusJSON: Data(body.utf8)), body)
        }
    }

    func testTokenOnlyNoticeNamesTheFallback() {
        XCTAssertTrue(FirstRunSetup.tokenOnlyNotice.contains("bearer token only"))
    }
}
