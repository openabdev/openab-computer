import Foundation
import XCTest
@testable import InstanceMCPCore

final class ArtifactDownloaderTests: XCTestCase {
    private var tmp: TempDir!
    override func setUp() { tmp = TempDir() }
    override func tearDown() { tmp.remove() }

    private let payload = Data((0..<5000).map { UInt8($0 % 251) })
    private var digest: String { PlaywrightManifest.sha256Hex(payload) }

    private func downloader(allow: Set<String> = ["127.0.0.1"], timeout: TimeInterval = 5) -> URLSessionArtifactDownloader {
        URLSessionArtifactDownloader(policy: DownloadPolicy(allowedHosts: allow, allowLoopbackHTTP: true), requestTimeout: timeout)
    }

    private func fetch(_ d: URLSessionArtifactDownloader, _ url: String, size: Int64? = nil, sha: String? = nil) async -> PlaywrightInstallFailure? {
        let dest = tmp.url.appendingPathComponent("out-\(UUID().uuidString)").path
        do {
            try await d.download(from: URL(string: url)!, to: dest, expectedSize: size ?? Int64(payload.count), expectedSHA256: sha ?? digest) { _ in }
            XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: dest)), payload)
            return nil
        } catch let f as PlaywrightInstallFailure {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dest), "a failed download leaves no file")
            return f
        } catch { XCTFail("unexpected \(error)"); return .other("x") }
    }

    func testHappyPath() async throws {
        let s = try StubHTTPServer { [payload] _ in HTTPResponse(status: 200, body: payload) }
        defer { s.stop() }
        let r = await fetch(downloader(), "http://127.0.0.1:\(s.port)/a")
        XCTAssertNil(r)
    }

    func testSizeAndDigestMismatchesDeleteTheFile() async throws {
        let s = try StubHTTPServer { [payload] _ in HTTPResponse(status: 200, body: payload) }
        defer { s.stop() }
        let u = "http://127.0.0.1:\(s.port)/a"
        let tooSmall = await fetch(downloader(), u, size: Int64(payload.count - 1))     // more bytes than pinned
        XCTAssertEqual(tooSmall, .digestMismatch)
        let tooBig = await fetch(downloader(), u, size: Int64(payload.count + 1))       // fewer bytes than pinned
        XCTAssertEqual(tooBig, .digestMismatch)
        let wrongDigest = await fetch(downloader(), u, sha: String(repeating: "0", count: 64))
        XCTAssertEqual(wrongDigest, .digestMismatch)
    }

    func testTransferStopsAtThePinnedSize() async throws {
        let huge = Data(count: 8 * 1024 * 1024)
        let s = try StubHTTPServer { _ in HTTPResponse(status: 200, body: huge) }
        defer { s.stop() }
        let r = await fetch(downloader(), "http://127.0.0.1:\(s.port)/a", size: 1000)
        XCTAssertEqual(r, .digestMismatch)
    }

    func testRedirectToAnotherHostIsRefusedAndNeverContacted() async throws {
        for code in [301, 302, 307, 308] {
            let target = try StubHTTPServer { [payload] _ in HTTPResponse(status: 200, body: payload) }
            defer { target.stop() }
            let tport = target.port
            // "localhost" is a different host name from the allowed 127.0.0.1.
            let origin = try StubHTTPServer { _ in HTTPResponse(status: code, headers: [("Location", "http://localhost:\(tport)/x")]) }
            defer { origin.stop() }
            let r = await fetch(downloader(), "http://127.0.0.1:\(origin.port)/a")
            XCTAssertEqual(r, .tls, "\(code)")
            XCTAssertTrue(target.requests.isEmpty, "\(code): the redirect target was contacted")
            XCTAssertEqual(origin.requests.count, 1)
        }
    }

    func testRedirectWithinTheAllowedHostIsFollowed() async throws {
        let s = try StubHTTPServer { [payload] req in
            req.path == "/start" ? HTTPResponse(status: 302, headers: [("Location", "/final")]) : HTTPResponse(status: 200, body: payload)
        }
        defer { s.stop() }
        let r = await fetch(downloader(), "http://127.0.0.1:\(s.port)/start")
        XCTAssertNil(r)
    }

    func testPolicy() {
        let manifest = PlaywrightManifest.embedded
        let p = DownloadPolicy.production(manifest: manifest)
        XCTAssertTrue(p.permits(URL(string: "https://nodejs.org/dist/x")!))
        XCTAssertTrue(p.permits(URL(string: "https://registry.npmjs.org/x")!))
        XCTAssertFalse(p.permits(URL(string: "http://nodejs.org/dist/x")!), "plain http")
        XCTAssertFalse(p.permits(URL(string: "https://evil.example/x")!))
        XCTAssertFalse(p.permits(URL(string: "https://nodejs.org.evil.example/x")!))
        XCTAssertFalse(p.permits(URL(string: "http://127.0.0.1/x")!), "production never allows loopback http")
        XCTAssertFalse(p.permits(URL(string: "https://nodejs.org/a/../b")!))
        XCTAssertFalse(p.permits(URL(string: "file:///etc/passwd")!))
        XCTAssertFalse(DownloadPolicy(allowedHosts: ["127.0.0.1"], allowLoopbackHTTP: true).permits(URL(string: "http://localhost/x")!))
    }

    func testDownloaderRefusesAForbiddenURLWithoutAnyRequest() async throws {
        let s = try StubHTTPServer { _ in .text(200, "x") }
        defer { s.stop() }
        let strict = URLSessionArtifactDownloader(policy: DownloadPolicy(allowedHosts: ["127.0.0.1"], allowLoopbackHTTP: false))
        let r = await fetch(strict, "http://127.0.0.1:\(s.port)/a")
        XCTAssertEqual(r, .tls)
        XCTAssertTrue(s.requests.isEmpty)
    }

    func testNoCookiesOrCredentialsAreSent() async throws {
        let s = try StubHTTPServer { [payload] _ in
            HTTPResponse(status: 200, headers: [("Set-Cookie", "session=canary; Path=/")], body: payload)
        }
        defer { s.stop() }
        for _ in 0..<2 { _ = await fetch(downloader(), "http://127.0.0.1:\(s.port)/a") }
        XCTAssertEqual(s.requests.count, 2)
        for r in s.requests {
            XCTAssertNil(r.header("cookie"))
            XCTAssertNil(r.header("authorization"))
            XCTAssertEqual(r.header("accept-encoding"), "identity")
        }
    }

    func testContentEncodingIsRefused() async throws {
        let s = try StubHTTPServer { [payload] _ in HTTPResponse(status: 200, headers: [("Content-Encoding", "gzip")], body: payload) }
        defer { s.stop() }
        let r = await fetch(downloader(), "http://127.0.0.1:\(s.port)/a")
        XCTAssertEqual(r, .digestMismatch)
    }

    func testNon200IsAFixedClass() async throws {
        let s = try StubHTTPServer { _ in .text(404, "CANARY-body") }
        defer { s.stop() }
        let r = await fetch(downloader(), "http://127.0.0.1:\(s.port)/a")
        XCTAssertEqual(r, .other("http_status"))
    }

    func testClosedPortIsOffline() async throws {
        let s = try StubHTTPServer { _ in .text(200, "x") }
        let port = s.port
        s.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        let r = await fetch(downloader(), "http://127.0.0.1:\(port)/a")
        XCTAssertEqual(r, .offline)
    }

    func testCancelStopsTheTransfer() async throws {
        let s = try StubHTTPServer { _ in
            Thread.sleep(forTimeInterval: 3)
            return HTTPResponse(status: 200, body: Data(count: 10))
        }
        defer { s.stop() }
        let d = downloader(timeout: 10)
        let dest = tmp.url.appendingPathComponent("c").path
        let url = URL(string: "http://127.0.0.1:\(s.port)/a")!
        let t = Task { () -> PlaywrightInstallFailure? in
            do { try await d.download(from: url, to: dest, expectedSize: 10, expectedSHA256: digest) { _ in }; return nil }
            catch let f as PlaywrightInstallFailure { return f } catch { return .other("x") }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        t.cancel()
        let r = await t.value
        XCTAssertEqual(r, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest))
    }

    func testExistingFileIsNeverOverwritten() async throws {
        let s = try StubHTTPServer { [payload] _ in HTTPResponse(status: 200, body: payload) }
        defer { s.stop() }
        let dest = tmp.file("exists", Data("old".utf8))
        do {
            try await downloader().download(from: URL(string: "http://127.0.0.1:\(s.port)/a")!, to: dest.path,
                                            expectedSize: Int64(payload.count), expectedSHA256: digest) { _ in }
            XCTFail("overwrote")
        } catch {}
        XCTAssertEqual(try String(contentsOf: dest), "old")
    }

    func testErrorMapping() {
        XCTAssertEqual(DownloadJob.map(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(DownloadJob.map(URLError(.timedOut)), .interrupted)
        XCTAssertEqual(DownloadJob.map(URLError(.networkConnectionLost)), .interrupted)
        XCTAssertEqual(DownloadJob.map(URLError(.secureConnectionFailed)), .tls)
        XCTAssertEqual(DownloadJob.map(URLError(.serverCertificateUntrusted)), .tls)
        XCTAssertEqual(DownloadJob.map(NSError(domain: "CANARY", code: 1, userInfo: [NSLocalizedDescriptionKey: "CANARY-secret"])), .other("network"))
    }
}
