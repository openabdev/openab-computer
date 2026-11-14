import Foundation

/// The only URL shape an external Playwright may have: `http` and a literal loopback address.
/// No name resolution, so `localhost` and DNS names are refused (R7.5.2).
public enum BrowserUpstreamURL {
    public struct Invalid: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    public static func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "http" else { throw Invalid(description: "browser upstream must use http") }
        let host = url.host ?? ""
        guard host == "127.0.0.1" || host == "::1" else {
            throw Invalid(description: "browser upstream host must be the literal 127.0.0.1 or ::1")
        }
    }
}
