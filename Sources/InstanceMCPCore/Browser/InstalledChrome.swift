import Foundation
import Security
import Darwin

/// The "use my installed Google Chrome" route (ADR Q3 and Q5, R7.3). Everything here only reads: the app never
/// copies, moves, edits or deletes the Chrome bundle, never touches its profile and never sets or removes
/// `com.apple.quarantine`. The version of this Chrome is not pinned and no digest of it is checked; what is
/// checked is that it is Google's own signed build, in an Applications folder, on every start.
public struct InstalledChrome: Equatable, Sendable {
    public let appPath: String
    public let executablePath: String
    /// `CFBundleShortVersionString`, read from the bundle after the signature check.
    public let version: String
    public let major: Int
}

/// Why an installed Chrome cannot be used. Each case has a fixed class that reaches logs and `sys_info`.
public enum InstalledChromeProblem: Error, Equatable, Sendable {
    case notFound
    /// Not at a known path, a symlink, or a bundle that is not Google Chrome (Chromium, Chrome Beta, a fork).
    case notGoogleChrome
    case invalidSignature
    case tooOld(found: Int, minimum: Int)
    case unreadable

    public var errorClass: String {
        switch self {
        case .notFound: return "chrome_missing"
        case .notGoogleChrome: return "chrome_not_google"
        case .invalidSignature: return "chrome_invalid_signature"
        case .tooOld: return "chrome_too_old"
        case .unreadable: return "chrome_unreadable"
        }
    }

    public static let classes = ["chrome_missing", "chrome_not_google", "chrome_invalid_signature", "chrome_too_old", "chrome_unreadable"]
}

/// What the app accepts as "Google Chrome". Nothing here is read from the network or from the bundle.
public enum InstalledChromePolicy {
    public static let appName = "Google Chrome.app"
    public static let bundleIdentifier = "com.google.Chrome"
    public static let executableName = "Google Chrome"
    /// Google LLC's Apple team identifier (read from `codesign -dv` on Google Chrome).
    public static let teamIdentifier = "EQHXZ8M8AV"
    /// The app's own floor for the major version. It is not a statement that every newer Chrome works.
    public static let minimumMajor = 120
    /// The signing identity: Chrome's identifier, an Apple-rooted chain, a Developer ID Application leaf
    /// (marker 1.2.840.113635.100.6.1.13) and Google LLC's team in the leaf's OU.
    public static let requirement =
        "identifier \"\(bundleIdentifier)\" and anchor apple generic "
        + "and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ "
        + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
}

public protocol ChromeSignatureVerifying: Sendable {
    func verify(app: URL) -> Bool
}

/// The production check: the Security framework validates the whole bundle, nested code included, against
/// `InstalledChromePolicy.requirement`, with no subprocess and no launch.
public struct SecurityFrameworkChromeVerifier: ChromeSignatureVerifying {
    public init() {}
    public func verify(app: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, SecCSFlags(), &code) == errSecSuccess, let code else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(InstalledChromePolicy.requirement as CFString, SecCSFlags(), &req) == errSecSuccess,
              let req else { return false }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        return (dict[kSecCodeInfoTeamIdentifier as String] as? String) == InstalledChromePolicy.teamIdentifier
    }
}

public protocol InstalledChromeChecking: Sendable {
    /// Cheap: a `Google Chrome.app` exists in an allowed folder. No signature check; used to decide whether to offer.
    func isInstalled() -> Bool
    /// The first allowed `Google Chrome.app`, fully checked.
    func check() -> Result<InstalledChrome, InstalledChromeProblem>
    /// A recorded path, fully checked. A path that is not one of the allowed locations is refused.
    func check(appPath: String) -> Result<InstalledChrome, InstalledChromeProblem>
    /// The version string of a recorded path, with no signature check (for a status line).
    func displayVersion(appPath: String) -> String?
}

/// Looks for Google Chrome in `/Applications` and `~/Applications` only, and accepts it only when it is the
/// real bundle, signed by Google LLC, at or above the minimum major version.
public final class InstalledChromeChecker: InstalledChromeChecking, @unchecked Sendable {
    private let directories: [URL]
    private let verifier: any ChromeSignatureVerifying
    private let minimumMajor: Int

