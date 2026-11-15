import Foundation
import Compression
@testable import InstanceMCPCore

/// Hand-written tar, gzip and zip writers. They can emit hostile shapes that no real tool would.
enum ArchiveFixtures {
    // MARK: deflate / gzip

    static func deflate(_ d: Data) -> Data {
        if d.isEmpty { return Data([0x03, 0x00]) }
        var out = [UInt8](repeating: 0, count: d.count + d.count / 8 + 4096)
        let n = d.withUnsafeBytes { src in
            compression_encode_buffer(&out, out.count, src.baseAddress!.assumingMemoryBound(to: UInt8.self), d.count, nil, COMPRESSION_ZLIB)
        }
        precondition(n > 0)
        return Data(out[0..<n])
    }

    static func crc(_ d: Data) -> UInt32 {
        var c = CRC32()
        d.withUnsafeBytes { c.update($0) }
        return c.final
    }

    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

    static func gzip(_ raw: Data) -> Data {
        var out = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
        out.append(deflate(raw))
        out.append(contentsOf: le32(crc(raw)))
        out.append(contentsOf: le32(UInt32(truncatingIfNeeded: raw.count)))
        return out
    }

    // MARK: tar

    struct TarMember {
        var name: String
        var type: Character = "0"
        var data: Data = Data()
        var mode: Int = 0o644
        var linkName: String = ""
        var badChecksum = false
        var sizeOverride: Int?
        init(_ name: String, type: Character = "0", data: Data = Data(), mode: Int = 0o644, link: String = "") {
            self.name = name; self.type = type; self.data = data; self.mode = mode; self.linkName = link
        }
        static func file(_ n: String, _ s: String = "x", mode: Int = 0o644) -> TarMember { .init(n, data: Data(s.utf8), mode: mode) }
        static func dir(_ n: String) -> TarMember { .init(n.hasSuffix("/") ? n : n + "/", type: "5", mode: 0o755) }
        static func symlink(_ n: String, to t: String) -> TarMember { .init(n, type: "2", mode: 0o755, link: t) }
    }

    private static func put(_ block: inout [UInt8], _ s: String, at o: Int, max: Int) {
        for (i, b) in s.utf8.prefix(max).enumerated() { block[o + i] = b }
    }

    private static func octal(_ v: Int, width: Int) -> String {
        let s = String(v, radix: 8)
        return String(repeating: "0", count: max(0, width - 1 - s.count)) + s
    }

    static func tarHeader(_ m: TarMember) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 512)
        put(&b, m.name, at: 0, max: 100)
        put(&b, octal(m.mode, width: 8), at: 100, max: 7)
        put(&b, "0000000", at: 108, max: 7)
        put(&b, "0000000", at: 116, max: 7)
        put(&b, octal(m.sizeOverride ?? m.data.count, width: 12), at: 124, max: 11)
        put(&b, "00000000000", at: 136, max: 11)
        b[156] = m.type.asciiValue!
        put(&b, m.linkName, at: 157, max: 100)
        put(&b, "ustar", at: 257, max: 5)
        put(&b, "00", at: 263, max: 2)
        for i in 148..<156 { b[i] = 0x20 }
        var sum = 0
        for x in b { sum += Int(x) }
        if m.badChecksum { sum += 1 }
        put(&b, octal(sum, width: 7), at: 148, max: 6)
        b[154] = 0; b[155] = 0x20
        return b
    }

    static func pax(_ records: [String: String]) -> TarMember {
        var body = Data()
        for (k, v) in records.sorted(by: { $0.key < $1.key }) {
            let payload = " \(k)=\(v)\n"
            var len = payload.utf8.count + 1
            while String(len).utf8.count + payload.utf8.count != len { len = String(len).utf8.count + payload.utf8.count }
            body.append(Data("\(len)\(payload)".utf8))
        }
        return TarMember("PaxHeader", type: "x", data: body)
    }

    static func tar(_ members: [TarMember], terminate: Bool = true) -> Data {
        var out = Data()
        for m in members {
            out.append(contentsOf: tarHeader(m))
            out.append(m.data)
            let pad = (512 - m.data.count % 512) % 512
            out.append(Data(repeating: 0, count: pad))
        }
        if terminate { out.append(Data(repeating: 0, count: 1024)) }
        return out
    }

    static func tarGz(_ members: [TarMember]) -> Data { gzip(tar(members)) }

    // MARK: zip

    struct ZipEntry {
        var name: String
        var data: Data = Data()
        var method: UInt16 = 0
        var unixMode: UInt32 = 0o100644
        var flags: UInt16 = 0
        var localName: String?
        var centralCompressedSize: UInt32?
        var localOffsetOverride: UInt32?
    var localMethod: UInt16?
    var localCRC: UInt32?
        var hostUnix = true
        static func file(_ n: String, _ s: String = "x", mode: UInt32 = 0o100644, deflated: Bool = false) -> ZipEntry {
            .init(name: n, data: Data(s.utf8), method: deflated ? 8 : 0, unixMode: mode)
        }
        static func dir(_ n: String) -> ZipEntry { .init(name: n.hasSuffix("/") ? n : n + "/", unixMode: 0o040755) }
        static func symlink(_ n: String, to t: String) -> ZipEntry { .init(name: n, data: Data(t.utf8), unixMode: 0o120755) }
    }

    static func zip(_ entries: [ZipEntry], zip64Locator: Bool = false, comment: String = "") -> Data {
        var out = Data()
        var central = Data()
        for e in entries {
            let stored = e.method == 8 ? deflate(e.data) : e.data
            let off = UInt32(out.count)
            let ln = Data((e.localName ?? e.name).utf8)
            out.append(contentsOf: le32(0x0403_4b50) + le16(20) + le16(e.flags) + le16(e.localMethod ?? e.method) + le16(0) + le16(0)
                       + le32(e.localCRC ?? crc(e.data)) + le32(UInt32(stored.count)) + le32(UInt32(e.data.count))
                       + le16(UInt16(ln.count)) + le16(0))
            out.append(ln)
            out.append(stored)
            let n = Data(e.name.utf8)
            central.append(contentsOf: le32(0x0201_4b50) + le16((e.hostUnix ? 3 << 8 : 0) | 20) + le16(20) + le16(e.flags) + le16(e.method)
                           + le16(0) + le16(0) + le32(crc(e.data)) + le32(e.centralCompressedSize ?? UInt32(stored.count))
                           + le32(UInt32(e.data.count)) + le16(UInt16(n.count)) + le16(0) + le16(0) + le16(0) + le16(0)
                           + le32(e.unixMode << 16) + le32(e.localOffsetOverride ?? off))
            central.append(n)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        if zip64Locator {
            out.append(contentsOf: le32(0x0706_4b50) + le32(0) + [UInt8](repeating: 0, count: 8) + le32(1))
        }
        let c = Data(comment.utf8)
        out.append(contentsOf: le32(0x0605_4b50) + le16(0) + le16(0) + le16(UInt16(entries.count)) + le16(UInt16(entries.count))
                   + le32(UInt32(central.count)) + le32(cdOffset) + le16(UInt16(c.count)))
        out.append(c)
        return out
    }
}

/// A fresh directory under the system temp dir, removed in `tearDown`.
final class TempDir {
    let url: URL
    init() {
        url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oab-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func file(_ name: String, _ data: Data) -> URL {
        let u = url.appendingPathComponent(name)
        try! data.write(to: u)
        return u
    }
    func dir(_ name: String) -> URL {
        let u = url.appendingPathComponent(name, isDirectory: true)
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return u
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
}
