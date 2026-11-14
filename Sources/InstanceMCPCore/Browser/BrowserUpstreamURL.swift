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

    /// A validated loopback listener address: the family follows the literal host.
    public struct Endpoint: Equatable, Sendable {
        public enum Family: Equatable, Sendable { case v4, v6 }
        public let family: Family
        public let port: UInt16
        public init(family: Family, port: UInt16) { self.family = family; self.port = port }
    }

    /// `validate`, then the family and a range-checked port (no port means 80).
    public static func endpoint(_ url: URL) throws -> Endpoint {
        try validate(url)
        let p = url.port ?? 80
        guard (1...65535).contains(p) else { throw Invalid(description: "browser upstream port must be 1-65535") }
        return Endpoint(family: url.host == "::1" ? .v6 : .v4, port: UInt16(p))
    }
}
