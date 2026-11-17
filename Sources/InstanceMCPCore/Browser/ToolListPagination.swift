import Foundation

/// Follows `tools/list` pagination (MCP: request `params.cursor`, result `nextCursor`) for the
/// stdio and external HTTP Playwright clients, so a paged server (agent-browser's `all` profile
/// is about 160 tools over 3 pages) is not silently cut to its first page.
///
/// Rules:
/// - Pages are followed until `nextCursor` is absent, `null` or the empty string.
/// - At most `maxPages` pages and `maxTools` raw entries, so a hostile or buggy server cannot loop
///   forever or exhaust memory. Exceeding either is an error, never a truncated list.
/// - A cursor seen before (a cycle) is an error. A `nextCursor` that is not a string is an error.
/// - Fail closed: if any page fails after earlier pages succeeded, the whole call fails with that
///   page's error class. The partial list is dropped.
/// - Order is kept. Tools are de-duplicated by `name`, first occurrence wins; entries without a
///   string name are kept as they are.
/// - The caller's timeout is the overall budget, turned into one monotonic deadline when the walk
///   starts. Each page request gets the time left, so no request outlives it. The transports pass
///   the same deadline to everything else they do for the walk (HTTP `initialize`, session reset,
///   retry). Running out of budget is always `playwright_timeout`, on both transports.
/// - `cap`/`cycle`/`bad cursor` errors blame the server's answers, not the child's health; see
///   `isServerProtocolError`.
/// - Errors carry fixed classes only, never server-supplied text (cursors are never logged).
enum ToolListPagination {
    static let maxPages = 50
    static let maxTools = 2000

    /// The one error for "the overall budget ran out".
    static let budgetExhausted = "playwright_timeout"

    /// Errors caused by what a reachable server answered. The child is alive and talking, so these
    /// are returned to the caller and must not count as a child failure.
    static let serverProtocolErrors: Set<String> = [
        "tools_list_too_many_tools", "tools_list_too_many_pages", "tools_list_cursor_cycle", "tools_list_bad_cursor",
    ]
    static func isServerProtocolError(_ error: Error) -> Bool {
        guard let e = error as? PlaywrightTransportError else { return false }
        return serverProtocolErrors.contains(e.errorClass)
    }

    /// Seconds left until `deadline` on the monotonic clock (negative once past).
    static func remaining(until deadline: ContinuousClock.Instant) -> TimeInterval {
        let d = ContinuousClock.now.duration(to: deadline).components
        return TimeInterval(d.seconds) + TimeInterval(d.attoseconds) / 1e18
    }

    /// `fetch(params, deadline)` performs one `tools/list` request, finishing by `deadline`, and
    /// returns its `result`.
    static func collect(deadline overall: TimeInterval,
                        fetch: (_ params: JSONValue, _ deadline: ContinuousClock.Instant) async throws -> JSONValue) async throws -> [JSONValue] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(overall))
        var tools: [JSONValue] = []
        var seenNames = Set<String>()
        var seenCursors = Set<String>()
        var raw = 0
        var params: JSONValue = [:]
        for _ in 0..<maxPages {
            guard remaining(until: deadline) > 0 else { throw PlaywrightTransportError(errorClass: budgetExhausted) }
            let result = try await fetch(params, deadline)
            let page = result["tools"]?.arrayValue ?? []
            raw += page.count
            guard raw <= maxTools else { throw PlaywrightTransportError(errorClass: "tools_list_too_many_tools") }
            for tool in page {
                if let name = tool["name"]?.stringValue {
                    guard seenNames.insert(name).inserted else { continue }
                }
                tools.append(tool)
            }
            switch result["nextCursor"] {
            case nil, .some(.null): return tools
            case .some(.string(let c)):
                if c.isEmpty { return tools }
                guard seenCursors.insert(c).inserted else { throw PlaywrightTransportError(errorClass: "tools_list_cursor_cycle") }
                params = ["cursor": .string(c)]
            default:
                throw PlaywrightTransportError(errorClass: "tools_list_bad_cursor")
            }
        }
        throw PlaywrightTransportError(errorClass: "tools_list_too_many_pages")
    }
}
