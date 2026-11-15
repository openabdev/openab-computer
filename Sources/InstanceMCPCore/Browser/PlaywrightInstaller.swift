import Foundation
import Darwin

/// Downloads, verifies, installs, updates and removes the managed Playwright (R7.1 to R7.7).
///
/// Everything it downloads is checked against the manifest built into the signed app before it is
/// used or extracted. It never adds or removes `com.apple.quarantine`. A first install and an
/// update are the same flow; an update never starts unless the caller asks for it. The managed
/// tier reads `install.json` on every call, so nothing here needs a restart.
public final class PlaywrightInstaller: @unchecked Sendable {
    // MARK: configuration

    let root: URL
    let manifest: PlaywrightManifest
    let archProvider: any ArchProvider
    let downloader: any ArtifactDownloader
    let verifier: any NodeSignatureVerifying
    let packageJSON: String
    let lockfileJSON: String
    let allowLoopbackHTTP: Bool
    let freeDisk: @Sendable (URL) -> Int64
    let now: @Sendable () -> Date
    let lockTries: Int
    let lockInterval: UInt64
    let npmTimeout: TimeInterval
    let healthTimeout: TimeInterval
    private let stopManaged: @Sendable () async -> Void
    private let verifyServing: @Sendable () async -> Bool
    private let onRemoved: @Sendable () -> Void
    private let log: @Sendable (String) -> Void

    private let stateLock = NSLock()
    private var current: Task<Result<PlaywrightInstallState, PlaywrightInstallFailure>, Never>?

    /// The production installer: the embedded manifest, the real downloader and the Security
    /// framework signature check.
    public static func standard(root: URL,
                                stopManaged: @escaping @Sendable () async -> Void,
                                verifyServing: @escaping @Sendable () async -> Bool,
                                onRemoved: @escaping @Sendable () -> Void,
                                log: @escaping @Sendable (String) -> Void) -> PlaywrightInstaller {
        let m = PlaywrightManifest.embedded
        return PlaywrightInstaller(root: root, manifest: m, archProvider: SystemArchProvider(),
                                   downloader: URLSessionArtifactDownloader(policy: .production(manifest: m)),
                                   verifier: SecurityFrameworkNodeVerifier(),
                                   packageJSON: PlaywrightPins.packageJSON, lockfileJSON: PlaywrightPins.lockfileJSON,
                                   allowLoopbackHTTP: false, freeDisk: { PlaywrightInstaller.systemFreeDisk($0) }, now: { Date() },
                                   lockTries: 50, lockInterval: 100_000_000, npmTimeout: 600, healthTimeout: 60,
                                   stopManaged: stopManaged, verifyServing: verifyServing, onRemoved: onRemoved, log: log)
    }

    init(root: URL, manifest: PlaywrightManifest, archProvider: any ArchProvider, downloader: any ArtifactDownloader,
         verifier: any NodeSignatureVerifying, packageJSON: String, lockfileJSON: String, allowLoopbackHTTP: Bool,
         freeDisk: @escaping @Sendable (URL) -> Int64, now: @escaping @Sendable () -> Date,
         lockTries: Int, lockInterval: UInt64, npmTimeout: TimeInterval, healthTimeout: TimeInterval,
         stopManaged: @escaping @Sendable () async -> Void, verifyServing: @escaping @Sendable () async -> Bool,
         onRemoved: @escaping @Sendable () -> Void, log: @escaping @Sendable (String) -> Void) {
        self.root = root; self.manifest = manifest; self.archProvider = archProvider; self.downloader = downloader
        self.verifier = verifier; self.packageJSON = packageJSON; self.lockfileJSON = lockfileJSON
        self.allowLoopbackHTTP = allowLoopbackHTTP; self.freeDisk = freeDisk; self.now = now
        self.lockTries = lockTries; self.lockInterval = lockInterval; self.npmTimeout = npmTimeout
        self.healthTimeout = healthTimeout; self.stopManaged = stopManaged; self.verifyServing = verifyServing
        self.onRemoved = onRemoved; self.log = log
    }

