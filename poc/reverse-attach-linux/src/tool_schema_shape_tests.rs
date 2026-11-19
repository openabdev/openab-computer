//! Schema shape guard for the tool lists this daemon serves: `tool_list_with` (the local
//! tools and the job tools, for the owner and observe profiles), `jobs::tools::tool_specs`
//! on their own, and the owner list with the recorded Playwright upstream. The rules match
//! the Swift `ToolSchemaShapeTests`: no union, negation or reference keyword, and no `type`
//! array, at any schema position, and every schema position carries one plain `type` string.
//! browser_emulate_media is also pinned to option B, as on the Swift side.

use std::sync::Arc;

use serde_json::{json, Value};

use crate::backend::{BackendStatus, Upstream};
use crate::mcp::{tool_list_with, upstream_owning_with, upstream_tools_for_with};
use crate::schema_shape::{problems, BANNED};

/// A schema `{type: object, properties: {a: {type: string, <keyword>: value}}}`.
fn with_property_keyword(keyword: &str, value: Value) -> Value {
    let mut a = json!({ "type": "string" });
    a.as_object_mut()
        .unwrap()
        .insert(keyword.to_string(), value);
    json!({ "type": "object", "properties": { "a": a } })
}

fn assert_tool_passes(tool: &Value, context: &str) {
    let name = tool["name"].as_str().unwrap_or("?");
    assert_eq!(
        tool["inputSchema"]["type"], "object",
        "{context}/{name}: top-level type"
    );
    assert_eq!(
        problems(&tool["inputSchema"], name),
        Vec::<String>::new(),
        "{context}/{name}"
    );
}

#[test]
fn banned_set_is_exactly_the_seven_keywords() {
    assert_eq!(
        BANNED,
        [
            "anyOf",
            "oneOf",
            "allOf",
            "not",
            "$ref",
            "$defs",
            "definitions"
        ]
    );
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
    assert_eq!(
        problems(&schema, "t"),
        vec!["t.properties.a.type is an array".to_string()]
    );
}

#[test]
fn plain_type_is_checked_at_every_depth() {
    let nested = json!({ "type": "object", "properties": { "outer": { "type": "object",
        "properties": { "inner": { "description": "no type" } } } } });
    assert_eq!(
        problems(&nested, "t"),
        vec!["t.properties.outer.properties.inner has no single string type".to_string()]
    );

    let items = json!({ "type": "object", "properties": { "list": { "type": "array",
        "items": { "properties": { "x": { "type": "string" } } } } } });
    assert_eq!(
        problems(&items, "t"),
        vec!["t.properties.list.items has no single string type".to_string()]
    );

    let extra = json!({ "type": "object", "properties": { "map": { "type": "object",
        "additionalProperties": { "description": "no type" } } } });
    assert_eq!(
        problems(&extra, "t"),
        vec!["t.properties.map.additionalProperties has no single string type".to_string()]
    );
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
    assert_eq!(
        problems(&json!("x"), "t"),
        vec!["t is not an object schema".to_string()]
    );
}

#[test]
fn local_tool_lists_obey_the_schema_rules() {
    // owner gets every local and job tool; observe is the read-only subset. Both lists are
    // built with no upstreams, so only this daemon's own schemas are checked.
    let owner = tool_list_with("owner", &[]);
    let owner = owner.as_array().expect("tools/list is an array");
    let names: Vec<&str> = owner.iter().filter_map(|t| t["name"].as_str()).collect();
    assert!(
        names.contains(&"screenshot") && names.contains(&"exec_start"),
        "owner list: {names:?}"
    );
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
    assert_eq!(
        specs.len(),
        4,
        "exec_start, exec_poll, exec_list, exec_cancel"
    );
    for tool in &specs {
        assert_tool_passes(tool, "jobs");
    }
}

/// The recorded tools/list of the pinned @playwright/mcp 0.0.82. The same file the Swift tests read.
const RECORDED_PLAYWRIGHT_TOOLS: &str =
    include_str!("../../../Tests/Fixtures/playwright-mcp-0.0.82-tools-list.json");

