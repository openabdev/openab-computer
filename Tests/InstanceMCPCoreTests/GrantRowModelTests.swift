import Foundation
import XCTest
@testable import InstanceMCPCore

final class GrantRowModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func grant(profile: ToolProfile, requested: String, warning: String?,
                       state: ReverseAttachClient.State = .attached, expiresIn: TimeInterval = 3600) -> AttachManager.Grant {
        AttachManager.Grant(
            id: "11111111-2222-3333-4444-555555555555",
            runtime: URL(string: "ws://localhost:8090")!,
            session: "kiro-1",
            profile: profile,
            requestedProfile: requested,
            warning: warning,
            principal: "someone",
            createdAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(expiresIn),
            state: state)
    }

    func testAMappedDesktopGrantShowsTheRequestedNameAndTheWarning() {
        let row = GrantRowModel.make(
            grant(profile: .observe, requested: "desktop", warning: ToolProfile.retiredWarning), now: now)

        XCTAssertEqual(row.profile, "observe")
        XCTAssertEqual(row.requestedProfile, "desktop")
        XCTAssertEqual(row.warning, ToolProfile.retiredWarning)
        XCTAssertEqual(row.session, "kiro-1")
        XCTAssertEqual(row.stateLabel, "attached")
        XCTAssertEqual(row.expiresText, "expires in 1 h")
    }

    func testAGrantThatAskedForItsServedProfileShowsNoRequestedNameOrWarning() {
        let row = GrantRowModel.make(grant(profile: .owner, requested: "owner", warning: nil), now: now)

        XCTAssertNil(row.requestedProfile)
        XCTAssertNil(row.warning)
        XCTAssertEqual(row.profile, "owner")
    }

    func testStateLabelsCoverEveryState() {
        XCTAssertEqual(GrantRowModel.stateLabel(.idle), "idle")
        XCTAssertEqual(GrantRowModel.stateLabel(.dialing), "dialling")
        XCTAssertEqual(GrantRowModel.stateLabel(.waitingToRedial(seconds: 29.6)), "redialling in 30 s")
        XCTAssertEqual(GrantRowModel.stateLabel(.ended(.revoked)), "revoked")
        XCTAssertEqual(GrantRowModel.stateLabel(.ended(.handshakeRejected(401))), "handshake rejected 401")
    }

    func testExpiryTextAtEachScale() {
        XCTAssertEqual(GrantRowModel.expiresText(now, now: now), "expired")
        XCTAssertEqual(GrantRowModel.expiresText(now.addingTimeInterval(30), now: now), "expires in under a minute")
        XCTAssertEqual(GrantRowModel.expiresText(now.addingTimeInterval(14 * 60), now: now), "expires in 14 min")
        XCTAssertEqual(GrantRowModel.expiresText(now.addingTimeInterval(7_200), now: now), "expires in 2 h")
        XCTAssertEqual(GrantRowModel.expiresText(now.addingTimeInterval(5_400), now: now), "expires in 1 h 30 min")
    }
}
