import Foundation
import Compression

/// CRC-32 (IEEE), table driven, for gzip trailers and zip entries.
struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }
    private(set) var value: UInt32 = 0xFFFF_FFFF

    mutating func update(_ buf: UnsafeRawBufferPointer) {
        var c = value
        Self.table.withUnsafeBufferPointer { t in
            for b in buf { c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        value = c
    }

    var final: UInt32 { value ^ 0xFFFF_FFFF }
}

/// Streaming raw-deflate decoder over the Compression framework (`COMPRESSION_ZLIB` is raw
/// deflate, with no zlib or gzip wrapper). Memory is bounded: output leaves in 64 KiB pieces.
final class RawInflater {
    private var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
    private var out = [UInt8](repeating: 0, count: 64 * 1024)
    private(set) var finished = false
    /// Input bytes left unconsumed once the deflate stream ended (a gzip trailer, normally).
    private(set) var leftover = 0

    init() throws {
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw SafeArchiveError.rejected(.malformed)
        }
    }

    deinit { compression_stream_destroy(&stream) }

    /// Feed one input piece. Returns the number of input bytes consumed (less than `input.count`
    /// only once the stream has ended). Output goes to `sink`, which may throw to abort.
    @discardableResult
    func feed(_ input: UnsafeRawBufferPointer, sink: (UnsafeRawBufferPointer) throws -> Void) throws -> Int {
        if finished { leftover += input.count; return 0 }
        let total = input.count
        var consumed = 0
        let base = input.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? UnsafePointer<UInt8>(bitPattern: 1)!
        stream.src_ptr = base
        stream.src_size = total
        while true {
            let status: compression_status = out.withUnsafeMutableBufferPointer { ob in
                stream.dst_ptr = ob.baseAddress!
                stream.dst_size = ob.count
                return compression_stream_process(&stream, 0)
            }
            let produced = out.count - stream.dst_size
            if produced > 0 {
                try out.withUnsafeBytes { try sink(UnsafeRawBufferPointer(rebasing: $0[0..<produced])) }
            }
            consumed = total - stream.src_size
            switch status {
            case COMPRESSION_STATUS_END:
                finished = true
                leftover += stream.src_size
                return consumed
            case COMPRESSION_STATUS_OK:
                if stream.src_size == 0 && stream.dst_size > 0 { return consumed }
            default:
                throw SafeArchiveError.rejected(.malformed)
            }
        }
    }
}

/// A file read with `pread`, in bounded pieces. Never maps or slurps a whole archive.
final class ReadFile {
    let fd: Int32
    let size: Int64

    init(path: String) throws {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw SafeArchiveError.rejected(.io) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { Darwin.close(fd); throw SafeArchiveError.rejected(.io) }
        self.fd = fd
        self.size = Int64(st.st_size)
    }

    deinit { Darwin.close(fd) }

    func read(at offset: Int64, count: Int, into buf: inout [UInt8]) throws -> Int {
        if buf.count < count { buf = [UInt8](repeating: 0, count: count) }
        var got = 0
        while got < count {
            let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + got, count - got, off_t(offset) + off_t(got)) }
            if n > 0 { got += n } else if n == 0 { break } else if errno == EINTR { continue } else { throw SafeArchiveError.rejected(.io) }
        }
        return got
    }
}

/// Reads a gzip member (RFC 1952) in pieces and hands the decompressed bytes to `sink`. The
/// decompressed length is capped, so a bomb stops at the cap. Exactly one member, with a CRC and
/// length trailer that must agree.
enum GzipReader {
    static func decompress(file: ReadFile, maxOutput: Int64, sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        var chunk = [UInt8](repeating: 0, count: 128 * 1024)
        let first = try file.read(at: 0, count: chunk.count, into: &chunk)
        let headerEnd = try parseHeader(chunk, count: first)
        let inflater = try RawInflater()
        var crc = CRC32()
        var produced: Int64 = 0
        func counted(_ piece: UnsafeRawBufferPointer) throws {
            produced += Int64(piece.count)
            if produced > maxOutput { throw SafeArchiveError.rejected(.tooLarge) }
            crc.update(piece)
            try sink(piece)
        }
        // The trailer is the last 8 bytes of the file (one member, nothing after it). The deflate
        // stream is everything between the header and the trailer and must end exactly there.
        guard file.size >= Int64(headerEnd) + 8 else { throw SafeArchiveError.rejected(.malformed) }
        let dataEnd = file.size - 8
        var tail = [UInt8](repeating: 0, count: 8)
        guard try file.read(at: dataEnd, count: 8, into: &tail) == 8 else { throw SafeArchiveError.rejected(.malformed) }
        var offset = Int64(headerEnd)
        while offset < dataEnd && !inflater.finished {
            let want = Int(min(Int64(chunk.count), dataEnd - offset))
            let n = try file.read(at: offset, count: want, into: &chunk)
            if n == 0 { throw SafeArchiveError.rejected(.malformed) }
            let piece = Array(chunk[0..<n])
            try piece.withUnsafeBytes { _ = try inflater.feed($0, sink: counted) }
            offset += Int64(n)
        }
        guard inflater.finished, inflater.leftover == 0, offset == dataEnd else { throw SafeArchiveError.rejected(.malformed) }
        let wantCRC = UInt32(tail[0]) | UInt32(tail[1]) << 8 | UInt32(tail[2]) << 16 | UInt32(tail[3]) << 24
        let wantLen = UInt32(tail[4]) | UInt32(tail[5]) << 8 | UInt32(tail[6]) << 16 | UInt32(tail[7]) << 24
        guard crc.final == wantCRC, UInt32(truncatingIfNeeded: produced) == wantLen else { throw SafeArchiveError.rejected(.malformed) }
    }

    private static func parseHeader(_ b: [UInt8], count: Int) throws -> Int {
        guard count >= 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { throw SafeArchiveError.rejected(.malformed) }
        let flg = b[3]
        guard flg & 0xE0 == 0 else { throw SafeArchiveError.rejected(.malformed) }   // reserved bits
        var p = 10
        if flg & 0x04 != 0 {
            guard p + 2 <= count else { throw SafeArchiveError.rejected(.malformed) }
            p += 2 + (Int(b[p]) | Int(b[p + 1]) << 8)
        }
        for bit in [UInt8(0x08), UInt8(0x10)] where flg & bit != 0 {
            while p < count && b[p] != 0 { p += 1 }
            p += 1
        }
        if flg & 0x02 != 0 { p += 2 }
        guard p <= count else { throw SafeArchiveError.rejected(.malformed) }
        return p
    }
}