/// An upstream that serves a fixed descriptor list, as the managed Playwright backend does.
struct RecordedUpstream(Vec<Value>);

impl Upstream for RecordedUpstream {
    fn tools(&self) -> Vec<Value> {
        self.0.clone()
    }
    fn call(&self, _name: &str, _arguments: Value) -> Result<Value, String> {
        Err("not called by this test".to_string())
    }
    fn status(&self) -> BackendStatus {
        BackendStatus {
            backend: "managed",
            reason: String::new(),
            containment: String::new(),
            display: "",
        }
    }
}

/// browser_emulate_media as a client receives it: no anyOf, each override is a plain string enum
/// with no null branch (option B), and the description no longer offers null.
fn assert_option_b_emulate_media(entry: &Value) {
    let schema = &entry["inputSchema"];
    let text = schema.to_string();
    assert!(
        !text.contains("anyOf"),
        "served browser_emulate_media schema still has anyOf: {text}"
    );
    assert!(
        problems(schema, "browser_emulate_media").is_empty(),
        "served browser_emulate_media schema uses a banned construct: {:?}",
        problems(schema, "browser_emulate_media")
    );
    let description = entry["description"].as_str().unwrap_or_default();
    assert!(
        !description.contains("null"),
        "served browser_emulate_media description still mentions null: {description}"
    );
    let expected = [
        ("colorScheme", json!(["light", "dark"])),
        ("reducedMotion", json!(["reduce", "no-preference"])),
        ("forcedColors", json!(["active", "none"])),
        ("contrast", json!(["more", "no-preference"])),
        ("media", json!(["screen", "print"])),
    ];
    for (key, values) in expected {
        let prop = &schema["properties"][key];
        assert_eq!(prop["type"], json!("string"), "{key} is not a plain string");
        assert_eq!(prop["enum"], values, "{key} enum is not option B");
    }
}

#[test]
fn served_owner_list_carries_option_b_for_upstream_emulate_media() {
    let fixture: Value = serde_json::from_str(RECORDED_PLAYWRIGHT_TOOLS).expect("fixture parses");
    let tools = fixture["result"]["tools"]
        .as_array()
        .expect("fixture has result.tools")
        .clone();
    assert_eq!(tools.len(), 32);
    let ups: Vec<Arc<dyn Upstream>> = vec![Arc::new(RecordedUpstream(tools))];
    let owner = tool_list_with("owner", &ups);
    let entry = owner
        .as_array()
        .expect("tools/list is an array")
        .iter()
        .find(|t| t["name"].as_str() == Some("browser_emulate_media"))
        .expect("browser_emulate_media is served to owner");
    assert_option_b_emulate_media(entry);
}

/// Every forwarded upstream tool in the owner list, not only browser_emulate_media, passes the
/// shape rules. Each recorded upstream name must be served, so a dropped tool cannot hide a schema.
#[test]
fn every_served_owner_tool_obeys_the_schema_rules_with_recorded_upstream() {
    let fixture: Value = serde_json::from_str(RECORDED_PLAYWRIGHT_TOOLS).expect("fixture parses");
    let tools = fixture["result"]["tools"]
        .as_array()
        .expect("fixture has result.tools")
        .clone();
    let upstream_names: Vec<String> = tools
        .iter()
        .filter_map(|t| t["name"].as_str().map(str::to_string))
        .collect();
    let ups: Vec<Arc<dyn Upstream>> = vec![Arc::new(RecordedUpstream(tools))];
    let owner = tool_list_with("owner", &ups);
    let owner = owner.as_array().expect("tools/list is an array");
    for name in &upstream_names {
        assert!(
            owner
                .iter()
                .any(|t| t["name"].as_str() == Some(name.as_str())),
            "upstream tool {name} is not served to owner"
        );
    }
    for tool in owner {
        assert_tool_passes(tool, "owner+upstream");
    }
}

