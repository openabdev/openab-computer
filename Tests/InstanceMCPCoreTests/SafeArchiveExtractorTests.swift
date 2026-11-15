import Foundation
import XCTest
@testable import InstanceMCPCore

private typealias T = ArchiveFixtures.TarMember
private typealias Z = ArchiveFixtures.ZipEntry

final class SafeArchiveExtractorTests: XCTestCase {
    private var tmp: TempDir!
    private var outside: URL!
    private var target: URL!

    override func setUp() {
        tmp = TempDir()
        outside = tmp.file("outside-sentinel", Data("keep".utf8))
        target = tmp.dir("target")
    }
    override func tearDown() { tmp.remove() }

    private let limits = ArchiveLimits(maxEntries: 100, maxTotalBytes: 1 << 20, maxEntryBytes: 1 << 20, stripComponents: 0)

    /// Stage 1 must refuse; nothing is written anywhere.
    private func refuse(_ data: Data, _ format: ArchiveFormat, _ why: SafeArchiveError.Reason? = nil, limits l: ArchiveLimits? = nil,
                        file: StaticString = #filePath, line: UInt = #line) {
        let f = tmp.file("a-\(UUID().uuidString)", data)
        XCTAssertThrowsError(try SafeArchiveExtractor.validate(file: f, format: format, limits: l ?? limits), file: file, line: line) { e in
            if let why { XCTAssertEqual((e as? SafeArchiveError)?.reason, why, file: file, line: line) }
            XCTAssertTrue(e is SafeArchiveError, file: file, line: line)
        }
        XCTAssertEqual(try! String(contentsOf: outside), "keep", file: file, line: line)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: target.path))?.count, 0, file: file, line: line)
    }

    private func refuseTar(_ members: [T], _ why: SafeArchiveError.Reason? = nil, limits l: ArchiveLimits? = nil,
                           file: StaticString = #filePath, line: UInt = #line) {
        refuse(ArchiveFixtures.tarGz(members), .tarGz, why, limits: l, file: file, line: line)
    }

    private func refuseZip(_ entries: [Z], _ why: SafeArchiveError.Reason? = nil, zip64: Bool = false,
                           file: StaticString = #filePath, line: UInt = #line) {
        refuse(ArchiveFixtures.zip(entries, zip64Locator: zip64), .zip, why, file: file, line: line)
    }

    // MARK: hostile tar

    func testPathRules() {
        refuseTar([.file("/etc/passwd")], .unsafePath)
        refuseTar([.file("../x")], .unsafePath)
        refuseTar([.file("a/../../x")], .unsafePath)
        refuseTar([.file("a/b/../c")], .unsafePath)
        refuseTar([.file("")], .unsafePath)
        refuseTar([ArchiveFixtures.pax(["path": "a\0b"]), .file("placeholder")], .unsafePath)
        refuseTar([ArchiveFixtures.pax(["path": String(repeating: "a", count: 1100)]), .file("placeholder")], .unsafePath)
        refuseTar([.file("a//b")], .unsafePath)
    }

    func testLinkRules() {
        refuseTar([.symlink("l", to: "/tmp")], .linkEscape)
        refuseTar([.symlink("l", to: "../outside")], .linkEscape)
        refuseTar([.dir("d"), .symlink("d/l", to: "../../x")], .linkEscape)
        refuseTar([.dir("a"), .symlink("a/l", to: "x/../y")], .linkEscape)   // mixed form
        refuseTar([.symlink("l", to: "")], .linkEscape)
        refuseTar([.dir("sub"), .symlink("link", to: "sub"), .file("link/x")], .unsafePath)   // through an earlier symlink
    }

    func testEntryTypes() {
        refuseTar([T("h", type: "1", link: "x")], .forbiddenType)
        refuseTar([T("c", type: "3")], .forbiddenType)
        refuseTar([T("b", type: "4")], .forbiddenType)
        refuseTar([T("f", type: "6")], .forbiddenType)
        refuseTar([T("s", type: "7")], .unsupported)
        refuseTar([.file("x", mode: 0o4755)], .setuid)
        refuseTar([.file("x", mode: 0o2755)], .setuid)
    }

    func testDuplicatesAndCollisions() {
        refuseTar([.file("a"), .dir("a")], .duplicate)
        refuseTar([.file("a"), .file("a")], .duplicate)
        refuseTar([.file("Readme"), .file("README")], .caseCollision)
        refuseTar([.dir("a"), .file("a/b"), .file("A/c")], .caseCollision)
        // An unlisted parent is still a directory: a later file or link of that name is refused in stage 1.
        refuseTar([.file("a/x"), .file("a")], .duplicate)
        refuseTar([.file("a/b/x"), .symlink("a/b", to: "x")], .duplicate)
        refuseTar([.file("a/x"), .symlink("a", to: "x")], .duplicate)
    }

    func testLimits() {
        let small = ArchiveLimits(maxEntries: 3, maxTotalBytes: 100, maxEntryBytes: 50, stripComponents: 0)
        refuseTar([.file("a"), .file("b"), .file("c"), .file("d")], .tooManyEntries, limits: small)
        refuseTar([.file("a", String(repeating: "x", count: 51))], .tooLarge, limits: small)
        refuseTar([.file("a", String(repeating: "x", count: 50)), .file("b", String(repeating: "x", count: 50)),
                   .file("c", "xx")], .tooLarge, limits: small)
    }

    func testGzipBombStopsAtTheCap() {
        let zeros = Data(count: 64 * 1024 * 1024)
        let bomb = ArchiveFixtures.gzip(zeros)
        XCTAssertLessThan(bomb.count, 1_000_000)
        refuse(bomb, .tarGz, .tooLarge, limits: ArchiveLimits(maxEntries: 10, maxTotalBytes: 1024, maxEntryBytes: 1024))
    }

    func testMalformedTar() {
        refuseTar([T("a", data: Data("x".utf8)).with { $0.badChecksum = true }], .malformed)
        let ok = ArchiveFixtures.tarGz([.file("a")])
        refuse(ok.prefix(ok.count - 12), .tarGz, .malformed)                   // truncated gzip
        var corrupt = ok; corrupt[corrupt.count - 6] ^= 0xFF
        refuse(corrupt, .tarGz, .malformed)                                    // bad crc
        refuse(ArchiveFixtures.gzip(ArchiveFixtures.tar([.file("a")], terminate: false)), .tarGz, .malformed)   // no end marker
        refuse(Data("not gzip at all".utf8), .tarGz, .malformed)
        refuse(ArchiveFixtures.gzip(ArchiveFixtures.tar([.file("a")]) + Data([1, 2, 3])), .tarGz, .malformed)   // data after the end
        refuse(ArchiveFixtures.tarGz([.file("a")]) + ArchiveFixtures.tarGz([.file("b")]), .tarGz, .malformed)   // two members
    }

    // MARK: hostile zip

    func testZipRules() {
        refuseZip([Z.file("../x")], .unsafePath)
        refuseZip([Z.file("/abs")], .unsafePath)
        refuseZip([Z.symlink("l", to: "../../x")], .linkEscape)
        refuseZip([Z.symlink("l", to: "/etc")], .linkEscape)
        var enc = Z.file("e"); enc.flags = 1
        refuseZip([enc], .unsupported)
        refuseZip([Z.file("a")], .unsupported, zip64: true)
        var wrong = Z.file("a"); wrong.localName = "b"
        refuseZip([wrong], .malformed)
        var lie = Z.file("a"); lie.centralCompressedSize = 999_999
        refuseZip([lie], .malformed)
        var method = Z.file("a"); method.method = 12
        refuseZip([method], .unsupported)
        refuseZip([Z(name: "dev", unixMode: 0o020644)], .forbiddenType)
        refuseZip([Z.file("x", mode: 0o104755)], .setuid)
        var lm = Z.file("a"); lm.localMethod = 8
        refuseZip([lm], .malformed)
        var lc = Z.file("a"); lc.localCRC = 1
        refuseZip([lc], .malformed)
        var two = Z.file("b"); two.localOffsetOverride = 0     // points at the first entry's header
        refuseZip([Z.file("a"), two], .malformed)
        refuseZip([Z.file("a"), Z.file("a")], .duplicate)
    }

    // MARK: benign

    func testNodeShapedTarExtractsWithModesAndLinks() throws {
        let members: [T] = [
            .dir("node-v1"), .dir("node-v1/bin"), .dir("node-v1/lib/node_modules/npm/bin"),
            .file("node-v1/bin/node", "binary", mode: 0o755),
            .file("node-v1/lib/node_modules/npm/bin/npm-cli.js", "js", mode: 0o644),
            .symlink("node-v1/bin/npm", to: "../lib/node_modules/npm/bin/npm-cli.js"),
            .file("node-v1/README", "r", mode: 0o666),
        ]
        let f = tmp.file("node.tgz", ArchiveFixtures.tarGz(members))
        let l = ArchiveLimits(maxEntries: 20, maxTotalBytes: 1 << 20, maxEntryBytes: 1 << 20, stripComponents: 1)
        let plan = try SafeArchiveExtractor.validate(file: f, format: .tarGz, limits: l)
        try SafeArchiveExtractor.extract(plan, from: f, into: target)
        let fm = FileManager.default
        func mode(_ p: String) -> Int { (try! fm.attributesOfItem(atPath: target.appendingPathComponent(p).path)[.posixPermissions] as! NSNumber).intValue }
        XCTAssertEqual(mode("bin/node"), 0o755)
        XCTAssertEqual(mode("README"), 0o644)   // 0o666 & 0o755
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: target.appendingPathComponent("bin/npm").path),
                       "../lib/node_modules/npm/bin/npm-cli.js")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("bin/npm")), "js")   // the link resolves
    }

    func testPaxAndGnuLongNamesAreHonoured() throws {
        let long = String(repeating: "d", count: 150) + "/f"
        let f = tmp.file("p.tgz", ArchiveFixtures.tarGz([ArchiveFixtures.pax(["path": long, "mtime": "1.5"]), .file("short")]))
        let plan = try SafeArchiveExtractor.validate(file: f, format: .tarGz, limits: limits)
        XCTAssertEqual(plan.entries.first?.path, long)
        try SafeArchiveExtractor.extract(plan, from: f, into: target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(long).path))
    }

    func testChromiumShapedZipExtracts() throws {
        let entries: [Z] = [
            .dir("app/"), .dir("app/Contents/"), .dir("app/Contents/Frameworks/F.framework/Versions/A/"),
            .file("app/Contents/MacOS/Chromium", "bin", mode: 0o100755, deflated: true),
            .file("app/Contents/Frameworks/F.framework/Versions/A/F", String(repeating: "z", count: 5000), deflated: true),
            .symlink("app/Contents/Frameworks/F.framework/Versions/Current", to: "A"),
            .symlink("app/Contents/Frameworks/F.framework/F", to: "Versions/Current/F"),
            .file("app/empty", ""),
        ]
        let f = tmp.file("c.zip", ArchiveFixtures.zip(entries))
        let plan = try SafeArchiveExtractor.validate(file: f, format: .zip, limits: limits)
        try SafeArchiveExtractor.extract(plan, from: f, into: target)
        let exe = target.appendingPathComponent("app/Contents/MacOS/Chromium").path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: exe))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("app/Contents/Frameworks/F.framework/F")).count, 5000)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("app/empty")), "")
    }

    // MARK: stage 2 fails closed

    func testExtractionDoesNotFollowAPlantedSymlink() throws {
        let f = tmp.file("a.tgz", ArchiveFixtures.tarGz([.file("x", "attack")]))
        let plan = try SafeArchiveExtractor.validate(file: f, format: .tarGz, limits: limits)
        try FileManager.default.createSymbolicLink(at: target.appendingPathComponent("x"), withDestinationURL: outside)
        XCTAssertThrowsError(try SafeArchiveExtractor.extract(plan, from: f, into: target))
        XCTAssertEqual(try String(contentsOf: outside), "keep")
    }

    func testPlantedDirectorySymlinkIsNotTraversed() throws {
        let f = tmp.file("a.tgz", ArchiveFixtures.tarGz([.dir("d"), .file("d/x", "attack")]))
        let plan = try SafeArchiveExtractor.validate(file: f, format: .tarGz, limits: limits)
        let other = tmp.dir("elsewhere")
        try FileManager.default.createSymbolicLink(at: target.appendingPathComponent("d"), withDestinationURL: other)
        XCTAssertThrowsError(try SafeArchiveExtractor.extract(plan, from: f, into: target))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: other.path))?.count, 0)
    }

    func testTargetThatIsASymlinkIsRefused() throws {
        let f = tmp.file("a.tgz", ArchiveFixtures.tarGz([.file("x")]))
        let plan = try SafeArchiveExtractor.validate(file: f, format: .tarGz, limits: limits)
        let link = tmp.url.appendingPathComponent("link-to-target")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try SafeArchiveExtractor.extract(plan, from: f, into: link))
    }

    func testArchiveChangedBetweenStagesIsRefused() throws {
        let f = tmp.file("a.tgz", ArchiveFixtures.tarGz([.file("good")]))
        let plan = try SafeArchiveExtractor.validate(file: f, format: .tarGz, limits: limits)
        try ArchiveFixtures.tarGz([.file("good"), .file("../evil")]).write(to: f)
        XCTAssertThrowsError(try SafeArchiveExtractor.extract(plan, from: f, into: target))
        let g = tmp.file("b.zip", ArchiveFixtures.zip([.file("good")]))
        let zplan = try SafeArchiveExtractor.validate(file: g, format: .zip, limits: limits)
        try ArchiveFixtures.zip([.file("good2")]).write(to: g)
        XCTAssertThrowsError(try SafeArchiveExtractor.extract(zplan, from: g, into: tmp.dir("t2")))
    }

    func testZipContentThatDisagreesWithTheCentralDirectoryIsRefused() throws {
        // Declared 5 bytes, stored data differs from the CRC: caught at stage 2.
        var raw = ArchiveFixtures.zip([.file("a", "hello")])
        let i = raw.range(of: Data("hello".utf8))!.lowerBound
        raw[i] = UInt8(ascii: "j")
        let f = tmp.file("bad.zip", raw)
        let plan = try SafeArchiveExtractor.validate(file: f, format: .zip, limits: limits)
        XCTAssertThrowsError(try SafeArchiveExtractor.extract(plan, from: f, into: target))
    }
}

private extension ArchiveFixtures.TarMember {
    func with(_ f: (inout ArchiveFixtures.TarMember) -> Void) -> ArchiveFixtures.TarMember { var c = self; f(&c); return c }
}