    static func systemFreeDisk(_ url: URL) -> Int64 {
        var s = statfs()
        guard statfs(url.path, &s) == 0 else { return 0 }
        return Int64(s.f_bavail) * Int64(s.f_bsize)
    }

    private func emit(_ e: InstallLogEvent) { log(e.line) }

    // MARK: public API

    /// For the consent text: every number comes from the manifest.
    public func plan() -> PlaywrightInstallPlan {
        PlaywrightInstallPlan(manifest: manifest, arch: archProvider.arch, root: root)
    }

    /// Reads `install.json` and checks the files exist. No network and no child process.
    public func state() -> PlaywrightInstallState {
        guard let rec = readRecord() else {
            return FileManager.default.fileExists(atPath: root.appendingPathComponent("install.json").path) ? .invalid : .notInstalled
        }
        guard Self.safeVersion(rec.version) else { return .invalid }
        let base = root.appendingPathComponent(rec.version, isDirectory: true)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue,
              fm.isExecutableFile(atPath: base.appendingPathComponent("node/bin/node").path),
              fm.fileExists(atPath: base.appendingPathComponent("pkg/node_modules/@playwright/mcp/cli.js").path),
              fm.isExecutableFile(atPath: base.appendingPathComponent(rec.chromiumExecutable).path) else { return .invalid }
        var stale = false
        if let installed = rec.chromiumReleasedAt.flatMap(PlaywrightManifest.parseDay),
           let latest = PlaywrightManifest.parseDay(manifest.chromium.releasedAt) {
            stale = latest.timeIntervalSince(installed) > Double(manifest.staleAfterDays) * 86400
        }
        return .installed(id: rec.version, updateAvailable: rec.version != manifest.id, stale: stale)
    }

    /// One flow for a first install and for an update.
    public func install(progress: @escaping @Sendable (PlaywrightInstallProgress) -> Void)
        async -> Result<PlaywrightInstallState, PlaywrightInstallFailure> {
        // One install at a time in this process, so `cancel()` always reaches the running one.
        let started: Task<Result<PlaywrightInstallState, PlaywrightInstallFailure>, Never>? = stateLock.withLock {
            if current != nil { return nil }
            let t = Task { await self.runInstall(progress) }
            current = t
            return t
        }
        guard let task = started else { return .failure(.lockHeld) }
        let r = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        stateLock.withLock { if current == task { current = nil } }
        return r
    }

    /// Stops a running install, kills its children and removes its staging directory.
    public func cancel() async {
        let t = stateLock.withLock { current }
        t?.cancel()
        _ = await t?.value
    }