fn recorded_tools() -> Vec<Value> {
    let fixture: Value = serde_json::from_str(RECORDED_PLAYWRIGHT_TOOLS).expect("fixture parses");
    fixture["result"]["tools"]
        .as_array()
        .expect("fixture has result.tools")
        .clone()
}

/// Upstream descriptors whose schemas still carry a banned construct after forwarding. Option B
/// covers browser_emulate_media only, so these other names must be refused by the runtime guard.
fn banned_upstream_tools() -> Vec<Value> {
    vec![
        json!({ "name": "browser_union", "description": "fixture", "inputSchema": {
            "type": "object",
            "properties": { "x": { "type": "string", "anyOf": [{ "type": "string" }, { "type": "null" }] } }
        } }),
        json!({ "name": "browser_ref", "description": "fixture", "inputSchema": {
            "type": "object",
            "properties": { "x": { "$ref": "#/$defs/x" } }
        } }),
        json!({ "name": "browser_defs", "description": "fixture", "inputSchema": {
            "type": "object",
            "$defs": { "x": { "type": "string" } },
            "properties": { "x": { "type": "string" } }
        } }),
    ]
}

const BANNED_NAMES: [&str; 3] = ["browser_union", "browser_ref", "browser_defs"];

/// An upstream tool whose schema has a banned construct is not served to the owner profile, and its
/// name is not left in the list. Covers anyOf, $ref and $defs.
#[test]
fn served_owner_list_hides_upstream_tools_with_banned_schemas() {
    let mut tools = recorded_tools();
    tools.extend(banned_upstream_tools());
    let ups: Vec<Arc<dyn Upstream>> = vec![Arc::new(RecordedUpstream(tools))];
    let owner = tool_list_with("owner", &ups);
    let owner = owner.as_array().expect("tools/list is an array");
    let names: Vec<&str> = owner.iter().filter_map(|t| t["name"].as_str()).collect();
    assert!(names.contains(&"browser_navigate"), "owner list: {names:?}");
    for name in BANNED_NAMES {
        assert!(
            !names.contains(&name),
            "{name} is served with a banned schema: {names:?}"
        );
    }
    for tool in owner {
        assert_tool_passes(tool, "owner+banned");
    }
}

/// The forwarded upstream list is shape-checked: every recorded tool is still forwarded, and the
/// banned tools are dropped. The recorded list is live only for the pinned fixture; a query to a
/// running @playwright/mcp is not part of the unit tests.
#[test]
fn forwarded_upstream_list_refuses_banned_tools_and_keeps_recorded_tools() {
    let recorded: Vec<String> = recorded_tools()
        .iter()
        .filter_map(|t| t["name"].as_str().map(str::to_string))
        .collect();
    let mut tools = recorded_tools();
    tools.extend(banned_upstream_tools());
    let ups: Vec<Arc<dyn Upstream>> = vec![Arc::new(RecordedUpstream(tools))];
    let forwarded = upstream_tools_for_with("owner", &[], &ups);
    let names: Vec<&str> = forwarded
        .iter()
        .filter_map(|(_, t)| t["name"].as_str())
        .collect();
    for name in &recorded {
        assert!(names.contains(&name.as_str()), "{name} was dropped: {names:?}");
    }
    for name in BANNED_NAMES {
        assert!(!names.contains(&name), "{name} is forwarded: {names:?}");
    }
    for (_, tool) in &forwarded {
        let name = tool["name"].as_str().unwrap_or("?");
        assert_eq!(
            problems(&tool["inputSchema"], name),
            Vec::<String>::new(),
            "{name} forwarded with a banned construct"
        );
    }
}

/// A call to a refused upstream tool is not routed upstream, so the upstream never runs it.
#[test]
fn upstream_does_not_own_a_call_to_a_banned_schema_tool() {
    let ups: Vec<Arc<dyn Upstream>> = vec![Arc::new(RecordedUpstream(banned_upstream_tools()))];
    assert!(
        upstream_owning_with("browser_union", "owner", &ups).is_none(),
        "a call to a refused tool is routed to the upstream"
    );
}
