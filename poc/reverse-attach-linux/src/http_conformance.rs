//! `conformance/mcp_http_vectors.json` against `http::mcp_route`, the `/mcp`
//! handler after auth. The Swift `MCPHTTPEndpoint` is the oracle and runs the
//! same file in `HTTPConformanceTests`.

use serde_json::Value;

use crate::http::{mcp_route, McpReply, McpSessions};

const VECTORS: &str = include_str!("../../../conformance/mcp_http_vectors.json");

/// Subset match, same rules as the Swift runner. Unknown keys fail.
fn matches(reply: &McpReply, want: &Value) -> bool {
    let Some(w) = want.as_object() else {
        return false;
    };
    let body: Option<Value> = serde_json::from_str(&reply.body).ok();
    w.iter().all(|(key, value)| match key.as_str() {
        "status" => value.as_u64() == Some(u64::from(reply.status)),
        "session_header" => value.as_bool() == Some(reply.session_id.is_some()),
        "error" => {
            body.as_ref()
                .and_then(|b| b.get("error")?.get("code").cloned())
                == Some(value.clone())
        }
        "result" => {
            value.as_bool() == Some(body.as_ref().is_some_and(|b| b.get("result").is_some()))
        }
        "body_empty" => value.as_bool() == Some(reply.body.is_empty()),
        _ => false,
    })
}

#[test]
fn http_fixtures_match_the_swift_oracle() {
    let doc: Value = serde_json::from_str(VECTORS).unwrap();
    let cases = doc["cases"].as_array().unwrap();
    assert!(
        cases.len() >= 18,
        "http vector file shrank: {}",
        cases.len()
    );

    let mut failures = Vec::new();
    for c in cases {
        let name = c["name"].as_str().unwrap();
        let sessions = McpSessions::default();
        let mut issued: Option<String> = None;
        for (i, step) in c["steps"].as_array().unwrap().iter().enumerate() {
            let session = match step["session"].as_str() {
                Some("$issued") => issued.clone(),
                other => other.map(str::to_string),
            };
            let reply = mcp_route(
                step["method"].as_str().unwrap(),
                step["content_type"].as_str(),
                session.as_deref(),
                step["body"].as_str().unwrap_or("").as_bytes(),
                &sessions,
            );
            if reply.session_id.is_some() {
                issued = reply.session_id.clone();
            }
            let expect = &step["expect"];
            if !matches(&reply, expect) {
                failures.push(format!(
                    "{name} step {i}: got status {} session {:?} body {:?}, oracle wants {expect}",
                    reply.status, reply.session_id, reply.body
                ));
            }
        }
    }
    assert!(
        failures.is_empty(),
        "http conformance:\n{}",
        failures.join("\n")
    );
}
