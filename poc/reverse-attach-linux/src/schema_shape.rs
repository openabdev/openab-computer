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

/// Keywords whose value is a map of name to sub-schema.
const SCHEMA_MAPS: &[&str] = &[
    "properties",
    "patternProperties",
    "dependentSchemas",
    "dependencies",
];

/// Keywords whose value is one sub-schema.
const SINGLE_SCHEMAS: &[&str] = &[
    "additionalProperties",
    "additionalItems",
    "unevaluatedProperties",
    "unevaluatedItems",
    "propertyNames",
    "contains",
    "contentSchema",
    "if",
    "then",
    "else",
];

/// Every other keyword a schema node may carry: the rest of the JSON Schema 2020-12 vocabularies
/// plus the draft-7 `id`. With `BANNED`, `SCHEMA_MAPS` and `SINGLE_SCHEMAS` this is the known set;
/// anything else is reported, so a keyword this walker does not know cannot hide a sub-schema from
/// it (fail closed). Same set as `ToolSchemaShape.known` on the Swift side.
const OTHER_KNOWN: &[&str] = &[
    "$schema",
    "$id",
    "id",
    "$anchor",
    "$dynamicAnchor",
    "$dynamicRef",
    "$recursiveRef",
    "$recursiveAnchor",
    "$comment",
    "$vocabulary",
    "items",
    "prefixItems",
    "type",
    "enum",
    "const",
    "multipleOf",
    "maximum",
    "exclusiveMaximum",
    "minimum",
    "exclusiveMinimum",
    "maxLength",
    "minLength",
    "pattern",
    "maxItems",
    "minItems",
    "uniqueItems",
    "maxContains",
    "minContains",
    "maxProperties",
    "minProperties",
    "required",
    "dependentRequired",
    "title",
    "description",
    "default",
    "deprecated",
    "readOnly",
    "writeOnly",
    "examples",
    "format",
    "contentEncoding",
    "contentMediaType",
];

fn is_known(keyword: &str) -> bool {
    [BANNED, SCHEMA_MAPS, SINGLE_SCHEMAS, OTHER_KNOWN]
        .iter()
        .any(|set| set.contains(&keyword))
}

/// Schema positions under `schema`, as (path, node): the node itself, the values of `SCHEMA_MAPS`,
/// `items` (object or tuple form), `prefixItems`, and `SINGLE_SCHEMAS`. Data keywords (`default`,
/// `enum`, `const`, `examples`) are never entered, and a property named like a keyword is a name,
/// not a keyword. A non-object sub-schema is not a node (a boolean schema, or a draft-7
/// `dependencies` array of names).
fn schema_nodes<'a>(schema: &'a Value, path: String, out: &mut Vec<(String, &'a Value)>) {
    if !schema.is_object() {
        return;
    }
    out.push((path.clone(), schema));
    for key in SCHEMA_MAPS {
        if let Some(map) = schema.get(*key).and_then(Value::as_object) {
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
    for key in SINGLE_SCHEMAS {
        if let Some(sub) = schema.get(*key) {
            schema_nodes(sub, format!("{path}.{key}"), out);
        }
    }
}

/// Findings for one schema, by path: a banned keyword, an unknown keyword, a `type` array, or a
/// schema position without one plain `type` string. An empty result means the schema passes.
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
        if let Some(map) = node.as_object() {
            let mut unknown: Vec<&String> = map.keys().filter(|k| !is_known(k)).collect();
            unknown.sort();
            for keyword in unknown {
                out.push(format!("{path}.{keyword} is not a known schema keyword"));
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
