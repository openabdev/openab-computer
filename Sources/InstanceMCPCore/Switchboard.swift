import Foundation

/// Switchboard mode: this computer dials an openab-sb switchboard's
/// `GET /vm/attach` and serves its tools there, under one tool profile, for as
/// long as the process runs. Contract: openab-sb `docs/SOUTHBOUND-CONTRACT.md`.
///
/// ```text
///   callers ─► openab-sb /mcp ─► Hub ◄── WS /vm/attach ── this Mac (dials out)
/// ```
///
/// The switchboard applies its own per-caller allowlist on top; the profile here
/// is this computer's own ceiling and the one that matters if the switchboard
/// is misconfigured.
public enum Switchboard {
    public enum ConfigError: Error, Equatable, CustomStringConvertible {
        case badURL(String)
        case plaintextToRemote(String)

        public var description: String {
            switch self {
            case .badURL(let u):
                return "--switchboard wants a ws:// or wss:// URL ending in /vm/attach, got \(u)"
            case .plaintextToRemote(let h):
                return "--switchboard: ws:// is only allowed to loopback; use wss:// for \(h) (the secret would cross the network in clear)"
            }
        }
    }

    /// Accept `wss://…/vm/attach`, or `ws://` to a loopback host only.
    public static func validate(_ text: String) throws -> URL {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty,
              scheme == "ws" || scheme == "wss",
              url.path.hasSuffix("/vm/attach") else {
            throw ConfigError.badURL(text)
        }
        if scheme == "ws" && !isLoopback(host) { throw ConfigError.plaintextToRemote(host) }
        return url
    }

    static func isLoopback(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return h == "localhost" || h == "::1" || h.hasPrefix("127.")
    }

    /// Instructions for the scoped server: say how the caller got here, which a
    /// Connect-lent session's instructions would get wrong.
    public static func instructions(profile: ToolProfile, base: String?) -> String? {
        let head = base.map { $0 + "\n\n" } ?? ""
        switch profile {
        case .observe:
            return head + """
                You reached this computer through OpenAB Switchboard under the `observe` profile: you may \
                look, not act. Only `sys_info` and `screenshot` are available — you cannot click, type or run \
                anything here. If the task needs input, ask the operator to change the profile.
                """
        case .owner:
            return base
        }
    }

    /// A client that dials `url` with the secret in `secretFile` (re-read on
    /// every dial) and serves `server` scoped to `profile`.
    public static func client(url: URL, secretFile: URL, secret: String, profile: ToolProfile,
                              server: MCPServer,
                              onStateChange: @escaping @Sendable (ReverseAttachClient.State) -> Void = { _ in },
                              log: @escaping @Sendable (String) -> Void = { _ in }) -> ReverseAttachClient {
        let scoped = server.scoped(to: profile, instructions: instructions(profile: profile, base: server.instructions))
        let config = ReverseAttachClient.Config.switchboard(url: url, secret: secret, secretFile: secretFile,
                                                            profile: profile)
        return ReverseAttachClient(config: config, server: scoped, onStateChange: onStateChange, log: log)
    }
}
