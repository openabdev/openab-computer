import Foundation
import XCTest
@testable import InstanceMCPCore

private typealias T = ArchiveFixtures.TarMember
private typealias Z = ArchiveFixtures.ZipEntry

final class MutableBox<V>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: V
    init(_ v: V) { self.v = v }
    var value: V { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}

final class StubVerifier: NodeSignatureVerifying, @unchecked Sendable {
    let result: MutableBox<Bool>
    let asked = MutableBox<[String]>([])
    init(_ r: Bool = true) { result = MutableBox(r) }
    func verify(executable: URL, teamIdentifier: String) -> Bool {
        asked.value += [teamIdentifier]
        return result.value
    }
}

/// A complete fake release: a Node tarball whose `bin/node` is a shell script, a Chromium zip, a
/// loopback server and a manifest that pins them. The script plays two roles. Run as `node
/// npm-cli.js ci ...` it records its call and creates the package; run as `node cli.js ...` it
/// becomes the fake MCP stdio server.
final class FakeInstallFixture {
    enum NpmMode: String { case ok, fail, offline, integrity, hang, detached }
    enum NodeMode: String { case ok, refused, missingTool, deadOnStart }

    let tmp = TempDir()
    let record: URL
    var server: StubHTTPServer!
    var manifest: PlaywrightManifest!
    let packageJSON = "{\"name\":\"fixture\"}\n"
    let lockfileJSON = "{\"lockfileVersion\":3}\n"
    let nodeData: MutableBox<Data>
    let chromiumData: MutableBox<Data>
    let requested = MutableBox<[String]>([])
    private(set) var nodeTar = Data()
    private(set) var crZip = Data()
    private(set) var crExe = ""

    static let names = BrowserToolCatalog.allNames

    init(id: String = "mcpfixture-1", npm: NpmMode = .ok, node: NodeMode = .ok, hostileNodeTar: Data? = nil) throws {
        record = tmp.dir("record")
        let fake = fakeServerPath()
        let toolNames = node == .missingTool ? Array(Self.names.dropLast()).joined(separator: ",") : Self.names.joined(separator: ",")
        let rec = record.path
        let nodeScript = """
        #!/bin/sh
        REC='\(rec)'
        case "$1" in
        *npm-cli.js)
          { echo "cwd=$(pwd)"; for a in "$@"; do echo "arg=$a"; done; env | sort | sed 's/^/env=/'; } > "$REC/npm-$(date +%s%N 2>/dev/null || echo 0)-$$.txt"
          \(Self.npmBody(npm, fake))
          ;;
        *)
          echo "$$" > "$REC/serving.pid"
          \(Self.nodeBody(node, fake, toolNames))
          ;;
        esac
        """
        let goodNodeTar = ArchiveFixtures.tarGz([
            .dir("node-vfix"), .dir("node-vfix/bin"), .dir("node-vfix/lib/node_modules/npm/bin"),
            T("node-vfix/bin/node", data: Data(nodeScript.utf8), mode: 0o755),
            .file("node-vfix/lib/node_modules/npm/bin/npm-cli.js", "// fake npm\n"),
            .symlink("node-vfix/bin/npm", to: "../lib/node_modules/npm/bin/npm-cli.js"),
        ])
        let exe = "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
        let crZip = ArchiveFixtures.zip([
            .dir("chrome-mac-arm64/"), .dir("chrome-mac-arm64/Google Chrome for Testing.app/"),
            .dir("chrome-mac-arm64/Google Chrome for Testing.app/Contents/"),
            .dir("chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/"),
            .file(exe, "#!/bin/sh\nexit 0\n", mode: 0o100755, deflated: true),
        ])
        let nodeTar = hostileNodeTar ?? goodNodeTar
        nodeData = MutableBox(nodeTar)
        chromiumData = MutableBox(crZip)
        let nd = nodeData, cd = chromiumData, req = requested
        server = try StubHTTPServer { r in
            req.value += [r.path]
            if r.path == "/node.tgz" { return HTTPResponse(status: 200, body: nd.value) }
            if r.path == "/chromium.zip" { return HTTPResponse(status: 200, body: cd.value) }
            return .text(404, "no")
        }
        self.nodeTar = nodeTar; self.crZip = crZip; self.crExe = exe
        manifest = try Self.manifest(id: id, port: server.port, node: nodeTar, chromium: crZip, exe: exe,
                                     packageJSON: packageJSON, lockfileJSON: lockfileJSON)
    }

    deinit { server.stop(); tmp.remove() }

    func manifest(id: String) throws -> PlaywrightManifest {
        try Self.manifest(id: id, port: server.port, node: nodeTar, chromium: crZip, exe: crExe,
                          packageJSON: packageJSON, lockfileJSON: lockfileJSON)
    }

    private static func npmBody(_ m: NpmMode, _ fake: String) -> String {
        switch m {
        case .ok: return "mkdir -p node_modules/@playwright/mcp && echo '// cli' > node_modules/@playwright/mcp/cli.js && exit 0"
        case .fail: return "echo 'CANARY-npm-stderr https://example.invalid/?token=CANARY' >&2; exit 1"
        case .offline: return "echo 'npm ERR! code ENOTFOUND CANARY' >&2; exit 1"
        case .integrity: return "echo 'npm ERR! code EINTEGRITY CANARY' >&2; exit 1"
        case .hang: return "echo $$ > \"$REC/npm.pid\"; sleep 300 & echo $! > \"$REC/npm-child.pid\"; wait"
        case .detached:
            return "echo $$ > \"$REC/npm.pid\"; '\(fake)' detached-grandchild hold > \"$REC/gc.out\" & sleep 300"
        }
    }

