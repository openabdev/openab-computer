import Foundation
import Darwin

/// Why an archive was refused. Fixed values only: no entry name, path or archive text ever
/// reaches a log or a caller (R8.1).
public enum SafeArchiveError: Error, Equatable, Sendable {
    public enum Reason: String, Sendable {
        case unsafePath = "unsafe_path"
        case linkEscape = "link_escape"
        case forbiddenType = "forbidden_type"
        case duplicate = "duplicate"
        case caseCollision = "case_collision"
        case tooManyEntries = "too_many_entries"
        case tooLarge = "too_large"
        case malformed = "malformed"
        case unsupported = "unsupported"
        case setuid = "setuid"
        case changed = "changed_between_stages"
        case io = "io"
    }
    case rejected(Reason)
    public var reason: Reason { if case .rejected(let r) = self { return r }; return .io }
}

public enum ArchiveFormat: String, Sendable { case tarGz = "tar.gz", zip }

public struct ArchiveLimits: Equatable, Sendable {
    public var maxEntries: Int
    public var maxTotalBytes: Int64
    public var maxEntryBytes: Int64
    public var stripComponents: Int
    public init(maxEntries: Int, maxTotalBytes: Int64, maxEntryBytes: Int64, stripComponents: Int = 0) {
        self.maxEntries = maxEntries; self.maxTotalBytes = maxTotalBytes
        self.maxEntryBytes = maxEntryBytes; self.stripComponents = stripComponents
    }
    public init(_ a: PlaywrightManifest.Artifact) {
        self.init(maxEntries: a.entryCount, maxTotalBytes: a.expandedBytes, maxEntryBytes: a.maxEntryBytes,
                  stripComponents: a.stripComponents)
    }
}

public struct PlannedEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case file, directory, symlink }
    public let path: String
    public let kind: Kind
    public let mode: UInt16
    public let size: Int64
    public let linkTarget: String?
    // zip only
    let localOffset: Int64
    let compressedSize: Int64
    let method: UInt16
    let crc: UInt32
}

public struct ArchivePlan: Equatable, Sendable {
    public let format: ArchiveFormat
    public let entries: [PlannedEntry]
    public let totalBytes: Int64
    let stripComponents: Int
    /// Every header, including the stripped top directory.
    let headerCount: Int
}

/// Two-stage archive handling (R7.2 step 5). Stage 1, `validate`, reads the whole archive and
/// writes nothing. Stage 2, `extract`, re-reads it, checks every entry against the plan again and
/// creates entries relative to a directory descriptor with `O_NOFOLLOW` and `O_EXCL`. Only tar.gz
/// (ustar, pax, GNU long names) and zip (stored and deflate, no zip64, no encryption) exist; every
/// other shape is refused. `/usr/bin/tar` and `/usr/bin/unzip` are never used.
public enum SafeArchiveExtractor {
    public static func validate(file: URL, format: ArchiveFormat, limits: ArchiveLimits) throws -> ArchivePlan {
        let f = try ReadFile(path: file.path)
        let planner = EntryPlanner(limits: limits)
        switch format {
        case .tarGz:
            try TarProcessor.run(file: f, limits: limits, sink: PlanningTarSink(planner: planner))
        case .zip:
            try ZipProcessor.plan(file: f, planner: planner)
        }
        return ArchivePlan(format: format, entries: planner.entries, totalBytes: planner.totalBytes,
                           stripComponents: limits.stripComponents, headerCount: planner.headerCount)
    }

    public static func extract(_ plan: ArchivePlan, from file: URL, into directory: URL) throws {
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw SafeArchiveError.rejected(.io) }
        defer { Darwin.close(root) }
        let f = try ReadFile(path: file.path)
        let writer = TreeWriter(root: root)
        defer { writer.closeAll() }
        let limits = ArchiveLimits(maxEntries: plan.headerCount, maxTotalBytes: plan.totalBytes,
                                   maxEntryBytes: plan.entries.map(\.size).max() ?? 0, stripComponents: plan.stripComponents)
        switch plan.format {
        case .tarGz:
            let sink = ExtractingTarSink(planner: EntryPlanner(limits: limits), plan: plan, writer: writer)
            try TarProcessor.run(file: f, limits: limits, sink: sink)
            guard sink.index == plan.entries.count else { throw SafeArchiveError.rejected(.changed) }
        case .zip:
            try ZipProcessor.extract(plan: plan, file: f, writer: writer)
        }
    }
}

/// An entry as the archive names it, before the path rules.
struct RawEntry {
    var name: String
    var kind: PlannedEntry.Kind
    var mode: UInt16
    var size: Int64
    var linkTarget: String?
    var localOffset: Int64 = 0
    var compressedSize: Int64 = 0
    var method: UInt16 = 0
    var crc: UInt32 = 0

    init(_ h: TarHeader) {
        name = h.name; kind = h.kind; mode = h.mode; size = h.size; linkTarget = h.linkName
    }
    init(name: String, kind: PlannedEntry.Kind, mode: UInt16, size: Int64, linkTarget: String?,
         localOffset: Int64, compressedSize: Int64, method: UInt16, crc: UInt32) {
        self.name = name; self.kind = kind; self.mode = mode; self.size = size; self.linkTarget = linkTarget
        self.localOffset = localOffset; self.compressedSize = compressedSize; self.method = method; self.crc = crc
    }
}

