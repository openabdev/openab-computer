//! `sys_info`: what this node is. `host` / `displays` / `permissions` / `agent` are the
//! fields OpenAB Connect's Screens pane reads; the rest is ours.

use serde_json::{json, Value};

use crate::platform;

pub const AGENT_NAME: &str = "oab-computer-rpi";
/// The release version this binary reports (`sys_info.agent.version`, MCP `serverInfo`).
/// The release workflow sets `OAB_RELEASE_VERSION` from the tag, which it requires to equal
/// `let version` in `Sources/oab-computer/main.swift`, so the tag is the only source.
/// A build without it (local, `cargo test`) reports `<crate version>-dev`, never a release
/// number; the crate version in Cargo.toml is not bumped per release (#74).
pub const AGENT_VERSION: &str = match option_env!("OAB_RELEASE_VERSION") {
    Some(v) => v,
    None => concat!(env!("CARGO_PKG_VERSION"), "-dev"),
};

fn read_file_trim(path: &str) -> Option<String> {
    std::fs::read_to_string(path)
        .ok()
        .map(|s| s.trim().to_string())
}

pub fn tool_sys_info() -> Value {
    let pretty_name = std::fs::read_to_string("/etc/os-release")
        .ok()
        .and_then(|content| {
            content.lines().find_map(|line| {
                line.strip_prefix("PRETTY_NAME=")
                    .map(|v| v.trim().trim_matches('"').to_string())
            })
        })
        .unwrap_or_else(|| "unknown".to_string());

    let cpu_count = std::fs::read_to_string("/proc/cpuinfo")
        .map(|c| c.lines().filter(|l| l.starts_with("processor")).count())
        .unwrap_or(0);

    let mem_total = std::fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|content| {
            content
                .lines()
                .find_map(|line| line.strip_prefix("MemTotal:").map(|v| v.trim().to_string()))
        })
        .unwrap_or_else(|| "unknown".to_string());

    let hostname =
        read_file_trim("/proc/sys/kernel/hostname").unwrap_or_else(|| "unknown".to_string());

    let display_ok = platform::desktop().display_ok();
    json!({
        "host": hostname,
        "hostname": hostname,
        "os": pretty_name,
        "cpu_count": cpu_count,
        "mem_total": mem_total,
        "arch": std::env::consts::ARCH,
        "displays": if display_ok { json!([{ "index": 0, "kind": "wayland" }]) } else { json!([]) },
        "permissions": { "screen_recording": display_ok, "accessibility": false },
        "agent": { "name": AGENT_NAME, "version": AGENT_VERSION, "platform": "linux" }
    })
}
