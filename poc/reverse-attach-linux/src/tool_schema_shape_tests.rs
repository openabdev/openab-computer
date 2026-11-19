//! Schema shape guard for the tool lists this daemon serves: `tool_list_with` (the local
//! tools and the job tools, for the owner and observe profiles), `jobs::tools::tool_specs`
//! on their own, and the owner list with the recorded Playwright upstream. The rules match
//! the Swift `ToolSchemaShapeTests`: no union, negation or reference keyword, and no `type`
//! array, at any schema position, and every schema position carries one plain `type` string.
//! browser_emulate_media is also pinned to option B, as on the Swift side.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use serde_json::{json, Value};

use crate::backend::{BackendStatus, Upstream};
use crate::mcp::{
    handle_tool_call_with, tool_list_with, upstream_owning_with, upstream_tools_for_with,
    INVALID_PARAMS,
};
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
fn banned_set_is_exactly_the_nine_keywords() {
    assert_eq!(
        BANNED,
        [
            "anyOf",
            "oneOf",
            "allOf",
            "not",
            "$ref",
            "$dynamicRef",
            "$recursiveRef",
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
    bans_dynamic_ref => "$dynamicRef",
    bans_recursive_ref => "$recursiveRef",
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

/// F3: the keywords that hold a sub-schema are walked too.
#[test]
fn walks_property_names_and_pattern_properties() {
    let value = json!({ "type": "string", "anyOf": [{ "type": "string" }] });
    let names = with_property_keyword("propertyNames", value);
    assert_eq!(
        problems(&names, "t"),
        vec!["t.properties.a.propertyNames.anyOf".to_string()]
    );

    let value = json!({ "p": { "description": "no type" } });
    let pattern = with_property_keyword("patternProperties", value);
    assert_eq!(
        problems(&pattern, "t"),
        vec!["t.properties.a.patternProperties.p has no single string type".to_string()]
    );
}

#[test]
fn walks_dependent_schemas_prefix_items_and_contains() {
    let value = json!({ "p": { "type": "string", "not": { "type": "string" } } });
    let dependent = with_property_keyword("dependentSchemas", value);
    assert_eq!(
        problems(&dependent, "t"),
        vec!["t.properties.a.dependentSchemas.p.not".to_string()]
    );

    let value = json!([{ "type": "string", "oneOf": [{ "type": "string" }] }]);
    let prefix = with_property_keyword("prefixItems", value);
    assert_eq!(
        problems(&prefix, "t"),
        vec!["t.properties.a.prefixItems[0].oneOf".to_string()]
    );

    let contains = with_property_keyword("contains", json!({ "description": "no type" }));
    assert_eq!(
        problems(&contains, "t"),
        vec!["t.properties.a.contains has no single string type".to_string()]
    );
}

#[test]
fn walks_if_then_and_else() {
    let value = json!({ "type": "string", "allOf": [{ "type": "string" }] });
    let branch = with_property_keyword("if", value);
    assert_eq!(
        problems(&branch, "t"),
        vec!["t.properties.a.if.allOf".to_string()]
    );

    for keyword in ["then", "else"] {
        let branch = with_property_keyword(keyword, json!({ "description": "no type" }));
        assert_eq!(
            problems(&branch, "t"),
            vec![format!(
                "t.properties.a.{keyword} has no single string type"
            )]
        );
    }
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
        assert!(
            names.contains(&name.as_str()),
            "{name} was dropped: {names:?}"
        );
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

/// An upstream that counts the calls and the listings it receives and answers each call with an
/// empty result. Like the managed backend, it owns a name without listing, and its cached list is
/// read without a listing.
struct CountingUpstream {
    tools: Vec<Value>,
    calls: AtomicUsize,
    lists: AtomicUsize,
}

impl CountingUpstream {
    fn new(tools: Vec<Value>) -> Arc<CountingUpstream> {
        Arc::new(CountingUpstream {
            tools,
            calls: AtomicUsize::new(0),
            lists: AtomicUsize::new(0),
        })
    }
}

impl Upstream for CountingUpstream {
    fn tools(&self) -> Vec<Value> {
        self.lists.fetch_add(1, Ordering::SeqCst);
        self.tools.clone()
    }
    fn cached_tools(&self) -> Vec<Value> {
        self.tools.clone()
    }
    fn owns(&self, name: &str) -> bool {
        self.tools
            .iter()
            .any(|t| t.get("name").and_then(Value::as_str) == Some(name))
    }
    fn call(&self, _name: &str, _arguments: Value) -> Result<Value, String> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(json!({ "content": [] }))
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

/// F2: an explicit null for a browser_emulate_media override is refused at the call, and the
/// upstream never sees it. The reason names the key only.
#[test]
fn emulate_media_null_override_is_refused_before_the_upstream_call() {
    let upstream = CountingUpstream::new(recorded_tools());
    let ups: Vec<Arc<dyn Upstream>> = vec![upstream.clone()];
    let params = json!({ "name": "browser_emulate_media",
        "arguments": { "colorScheme": null, "media": "print" } });
    let refused = handle_tool_call_with(&params, "owner", None, &ups);
    let err = refused.expect_err("a null override is refused");
    assert_eq!(err.0, INVALID_PARAMS);
    assert_eq!(
        err.1,
        "Invalid params: browser_emulate_media: colorScheme cannot be null; omit it or send one of its enum values"
    );
    assert_eq!(
        upstream.calls.load(Ordering::SeqCst),
        0,
        "a refused call reached the upstream"
    );
}

/// The enum values still reach the upstream, so the refusal is only for null.
#[test]
fn emulate_media_enum_value_still_reaches_the_upstream() {
    let upstream = CountingUpstream::new(recorded_tools());
    let ups: Vec<Arc<dyn Upstream>> = vec![upstream.clone()];
    let params = json!({ "name": "browser_emulate_media", "arguments": { "colorScheme": "dark" } });
    let ok = handle_tool_call_with(&params, "owner", None, &ups);
    assert!(ok.is_ok(), "{ok:?}");
    assert_eq!(upstream.calls.load(Ordering::SeqCst), 1);
}

/// Round-4 F1: a routed call decides refusal from the cached list, so it never sends a tools/list.
#[test]
fn a_routed_call_does_not_list_the_upstream() {
    let upstream = CountingUpstream::new(recorded_tools());
    let ups: Vec<Arc<dyn Upstream>> = vec![upstream.clone()];
    let params = json!({ "name": "browser_navigate", "arguments": { "url": "https://a.test" } });
    let ok = handle_tool_call_with(&params, "owner", None, &ups);
    assert!(ok.is_ok(), "{ok:?}");
    assert_eq!(upstream.calls.load(Ordering::SeqCst), 1);
    assert_eq!(
        upstream.lists.load(Ordering::SeqCst),
        0,
        "a tools/call sent a tools/list"
    );
}

/// Round-4 F1: a refused tool in the cached list is still not routed, without a listing.
#[test]
fn a_cached_refused_tool_is_not_routed_and_not_listed() {
    let upstream = CountingUpstream::new(banned_upstream_tools());
    let ups: Vec<Arc<dyn Upstream>> = vec![upstream.clone()];
    for name in BANNED_NAMES {
        assert!(
            upstream_owning_with(name, "owner", &ups).is_none(),
            "{name} is routed"
        );
    }
    assert_eq!(upstream.lists.load(Ordering::SeqCst), 0);
}

/// Round-4 F2: a null is refused for any browser_emulate_media argument, including one a later
/// upstream adds, not only the five overrides of 0.0.82.
#[test]
fn emulate_media_null_for_a_sixth_property_is_refused() {
    let mut tools = recorded_tools();
    let media = tools
        .iter_mut()
        .find(|t| t["name"].as_str() == Some("browser_emulate_media"))
        .expect("fixture has browser_emulate_media");
    media["inputSchema"]["properties"]["zoom"] = json!({
        "anyOf": [{ "type": "string", "enum": ["in", "out"] }, { "type": "null" }]
    });
    let upstream = CountingUpstream::new(tools);
    let ups: Vec<Arc<dyn Upstream>> = vec![upstream.clone()];
    let params = json!({ "name": "browser_emulate_media", "arguments": { "zoom": null } });
    let refused = handle_tool_call_with(&params, "owner", None, &ups);
    let err = refused.expect_err("null is refused");
    assert_eq!(err.0, INVALID_PARAMS);
    assert_eq!(
        err.1,
        "Invalid params: browser_emulate_media: zoom cannot be null; omit it or send one of its enum values"
    );
    assert_eq!(upstream.calls.load(Ordering::SeqCst), 0);
}

/// Round-4 F3: a union with a branch other than null keeps its anyOf, so the tool is refused
/// instead of losing that branch.
#[test]
fn emulate_media_union_with_a_non_null_branch_is_refused_not_collapsed() {
    let tool = json!({ "name": "browser_emulate_media", "description": "fixture", "inputSchema": {
        "type": "object",
        "properties": { "zoom": { "anyOf": [{ "type": "string", "enum": ["in"] }, { "type": "number" }] } }
    } });
    let served = crate::mcp::forwarded_descriptor(tool);
    assert!(
        served["inputSchema"]["properties"]["zoom"]["anyOf"].is_array(),
        "a non-null branch was dropped: {served}"
    );
    assert_eq!(
        crate::mcp::schema_refusal(&served).as_deref(),
        Some("browser_emulate_media.properties.zoom.anyOf")
    );
}

/// Round-4 F3: a string-or-null union is still collapsed to its string branch.
#[test]
fn emulate_media_string_or_null_union_is_collapsed() {
    let tool = json!({ "name": "browser_emulate_media", "description": "fixture", "inputSchema": {
        "type": "object",
        "properties": { "zoom": { "anyOf": [{ "type": "string", "enum": ["in"] }, { "type": "null" }] } }
    } });
    let served = crate::mcp::forwarded_descriptor(tool);
    let zoom = &served["inputSchema"]["properties"]["zoom"];
    assert_eq!(zoom["type"], json!("string"));
    assert!(zoom.get("anyOf").is_none(), "{served}");
    assert_eq!(crate::mcp::schema_refusal(&served), None);
}

/// Round-4 F4: the draft-7 `dependencies` schema form is walked; its list form is not a schema.
#[test]
fn walks_dependencies_schema_form_and_skips_its_list_form() {
    let union = json!({ "type": "string", "anyOf": [{ "type": "string" }] });
    let value = json!({ "p": union, "q": ["r", "s"] });
    let schema = with_property_keyword("dependencies", value);
    assert_eq!(
        problems(&schema, "t"),
        vec!["t.properties.a.dependencies.p.anyOf".to_string()]
    );
}

/// Round-4 F4: the remaining single sub-schema keywords are walked.
#[test]
fn walks_additional_and_unevaluated_items_and_properties() {
    for keyword in [
        "additionalItems",
        "unevaluatedItems",
        "unevaluatedProperties",
        "contentSchema",
    ] {
        let value = json!({ "type": "string", "oneOf": [{ "type": "string" }] });
        let schema = with_property_keyword(keyword, value);
        assert_eq!(
            problems(&schema, "t"),
            vec![format!("t.properties.a.{keyword}.oneOf")],
            "{keyword}"
        );
    }
}

/// Round-4 F4: a keyword outside the known vocabulary fails closed, because it may hold a
/// sub-schema the walker would not enter.
#[test]
fn unknown_keyword_fails_closed() {
    let hidden = with_property_keyword("x-schema", json!({ "anyOf": [{ "type": "string" }] }));
    assert_eq!(
        problems(&hidden, "t"),
        vec!["t.properties.a.x-schema is not a known schema keyword".to_string()]
    );
    let nullable = with_property_keyword("nullable", json!(true));
    assert_eq!(
        problems(&nullable, "t"),
        vec!["t.properties.a.nullable is not a known schema keyword".to_string()]
    );
    for (keyword, value) in [("format", json!("uri")), ("$comment", json!("c"))] {
        let known = with_property_keyword(keyword, value);
        assert_eq!(problems(&known, "t"), Vec::<String>::new(), "{keyword}");
    }
}

/// Round-5 F1: `$dynamicRef` and `$recursiveRef` are banned (see `bans!`); their anchors stay
/// allowed, since an anchor does nothing without a reference.
#[test]
fn anchors_without_a_reference_are_allowed() {
    for keyword in ["$dynamicAnchor", "$recursiveAnchor"] {
        let schema = with_property_keyword(keyword, json!("meta"));
        assert_eq!(problems(&schema, "t"), Vec::<String>::new(), "{keyword}");
    }
}