    /// Deletes what the installer created under the root, including the browser profile. Idempotent.
    public func remove() async -> Result<Void, PlaywrightInstallFailure> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { onRemoved(); emit(.removed); return .success(()) }
        do { try await acquireLock() }
        catch let f as PlaywrightInstallFailure { return .failure(f) }
        catch { return .failure(.other("lock")) }
        // Only what this installer wrote: a record it wrote (`manifestId`) owns install.json, profile
        // and output; a version directory must carry the ownership marker.
        // An unreadable install.json proves nothing about ownership, so it, the profile and the output
        // stay; marked version directories are still removed.
        let ownsRoot = recordIsOurs(readRecord())
        // install.json goes first so a browser_* call cannot respawn the child from a directory being deleted.
        if ownsRoot { try? fm.removeItem(at: root.appendingPathComponent("install.json")) }
        await stopManaged()
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        for n in names where n != ".install.lock" && isOurs(n, ownsRoot: ownsRoot) {
            do { try fm.removeItem(at: root.appendingPathComponent(n)) }
            catch { releaseLock(); emit(.installFailed("remove_failed")); return .failure(.other("remove_failed")) }
        }
        releaseLock()
        // Only an empty directory is removed: anything the installer did not create stays.
        rmdir(root.path)
        onRemoved()
        emit(.removed)
        return .success(())
    }

    /// At launch: removes staging directories and orphaned version directories left by a crash,
    /// and a stale lock. Does nothing while another install holds the lock.
    public func sweepStaging() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        // One non-waiting attempt at the same lock an install holds: a live holder means no sweep.
        var got = mkdir(lockURL.path, 0o700) == 0
        if !got, errno == EEXIST, reclaimStaleLock() { got = mkdir(lockURL.path, 0o700) == 0 }
        guard got else { return }
        let start = Self.processStart(getpid()).map { " \($0)" } ?? ""
        try? "\(getpid())\(start)\n".write(to: lockURL.appendingPathComponent("pid"), atomically: false, encoding: .utf8)
        defer { releaseLock() }
        let keep = readRecord()?.version
        var n = 0
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let isStaging = Self.hasUUIDSuffix(name, prefix: ".staging-")
            let isOrphan = name != keep && hasOwnershipMarker(name)
            if isStaging || isOrphan, (try? fm.removeItem(at: root.appendingPathComponent(name))) != nil { n += 1 }
        }
        if n > 0 { emit(.swept(n)) }
    }

    // MARK: names

    static func safeVersion(_ v: String) -> Bool {
        !v.isEmpty && !v.contains("/") && v != "." && v != ".." && !v.hasPrefix(".")
    }

    static let ownershipMarker = ".oab-owned"

    static func hasUUIDSuffix(_ name: String, prefix: String) -> Bool {
        name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    /// A version directory this installer created carries a regular marker file written before the rename.
    func hasOwnershipMarker(_ name: String) -> Bool {
        guard PlaywrightManifest.isSafeID(name) else { return false }
        var st = stat()
        let dir = root.appendingPathComponent(name)
        guard lstat(dir.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        return lstat(dir.appendingPathComponent(Self.ownershipMarker).path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    /// Entries the installer creates; `remove` deletes only these.
    func isOurs(_ name: String, ownsRoot: Bool) -> Bool {
        if Self.hasUUIDSuffix(name, prefix: ".staging-") || Self.hasUUIDSuffix(name, prefix: "install.json.tmp-") { return true }
        if ownsRoot, ["install.json", "profile", "output"].contains(name) { return true }
        return hasOwnershipMarker(name)
    }

    // MARK: install.json

    struct Digests: Codable { let node: String; let chromium: String; let lockfile: String }
    struct Record: Codable {
        var version: String
        var chromiumExecutable: String
        var manifestId: String?
        var arch: String?
        var chromiumRevision: String?
        var chromiumReleasedAt: String?
        var installedAt: String?
        var previous: String?
        var digests: Digests?
    }

    /// A record is the installer's own only if `manifestId` names its version AND that version directory
    /// carries the ownership marker the installer wrote. Hand-written JSON cannot fake the marker check.
    func recordIsOurs(_ r: Record?) -> Bool {
        guard let r, let id = r.manifestId, id == r.version, Self.safeVersion(r.version) else { return false }
        return hasOwnershipMarker(r.version)
    }

    func readRecord() -> Record? {
        guard let d = try? Data(contentsOf: root.appendingPathComponent("install.json")) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: d)
    }

    /// Writes `data` to a temp file and renames it over `url`, but only if `url` still holds `replacing`
    /// (nil: it must not exist). A file changed by someone else meanwhile is never overwritten.
    private func writeAtomically(_ data: Data, to url: URL, replacing: Data?) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent("install.json.tmp-\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PlaywrightInstallFailure.other("write_install_json") }
        var off = 0
        let ok: Bool = data.withUnsafeBytes { raw in
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
        fsync(fd)
        Darwin.close(fd)
        guard ok else { unlink(tmp.path); throw PlaywrightInstallFailure.other("write_install_json") }
        let current = try? Data(contentsOf: url)
        guard current == replacing else { unlink(tmp.path); throw PlaywrightInstallFailure.other("foreign_install") }
        // With nothing to replace the rename must not clobber a file that appears now.
        let renamed = replacing == nil ? renamex_np(tmp.path, url.path, UInt32(RENAME_EXCL)) : rename(tmp.path, url.path)
        guard renamed == 0 else {
            unlink(tmp.path)
            throw PlaywrightInstallFailure.other(replacing == nil && errno == EEXIST ? "foreign_install" : "write_install_json")
        }
    }

    // MARK: lock

    private var lockURL: URL { root.appendingPathComponent(".install.lock", isDirectory: true) }

    /// The pid file holds "<pid> <start seconds>", so a recycled pid does not keep a dead owner's lock alive.
    private func lockOwner() -> (pid: pid_t, start: Int64?)? {
        guard let s = try? String(contentsOf: lockURL.appendingPathComponent("pid"), encoding: .utf8) else { return nil }
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard let first = parts.first, let p = pid_t(first) else { return nil }
        return (p, parts.count > 1 ? Int64(parts[1]) : nil)
    }

    private static func processStart(_ p: pid_t) -> Int64? {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return n == Int32(MemoryLayout<proc_bsdinfo>.size) ? Int64(info.pbi_start_tvsec) : nil
    }

    private func pidAlive(_ o: (pid: pid_t, start: Int64?)) -> Bool {
        guard kill(o.pid, 0) == 0 || errno == EPERM else { return false }
        if let s = o.start, let now = Self.processStart(o.pid) { return s == now }
        return true
    }

    /// A lock whose recorded process is gone is reclaimed; one with no pid file yet is given a few
    /// seconds, because its owner may be between `mkdir` and the pid write.
    private func reclaimStaleLock() -> Bool {
        var st = stat()
        guard lstat(lockURL.path, &st) == 0 else { return false }
        if let o = lockOwner() {
            guard !pidAlive(o) else { return false }
        } else if Date().timeIntervalSince1970 - Double(st.st_mtimespec.tv_sec) < 5 {
            return false
        }
        // Rename first, so two reclaimers cannot delete a lock the other just took: only one rename wins,
        // and a lock that turns out live is put back.
        let judged = lockOwner()
        let gone = root.appendingPathComponent(".install.lock.stale-\(UUID().uuidString)", isDirectory: true)
        guard rename(lockURL.path, gone.path) == 0 else { return false }
        let moved = (try? String(contentsOf: gone.appendingPathComponent("pid"), encoding: .utf8)) ?? ""
        let judgedText = judged.map { "\($0.pid)" } ?? ""
        if let o = judged, !moved.hasPrefix(judgedText) || pidAlive(o) {
            if rename(gone.path, lockURL.path) != 0 { try? FileManager.default.removeItem(at: gone) }
            return false
        }
        try? FileManager.default.removeItem(at: gone)
        return true
    }

    private func lockIsLive() -> Bool {
        var st = stat()
        guard lstat(lockURL.path, &st) == 0 else { return false }
        if let o = lockOwner() { return pidAlive(o) }
        return Date().timeIntervalSince1970 - Double(st.st_mtimespec.tv_sec) < 5
    }

    private func acquireLock() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for _ in 0..<lockTries {
            if mkdir(lockURL.path, 0o700) == 0 {
                let start = Self.processStart(getpid()).map { " \($0)" } ?? ""
                try? "\(getpid())\(start)\n".write(to: lockURL.appendingPathComponent("pid"), atomically: false, encoding: .utf8)
                return
            }
            guard errno == EEXIST else { throw PlaywrightInstallFailure.other("lock") }
            if reclaimStaleLock() { continue }
            do { try await Task.sleep(nanoseconds: lockInterval) } catch { throw PlaywrightInstallFailure.cancelled }
        }
        throw PlaywrightInstallFailure.lockHeld
    }

    private func releaseLock() { try? FileManager.default.removeItem(at: lockURL) }

    // MARK: the flow

    private func runInstall(_ progress: @escaping @Sendable (PlaywrightInstallProgress) -> Void)
        async -> Result<PlaywrightInstallState, PlaywrightInstallFailure> {
        emit(.installStart(id: manifest.id))
        do {
            let s = try await doInstall(progress)
            emit(.installOK(id: manifest.id))
            return .success(s)
        } catch let f as PlaywrightInstallFailure {
            emit(.installFailed(f.errorClass))
            return .failure(f)
        } catch is CancellationError {
            emit(.installFailed("cancelled"))
            return .failure(.cancelled)
        } catch {
            emit(.installFailed("internal"))
            return .failure(.other("internal"))
        }
    }

    private func step(_ s: PlaywrightInstallStep, _ f: Double? = nil, _ progress: @Sendable (PlaywrightInstallProgress) -> Void) throws {
        if Task.isCancelled { throw PlaywrightInstallFailure.cancelled }
        emit(.step(s))
        progress(PlaywrightInstallProgress(step: s, fraction: f))
    }

    /// Runs `body` off the cooperative pool: extraction and hashing block for seconds.
    private func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(with: Result { try body() }) }
        }
    }

    private func doInstall(_ progress: @escaping @Sendable (PlaywrightInstallProgress) -> Void) async throws -> PlaywrightInstallState {
        guard manifest.validate(allowLoopbackHTTP: allowLoopbackHTTP).isEmpty,
              manifest.validateEmbeddedFiles(packageJSON: packageJSON, lockfileJSON: lockfileJSON).isEmpty else {
            throw PlaywrightInstallFailure.other("manifest_invalid")
        }
        let arch = archProvider.arch
        guard let nodeArt = manifest.nodeArtifact(arch), let crArt = manifest.chromiumArtifact(arch),
              let crExec = crArt.executable else { throw PlaywrightInstallFailure.other("manifest_invalid") }
        try step(.preflight, nil, progress)
        try await acquireLock()
        defer { releaseLock() }

        // An install.json this installer did not write (no `manifestId`, or unreadable) is the user's
        // configuration: it is never replaced, and nothing it points at is touched.
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("install.json").path),
           !recordIsOurs(readRecord()) {
            throw PlaywrightInstallFailure.other("foreign_install")
        }
        // The install.json as it was when the install began: the commit replaces exactly this, or nothing.
        let initialBytes = try? Data(contentsOf: root.appendingPathComponent("install.json"))
        let before = state()
        if case .installed(let id, _, _) = before, id == manifest.id { return before }

        // Preflight: free disk at least three times the download (or what the install may use).
        let needed = max(Int64(manifest.freeDiskFactor) * manifest.downloadBytes(arch), manifest.diskBytes(arch))
        let available = freeDisk(root)
        if available < needed { throw PlaywrightInstallFailure.notEnoughDisk(needed: needed, available: available) }

        // Staging: fresh, 0700, and checked to be a real directory of ours.
        let fm = FileManager.default
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(staging.path, 0o700) == 0 else { throw PlaywrightInstallFailure.other("staging") }
        defer { try? fm.removeItem(at: staging) }
        var st = stat()
        guard lstat(staging.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == geteuid() else {
            throw PlaywrightInstallFailure.other("staging")
        }
        let dl = staging.appendingPathComponent("dl", isDirectory: true)
        try fm.createDirectory(at: dl, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        // Download and verify, size then digest, into staging.
        let nodeFile = dl.appendingPathComponent("node.tar.gz")
        let crFile = dl.appendingPathComponent("chromium.zip")
        for (s, art, file) in [(PlaywrightInstallStep.downloadNode, nodeArt, nodeFile), (.downloadChromium, crArt, crFile)] {
            try step(s, 0, progress)
            guard let url = URL(string: art.url) else { throw PlaywrightInstallFailure.other("manifest_invalid") }
            let total = Double(art.size)
            try await downloader.download(from: url, to: file.path, expectedSize: art.size, expectedSHA256: art.sha256) { got in
                progress(PlaywrightInstallProgress(step: s, fraction: min(1, Double(got) / total)))
            }
        }

        // Package files from the embedded constants (digests were checked above).
        let pkg = staging.appendingPathComponent("pkg", isDirectory: true)
        try fm.createDirectory(at: pkg, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data(packageJSON.utf8).write(to: pkg.appendingPathComponent("package.json"))
        try Data(lockfileJSON.utf8).write(to: pkg.appendingPathComponent("package-lock.json"))

        // Validate, then extract, with the app's own extractor.
        try step(.extract, nil, progress)
        let nodeDir = staging.appendingPathComponent("node", isDirectory: true)
        let crDir = staging.appendingPathComponent("chromium", isDirectory: true)
        try await blocking {
            for (file, art, dir, format) in [(nodeFile, nodeArt, nodeDir, ArchiveFormat.tarGz), (crFile, crArt, crDir, .zip)] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let plan = try SafeArchiveExtractor.validate(file: file, format: format, limits: ArchiveLimits(art))
                try SafeArchiveExtractor.extract(plan, from: file, into: dir)
            }
        } mapError: { e in
            if let a = e as? SafeArchiveError { return a.reason == .io ? PlaywrightInstallFailure.other("extract_io") : .archiveRejected }
            return e
        }
        try? fm.removeItem(at: dl)

        // Node's signature, before it ever runs.
        try step(.signature, nil, progress)
        let nodeBin = nodeDir.appendingPathComponent("bin/node")
        guard Self.isRegularExecutable(nodeBin.path),
              verifier.verify(executable: nodeBin, teamIdentifier: manifest.node.teamIdentifier) else {
            throw PlaywrightInstallFailure.nodeSignature
        }

        // Packages.
        try step(.packages, nil, progress)
        try NpmRunner.prepare(staging: staging)
        switch await NpmRunner.run(staging: staging, timeout: npmTimeout) {
        case .ok: break
        case .offline: throw PlaywrightInstallFailure.offline
        case .integrity: throw PlaywrightInstallFailure.digestMismatch
        case .cancelled: throw PlaywrightInstallFailure.cancelled
        case .timedOut: throw PlaywrightInstallFailure.interrupted
        case .failed: throw PlaywrightInstallFailure.other("packages_failed")
        }
        let cli = pkg.appendingPathComponent("node_modules/@playwright/mcp/cli.js")
        let chromiumBin = crDir.appendingPathComponent(crExec)
        guard fm.fileExists(atPath: cli.path), Self.isRegularExecutable(chromiumBin.path) else {
            throw PlaywrightInstallFailure.healthCheckFailed
        }

        // Health check from staging, headless.
        try step(.healthCheck, nil, progress)
        try await healthCheck(staging: staging, node: nodeBin.path, cli: cli.path, chromium: chromiumBin.path)
        for n in ["hc-profile", "hc-output", "npm-cache", "home", "tmp", "user.npmrc", "global.npmrc"] {
            try? fm.removeItem(at: staging.appendingPathComponent(n))
        }

        // Commit: mark the directory as ours, rename staging to <root>/<id>, then write install.json by write then rename.
        try step(.commit, nil, progress)
        var createdDirs: [String] = []
        for d in ["profile", "output"] {
            let u = root.appendingPathComponent(d)
            if !fm.fileExists(atPath: u.path) { createdDirs.append(d) }
            try fm.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let target = root.appendingPathComponent(manifest.id, isDirectory: true)
        // Only a directory this installer marked may be replaced; anything else at that name stays.
        var tst = stat()
        if lstat(target.path, &tst) == 0 {
            guard hasOwnershipMarker(manifest.id) else { throw PlaywrightInstallFailure.other("commit_collision") }
            try? fm.removeItem(at: target)   // an invalid leftover of ours
        }
        let oldBytes = initialBytes
        guard (try? Data(contentsOf: root.appendingPathComponent("install.json"))) == initialBytes else {
            throw PlaywrightInstallFailure.other("foreign_install")
        }
        let old = readRecord()
        let hadInstall = old != nil
        do { try Data("oab-computer playwright install\n".utf8).write(to: staging.appendingPathComponent(Self.ownershipMarker)) }
        catch { throw PlaywrightInstallFailure.other("commit") }
        guard rename(staging.path, target.path) == 0 else { throw PlaywrightInstallFailure.other("commit") }
        let rec = Record(version: manifest.id, chromiumExecutable: "chromium/" + crExec, manifestId: manifest.id,
                         arch: arch.rawValue, chromiumRevision: manifest.chromium.revision,
                         chromiumReleasedAt: manifest.chromium.releasedAt,
                         installedAt: ISO8601DateFormatter().string(from: now()),
                         previous: old.map(\.version).flatMap { $0 == manifest.id ? nil : $0 },
                         digests: Digests(node: nodeArt.sha256, chromium: crArt.sha256, lockfile: manifest.mcp.lockfileSHA256))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let recData = try enc.encode(rec)

        // Switch: the old process stops first, so two children never share one profile.
        try step(.switchOver, nil, progress)
        if hadInstall { await stopManaged() }
        do { try writeAtomically(recData, to: root.appendingPathComponent("install.json"), replacing: oldBytes) }
        catch {
            try? fm.removeItem(at: target)
            if !hadInstall { for d in createdDirs { try? fm.removeItem(at: root.appendingPathComponent(d)) } }
            throw error
        }
        let serving = await verifyServing()
        guard serving else {
            // Roll back: the old install.json (or none), the old child, no new directory.
            await stopManaged()
            let ij = root.appendingPathComponent("install.json")
            if (try? Data(contentsOf: ij)) == recData {   // only our own record is rolled back
                if let oldBytes { try? writeAtomically(oldBytes, to: ij, replacing: recData) }
                else { try? fm.removeItem(at: ij) }
            }
            try? fm.removeItem(at: target)
            if hadInstall { _ = await verifyServing() }   // bring the old version's child back
            else { for d in createdDirs { try? fm.removeItem(at: root.appendingPathComponent(d)) } }
            emit(.updateRolledBack)
            throw PlaywrightInstallFailure.healthCheckFailed
        }
        // The new version served once: the previous directory can go.
        for n in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where n != manifest.id && hasOwnershipMarker(n) {
            try? fm.removeItem(at: root.appendingPathComponent(n))
        }
        if let o = old, recordIsOurs(o), o.version != manifest.id, Self.safeVersion(o.version), hasOwnershipMarker(o.version) {
            let prev = o.version
            try? fm.removeItem(at: root.appendingPathComponent(prev))
        }
        return state()
    }

    static func isRegularExecutable(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && access(path, X_OK) == 0
    }

    // MARK: health check

    private func healthCheck(staging: URL, node: String, cli: String, chromium: String) async throws {
        let spec = ManagedPlaywrightLocator.launchSpec(
            node: node, cli: cli, chromium: chromium,
            profile: staging.appendingPathComponent("hc-profile").path, output: staging.appendingPathComponent("hc-output").path,
            workingDirectory: staging.path, headless: true)
        for d in ["hc-profile", "hc-output"] {
            try FileManager.default.createDirectory(at: staging.appendingPathComponent(d), withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let child: ManagedProcess
        do {
            child = try ManagedProcess.spawn(executable: spec.executable, arguments: spec.arguments,
                                             environment: spec.environment, workingDirectory: spec.workingDirectory)
        } catch { throw PlaywrightInstallFailure.healthCheckFailed }
        let client = StdioMCPClient(channel: child)
        let timeout = healthTimeout
        var failure: PlaywrightInstallFailure?
        do {
            try await withTaskCancellationHandler {
                try await client.initialize(timeout: timeout)
                let tools = try await client.listTools(timeout: timeout)
                let names = Set(tools.compactMap { $0["name"]?.stringValue })
                guard Set(BrowserToolCatalog.allNames).isSubset(of: names) else { throw PlaywrightInstallFailure.healthCheckFailed }
                // `initialize` and `tools/list` never start Chromium. One navigation does, so a
                // browser macOS refuses to run is found here and not at the first agent call.
                let r = try await client.callTool("browser_navigate", arguments: ["url": "about:blank"], timeout: timeout)
                if r["isError"]?.boolValue == true { throw PlaywrightInstallFailure.healthCheckFailed }
                _ = try? await client.callTool("browser_close", arguments: [:], timeout: 15)
            } onCancel: { Task { await client.close() } }
        } catch let f as PlaywrightInstallFailure {
            failure = f
        } catch {
            failure = .healthCheckFailed
        }
        if failure != nil, child.stderrClass == .launchRefused { failure = .launchRefused }
        if Task.isCancelled { failure = .cancelled }
        await client.close()
        await child.terminate()
        if let failure { throw failure }
    }
}

private extension PlaywrightInstaller {
    func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T, mapError: @escaping @Sendable (Error) -> Error) async throws -> T {
        do { return try await blocking(body) } catch { throw mapError(error) }
    }
}
