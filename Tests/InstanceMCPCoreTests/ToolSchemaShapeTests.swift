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
    static let banned: Set<String> = ToolSchemaShape.banned

    /// Findings for one guarded schema, by path. The rules live in `ToolSchemaShape`, the same code the
    /// runtime uses to refuse a forwarded tool.
    static func problems(_ schema: JSONValue, root: String) -> [String] {
        ToolSchemaShape.problems(schema, root: root)
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
    static func assertServedOptionB(_ result: JSONValue?, name: String = "browser_emulate_media",
                                    file: StaticString = #filePath, line: UInt = #line) {
        guard let entry = result?["tools"]?.arrayValue?.first(where: { $0["name"]?.stringValue == name }) else {
            return XCTFail("\(name) is not in tools/list", file: file, line: line)
        }
        let schema = entry["inputSchema"] ?? .null
        let text = String(decoding: (try? JSONCoding.encoder.encode(schema)) ?? Data(), as: UTF8.self)
        XCTAssertFalse(text.contains("anyOf"), "served \(name) schema still has anyOf", file: file, line: line)
        XCTAssertEqual(problems(schema, root: name), [], "served schema uses a banned construct", file: file, line: line)
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

    // F1: the rewrite is decided on the upstream's own name, so a non-empty prefix still gets option B.
    func testServedToolsListCarriesOptionBUnderAPrefix() async throws {
        let up = try FakeUpstream(descriptors: try Self.recordedUpstreamTools()); defer { up.stop() }
        let server = MCPServer(name: "t", version: "0", tools: [],
                               upstreams: [UpstreamMCP(name: "browser", url: URL(string: "http://127.0.0.1:\(up.port)/mcp")!,
                                                       prefix: "pw_")])
        Self.assertServedOptionB(try await serverRequest(server, "tools/list")?.result, name: "pw_browser_emulate_media")
    }

    // The real tools/list handler, on the browser router path (Playwright backend, recorded list).
    func testServedToolsListCarriesOptionBForBrowserRouterEmulateMedia() async throws {
        let backend = FakeBrowserBackend(.playwright)
        backend.served = try Self.recordedUpstreamTools()
        let server = MCPServer(name: "t", version: "0", tools: [],
                               browser: BrowserRouter(playwright: backend, store: MemoryPreferenceStore()))
        Self.assertServedOptionB(try await serverRequest(server, "tools/list")?.result)
    }

    // F2: a null override is refused at the call on the browser router path, before the backend runs.
    func testNullEmulateMediaOverrideIsRefusedOnTheBrowserRouter() async throws {
        let backend = FakeBrowserBackend(.playwright)
        backend.served = try Self.recordedUpstreamTools()
        let server = MCPServer(name: "t", version: "0", tools: [],
                               browser: BrowserRouter(playwright: backend, store: MemoryPreferenceStore()))
        let r = try await serverRequest(server, "tools/call",
                                        params: ["name": "browser_emulate_media", "arguments": ["media": .null]])
        XCTAssertEqual(r?.result?["isError"], true)
        let text = r?.result?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.contains("media cannot be null"), text)
        XCTAssertEqual(backend.calls, [], "a refused null reached the browser backend")
    }

    func testOtherRecordedPlaywrightToolsAreForwardedUnchanged() throws {
        let upstream = UpstreamMCP(name: "browser", url: URL(string: "http://127.0.0.1:9/mcp")!)
        for d in try Self.recordedUpstreamTools() where d["name"]?.stringValue != "browser_emulate_media" {
            let t = UpstreamTool(descriptorValue: d, upstream: upstream)
            XCTAssertEqual(t.inputSchema, d["inputSchema"] ?? ["type": "object"], t.name)
        }
    }

    // One test per banned keyword, so deleting an entry from `banned` fails its own test.

    func testBannedSetIsExactlyTheNineKeywords() {
        XCTAssertEqual(Self.banned, ["anyOf", "oneOf", "allOf", "not", "$ref", "$dynamicRef", "$recursiveRef",
                                     "$defs", "definitions"])
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

    func testBansDynamicRef() {
        XCTAssertEqual(Self.problems(fixture("$dynamicRef", "#meta"), root: "t"), ["t.properties.a.$dynamicRef"])
    }

    func testBansRecursiveRef() {
        XCTAssertEqual(Self.problems(fixture("$recursiveRef", "#"), root: "t"), ["t.properties.a.$recursiveRef"])
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

    // F3: the keywords that hold a sub-schema are walked too, so a banned keyword or a missing type there is found.

    func testWalksPropertyNames() {
        XCTAssertEqual(Self.problems(fixture("propertyNames", ["type": "string", "anyOf": [["type": "string"]]]), root: "t"),
                       ["t.properties.a.propertyNames.anyOf"])
    }

    func testWalksPatternProperties() {
        XCTAssertEqual(Self.problems(fixture("patternProperties", ["p": ["description": "no type"]]), root: "t"),
                       ["t.properties.a.patternProperties.p has no single string type"])
    }

    func testWalksDependentSchemas() {
        XCTAssertEqual(Self.problems(fixture("dependentSchemas", ["p": ["type": "string", "not": ["type": "string"]]]), root: "t"),
                       ["t.properties.a.dependentSchemas.p.not"])
    }

    func testWalksPrefixItems() {
        XCTAssertEqual(Self.problems(fixture("prefixItems", [["type": "string", "oneOf": [["type": "string"]]]]), root: "t"),
                       ["t.properties.a.prefixItems[0].oneOf"])
    }

    func testWalksContains() {
        XCTAssertEqual(Self.problems(fixture("contains", ["description": "no type"]), root: "t"),
                       ["t.properties.a.contains has no single string type"])
    }

    func testWalksIfThenElse() {
        XCTAssertEqual(Self.problems(fixture("if", ["type": "string", "allOf": [["type": "string"]]]), root: "t"),
                       ["t.properties.a.if.allOf"])
        XCTAssertEqual(Self.problems(fixture("then", ["description": "no type"]), root: "t"),
                       ["t.properties.a.then has no single string type"])
        XCTAssertEqual(Self.problems(fixture("else", ["description": "no type"]), root: "t"),
                       ["t.properties.a.else has no single string type"])
    }

    // Round-4 F4: the remaining draft-7 and 2020-12 sub-schema keywords are walked too.

    func testWalksDependenciesSchemaFormAndSkipsItsListForm() {
        XCTAssertEqual(Self.problems(fixture("dependencies", ["p": ["type": "string", "anyOf": [["type": "string"]]],
                                                               "q": ["r", "s"]]), root: "t"),
                       ["t.properties.a.dependencies.p.anyOf"])
    }

    func testWalksAdditionalAndUnevaluatedItemsAndProperties() {
        for key in ["additionalItems", "unevaluatedItems", "unevaluatedProperties", "contentSchema"] {
            XCTAssertEqual(Self.problems(fixture(key, ["type": "string", "oneOf": [["type": "string"]]]), root: "t"),
                           ["t.properties.a.\(key).oneOf"], key)
        }
    }

    /// A keyword outside the known vocabulary fails closed: it may hold a sub-schema the walker
    /// would not enter, so it is reported instead of passing silently.
    func testUnknownKeywordFailsClosed() {
        XCTAssertEqual(Self.problems(fixture("x-schema", ["anyOf": [["type": "string"]]]), root: "t"),
                       ["t.properties.a.x-schema is not a known schema keyword"])
        XCTAssertEqual(Self.problems(fixture("nullable", true), root: "t"),
                       ["t.properties.a.nullable is not a known schema keyword"])
        // Known annotation and validation keywords still pass.
        XCTAssertEqual(Self.problems(fixture("format", "uri"), root: "t"), [])
        XCTAssertEqual(Self.problems(fixture("$comment", "c"), root: "t"), [])
    }

    // Round-5 F1: `$dynamicRef` and `$recursiveRef` are banned (see testBansDynamicRef and
    // testBansRecursiveRef); their anchors stay allowed, since an anchor does nothing without a reference.

    func testAnchorsWithoutAReferenceAreAllowed() {
        for key in ["$dynamicAnchor", "$recursiveAnchor"] {
            XCTAssertEqual(Self.problems(fixture(key, "meta"), root: "t"), [], key)
        }
    }

    // Round-4 F3: only a string-or-null union is collapsed; any other union keeps its anyOf and is refused.

    func testEmulateMediaUnionWithANonNullBranchIsRefusedNotCollapsed() {
        let d = Self.descriptor("browser_emulate_media", [
            "zoom": ["anyOf": [["type": "string", "enum": ["in"]], ["type": "number"]]],
        ], required: [])
        let served = UpstreamTool.forwardedDescriptor(d)
        XCTAssertNotNil(served["inputSchema"]?["properties"]?["zoom"]?["anyOf"], "a non-null branch was dropped")
        XCTAssertEqual(UpstreamTool.refusal(d), "browser_emulate_media.properties.zoom.anyOf")
    }

    func testEmulateMediaStringOrNullUnionIsStillCollapsed() {
        let d = Self.descriptor("browser_emulate_media", [
            "zoom": ["anyOf": [["type": "string", "enum": ["in"]], ["type": "null"]], "description": "z"],
        ], required: [])
        XCTAssertNil(UpstreamTool.refusal(d))
        let zoom = UpstreamTool.forwardedDescriptor(d)["inputSchema"]?["properties"]?["zoom"]
        XCTAssertEqual(zoom?["type"]?.stringValue, "string")
        XCTAssertNil(zoom?["anyOf"])
    }

    // Round-4 F2: a null is refused for any browser_emulate_media argument, not a fixed key list.

    func testNullIsRefusedForAnEmulateMediaPropertyAddedLater() {
        XCTAssertEqual(UpstreamTool.nullOverrideRefusal("browser_emulate_media", ["zoom": .null]),
                       "browser_emulate_media: zoom cannot be null; omit it or send one of its enum values")
        XCTAssertNil(UpstreamTool.nullOverrideRefusal("browser_emulate_media", ["zoom": "in"]))
        XCTAssertNil(UpstreamTool.nullOverrideRefusal("browser_click", ["zoom": .null]))
    }

    /// The non-object root rule, the same as the Rust guard's `root_must_be_an_object_schema`.
    func testNonObjectRootIsRefused() {
        XCTAssertEqual(Self.problems(.bool(true), root: "t"), ["t is not an object schema"])
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
