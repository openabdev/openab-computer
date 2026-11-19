import Foundation
import Darwin

/// Everything needed to start the managed Playwright MCP (R7.4). There is no `--port`, `--host`
/// or `--allowed-hosts`: stdio is the transport and nothing listens.
public struct ManagedLaunchSpec: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String
}

/// Finds an installed Playwright under `root`. The install itself (download and verify) is not
/// part of this code; `install.json` is read, never written:
/// `{ "version": "<dir>", "chromiumExecutable": "<path relative to <root>/<version>>" }`.
/// Inside `<root>/<version>/`: `node/bin/node` and `pkg/node_modules/@playwright/mcp/cli.js`.
public struct ManagedPlaywrightLocator: Sendable {
    public let root: URL
    /// Checks the user's Chrome when `install.json` records that the user chose it. Never used otherwise.
    public let chrome: any InstalledChromeChecking

    public init(root: URL, chrome: any InstalledChromeChecking = InstalledChromeChecker()) {
        self.root = root; self.chrome = chrome
    }

    public static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/oab-computer/playwright", isDirectory: true)
    }

    private struct Manifest: Decodable { let version: String; let chromiumExecutable: String; let systemChrome: SystemChromeRecord? }

    /// `chrome: system` with the live bundle version when `install.json` records the user's Chrome; nil otherwise.
    /// Reads the record and the bundle's Info.plist only; the signature is checked by `locate()`.
    public func systemChromeSummary() -> BrowserEngineSummary? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("install.json")),
              let m = try? JSONDecoder().decode(Manifest.self, from: data), let choice = m.systemChrome else { return nil }
        return .systemChrome(version: chrome.displayVersion(appPath: choice.appPath))
    }

    public func locate() -> Result<ManagedLaunchSpec, PlaywrightTransportError> {
        let fm = FileManager.default
        let manifestURL = root.appendingPathComponent("install.json")
        guard fm.fileExists(atPath: manifestURL.path) else {
            return .failure(.init(errorClass: "playwright_not_installed"))
        }
        let invalid = Result<ManagedLaunchSpec, PlaywrightTransportError>.failure(.init(errorClass: "playwright_install_invalid"))
        guard let data = try? Data(contentsOf: manifestURL),
              let m = try? JSONDecoder().decode(Manifest.self, from: data),
              !m.version.isEmpty, !m.version.contains("/"), m.version != ".", m.version != ".." else { return invalid }
        let base = root.appendingPathComponent(m.version, isDirectory: true).resolvingSymlinksInPath()
        func inside(_ rel: String, executable: Bool) -> String? {
            let u = base.appendingPathComponent(rel).resolvingSymlinksInPath()
            guard u.path.hasPrefix(base.path + "/") else { return nil }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
            if executable && !fm.isExecutableFile(atPath: u.path) { return nil }
            return u.path
        }
        guard let node = inside("node/bin/node", executable: true),
              let cli = inside("pkg/node_modules/@playwright/mcp/cli.js", executable: false) else { return invalid }
        let chromium: String
        if let choice = m.systemChrome {
            // The user's own Chrome, chosen with consent. It is checked again here, on every start: a Chrome that
            // was replaced, downgraded below the floor or lost its signature stops being used until it passes.
            switch chrome.check(appPath: choice.appPath) {
            case .success(let c): chromium = c.executablePath
            case .failure(let problem): return .failure(.init(errorClass: problem.errorClass))
            }
        } else {
            guard let c = inside(m.chromiumExecutable, executable: true) else { return invalid }
            chromium = c
        }
        let profile = root.appendingPathComponent("profile").path
        let output = root.appendingPathComponent("output").path
        for d in [profile, output] {
            do { try fm.createDirectory(atPath: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { return .failure(.init(errorClass: "playwright_install_invalid")) }
        }
        return .success(Self.launchSpec(node: node, cli: cli, chromium: chromium, profile: profile, output: output,
                                        workingDirectory: root.path))
    }

    /// The one place the launch vector is built (R7.4): no `--port`, `--host` or `--allowed-hosts`,
    /// an allow-list environment, stdio only. The installer's health check uses it too, with
    /// `headless` so no window opens.
    public static func launchSpec(node: String, cli: String, chromium: String, profile: String, output: String,
                                  workingDirectory: String, headless: Bool = false) -> ManagedLaunchSpec {
        let nodeDir = (node as NSString).deletingLastPathComponent
        let env: [String: String] = [
            "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(),
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
            "PATH": "\(nodeDir):/usr/bin:/bin",
        ]
        var args = [cli, "--user-data-dir", profile, "--output-dir", output, "--idle-timeout", "1800000",
                    "--browser", "chromium", "--executable-path", chromium, "--shared-browser-context",
                    "--caps", "vision,pdf"]
        if headless { args.append("--headless") }
        return ManagedLaunchSpec(executable: node, arguments: args, environment: env, workingDirectory: workingDirectory)
    }
}

/// A running child, as the transport sees it.
public protocol ManagedChild: AnyObject, Sendable {
    var channel: any StdioChannel { get }
    var hasExited: Bool { get }
    var exitInfo: ExitInfo? { get }
    var stderrClass: StderrClass? { get }
    func terminate() async
}

extension ManagedProcess: ManagedChild {
    public var channel: any StdioChannel { self }
    public var stderrClass: StderrClass? { stderrRing.classify() }
}

public protocol ChildLauncher: Sendable {
    func launch(_ spec: ManagedLaunchSpec) throws -> any ManagedChild
}

public struct ProcessChildLauncher: ChildLauncher {
    public init() {}
    public func launch(_ spec: ManagedLaunchSpec) throws -> any ManagedChild {
        try ManagedProcess.spawn(executable: spec.executable, arguments: spec.arguments,
                                 environment: spec.environment, workingDirectory: spec.workingDirectory)
    }
}

/// The managed Playwright transport: starts the child on demand, speaks stdio MCP to it and
/// restarts it lazily, with backoff, after an unexpected exit. There is no timer: a child that
/// died is started again by the next call, never by itself.
public actor ManagedPlaywrightTransport: PlaywrightTransport {
    public static let backoff: [TimeInterval] = [1, 2, 4, 8, 16, 30]
    public static let failureWindow: TimeInterval = 120
    public static let failureLimit = 5

    private let spec: ManagedLaunchSpec
    private let launcher: any ChildLauncher
    private let clock: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private let initTimeout: TimeInterval
    private let healthTimeout: TimeInterval
    private let callTimeout: TimeInterval

    private var child: (any ManagedChild)?
    private var client: StdioMCPClient?
    private var starting: Task<Void, Error>?
    private var failures: [Date] = []
    private var step = 0
    private var notBefore: Date?
    public private(set) var latched = false

    public init(spec: ManagedLaunchSpec, launcher: any ChildLauncher = ProcessChildLauncher(),
                initializeTimeout: TimeInterval = StdioMCPClient.initializeTimeout,
                healthTimeout: TimeInterval = StdioMCPClient.healthTimeout,
                callTimeout: TimeInterval = StdioMCPClient.callTimeout,
                clock: @escaping @Sendable () -> Date = { Date() }, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.spec = spec; self.launcher = launcher; self.clock = clock; self.log = log
        self.initTimeout = initializeTimeout; self.healthTimeout = healthTimeout; self.callTimeout = callTimeout
    }

    /// The delay the next failure would impose; for tests.
    var nextBackoff: TimeInterval { Self.backoff[min(step, Self.backoff.count - 1)] }

    public var isLatched: Bool { latched }

    public func retry() {
        latched = false; failures = []; step = 0; notBefore = nil
    }

    public func shutdown() async {
        let c = child
        child = nil; client = nil
        await c?.terminate()
    }

    // MARK: PlaywrightTransport

    public func healthCheck() async throws {
        let fresh = child == nil
        try await ensureRunning()
        if fresh { resetBackoff(); return }
        do { try await client!.ping(timeout: healthTimeout); resetBackoff() }
        catch { await noteFailure(error); throw error }
    }

    public func listTools() async throws -> [JSONValue] {
        try await ensureRunning()
        do { return try await client!.listTools(timeout: callTimeout) }
        catch {
            // A cap, cycle or bad cursor is the server's answer on a live channel, not a crash or a hang.
            // Whether the child died while answering is still checked, and still counts.
            if Self.isServerProtocolError(error) { await noteFailureIfDead() } else { await noteFailure(error) }
            throw error
        }
    }

    private static func isServerProtocolError(_ error: Error) -> Bool {
        guard let e = error as? PlaywrightTransportError else { return false }
        return ["tools_list_too_many_tools", "tools_list_too_many_pages", "tools_list_cursor_cycle",
                "tools_list_bad_cursor"].contains(e.errorClass)
    }

    public func callTool(_ name: String, arguments: JSONValue) async throws -> JSONValue {
        try await ensureRunning()
        do { let r = try await client!.callTool(name, arguments: arguments, timeout: callTimeout); resetBackoff(); return r }
        catch { await noteFailure(error); throw error }
    }

    // MARK: supervision

    private func resetBackoff() { step = 0 }

    private func recordFailure() {
        let now = clock()
        failures = failures.filter { now.timeIntervalSince($0) < Self.failureWindow } + [now]
        notBefore = now.addingTimeInterval(Self.backoff[min(step, Self.backoff.count - 1)])
        step += 1
        if failures.count >= Self.failureLimit { latched = true; log("browser: playwright_unavailable failures=\(failures.count)") }
    }

    /// If the child is gone (or its channel closed), log one classified line, record the failure
    /// and drop it. A live child that timed out is handled by `noteFailure`.
    private func noteFailureIfDead() async {
        guard let c = child else { return }
        let closed = await client?.isClosed ?? true
        guard c.hasExited || closed else { return }
        let cls = c.stderrClass?.rawValue ?? "none"
        log("browser: playwright_exit class=\(cls) \(c.exitInfo?.summary ?? "status=unknown")")
        child = nil; client = nil
        recordFailure()
        await c.terminate()
    }

    /// After a failed request: a dead child is recorded as before. A live child that timed out is
    /// asked once more for a ping; if that times out too it is hung, so it is terminated and
    /// recorded as a failure, which puts it under the same backoff and latch as a crash.
    private func noteFailure(_ error: Error) async {
        await noteFailureIfDead()
        guard let c = child, let cl = client,
              (error as? PlaywrightTransportError)?.errorClass == "playwright_timeout" else { return }
        do { try await cl.ping(timeout: healthTimeout); return } catch {}
        guard child === c else { return }   // replaced while the confirming ping ran
        log("browser: playwright_hung \(c.exitInfo?.summary ?? "status=running")")
        child = nil; client = nil
        recordFailure()
        await cl.close()
        await c.terminate()
    }

    private func ensureRunning() async throws {
        if latched { throw PlaywrightTransportError(errorClass: "playwright_unavailable") }
        if let t = starting { try await t.value; return }
        await noteFailureIfDead()
        if latched { throw PlaywrightTransportError(errorClass: "playwright_unavailable") }
        if child != nil { return }
        if let nb = notBefore, clock() < nb { throw PlaywrightTransportError(errorClass: "playwright_restarting") }
        let t = Task { try await self.start() }
        starting = t
        defer { starting = nil }
        try await t.value
    }

    private func start() async throws {
        let c: any ManagedChild
        do { c = try launcher.launch(spec) }
        catch { recordFailure(); throw PlaywrightTransportError(errorClass: "playwright_spawn_failed") }
        let cl = StdioMCPClient(channel: c.channel)
        do {
            try await cl.initialize(timeout: initTimeout)
        } catch {
            let cls = c.stderrClass
            log("browser: playwright_start_failed class=\(cls?.rawValue ?? "none") \(c.exitInfo?.summary ?? "status=running")")
            await cl.close()
            await c.terminate()
            recordFailure()
            if let cls { throw PlaywrightTransportError(errorClass: cls.rawValue) }
            throw (error as? PlaywrightTransportError) ?? PlaywrightTransportError(errorClass: "playwright_exited")
        }
        child = c; client = cl
    }
}
