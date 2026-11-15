import Foundation
import Darwin

enum NpmOutcome: Equatable {
    case ok, offline, integrity, failed, timedOut, cancelled
}

/// Runs `npm ci` with the staged Node (R7.2 step 6). Node runs `npm-cli.js` directly, so no
/// `#!/usr/bin/env node` lookup happens. The environment is an allow-list: no `npm_config_*`, no
/// `NODE_OPTIONS`, no proxy variables, and `HOME` points inside staging so `~/.npmrc` is never
/// read. Output is never kept: stdout is drained and dropped, stderr goes to the in-memory ring
/// and only yes/no signatures leave it.
enum NpmRunner {
    static let registry = "https://registry.npmjs.org/"

    struct Command: Equatable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
        let workingDirectory: String
    }

    static func command(staging: URL) -> Command {
        let node = staging.appendingPathComponent("node/bin/node").path
        let cli = staging.appendingPathComponent("node/lib/node_modules/npm/bin/npm-cli.js").path
        let args = [cli, "ci", "--ignore-scripts", "--omit=dev", "--no-audit", "--no-fund",
                    "--userconfig", staging.appendingPathComponent("user.npmrc").path,
                    "--globalconfig", staging.appendingPathComponent("global.npmrc").path,
                    "--registry", registry,
                    "--cache", staging.appendingPathComponent("npm-cache").path]
        let env: [String: String] = [
            "HOME": staging.appendingPathComponent("home").path,
            "TMPDIR": staging.appendingPathComponent("tmp").path,
            "LANG": "en_US.UTF-8",
            "PATH": "\(staging.appendingPathComponent("node/bin").path):/usr/bin:/bin",
        ]
        return Command(executable: node, arguments: args, environment: env,
                       workingDirectory: staging.appendingPathComponent("pkg").path)
    }

    /// Creates the empty config files and the private HOME/TMPDIR the command refers to.
    static func prepare(staging: URL) throws {
        let fm = FileManager.default
        for d in ["home", "tmp", "npm-cache"] {
            try fm.createDirectory(at: staging.appendingPathComponent(d), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        for f in ["user.npmrc", "global.npmrc"] {
            guard fm.createFile(atPath: staging.appendingPathComponent(f).path, contents: Data(),
                                attributes: [.posixPermissions: 0o600]) else { throw PlaywrightInstallFailure.other("npm_prepare") }
        }
    }

    static func run(staging: URL, timeout: TimeInterval = 600) async -> NpmOutcome {
        let c = command(staging: staging)
        let child: ManagedProcess
        do {
            child = try ManagedProcess.spawn(executable: c.executable, arguments: c.arguments,
                                             environment: c.environment, workingDirectory: c.workingDirectory)
        } catch { return .failed }
        child.closeStdin()
        let drain = Task { for await _ in child.incoming {} }
        defer { drain.cancel() }
        let deadline = Date().addingTimeInterval(timeout)
        var outcome: NpmOutcome?
        await withTaskCancellationHandler {
            while !child.hasExited {
                if Task.isCancelled { outcome = .cancelled; break }
                if Date() >= deadline { outcome = .timedOut; break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        } onCancel: {}
        if let o = outcome {
            await child.terminate()
            return o
        }
        await child.terminate()   // sweeps anything the exited child left behind
        if case .exited(0)? = child.exitInfo { return .ok }
        if child.stderrRing.contains(anyOf: ["eintegrity"]) { return .integrity }
        if child.stderrRing.contains(anyOf: ["enotfound", "etimedout", "econnrefused", "eai_again", "econnreset", "enetunreach"]) { return .offline }
        return .failed
    }
}
