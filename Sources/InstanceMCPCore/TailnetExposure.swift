import Foundation

/// The opt-in "allow other devices on my tailnet" step. It maps `https://<tailnet name>:8444` to the loopback
/// backend with `tailscale serve`, the way the installer does, but only after the user asks for it.
///
/// Rules, each enforced here and covered by tests with an injected runner (no test starts a real CLI):
///  - Off by default. Nothing in this type runs unless `enable()` or `reapplyAtLaunch()` is called, and
///    `reapplyAtLaunch()` does nothing without a stored opt-in.
///  - Refused when no Tailscale login was detected at launch: a tailnet mapping with the bearer token alone is
///    weaker than the login allow list plus the token, so it is never offered.
///  - Only port 8444 is ever touched. A mapping on 8444 that is not this app's own backend is never overwritten
///    (and never removed). Every other serve mapping stays as it is.
///  - The mapping is verified with `tailscale serve status` after each change.
///
/// The methods block while the CLI runs (seconds); call them off the main thread.
public final class TailnetExposure: @unchecked Sendable {
    public static let httpsPort = 8444
    public static let optInKey = "tailnetExposure.optIn.v1"

    public enum Outcome: Equatable, Sendable {
        /// The 8444 mapping exists, verified, and this is its URL.
        case on(url: String)
        /// The 8444 mapping is gone (or was not there), verified.
        case off
        /// No Tailscale login was detected at launch; nothing was run.
        case refusedNoLogin
        /// Port 8444 maps to something else. Nothing was changed. `existing` names the target.
        case conflict(existing: String)
        /// A step failed; `message` says which. The choice stays off (or, for a failed turn-off, unchanged).
        case failed(String)

        /// What the wizard row and the menu show.
        public var message: String {
            switch self {
            case .on(let url): return "On. Reachable at \(url)"
            case .off: return "Off"
            case .refusedNoLogin:
                return "Not available: no Tailscale login was detected, and tailnet access needs the login as well as the token."
            case .conflict(let existing):
                return "Port \(TailnetExposure.httpsPort) is already used by Tailscale Serve for \(existing). OpenAB Computer did not change it."
            case .failed(let why): return why
            }
        }
    }

    /// What `tailscale serve status` says about port 8444.
    public enum ServeMapping: Equatable, Sendable {
        case absent
        /// Exactly one handler, `/`, proxying to the backend, and no Funnel.
        case ours
        /// Anything else. `description` is safe to show: targets only.
        case foreign(description: String)
    }

    private let defaults: UserDefaults
    public let loginDetected: Bool
    private let backend: String
    private let runner: FirstRunSetup.TailscaleCommandRunner
    private let candidates: () -> [String]
    private let sleep: (TimeInterval) -> Void
    private let log: (String) -> Void
    private let lock = NSLock()
    /// One operation at a time (wizard, menu and launch share the instance). Recursive: the launch re-apply calls `enable()`.
    private let operation = NSRecursiveLock()
    private var url: String?
    /// True while the launch re-apply runs `enable()`: a failed attempt then keeps the stored opt-in, so one bad
    /// launch (tailscaled still starting) does not silently drop the user's choice.
    private var preserveChoiceOnFailure = false

    /// - runner: required, so no caller can start a real CLI by omission. Production passes
    ///   `FirstRunSetup.systemTailscaleCommandRunner`.
    public init(defaults: UserDefaults, loginDetected: Bool, backendPort: UInt16,
                runner: @escaping FirstRunSetup.TailscaleCommandRunner,
                candidates: @escaping () -> [String] = { FirstRunSetup.tailscaleCandidates() },
                sleep: @escaping (TimeInterval) -> Void = { usleep(UInt32($0 * 1_000_000)) },
                log: @escaping (String) -> Void = { _ in }) {
        self.defaults = defaults
        self.loginDetected = loginDetected
        self.backend = "http://127.0.0.1:\(backendPort)"
        self.runner = runner
        self.candidates = candidates
        self.sleep = sleep
        self.log = log
    }

    /// The user chose "on" and it has not been turned off since.
    public var optedIn: Bool { defaults.bool(forKey: Self.optInKey) }

    /// The verified tailnet URL while exposure is on; nil otherwise. This is what the menu shows and copies.
    public var publicURL: String? {
        lock.lock(); defer { lock.unlock() }
        return url
    }

    /// Whether the wizard offers the page at all.
    public var offersExposure: Bool { loginDetected }

    // MARK: arguments

    public var serveOnArguments: [String] { ["serve", "--bg", "--https=\(Self.httpsPort)", backend] }
    public var serveOffArguments: [String] { ["serve", "--https=\(Self.httpsPort)", "off"] }
    static let serveStatusArguments = ["serve", "status", "--json"]

