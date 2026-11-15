import Foundation
import CryptoKit
import Darwin

/// Which URLs the downloader may touch. Info.plist sets `NSAllowsArbitraryLoads`, so HTTPS and the
/// host list are enforced here, for the first request and for every redirect (R7.1).
public struct DownloadPolicy: Sendable, Equatable {
    public let allowedHosts: Set<String>
    let allowLoopbackHTTP: Bool

    public static func production(manifest: PlaywrightManifest) -> DownloadPolicy {
        DownloadPolicy(allowedHosts: Set(manifest.hosts), allowLoopbackHTTP: false)
    }

    /// Tests only (`@testable`): plain http to a loopback literal.
    init(allowedHosts: Set<String>, allowLoopbackHTTP: Bool) {
        self.allowedHosts = allowedHosts; self.allowLoopbackHTTP = allowLoopbackHTTP
    }

    func permits(_ url: URL) -> Bool {
        guard let host = url.host, !url.pathComponents.contains("..") else { return false }
        if url.scheme == "https" { return allowedHosts.contains(host) }
        if allowLoopbackHTTP, url.scheme == "http", host == "127.0.0.1" || host == "::1" { return allowedHosts.contains(host) }
        return false
    }
}

protocol ArtifactDownloader: Sendable {
    /// Streams `url` into a new file at `path`, checking size then SHA-256 against the pin. On any
    /// failure the file is removed.
    func download(from url: URL, to path: String, expectedSize: Int64, expectedSHA256: String,
                  progress: @escaping @Sendable (Int64) -> Void) async throws
}

/// An ephemeral session with no cookies, cache or credentials. Redirects are re-checked against
/// the policy. Bytes are counted as they arrive and the transfer stops the moment the pinned size
/// is crossed, so a hostile server cannot fill the disk.
final class URLSessionArtifactDownloader: ArtifactDownloader, @unchecked Sendable {
    private let policy: DownloadPolicy
    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval

    init(policy: DownloadPolicy, requestTimeout: TimeInterval = 30, resourceTimeout: TimeInterval = 3600) {
        self.policy = policy; self.requestTimeout = requestTimeout; self.resourceTimeout = resourceTimeout
    }

    func download(from url: URL, to path: String, expectedSize: Int64, expectedSHA256: String,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard policy.permits(url) else { throw PlaywrightInstallFailure.tls }
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PlaywrightInstallFailure.other("download_file") }
        let job = DownloadJob(policy: policy, fd: fd, expectedSize: expectedSize, expectedSHA256: expectedSHA256, progress: progress)
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        let session = URLSession(configuration: config, delegate: job, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    job.start(session: session, url: url, continuation: c)
                }
            } onCancel: { job.cancel() }
        } catch {
            unlink(path)
            throw error
        }
    }
}

final class DownloadJob: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let policy: DownloadPolicy
    private let fd: Int32
    private let expectedSize: Int64
    private let expectedSHA256: String
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var hasher = SHA256()
    private var received: Int64 = 0
    private var failure: PlaywrightInstallFailure?
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var closed = false

    init(policy: DownloadPolicy, fd: Int32, expectedSize: Int64, expectedSHA256: String, progress: @escaping @Sendable (Int64) -> Void) {
        self.policy = policy; self.fd = fd; self.expectedSize = expectedSize
        self.expectedSHA256 = expectedSHA256; self.progress = progress
    }

    func start(session: URLSession, url: URL, continuation c: CheckedContinuation<Void, Error>) {
        var req = URLRequest(url: url)
        req.httpShouldHandleCookies = false
        let t = session.dataTask(with: req)
        let alreadyCancelled = lock.withLock { () -> Bool in
            continuation = c; task = t
            return cancelled
        }
        if alreadyCancelled { t.cancel() }
        t.resume()
    }

    func cancel() {
        let t = lock.withLock { () -> URLSessionDataTask? in cancelled = true; return task }
        t?.cancel()
    }

    private func fail(_ f: PlaywrightInstallFailure, cancelTask: URLSessionTask?) {
        lock.withLock { if failure == nil { failure = f } }
        cancelTask?.cancel()
    }

    // MARK: delegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let u = request.url, policy.permits(u) else {
            fail(.tls, cancelTask: task)
            completionHandler(nil)
            return
        }
        var r = request
        r.httpShouldHandleCookies = false
        r.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(r)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            fail(.other("http_status"), cancelTask: dataTask); completionHandler(.cancel); return
        }
        if let enc = http.value(forHTTPHeaderField: "Content-Encoding"), !enc.isEmpty, enc.lowercased() != "identity" {
            fail(.digestMismatch, cancelTask: dataTask); completionHandler(.cancel); return
        }
        if http.expectedContentLength > expectedSize {
            fail(.digestMismatch, cancelTask: dataTask); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let over: Bool = lock.withLock {
            if failure != nil || closed { return true }
            received += Int64(data.count)
            if received > expectedSize { failure = .digestMismatch; return true }
            hasher.update(data: data)
            return false
        }
        if over { dataTask.cancel(); return }
        var off = 0
        let ok: Bool = data.withUnsafeBytes { raw in
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
        if !ok { fail(.other("download_file"), cancelTask: dataTask); return }
        progress(lock.withLock { received })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (cont, result): (CheckedContinuation<Void, Error>?, PlaywrightInstallFailure?) = lock.withLock {
            closed = true
            Darwin.close(fd)
            var f = failure
            if f == nil {
                if let error {
                    f = cancelled ? .cancelled : Self.map(error)
                } else if received != expectedSize {
                    f = .digestMismatch
                } else {
                    let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    if hex != expectedSHA256 { f = .digestMismatch }
                }
            }
            if cancelled && f != nil && f != .cancelled { f = .cancelled }
            let c = continuation
            continuation = nil
            return (c, f)
        }
        if let result { cont?.resume(throwing: result) } else { cont?.resume() }
    }

    static func map(_ error: Error) -> PlaywrightInstallFailure {
        guard let e = error as? URLError else { return .other("network") }
        switch e.code {
        case .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .internationalRoamingOff, .dataNotAllowed:
            return .offline
        case .timedOut, .networkConnectionLost:
            return .interrupted
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection,
             .httpTooManyRedirects, .redirectToNonExistentLocation:
            return .tls
        case .cannotDecodeContentData, .cannotDecodeRawData:
            return .digestMismatch   // a Content-Encoding the request refused: the bytes are not the pinned ones
        case .cancelled:
            return .cancelled
        default:
            return .other("network")
        }
    }
}
