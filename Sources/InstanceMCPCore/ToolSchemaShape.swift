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

    /// Every schema node reachable from `schema` through a schema position: the node itself,
    /// the values of `properties`, `items` (object or tuple form) and `additionalProperties`.
    /// Data keywords (`default`, `enum`, `const`, `examples`) are never entered.
    static func nodes(_ schema: JSONValue, path: String) -> [(String, [String: JSONValue])] {
        guard case .object(let node) = schema else { return [] }
        var out: [(String, [String: JSONValue])] = [(path, node)]
        for (name, sub) in (node["properties"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            out += nodes(sub, path: "\(path).properties.\(name)")
        }
        if let items = node["items"] {
            if let tuple = items.arrayValue {
                for (i, sub) in tuple.enumerated() { out += nodes(sub, path: "\(path).items[\(i)]") }
            } else {
                out += nodes(items, path: "\(path).items")
            }
        }
        if let extra = node["additionalProperties"] {
            out += nodes(extra, path: "\(path).additionalProperties")
        }
        return out
    }
}
