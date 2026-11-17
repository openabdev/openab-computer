//! The headless health check of a staged Playwright MCP over stdio (R3.1; L1b). Counterpart of the
//! Swift `PlaywrightInstaller.healthCheck`, with the same identity rule: the server's `serverInfo`
//! name must contain "playwright" (case-insensitive), `tools/list` must hold every `browser_*` name,
//! and one `browser_navigate` to `about:blank` must succeed, because `initialize` and `tools/list`
//! never start Chromium.
//!
//! Wire: newline-delimited JSON-RPC on the child's stdin and stdout. A line is at most 8 MiB, every
//! wait has a deadline, and the cancel flag is looked at every 100 ms. stderr stays in the child's
//! ring and only a yes/no class leaves. No tool output or stderr text is copied into any message.
//! L2's long-lived client replaces this one.

use std::path::Path;
use std::sync::mpsc::RecvTimeoutError;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::catalog::BROWSER_TOOLS;
use crate::proc::{Child, Line, Spec, StderrClass};

pub const MAX_LINE: usize = 8 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    Check,
    Refused,
    Cancelled,
}

impl Failure {
    pub fn class(self) -> &'static str {
        match self {
            Failure::Check => "health_check_failed",
            Failure::Refused => "launch_refused",
            Failure::Cancelled => "cancelled",
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Timeouts {
    pub initialize: Duration,
    pub call: Duration,
    pub close: Duration,
}

impl Default for Timeouts {
    fn default() -> Timeouts {
        Timeouts {
            initialize: Duration::from_secs(15),
            call: Duration::from_secs(60),
            close: Duration::from_secs(15),
        }
    }
}

/// The launch vector, headless, with no `--port`, `--host`, `--allowed-hosts` or `--no-sandbox`:
/// Playwright adds `--no-sandbox` to Chromium unless the server is started with `--sandbox`, so the
/// flag is passed, and a host that cannot run Chromium's sandbox is found here, not at the first
/// agent call. `staging` is absolute and `HOME` is a private directory inside it. `tmp` is a short
/// private directory: Chromium puts a Unix socket below `TMPDIR`, and a socket path over about 100
/// bytes is refused, which the staging path alone would exceed.
pub fn launch_spec(
    node: &Path,
    cli: &Path,
    chromium: &Path,
    profile: &Path,
    output: &Path,
    staging: &Path,
    tmp: &Path,
) -> Spec {
    let s = |p: &Path| p.to_string_lossy().into_owned();
    Spec {
        exe: node.to_path_buf(),
        args: vec![
            s(cli),
            "--user-data-dir".into(),
            s(profile),
            "--output-dir".into(),
            s(output),
            "--idle-timeout".into(),
            "1800000".into(),
            "--browser".into(),
            "chromium".into(),
            "--executable-path".into(),
            s(chromium),
            "--shared-browser-context".into(),
            "--caps".into(),
            "vision,pdf".into(),
            "--sandbox".into(),
            "--headless".into(),
        ],
        env: vec![
            ("HOME".into(), s(&staging.join("home"))),
            ("TMPDIR".into(), s(tmp)),
            ("LANG".into(), "C.UTF-8".into()),
            (
                "PATH".into(),
                format!(
                    "{}:/usr/bin:/bin",
                    s(node.parent().unwrap_or(Path::new("/")))
                ),
            ),
        ],
        cwd: staging.to_path_buf(),
    }
}

#[derive(Debug, PartialEq, Eq)]
enum RpcError {
    Timeout,
    Exited,
    TooLong,
    Protocol,
    Server,
    Cancelled,
}

struct Rpc<'a> {
    child: &'a mut Child,
    next: u64,
}

impl Rpc<'_> {
    fn send(&mut self, v: &Value) -> Result<(), RpcError> {
        use std::io::Write;
        let stdin = self.child.stdin.as_mut().ok_or(RpcError::Exited)?;
        let mut line = v.to_string();
        line.push('\n');
        stdin
            .write_all(line.as_bytes())
            .and_then(|_| stdin.flush())
            .map_err(|_| RpcError::Exited)
    }

    fn notify(&mut self, method: &str) -> Result<(), RpcError> {
        self.send(&json!({"jsonrpc": "2.0", "method": method}))
    }

