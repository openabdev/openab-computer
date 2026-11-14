import Foundation

/// Shared plumbing for `exec` (synchronous) and `exec_start`/`exec_poll`/`exec_cancel`
/// (asynchronous jobs). Two concerns live here:
///
///  1. `resolveCwd` — turn a caller-supplied working directory (which may contain a
///     leading `~`) into an absolute path and fail *clearly* if it does not exist, is
///     not a directory, or sits on an external volume the daemon cannot read. Without
///     this a bad `cwd` surfaces as an opaque `posix_spawn failed: No such file or
///     directory`, and an external-volume path *hangs* until the timeout (see below).
///
///  2. `SpawnedProcess` — a non-blocking spawn that returns immediately with the pid
///     and the two read FDs, so a job can be polled/cancelled across MCP calls. The
///     synchronous `ExecTool.run` is now a thin wrapper that spawns then waits.

public enum ExecCwd {
    /// Result of validating a caller-supplied cwd.
    public enum Resolution {
        case ok(String)
        case failure(String)   // human-readable, safe to return as a ToolResult.error
    }

    /// Expand a leading `~` / `~user`, then require the path to exist and be a directory.
    /// External-volume paths (`/Volumes/...`) that the process cannot read are called out
    /// explicitly because a LaunchAgent without Full Disk Access does not get EPERM — the
    /// syscall *blocks*, so the caller would otherwise wait for the whole timeout.
    public static func resolve(_ raw: String) -> Resolution {
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return .failure("cwd must be an absolute path or start with ~ (got: \(raw))")
        }

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir)
        if !exists {
            if isExternalVolume(expanded) {
                return .failure(externalVolumeHint(expanded, verb: "does not exist or cannot be read"))
            }
            return .failure("cwd does not exist: \(expanded)")
        }
        if !isDir.boolValue {
            return .failure("cwd is not a directory: \(expanded)")
        }
        // Exists and is a directory. If it is on an external volume, probe readability so
        // we fail fast with actionable advice instead of hanging inside posix_spawn's chdir.
        if isExternalVolume(expanded), !isReadableDirectory(expanded) {
            return .failure(externalVolumeHint(expanded, verb: "is not readable by this daemon"))
        }
        return .ok(expanded)
    }

    static func isExternalVolume(_ path: String) -> Bool {
        path == "/Volumes" || path.hasPrefix("/Volumes/")
    }

    /// A bounded readability probe: open the directory with a short deadline. A LaunchAgent
    /// lacking Full Disk Access blocks here, so we time-box it rather than let it hang.
    static func isReadableDirectory(_ path: String) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var readable = false
        DispatchQueue.global().async {
            let fd = open(path, O_RDONLY | O_DIRECTORY)
            if fd >= 0 { readable = true; close(fd) }
            sem.signal()
        }
        // 1.5s is plenty for a local FS; a hang means TCC is blocking us.
        return sem.wait(timeout: .now() + 1.5) == .success && readable
    }

    static func externalVolumeHint(_ path: String, verb: String) -> String {
        "cwd \(path) is on an external volume and \(verb). If this daemon runs as a LaunchAgent, "
            + "macOS TCC blocks external-volume access unless the app bundle (dev.openab.computer) is granted "
            + "Full Disk Access in System Settings → Privacy & Security → Full Disk Access. "
            + "Grant it and restart the agent, or use an internal-disk path."
    }
}

/// A running child process spawned as its own session leader (POSIX_SPAWN_SETSID), with
/// stdout/stderr as read FDs. `pid` can be signalled via `killpg` to take the whole tree.
public struct SpawnedProcess: Sendable {
    public let pid: pid_t
    public let stdoutFD: Int32
    public let stderrFD: Int32
}

public enum ExecSpawn {
    /// Spawn `zsh -f -c command` non-blocking. Caller owns draining/closing the returned
    /// read FDs and reaping the pid. `cwd` must already be resolved (see `ExecCwd`).
    public static func spawn(command: String, cwd: String, env: [String: String]) throws -> SpawnedProcess {
        var outFDs: [Int32] = [0, 0], errFDs: [Int32] = [0, 0]
        guard pipe(&outFDs) == 0, pipe(&errFDs) == 0 else { throw ToolError("pipe() failed: \(errno)") }

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var sigs = sigset_t(); sigemptyset(&sigs)
        posix_spawnattr_setsigmask(&attr, &sigs)
        var flags = Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)
        flags |= Int16(POSIX_SPAWN_SETSID)
        posix_spawnattr_setflags(&attr, flags)

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outFDs[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errFDs[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, cwd)

        let argv: [String] = ["/bin/zsh", "-f", "-c", command]
        let envp: [String] = env.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let rc = withCStrings(argv) { argvPtrs in
            withCStrings(envp) { envPtrs in
                posix_spawn(&pid, "/bin/zsh", &actions, &attr, argvPtrs, envPtrs)
            }
        }
        close(outFDs[1]); close(errFDs[1])
        guard rc == 0 else {
            close(outFDs[0]); close(errFDs[0])
            throw ToolError("posix_spawn failed: \(String(cString: strerror(rc)))")
        }
        return SpawnedProcess(pid: pid, stdoutFD: outFDs[0], stderrFD: errFDs[0])
    }
}
