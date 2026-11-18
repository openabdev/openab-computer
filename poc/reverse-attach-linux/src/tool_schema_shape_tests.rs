//! Schema shape guard for the tool lists this daemon serves: `tool_list_with` (the local
//! tools and the job tools, for the owner and observe profiles) and `jobs::tools::tool_specs`
//! on their own. The rules match the Swift `ToolSchemaShapeTests`: no union, negation or
//! reference keyword, and no `type` array, at any schema position, and every schema position
//! carries one plain `type` string. Upstream (Playwright) schemas are forwarded unchanged and
//! are not in these lists; the Swift test covers them with fixtures. The live upstream
//! tools/list was not queried.

use serde_json::{json, Value};

use crate::mcp::tool_list_with;

/// Keywords no guarded schema may use at a schema position.
const BANNED: &[&str] = &["anyOf", "oneOf", "allOf", "not", "$ref", "$defs", "definitions"];

/// Schema positions under `schema`, as (path, node): the node itself, the values of
/// `properties`, `items` (object or tuple form) and `additionalProperties`. Data keywords
/// (`default`, `enum`, `const`, `examples`) are never entered, and a property named like a
/// keyword is a name, not a keyword.
fn schema_nodes<'a>(schema: &'a Value, path: String, out: &mut Vec<(String, &'a Value)>) {
    if !schema.is_object() {
        return;
    }
    out.push((path.clone(), schema));
    if let Some(props) = schema.get("properties").and_then(Value::as_object) {
        for (name, sub) in props {
            schema_nodes(sub, format!("{path}.properties.{name}"), out);
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
    if let Some(extra) = schema.get("additionalProperties") {
        schema_nodes(extra, format!("{path}.additionalProperties"), out);
    }
}

/// Findings for one guarded schema, by path. An empty result means the schema passes.
fn problems(schema: &Value, root: &str) -> Vec<String> {
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

/// A schema `{type: object, properties: {a: {type: string, <keyword>: value}}}`.
fn with_property_keyword(keyword: &str, value: Value) -> Value {
    let mut a = json!({ "type": "string" });
    a.as_object_mut().unwrap().insert(keyword.to_string(), value);
    json!({ "type": "object", "properties": { "a": a } })
}

fn assert_tool_passes(tool: &Value, context: &str) {
    let name = tool["name"].as_str().unwrap_or("?");
    assert_eq!(tool["inputSchema"]["type"], "object", "{context}/{name}: top-level type");
    assert_eq!(problems(&tool["inputSchema"], name), Vec::<String>::new(), "{context}/{name}");
}

#[test]
fn banned_set_is_exactly_the_seven_keywords() {
    assert_eq!(BANNED, ["anyOf", "oneOf", "allOf", "not", "$ref", "$defs", "definitions"]);
}

// One test per banned keyword, so dropping an entry from BANNED fails its own test.
macro_rules! bans {
    ($($test:ident => $keyword:literal),* $(,)?) => {
        $(
            #[test]
            fn $test() {
                let schema = with_property_keyword($keyword, json!("x"));
                assert_eq!(problems(&schema, "t"), vec![format!("t.properties.a.{}", $keyword)]);
            }
        )*
    };
}

bans! {
    bans_any_of => "anyOf",
    bans_one_of => "oneOf",
    bans_all_of => "allOf",
    bans_schema_not => "not",
    bans_ref => "$ref",
    bans_defs => "$defs",
    bans_definitions => "definitions",
}

#[test]
fn bans_array_valued_type() {
    let schema = json!({ "type": "object", "properties": { "a": { "type": ["string", "null"] } } });
    assert_eq!(problems(&schema, "t"), vec!["t.properties.a.type is an array".to_string()]);
}

#[test]
fn plain_type_is_checked_at_every_depth() {
    let nested = json!({ "type": "object", "properties": { "outer": { "type": "object",
        "properties": { "inner": { "description": "no type" } } } } });
    assert_eq!(problems(&nested, "t"), vec!["t.properties.outer.properties.inner has no single string type".to_string()]);

    let items = json!({ "type": "object", "properties": { "list": { "type": "array",
        "items": { "properties": { "x": { "type": "string" } } } } } });
    assert_eq!(problems(&items, "t"), vec!["t.properties.list.items has no single string type".to_string()]);

    let extra = json!({ "type": "object", "properties": { "map": { "type": "object",
        "additionalProperties": { "description": "no type" } } } });
    assert_eq!(problems(&extra, "t"), vec!["t.properties.map.additionalProperties has no single string type".to_string()]);
}

#[test]
fn boolean_additional_properties_is_not_a_schema() {
    let schema = json!({ "type": "object", "properties": { "map": { "type": "object", "additionalProperties": false } } });
    assert_eq!(problems(&schema, "t"), Vec::<String>::new());
}

#[test]
fn data_payloads_are_not_inspected() {
    let schema = json!({ "type": "object", "properties": { "a": {
        "type": "object",
        "default": { "anyOf": [{ "type": "string" }] },
        "const": { "oneOf": 1 }
    } } });
    assert_eq!(problems(&schema, "t"), Vec::<String>::new());
}

#[test]
fn property_named_like_a_keyword_is_a_name() {
    let schema = json!({ "type": "object", "properties": { "not": { "type": "string" }, "anyOf": { "type": "string" } } });
    assert_eq!(problems(&schema, "t"), Vec::<String>::new());
}

#[test]
fn root_must_be_an_object_schema() {
    assert_eq!(problems(&json!("x"), "t"), vec!["t is not an object schema".to_string()]);
}

#[test]
fn local_tool_lists_obey_the_schema_rules() {
    // owner gets every local and job tool; observe is the read-only subset. Both lists are
    // built with no upstreams, so only this daemon's own schemas are checked.
    let owner = tool_list_with("owner", &[]);
    let owner = owner.as_array().expect("tools/list is an array");
    let names: Vec<&str> = owner.iter().filter_map(|t| t["name"].as_str()).collect();
    assert!(names.contains(&"screenshot") && names.contains(&"exec_start"), "owner list: {names:?}");
    for tool in owner {
        assert_tool_passes(tool, "owner");
    }

    let observe = tool_list_with("observe", &[]);
    let observe = observe.as_array().expect("tools/list is an array");
    assert!(!observe.is_empty(), "observe list is empty");
    for tool in observe {
        assert_tool_passes(tool, "observe");
    }
}

#[test]
fn job_tool_specs_obey_the_schema_rules() {
    let specs = crate::jobs::tools::tool_specs();
    assert_eq!(specs.len(), 4, "exec_start, exec_poll, exec_list, exec_cancel");
    for tool in &specs {
        assert_tool_passes(tool, "jobs");
    }
}
