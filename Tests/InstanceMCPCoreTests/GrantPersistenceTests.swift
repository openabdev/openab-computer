import Foundation
import XCTest
@testable import InstanceMCPCore

/// #12: grants survive a daemon restart. These use `FileGrantStore` against a temp
/// directory with an in-memory `SecretStore` — CI has no usable login Keychain,
/// and the Keychain backend is exercised live on the Mac instead.
final class GrantPersistenceTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grants-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store(_ secrets: InMemorySecretStore) -> FileGrantStore {
        FileGrantStore(url: dir.appendingPathComponent("sub/grants.json"), secrets: secrets)
    }

    private func grant(_ id: String, expiresIn: TimeInterval) -> PersistedGrant {
        PersistedGrant(id: id, runtime: URL(string: "ws://127.0.0.1:9")!, session: "s", profile: "owner",
                       principal: "a@b", createdAt: Date(), expiresAt: Date().addingTimeInterval(expiresIn),
                       secret: "secret-\(id)")
    }

    private func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: store

    func testRoundTripKeepsTheSecretOutOfTheFile() throws {
        let secrets = InMemorySecretStore()
        let s = store(secrets)
        s.save([grant("a", expiresIn: 600), grant("b", expiresIn: 600)])

        XCTAssertEqual(mode(s.url.path) & 0o777, 0o600)
        XCTAssertEqual(mode(s.url.deletingLastPathComponent().path) & 0o777, 0o700)
        let onDisk = try String(contentsOf: s.url, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("secret-a"), "secret must not be in the record file")
        XCTAssertEqual(secrets.accounts, ["a", "b"])

        let loaded = s.load()
        XCTAssertEqual(loaded.map(\.id), ["a", "b"])
        XCTAssertEqual(loaded.map(\.secret), ["secret-a", "secret-b"])
    }

    func testRemovedGrantsLoseTheirSecrets() {
        let secrets = InMemorySecretStore()
        let s = store(secrets)
        s.save([grant("a", expiresIn: 600), grant("b", expiresIn: 600)])
        s.save([grant("b", expiresIn: 600)])
        XCTAssertEqual(secrets.accounts, ["b"])
        XCTAssertEqual(s.load().map(\.id), ["b"])
    }

    func testExpiredOrSecretlessRecordsAreDroppedOnLoad() {
        let secrets = InMemorySecretStore()
        let s = store(secrets)
        s.save([grant("live", expiresIn: 600), grant("stale", expiresIn: -1), grant("orphan", expiresIn: 600)])
        secrets.delete(account: "orphan")
        XCTAssertEqual(s.load().map(\.id), ["live"])
    }

    func testAWidenedFileIsNarrowedBeforeItIsRead() {
        let s = store(InMemorySecretStore())
        s.save([grant("a", expiresIn: 600)])
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: s.url.path)
        XCTAssertEqual(s.load().count, 1)
        XCTAssertEqual(mode(s.url.path) & 0o777, 0o600)
    }

    func testMissingOrCorruptFileIsEmpty() throws {
        let s = store(InMemorySecretStore())
        XCTAssertTrue(s.load().isEmpty)
        try FileManager.default.createDirectory(at: s.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: s.url)
        XCTAssertTrue(s.load().isEmpty)
    }

    // MARK: manager

    private func request(_ session: String, secret: String = "abc", ttl: TimeInterval = 60) -> AttachManager.Request {
        // Unreachable runtime: the grant exists and its client keeps redialling.
        AttachManager.Request(runtime: URL(string: "ws://127.0.0.1:9")!, session: session, profile: .owner,
                              ttl: ttl, secret: secret, adminCredential: nil)
    }

    func testAGrantIsResumedUnderTheSameIdAfterARestart() async throws {
        let secrets = InMemorySecretStore()
        let first = AttachManager(server: fullServer(), store: store(secrets))
        let created = try await first.create(request("laptop", secret: "k1"), principal: "a@b")
        XCTAssertEqual(secrets.get(account: created.id), "k1")

        // "Restart": a fresh manager over the same store. The old one is simply
        // abandoned, as a killed process would be.
        let second = AttachManager(server: fullServer(), store: store(secrets))
        let resumed = await second.resume()
        XCTAssertEqual(resumed, 1)
        let grants = await second.list()
        XCTAssertEqual(grants.map(\.id), [created.id])
        XCTAssertEqual(grants.first?.session, "laptop")
        XCTAssertEqual(grants.first?.profile, .owner)
        XCTAssertEqual(grants.first?.principal, "a@b")
        XCTAssertEqual(grants.first?.expiresAt.timeIntervalSince1970 ?? 0,
                       created.expiresAt.timeIntervalSince1970, accuracy: 1)

        await second.revoke(created.id)
        await first.revoke(created.id)
    }

    func testARevokedGrantIsNotResumed() async throws {
        let secrets = InMemorySecretStore()
        let mgr = AttachManager(server: fullServer(), store: store(secrets))
        let g = try await mgr.create(request("laptop"), principal: "a@b")
        await mgr.revoke(g.id)
        XCTAssertTrue(secrets.accounts.isEmpty, "revoke deletes the Keychain secret")
        let next = AttachManager(server: fullServer(), store: store(secrets))
        let resumed = await next.resume()
        XCTAssertEqual(resumed, 0)
        let remaining = await next.list()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAReplacedGrantLeavesOnlyTheNewOnePersisted() async throws {
        let secrets = InMemorySecretStore()
        let mgr = AttachManager(server: fullServer(), store: store(secrets))
        let old = try await mgr.create(request("laptop", secret: "old"), principal: "a@b")
        let new = try await mgr.create(request("laptop", secret: "new"), principal: "a@b")
        XCTAssertEqual(secrets.accounts, [new.id])
        XCTAssertNil(secrets.get(account: old.id))
        await mgr.revoke(new.id)
    }

    /// instance-mcp#45: `sandbox` is refused, not aliased. A grant stored under it by an
    /// older build ends at resume instead of coming back under any profile.
    func testAGrantStoredUnderTheOldSandboxNameIsDropped() async throws {
        let secrets = InMemorySecretStore()
        let old = PersistedGrant(id: "old-sandbox", runtime: URL(string: "ws://127.0.0.1:9")!, session: "s",
                                 profile: "sandbox", principal: "a@b", createdAt: Date(),
                                 expiresAt: Date().addingTimeInterval(600), secret: "secret-old")
        store(secrets).save([old])
        let mgr = AttachManager(server: fullServer(), store: store(secrets))
        let resumed = await mgr.resume()
        XCTAssertEqual(resumed, 0)
        let remaining = await mgr.list()
        XCTAssertTrue(remaining.isEmpty)
    }

    /// #59: a grant stored as `desktop` by 0.8.x is kept and re-dialled under its id,
    /// but serves `observe`, reports the mapping, and is rewritten so the file says so.
    func testAGrantStoredAsDesktopResumesAsObserve() async throws {
        let secrets = InMemorySecretStore()
        let s = store(secrets)
        // Exactly what 0.8.x wrote: no requestedProfile key.
        try FileManager.default.createDirectory(at: s.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(600))
        let created = ISO8601DateFormatter().string(from: Date())
        try Data("""
            {"grants":[{"createdAt":"\(created)","expiresAt":"\(expires)","id":"old-desktop","principal":"a@b","profile":"desktop","runtime":"ws:\\/\\/127.0.0.1:9","session":"s"}],"version":1}
            """.utf8).write(to: s.url)
        _ = secrets.set("secret-old", account: "old-desktop")

        let audit = InMemoryAuditLog()
        let mgr = AttachManager(server: fullServer(), store: s, audit: audit)
        let resumed = await mgr.resume()
        XCTAssertEqual(resumed, 1)
        let entry = try XCTUnwrap(audit.entries.first)
        XCTAssertEqual(audit.entries.count, 1)
        XCTAssertEqual(entry["event"]?.stringValue, "profile_mapped")
        XCTAssertEqual(entry["source"]?.stringValue, "resume")
        XCTAssertEqual(entry["grant"]?.stringValue, "old-desktop")
        XCTAssertEqual(entry["requested_profile"]?.stringValue, "desktop")
        XCTAssertEqual(entry["profile"]?.stringValue, "observe")
        let fetched = await mgr.get("old-desktop")
        let g = try XCTUnwrap(fetched)
        XCTAssertEqual(g.profile, .observe)
        XCTAssertEqual(g.requestedProfile, "desktop")
        XCTAssertEqual(g.warning, ToolProfile.retiredWarning)
        XCTAssertEqual(g.json["profile"]?.stringValue, "observe")
        XCTAssertEqual(g.json["requested_profile"]?.stringValue, "desktop")
        XCTAssertEqual(g.json["warning"]?.stringValue, ToolProfile.retiredWarning)

        let rewritten = s.load()
        XCTAssertEqual(rewritten.map(\.profile), ["observe"])
        XCTAssertEqual(rewritten.map(\.requestedProfile), ["desktop"])

        // A second restart keeps it at observe, with the same report.
        let again = AttachManager(server: fullServer(), store: store(secrets))
        _ = await again.resume()
        let g2 = await again.get("old-desktop")
        XCTAssertEqual(g2?.profile, .observe)
        XCTAssertEqual(g2?.warning, ToolProfile.retiredWarning)
        await again.revoke("old-desktop")
        await mgr.revoke("old-desktop")
    }

    /// #59 review: `create` serves the narrower of `profile` and `requestedProfile`,
    /// so a caller pairing `owner` with `desktop` still gets `observe`, and the
    /// mapping is audited. An unmapped request writes no audit record.
    func testCreateNeverServesWiderThanTheRequestedName() async throws {
        let audit = InMemoryAuditLog()
        let mgr = AttachManager(server: fullServer(), audit: audit)
        var r = request("mixed")
        r.requestedProfile = "desktop"
        let g = try await mgr.create(r, principal: "a@b")
        XCTAssertEqual(g.profile, .observe)
        XCTAssertEqual(g.warning, ToolProfile.retiredWarning)
        XCTAssertEqual(audit.entries.map { $0["source"]?.stringValue }, ["attach"])
        XCTAssertEqual(audit.entries.first?["grant"]?.stringValue, g.id)
        XCTAssertEqual(audit.entries.first?["session"]?.stringValue, "mixed")
        let plain = try await mgr.create(request("plain"), principal: "a@b")
        XCTAssertEqual(plain.profile, .owner)
        XCTAssertEqual(audit.entries.count, 1)
        await mgr.revoke(g.id); await mgr.revoke(plain.id)
    }

    /// #59 review: a non-string `requestedProfile` counts as absent (as on Linux), so
    /// one hand-edited row does not drop the whole file.
    func testANonStringRequestedProfileCountsAsAbsent() throws {
        let secrets = InMemorySecretStore()
        let s = store(secrets)
        try FileManager.default.createDirectory(at: s.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(600))
        let created = ISO8601DateFormatter().string(from: Date())
        try Data("""
            {"grants":[{"createdAt":"\(created)","expiresAt":"\(expires)","id":"odd","principal":"a@b","profile":"observe","requestedProfile":7,"runtime":"ws:\\/\\/127.0.0.1:9","session":"s"},{"createdAt":"\(created)","expiresAt":"\(expires)","id":"fine","principal":"a@b","profile":"owner","runtime":"ws:\\/\\/127.0.0.1:9","session":"t"}],"version":1}
            """.utf8).write(to: s.url)
        _ = secrets.set("k1", account: "odd"); _ = secrets.set("k2", account: "fine")
        let loaded = s.load()
        XCTAssertEqual(loaded.map(\.id), ["odd", "fine"])
        XCTAssertEqual(loaded.map(\.profile), ["observe", "owner"])
        XCTAssertEqual(loaded.map(\.requestedProfile), [nil, nil])
    }

    /// #59: the audit file is append-only JSON lines, mode 600, in a 0700 directory.
    func testFileAuditLogAppendsPrivateJSONLines() throws {
        let url = dir.appendingPathComponent("audit/audit.jsonl")
        let log = FileAuditLog(url: url)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        log.append(ProfileAudit.mapped(source: "switchboard", requested: "desktop", profile: .observe, at: when))
        log.append(ProfileAudit.mapped(source: "attach", requested: "desktop", profile: .observe,
                                       grant: "g", session: "s", principal: "a@b", at: when))
        XCTAssertEqual(mode(url.path) & 0o777, 0o600)
        XCTAssertEqual(mode(url.deletingLastPathComponent().path) & 0o777, 0o700)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let first = decodeJSON(Data(lines[0].utf8))
        XCTAssertEqual(first["source"]?.stringValue, "switchboard")
        XCTAssertEqual(first["ts_epoch_secs"]?.intValue, 1_700_000_000)
        XCTAssertNil(first["grant"])
        let second = decodeJSON(Data(lines[1].utf8))
        XCTAssertEqual(second["grant"]?.stringValue, "g")
        XCTAssertEqual(second["principal"]?.stringValue, "a@b")
    }

    func testWithoutAStoreNothingIsPersisted() async throws {
        let mgr = AttachManager(server: fullServer())
        let g = try await mgr.create(request("laptop"), principal: "a@b")
        let resumed = await mgr.resume()
        XCTAssertEqual(resumed, 0)
        await mgr.revoke(g.id)
    }
}
