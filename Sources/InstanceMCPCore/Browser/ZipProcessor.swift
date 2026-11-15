import Foundation
import Darwin

/// Reads a zip through its central directory. Refused: encryption, zip64, multi-disk archives,
/// methods other than stored and deflate, local headers that disagree with the central directory,
/// and entries whose data ranges overlap.
enum ZipProcessor {
    private struct Central {
        var name: String
        var flags: UInt16
        var method: UInt16
        var crc: UInt32
        var csize: Int64
        var usize: Int64
        var localOffset: Int64
        var hostUnix: Bool
        var attr: UInt32
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    static func plan(file: ReadFile, planner: EntryPlanner) throws {
        let entries = try readCentral(file: file, maxEntries: planner.limits.maxEntries)
        var ranges: [(Int64, Int64)] = []
        var scratch = [UInt8](repeating: 0, count: 4096)
        for c in entries {
            let (dataStart, _) = try localData(file: file, central: c, scratch: &scratch)
            ranges.append((c.localOffset, dataStart + c.csize))
            let unixMode = c.hostUnix ? (c.attr >> 16) & 0xFFFF : 0
            let fmt = unixMode & 0o170000
            var kind: PlannedEntry.Kind
            switch fmt {
            case 0, 0o100000: kind = c.name.hasSuffix("/") ? .directory : .file
            case 0o040000: kind = .directory
            case 0o120000: kind = .symlink
            default: throw SafeArchiveError.rejected(.forbiddenType)
            }
            if c.name.hasSuffix("/") && kind != .directory { throw SafeArchiveError.rejected(.malformed) }
            var mode = UInt16(truncatingIfNeeded: unixMode & 0o7777)
            if fmt == 0 { mode = kind == .directory ? 0o755 : 0o644 }
            var target: String?
            if kind == .symlink {
                guard c.usize > 0, c.usize <= 1024 else { throw SafeArchiveError.rejected(.linkEscape) }
                target = try readSmall(file: file, central: c, dataStart: dataStart)
            }
            if kind == .directory && c.usize != 0 { throw SafeArchiveError.rejected(.malformed) }
            _ = try planner.accept(RawEntry(name: c.name, kind: kind, mode: mode, size: c.usize, linkTarget: target,
                                            localOffset: c.localOffset, compressedSize: c.csize, method: c.method, crc: c.crc))
        }
        ranges.sort { $0.0 < $1.0 }
        for i in 1..<max(ranges.count, 1) where ranges[i].0 < ranges[i - 1].1 { throw SafeArchiveError.rejected(.malformed) }
    }

