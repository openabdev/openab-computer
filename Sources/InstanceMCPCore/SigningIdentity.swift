import Foundation
import Security

/// Signing facts about the running app. Used only to decide whether to show the ad-hoc banner.
public enum SigningIdentity {
    // TODO(Q10): the re-sign reset text (designated requirement hash, old TCC entry guidance) is not implemented.
    // It needs the manual re-sign test on a real Mac before it ships.

    /// What the signature of the running app says about its team.
    public enum Lookup: Equatable, Sendable {
        /// Signed with a team identifier (the release build).
        case team(String)
        /// The signature was read and has no team identifier (ad-hoc or unsigned).
        case noTeam
        /// The signature could not be read. Carries the OSStatus of the failing call.
        case failed(OSStatus)
    }

    public static func lookup() -> Lookup {
        var code: SecCode?
        let selfStatus = SecCodeCopySelf(SecCSFlags(rawValue: 0), &code)
        guard selfStatus == errSecSuccess, let code else { return .failed(selfStatus) }

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else { return .failed(staticStatus) }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        let infoStatus = SecCodeCopySigningInformation(staticCode, flags, &info)
        guard infoStatus == errSecSuccess else { return .failed(infoStatus) }
        guard let dict = info as? [String: Any] else { return .failed(errSecInternalComponent) }

        if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return .team(team)
        }
        return .noTeam
    }
}
