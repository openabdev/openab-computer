import Foundation

/// The schema rules every served tool must meet. Some MCP clients (Grok's connector, many
/// function-calling validators) drop a tool whose input schema uses a union, a negation or a
/// reference keyword, or a `type` array, at any depth. Every schema position must carry one plain
/// `type` string. The runtime uses these rules to refuse a forwarded tool that breaks them (see
/// `UpstreamTool.refusal`), and the tests use them over the local catalog.
enum ToolSchemaShape {
    /// Keywords no served schema may use at a schema position.
    static let banned: Set<String> = ["anyOf", "oneOf", "allOf", "not", "$ref", "$defs", "definitions"]

    /// Findings for one schema, by path: a banned keyword, a `type` array, or a schema position
    /// without one plain `type` string. Empty when the schema passes.
    static func problems(_ schema: JSONValue, root: String) -> [String] {
        guard schema.objectValue != nil else { return ["\(root) is not an object schema"] }
        var out: [String] = []
        for (path, node) in nodes(schema, path: root) {
            for k in node.keys.sorted() where banned.contains(k) { out.append("\(path).\(k)") }
            if node["type"]?.arrayValue != nil {
                out.append("\(path).type is an array")
            } else if node["type"]?.stringValue == nil {
                out.append("\(path) has no single string type")
            }
        }
        return out
    }

    /// Every schema node reachable from `schema` through a schema position: the node itself, the
    /// values of `properties`, `patternProperties` and `dependentSchemas`, `items` (object or tuple
    /// form), `prefixItems`, and the single-schema keywords `additionalProperties`, `propertyNames`,
    /// `contains`, `if`, `then` and `else`. Data keywords (`default`, `enum`, `const`, `examples`) are
    /// never entered. A non-object sub-schema is not a node.
    static func nodes(_ schema: JSONValue, path: String) -> [(String, [String: JSONValue])] {
        guard case .object(let node) = schema else { return [] }
        var out: [(String, [String: JSONValue])] = [(path, node)]
        for key in ["properties", "patternProperties", "dependentSchemas"] {
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
        for key in ["additionalProperties", "propertyNames", "contains", "if", "then", "else"] {
            if let sub = node[key] { out += nodes(sub, path: "\(path).\(key)") }
        }
        return out
    }
}