    private static func readCentral(file: ReadFile, maxEntries: Int) throws -> [Central] {
        let size = file.size
        guard size >= 22 else { throw SafeArchiveError.rejected(.malformed) }
        let tailLen = Int(min(size, 22 + 65535))
        var tail = [UInt8](repeating: 0, count: tailLen)
        guard try file.read(at: size - Int64(tailLen), count: tailLen, into: &tail) == tailLen else { throw SafeArchiveError.rejected(.io) }
        var eocd = -1
        var i = tailLen - 22
        while i >= 0 {
            if tail[i] == 0x50 && tail[i + 1] == 0x4b && tail[i + 2] == 5 && tail[i + 3] == 6 {
                let commentLen = Int(u16(tail, i + 20))
                if i + 22 + commentLen == tailLen { eocd = i; break }
            }
            i -= 1
        }
        guard eocd >= 0 else { throw SafeArchiveError.rejected(.malformed) }
        // A zip64 locator sits just before the end record.
        if eocd >= 20, tail[eocd - 20] == 0x50, tail[eocd - 19] == 0x4b, tail[eocd - 18] == 6, tail[eocd - 17] == 7 {
            throw SafeArchiveError.rejected(.unsupported)
        }
        let disk = u16(tail, eocd + 4), cdDisk = u16(tail, eocd + 6)
        let onDisk = Int(u16(tail, eocd + 8)), total = Int(u16(tail, eocd + 10))
        let cdSize = Int64(u32(tail, eocd + 12)), cdOffset = Int64(u32(tail, eocd + 16))
        if disk != 0 || cdDisk != 0 || onDisk != total { throw SafeArchiveError.rejected(.unsupported) }
        if total == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF { throw SafeArchiveError.rejected(.unsupported) }
        if total > maxEntries { throw SafeArchiveError.rejected(.tooManyEntries) }
        guard cdOffset + cdSize <= size - Int64(tailLen) + Int64(eocd), cdSize < 64 * 1024 * 1024 else { throw SafeArchiveError.rejected(.malformed) }
        var cd = [UInt8](repeating: 0, count: Int(cdSize))
        guard try file.read(at: cdOffset, count: Int(cdSize), into: &cd) == Int(cdSize) else { throw SafeArchiveError.rejected(.io) }
        var out: [Central] = []
        var p = 0
        for _ in 0..<total {
            guard p + 46 <= cd.count, u32(cd, p) == 0x0201_4b50 else { throw SafeArchiveError.rejected(.malformed) }
            let made = u16(cd, p + 4), flags = u16(cd, p + 8), method = u16(cd, p + 10)
            let crc = u32(cd, p + 16), csize = u32(cd, p + 20), usize = u32(cd, p + 24)
            let nlen = Int(u16(cd, p + 28)), elen = Int(u16(cd, p + 30)), clen = Int(u16(cd, p + 32))
            let diskStart = u16(cd, p + 34), attr = u32(cd, p + 38), lho = u32(cd, p + 42)
            guard p + 46 + nlen + elen + clen <= cd.count else { throw SafeArchiveError.rejected(.malformed) }
            if flags & 0x1 != 0 || flags & 0x40 != 0 || flags & 0x2000 != 0 { throw SafeArchiveError.rejected(.unsupported) }
            if method != 0 && method != 8 { throw SafeArchiveError.rejected(.unsupported) }
            if csize == 0xFFFF_FFFF || usize == 0xFFFF_FFFF || lho == 0xFFFF_FFFF || diskStart != 0 { throw SafeArchiveError.rejected(.unsupported) }
            guard let name = String(data: Data(cd[(p + 46)..<(p + 46 + nlen)]), encoding: .utf8) else { throw SafeArchiveError.rejected(.malformed) }
            out.append(Central(name: name, flags: flags, method: method, crc: crc, csize: Int64(csize), usize: Int64(usize),
                               localOffset: Int64(lho), hostUnix: (made >> 8) == 3, attr: attr))
            p += 46 + nlen + elen + clen
        }
        guard p == cd.count else { throw SafeArchiveError.rejected(.malformed) }
        return out
    }

    /// Validates the local header against the central entry; returns where the data starts.
    private static func localData(file: ReadFile, central c: Central, scratch: inout [UInt8]) throws -> (Int64, Int) {
        let nameBytes = Array(c.name.utf8)
        guard c.localOffset >= 0, c.localOffset + 30 <= file.size,
              try file.read(at: c.localOffset, count: 30, into: &scratch) == 30, u32(scratch, 0) == 0x0403_4b50 else {
            throw SafeArchiveError.rejected(.malformed)
        }
        let nlen = Int(u16(scratch, 26)), elen = Int(u16(scratch, 28))
        guard nlen == nameBytes.count else { throw SafeArchiveError.rejected(.malformed) }
        var nb = [UInt8](repeating: 0, count: nlen)
        guard try file.read(at: c.localOffset + 30, count: nlen, into: &nb) == nlen, nb == nameBytes else {
            throw SafeArchiveError.rejected(.malformed)
        }
        let start = c.localOffset + 30 + Int64(nlen) + Int64(elen)
        guard start + c.csize <= file.size else { throw SafeArchiveError.rejected(.malformed) }
        if c.method == 0 && c.csize != c.usize { throw SafeArchiveError.rejected(.malformed) }
        return (start, nlen)
    }

