import Foundation
import XCTest
@testable import InstanceMCPCore

/// conformance/pins_vectors.json is shared with the Rust validator (ADR linux-browser-tier D1). Each
/// case mutates the tracked pins.json and states the exact problems the validators return.
final class PinsVectorTests: XCTestCase {
    private func pinsObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(PlaywrightPins.pinsJSON.utf8)) as? [String: Any])
    }

    private func expand(_ v: Any, _ m: PlaywrightManifest) -> Any {
        guard let s = v as? String else { return v }
        return s.replacingOccurrences(of: "{browserVersion}", with: m.chromium.browserVersion)
            .replacingOccurrences(of: "{revision}", with: m.chromium.revision)
            .replacingOccurrences(of: "{nodeVersion}", with: m.node.version)
    }

    private func get(_ root: Any, _ path: [String]) -> Any? {
        var cur: Any = root
        for k in path {
            guard let d = cur as? [String: Any], let n = d[k] else { return nil }
            cur = n
        }
        return cur
    }

    /// Replace the value at `path`, rebuilding the containers on the way back up.
    private func put(_ root: [String: Any], _ path: [String], _ value: Any?) -> [String: Any] {
        guard let first = path.first else { return root }
        var out = root
        if path.count == 1 {
            if let value { out[first] = value } else { out.removeValue(forKey: first) }
        } else {
            out[first] = put(out[first] as? [String: Any] ?? [:], Array(path.dropFirst()), value)
        }
        return out
    }

    private func apply(_ op: [String: Any], to obj: [String: Any], _ m: PlaywrightManifest) throws -> [String: Any] {
        let path = try XCTUnwrap(op["path"] as? [String])
        switch try XCTUnwrap(op["op"] as? String) {
        case "set": return put(obj, path, expand(try XCTUnwrap(op["value"]), m))
        case "remove": return put(obj, path, nil)
        case "copy": return put(obj, path, try XCTUnwrap(get(obj, try XCTUnwrap(op["from"] as? [String]))))
        case "replace":
            let s = try XCTUnwrap(get(obj, path) as? String)
            let from = expand(try XCTUnwrap(op["from"] as? String), m) as? String ?? ""
            let to = expand(try XCTUnwrap(op["to"] as? String), m) as? String ?? ""
            XCTAssertTrue(s.contains(from), "replace target \(from) not found")
            return put(obj, path, s.replacingOccurrences(of: from, with: to))
        default: XCTFail("unknown op"); return obj
        }
    }

    func testEveryPinsVectorGivesTheSameProblemsAsTheOracle() throws {
        let doc = try loadConformanceVector("pins_vectors.json")
        let cases = try XCTUnwrap(doc["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 40)
        let m = PlaywrightManifest.embedded
        var names = Set<String>()
        for c in cases {
            let name = try XCTUnwrap(c["name"] as? String)
            XCTAssertTrue(names.insert(name).inserted, "duplicate case \(name)")
            var obj = try pinsObject()
            for op in try XCTUnwrap(c["ops"] as? [[String: Any]]) { obj = try apply(op, to: obj, m) }
            let data = try JSONSerialization.data(withJSONObject: obj)
            let manifest = try PlaywrightManifest.decode(String(decoding: data, as: UTF8.self))
            let got = manifest.validate().sorted()
            let want = try XCTUnwrap(c["problems"] as? [String]).sorted()
            XCTAssertEqual(got, want, name)
            XCTAssertEqual(got.isEmpty, c["valid"] as? Bool, name)
        }
    }

    func testPlatformSelectionVectors() throws {
        let doc = try loadConformanceVector("pins_vectors.json")
        let rows = try XCTUnwrap(doc["selection"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(rows.count, 8)
        for r in rows {
            let os = try XCTUnwrap(r["os"] as? String), arch = try XCTUnwrap(r["arch"] as? String)
            XCTAssertEqual(PlatformID.select(os: os, arch: arch)?.rawValue, r["platform"] as? String, "\(os)/\(arch)")
        }
    }

    func testTheShippedPinsCoverAllFourPlatformsWithNoSilentSkip() {
        let m = PlaywrightManifest.embedded
        XCTAssertEqual(Set(PlatformID.allCases.map(\.rawValue)), ["darwin-arm64", "darwin-x64", "linux-x64", "linux-arm64"])
        for p in PlatformID.allCases {
            XCTAssertNotNil(m.nodeArtifact(platform: p), "node/\(p.rawValue)")
            XCTAssertNotNil(m.chromiumArtifact(platform: p), "chromium/\(p.rawValue)")
            XCTAssertNotNil(m.chromiumArtifact(platform: p)?.source)
            if p.isLinux { XCTAssertNotNil(m.chromiumArtifact(platform: p)?.minGlibc) }
        }
    }
}
