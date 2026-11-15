import Foundation
import Security

/// Checks the downloaded Node's code signature before it first runs (Q5, R7.1). No subprocess:
/// the Security framework validates the signature and the Developer ID chain, and the team
/// identifier must equal the manifest's value.
protocol NodeSignatureVerifying: Sendable {
    func verify(executable: URL, teamIdentifier: String) -> Bool
}

struct SecurityFrameworkNodeVerifier: NodeSignatureVerifying {
    func verify(executable: URL, teamIdentifier: String) -> Bool {
        // The team identifier is interpolated into a code requirement: only ten upper-case
        // letters and digits are accepted, so nothing can alter the requirement text.
        guard PlaywrightManifest.isSafeTeamID(teamIdentifier) else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, SecCSFlags(), &code) == errSecSuccess, let code else { return false }
        // Developer ID Application leaf (marker 1.2.840.113635.100.6.1.13), Apple anchor, this team.
        let text = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ "
            + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &req) == errSecSuccess, let req else { return false }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        return (dict[kSecCodeInfoTeamIdentifier as String] as? String) == teamIdentifier
    }
}
