//! Harness for the real end-to-end run (`OAB_L2_E2E=1`, `--ignored`). Not part of `cargo test`.
//!
//! It plays the daemon: started as the main process of a transient unit, it starts the managed
//! child through the production code (`Supervisor`, `Systemd`), speaks `initialize` and
//! `tools/list`, navigates to a `data:` URL, takes a snapshot, writes the transcript summary and
//! then waits to be killed with `SIGKILL`. The outer script proves that nothing survives.
//! Unit names use the `oab-l4-test-` prefix. No TCP listener is opened.

use std::io::Write;
use std::sync::Arc;
use std::time::Duration;

use serde_json::json;

use crate::child::{Config, Supervisor};
use crate::containment::{Availability, Mechanism, Systemd};

fn out(path: &str, line: &str) {
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .unwrap();
    writeln!(f, "{line}").unwrap();
}

#[test]
#[ignore = "real end-to-end harness; OAB_L2_E2E=1"]
fn e2e_daemon_harness() {
    let (Some(base), Some(log)) = (
        std::env::var_os("OAB_L2_E2E_BASE"),
        std::env::var("OAB_L2_E2E_OUT").ok(),
    ) else {
        return;
    };
    let base = std::path::PathBuf::from(base);
    let root = crate::state::Root::open(&base, false).unwrap().unwrap();
    let mut sd = Systemd::new(Some(root.abs_path().to_path_buf()), true);
    sd.selftest_prefix = format!("{}-selftest", crate::test_exec::TEST_UNIT_PREFIX);
    sd.browser_prefix = format!("{}-browser", crate::test_exec::TEST_UNIT_PREFIX);
    let mech: Arc<dyn Mechanism> = Arc::new(sd);
    let avail = Arc::new(Availability::new(mech));
    let mut cfg = Config::production(base);
    // Headless unless asked: the harness must not open a window on the host's own desktop.
    if std::env::var_os("OAB_L2_E2E_HEADED").is_none() {
        cfg.seat = Arc::new(|| None);
    }
    let sup = Supervisor::new(cfg, avail);
    let t = Duration::from_secs(120);
    let r = sup.call("tools/list", json!({}), t);
    let names: Vec<String> = match &r {
        Ok(v) => v["tools"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|t| t["name"].as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default(),
        Err(c) => {
            out(&log, &format!("TOOLS_LIST_FAILED {c}"));
            return;
        }
    };
    out(&log, &format!("CONTAINMENT {}", sup.containment()));
    out(&log, &format!("TOOLS {}", names.len()));
    let url = "data:text/html,<title>oab-l2</title><h1>hello-from-l2-e2e</h1><p>second-line</p>";
    let nav = sup.call(
        "tools/call",
        json!({"name": "browser_navigate", "arguments": {"url": url}}),
        t,
    );
    // The harness is test code on a scratch root: it may print the tool's own error text.
    let nav_err = nav.as_ref().ok().filter(|v| v["isError"] == true);
    out(
        &log,
        &format!(
            "NAVIGATE {}",
            match (&nav, nav_err) {
                (Err(c), _) => format!("failed {c}"),
                (Ok(_), Some(v)) => format!(
                    "tool_error {}",
                    v["content"][0]["text"]
                        .as_str()
                        .unwrap_or("")
                        .chars()
                        .take(600)
                        .collect::<String>()
                        .replace('\n', " | ")
                ),
                _ => "ok".to_string(),
            }
        ),
    );
    let snap = sup.call(
        "tools/call",
        json!({"name": "browser_snapshot", "arguments": {}}),
        t,
    );
    let text = snap
        .as_ref()
        .ok()
        .and_then(|v| v["content"][0]["text"].as_str().map(str::to_string))
        .unwrap_or_default();
    out(
        &log,
        &format!("SNAPSHOT_HAS_TEXT {}", text.contains("hello-from-l2-e2e")),
    );
    out(&log, &format!("LEADER {}", sup.leader_pid().unwrap_or(0)));
    out(&log, &format!("DISPLAY {}", sup.display()));
    out(&log, &format!("READY {}", std::process::id()));
    // Wait to be killed. A graceful end would clean up; the proof wants `kill -9`.
    std::thread::sleep(Duration::from_secs(900));
}

/// One router case against the production code path of `serve()` minus the HTTP listener: the
/// environment decides, `sys_info.browser` is printed, and the tool count is read. Run as the main
/// process of a transient unit (so the managed backend can verify) with the case's variables.
#[test]
#[ignore = "real end-to-end router case; OAB_L2_E2E=1"]
fn e2e_router_case() {
    let Some(log) = std::env::var("OAB_L2_E2E_OUT").ok() else {
        return;
    };
    let base = crate::state::Root::default_base().unwrap();
    let env = crate::backend::EnvIn::from_env();
    let ups = crate::backend::build_with(&env, &base, &|data_root| {
        let mut sd = Systemd::new(data_root, true);
        sd.selftest_prefix = format!("{}-selftest", crate::test_exec::TEST_UNIT_PREFIX);
        sd.browser_prefix = format!("{}-browser", crate::test_exec::TEST_UNIT_PREFIX);
        Arc::new(sd)
    });
    // The background verification is done within a few seconds.
    for _ in 0..100 {
        let v = crate::backend::sys_info_field();
        if v["reason"] != "containment_pending" {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    out(&log, &format!("UPSTREAMS {}", ups.len()));
    let tools = crate::mcp::tool_list_with("owner", &ups);
    let n = tools
        .as_array()
        .map(|a| {
            a.iter()
                .filter(|t| {
                    t["name"]
                        .as_str()
                        .is_some_and(|n| n.starts_with("browser_"))
                })
                .count()
        })
        .unwrap_or(0);
    out(&log, &format!("BROWSER_TOOLS_FOR_OWNER {n}"));
    out(
        &log,
        &format!("SYS_INFO_BROWSER {}", crate::backend::sys_info_field()),
    );
}
