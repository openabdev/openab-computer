//! The schema rules every tool this daemon serves must meet. Some MCP clients (Grok's connector,
//! many function-calling validators) drop a tool whose input schema uses a union, a negation or a
//! reference keyword, or a `type` array, at any depth. Every schema position must carry one plain
//! `type` string. `mcp::upstream_tools_for_with` uses these rules to refuse a forwarded tool that
//! breaks them. Mirrors `ToolSchemaShape` on the Swift side.

use serde_json::Value;

/// Keywords no served schema may use at a schema position.
pub(crate) const BANNED: &[&str] = &[
    "anyOf",
    "oneOf",
    "allOf",
    "not",
    "$ref",
    "$defs",
    "definitions",
];

/// Schema positions under `schema`, as (path, node): the node itself, the values of `properties`,
/// `patternProperties` and `dependentSchemas`, `items` (object or tuple form), `prefixItems`, and
/// the single-schema keywords `additionalProperties`, `propertyNames`, `contains`, `if`, `then` and
/// `else`. Data keywords (`default`, `enum`, `const`, `examples`) are never entered, and a property
/// named like a keyword is a name, not a keyword. A non-object sub-schema is not a node.
fn schema_nodes<'a>(schema: &'a Value, path: String, out: &mut Vec<(String, &'a Value)>) {
    if !schema.is_object() {
        return;
    }
    out.push((path.clone(), schema));
    for key in ["properties", "patternProperties", "dependentSchemas"] {
        if let Some(map) = schema.get(key).and_then(Value::as_object) {
            for (name, sub) in map {
                schema_nodes(sub, format!("{path}.{key}.{name}"), out);
            }
        }
    }
    match schema.get("items") {
        Some(Value::Array(tuple)) => {
            for (i, sub) in tuple.iter().enumerate() {
                schema_nodes(sub, format!("{path}.items[{i}]"), out);
            }
        }
        Some(items) => schema_nodes(items, format!("{path}.items"), out),
        None => {}
    }
    if let Some(prefix) = schema.get("prefixItems").and_then(Value::as_array) {
        for (i, sub) in prefix.iter().enumerate() {
            schema_nodes(sub, format!("{path}.prefixItems[{i}]"), out);
        }
    }
    for key in [
        "additionalProperties",
        "propertyNames",
        "contains",
        "if",
        "then",
        "else",
    ] {
        if let Some(sub) = schema.get(key) {
            schema_nodes(sub, format!("{path}.{key}"), out);
        }
    }
}

/// Findings for one schema, by path. An empty result means the schema passes.
pub(crate) fn problems(schema: &Value, root: &str) -> Vec<String> {
    if !schema.is_object() {
        return vec![format!("{root} is not an object schema")];
    }
    let mut nodes = Vec::new();
    schema_nodes(schema, root.to_string(), &mut nodes);
    let mut out = Vec::new();
    for (path, node) in nodes {
        for keyword in BANNED {
            if node.get(*keyword).is_some() {
                out.push(format!("{path}.{keyword}"));
            }
        }
        match node.get("type") {
            Some(Value::String(_)) => {}
            Some(Value::Array(_)) => out.push(format!("{path}.type is an array")),
            _ => out.push(format!("{path} has no single string type")),
        }
    }
    out
}
