import Foundation
import XCTest
@testable import InstanceMCPCore

/// Some MCP clients (Grok's connector, many function-calling validators) drop a tool whose
/// input schema uses composition keywords or a `type` array inside a property. ui_snapshot
/// and ui_action vanished from Grok's tool list that way. Every advertised property must
/// have one plain type.
final class ToolSchemaShapeTests: XCTestCase {
    static let banned: Set<String> = ["anyOf", "oneOf", "allOf", "not"]

    /// Paths of banned constructs in a schema. A key named like a banned keyword under
    /// `properties` is a property name, not a keyword, so it is skipped.
    static func violations(_ v: JSONValue, path: String, inPropertyMap: Bool = false) -> [String] {
        var out: [String] = []
        switch v {
        case .object(let o):
            for (k, child) in o.sorted(by: { $0.key < $1.key }) {
                if !inPropertyMap {
                    if banned.contains(k) { out.append("\(path).\(k)") }
                    if k == "type", child.arrayValue != nil { out.append("\(path).type is an array") }
                }
                out += violations(child, path: "\(path).\(k)", inPropertyMap: !inPropertyMap && k == "properties")
            }
        case .array(let a):
            for (i, child) in a.enumerated() { out += violations(child, path: "\(path)[\(i)]") }
        default: break
        }
        return out
    }

    func testNoLocalToolSchemaUsesCompositionOrTypeArrays() {
        let tools = ToolCatalog.local(agentVersion: "test")
        XCTAssertGreaterThan(tools.count, 10)
        for t in tools {
            XCTAssertEqual(t.inputSchema["type"]?.stringValue, "object", "\(t.name): top-level type")
            let bad = Self.violations(t.inputSchema, path: t.name)
            XCTAssertTrue(bad.isEmpty, "\(t.name) uses a construct some MCP clients reject: \(bad)")
        }
    }

    func testEveryPropertyHasAPlainType() {
        for t in ToolCatalog.local(agentVersion: "test") {
            for (name, schema) in t.inputSchema["properties"]?.objectValue ?? [:] {
                XCTAssertNotNil(schema["type"]?.stringValue, "\(t.name).\(name) has no single string type")
            }
        }
    }

    func testWalkerCatchesBannedConstructs() {
        XCTAssertEqual(Self.violations(["properties": ["a": ["anyOf": [["type": "string"]]]]], path: "t"),
                       ["t.properties.a.anyOf"])
        XCTAssertEqual(Self.violations(["properties": ["a": ["type": ["string", "null"]]]], path: "t"),
                       ["t.properties.a.type is an array"])
        XCTAssertEqual(Self.violations(["properties": ["not": ["type": "string"]]], path: "t"), [])
    }

    // The runtime parsers keep the shapes the old schemas allowed.
    func testSnapshotWindowAcceptsTitleAndIndex() throws {
        XCTAssertEqual(try UISnapshotTool.parse(["window": "Untitled"]).window, .title("Untitled"))
        XCTAssertEqual(try UISnapshotTool.parse(["window": 2]).window, .index(2))
        XCTAssertEqual(try UISnapshotTool.parse(["window": 0]).window, .index(0))
        XCTAssertThrowsError(try UISnapshotTool.parse(["window": -1]))
    }

    func testActionValueAcceptsStringNumberAndBool() throws {
        func value(_ v: JSONValue) throws -> UIAttrValue? {
            try UIActionTool.parse(["snapshot_id": "s", "ref": "e1", "action": "set_value", "value": v]).value
        }
        XCTAssertEqual(try value("hello"), .string("hello"))
        XCTAssertEqual(try value(12), .number(12))
        XCTAssertEqual(try value(true), .bool(true))
        XCTAssertThrowsError(try value(["a": 1]))
    }
}