    public static func defaultDirectories(home: String = NSHomeDirectory()) -> [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Applications", isDirectory: true)]
    }

    /// Every check runs the full signature validation: the result is never reused.
    public init(directories: [URL] = InstalledChromeChecker.defaultDirectories(),
                verifier: any ChromeSignatureVerifying = SecurityFrameworkChromeVerifier(),
                minimumMajor: Int = InstalledChromePolicy.minimumMajor) {
        self.directories = directories.map { $0.standardizedFileURL }
        self.verifier = verifier; self.minimumMajor = minimumMajor
    }

    private func candidates() -> [URL] {
        directories.map { $0.appendingPathComponent(InstalledChromePolicy.appName, isDirectory: true) }
    }

    private static func kind(_ path: String) -> mode_t? {
        var st = stat()
        return lstat(path, &st) == 0 ? (st.st_mode & S_IFMT) : nil
    }

    public func isInstalled() -> Bool {
        candidates().contains { Self.kind($0.path) != nil }
    }

    public func check() -> Result<InstalledChrome, InstalledChromeProblem> {
        guard let first = candidates().first(where: { Self.kind($0.path) != nil }) else { return .failure(.notFound) }
        return check(appPath: first.path)
    }

    private func plist(_ app: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let o = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any] else { return nil }
        return o
    }

    public func displayVersion(appPath: String) -> String? {
        let app = URL(fileURLWithPath: appPath, isDirectory: true).standardizedFileURL
        guard candidates().contains(where: { $0.path == app.path }) else { return nil }
        return plist(app)?["CFBundleShortVersionString"] as? String
    }

    public func check(appPath: String) -> Result<InstalledChrome, InstalledChromeProblem> {
        let app = URL(fileURLWithPath: appPath, isDirectory: true).standardizedFileURL
        // Only the two Applications folders. A hand-edited record cannot point the app at another binary.
        guard candidates().contains(where: { $0.path == app.path }) else { return .failure(.notGoogleChrome) }
        guard let k = Self.kind(app.path) else { return .failure(.notFound) }
        guard k == S_IFDIR else { return .failure(.notGoogleChrome) }   // a symlink or a file is never accepted
        guard let p = plist(app) else { return .failure(.unreadable) }
        guard p["CFBundleIdentifier"] as? String == InstalledChromePolicy.bundleIdentifier,
              p["CFBundleExecutable"] as? String == InstalledChromePolicy.executableName else { return .failure(.notGoogleChrome) }
        let exec = app.appendingPathComponent("Contents/MacOS/\(InstalledChromePolicy.executableName)")
        guard Self.kind(exec.path) == S_IFREG, access(exec.path, X_OK) == 0 else { return .failure(.unreadable) }
        guard verifier.verify(app: app) else { return .failure(.invalidSignature) }
        // The version is read after the signature check: the Info.plist is sealed by it.
        guard let v = plist(app)?["CFBundleShortVersionString"] as? String,
              let major = Int(v.prefix(while: { $0.isASCII && $0.isNumber })), v.count < 64 else { return .failure(.unreadable) }
        guard major >= minimumMajor else { return .failure(.tooOld(found: major, minimum: minimumMajor)) }
        return .success(InstalledChrome(appPath: app.path, executablePath: exec.path, version: v, major: major))
    }
}

/// Which browser the managed Playwright drives.
public enum BrowserEngine: Equatable, Sendable {
    /// The pinned, digest-checked Chromium this app downloads (the default).
    case downloadedChromium
    /// The user's installed Google Chrome, after an explicit consent. Not pinned and not digest-checked.
    case installedChrome
}

/// The stored choice, written into the install record only after consent and a successful health check.
struct SystemChromeRecord: Codable, Equatable {
    var appPath: String
    /// The version when the user consented; the live version is read from the bundle on every start.
    var versionAtConsent: String
    var consentedAt: String?
}
