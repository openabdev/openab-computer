import Foundation

/// Which tools a connection may see and call. Chosen by *this* side — the Mac is
/// the MCP server, so scoping is a per-connection tool list here, never MCP
/// parsing in a proxy (instance-mcp `docs/adr/reverse-attach.md`).
///
/// Two profiles (openab-computer#59), named after the one boundary that is real:
/// shell-equivalent or not.
///
/// `owner` is everything: every local tool (shell, input, `osascript`, background
/// jobs) and every upstream tool, including all `browser_*` tools. The browser uses
/// this computer's persistent profile and network, so it is owner-level, like the
/// shell. `owner` is shell-equivalent.
///
/// `observe` is the boundary: `sys_info` and `screenshot` only, no upstream tool.
/// The agent can see the screen (which still discloses what is on it) but cannot
/// change anything, so it is not shell-equivalent. It is also the default when an
/// attach request names no profile.
///
/// The retired name `desktop` is accepted as *input* only and resolves to
/// `observe`, never to `owner`, with `retiredWarning` returned to the granter
/// (`resolve(requested:)`, `resolve(stored:requested:)`). The old name `sandbox` is
/// **not** accepted: it is refused (400) like any unknown profile, and a grant stored
/// under it is dropped (#46). Full per-profile tool lists: `docs/tool-profiles.md`.
public enum ToolProfile: String, Codable, Sendable, CaseIterable {
    case owner
    case observe

    /// The profile of an attach request that names none. Fails closed.
    public static let defaultProfile: ToolProfile = .observe

    /// The profile name removed in #59. Input only; never a `ToolProfile`.
    public static let retiredName = "desktop"

    /// The 400 body for an unknown profile name. Byte-identical on Linux and pinned in
    /// `conformance/profile_vectors.json`.
    public static let rejectionMessage = "profile must be one of [owner, observe]"

    /// Shown to the granter when `desktop` was asked for (or stored) and `observe` is
    /// served. Byte-identical on Linux and pinned in the vectors.
    public static let retiredWarning = "The `desktop` profile was removed (openab-computer#59). This grant runs as `observe`: sys_info and screenshot only. Grant `owner` explicitly for shell and browser access."

    /// What a profile name resolved to: the profile served, the name asked for, and
    /// the warning the granter must see when the two differ.
    public struct Resolution: Sendable, Equatable {
        public let profile: ToolProfile
        public let requested: String
        public let warning: String?
    }

    /// Resolve a name from an attach request or a `--switchboard-profile` flag. Exact,
    /// case-sensitive match. `desktop` → `observe` with `retiredWarning`; any other
    /// unknown name → nil (refuse).
    public static func resolve(requested name: String) -> Resolution? {
        if let p = ToolProfile(rawValue: name) { return Resolution(profile: p, requested: name, warning: nil) }
        if name == retiredName { return Resolution(profile: .observe, requested: name, warning: retiredWarning) }
        return nil
    }

    /// Resolve a persisted grant row. `requested` is display-only and never widens:
    /// the effective profile is the narrower of the two resolutions. Either name
    /// unknown → nil (drop the row).
    public static func resolve(stored: String, requested: String?) -> Resolution? {
        guard let s = resolve(requested: stored) else { return nil }
        guard let requested else { return s }
        guard let r = resolve(requested: requested) else { return nil }
        let profile: ToolProfile = (s.profile == .observe || r.profile == .observe) ? .observe : .owner
        return Resolution(profile: profile, requested: requested, warning: s.warning ?? r.warning)
    }

    /// Whether this profile grants (directly or through GUI control) the desktop
    /// user's shell. `observe` is not, and `ProfileBoundaryTests` holds it to that:
    /// it must allow no shell-capable tool.
    public var isShellEquivalent: Bool {
        switch self {
        case .owner: return true
        case .observe: return false
        }
    }

    /// Everything `observe` may call. An allowlist, so a new tool — local or
    /// upstream — is denied under `observe` until it is listed here.
    public static let observeTools: Set<String> = ["sys_info", "screenshot"]

    /// What a tool can do, as far as a boundary is concerned.
    public enum ToolClass: String, Sendable, CaseIterable {
        /// Reads only; changes nothing.
        case observe
        /// Changes state, but cannot run code as the desktop user.
        case act
        /// Reaches the desktop user's shell, directly or by driving the GUI.
        case shell
    }

    /// Every local tool, classified. **Exhaustive by test**: a tool in
    /// `ToolCatalog.local` without an entry here fails `ProfileBoundaryTests`,
    /// so a new tool cannot slip past the boundary check by simply not being
    /// listed as dangerous. Classify conservatively: if it can open, type into,
    /// or script anything that runs code, it is `.shell`.
    public static let localToolClass: [String: ToolClass] = [
        "sys_info": .observe,
        "screenshot": .observe,
        "exec_poll": .observe,     // reads a job's state and output; starts nothing
        "exec_list": .observe,
        "ui_snapshot": .observe,   // reads other apps' UI; owner-only in phase 1 (#67), not in observeTools
        "exec_cancel": .act,       // signals a job's process group
        "exec": .shell,
        "exec_start": .shell,
        "osascript": .shell,       // `do shell script`, JXA, NSTask
        "key": .shell,             // can type into a terminal
        "mouse": .shell,           // can open one
    ]

    /// Local tools that reach a shell as the desktop user. Any profile with
    /// `isShellEquivalent == false` must allow none.
    public static var shellCapableTools: Set<String> {
        Set(localToolClass.filter { $0.value == .shell }.keys)
    }

    /// Match is on the tool name. `owner` allows every tool, local or upstream,
    /// including every `browser_*` tool.
    public func allows(_ toolName: String) -> Bool {
        switch self {
        case .owner: return true
        case .observe:
            // Both: on the allowlist *and* classified as observation, so a tool added
            // to the allowlist by mistake is still refused unless it changes nothing.
            return Self.observeTools.contains(toolName) && Self.localToolClass[toolName] == .observe
        }
    }
}

extension MCPServer {
    /// The same server with its tool list narrowed to `profile`. `tools/list`
    /// omits the rest and `tools/call` on an omitted tool is an *unknown tool*
    /// error, indistinguishable from a tool that never existed — the agent is not
    /// told there is something it is not allowed to have.
    public func scoped(to profile: ToolProfile, instructions: String? = nil) -> MCPServer {
        MCPServer(
            name: serverName,
            version: serverVersion,
            instructions: instructions ?? self.instructions,
            tools: allTools.filter { profile.allows($0.name) },
            upstreams: upstreams,
            upstreamFilter: profile
        )
    }
}