    private static func nodeBody(_ m: NodeMode, _ fake: String, _ names: String) -> String {
        switch m {
        case .ok, .missingTool: return "exec '\(fake)' playwright-fake '\(names)'"
        case .refused: return "echo 'Operation not permitted CANARY' >&2; exit 1"
        case .deadOnStart: return "exit 3"
        }
    }

    static func manifest(id: String, port: UInt16, node: Data, chromium: Data, exe: String,
                         packageJSON: String, lockfileJSON: String, previous: PlaywrightManifest? = nil) throws -> PlaywrightManifest {
        func limits(_ data: Data, _ f: ArchiveFormat, strip: Int) throws -> (Int64, Int, Int64) {
            let tmp = TempDir(); defer { tmp.remove() }
            let u = tmp.file("a", data)
            // A hostile fixture cannot be measured; give it ordinary limits so the installer is what refuses it.
            guard let p = try? SafeArchiveExtractor.validate(file: u, format: f, limits: ArchiveLimits(maxEntries: 10_000, maxTotalBytes: 1 << 30, maxEntryBytes: 1 << 30, stripComponents: strip)) else {
                return (1 << 20, 100, 1 << 20)
            }
            return (p.totalBytes, p.headerCount, p.entries.map(\.size).max() ?? 1)
        }
        let (nb, nc, nm) = try limits(node, .tarGz, strip: 1)
        let (cb, cc, cm) = try limits(chromium, .zip, strip: 0)
        func art(_ path: String, _ data: Data, _ fmt: String, _ b: Int64, _ c: Int, _ m: Int64, strip: Int, exe: String?) -> [String: Any] {
            var a: [String: Any] = ["url": "http://127.0.0.1:\(port)/\(path)", "format": fmt, "size": data.count,
                                    "sha256": PlaywrightManifest.sha256Hex(data), "stripComponents": strip,
                                    "expandedBytes": max(b, 1), "entryCount": c, "maxEntryBytes": max(m, 1)]
            if let exe { a["executable"] = exe }
            return a
        }
        let both: ([String: Any]) -> [String: Any] = { ["arm64": $0, "x86_64": $0] }
        let obj: [String: Any] = [
            "schema": 1, "id": id,
            "mcp": ["package": "@playwright/mcp", "version": "0.0.1", "playwrightCoreVersion": "0.0.1",
                    "packageJsonSHA256": PlaywrightManifest.sha256Hex(Data(packageJSON.utf8)),
                    "lockfileSHA256": PlaywrightManifest.sha256Hex(Data(lockfileJSON.utf8)),
                    "npmDownloadBytes": 1000, "npmInstalledBytes": 2000, "npmPackageCount": 1],
            "node": ["version": "1.0.0", "teamIdentifier": "ABCDE12345",
                     "artifacts": both(art("node.tgz", node, "tar.gz", nb, nc, nm, strip: 1, exe: nil))],
            "chromium": ["revision": "1", "browserVersion": "1.0.0.0", "releasedAt": "2026-09-01", "host": "127.0.0.1",
                         "artifacts": both(art("chromium.zip", chromium, "zip", cb, cc, cm, strip: 0, exe: exe))],
            "hosts": ["nodejs.org", "registry.npmjs.org", "127.0.0.1"],
            "staleAfterDays": 180, "freeDiskFactor": 3,
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try PlaywrightManifest.decode(String(decoding: data, as: UTF8.self))
    }

    func installer(root: URL, manifest m: PlaywrightManifest? = nil, verifier: StubVerifier = StubVerifier(),
                   stop: @escaping @Sendable () async -> Void = {}, serving: @escaping @Sendable () async -> Bool = { true },
                   removed: @escaping @Sendable () -> Void = {}, logs: MutableBox<[String]> = MutableBox([]),
                   freeDisk: @escaping @Sendable (URL) -> Int64 = { _ in Int64.max / 4 },
                   lockTries: Int = 50, npmTimeout: TimeInterval = 30, healthTimeout: TimeInterval = 20,
                   now: @escaping @Sendable () -> Date = { Date() },
                   downloader: (any ArtifactDownloader)? = nil, lockfile: String? = nil) -> PlaywrightInstaller {
        let man = m ?? manifest!
        return PlaywrightInstaller(
            root: root, manifest: man, archProvider: FixedArch(.arm64),
            downloader: downloader ?? URLSessionArtifactDownloader(policy: DownloadPolicy(allowedHosts: Set(man.hosts), allowLoopbackHTTP: true), requestTimeout: 10),
            verifier: verifier, packageJSON: packageJSON, lockfileJSON: lockfile ?? lockfileJSON, allowLoopbackHTTP: true,
            freeDisk: freeDisk, now: now, lockTries: lockTries, lockInterval: 20_000_000, npmTimeout: npmTimeout,
            healthTimeout: healthTimeout, stopManaged: stop, verifyServing: serving, onRemoved: removed,
            log: { l in logs.value += [l] })
    }
}

struct FixedArch: ArchProvider {
    let arch: Arch
    init(_ a: Arch) { arch = a }
}

func pidIsAlive(_ p: pid_t) -> Bool {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
    return info.pbi_status != 5
}
