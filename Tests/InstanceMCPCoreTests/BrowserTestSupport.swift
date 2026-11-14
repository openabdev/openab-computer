import Foundation
import Network
import XCTest
@testable import InstanceMCPCore

/// A backend with canned behavior, for router and wiring tests.
final class FakeBrowserBackend: BrowserBackend, @unchecked Sendable {
    let id: BrowserBackendID
    private let lock = NSLock()
    private var _status: BrowserBackendStatus
    private var _names: [String]
    private var _calls: [String] = []
    var failure: BrowserBackendError?
    private var _statusCalls = 0
    var statusCalls: Int { lock.withLock { _statusCalls } }

    init(_ id: BrowserBackendID, status: BrowserBackendStatus = .ready, names: [String] = BrowserToolCatalog.allNames) {
        self.id = id; _status = status; _names = names
    }
    var status_: BrowserBackendStatus {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    var calls: [String] { lock.withLock { _calls } }

    func status() async -> BrowserBackendStatus { lock.withLock { _statusCalls += 1 }; return status_ }
    func tools() async -> [JSONValue] {
        lock.withLock { _names }.map { ["name": .string($0), "description": "fake", "inputSchema": ["type": "object"]] }
    }
    func call(_ name: String, arguments: JSONValue) async throws -> JSONValue {
        lock.withLock { _calls.append(name) }
        if let failure { throw failure }
        return ["content": [["type": "text", "text": .string("\(id.rawValue) did \(name)")]]]
    }
}

final class MemoryPreferenceStore: BrowserPreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: BrowserPreference
    init(_ v: BrowserPreference = .auto) { value = v }
    func load() -> BrowserPreference { lock.withLock { value } }
    func save(_ p: BrowserPreference) { lock.withLock { value = p } }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now = Date(timeIntervalSince1970: 1_000_000)
    func date() -> Date { lock.withLock { now } }
    func advance(_ s: TimeInterval) { lock.withLock { now = now.addingTimeInterval(s) } }
}

final class FakePortOwnerProbe: PortOwnerProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var _result: PortOwner?
    private var _asked: [BrowserUpstreamURL.Endpoint] = []
    init(result: PortOwner?) { _result = result }
    var result: PortOwner? {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }
    var asked: [BrowserUpstreamURL.Endpoint] { lock.withLock { _asked } }
    func owner(of endpoint: BrowserUpstreamURL.Endpoint) -> PortOwner? {
        lock.withLock { _asked.append(endpoint); return _result }
    }
}

/// A BSD loopback listener on a chosen family and port, held open by the test process.
final class BSDListener {
    let fd: Int32
    let port: UInt16
    init?(v6: Bool, port: UInt16) {
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var ok = false
        if v6 {
            var a = sockaddr_in6(); a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = port.bigEndian; a.sin6_addr = in6addr_loopback
            ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } } == 0
        } else {
            var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian; a.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
            ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
        }
        guard ok, listen(fd, 4) == 0 else { Darwin.close(fd); return nil }
        self.fd = fd; self.port = port
    }
    deinit { Darwin.close(fd) }

    /// A free port on both families (v4 listener returned, v6 left to the caller), or nil.
    static func freePort() -> UInt16? {
        for _ in 0..<50 {
            let p = UInt16.random(in: 40000...60000)
            if let a = BSDListener(v6: false, port: p), let b = BSDListener(v6: true, port: p) { _ = (a, b); return p }
        }
        return nil
    }
}

/// The built helper next to the test bundle.
func fakeServerPath() -> String {
    let bundle = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }!
    return bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("FakeMCPStdioServer").path
}

/// A loopback HTTP server whose handler decides every reply; counts requests and keeps bodies.
final class StubHTTPServer: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "stub-http")
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []
    private let handler: @Sendable (HTTPRequest) -> HTTPResponse

    var requests: [HTTPRequest] { lock.withLock { _requests } }

    init(_ handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) throws {
        self.handler = handler
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: .any)
        let sem = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] st in
            if case .ready = st { self?.port = self?.listener.port?.rawValue ?? 0; sem.signal() }
            if case .failed = st { sem.signal() }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: queue)
        sem.wait()
    }
    func stop() { listener.cancel() }

    private func accept(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] st in if case .ready = st { self?.read(conn, Data()) } }
        conn.start(queue: queue)
    }
    private func read(_ conn: NWConnection, _ buf: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, _ in
            guard let self else { return }
            var b = buf; if let data { b.append(data) }
            switch HTTPParser.parse(b) {
            case .incomplete: if done { conn.cancel() } else { self.read(conn, b) }
            case .invalid: conn.cancel()
            case .request(let req, _):
                self.lock.withLock { self._requests.append(req) }
                conn.send(content: self.handler(req).serialize(keepAlive: false), completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }
}

func jsonBody(_ v: JSONValue) -> Data { try! JSONCoding.encoder.encode(v) }

func serverRequest(_ s: MCPServer, _ method: String, params: JSONValue? = nil) async throws -> JSONRPCResponse? {
    await s.handle(try JSONCoding.decoder.decode(JSONRPCRequest.self, from: rpc(method, params: params)))
}

func listedNames(_ r: JSONRPCResponse?) -> [String] {
    r?.result?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
}
