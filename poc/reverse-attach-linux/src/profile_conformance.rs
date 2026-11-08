//! `conformance/profile_vectors.json` (#59) against the Linux profile code: the two
//! names, the default, `desktop` → `observe` with the warning, the 400 message,
//! persisted-grant resolution, per-profile local and upstream membership, tool
//! classes and shell-equivalence. The upstream half runs the real `tools/list` /
//! `tools/call` path against a loopback fake that serves the full `browser_*`
//! fixture. The Swift `ToolProfile` is the oracle (`ConformanceVectorTests.
//! testProfileVectors`, `BrowserProfileTests`).

use std::collections::BTreeSet;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};

use crate::attach::store;
use crate::mcp::{
    handle_tool_call_with, local_tool_allowed, local_tool_class, profile_is_shell_equivalent,
    tool_list_with, upstream_tool_allowed, ToolClass, Upstream, DEFAULT_PROFILE,
    DESKTOP_RETIRED_WARNING, INVALID_PARAMS, LOCAL_TOOL_CLASS, LOCAL_TOOL_NAMES, PROFILES,
    PROFILE_REJECTION,
};

const VECTORS: &str = include_str!("../../../conformance/profile_vectors.json");

fn doc() -> Value {
    serde_json::from_str(VECTORS).expect("profile_vectors.json is JSON")
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array()
        .expect("array")
        .iter()
        .map(|s| s.as_str().expect("string").to_string())
        .collect()
}

fn set(v: impl IntoIterator<Item = impl Into<String>>) -> BTreeSet<String> {
    v.into_iter().map(Into::into).collect()
}

#[test]
fn constants_match_the_vectors() {
    let d = doc();
    assert_eq!(strings(&d["profiles"]), PROFILES);
    assert_eq!(d["default_profile"], DEFAULT_PROFILE);
    assert_eq!(d["rejection_message"], PROFILE_REJECTION);
    assert_eq!(d["retired_warning"], DESKTOP_RETIRED_WARNING);
}

#[test]
fn local_tools_and_classes_match_the_vectors() {
    let d = doc();
    let local = strings(&d["local_tools"]["linux"]);
    assert_eq!(set(local.clone()), set(LOCAL_TOOL_NAMES.iter().copied()));
    assert_eq!(local.len(), LOCAL_TOOL_NAMES.len());
    let served: Vec<String> = tool_list_with("owner", &[])
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(set(served), set(local));

    let classes = d["tool_class"]["linux"].as_object().unwrap();
    let mut want: Vec<(String, ToolClass)> = Vec::new();
    for (name, tools) in classes {
        let class = match name.as_str() {
            "observe" => ToolClass::Observe,
            "act" => ToolClass::Act,
            "shell" => ToolClass::Shell,
            other => panic!("unknown class {other}"),
        };
        for t in strings(tools) {
            want.push((t, class));
        }
    }
    assert_eq!(want.len(), LOCAL_TOOL_CLASS.len());
    for (tool, class) in want {
        assert_eq!(local_tool_class(&tool), Some(class), "{tool}");
    }
}

#[test]
fn membership_matches_the_vectors() {
    let d = doc();
    let local = strings(&d["local_tools"]["linux"]);
    let mut upstream = strings(&d["upstream_fixture"]);
    assert_eq!(upstream.len(), 32);
    upstream.extend(strings(&d["unlisted_upstream"]));
    let served = d["served"].as_object().unwrap();
    assert_eq!(set(served.keys().cloned()), set(PROFILES.iter().copied()));
    for profile in PROFILES {
        let spec = &served[*profile];
        let pick = |key: &str, all: &[String]| -> BTreeSet<String> {
            if spec[key] == "all" {
                set(all.iter().cloned())
            } else {
                set(strings(&spec[key]))
            }
        };
        let got_local = set(local
            .iter()
            .filter(|t| local_tool_allowed(t, profile))
            .cloned());
        assert_eq!(got_local, pick("local", &local), "{profile} local");
        let got_up = set(upstream
            .iter()
            .filter(|t| upstream_tool_allowed(t, profile))
            .cloned());
        assert_eq!(got_up, pick("upstream", &upstream), "{profile} upstream");
        assert_eq!(
            profile_is_shell_equivalent(profile),
            spec["shell_equivalent"].as_bool().unwrap(),
            "{profile}"
        );
    }
}

#[test]
fn attach_requests_match_the_vectors() {
    let cases = doc()["attach_requests"].as_array().unwrap().clone();
    assert!(cases.len() >= 14);
    for c in cases {
        let name = c["name"].as_str().unwrap();
        let expect = &c["expect"];
        let got = crate::http::resolve_attach_profile(&c["body"]);
        if expect["status"] == 400 {
            assert_eq!(got, Err(PROFILE_REJECTION), "{name}");
            continue;
        }
        assert_eq!(expect["status"], 202, "{name}");
        let r = got.unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(r.profile, expect["profile"], "{name}");
        assert_eq!(r.requested, expect["requested_profile"], "{name}");
        let warning = expect["warning"].as_bool().unwrap();
        assert_eq!(
            r.warning,
            warning.then_some(DESKTOP_RETIRED_WARNING),
            "{name}"
        );
    }
}