/// The path and link rules, shared by both stages and both formats.
final class EntryPlanner {
    let limits: ArchiveLimits
    private(set) var entries: [PlannedEntry] = []
    private(set) var totalBytes: Int64 = 0
    private var kinds: [String: PlannedEntry.Kind] = [:]
    private var lowered: [String: String] = [:]
    private var seen = 0
    var headerCount: Int { seen }

    init(limits: ArchiveLimits) { self.limits = limits }

    /// Returns the planned entry, or nil for the stripped top directory.
    @discardableResult
    func accept(_ e: RawEntry) throws -> PlannedEntry? {
        seen += 1
        if seen > limits.maxEntries { throw SafeArchiveError.rejected(.tooManyEntries) }
        guard let path = try Self.normalize(e.name, strip: limits.stripComponents, isDirectory: e.kind == .directory) else {
            if e.kind != .directory { throw SafeArchiveError.rejected(.unsafePath) }
            return nil
        }
        if e.mode & 0o6000 != 0 { throw SafeArchiveError.rejected(.setuid) }
        let comps = path.split(separator: "/").map(String.init)
        // Every parent must be a directory (an explicit one, or one that does not exist yet): an
        // entry never passes through an earlier symlink or file.
        var prefix = ""
        for c in comps.dropLast() {
            prefix = prefix.isEmpty ? c : prefix + "/" + c
            if let k = kinds[prefix], k != .directory { throw SafeArchiveError.rejected(.unsafePath) }
            // APFS is case-insensitive: `a/x` and `A/y` would share a directory.
            if let other = lowered[prefix.lowercased()], other != prefix { throw SafeArchiveError.rejected(.caseCollision) }
        }
        if let prior = kinds[path] {
            if prior != e.kind || e.kind != .directory { throw SafeArchiveError.rejected(.duplicate) }
        } else {
            let key = path.lowercased()
            if let other = lowered[key], other != path { throw SafeArchiveError.rejected(.caseCollision) }
        }
        var acc = ""
        for c in comps {
            acc = acc.isEmpty ? c : acc + "/" + c
            lowered[acc.lowercased()] = lowered[acc.lowercased()] ?? acc
        }
        var target: String?
        switch e.kind {
        case .file:
            if e.size < 0 || e.size > limits.maxEntryBytes { throw SafeArchiveError.rejected(.tooLarge) }
            totalBytes += e.size
            if totalBytes > limits.maxTotalBytes { throw SafeArchiveError.rejected(.tooLarge) }
        case .directory:
            break
        case .symlink:
            guard let t = e.linkTarget else { throw SafeArchiveError.rejected(.linkEscape) }
            try Self.checkLink(t, from: comps.dropLast().count, kinds: kinds, parent: comps.dropLast().joined(separator: "/"))
            target = t
        }
        kinds[path] = e.kind
        let planned = PlannedEntry(path: path, kind: e.kind, mode: e.kind == .directory ? 0o755 : e.mode & 0o755,
                                   size: e.kind == .file ? e.size : 0, linkTarget: target,
                                   localOffset: e.localOffset, compressedSize: e.compressedSize, method: e.method, crc: e.crc)
        entries.append(planned)
        return planned
    }

    /// Absolute paths, `..`, empty or NUL-containing names, names over 1024 bytes: refused.
    /// `.` components are dropped (`./a`). Returns nil if nothing is left after stripping.
    static func normalize(_ raw: String, strip: Int, isDirectory: Bool) throws -> String? {
        if raw.isEmpty || raw.utf8.count > 1024 || raw.utf8.contains(0) || raw.hasPrefix("/") {
            throw SafeArchiveError.rejected(.unsafePath)
        }
        var comps = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if comps.last == "" { comps.removeLast() }   // directory entries end in a slash
        comps = comps.filter { $0 != "." }
        for c in comps where c.isEmpty || c == ".." { throw SafeArchiveError.rejected(.unsafePath) }
        if comps.count <= strip {
            if comps.count == strip && isDirectory { return nil }
            if comps.isEmpty && isDirectory { return nil }
            throw SafeArchiveError.rejected(.unsafePath)
        }
        return comps.dropFirst(strip).joined(separator: "/")
    }

    /// A relative target made of leading `..` components, then plain names, that stays inside the
    /// root. Mixed forms such as `a/../b` are refused: a link met halfway could make the physical
    /// walk differ from the logical one. Names after the `..` run may pass through other links
    /// (`Versions/Current/Libraries` is the normal macOS framework shape): every link resolves
    /// inside the root by this same rule, and plain names can only descend, so none can leave it.
    static func checkLink(_ t: String, from depth: Int, kinds: [String: PlannedEntry.Kind], parent: String) throws {
        if t.isEmpty || t.utf8.count > 1024 || t.utf8.contains(0) || t.hasPrefix("/") {
            throw SafeArchiveError.rejected(.linkEscape)
        }
        var comps = t.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if comps.last == "" { comps.removeLast() }
        var ups = 0
        var names: [String] = []
        for c in comps {
            if c.isEmpty || c == "." { throw SafeArchiveError.rejected(.linkEscape) }
            if c == ".." {
                if !names.isEmpty { throw SafeArchiveError.rejected(.linkEscape) }
                ups += 1
            } else { names.append(c) }
        }
        if ups > depth { throw SafeArchiveError.rejected(.linkEscape) }
    }
}

