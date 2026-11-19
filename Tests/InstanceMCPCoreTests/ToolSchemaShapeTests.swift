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

    // Upstream (Playwright) descriptors. UpstreamTool forwards each inputSchema, so the same guard
    // must hold for them. These hand-written fixtures are in the shape the Playwright MCP server
    // publishes. The recorded list below is the real one.

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

    // The recorded tools/list of the pinned @playwright/mcp 0.0.82 (Tests/Fixtures). It was taken from
    // a fresh stdio process with the app's flags; the running service on the browser port was not queried.
    static func recordedUpstreamTools() throws -> [JSONValue] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/playwright-mcp-0.0.82-tools-list.json")
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        return root["result"]?["tools"]?.arrayValue ?? []
    }

    func testRecordedPlaywrightToolsAreAllPlainAfterForwarding() throws {
        let upstream = UpstreamMCP(name: "browser", url: URL(string: "http://127.0.0.1:9/mcp")!)
        let tools = try Self.recordedUpstreamTools()
        XCTAssertEqual(tools.count, 32)
        for d in tools {
            let t = UpstreamTool(descriptorValue: d, upstream: upstream)
            XCTAssertEqual(Self.problems(t.inputSchema, root: t.name), [], "\(t.name) uses a construct some MCP clients reject")
        }
    }

    func testEmulateMediaOverridesAreForwardedAsPlainEnums() throws {
        let upstream = UpstreamMCP(name: "browser", url: URL(string: "http://127.0.0.1:9/mcp")!)
        let d = try XCTUnwrap(Self.recordedUpstreamTools().first { $0["name"]?.stringValue == "browser_emulate_media" })
        let props = UpstreamTool(descriptorValue: d, upstream: upstream).inputSchema["properties"]
        let expected = [
            "colorScheme": ["light", "dark"],
            "reducedMotion": ["reduce", "no-preference"],
            "forcedColors": ["active", "none"],
            "contrast": ["more", "no-preference"],
            "media": ["screen", "print"],
        ]
        for (key, values) in expected {
            XCTAssertNil(props?[key]?["anyOf"], "\(key) still carries anyOf")
            XCTAssertEqual(props?[key]?["type"]?.stringValue, "string", key)
            XCTAssertEqual(props?[key]?["enum"]?.arrayValue?.compactMap(\.stringValue), values, key)
            XCTAssertNotNil(props?[key]?["description"], "\(key) lost its description")
        }
    }

    static let emulateMediaEnums: [String: [String]] = [
        "colorScheme": ["light", "dark"],
        "reducedMotion": ["reduce", "no-preference"],
        "forcedColors": ["active", "none"],
        "contrast": ["more", "no-preference"],
        "media": ["screen", "print"],
    ]

    /// Checks the browser_emulate_media entry of a `tools/list` result as a client receives it:
    /// no anyOf anywhere, and each of the five overrides is a plain string enum with no null.
    static func assertServedOptionB(_ result: JSONValue?, file: StaticString = #filePath, line: UInt = #line) {
        guard let entry = result?["tools"]?.arrayValue?.first(where: { $0["name"]?.stringValue == "browser_emulate_media" }) else {
            return XCTFail("browser_emulate_media is not in tools/list", file: file, line: line)
        }
        let schema = entry["inputSchema"] ?? .null
        let text = String(decoding: (try? JSONCoding.encoder.encode(schema)) ?? Data(), as: UTF8.self)
        XCTAssertFalse(text.contains("anyOf"), "served browser_emulate_media schema still has anyOf", file: file, line: line)
        XCTAssertEqual(problems(schema, root: "browser_emulate_media"), [], "served schema uses a banned construct", file: file, line: line)
        let description = entry["description"]?.stringValue ?? ""
        XCTAssertFalse(description.contains("null"), "served browser_emulate_media description still mentions null: \(description)", file: file, line: line)
        for (key, values) in emulateMediaEnums {
            let prop = schema["properties"]?[key]
            XCTAssertEqual(prop?["type"]?.stringValue, "string", "\(key) is not a plain string", file: file, line: line)
            XCTAssertEqual(prop?["enum"]?.arrayValue?.map { $0.stringValue ?? "<non-string>" }, values,
                           "\(key) enum is not option B", file: file, line: line)
        }
    }

    // The real tools/list handler (MCPServer.handle), on the upstream path: the fake upstream
    // serves the recorded Playwright list, and the server forwards it to the client.
    func testServedToolsListCarriesOptionBForUpstreamEmulateMedia() async throws {
        let up = try FakeUpstream(descriptors: try Self.recordedUpstreamTools()); defer { up.stop() }
        let server = MCPServer(name: "t", version: "0", tools: [],
                               upstreams: [UpstreamMCP(name: "browser", url: URL(string: "http://127.0.0.1:\(up.port)/mcp")!)])
        Self.assertServedOptionB(try await serverRequest(server, "tools/list")?.result)
    }

    // The real tools/list handler, on the browser router path (Playwright backend, recorded list).
    func testServedToolsListCarriesOptionBForBrowserRouterEmulateMedia() async throws {
        let backend = FakeBrowserBackend(.playwright)
        backend.served = try Self.recordedUpstreamTools()
        let server = MCPServer(name: "t", version: "0", tools: [],
                               browser: BrowserRouter(playwright: backend, store: MemoryPreferenceStore()))
        Self.assertServedOptionB(try await serverRequest(server, "tools/list")?.result)
    }

    func testOtherRecordedPlaywrightToolsAreForwardedUnchanged() throws {
        let upstream = UpstreamMCP(name: "browser", url: URL(string: "http://127.0.0.1:9/mcp")!)
        for d in try Self.recordedUpstreamTools() where d["name"]?.stringValue != "browser_emulate_media" {
            let t = UpstreamTool(descriptorValue: d, upstream: upstream)
            XCTAssertEqual(t.inputSchema, d["inputSchema"] ?? ["type": "object"], t.name)
        }
    }

    // Runtime refusal (finding 1). A forwarded schema that still carries a banned construct is hidden
    // from tools/list and cannot be called, on the upstream path and on the browser router path. Option B
    // covers browser_emulate_media only, so these fixtures use other names.

    private static func rawTool(_ name: String, _ inputSchema: JSONValue) -> JSONValue {
        ["name": .string(name), "description": "fixture", "inputSchema": inputSchema]
    }

    private static let bannedUpstreamTools: [JSONValue] = [
        rawTool("browser_union", ["type": "object", "properties": ["x": ["type": "string",
            "anyOf": [["type": "string"], ["type": "null"]]]]]),
        rawTool("browser_ref", ["type": "object", "properties": ["x": ["$ref": "#/$defs/x"]]]),
        rawTool("browser_defs", ["type": "object", "$defs": ["x": ["type": "string"]],
            "properties": ["x": ["type": "string"]]]),
    ]

    func testServedToolsListHidesUpstreamToolsWithBannedSchemas() async throws {
        let up = try FakeUpstream(descriptors: [Self.descriptor("browser_navigate", ["url": Self.plain("string")], required: ["url"])]
            + Self.bannedUpstreamTools)
        defer { up.stop() }
        let server = MCPServer(name: "t", version: "0", tools: [],
                               upstreams: [UpstreamMCP(name: "browser", url: URL(string: "http://127.0.0.1:\(up.port)/mcp")!)])
        let names = listedNames(try await serverRequest(server, "tools/list"))
        XCTAssertTrue(names.contains("browser_navigate"), "\(names)")
        for name in ["browser_union", "browser_ref", "browser_defs"] {
            XCTAssertFalse(names.contains(name), "\(name) is served with a banned schema: \(names)")
        }
    }

    func testUpstreamToolWithBannedSchemaIsNotCalled() async throws {
        let up = try FakeUpstream(descriptors: Self.bannedUpstreamTools)
        defer { up.stop() }
        let server = MCPServer(name: "t", version: "0", tools: [],
                               upstreams: [UpstreamMCP(name: "browser", url: URL(string: "http://127.0.0.1:\(up.port)/mcp")!)])
        _ = try await serverRequest(server, "tools/call", params: ["name": "browser_union", "arguments": [:]])
        XCTAssertTrue(up.calls.isEmpty, "the upstream ran browser_union, whose schema is refused")
    }

    func testBrowserRouterHidesToolWithBannedSchema() async throws {
        let backend = FakeBrowserBackend(.playwright)
        backend.served = [Self.rawTool("browser_navigate", ["type": "object", "properties": ["x": ["type": "string",
            "anyOf": [["type": "string"], ["type": "null"]]]]]),
            Self.rawTool("browser_snapshot", ["type": "object"])]
        let server = MCPServer(name: "t", version: "0", tools: [],
                               browser: BrowserRouter(playwright: backend, store: MemoryPreferenceStore()))
        let names = listedNames(try await serverRequest(server, "tools/list"))
        XCTAssertTrue(names.contains("browser_snapshot"), "\(names)")
        XCTAssertFalse(names.contains("browser_navigate"), "browser_navigate is served with a banned schema: \(names)")
    }

    func testBrowserRouterRefusesCallToToolWithBannedSchema() async {
        let backend = FakeBrowserBackend(.playwright)
        backend.served = [Self.rawTool("browser_navigate", ["type": "object", "properties": ["x": ["$ref": "#/$defs/x"]]])]
        let router = BrowserRouter(playwright: backend, store: MemoryPreferenceStore())
        let result = await router.call("browser_navigate", arguments: [:], BrowserConnection(key: "c1"))
        XCTAssertEqual(result["isError"]?.boolValue, true, "\(result)")
        XCTAssertTrue(backend.calls.isEmpty, "the backend ran browser_navigate, whose schema is refused")
    }

    func testForwardedEmulateMediaDescriptionDoesNotMentionNull() throws {
        let upstream = UpstreamMCP(name: "browser", url: URL(string: "http://127.0.0.1:9/mcp")!)
        let d = try XCTUnwrap(Self.recordedUpstreamTools().first { $0["name"]?.stringValue == "browser_emulate_media" })
        let served = UpstreamTool(descriptorValue: d, upstream: upstream).descriptor["description"]?.stringValue ?? ""
        XCTAssertFalse(served.contains("null"), "served description still mentions null: \(served)")
        XCTAssertTrue(served.contains("Omitted parameters are left unchanged"), served)
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

    func testSnapshotWindowSchemaIsTitleOnly() throws {
        let props = UISnapshotTool().inputSchema["properties"]
        XCTAssertEqual(props?["window"]?["type"]?.stringValue, "string")
        XCTAssertNil(props?["window_index"], "index selection is not advertised: strict clients send a title")
        XCTAssertEqual(try UISnapshotTool.parse(["window": 1]).window, .index(1), "a native integer still selects an index for existing callers")
        XCTAssertEqual(try UISnapshotTool.parse(["window": "1"]).window, .title("1"))
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
