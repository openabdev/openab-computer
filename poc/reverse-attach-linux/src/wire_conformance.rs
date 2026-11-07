//! `conformance/mcp_wire_vectors.json` against `mcp::answer` (`POST /mcp`) and
//! `mcp::answer_attached` (a reverse-attach socket). The Swift `MCPServer` is
//! the oracle. A case the Rust port gets wrong is pinned in `known_drift` with
//! the output it returns today, so the drift stays visible and any change to it
//! (fixed or worse) fails this test. The list is empty since #78.

use std::sync::atomic::AtomicBool;

use serde_json::Value;

use crate::mcp::{answer, answer_attached};

const VECTORS: &str = include_str!("../../../conformance/mcp_wire_vectors.json");

/// The two ways a frame reaches the dispatcher: `POST /mcp` (`answer`) and a
/// reverse-attach socket (`answer_attached`). Swift runs both through the same
/// `MCPServer.parse` + `handle`, so every case must hold on both.
#[derive(Clone, Copy, Debug)]
enum Path {
    Http,
    Attached,
}

/// What a client sees for one raw request, in the vocabulary the fixture uses.
fn observe(request: &str, profile: &str, path: Path) -> Value {
    let cancel = AtomicBool::new(false);
    let reply = match path {
        Path::Http => answer(request, profile),
        Path::Attached => answer_attached(request, profile, &cancel),
    };
    match reply {
        None => serde_json::json!({ "response": false }),
        Some(text) => {
            let v: Value = serde_json::from_str(&text).expect("answer() returns JSON");
            let mut o = serde_json::json!({ "response": true });
            if let Some(code) = v.get("error").and_then(|e| e.get("code")) {
                o["error"] = code.clone();
            }
            if let Some(result) = v.get("result") {
                o["result"] = result.clone();
            }
            o
        }
    }
}

/// Subset match, same rules as the Swift runner. Unknown keys fail.
fn matches(obs: &Value, want: &Value) -> bool {
    let Some(w) = want.as_object() else {
        return false;
    };
    w.iter().all(|(key, value)| match key.as_str() {
        "response" | "error" => obs.get(key) == Some(value),
        "result_subset" => match (
            obs.get("result").and_then(Value::as_object),
            value.as_object(),
        ) {
            (Some(res), Some(sub)) => sub.iter().all(|(k, v)| res.get(k) == Some(v)),
            _ => false,
        },
        "result_tools_shape" => obs["result"]["tools"].as_array().is_some_and(|tools| {
            !tools.is_empty()
                && tools.iter().all(|t| {
                    t["name"].is_string()
                        && t["description"].is_string()
                        && t["inputSchema"].is_object()
                })
        }),
        _ => false,
    })
}

#[test]
fn wire_fixtures_match_the_swift_oracle_and_pin_known_drift() {
    let doc: Value = serde_json::from_str(VECTORS).unwrap();
    let cases = doc["cases"].as_array().unwrap();
    let drift = doc["known_drift"].as_array().unwrap();
    assert!(
        cases.len() >= 20,
        "wire vector file shrank: {}",
        cases.len()
    );

    let mut failures = Vec::new();
    for c in cases {
        let name = c["name"].as_str().unwrap();
        let request = c["request"].as_str().unwrap();
        let profile = c["profile"].as_str().unwrap_or("owner");
        let expect = &c["expect"];
        for path in [Path::Http, Path::Attached] {
            let obs = observe(request, profile, path);
            let name = format!("{name} ({path:?})");
            match drift.iter().find(|d| d["name"] == c["name"]) {
                None => {
                    if !matches(&obs, expect) {
                        failures.push(format!("{name}: got {obs}, oracle wants {expect}"));
                    }
                }
                Some(d) => {
                    let pinned = &d["rust_today"];
                    if !matches(&obs, pinned) {
                        failures.push(format!(
                            "{name}: known drift changed: got {obs}, pinned {pinned}"
                        ));
                    }
                    if matches(&obs, expect) {
                        failures.push(format!(
                            "{name}: now matches the oracle; remove it from known_drift"
                        ));
                    }
                }
            }
        }
    }
    for d in drift {
        if !cases.iter().any(|c| c["name"] == d["name"]) {
            failures.push(format!(
                "known_drift names a case that does not exist: {}",
                d["name"]
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "wire conformance:\n{}",
        failures.join("\n")
    );
}