    // MARK: actions

    /// Turn exposure on. Order: refuse without a login, read the tailnet name, read the serve status, map only
    /// when 8444 is free, verify, then record the choice. On any failure the choice stays off.
    public func enable() -> Outcome {
        operation.lock(); defer { operation.unlock() }
        guard loginDetected else {
            log("tailnet access: refused, no Tailscale login was detected at launch")
            return .refusedNoLogin
        }
        let dns: String
        switch selfDNSName() {
        case .success(let name): dns = name
        case .failure(let why):
            log("tailnet access: not turned on, could not read the tailnet name (\(why))")
            return fail("Could not read this Mac's tailnet name from Tailscale. Nothing was changed.")
        }
        let before: ServeMapping
        switch readMapping() {
        case .success(let m): before = m
        case .failure(let why):
            log("tailnet access: not turned on, could not read serve status (\(why))")
            return fail("Could not read Tailscale Serve status. Nothing was changed.")
        }
        if case .foreign(let existing) = before {
            log("tailnet access: not turned on, port \(Self.httpsPort) is already mapped to \(existing); left untouched")
            setChoice(false)
            return .conflict(existing: existing)
        }
        if before == .absent {
            if case .failure(let why) = tailscale(serveOnArguments, timeout: 10, attempts: 2, allowEmpty: true) {
                log("tailnet access: tailscale serve failed (\(why))")
                // A timed-out serve may still have applied; undo it so "off" means off.
                if case .success(.ours) = readMapping() { rollback() }
                return fail("Tailscale could not map port \(Self.httpsPort). If this is the first use of Tailscale Serve, enable HTTPS for your tailnet in the Tailscale admin console. The choice stays off.")
            }
        }
        switch readMapping() {
        case .success(.ours):
            let result = "https://\(dns):\(Self.httpsPort)/mcp"
            setChoice(true, url: result)
            log("tailnet access: on, mapping on port \(Self.httpsPort) verified")
            return .on(url: result)
        case .success(.foreign(let existing)):
            log("tailnet access: after serve, port \(Self.httpsPort) maps to \(existing); not recorded as on")
            setChoice(false)
            return .conflict(existing: existing)
        case .success(.absent):
            log("tailnet access: serve reported success but port \(Self.httpsPort) is not mapped")
            return fail("Tailscale did not report the mapping on port \(Self.httpsPort) after setting it. The choice stays off.")
        case .failure(let why):
            log("tailnet access: could not verify the mapping (\(why))")
            if before == .absent { rollback() }
            return fail("Could not verify the mapping with Tailscale Serve status, so it was undone. The choice stays off.")
        }
    }

    /// Turn exposure off. Removes only a mapping on 8444 that is this app's own; a foreign one is left alone.
    public func disable() -> Outcome {
        operation.lock(); defer { operation.unlock() }
        let before: ServeMapping
        switch readMapping() {
        case .success(let m): before = m
        case .failure(let why):
            log("tailnet access: could not read serve status before turning off (\(why))")
            return .failed("Could not read Tailscale Serve status, so access was not turned off. Try again, or run: tailscale serve --https=\(Self.httpsPort) off")
        }
        switch before {
        case .absent:
            setChoice(false)
            log("tailnet access: off, no mapping on port \(Self.httpsPort)")
            return .off
        case .foreign(let existing):
            setChoice(false)
            log("tailnet access: turned off in the app; port \(Self.httpsPort) maps to \(existing), left untouched")
            return .conflict(existing: existing)
        case .ours:
            break
        }
        if case .failure(let why) = tailscale(serveOffArguments, timeout: 10, attempts: 2, allowEmpty: true) {
            log("tailnet access: tailscale serve off failed (\(why))")
            return .failed("Tailscale could not remove the mapping on port \(Self.httpsPort). Access is still on.")
        }
        switch readMapping() {
        case .success(.absent):
            setChoice(false)
            log("tailnet access: off, mapping on port \(Self.httpsPort) removed and verified")
            return .off
        case .success:
            log("tailnet access: serve off ran but port \(Self.httpsPort) is still mapped")
            return .failed("The mapping on port \(Self.httpsPort) is still there after turning it off. Access is still on.")
        case .failure(let why):
            log("tailnet access: could not verify removal (\(why))")
            return .failed("Could not verify that the mapping was removed. Access may still be on.")
        }
    }

