import Foundation
import CryptoKit
import Darwin

public enum Arch: String, Sendable, CaseIterable, Codable {
    case arm64
    case x86_64

    /// `sysctl hw.optional.arm64` is 1 on Apple silicon, including under Rosetta.
    public static var current: Arch {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &v, &size, nil, 0) == 0, v == 1 { return .arm64 }
        return .x86_64
    }
}

public protocol ArchProvider: Sendable { var arch: Arch { get } }
public struct SystemArchProvider: ArchProvider { public init() {}; public var arch: Arch { Arch.current } }

/// The pinned artifacts of the on-demand Playwright install (ADR browser-tiers Q4). The data is the
/// generated Swift constant in `PlaywrightPins.generated.swift`, part of the signed app. A release
/// check (`scripts/playwright-pins.py`) produces and verifies it; nothing here downloads a pin.
public struct PlaywrightManifest: Codable, Equatable, Sendable {
    public struct Artifact: Codable, Equatable, Sendable {
        public let url: String
        public let format: String
        public let size: Int64
        public let sha256: String
        public let stripComponents: Int
        public let expandedBytes: Int64
        public let entryCount: Int
        public let maxEntryBytes: Int64
        public let executable: String?
    }
    public struct MCP: Codable, Equatable, Sendable {
        public let package: String
        public let version: String
        public let playwrightCoreVersion: String
        public let packageJsonSHA256: String
        public let lockfileSHA256: String
        public let npmDownloadBytes: Int64
        public let npmInstalledBytes: Int64
        public let npmPackageCount: Int
    }
    public struct Node: Codable, Equatable, Sendable {
        public let version: String
        public let teamIdentifier: String
        public let artifacts: [String: Artifact]
    }
    public struct Chromium: Codable, Equatable, Sendable {
        public let revision: String
        public let browserVersion: String
        public let releasedAt: String
        public let host: String
        public let artifacts: [String: Artifact]
    }

    public let schema: Int
    public let id: String
    public let mcp: MCP
    public let node: Node
    public let chromium: Chromium
    public let hosts: [String]
    public let staleAfterDays: Int
    public let freeDiskFactor: Int

    public static let allowedFormats: [String: String] = ["node": "tar.gz", "chromium": "zip"]

    /// The manifest built into this app. A decoding failure here is a build error caught by
    /// `PlaywrightPinsTests`, never a runtime condition.
    public static let embedded: PlaywrightManifest = {
        // swiftlint:disable:next force_try
        try! decode(PlaywrightPins.pinsJSON)
    }()

    public static func decode(_ json: String) throws -> PlaywrightManifest {
        try JSONDecoder().decode(PlaywrightManifest.self, from: Data(json.utf8))
    }

    public func nodeArtifact(_ arch: Arch) -> Artifact? { node.artifacts[arch.rawValue] }
    public func chromiumArtifact(_ arch: Arch) -> Artifact? { chromium.artifacts[arch.rawValue] }

