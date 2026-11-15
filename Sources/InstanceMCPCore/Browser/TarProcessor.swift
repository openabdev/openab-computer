import Foundation

struct TarHeader {
    var name: String
    var kind: PlannedEntry.Kind
    var mode: UInt16
    var size: Int64
    var linkName: String?
}

protocol TarSink: AnyObject {
    /// A real entry (not a pax or GNU long-name record). Return true to receive its data.
    func header(_ h: TarHeader) throws -> Bool
    func data(_ b: UnsafeRawBufferPointer) throws
    func endEntry() throws
}

enum TarProcessor {
    /// Decompress `file` (one gzip member) and parse it as tar into `sink`. The decompressed length
    /// is capped by the limits, so a bomb stops at the cap.
    static func run(file: ReadFile, limits: ArchiveLimits, sink: TarSink) throws {
        let cap = limits.maxTotalBytes + Int64(limits.maxEntries + 16) * 4096 + 1_048_576
        let parser = TarParser(sink: sink)
        try GzipReader.decompress(file: file, maxOutput: cap) { try parser.push($0) }
        try parser.finish()
    }
}

/// A push parser for ustar, pax (`path`, `linkpath`) and GNU long names. Every other record shape
/// (hardlinks, devices, FIFOs, contiguous files, sparse files) is refused.
final class TarParser {
    private enum State {
        case header
        case body(remaining: Int64, padding: Int, deliver: Bool)
        case meta(kind: UInt8, remaining: Int, padding: Int)
        case padding(Int)
        case ended
    }

    private let sink: TarSink
    private var state = State.header
    private var block = [UInt8]()
    private var metaBytes = [UInt8]()
    private var pendingPath: String?
    private var pendingLink: String?

    init(sink: TarSink) { self.sink = sink; block.reserveCapacity(512) }

    func finish() throws {
        switch state {
        case .ended: return
        case .header where block.isEmpty: throw SafeArchiveError.rejected(.malformed)   // no end marker
        default: throw SafeArchiveError.rejected(.malformed)
        }
    }

    func push(_ buf: UnsafeRawBufferPointer) throws {
        var pos = 0
        let n = buf.count
        while pos < n {
            switch state {
            case .ended:
                for b in buf[pos...] where b != 0 { throw SafeArchiveError.rejected(.malformed) }
                return
            case .header:
                let take = min(512 - block.count, n - pos)
                block.append(contentsOf: buf[pos..<(pos + take)])
                pos += take
                if block.count == 512 { try handleHeader(); block.removeAll(keepingCapacity: true) }
            case .padding(let p):
                let take = min(p, n - pos)
                pos += take
                state = take == p ? .header : .padding(p - take)
            case .body(let remaining, let padding, let deliver):
                let take = Int(min(Int64(n - pos), remaining))
                if take > 0 && deliver { try sink.data(UnsafeRawBufferPointer(rebasing: buf[pos..<(pos + take)])) }
                pos += take
                if Int64(take) == remaining {
                    try sink.endEntry()
                    state = padding > 0 ? .padding(padding) : .header
                } else { state = .body(remaining: remaining - Int64(take), padding: padding, deliver: deliver) }
            case .meta(let kind, let remaining, let padding):
                let take = min(remaining, n - pos)
                metaBytes.append(contentsOf: buf[pos..<(pos + take)])
                pos += take
                if take == remaining {
                    try applyMeta(kind)
                    metaBytes.removeAll(keepingCapacity: true)
                    state = padding > 0 ? .padding(padding) : .header
                } else { state = .meta(kind: kind, remaining: remaining - take, padding: padding) }
            }
        }
    }

    // MARK: header

    private static func octal(_ b: ArraySlice<UInt8>) throws -> Int64 {
        if let f = b.first, f & 0x80 != 0 { throw SafeArchiveError.rejected(.unsupported) }   // base-256 sizes
        var v: Int64 = 0
        var any = false
        for c in b {
            if c == 0 || c == 0x20 { if any { break } else { continue } }
            guard c >= 0x30 && c <= 0x37 else { throw SafeArchiveError.rejected(.malformed) }
            v = v &* 8 &+ Int64(c - 0x30)
            any = true
            if v > (1 << 40) { throw SafeArchiveError.rejected(.tooLarge) }
        }
        return v
    }

    private static func utf8(_ b: [UInt8]) -> String? { String(data: Data(b), encoding: .utf8) }

    private static func string(_ b: ArraySlice<UInt8>) throws -> String {
        let end = b.firstIndex(of: 0) ?? b.endIndex
        guard let s = Self.utf8(Array(b[b.startIndex..<end])) else { throw SafeArchiveError.rejected(.malformed) }
        return s
    }