    /// At launch: with a stored opt-in and a detected login, make sure the mapping exists. Maps once when it is
    /// missing, does nothing when it is already ours, never overwrites a foreign mapping. Returns nil without an
    /// opt-in (nothing at all is run in that case).
    public func reapplyAtLaunch() -> Outcome? {
        operation.lock(); defer { operation.unlock() }
        guard optedIn else { return nil }
        guard loginDetected else {
            log("tailnet access: opted in, but no Tailscale login was detected at launch; not re-applying")
            return .refusedNoLogin
        }
        let dns: String
        switch selfDNSName() {
        case .success(let name): dns = name
        case .failure(let why):
            log("tailnet access: opted in, could not read the tailnet name at launch (\(why)); not re-applying")
            return .failed("Could not read this Mac's tailnet name from Tailscale.")
        }
        switch readMapping() {
        case .success(.ours):
            let result = "https://\(dns):\(Self.httpsPort)/mcp"
            setURL(result)
            log("tailnet access: opted in, mapping on port \(Self.httpsPort) already present")
            return .on(url: result)
        case .success(.absent):
            log("tailnet access: opted in and the mapping on port \(Self.httpsPort) is missing; re-applying once")
            preserveChoiceOnFailure = true
            defer { preserveChoiceOnFailure = false }
            return enable()
        case .success(.foreign(let existing)):
            log("tailnet access: opted in, but port \(Self.httpsPort) maps to \(existing); not re-applying")
            return .conflict(existing: existing)
        case .failure(let why):
            log("tailnet access: opted in, could not read serve status at launch (\(why)); not re-applying")
            return .failed("Could not read Tailscale Serve status.")
        }
    }

    /// At launch without a detected login: a mapping this app created earlier (or the installer's, same target) is
    /// still live in tailscaled, and this process would accept the bearer token alone through it. Remove it, but only
    /// when it is exactly our own backend on 8444; a foreign mapping and every other port stay untouched. The stored
    /// opt-in is kept, so a later launch that detects the login re-applies it. Call it before the server listens.
    /// Needs no opt-in; with a detected login it does nothing and runs nothing.
    @discardableResult
    public func withdrawWithoutLogin() -> Outcome? {
        operation.lock(); defer { operation.unlock() }
        guard !loginDetected else { return nil }
        switch readMapping() {
        case .failure(let why):
            log("tailnet access: no login detected and serve status could not be read (\(why)); cannot check for a leftover mapping")
            return nil
        case .success(.absent), .success(.foreign):
            return nil
        case .success(.ours):
            break
        }
        log("tailnet access: no Tailscale login was detected, so the leftover mapping on port \(Self.httpsPort) would accept the token alone; removing it")
        if case .failure(let why) = tailscale(serveOffArguments, timeout: 10, attempts: 2, allowEmpty: true) {
            log("tailnet access: could not remove the leftover mapping (\(why)); remove it with: tailscale serve --https=\(Self.httpsPort) off")
            return .failed("Could not remove the tailnet mapping on port \(Self.httpsPort).")
        }
        if case .success(.absent) = readMapping() {
            log("tailnet access: leftover mapping on port \(Self.httpsPort) removed; the opt-in is kept for a launch with a login")
            return .off
        }
        log("tailnet access: the leftover mapping on port \(Self.httpsPort) is still there after serve off")
        return .failed("The tailnet mapping on port \(Self.httpsPort) is still there.")
    }

    /// At launch with a login but no stored opt-in: if 8444 already maps to this app's backend (set by hand or by an
    /// older install), show it as on instead of "Off". Read-only: runs only `serve status` and the name lookup.
    @discardableResult
    public func adoptExistingMapping() -> Outcome? {
        operation.lock(); defer { operation.unlock() }
        guard loginDetected, !optedIn else { return nil }
        guard case .success(.ours) = readMapping(), case .success(let dns) = selfDNSName() else { return nil }
        let result = "https://\(dns):\(Self.httpsPort)/mcp"
        setChoice(true, url: result)
        log("tailnet access: port \(Self.httpsPort) already maps to this app; shown as on")
        return .on(url: result)
    }

    // MARK: state

    private func fail(_ message: String) -> Outcome {
        if !preserveChoiceOnFailure { setChoice(false) }
        return .failed(message)
    }

    private func setChoice(_ on: Bool, url newURL: String? = nil) {
        defaults.set(on, forKey: Self.optInKey)
        setURL(on ? newURL : nil)
    }

    private func setURL(_ value: String?) {
        lock.lock(); url = value; lock.unlock()
    }

    private func rollback() {
        let result = tailscale(serveOffArguments, timeout: 10, attempts: 1, allowEmpty: true)
        log("tailnet access: rolled back the mapping on port \(Self.httpsPort) (\(result.isOK ? "ok" : "failed"))")
    }

    // MARK: reads