    private static let safeID = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]*$")
    private static let hex64 = try! NSRegularExpression(pattern: "^[0-9a-f]{64}$")
    private static let teamID = try! NSRegularExpression(pattern: "^[A-Z0-9]{10}$")

    private static func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    public static func isSafeID(_ s: String) -> Bool { matches(safeID, s) && s.utf8.count <= 128 }
    public static func isSafeTeamID(_ s: String) -> Bool { matches(teamID, s) }

    /// One line per problem; empty means valid. Called before any install.
    public func validate(allowLoopbackHTTP: Bool = false) -> [String] {
        var p: [String] = []
        if schema != 1 { p.append("schema") }
        if !Self.isSafeID(id) { p.append("id") }
        if !Self.isSafeTeamID(node.teamIdentifier) { p.append("node.teamIdentifier") }
        if Set(hosts) != Set(["nodejs.org", "registry.npmjs.org", chromium.host]) || hosts.count != 3 { p.append("hosts") }
        if !Self.matches(Self.hex64, mcp.packageJsonSHA256) || !Self.matches(Self.hex64, mcp.lockfileSHA256) { p.append("mcp digests") }
        if freeDiskFactor < 3 { p.append("freeDiskFactor") }
        if staleAfterDays < 1 { p.append("staleAfterDays") }
        if Self.parseDay(chromium.releasedAt) == nil { p.append("chromium.releasedAt") }
        for (label, arts) in [("node", node.artifacts), ("chromium", chromium.artifacts)] {
            if Set(arts.keys) != Set(Arch.allCases.map(\.rawValue)) { p.append("\(label) architectures") }
            for (arch, a) in arts {
                let tag = "\(label)/\(arch)"
                guard let u = URL(string: a.url), let h = u.host, hosts.contains(h),
                      u.scheme == "https" || (allowLoopbackHTTP && u.scheme == "http" && h == "127.0.0.1"),
                      !u.pathComponents.contains("..") else { p.append("\(tag) url"); continue }
                if !Self.matches(Self.hex64, a.sha256) { p.append("\(tag) sha256") }
                if a.format != Self.allowedFormats[label] { p.append("\(tag) format") }
                if a.size <= 0 || a.expandedBytes <= 0 || a.entryCount <= 0 || a.maxEntryBytes <= 0 { p.append("\(tag) limits") }
                if a.stripComponents < 0 || a.stripComponents > 4 { p.append("\(tag) stripComponents") }
                if label == "chromium" {
                    guard let e = a.executable, !e.isEmpty, !e.hasPrefix("/"), !e.split(separator: "/").contains("..") else {
                        p.append("\(tag) executable"); continue
                    }
                }
            }
        }
        return p
    }

    /// The embedded package.json and lockfile must hash to the values in this manifest.
    func validateEmbeddedFiles(packageJSON: String = PlaywrightPins.packageJSON,
                                      lockfileJSON: String = PlaywrightPins.lockfileJSON) -> [String] {
        var p: [String] = []
        if Self.sha256Hex(Data(packageJSON.utf8)) != mcp.packageJsonSHA256 { p.append("package.json digest") }
        if Self.sha256Hex(Data(lockfileJSON.utf8)) != mcp.lockfileSHA256 { p.append("lockfile digest") }
        return p
    }

    public static func sha256Hex(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    static func parseDay(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    /// Total bytes one architecture downloads: Node, Chromium and the npm tarballs.
    public func downloadBytes(_ arch: Arch) -> Int64 {
        (nodeArtifact(arch)?.size ?? 0) + (chromiumArtifact(arch)?.size ?? 0) + mcp.npmDownloadBytes
    }

    /// Disk the install may need while it runs: downloads plus the expanded trees plus npm.
    public func diskBytes(_ arch: Arch) -> Int64 {
        downloadBytes(arch) + (nodeArtifact(arch)?.expandedBytes ?? 0) + (chromiumArtifact(arch)?.expandedBytes ?? 0)
            + mcp.npmInstalledBytes
    }
}

/// What the consent text shows (R7.2 step 1): every number comes from the manifest.
public struct PlaywrightInstallPlan: Equatable, Sendable {
    public let downloadBytes: Int64
    public let diskBytes: Int64
    public let hosts: [String]
    public let installPath: String
    public let nodeVersion: String
    public let mcpVersion: String
    public let chromiumVersion: String
    public let id: String

    public init(manifest m: PlaywrightManifest, arch: Arch, root: URL) {
        downloadBytes = m.downloadBytes(arch)
        // The free space install() requires (same formula), not just what the install uses.
        diskBytes = max(Int64(m.freeDiskFactor) * m.downloadBytes(arch), m.diskBytes(arch))
        hosts = ["nodejs.org", "registry.npmjs.org", m.chromium.host]
        installPath = root.path
        nodeVersion = m.node.version
        mcpVersion = m.mcp.version
        chromiumVersion = m.chromium.browserVersion
        id = m.id
    }
}