    /// A small entry's content (a symlink target), decoded, bounded to 1024 bytes.
    private static func readSmall(file: ReadFile, central c: Central, dataStart: Int64) throws -> String {
        var raw = [UInt8](repeating: 0, count: Int(c.csize))
        guard try file.read(at: dataStart, count: Int(c.csize), into: &raw) == Int(c.csize) else { throw SafeArchiveError.rejected(.io) }
        var out = [UInt8]()
        if c.method == 0 { out = raw } else {
            let inflater = try RawInflater()
            _ = try raw.withUnsafeBytes { try inflater.feed($0) { piece in
                out += piece
                if out.count > 1024 { throw SafeArchiveError.rejected(.tooLarge) }
            } }
            guard inflater.finished, inflater.leftover == 0 else { throw SafeArchiveError.rejected(.malformed) }
        }
        guard Int64(out.count) == c.usize, let s = String(data: Data(out), encoding: .utf8) else { throw SafeArchiveError.rejected(.malformed) }
        return s
    }

    static func extract(plan: ArchivePlan, file: ReadFile, writer: TreeWriter) throws {
        // Re-read the central directory and require the same entries in the same order.
        let limits = ArchiveLimits(maxEntries: plan.headerCount, maxTotalBytes: plan.totalBytes,
                                   maxEntryBytes: plan.entries.map(\.size).max() ?? 0, stripComponents: plan.stripComponents)
        let again = EntryPlanner(limits: limits)
        try ZipProcessor.plan(file: file, planner: again)
        guard again.entries == plan.entries else { throw SafeArchiveError.rejected(.changed) }
        var scratch = [UInt8](repeating: 0, count: 4096)
        var buf = [UInt8](repeating: 0, count: 128 * 1024)
        for e in plan.entries {
            switch e.kind {
            case .directory: try writer.makeDirectory(e.path)
            case .symlink: try writer.makeSymlink(e.path, target: e.linkTarget!)
            case .file:
                let c = Central(name: "", flags: 0, method: e.method, crc: e.crc, csize: e.compressedSize, usize: e.size,
                                localOffset: e.localOffset, hostUnix: true, attr: 0)
                // The local header's name was checked against the central name when planning; the
                // data start is recomputed from the local header's own lengths.
                guard try file.read(at: c.localOffset, count: 30, into: &scratch) == 30, u32(scratch, 0) == 0x0403_4b50 else {
                    throw SafeArchiveError.rejected(.changed)
                }
                let start = c.localOffset + 30 + Int64(u16(scratch, 26)) + Int64(u16(scratch, 28))
                try writer.beginFile(e.path)
                var crc = CRC32()
                var written: Int64 = 0
                let sink: (UnsafeRawBufferPointer) throws -> Void = { piece in
                    written += Int64(piece.count)
                    if written > e.size { throw SafeArchiveError.rejected(.tooLarge) }
                    crc.update(piece)
                    try writer.write(piece)
                }
                let inflater = e.method == 8 ? try RawInflater() : nil
                var off: Int64 = 0
                while off < e.compressedSize {
                    let n = try file.read(at: start + off, count: Int(min(Int64(buf.count), e.compressedSize - off)), into: &buf)
                    if n == 0 { throw SafeArchiveError.rejected(.malformed) }
                    try buf.withUnsafeBytes { raw in
                        let piece = UnsafeRawBufferPointer(rebasing: raw[0..<n])
                        if let inflater { _ = try inflater.feed(piece, sink: sink) } else { try sink(piece) }
                    }
                    off += Int64(n)
                }
                if let inflater, !inflater.finished || inflater.leftover != 0 { throw SafeArchiveError.rejected(.malformed) }
                guard written == e.size, crc.final == e.crc else { throw SafeArchiveError.rejected(.malformed) }
                try writer.endFile(mode: e.mode)
            }
        }
    }
}