#[test]
fn persisted_grants_match_the_vectors() {
    let now = 1_000_000;
    for c in doc()["persisted_grants"].as_array().unwrap() {
        let name = c["name"].as_str().unwrap();
        let mut row = json!({
            "id": "g", "runtime": "ws://127.0.0.1:1", "session": "s", "principal": "p",
            "expires_at_epoch_secs": now + 60, "secret": "k",
        });
        for (k, v) in c["stored"].as_object().unwrap() {
            row[k] = v.clone();
        }
        let file = json!({"version": 1, "grants": [row]}).to_string();
        let got = store::parse(&file, now).unwrap();
        let expect = &c["expect"];
        if expect["outcome"] == "drop" {
            assert!(got.is_empty(), "{name}: {got:?}");
            continue;
        }
        assert_eq!(got.len(), 1, "{name}");
        assert_eq!(got[0].profile, expect["profile"], "{name}");
        assert_eq!(
            got[0].requested_profile, expect["requested_profile"],
            "{name}"
        );
        assert_eq!(
            crate::mcp::profile_warning(&got[0].requested_profile).is_some(),
            expect["warning"].as_bool().unwrap(),
            "{name}"
        );
    }
}

/// A loopback MCP server playing `@playwright/mcp`: answers `initialize` with a
/// session id, `tools/list` with `tools`, and records every `tools/call` name.
fn fake_upstream(tools: Vec<String>) -> (String, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/mcp", listener.local_addr().unwrap());
    let calls = Arc::new(Mutex::new(Vec::new()));
    let seen = calls.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut buf = Vec::new();
            let mut chunk = [0u8; 4096];
            let body = loop {
                let Ok(n) = stream.read(&mut chunk) else {
                    break None;
                };
                if n == 0 {
                    break None;
                }
                buf.extend_from_slice(&chunk[..n]);
                let text = String::from_utf8_lossy(&buf).to_string();
                let Some(end) = text.find("\r\n\r\n") else {
                    continue;
                };
                let len = text[..end]
                    .lines()
                    .find_map(|l| {
                        let (k, v) = l.split_once(':')?;
                        k.eq_ignore_ascii_case("content-length")
                            .then(|| v.trim().parse::<usize>().ok())?
                    })
                    .unwrap_or(0);
                if buf.len() >= end + 4 + len {
                    break Some(text[end + 4..end + 4 + len].to_string());
                }
            };
            let Some(body) = body else { continue };
            let req: Value = serde_json::from_str(&body).unwrap_or(Value::Null);
            let id = req["id"].clone();
            let (status, extra, reply) = match req["method"].as_str().unwrap_or("") {
                "initialize" => (
                    "200 OK",
                    "Mcp-Session-Id: fake-sid\r\n",
                    json!({"jsonrpc": "2.0", "id": id, "result": {
                        "protocolVersion": "2025-06-18", "capabilities": {},
                        "serverInfo": {"name": "FakePlaywright", "version": "0"}}}),
                ),
                "notifications/initialized" => ("202 Accepted", "", Value::Null),
                "tools/list" => (
                    "200 OK",
                    "",
                    json!({"jsonrpc": "2.0", "id": id, "result": {"tools": tools.iter().map(|t| json!({
                        "name": t, "description": "fixture", "inputSchema": {"type": "object"}
                    })).collect::<Vec<_>>()}}),
                ),
                "tools/call" => {
                    let name = req["params"]["name"].as_str().unwrap_or("?").to_string();
                    seen.lock().unwrap().push(name.clone());
                    (
                        "200 OK",
                        "",
                        json!({"jsonrpc": "2.0", "id": id, "result": {
                            "content": [{"type": "text", "text": format!("did {name}")}], "isError": false}}),
                    )
                }
                _ => ("400 Bad Request", "", Value::Null),
            };
            let body = if reply.is_null() {
                String::new()
            } else {
                reply.to_string()
            };
            let _ = stream.write_all(
                format!(
                    "HTTP/1.1 {status}\r\nContent-Type: application/json\r\n{extra}Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .as_bytes(),
            );
        }
    });
    (url, calls)
}

fn listed(v: &Value) -> Vec<String> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap().to_string())
        .collect()
}

#[test]
fn owner_reaches_every_upstream_tool_and_observe_none() {
    let d = doc();
    let mut fixture = strings(&d["upstream_fixture"]);
    fixture.extend(strings(&d["unlisted_upstream"]));
    let (url, calls) = fake_upstream(fixture.clone());
    let ups = vec![Arc::new(Upstream {
        name: "browser".to_string(),
        url,
        session_id: Mutex::new(None),
        cache: Mutex::new(None),
    })];

    let owner = listed(&tool_list_with("owner", &ups));
    for t in &fixture {
        assert!(owner.contains(t), "owner skips {t}");
    }
    for t in LOCAL_TOOL_NAMES {
        assert!(owner.iter().any(|n| n == t), "owner hides local {t}");
    }
    for t in [
        "browser_run_code_unsafe",
        "browser_evaluate",
        "browser_something_new",
    ] {
        let r = handle_tool_call_with(&json!({"name": t, "arguments": {}}), "owner", None, &ups)
            .unwrap_or_else(|e| panic!("owner {t}: {e:?}"));
        assert_eq!(r["content"][0]["text"], format!("did {t}"));
        assert_eq!(calls.lock().unwrap().last().map(String::as_str), Some(t));
    }

    let before = calls.lock().unwrap().len();
    let observe = listed(&tool_list_with("observe", &ups));
    assert_eq!(set(observe), set(["sys_info", "screenshot"]));
    for t in &fixture {
        let err =
            handle_tool_call_with(&json!({"name": t, "arguments": {}}), "observe", None, &ups)
                .unwrap_err();
        assert_eq!(err.0, INVALID_PARAMS, "{t}");
        assert_eq!(err.1, format!("Invalid params: unknown tool: {t}"));
    }
    assert_eq!(
        calls.lock().unwrap().len(),
        before,
        "no observe call reached the upstream"
    );
}
