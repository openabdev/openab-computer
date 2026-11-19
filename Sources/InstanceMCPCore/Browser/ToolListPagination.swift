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
/// - The caller's timeout is the overall deadline. Each page request gets the time left, so no
///   request outlives it and the whole walk is bounded by it.
/// - Errors carry fixed classes only, never server-supplied text (cursors are never logged).
enum ToolListPagination {
    static let maxPages = 50
    static let maxTools = 2000

    /// `fetch(params, timeout)` performs one `tools/list` request and returns its `result`.
    static func collect(deadline overall: TimeInterval,
                        fetch: (_ params: JSONValue, _ timeout: TimeInterval) async throws -> JSONValue) async throws -> [JSONValue] {
        let start = Date()
        var tools: [JSONValue] = []
        var seenNames = Set<String>()
        var seenCursors = Set<String>()
        var raw = 0
        var params: JSONValue = [:]
        for _ in 0..<maxPages {
            let left = overall - Date().timeIntervalSince(start)
            guard left > 0 else { throw PlaywrightTransportError(errorClass: "playwright_timeout") }
            let result = try await fetch(params, left)
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
