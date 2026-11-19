import Foundation

/// The schema rules every served tool must meet. Some MCP clients (Grok's connector, many
/// function-calling validators) drop a tool whose input schema uses a union, a negation or a
/// reference keyword, or a `type` array, at any depth. Every schema position must carry one plain
/// `type` string. The runtime uses these rules to refuse a forwarded tool that breaks them (see
/// `UpstreamTool.refusal`), and the tests use them over the local catalog.
enum ToolSchemaShape {
    /// Keywords no served schema may use at a schema position.
    static let banned: Set<String> = ["anyOf", "oneOf", "allOf", "not", "$ref", "$defs", "definitions"]

    /// Keywords whose value is a map of name to sub-schema.
    static let schemaMaps = ["properties", "patternProperties", "dependentSchemas", "dependencies"]
    /// Keywords whose value is one sub-schema.
    static let singleSchemas = ["additionalProperties", "additionalItems", "unevaluatedProperties", "unevaluatedItems",
                                "propertyNames", "contains", "contentSchema", "if", "then", "else"]

    /// Every keyword a schema node may carry: the JSON Schema 2020-12 vocabularies plus the draft-7
    /// keywords (`dependencies`, `additionalItems`, `definitions`, `id`). Anything else is reported,
    /// so a keyword this walker does not know cannot hide a sub-schema from it (fail closed).
    static let known: Set<String> = banned
        .union(schemaMaps).union(singleSchemas)
        .union(["$schema", "$id", "id", "$anchor", "$dynamicAnchor", "$dynamicRef", "$recursiveRef",
                "$recursiveAnchor", "$comment", "$vocabulary",
                "items", "prefixItems",
                "type", "enum", "const", "multipleOf", "maximum", "exclusiveMaximum", "minimum",
                "exclusiveMinimum", "maxLength", "minLength", "pattern", "maxItems", "minItems",
                "uniqueItems", "maxContains", "minContains", "maxProperties", "minProperties",
                "required", "dependentRequired",
                "title", "description", "default", "deprecated", "readOnly", "writeOnly", "examples",
                "format", "contentEncoding", "contentMediaType"])

    /// Findings for one schema, by path: a banned keyword, an unknown keyword, a `type` array, or a
    /// schema position without one plain `type` string. Empty when the schema passes.
    static func problems(_ schema: JSONValue, root: String) -> [String] {
        guard schema.objectValue != nil else { return ["\(root) is not an object schema"] }
        var out: [String] = []
        for (path, node) in nodes(schema, path: root) {
            for k in node.keys.sorted() where banned.contains(k) { out.append("\(path).\(k)") }
            for k in node.keys.sorted() where !known.contains(k) { out.append("\(path).\(k) is not a known schema keyword") }
            if node["type"]?.arrayValue != nil {
                out.append("\(path).type is an array")
            } else if node["type"]?.stringValue == nil {
                out.append("\(path) has no single string type")
            }
        }
        return out
    }

    /// Every schema node reachable from `schema` through a schema position: the node itself, the
    /// values of `schemaMaps`, `items` (object or tuple form), `prefixItems`, and `singleSchemas`.
    /// Data keywords (`default`, `enum`, `const`, `examples`) are never entered. A non-object
    /// sub-schema is not a node (a boolean schema, or a draft-7 `dependencies` array of names).
    static func nodes(_ schema: JSONValue, path: String) -> [(String, [String: JSONValue])] {
        guard case .object(let node) = schema else { return [] }
        var out: [(String, [String: JSONValue])] = [(path, node)]
        for key in schemaMaps {
            for (name, sub) in (node[key]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                out += nodes(sub, path: "\(path).\(key).\(name)")
            }
        }
        if let items = node["items"] {
            if let tuple = items.arrayValue {
                for (i, sub) in tuple.enumerated() { out += nodes(sub, path: "\(path).items[\(i)]") }
            } else {
                out += nodes(items, path: "\(path).items")
            }
        }
        for (i, sub) in (node["prefixItems"]?.arrayValue ?? []).enumerated() {
            out += nodes(sub, path: "\(path).prefixItems[\(i)]")
        }
        for key in singleSchemas {
            if let sub = node[key] { out += nodes(sub, path: "\(path).\(key)") }
        }
        return out
    }
}