    private func selfDNSName() -> Result<String, CLIFailure> {
        tailscale(FirstRunSetup.tailscaleStatusArguments, timeout: 3, attempts: 3, allowEmpty: false).flatMap { data in
            FirstRunSetup.tailscaleSelfDNSName(statusJSON: data).map { .success($0) } ?? .failure(.unparsable)
        }
    }

    private func readMapping() -> Result<ServeMapping, CLIFailure> {
        tailscale(Self.serveStatusArguments, timeout: 3, attempts: 3, allowEmpty: true).flatMap { data in
            Self.mapping(serveStatusJSON: data, httpsPort: Self.httpsPort, backend: backend)
                .map { .success($0) } ?? .failure(.unparsable)
        }
    }

    /// Reads port `httpsPort` out of `tailscale serve status --json`. Nil when the output is not a status object.
    /// An empty output or `{}` means nothing is served.
    public static func mapping(serveStatusJSON data: Data, httpsPort: Int, backend: String) -> ServeMapping? {
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .absent }
        guard let root = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] else { return nil }
        func normalized(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespaces)
            while t.hasSuffix("/") { t.removeLast() }
            return t
        }
        let suffix = ":\(httpsPort)"
        var found: [String] = []
        var funnel = false
        if let web = root["Web"] as? [String: Any] {
            for (hostPort, value) in web where hostPort.hasSuffix(suffix) {
                let handlers = ((value as? [String: Any])?["Handlers"] as? [String: Any]) ?? [:]
                if handlers.isEmpty { found.append("an empty web entry") }
                for (path, handler) in handlers {
                    let h = handler as? [String: Any] ?? [:]
                    if let proxy = h["Proxy"] as? String {
                        found.append(path == "/" ? normalized(proxy) : "\(normalized(proxy)) at \(path)")
                    } else if let p = h["Path"] as? String {
                        found.append("files at \(p)")
                    } else if h["Text"] != nil {
                        found.append("a text response")
                    } else {
                        found.append("another handler")
                    }
                }
            }
        }
        if let tcp = root["TCP"] as? [String: Any], let entry = tcp[String(httpsPort)] as? [String: Any] {
            if let forward = entry["TCPForward"] as? String {
                found.append("TCP forward to \(forward)")
            } else if found.isEmpty {
                found.append("another Serve entry")
            }
        }
        if let allow = root["AllowFunnel"] as? [String: Any] {
            for (hostPort, on) in allow where hostPort.hasSuffix(suffix) && (on as? Bool) == true { funnel = true }
        }
        if found.isEmpty { return funnel ? .foreign(description: "a public Funnel entry") : .absent }
        if found.count == 1, normalized(found[0]) == normalized(backend), !funnel { return .ours }
        let names = found.sorted().joined(separator: ", ")
        return .foreign(description: funnel ? names + " (public via Funnel)" : names)
    }

    // MARK: running the CLI

    enum CLIFailure: Error, Equatable, CustomStringConvertible {
        case noCLI, failed(String), unparsable
        var description: String {
            switch self {
            case .noCLI: return "no tailscale CLI found"
            case .failed(let why): return why
            case .unparsable: return "unexpected output"
            }
        }
    }

    /// Runs the CLI with up to `attempts` tries over every candidate, waiting 0.5 s then 1 s between tries. The
    /// reason is logged by name only; output is never logged. Exit 0 with the app binary's GUI message is a failure,
    /// like the login detection treats it.
    private func tailscale(_ arguments: [String], timeout: TimeInterval, attempts: Int,
                           allowEmpty: Bool) -> Result<Data, CLIFailure> {
        let clis = candidates()
        guard !clis.isEmpty else { return .failure(.noCLI) }
        var last: CLIFailure = .failed("no attempt")
        let backoff: [TimeInterval] = [0.5, 1.0]
        for attempt in 1...max(1, attempts) {
            for cli in clis {
                switch runner(cli, arguments, timeout) {
                case .launchFailed: last = .failed("could not start")
                case .timeout: last = .failed("timeout")
                case let .finished(output, status):
                    if status != 0 {
                        last = .failed("exit status \(status)")
                    } else if String(decoding: output, as: UTF8.self).contains("GUI failed to start") {
                        last = .failed("the Tailscale app binary did not act as a CLI")
                    } else if output.isEmpty && !allowEmpty {
                        last = .failed("empty output")
                    } else {
                        return .success(output)
                    }
                }
            }
            if attempt < attempts { sleep(backoff[min(attempt - 1, backoff.count - 1)]) }
        }
        return .failure(last)
    }
}

private extension Result {
    var isOK: Bool { if case .success = self { return true } else { return false } }
}
