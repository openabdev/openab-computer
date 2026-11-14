import Foundation
import Darwin

public struct PortOwner: Equatable, Sendable {
    public var pid: Int32
    public var uid: UInt32
    public var name: String
    public init(pid: Int32, uid: UInt32, name: String) { self.pid = pid; self.uid = uid; self.name = name }
}

/// Who listens on a loopback TCP port (R7.5.5). nil means "could not tell", which callers treat
/// as a refusal.
public protocol PortOwnerProbe: Sendable {
    func owner(ofLoopbackPort port: UInt16) -> PortOwner?
}

/// libproc walk: every process we may inspect, every socket fd, the listening TCP ones. Other
/// users' processes are not visible without elevated rights, which also reads as "unknown".
/// If several owners listen on the port, a foreign-uid one is reported first (fail closed).
public struct LibprocPortOwnerProbe: PortOwnerProbe {
    public init() {}

    public func owner(ofLoopbackPort port: UInt16) -> PortOwner? {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 32)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return nil }
        let me = geteuid()
        var found: [PortOwner] = []
        for pid in pids.prefix(Int(got) / MemoryLayout<pid_t>.size) where pid > 0 {
            guard listens(pid: pid, port: port) else { continue }
            var info = proc_bsdinfo()
            let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard n == Int32(MemoryLayout<proc_bsdinfo>.size) else { continue }
            let name = withUnsafePointer(to: &info.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            found.append(PortOwner(pid: pid, uid: info.pbi_uid, name: name))
        }
        return found.first { $0.uid != me } ?? found.first
    }

    private func listens(pid: pid_t, port: UInt16) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 8)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
        guard got > 0 else { return false }
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, Int32(MemoryLayout<socket_fdinfo>.size))
            guard r == Int32(MemoryLayout<socket_fdinfo>.size) else { continue }
            let s = si.psi
            guard s.soi_kind == Int32(SOCKINFO_TCP), s.soi_proto.pri_tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            if UInt16(truncatingIfNeeded: Int(s.soi_proto.pri_tcp.tcpsi_ini.insi_lport)).bigEndian == port { return true }
        }
        return false
    }
}