/// Creates entries below a directory descriptor, one component at a time, never following a link.
final class TreeWriter {
    private let root: Int32
    private var cachePath: String?
    private var cacheFD: Int32 = -1
    private var current: Int32 = -1

    init(root: Int32) { self.root = root }

    func closeAll() {
        if cacheFD >= 0 { Darwin.close(cacheFD); cacheFD = -1 }
        if current >= 0 { Darwin.close(current); current = -1 }
    }

    private func parentFD(_ comps: [String]) throws -> Int32 {
        let key = comps.joined(separator: "/")
        if let c = cachePath, c == key, cacheFD >= 0 { return cacheFD }
        var fd = root
        var opened: [Int32] = []
        defer { for o in opened where o != cacheFD { Darwin.close(o) } }
        for c in comps {
            if mkdirat(fd, c, 0o755) != 0 && errno != EEXIST { throw SafeArchiveError.rejected(.io) }
            let next = openat(fd, c, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw SafeArchiveError.rejected(.io) }
            opened.append(next)
            fd = next
        }
        if cacheFD >= 0 { Darwin.close(cacheFD); cacheFD = -1 }
        if comps.isEmpty { return root }
        let keep = dup(fd)
        guard keep >= 0 else { throw SafeArchiveError.rejected(.io) }
        cacheFD = keep; cachePath = key
        return keep
    }

    private func split(_ path: String) -> ([String], String) {
        var c = path.split(separator: "/").map(String.init)
        let last = c.removeLast()
        return (c, last)
    }

    func makeDirectory(_ path: String) throws {
        var comps = path.split(separator: "/").map(String.init)
        guard let last = comps.popLast() else { return }
        let parent = try parentFD(comps)
        if mkdirat(parent, last, 0o755) != 0 {
            guard errno == EEXIST else { throw SafeArchiveError.rejected(.io) }
            let d = openat(parent, last, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard d >= 0 else { throw SafeArchiveError.rejected(.io) }
            Darwin.close(d)
        }
    }

    func makeSymlink(_ path: String, target: String) throws {
        let (comps, last) = split(path)
        let parent = try parentFD(comps)
        guard symlinkat(target, parent, last) == 0 else { throw SafeArchiveError.rejected(.io) }
    }

    func beginFile(_ path: String) throws {
        let (comps, last) = split(path)
        let parent = try parentFD(comps)
        let fd = openat(parent, last, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SafeArchiveError.rejected(.io) }
        current = fd
    }

    func write(_ buf: UnsafeRawBufferPointer) throws {
        var off = 0
        while off < buf.count {
            let n = Darwin.write(current, buf.baseAddress! + off, buf.count - off)
            if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { throw SafeArchiveError.rejected(.io) }
        }
    }

    func endFile(mode: UInt16) throws {
        guard current >= 0 else { return }
        let fd = current
        current = -1
        defer { Darwin.close(fd) }
        guard fchmod(fd, mode_t(mode)) == 0 else { throw SafeArchiveError.rejected(.io) }
    }
}

// MARK: - tar sinks

final class PlanningTarSink: TarSink {
    let planner: EntryPlanner
    init(planner: EntryPlanner) { self.planner = planner }
    func header(_ h: TarHeader) throws -> Bool { _ = try planner.accept(RawEntry(h)); return false }
    func data(_ b: UnsafeRawBufferPointer) throws {}
    func endEntry() throws {}
}

final class ExtractingTarSink: TarSink {
    let planner: EntryPlanner
    let plan: ArchivePlan
    let writer: TreeWriter
    private(set) var index = 0
    private var mode: UInt16 = 0
    init(planner: EntryPlanner, plan: ArchivePlan, writer: TreeWriter) { self.planner = planner; self.plan = plan; self.writer = writer }

    func header(_ h: TarHeader) throws -> Bool {
        // The same rules run again; the result must equal what stage 1 planned.
        guard let planned = try planner.accept(RawEntry(h)) else { return false }
        guard index < plan.entries.count, plan.entries[index] == planned else { throw SafeArchiveError.rejected(.changed) }
        index += 1
        switch planned.kind {
        case .directory: try writer.makeDirectory(planned.path); return false
        case .symlink: try writer.makeSymlink(planned.path, target: planned.linkTarget!); return false
        case .file: try writer.beginFile(planned.path); mode = planned.mode; return true
        }
    }
    func data(_ b: UnsafeRawBufferPointer) throws { try writer.write(b) }
    func endEntry() throws { try writer.endFile(mode: mode) }
}