    private func handleHeader() throws {
        if block.allSatisfy({ $0 == 0 }) { state = .ended; return }
        // Checksum: sum of all bytes with the checksum field read as spaces.
        var sum = 0
        for (i, b) in block.enumerated() { sum += (i >= 148 && i < 156) ? 0x20 : Int(b) }
        guard try Self.octal(block[148..<156]) == Int64(sum) else { throw SafeArchiveError.rejected(.malformed) }
        let type = block[156]
        let size = try Self.octal(block[124..<136])
        let mode = try Self.octal(block[100..<108])
        let padding = Int((512 - size % 512) % 512)
        switch type {
        case UInt8(ascii: "x"), UInt8(ascii: "g"), UInt8(ascii: "L"), UInt8(ascii: "K"):
            guard size <= 65536 else { throw SafeArchiveError.rejected(.tooLarge) }
            if size == 0 { state = .header; return }
            state = .meta(kind: type, remaining: Int(size), padding: padding)
        case UInt8(ascii: "0"), 0, UInt8(ascii: "5"), UInt8(ascii: "2"):
            var name = try Self.string(block[0..<100])
            let magic = Array(block[257..<263])
            if magic == Array("ustar\0".utf8) {
                let prefix = try Self.string(block[345..<500])
                if !prefix.isEmpty { name = prefix + "/" + name }
            }
            var link = try Self.string(block[157..<257])
            if let p = pendingPath { name = p }
            if let l = pendingLink { link = l }
            pendingPath = nil; pendingLink = nil
            let kind: PlannedEntry.Kind = type == UInt8(ascii: "5") ? .directory : (type == UInt8(ascii: "2") ? .symlink : .file)
            if kind == .file && name.hasSuffix("/") { throw SafeArchiveError.rejected(.malformed) }
            if kind == .symlink && size != 0 { throw SafeArchiveError.rejected(.malformed) }
            if kind == .directory && size != 0 { throw SafeArchiveError.rejected(.malformed) }
            let h = TarHeader(name: name, kind: kind, mode: UInt16(truncatingIfNeeded: mode), size: size,
                              linkName: kind == .symlink ? link : nil)
            let deliver = try sink.header(h)
            if kind == .file {
                if size == 0 { try sink.endEntry(); state = .header }
                else { state = .body(remaining: size, padding: padding, deliver: deliver) }
            } else { state = .header }
        case UInt8(ascii: "1"), UInt8(ascii: "3"), UInt8(ascii: "4"), UInt8(ascii: "6"):
            throw SafeArchiveError.rejected(.forbiddenType)
        default:
            throw SafeArchiveError.rejected(.unsupported)
        }
    }

    private func applyMeta(_ kind: UInt8) throws {
        switch kind {
        case UInt8(ascii: "L"), UInt8(ascii: "K"):
            let end = metaBytes.firstIndex(of: 0) ?? metaBytes.endIndex
            if metaBytes[end...].contains(where: { $0 != 0 }) { throw SafeArchiveError.rejected(.malformed) }
            guard let s = Self.utf8(Array(metaBytes[0..<end])) else { throw SafeArchiveError.rejected(.malformed) }
            if kind == UInt8(ascii: "L") { pendingPath = s } else { pendingLink = s }
        default:   // pax local ("x") or global ("g")
            var i = 0
            let b = metaBytes
            while i < b.count {
                guard let sp = b[i...].firstIndex(of: 0x20), let len = Int(String(decoding: b[i..<sp], as: UTF8.self)),
                      len > 0, i + len <= b.count, b[i + len - 1] == 0x0A else { throw SafeArchiveError.rejected(.malformed) }
                let rec = b[(sp + 1)..<(i + len - 1)]
                guard let eq = rec.firstIndex(of: 0x3D) else { throw SafeArchiveError.rejected(.malformed) }
                let key = String(decoding: rec[rec.startIndex..<eq], as: UTF8.self)
                let valBytes = Array(rec[(eq + 1)...])
                if valBytes.contains(0) && (key == "path" || key == "linkpath") { throw SafeArchiveError.rejected(.unsafePath) }
                switch key {
                case "path", "linkpath":
                    guard kind == UInt8(ascii: "x") else { throw SafeArchiveError.rejected(.unsupported) }
                    guard let v = Self.utf8(valBytes) else { throw SafeArchiveError.rejected(.malformed) }
                    if key == "path" { pendingPath = v } else { pendingLink = v }
                case "size":
                    throw SafeArchiveError.rejected(.unsupported)
                default:
                    break
                }
                i += len
            }
        }
    }
}
