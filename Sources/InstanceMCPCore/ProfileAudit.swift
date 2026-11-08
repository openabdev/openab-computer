import Foundation

/// The audit trail for retired profile names (#59).
///
/// When a request, a stored grant or a `--switchboard-profile` flag names the retired
/// `desktop` and the daemon serves `observe` instead, it appends one JSON line here
/// as well as logging it. The file is append-only and separate from the daemon log,
/// so the record survives log rotation and is easy to inspect:
/// `~/Library/Application Support/oab-instance-mcp/audit.jsonl`, mode 600 in a 0700
/// directory, beside `grants.json`. The Linux node writes the same record shape.
///
/// Writing is best-effort: a failure is logged and never blocks the grant.
public protocol AuditLog: Sendable {
    func append(_ entry: JSONValue)
}

public enum ProfileAudit {
    /// One `profile_mapped` record. `source` is `attach`, `resume` or `switchboard`.
    /// `grant`, `session` and `principal` are nil for the switchboard flag.
    public static func mapped(source: String, requested: String, profile: ToolProfile,
                              grant: String? = nil, session: String? = nil, principal: String? = nil,
                              at now: Date = Date()) -> JSONValue {
        var o: [String: JSONValue] = [
            "event": "profile_mapped",
            "source": .string(source),
            "requested_profile": .string(requested),
            "profile": .string(profile.rawValue),
            "ts_epoch_secs": .number(now.timeIntervalSince1970.rounded(.down)),
        ]
        if let grant { o["grant"] = .string(grant) }
        if let session { o["session"] = .string(session) }
        if let principal { o["principal"] = .string(principal) }
        return .object(o)
    }
}

public final class FileAuditLog: AuditLog, @unchecked Sendable {
    public let url: URL
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/oab-instance-mcp/audit.jsonl")
    }

    public init(url: URL = FileAuditLog.defaultURL, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.url = url; self.log = log
    }

    public func append(_ entry: JSONValue) {
        lock.lock(); defer { lock.unlock() }
        do {
            var line = try JSONCoding.encoder.encode(entry)
            line.append(0x0A)
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            if !fm.fileExists(atPath: url.path) {
                guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            } else if let mode = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber,
                      mode.intValue & 0o077 != 0 {
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: line)
        } catch {
            log("audit: could not append to \(url.path): \(error)")
        }
    }
}

/// Test double.
public final class InMemoryAuditLog: AuditLog, @unchecked Sendable {
    private var values: [JSONValue] = []
    private let lock = NSLock()
    public init() {}
    public func append(_ entry: JSONValue) { lock.lock(); values.append(entry); lock.unlock() }
    public var entries: [JSONValue] { lock.lock(); defer { lock.unlock() }; return values }
}