    /// One request; returns `result`. Notifications and answers to other ids are skipped, with a
    /// bound on how many lines that may take.
    fn call(&mut self, method: &str, params: Value, timeout: Duration) -> Result<Value, RpcError> {
        self.next += 1;
        let id = self.next;
        self.send(&json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}))?;
        let deadline = Instant::now() + timeout;
        let mut skipped = 0;
        loop {
            if crate::cancel::is_cancelled() {
                return Err(RpcError::Cancelled);
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(RpcError::Timeout);
            }
            let rx = self.child.lines.as_ref().ok_or(RpcError::Exited)?;
            let wait = (deadline - now).min(Duration::from_millis(100));
            let line = match rx.recv_timeout(wait) {
                Ok(l) => l,
                Err(RecvTimeoutError::Timeout) => continue,
                Err(RecvTimeoutError::Disconnected) => return Err(RpcError::Exited),
            };
            let bytes = match line {
                Line::Data(b) => b,
                Line::TooLong => return Err(RpcError::TooLong),
                Line::Eof => return Err(RpcError::Exited),
            };
            let Ok(v) = serde_json::from_slice::<Value>(&bytes) else {
                skipped += 1;
                if skipped > 1000 {
                    return Err(RpcError::Protocol);
                }
                continue;
            };
            if v.get("id").and_then(Value::as_u64) != Some(id) || v.get("method").is_some() {
                skipped += 1;
                if skipped > 1000 {
                    return Err(RpcError::Protocol);
                }
                continue;
            }
            if v.get("error").is_some() {
                return Err(RpcError::Server);
            }
            return v.get("result").cloned().ok_or(RpcError::Protocol);
        }
    }
}

fn identity_ok(init: &Value) -> bool {
    init.get("serverInfo")
        .and_then(|s| s.get("name"))
        .and_then(Value::as_str)
        .is_some_and(|n| n.to_lowercase().contains("playwright"))
}

fn tools_ok(list: &Value) -> bool {
    let Some(arr) = list.get("tools").and_then(Value::as_array) else {
        return false;
    };
    let names: Vec<&str> = arr
        .iter()
        .filter_map(|t| t.get("name").and_then(Value::as_str))
        .collect();
    BROWSER_TOOLS.iter().all(|n| names.contains(n))
}

fn is_error_result(r: &Value) -> bool {
    r.get("isError").and_then(Value::as_bool) == Some(true)
}

/// Runs the whole check. `scope` is the staging directory, so a detached grandchild whose
/// executable is below it is killed with the rest of the tree before this returns.
#[cfg(test)]
pub fn check(spec: &Spec, scope: &Path, t: &Timeouts) -> Result<(), Failure> {
    check_with(
        Child::spawn(spec, true, true, MAX_LINE, scope).map(crate::sigstop::Launched::plain),
        t,
    )
}

/// [`check`] over a child that the caller started (`sigstop::Launcher`: a transient unit when the
/// mechanism verifies). The child, its unit and its run record end before this returns.
pub fn check_with(
    launched: std::io::Result<crate::sigstop::Launched>,
    t: &Timeouts,
) -> Result<(), Failure> {
    let mut launched = launched.map_err(|_| Failure::Check)?;
    let result = {
        let mut rpc = Rpc {
            child: &mut launched.child,
            next: 0,
        };
        steps(&mut rpc, t)
    };
    let refused = launched.child.stderr_class() == StderrClass::LaunchRefused;
    launched.child.stop();
    drop(launched);
    match result {
        Ok(()) => Ok(()),
        Err(RpcError::Cancelled) => Err(Failure::Cancelled),
        Err(_) if refused => Err(Failure::Refused),
        Err(_) => Err(Failure::Check),
    }
}

fn steps(rpc: &mut Rpc<'_>, t: &Timeouts) -> Result<(), RpcError> {
    let init = rpc.call(
        "initialize",
        json!({
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "oab-computer", "version": "browser"},
        }),
        t.initialize,
    )?;
    rpc.notify("notifications/initialized")?;
    // The pinned package identifies itself as Playwright; anything else is not what was pinned.
    if !identity_ok(&init) {
        return Err(RpcError::Protocol);
    }
    let list = rpc.call("tools/list", json!({}), t.call)?;
    if !tools_ok(&list) {
        return Err(RpcError::Protocol);
    }
    // Neither of the two calls above starts Chromium. One navigation does.
    let nav = rpc.call(
        "tools/call",
        json!({"name": "browser_navigate", "arguments": {"url": "about:blank"}}),
        t.call,
    )?;
    if is_error_result(&nav) {
        return Err(RpcError::Protocol);
    }
    let _ = rpc.call(
        "tools/call",
        json!({"name": "browser_close", "arguments": {}}),
        t.close,
    );
    Ok(())
}

#[cfg(test)]
#[path = "health_tests.rs"]
mod tests;
