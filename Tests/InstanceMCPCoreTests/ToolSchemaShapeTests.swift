import Foundation
import XCTest
@testable import InstanceMCPCore

/// Some MCP clients (Grok's connector, many function-calling validators) drop a tool whose
/// input schema uses a union, a negation or a reference keyword, or a `type` array, at any
/// depth. ui_snapshot and ui_action vanished from Grok's tool list that way. Every schema
/// position must carry one plain `type` string. The guard runs over the local catalog, over
/// the upstream (Playwright) descriptors that UpstreamTool forwards unchanged, and over the
/// Linux daemon's list in tool_schema_shape_tests.rs.
final class ToolSchemaShapeTests: XCTestCase {
    /// Keywords no guarded schema may use at a schema position.
    static let banned: Set<String> = ["anyOf", "oneOf", "allOf", "not", "$ref", "$defs", "definitions"]

    /// Every schema node reachable from `schema` through a schema position: the node itself,
    /// the values of `properties`, `items` (object or tuple form) and `additionalProperties`.
    /// Data keywords (`default`, `enum`, `const`, `examples`) are never entered, so a payload
    /// that happens to contain `anyOf` is not a finding. A property named `not` is a name, not
    /// a keyword: only the values under `properties` are walked.
    static func schemaNodes(_ schema: JSONValue, path: String) -> [(String, [String: JSONValue])] {
        guard case .object(let node) = schema else { return [] }
        var out: [(String, [String: JSONValue])] = [(path, node)]
        for (name, sub) in (node["properties"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            out += schemaNodes(sub, path: "\(path).properties.\(name)")
        }
        if let items = node["items"] {
            if let tuple = items.arrayValue {
                for (i, sub) in tuple.enumerated() { out += schemaNodes(sub, path: "\(path).items[\(i)]") }
            } else {
                out += schemaNodes(items, path: "\(path).items")
            }
        }
        if let extra = node["additionalProperties"] {
            out += schemaNodes(extra, path: "\(path).additionalProperties")
        }
        return out
    }

    /// Findings for one guarded schema, by path: a banned keyword, a `type` array, or a schema
    /// position without one plain `type` string.
    static func problems(_ schema: JSONValue, root: String) -> [String] {
        var out: [String] = []
        for (path, node) in schemaNodes(schema, path: root) {
            for k in node.keys.sorted() where banned.contains(k) { out.append("\(path).\(k)") }
            if node["type"]?.arrayValue != nil {
                out.append("\(path).type is an array")
            } else if node["type"]?.stringValue == nil {
                out.append("\(path) has no single string type")
            }
        }
        return out
    }

    /// A one-property object schema whose property `a` carries `keyword`.
    private func fixture(_ keyword: String, _ value: JSONValue) -> JSONValue {
        var a: [String: JSONValue] = ["type": .string("string")]
        a[keyword] = value
        return ["type": "object", "properties": ["a": .object(a)]]
    }

    func testNoLocalToolSchemaUsesCompositionOrTypeArrays() {
        let tools = ToolCatalog.local(agentVersion: "test")
        XCTAssertGreaterThan(tools.count, 10)
        for t in tools {
            XCTAssertEqual(t.inputSchema["type"]?.stringValue, "object", "\(t.name): top-level type")
            XCTAssertEqual(Self.problems(t.inputSchema, root: t.name), [], "\(t.name) uses a construct some MCP clients reject")
        }
    }

    // Upstream (Playwright) descriptors. UpstreamTool forwards each inputSchema unchanged, so the
    // same guard must hold for them. These fixtures are written in the shape the Playwright MCP
    // server publishes; the live tools/list was not queried.

    private static func plain(_ type: String) -> JSONValue { ["type": .string(type)] }

    private static func oneOf(_ values: [String]) -> JSONValue {
        ["type": "string", "enum": .array(values.map { .string($0) })]
    }

    private static func descriptor(_ name: String, _ properties: [String: JSONValue], required: [String]) -> JSONValue {
        [
            "name": .string(name),
            "description": "fixture",
            "inputSchema": [
                "type": "object",
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
                "additionalProperties": .bool(false),
            ],
        ]
    }

    static let upstreamDescriptors: [JSONValue] = [
        descriptor("browser_navigate", ["url": plain("string")], required: ["url"]),
        descriptor("browser_snapshot", [:], required: []),
        descriptor("browser_click", [
            "element": plain("string"),
            "ref": plain("string"),
            "doubleClick": plain("boolean"),
            "button": oneOf(["left", "right", "middle"]),
        ], required: ["element", "ref"]),
        descriptor("browser_type", [
            "element": plain("string"),
            "ref": plain("string"),
            "text": plain("string"),
            "submit": plain("boolean"),
        ], required: ["element", "ref", "text"]),
        descriptor("browser_fill_form", [
            "fields": ["type": "array", "items": [
                "type": "object",
                "properties": [
                    "name": plain("string"),
                    "type": oneOf(["textbox", "checkbox", "radio", "combobox", "slider"]),
                    "ref": plain("string"),
                    "value": plain("string"),
                ],
                "required": ["name", "type", "ref", "value"],
                "additionalProperties": .bool(false),
            ]],
        ], required: ["fields"]),
        descriptor("browser_tabs", [
            "action": oneOf(["list", "new", "close", "select"]),
            "index": ["type": "integer", "minimum": .number(0)],
        ], required: ["action"]),
        descriptor("browser_wait_for", [
            "time": plain("number"),
            "text": plain("string"),
            "textGone": plain("string"),
        ], required: []),
        descriptor("browser_file_upload", ["paths": ["type": "array", "items": plain("string")]], required: ["paths"]),
    ]

    func testForwardedUpstreamSchemasObeyTheSameRules() {
        let upstream = UpstreamMCP(name: "browser", url: URL(string: "http://127.0.0.1:9/mcp")!)
        XCTAssertEqual(Self.upstreamDescriptors.count, 8)
        for d in Self.upstreamDescriptors {
            let t = UpstreamTool(descriptorValue: d, upstream: upstream)
            XCTAssertEqual(t.inputSchema["type"]?.stringValue, "object", "\(t.name): top-level type")
            XCTAssertEqual(Self.problems(t.inputSchema, root: t.name), [], "\(t.name) uses a construct some MCP clients reject")
        }
    }

    func testForwardedUpstreamSchemaWithAUnionIsCaught() {
        let upstream = UpstreamMCP(name: "browser", url: URL(string: "http://127.0.0.1:9/mcp")!)
        let d = Self.descriptor("browser_bad", ["x": ["type": "string", "anyOf": [["type": "string"], ["type": "null"]]]], required: [])
        let t = UpstreamTool(descriptorValue: d, upstream: upstream)
        XCTAssertEqual(Self.problems(t.inputSchema, root: t.name), ["browser_bad.properties.x.anyOf"])
    }

    // One test per banned keyword, so deleting an entry from `banned` fails its own test.

    func testBannedSetIsExactlyTheSevenKeywords() {
        XCTAssertEqual(Self.banned, ["anyOf", "oneOf", "allOf", "not", "$ref", "$defs", "definitions"])
    }

    func testBansAnyOf() {
        XCTAssertEqual(Self.problems(fixture("anyOf", [["type": "string"]]), root: "t"), ["t.properties.a.anyOf"])
    }

    func testBansOneOf() {
        XCTAssertEqual(Self.problems(fixture("oneOf", [["type": "string"]]), root: "t"), ["t.properties.a.oneOf"])
    }

    func testBansAllOf() {
        XCTAssertEqual(Self.problems(fixture("allOf", [["type": "string"]]), root: "t"), ["t.properties.a.allOf"])
    }

    func testBansSchemaKeywordNot() {
        XCTAssertEqual(Self.problems(fixture("not", ["type": "string"]), root: "t"), ["t.properties.a.not"])
    }

    func testBansRef() {
        XCTAssertEqual(Self.problems(fixture("$ref", "#/$defs/x"), root: "t"), ["t.properties.a.$ref"])
    }

    func testBansDefs() {
        XCTAssertEqual(Self.problems(fixture("$defs", ["x": ["type": "string"]]), root: "t"), ["t.properties.a.$defs"])
    }

    func testBansDefinitions() {
        XCTAssertEqual(Self.problems(fixture("definitions", ["x": ["type": "string"]]), root: "t"), ["t.properties.a.definitions"])
    }

    func testBansArrayValuedType() {
        let schema: JSONValue = ["type": "object", "properties": ["a": ["type": ["string", "null"]]]]
        XCTAssertEqual(Self.problems(schema, root: "t"), ["t.properties.a.type is an array"])
    }

    // Plain-type check: recursive over every schema position, and nothing else.

    func testPlainTypeIsCheckedAtEveryDepth() {
        let nested: JSONValue = ["type": "object", "properties": ["outer": ["type": "object",
            "properties": ["inner": ["description": "no type here"]]]]]
        XCTAssertEqual(Self.problems(nested, root: "t"), ["t.properties.outer.properties.inner has no single string type"])

        let items: JSONValue = ["type": "object", "properties": ["list": ["type": "array",
            "items": ["properties": ["x": ["type": "string"]]]]]]
        XCTAssertEqual(Self.problems(items, root: "t"), ["t.properties.list.items has no single string type"])

        let extra: JSONValue = ["type": "object", "properties": ["map": ["type": "object",
            "additionalProperties": ["description": "no type"]]]]
        XCTAssertEqual(Self.problems(extra, root: "t"), ["t.properties.map.additionalProperties has no single string type"])
    }

    func testBooleanAdditionalPropertiesIsNotASchema() {
        let schema: JSONValue = ["type": "object", "properties": ["map": ["type": "object", "additionalProperties": .bool(false)]]]
        XCTAssertEqual(Self.problems(schema, root: "t"), [])
    }

    func testDataPayloadsAreNotInspected() {
        // `default`, `enum` and `const` hold values, not schemas: keys that look like keywords there are fine.
        let schema: JSONValue = ["type": "object", "properties": ["a": [
            "type": "object",
            "default": ["anyOf": [["type": "string"]]],
            "const": ["oneOf": 1],
        ]]]
        XCTAssertEqual(Self.problems(schema, root: "t"), [])
    }

    func testPropertyNamedLikeAKeywordIsAName() {
        let schema: JSONValue = ["type": "object", "properties": ["not": ["type": "string"], "anyOf": ["type": "string"]]]
        XCTAssertEqual(Self.problems(schema, root: "t"), [])
    }

    // The runtime parsers keep the shapes the old schemas allowed, and the new integer field.

    func testSnapshotWindowAcceptsTitleAndIndex() throws {
        XCTAssertEqual(try UISnapshotTool.parse(["window": "Untitled"]).window, .title("Untitled"))
        XCTAssertEqual(try UISnapshotTool.parse(["window": "2026"]).window, .title("2026"))
        XCTAssertEqual(try UISnapshotTool.parse(["window": 2]).window, .index(2))
        XCTAssertEqual(try UISnapshotTool.parse(["window": 0]).window, .index(0))
        XCTAssertThrowsError(try UISnapshotTool.parse(["window": -1]))
    }

    func testSnapshotWindowIndexIsAFlatInteger() throws {
        let props = UISnapshotTool().inputSchema["properties"]
        XCTAssertEqual(props?["window_index"]?["type"]?.stringValue, "integer")
        XCTAssertEqual(props?["window"]?["type"]?.stringValue, "string")
        XCTAssertEqual(try UISnapshotTool.parse(["window_index": 1]).window, .index(1))
        XCTAssertEqual(try UISnapshotTool.parse(["window_index": 0]).window, .index(0))
        XCTAssertThrowsError(try UISnapshotTool.parse(["window_index": "1"]))
        XCTAssertThrowsError(try UISnapshotTool.parse(["window_index": -1]))
        XCTAssertThrowsError(try UISnapshotTool.parse(["window": "Untitled", "window_index": 0]))
        XCTAssertThrowsError(try UISnapshotTool.parse(["window": 2, "window_index": 0]))
        XCTAssertThrowsError(try UISnapshotTool.parse(["window_index": 0, "all_windows": true]))
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
