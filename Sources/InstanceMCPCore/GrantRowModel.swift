import Foundation

/// One reverse-attach grant as the menu lists it. Pure, so the warning and the
/// requested profile are tested without AppKit.
public struct GrantRowModel: Equatable, Sendable {
    public let id: String
    public let session: String
    /// The profile served (`owner` or `observe`).
    public let profile: String
    /// True for `owner`: the grant reaches the desktop user's shell, so the row says so.
    public let shellEquivalent: Bool
    /// The name the granter asked for, shown only when it differs from `profile`
    /// (for example `desktop`, mapped to `observe` per #59).
    public let requestedProfile: String?
    /// The mapping warning from the grant JSON. Shown whenever present.
    public let warning: String?
    public let stateLabel: String
    public let expiresText: String

    public static func make(_ g: AttachManager.Grant, now: Date) -> GrantRowModel {
        GrantRowModel(
            id: g.id,
            session: g.session,
            profile: g.profile.rawValue,
            shellEquivalent: g.profile.isShellEquivalent,
            requestedProfile: g.requestedProfile == g.profile.rawValue ? nil : g.requestedProfile,
            warning: g.warning,
            stateLabel: stateLabel(g.state),
            expiresText: expiresText(g.expiresAt, now: now)
        )
    }

    static func stateLabel(_ s: ReverseAttachClient.State) -> String {
        switch s {
        case .idle: return "idle"
        case .dialing: return "dialling"
        case .attached: return "attached"
        case .waitingToRedial(let secs): return "redialling in \(Int(secs.rounded())) s"
        case .ended(let t): return AttachManager.Grant.label(t).replacingOccurrences(of: "_", with: " ")
        }
    }

    static func expiresText(_ at: Date, now: Date) -> String {
        let left = Int(at.timeIntervalSince(now).rounded(.down))
        if left <= 0 { return "expired" }
        if left < 60 { return "expires in under a minute" }
        if left < 3600 { return "expires in \(left / 60) min" }
        let h = left / 3600
        let m = (left % 3600) / 60
        return m == 0 ? "expires in \(h) h" : "expires in \(h) h \(m) min"
    }
}
