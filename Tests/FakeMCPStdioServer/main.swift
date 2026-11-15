import Foundation
import Darwin

// A stand-in MCP stdio server for tests. Mode is argv[1]; see the cases below.
setvbuf(stdout, nil, _IONBF, 0)
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "normal"
let arg2 = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""

func emit(_ s: String, chunky: Bool = false) {
    let d = Array((s + "\n").utf8)
    if chunky {
        var i = 0
        while i < d.count { let n = min(3, d.count - i); _ = d[i..<(i + n)].withUnsafeBytes { write(1, $0.baseAddress, n) }; i += n; usleep(1000) }
    } else { d.withUnsafeBytes { _ = write(1, $0.baseAddress, d.count) } }
}
func err(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }

if mode == "listen4" || mode == "listen6" {
    let v6 = mode == "listen6"
    let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
    var yes: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, 4)
    let port = UInt16(arg2) ?? 0
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
    guard ok, listen(fd, 4) == 0 else { emit("failed"); exit(1) }
    emit("ready")
    sleep(600); exit(0)
}

if mode == "ignore-term" { signal(SIGTERM, SIG_IGN) }
if mode == "stderr-canary" || mode == "stderr-signature" {
    err("CANARY-token-abc https://example.invalid/?token=CANARY-secret\n")
    if mode == "stderr-signature" { err(String(repeating: "x", count: 70_000)); err("\nProcessSingleton: profile locked\n") }
    else { err(String(repeating: "filler ", count: 20_000)) }
    exit(3)
}
if mode == "env" { emit(ProcessInfo.processInfo.environment.keys.sorted().joined(separator: ",")); exit(0) }
if mode == "argv" { emit(CommandLine.arguments.dropFirst().joined(separator: " ")); exit(0) }
if mode == "grandchild" {
    // A same-group grandchild that outlives us unless the group is signalled.
    var gpid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup("sleep"), strdup("300"), nil]
    posix_spawn(&gpid, "/bin/sleep", nil, nil, argv, environ)   // inherits our process group
    emit("grandchild \(gpid)")
}
if mode == "detached-grandchild" {
    // A grandchild in its own session and group, like Chromium under Playwright: neither killpg
    // on our group nor our exit reaches it.
    var gpid: pid_t = 0
    var attr: posix_spawnattr_t?; posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup("sleep"), strdup("300"), nil]
    posix_spawn(&gpid, "/bin/sleep", nil, &attr, argv, environ)
    emit("grandchild \(gpid)")
    if arg2 == "hold" { while true { sleep(60) } }   // stay alive, ignoring stdin EOF
}
if mode == "hang-init" { while true { sleep(60) } }

var toolCalls = 0
let dieAfter = Int(arg2) ?? 0
while let line = readLine(strippingNewline: true) {
    guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
    guard let method = obj["method"] as? String, let id = obj["id"] else { continue }
    func reply(_ result: String) {
        let idJSON = (try? String(decoding: JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed), as: UTF8.self)) ?? "0"
        if mode == "noise" { emit("this is not json") }
        emit("{\"jsonrpc\":\"2.0\",\"id\":\(idJSON),\"result\":\(result)}", chunky: mode == "chunky")
    }
    switch method {
    case "initialize":
        let serverName = mode == "playwright-fake" ? "Playwright" : "fake"
        reply("{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"\(serverName)\",\"version\":\"0\"}}")
    case "ping": reply("{}")
    case "tools/list":
        if mode == "playwright-fake" || mode == "playwright-other" {
            // arg2 is a comma-separated list of tool names (the 32 real ones, or fewer for a failure test).
            reply("{\"tools\":[" + arg2.split(separator: ",").map { "{\"name\":\"\($0)\"}" }.joined(separator: ",") + "]}")
        } else { reply("{\"tools\":[{\"name\":\"browser_navigate\"},{\"name\":\"browser_snapshot\"}]}") }
    case "tools/call":
        toolCalls += 1
        let name = ((obj["params"] as? [String: Any])?["name"] as? String) ?? "?"
        if mode == "die-mid-call" { exit(9) }
        reply("{\"content\":[{\"type\":\"text\",\"text\":\"fake did \(name)\"}]}")
        if mode == "die-after" && toolCalls >= dieAfter { exit(7) }
    default: break
    }
}
if mode == "ignore-term" { while true { sleep(60) } }
exit(0)
