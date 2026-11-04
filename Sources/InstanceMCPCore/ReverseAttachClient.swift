import Foundation

/// The Mac's half of reverse attach: dial an `openab-pty` runtime's
/// `GET /tools/attach/{session}`, then act as the MCP **server** on that socket
/// with a per-grant tool profile. Contract: openab-pty `CLIENT-CONTRACT.md` §9.2.
///
/// The runtime is the MCP client here — it sends `initialize` first, then relays
/// the CLI's `tools/list` / `tools/call` with its own integer ids. We answer each
/// frame with the same id: one frame in, one frame out, no server-initiated
/// messages.
///
/// Liveness: the runtime pings every 20 s and drops a Mac that stays silent for
/// more than three intervals. `URLSessionWebSocketTask` only answers a ping while
/// a `receive()` is outstanding, so a `receive()` is **always** outstanding: each
/// frame is answered in its own task, replies go out through one writer task, and
/// a slow tool call no longer silences the socket. Calls also run concurrently
/// (the runtime allows many in flight). When a socket ends, for any reason, the
/// calls it still has running are cancelled, and `exec` kills its process group.
/// As a second safeguard we send our own ping every `keepaliveInterval` while
/// attached; any inbound frame counts as alive on the runtime side.
///
/// Retry ownership is ours (the pod cannot reach us). Close codes decide:
///
/// | code | meaning (§9.2) | we |
/// |---|---|---|
/// | 4001 | grant TTL elapsed | stop |
/// | 4002 | replaced by a newer attach | stop |
/// | 4004 | session ended | stop |
/// | 4006 | runtime replaced | redial with backoff while the grant is valid |
/// | 4010 | grant revoked | stop |
/// | 4011 | liveness: we were silent past the runtime's ping budget | redial with backoff while the grant is valid |
/// | 1000 / error | dropped | redial with backoff while the grant is valid |
///
/// A connection that stayed up for `stableAfter` resets the backoff, so a drop
/// after a long attach redials in about a second.
///
/// A `401` on the handshake means the verifier is gone (expired, revoked, or the
/// pod was replaced): stop and report it, there is nothing to wait for.
///
/// The same client also dials an openab-sb switchboard's `GET /vm/attach`
/// (`Kind.switchboard`, openab-sb `docs/SOUTHBOUND-CONTRACT.md`). The socket
/// carries the same plain MCP; only the URL, the lifetime and the close codes
/// differ:
///
/// | code | meaning (southbound §5) | we |
/// |---|---|---|
/// | 4002 | replaced by another daemon with the same secret | stop |
/// | 4003 | the operator revoked or rotated the secret | stop |
/// | 4005 / 1001 / 1000 / error | handshake failed, restart, drop | redial with backoff |
/// | `401`/`403` on upgrade | wrong secret | retry at most every 5 minutes |
///
/// A switchboard secret is long-lived, so there is no deadline; the secret file
/// is re-read on every dial so a rotated secret heals at the next retry.
public actor ReverseAttachClient {
    public enum Kind: Equatable, Sendable {
        /// openab-pty `GET /tools/attach/{session}`, CLIENT-CONTRACT §9.2.
        case openabPty
        /// openab-sb `GET /vm/attach`, SOUTHBOUND-CONTRACT.
        case switchboard
    }

    public enum Terminal: Equatable, Sendable {
        case grantExpired            // 4001
        case replaced                // 4002
        case sessionEnded            // 4004
        case revoked                 // 4010
        case secretRevoked           // 4003 from a switchboard
        case handshakeRejected(Int)  // HTTP status on upgrade, typically 401
        case cancelled
        case deadline                // our own grant deadline passed while redialling
    }

    public enum State: Equatable, Sendable {
        case idle
        case dialing
        case attached
        case waitingToRedial(seconds: Double)
        case ended(Terminal)
    }

    public struct Config: Sendable {
        /// `ws://` or `wss://` base of the runtime, e.g. `ws://100.111.174.31:8090`.
        public var runtime: URL
        public var session: String
        public var secret: String
        public var profile: ToolProfile
        /// When the grant we hold expires, as we understand it. Redialling stops here.
        public var deadline: Date
        public var initialBackoff: TimeInterval = 1
        public var maxBackoff: TimeInterval = 30
        public var kind: Kind = .openabPty
        /// When set, the secret is re-read from here on every dial (falling back
        /// to `secret` if the file cannot be read).
        public var secretFile: URL? = nil
        /// How long to wait after a credential refusal before trying again.
        public var credentialRetry: TimeInterval = 300
        /// A connection that stayed up this long resets the backoff.
        public var stableAfter: TimeInterval = 60
        /// How often we ping the peer while attached, below the runtime's 20 s
        /// ping interval. 0 turns our own pings off (tests).
        public var keepaliveInterval: TimeInterval = 15

        public init(runtime: URL, session: String, secret: String, profile: ToolProfile, deadline: Date) {
            self.runtime = runtime; self.session = session; self.secret = secret
            self.profile = profile; self.deadline = deadline
        }

        /// A switchboard dial: `url` is the full `…/vm/attach` URL, used as-is.
        public static func switchboard(url: URL, secret: String, secretFile: URL? = nil,
                                       profile: ToolProfile) -> Config {
            var c = Config(runtime: url, session: "switchboard", secret: secret, profile: profile,
                           deadline: .distantFuture)
            c.kind = .switchboard
            c.secretFile = secretFile
            c.maxBackoff = 60
            return c
        }

        public var attachURL: URL {
            if kind == .switchboard { return runtime }
            var c = URLComponents(url: runtime, resolvingAgainstBaseURL: false)!
            let base = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
            c.path = base + "/tools/attach/" + session
            return c.url!
        }
    }

    /// Pure function of a close code / handshake outcome → what to do. Kept
    /// separate from the socket so the policy in §9.2 is unit-testable.
    public enum Disposition: Equatable, Sendable {
        case stop(Terminal)
        case redial
        /// The credential was refused; only an operator can fix it. Retry slowly.
        case waitForCredentials
    }

    public static func disposition(closeCode: Int, kind: Kind = .openabPty) -> Disposition {
        if kind == .switchboard {
            switch closeCode {
            case 4002: return .stop(.replaced)
            case 4003: return .stop(.secretRevoked)
            default:   return .redial            // 4005, 1001, 1000, 1006, anything else
            }
        }
        switch closeCode {
        case 4001: return .stop(.grantExpired)
        case 4002: return .stop(.replaced)
        case 4004: return .stop(.sessionEnded)
        case 4010: return .stop(.revoked)
        case 4011: return .redial            // liveness: silent past the ping budget (openab-pty#86)
        default:   return .redial            // 1000, 1006, 4006, anything else
        }
    }

    public static func disposition(handshakeStatus: Int, kind: Kind = .openabPty) -> Disposition {
        if kind == .switchboard {
            switch handshakeStatus {
            case 401, 403: return .waitForCredentials
            default:       return .redial      // switchboard down, restarting, or behind a proxy error
            }
        }
        switch handshakeStatus {
        case 200..<300, 101: return .redial // not a rejection; caller should not be here
        case 429, 500..<600: return .redial // throttled or the runtime is unwell; wait
        default:             return .stop(.handshakeRejected(handshakeStatus))
        }
    }

    public private(set) var state: State = .idle
    public let config: Config
    private let server: MCPServer
    private let log: @Sendable (String) -> Void
    private var task: URLSessionWebSocketTask?
    private var runLoopTask: Task<Void, Never>?
    private let onStateChange: @Sendable (State) -> Void
    /// Frames answered on the current socket; surfaced for status.
    public private(set) var callsServed: Int = 0
    public private(set) var attachedSince: Date?
    /// Calls still running, so our own cancellation can reach them.
    private var inflight: [UUID: Task<Void, Never>] = [:]

    /// `server` should already be `scoped(to: config.profile)`; this type does
    /// not re-scope so a caller can pass a pre-built, instruction-tailored server.
    public init(config: Config, server: MCPServer,
                onStateChange: @escaping @Sendable (State) -> Void = { _ in },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.config = config; self.server = server; self.onStateChange = onStateChange; self.log = log
    }

    // MARK: lifecycle

    public func start() {
        guard runLoopTask == nil else { return }
        runLoopTask = Task { [weak self] in await self?.run() }
    }

    public func cancel() {
        runLoopTask?.cancel()
        runLoopTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        // Directly, not via the receive loop: during a redial backoff there is
        // no loop left to do it.
        cancelInflight()
        set(.ended(.cancelled))
    }

    private func set(_ s: State) {
        if case .ended = state { return }   // terminal is sticky
        state = s
        onStateChange(s)
    }

    private func run() async {
        var backoff = config.initialBackoff
        while !Task.isCancelled {
            if Date() >= config.deadline { set(.ended(.deadline)); return }
            set(.dialing)
            let started = Date()
            let outcome = await dialOnce()
            if Task.isCancelled { return }
            if Date().timeIntervalSince(started) >= config.stableAfter {
                backoff = config.initialBackoff
            }
            let base: TimeInterval
            switch outcome {
            case .stop(let t):
                log("attach \(config.session): stopping (\(t))")
                set(.ended(t)); return
            case .waitForCredentials:
                base = config.credentialRetry
            case .redial:
                base = backoff
                backoff = min(backoff * 2, config.maxBackoff)
            }
            let remaining = config.deadline.timeIntervalSinceNow
            guard remaining > 0 else { set(.ended(.deadline)); return }
            let wait = min(config.kind == .switchboard ? Self.jitter(base) : base, remaining)
            set(.waitingToRedial(seconds: wait))
            log("attach \(config.session): redial in \(Int(wait))s")
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    /// ±20 %, so many daemons restarted together do not redial in lockstep.
    static func jitter(_ base: TimeInterval) -> TimeInterval {
        base * Double.random(in: 0.8...1.2)
    }

    /// The secret for the next dial: the file's current contents when one is
    /// configured and readable, else the secret given at start.
    func currentSecret() -> String {
        if let file = config.secretFile,
           let text = try? String(contentsOf: file, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            log("attach \(config.session): \(file.path) is empty; using the previous secret")
        }
        return config.secret
    }

    /// The upgrade request for the next dial, with the current secret.
    func attachRequest() -> URLRequest {
        var req = URLRequest(url: config.attachURL)
        req.setValue("Bearer \(currentSecret())", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        return req
    }

    /// One connection lifetime. Returns what to do next.
    ///
    /// The receive loop never waits on a tool: each frame is answered in its own
    /// task and the reply is queued to a single writer, so a `receive()` is
    /// always outstanding and URLSession keeps answering the runtime's pings.
    private func dialOnce() async -> Disposition {
        let req = attachRequest()
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let ws = session.webSocketTask(with: req)
        ws.maximumMessageSize = 16 * 1024 * 1024
        task = ws
        ws.resume()

        // One writer per socket: WebSocket sends must not interleave.
        let (outbox, outboxIn) = AsyncStream<String>.makeStream()
        let sendFailed = LockedFlag()
        let writer = Task { [weak self] in
            for await reply in outbox {
                do { try await ws.send(.string(reply)) } catch {
                    // The socket is broken; wake the receive loop so it redials.
                    _ = sendFailed.trySet()
                    ws.cancel()
                    return
                }
                await self?.noteServed()
            }
        }
        var keepalive: Task<Void, Never>?
        defer {
            // Every exit (stop code, retryable close, send failure, our own
            // cancel) ends this socket's calls. The runtime has already failed
            // them for the caller, so nothing they do can be delivered, and an
            // `exec` left running would outlive the grant (it kills its process
            // group on cancellation). Long work belongs in `exec_start`, whose
            // jobs are not tied to a socket.
            cancelInflight()
            outboxIn.finish()
            writer.cancel()
            keepalive?.cancel()
        }

        // The handshake outcome is only observable by receiving. A rejected
        // upgrade surfaces as an error whose task has an HTTPURLResponse.
        var firstFrame = true
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await ws.receive()
            } catch {
                if Task.isCancelled { return .stop(.cancelled) }
                if let http = ws.response as? HTTPURLResponse, http.statusCode != 101, firstFrame {
                    log("attach \(config.session): handshake rejected \(http.statusCode)")
                    return Self.disposition(handshakeStatus: http.statusCode, kind: config.kind)
                }
                let code = ws.closeCode.rawValue
                if code != 0, !sendFailed.isSet {
                    log("attach \(config.session): closed \(code) after \(callsServed) calls")
                    finishAttached()
                    return Self.disposition(closeCode: code, kind: config.kind)
                }
                log("attach \(config.session): socket error \(error.localizedDescription)")
                finishAttached()
                return .redial
            }
            if firstFrame {
                firstFrame = false
                attachedSince = Date()
                callsServed = 0
                set(.attached)
                log("attach \(config.session): attached as \(config.profile.rawValue) to \(config.runtime.host ?? "?")")
                keepalive = startKeepalive(ws)
            }
            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(decoding: d, as: UTF8.self)
            @unknown default: continue
            }
            // No per-socket cap: the runtime already bounds calls in flight (64),
            // as the HTTP endpoint relies on its clients. Calls pipelined on one
            // socket may finish out of order (each reply carries its id), so a
            // caller that needs UI steps in order must wait for each reply.
            let id = UUID()
            inflight[id] = Task { [weak self] in
                guard let self else { return }
                if let reply = await self.answer(text) { outboxIn.yield(reply) }
                await self.inflightDone(id)
            }
        }
    }

    /// Our own ping, so the runtime hears from us even if nothing else is sent.
    private func startKeepalive(_ ws: URLSessionWebSocketTask) -> Task<Void, Never>? {
        let interval = config.keepaliveInterval
        guard interval > 0 else { return nil }
        let session = config.session
        let log = self.log
        return Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                ws.sendPing { error in
                    if let error { log("attach \(session): keepalive ping failed: \(error.localizedDescription)") }
                }
            }
        }
    }

    private func noteServed() { callsServed += 1 }

    private func inflightDone(_ id: UUID) { inflight[id] = nil }

    /// On every socket exit and on our own `cancel()`: the calls of a dead
    /// socket cannot be answered, so none of them carries into the next one.
    private func cancelInflight() {
        for t in inflight.values { t.cancel() }
        inflight.removeAll()
    }

    private func finishAttached() {
        attachedSince = nil
        task = nil
    }

    /// One inbound frame → one reply (nil for notifications). Exactly the HTTP
    /// endpoint's dispatch, minus sessions and auth: the socket *is* the session,
    /// and the grant *is* the auth. No header on this socket is trusted.
    func answer(_ text: String) async -> String? {
        let rpc: JSONRPCRequest
        switch MCPServer.parse(Data(text.utf8)) {
        case .failure(let e):
            return encode(JSONRPCResponse(id: .null, error: e))
        case .success(let r): rpc = r
        }
        if let refusal = refuseLongExec(rpc) { return encode(refusal) }
        guard let response = await server.handle(rpc) else { return nil }
        if rpc.method == "tools/call" {
            let name = rpc.params?["name"]?.stringValue ?? "?"
            log("sandbox[\(config.session)] tools/call \(name)\(response.error != nil ? " -> rpc error" : "")")
        }
        return encode(response)
    }

    /// The longest `exec` / `osascript` timeout we accept on an openab-pty
    /// attach. The runtime fails any call that has no reply after 120 s
    /// (`REQUEST_TIMEOUT`), so a longer one could only end in an error for the
    /// caller.
    public static let maxAttachedExecTimeout: TimeInterval = 100

    /// An `exec` or `osascript` over `maxAttachedExecTimeout` on an openab-pty
    /// attach is refused as a tool error (the model sees it) pointing at
    /// `exec_start`, rather than clamped, so the caller is not surprised by a
    /// silent early kill.
    func refuseLongExec(_ rpc: JSONRPCRequest) -> JSONRPCResponse? {
        guard config.kind == .openabPty, rpc.method == "tools/call",
              let tool = rpc.params?["name"]?.stringValue, tool == "exec" || tool == "osascript",
              let asked = rpc.params?["arguments"]?["timeout_secs"]?.doubleValue,
              asked > Self.maxAttachedExecTimeout else { return nil }
        let limit = Int(Self.maxAttachedExecTimeout)
        return JSONRPCResponse(id: rpc.id ?? .null, result: ToolResult.error(
            "\(tool) timeout_secs \(Int(asked)) is over this attach's limit of \(limit) s: the runtime fails " +
            "any call still running after 120 s. For long work use exec_start, then check it with " +
            "exec_poll; never sleep inside exec.").json)
    }

    private func encode(_ r: JSONRPCResponse) -> String {
        String(decoding: (try? JSONCoding.encoder.encode(r)) ?? Data("{}".utf8), as: UTF8.self)
    }
}
