import Foundation

/// AppleScript / JXA via `/usr/bin/osascript`. The cheapest way to drive GUI apps that
/// expose a scripting dictionary (Finder, Safari, Mail, System Events…) without pixel
/// hunting. Per-app Automation TCC prompts appear on the Mac the first time a target
/// app is scripted.
public struct OsascriptTool: Tool {
    public let name = "osascript"
    public let description = """
        Run AppleScript (default) or JavaScript for Automation (`language: "javascript"`) on this \
        Mac and return its result. Good for: activating apps (`tell application "Safari" to activate`), \
        reading window titles/URLs, System Events UI scripting, dialogs. Runs in the GUI session as the \
        desktop user. First use against a given app may trigger an Automation permission prompt on the Mac.
        """
    public let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "script": ["type": "string"],
            "language": ["type": "string", "enum": ["applescript", "javascript"], "default": "applescript"],
            "timeout_secs": ["type": "number", "description": "Default 15, max 300 (100 on openab-pty attaches)."],
        ],
        "required": ["script"],
    ]

    public init() {}

    public func call(arguments a: JSONValue) async throws -> ToolResult {
        guard let script = a["script"]?.stringValue, !script.isEmpty else { throw JSONRPCError.invalidParams("script is required") }
        let lang = a["language"]?.stringValue == "javascript" ? "JavaScript" : "AppleScript"
        let timeout = min(a["timeout_secs"]?.doubleValue ?? 15, 300)

        // Pass the script via a temp file to sidestep quoting entirely.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("oab-osa-\(UUID().uuidString).scpt")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cmd = "/usr/bin/osascript -l \(lang) \(shellQuote(tmp.path))"
        let r = try await ExecTool.run(command: cmd, cwd: FileManager.default.homeDirectoryForCurrentUser.path,
                                       env: ProcessInfo.processInfo.environment, timeout: timeout, cap: 256 * 1024)

        let out = r.stdout.trimmingCharacters(in: .newlines)
        let err = r.stderr.trimmingCharacters(in: .newlines)
        let structured: JSONValue = [
            "exit_code": .number(Double(r.exitCode)), "timed_out": .bool(r.timedOut),
            "result": .string(out), "stderr": .string(err), "language": .string(lang),
        ]
        if r.exitCode != 0 || r.timedOut {
            var msg = err.isEmpty ? out : err
            if r.timedOut {
                msg = "timed out after \(Int(timeout))s — if this is the first time scripting that app, macOS is probably " +
                      "showing an Automation consent dialog on the Mac; take a screenshot and click Allow with `mouse`." +
                      (msg.isEmpty ? "" : "\n" + msg)
            }
            return ToolResult(content: [.text(msg.isEmpty ? "osascript failed (exit \(r.exitCode))" : msg)], isError: true, structured: structured)
        }
        return ToolResult(content: [.text(out.isEmpty ? "(no result)" : out)], structured: structured)
    }

    func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
