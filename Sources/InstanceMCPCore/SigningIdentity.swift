import Foundation
import Security

/// Signing facts about the running app. Used only to decide whether to show the ad-hoc banner.
public enum SigningIdentity {
    // TODO(Q10): the re-sign reset text (designated requirement hash, old TCC entry guidance) is not implemented.
    // It needs the manual re-sign test on a real Mac before it ships.

    /// Team identifier of the running app, or nil for ad-hoc and unsigned builds or when the lookup fails.
    public static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
