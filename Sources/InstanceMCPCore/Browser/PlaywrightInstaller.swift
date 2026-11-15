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
        let task = Task { await self.runInstall(progress) }
        stateLock.withLock { current = task }
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
        if lockIsLive() { return .failure(.lockHeld) }
        await stopManaged()
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        for n in names where Self.isOurs(n) {
            do { try fm.removeItem(at: root.appendingPathComponent(n)) }
            catch { emit(.installFailed("remove_failed")); return .failure(.other("remove_failed")) }
        }
        // Only an empty directory is removed: anything the installer did not create stays.
        rmdir(root.path)
        onRemoved()
        emit(.removed)
        return .success(())
    }

    /// At launch: removes staging directories and orphaned version directories left by a crash,
    /// and a stale lock. Does nothing while another install holds the lock.
    public func sweepStaging() {
        if lockIsLive() { return }
        let fm = FileManager.default
        _ = reclaimStaleLock()
        let keep = readRecord()?.version
        var n = 0
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let isStaging = name.hasPrefix(".staging-")
            let isOrphan = name.hasPrefix("mcp") && PlaywrightManifest.isSafeID(name) && name != keep
            if isStaging || isOrphan, (try? fm.removeItem(at: root.appendingPathComponent(name))) != nil { n += 1 }
        }
        if n > 0 { emit(.swept(n)) }
    }

    // MARK: names

    static func safeVersion(_ v: String) -> Bool {
        !v.isEmpty && !v.contains("/") && v != "." && v != ".." && !v.hasPrefix(".")
    }

    /// Entries the installer creates; `remove` deletes only these.
    static func isOurs(_ name: String) -> Bool {
        if ["install.json", "profile", "output", ".install.lock"].contains(name) { return true }
        if name.hasPrefix(".staging-") || name.hasPrefix("install.json.tmp-") { return true }
        return name.hasPrefix("mcp") && PlaywrightManifest.isSafeID(name)
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

    func readRecord() -> Record? {
        guard let d = try? Data(contentsOf: root.appendingPathComponent("install.json")) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: d)
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
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
        guard ok, rename(tmp.path, url.path) == 0 else { unlink(tmp.path); throw PlaywrightInstallFailure.other("write_install_json") }
    }

    // MARK: lock

    private var lockURL: URL { root.appendingPathComponent(".install.lock", isDirectory: true) }

    private func lockOwner() -> pid_t? {
        guard let s = try? String(contentsOf: lockURL.appendingPathComponent("pid"), encoding: .utf8),
              let p = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return p
    }

    private func pidAlive(_ p: pid_t) -> Bool { kill(p, 0) == 0 || errno == EPERM }

    /// A lock whose recorded process is gone is reclaimed; one with no pid file yet is given a few
    /// seconds, because its owner may be between `mkdir` and the pid write.
    private func reclaimStaleLock() -> Bool {
        var st = stat()
        guard lstat(lockURL.path, &st) == 0 else { return false }
        if let p = lockOwner() {
            guard !pidAlive(p) else { return false }
        } else if Date().timeIntervalSince1970 - Double(st.st_mtimespec.tv_sec) < 5 {
            return false
        }
        return (try? FileManager.default.removeItem(at: lockURL)) != nil
    }

    private func lockIsLive() -> Bool {
        var st = stat()
        guard lstat(lockURL.path, &st) == 0 else { return false }
        if let p = lockOwner() { return pidAlive(p) }
        return Date().timeIntervalSince1970 - Double(st.st_mtimespec.tv_sec) < 5
    }

    private func acquireLock() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for _ in 0..<lockTries {
            if mkdir(lockURL.path, 0o700) == 0 {
                try? "\(getpid())\n".write(to: lockURL.appendingPathComponent("pid"), atomically: false, encoding: .utf8)
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

        // Commit: rename staging to <root>/<id>, then write install.json by write then rename.
        try step(.commit, nil, progress)
        for d in ["profile", "output"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let target = root.appendingPathComponent(manifest.id, isDirectory: true)
        if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }   // an invalid leftover
        let oldBytes = try? Data(contentsOf: root.appendingPathComponent("install.json"))
        let old = readRecord()
        let hadInstall = old != nil
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
        do { try writeAtomically(recData, to: root.appendingPathComponent("install.json")) }
        catch { try? fm.removeItem(at: target); throw error }
        let serving = await verifyServing()
        guard serving else {
            // Roll back: the old install.json (or none), the old child, no new directory.
            await stopManaged()
            if let oldBytes { try? writeAtomically(oldBytes, to: root.appendingPathComponent("install.json")) }
            else { try? fm.removeItem(at: root.appendingPathComponent("install.json")) }
            try? fm.removeItem(at: target)
            emit(.updateRolledBack)
            throw PlaywrightInstallFailure.healthCheckFailed
        }
        // The new version served once: the previous directory can go.
        for n in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where n != manifest.id && n.hasPrefix("mcp") && PlaywrightManifest.isSafeID(n) {
            try? fm.removeItem(at: root.appendingPathComponent(n))
        }
        // A previous install this app did not write (no `manifestId`: a hand-made `install.json`) is
        // replaced as the selected version but its directory is left where it is.
        if let o = old, o.manifestId != nil, o.version != manifest.id, Self.safeVersion(o.version) {
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
