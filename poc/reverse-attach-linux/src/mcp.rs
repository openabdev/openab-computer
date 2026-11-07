//! MCP JSON-RPC dispatch (`initialize`, `tools/list`, `tools/call`), the local tool table, and re-serving an upstream MCP (e.g. @playwright/mcp) filtered by profile.

use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};

use crate::http::{http_post, parse_mcp_body, HttpReply};
use crate::jobs::tools::JOB_TOOL_NAMES;
use crate::tools::sysinfo::AGENT_VERSION;
use crate::tools::{tool_bash, tool_key, tool_mouse, tool_result, tool_screenshot, tool_sys_info};

// Upstream MCP (e.g. @playwright/mcp on loopback), re-served under our tools/list.
// Mirrors Swift `UpstreamMCP`: Streamable HTTP request/response, session id held
// here and re-established on 400/404, tools cached 30 s, down → tools absent.
// ---------------------------------------------------------------------------

pub(crate) struct Upstream {
    pub(crate) name: String,
    pub(crate) url: String,
    pub(crate) session_id: Mutex<Option<String>>,
    pub(crate) cache: Mutex<Option<(std::time::Instant, Vec<Value>)>>,
}

impl Upstream {
    /// MCP_UPSTREAM="browser=http://127.0.0.1:8794/mcp[,name=url...]"
    pub(crate) fn from_env() -> Vec<Arc<Upstream>> {
        std::env::var("MCP_UPSTREAM")
            .unwrap_or_default()
            .split(',')
            .filter_map(|e| e.trim().split_once('='))
            .map(|(n, u)| {
                Arc::new(Upstream {
                    name: n.trim().to_string(),
                    url: u.trim().to_string(),
                    session_id: Mutex::new(None),
                    cache: Mutex::new(None),
                })
            })
            .collect()
    }

    fn post(&self, msg: &Value) -> Result<HttpReply, String> {
        let sid = self.session_id.lock().ok().and_then(|g| g.clone());
        let mut headers: Vec<(&str, &str)> = vec![
            ("Content-Type", "application/json"),
            ("Accept", "application/json, text/event-stream"),
        ];
        if let Some(s) = sid.as_deref() {
            headers.push(("Mcp-Session-Id", s));
        }
        http_post(
            &self.url,
            &headers,
            &msg.to_string(),
            Duration::from_secs(90),
        )
    }

    fn initialize(&self) -> Result<(), String> {
        // Never send a stale id on initialize: the upstream answers 404 to it.
        if let Ok(mut g) = self.session_id.lock() {
            *g = None;
        }
        let r = self.post(&json!({
            "jsonrpc": "2.0", "id": 0, "method": "initialize",
            "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                       "clientInfo": {"name": "instance-mcp-rpi", "version": AGENT_VERSION}}
        }))?;
        if !(200..300).contains(&r.status) {
            return Err(format!(
                "upstream {} initialize HTTP {}",
                self.name, r.status
            ));
        }
        let sid = r
            .headers
            .iter()
            .find(|(k, _)| k == "mcp-session-id")
            .map(|(_, v)| v.clone());
        if let Ok(mut g) = self.session_id.lock() {
            *g = sid;
        }
        let _ = self.post(&json!({"jsonrpc": "2.0", "method": "notifications/initialized"}));
        if let Ok(mut c) = self.cache.lock() {
            *c = None;
        }
        Ok(())
    }

    pub(crate) fn rpc(&self, method: &str, params: Option<Value>) -> Result<Value, String> {
        if self
            .session_id
            .lock()
            .ok()
            .map(|g| g.is_none())
            .unwrap_or(true)
        {
            self.initialize()?;
        }
        let mut msg = json!({"jsonrpc": "2.0", "id": 1, "method": method});
        if let Some(p) = &params {
            msg["params"] = p.clone();
        }
        let mut r = self.post(&msg)?;
        if r.status == 404 || r.status == 400 {
            // Upstream lost our session (restart). One re-init, one retry.
            self.initialize()?;
            r = self.post(&msg)?;
        }
        if !(200..300).contains(&r.status) {
            return Err(format!(
                "upstream {} HTTP {}: {}",
                self.name,
                r.status,
                &r.body[..r.body.len().min(120)]
            ));
        }
        let v = parse_mcp_body(&r.body)?;
        if let Some(e) = v.get("error") {
            return Err(format!("upstream {} error: {e}", self.name));
        }
        Ok(v.get("result").cloned().unwrap_or(Value::Null))
    }

    pub(crate) fn tools(&self) -> Vec<Value> {
        if let Ok(c) = self.cache.lock() {
            if let Some((at, t)) = c.as_ref() {
                if at.elapsed() < Duration::from_secs(30) {
                    return t.clone();
                }
            }
        }
        let list = match self.rpc("tools/list", None) {
            Ok(r) => r
                .get("tools")
                .and_then(|t| t.as_array())
                .cloned()
                .unwrap_or_default(),
            Err(e) => {
                eprintln!("upstream {}: {e}", self.name);
                // Do not cache a failure: the next tools/list retries immediately.
                if let Ok(mut c) = self.cache.lock() {
                    *c = None;
                }
                return Vec::new();
            }
        };
        if let Ok(mut c) = self.cache.lock() {
            *c = Some((std::time::Instant::now(), list.clone()));
        }
        list
    }
}

/// Same list as Swift `ToolProfile.desktopBrowserTools`: navigate / read / interact.
/// Everything else from the upstream (evaluate / run_code_unsafe = arbitrary JS, upload,
/// pdf, network, raw mouse-by-coordinate, dialogs, close, and any new tool) is denied
/// under `desktop`.
pub(crate) const DESKTOP_BROWSER_TOOLS: &[&str] = &[
    "browser_click",
    "browser_console_messages",
    "browser_fill_form",
    "browser_find",
    "browser_hover",
    "browser_navigate",
    "browser_navigate_back",
    "browser_press_key",
    "browser_resize",
    "browser_select_option",
    "browser_snapshot",
    "browser_tabs",
    "browser_take_screenshot",
    "browser_type",
    "browser_wait_for",
];

pub(crate) fn upstream_tool_allowed(name: &str, profile: &str) -> bool {
    match normalize_profile(profile) {
        Some("owner") => true,
        Some("desktop") => DESKTOP_BROWSER_TOOLS.contains(&name),
        // observe: look only; no upstream (browser) tool is an observation of this node.
        _ => false,
    }
}

/// Local tools `observe` may call: look, never act (instance-mcp#45).
pub(crate) const OBSERVE_TOOLS: &[&str] = &["sys_info", "screenshot"];

/// What a tool can do, as far as a boundary is concerned (same classes as the
/// Swift `ToolProfile.ToolClass`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ToolClass {
    /// Reads only; changes nothing.
    Observe,
    /// Changes state, but cannot run code as the desktop user.
    #[allow(dead_code)]
    Act,
    /// Reaches the desktop user's shell, directly or by driving the GUI.
    #[cfg_attr(not(test), allow(dead_code))]
    Shell,
}

/// Every local tool, classified. Exhaustive by test: a tool in `LOCAL_TOOL_NAMES`
/// (or served by `tool_list`) without an entry here fails `profile_tests`, so a new
/// tool cannot pass the boundary check just by not being listed as dangerous.
pub(crate) const LOCAL_TOOL_CLASS: &[(&str, ToolClass)] = &[
    ("sys_info", ToolClass::Observe),
    ("screenshot", ToolClass::Observe),
    ("bash", ToolClass::Shell),
    ("mouse", ToolClass::Shell), // can open a terminal
    ("key", ToolClass::Shell),   // can type into one
    ("exec_start", ToolClass::Shell),
    ("exec_poll", ToolClass::Shell), // reads what a shell job printed
    ("exec_list", ToolClass::Shell), // lists shell command lines
    ("exec_cancel", ToolClass::Shell),
];

/// Shell tools only `owner` gets, like the Swift `exec*` (#32 item 4). `desktop`
/// keeps `bash` (see `tool_list`), so this narrows the list, not the privilege.
pub(crate) const OWNER_ONLY_TOOLS: &[&str] = JOB_TOOL_NAMES;

pub(crate) fn local_tool_class(name: &str) -> Option<ToolClass> {
    LOCAL_TOOL_CLASS
        .iter()
        .find(|(n, _)| *n == name)
        .map(|(_, c)| *c)
}

/// Whether a profile honestly grants the node user's shell (instance-mcp#45).
#[cfg(test)]
pub(crate) fn profile_is_shell_equivalent(profile: &str) -> bool {
    matches!(normalize_profile(profile), Some("owner") | Some("desktop"))
}

/// Whether a local tool is visible/callable under `profile`.
pub(crate) fn local_tool_allowed(name: &str, profile: &str) -> bool {
    match normalize_profile(profile) {
        Some("owner") => true,
        Some("desktop") => !OWNER_ONLY_TOOLS.contains(&name),
        // Both: on the allowlist *and* classified as observation. A tool added to the
        // allowlist by mistake is still refused unless it was also classified as
        // changing nothing.
        Some("observe") => {
            OBSERVE_TOOLS.contains(&name) && local_tool_class(name) == Some(ToolClass::Observe)
        }
        _ => false,
    }
}

/// `owner` | `desktop` | `observe`. The old name `sandbox` is refused like any unknown
/// profile (instance-mcp#45): it promised a boundary that does not exist.
pub(crate) fn normalize_profile(profile: &str) -> Option<&'static str> {
    match profile {
        "owner" => Some("owner"),
        "desktop" => Some("desktop"),
        "observe" => Some("observe"),
        _ => None,
    }
}

pub(crate) static UPSTREAMS: Mutex<Vec<Arc<Upstream>>> = Mutex::new(Vec::new());

pub(crate) fn upstreams() -> Vec<Arc<Upstream>> {
    UPSTREAMS.lock().map(|g| g.clone()).unwrap_or_default()
}

/// Upstream tools visible to `profile`, excluding names that collide with local tools.
pub(crate) fn upstream_tools_for(
    profile: &str,
    local_names: &[&str],
) -> Vec<(Arc<Upstream>, Value)> {
    let mut out = Vec::new();
    for up in upstreams() {
        for t in up.tools() {
            let Some(name) = t.get("name").and_then(|n| n.as_str()) else {
                continue;
            };
            if local_names.contains(&name) || !upstream_tool_allowed(name, profile) {
                continue;
            }
            out.push((up.clone(), t));
        }
    }
    out
}

pub(crate) fn upstream_owning(name: &str, profile: &str) -> Option<Arc<Upstream>> {
    if !upstream_tool_allowed(name, profile) {
        return None;
    }
    upstreams().into_iter().find(|up| {
        up.tools()
            .iter()
            .any(|t| t.get("name").and_then(|n| n.as_str()) == Some(name))
    })
}

// ---------------------------------------------------------------------------
// answer(): MCP JSON-RPC dispatch
// ---------------------------------------------------------------------------

pub(crate) fn answer(text: &str, profile: &str) -> Option<String> {
    answer_with(text, profile, None)
}

/// The longest `bash` `timeout_secs` accepted on a reverse attach. The
/// openab-pty runtime fails any call that has no reply after 120 s
/// (`REQUEST_TIMEOUT`), so a longer one could only end in an error for the
/// caller.
pub(crate) const MAX_ATTACHED_BASH_TIMEOUT_SECS: u64 = 100;

/// `answer` for a frame on a reverse-attach socket: `cancel` is set when that
/// socket ends (a running `bash` then kills its process group), and a `bash`
/// with `timeout_secs` over `MAX_ATTACHED_BASH_TIMEOUT_SECS` is refused.
pub(crate) fn answer_attached(text: &str, profile: &str, cancel: &AtomicBool) -> Option<String> {
    answer_with(text, profile, Some(cancel))
}

fn answer_with(text: &str, profile: &str, cancel: Option<&AtomicBool>) -> Option<String> {
    let req: Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(_) => return None,
    };

    // Notifications have no id -> no response.
    let id = req.get("id").cloned()?;

    let method = req.get("method").and_then(|m| m.as_str()).unwrap_or("");
    let params = req.get("params").cloned().unwrap_or(Value::Null);

    let result: Result<Value, (i64, String)> = match method {
        "initialize" => Ok(json!({
            "protocolVersion": "2024-11-05",
            "capabilities": { "tools": {} },
            "serverInfo": {
                "name": "instance-mcp-rpi",
                "version": AGENT_VERSION
            },
            "instructions": instructions(profile)
        })),
        "tools/list" => Ok(json!({ "tools": tool_list(profile) })),
        "tools/call" => match cancel.and_then(|_| refuse_long_bash(&params, profile)) {
            Some(refusal) => Ok(refusal),
            None => handle_tool_call(&params, profile, cancel),
        },
        other => Err((-32601, format!("method not found: {other}"))),
    };

    let response = match result {
        Ok(res) => json!({ "jsonrpc": "2.0", "id": id, "result": res }),
        Err((code, message)) => json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": { "code": code, "message": message }
        }),
    };

    Some(response.to_string())
}

/// Every profile is told how long a call may run: the runtime fails a call with
/// no reply after 120 s, and older clients were dropped during long calls (#70).
const LONG_CALL_NOTICE: &str = "Keep each tool call on this node under about 60 seconds: a \
    longer call can time out or disconnect you.";

/// For profiles with the job tools: how to do long work without one long call.
const LONG_WORK_JOBS_NOTICE: &str = "For long work use `exec_start`, then check it with \
    `exec_poll` (pass the returned offsets to get only new output); a job keeps running if this \
    attach drops. Never `sleep` inside `bash`.";

/// For profiles with `bash` but no job tools (`desktop`).
const LONG_WORK_NOTICE: &str = "For long work, start it in the background with `bash` (for \
    example `nohup cmd > /tmp/job.log 2>&1 &`) and check on it with short `bash` calls; never \
    `sleep` inside `bash`.";

/// Calls on one attach run concurrently (#70), so parallel input calls can
/// interleave on the screen.
const UI_ORDER_NOTICE: &str = "Tool calls run concurrently: issue `mouse` and `key` steps one at \
    a time and wait for each result before sending the next.";

pub(crate) fn instructions(profile: &str) -> String {
    if local_tool_allowed("exec_start", profile) {
        format!("{UI_ORDER_NOTICE}\n\n{LONG_CALL_NOTICE} {LONG_WORK_JOBS_NOTICE}")
    } else if local_tool_allowed("bash", profile) {
        format!("{UI_ORDER_NOTICE}\n\n{LONG_CALL_NOTICE} {LONG_WORK_NOTICE}")
    } else {
        LONG_CALL_NOTICE.to_string()
    }
}

/// A `bash` call over `MAX_ATTACHED_BASH_TIMEOUT_SECS` on an attach, refused as
/// a tool error the model sees rather than clamped, so a long command is not
/// killed early by surprise.
fn refuse_long_bash(params: &Value, profile: &str) -> Option<Value> {
    if params.get("name").and_then(|n| n.as_str()) != Some("bash") {
        return None;
    }
    let asked = params
        .get("arguments")
        .and_then(|a| a.get("timeout_secs"))
        .and_then(|t| t.as_f64())?;
    if asked <= MAX_ATTACHED_BASH_TIMEOUT_SECS as f64 {
        return None;
    }
    let how = if local_tool_allowed("exec_start", profile) {
        "For long work start it in the background with exec_start, then check it with exec_poll; \
         never sleep inside bash."
    } else {
        "For long work start the command in the background (nohup cmd > /tmp/job.log 2>&1 &) and \
         check on it with short bash calls; never sleep inside bash."
    };
    let message = format!(
        "bash timeout_secs {asked} is over this attach's limit of {MAX_ATTACHED_BASH_TIMEOUT_SECS} s: \
         the runtime fails any call still running after 120 s. {how}"
    );
    Some(json!({
        "content": [ { "type": "text", "text": message } ],
        "isError": true
    }))
}

pub(crate) const LOCAL_TOOL_NAMES: &[&str] = &[
    "sys_info",
    "screenshot",
    "bash",
    "mouse",
    "key",
    "exec_start",
    "exec_poll",
    "exec_list",
    "exec_cancel",
];

pub(crate) fn tool_list(profile: &str) -> Value {
    let sys_info = json!({
        "name": "sys_info",
        "description": "Report OS, CPU, memory, architecture and hostname of this node.",
        "inputSchema": { "type": "object", "properties": {}, "additionalProperties": false }
    });
    let screenshot = json!({
        "name": "screenshot",
        "description": "Capture the node's Wayland display (via grim) and return it as an image. \
                        Default PNG at scale 0.5 (960x540 for a 1080p output). jpeg only if the \
                        node's grim was built with JPEG support (Debian's is not).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "scale":   { "type": "number", "description": "output scale factor, default 0.5" },
                "format":  { "type": "string", "enum": ["jpeg", "png"], "description": "default png" },
                "quality": { "type": "integer", "description": "jpeg quality 1-100, default 80" }
            },
            "additionalProperties": false
        }
    });
    let bash = json!({
        "name": "bash",
        "description": "Run a command with `bash -c` on this node as the daemon user. Returns stdout, \
                        stderr, exit code and duration. The whole process group is killed on timeout \
                        (exit 137, timed_out=true). Output is capped per stream.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "command":          { "type": "string" },
                "cwd":              { "type": "string", "description": "working directory; leading ~ expands to $HOME" },
                "timeout_secs":     { "type": "integer", "description": "default 60, max 600 (100 on a reverse attach; run longer work in the background)" },
                "max_output_bytes": { "type": "integer", "description": "per stream, default 65536, max 1048576" }
            },
            "required": ["command"],
            "additionalProperties": false
        }
    });

    let mouse = json!({
        "name": "mouse",
        "description": "Pointer input on this node's Wayland display (wlroots virtual pointer). Coordinates \
                        are display pixels = screenshot pixels at scale 1 (1920x1080 here). Actions: move, \
                        click, double_click, right_click, drag (x,y → to_x,to_y), scroll (dy/dx in wheel \
                        notches/lines, positive = down/right).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": { "type": "string", "enum": ["move", "click", "double_click", "right_click", "drag", "scroll"] },
                "x": { "type": "number" }, "y": { "type": "number" },
                "to_x": { "type": "number" }, "to_y": { "type": "number" },
                "dx": { "type": "number" }, "dy": { "type": "number" }
            },
            "required": ["action"],
            "additionalProperties": false
        }
    });
    let key = json!({
        "name": "key",
        "description": "Keyboard input via wtype. `type`: send text (unicode, layout independent). `press`: \
                        a key combo such as \"Return\", \"Tab\", \"ctrl+c\", \"ctrl+shift+t\", \"alt+F4\" \
                        (xkb key names; modifiers ctrl/shift/alt/super).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": { "type": "string", "enum": ["type", "press"] },
                "text": { "type": "string" },
                "combo": { "type": "string" }
            },
            "required": ["action"],
            "additionalProperties": false
        }
    });

    // owner and desktop get every local tool but the job tools, `bash` included: `desktop`
    // is not a boundary on any platform (instance-mcp#45) — mouse and keyboard reach a
    // terminal, so hiding `bash` would remove a convenience, not a privilege. The job tools
    // are owner-only like the Swift `exec*` (`OWNER_ONLY_TOOLS`). `observe` is the real
    // boundary: sys_info + screenshot only.
    let mut tools: Vec<Value> = vec![sys_info, screenshot, bash, mouse, key]
        .into_iter()
        .chain(crate::jobs::tools::tool_specs())
        .filter(|t| local_tool_allowed(t["name"].as_str().unwrap_or_default(), profile))
        .collect();
    for (_, t) in upstream_tools_for(profile, LOCAL_TOOL_NAMES) {
        tools.push(t);
    }
    Value::Array(tools)
}

pub(crate) fn handle_tool_call(
    params: &Value,
    profile: &str,
    cancel: Option<&AtomicBool>,
) -> Result<Value, (i64, String)> {
    let name = params
        .get("name")
        .and_then(|n| n.as_str())
        .ok_or_else(|| (-32602, "missing tool name".to_string()))?;
    let arguments = params.get("arguments").cloned().unwrap_or(Value::Null);

    // A tool hidden from this profile's list is unknown here too, indistinguishable
    // from one that never existed (same rule as the Swift `scoped(to:)`).
    if LOCAL_TOOL_NAMES.contains(&name) && !local_tool_allowed(name, profile) {
        return Err((-32601, format!("unknown tool: {name}")));
    }
    match name {
        "sys_info" => Ok(tool_result(tool_sys_info())),
        "screenshot" => tool_screenshot(&arguments),
        "bash" => tool_bash(&arguments, cancel),
        "mouse" => tool_mouse(&arguments),
        "key" => tool_key(&arguments),
        // Not tied to `cancel`: a job outlives the attach that started it.
        n if JOB_TOOL_NAMES.contains(&n) => crate::jobs::tools::call(n, &arguments),
        other => match upstream_owning(other, profile) {
            Some(up) => up
                .rpc(
                    "tools/call",
                    Some(json!({"name": other, "arguments": arguments})),
                )
                .map_err(|e| (-32000, e)),
            None => Err((-32601, format!("unknown tool: {other}"))),
        },
    }
}

// ---------------------------------------------------------------------------

#[cfg(test)]
mod profile_tests {
    use super::*;

    #[test]
    fn unknown_profiles_including_the_old_sandbox_name_do_not_widen() {
        assert_eq!(normalize_profile("owner"), Some("owner"));
        assert_eq!(normalize_profile("desktop"), Some("desktop"));
        assert_eq!(normalize_profile("sandbox"), None);
        assert_eq!(normalize_profile("Sandbox"), None);
        assert_eq!(normalize_profile("observe"), Some("observe"));
        assert_eq!(normalize_profile("browser"), None);
    }

    #[test]
    fn desktop_never_gets_arbitrary_javascript() {
        for tool in ["browser_evaluate", "browser_run_code_unsafe"] {
            assert!(!upstream_tool_allowed(tool, "desktop"), "{tool}");
            assert!(
                !upstream_tool_allowed(tool, "sandbox"),
                "{tool}: unknown profile gets nothing"
            );
            assert!(upstream_tool_allowed(tool, "owner"), "{tool}");
        }
        assert!(upstream_tool_allowed("browser_navigate", "desktop"));
    }

    /// Local tool names as actually served under `profile` (no upstream in tests).
    fn served(profile: &str) -> Vec<String> {
        tool_list(profile)
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap().to_owned())
            .filter(|n| !n.starts_with("browser_"))
            .collect()
    }

    #[test]
    fn every_served_tool_is_classified_and_the_lists_agree() {
        let served = served("owner");
        let mut sorted_served = served.clone();
        sorted_served.sort();
        let mut names: Vec<String> = LOCAL_TOOL_NAMES.iter().map(|s| s.to_string()).collect();
        names.sort();
        assert_eq!(
            sorted_served, names,
            "tool_list and LOCAL_TOOL_NAMES disagree"
        );
        let unclassified: Vec<_> = served
            .iter()
            .filter(|n| local_tool_class(n).is_none())
            .collect();
        assert!(
            unclassified.is_empty(),
            "classify in LOCAL_TOOL_CLASS: {unclassified:?}"
        );
        let stale: Vec<_> = LOCAL_TOOL_CLASS
            .iter()
            .filter(|(n, _)| !served.iter().any(|s| s == n))
            .collect();
        assert!(stale.is_empty(), "classified but not served: {stale:?}");
    }

    #[test]
    fn no_profile_claims_to_be_narrower_than_it_is() {
        for profile in ["owner", "desktop", "observe"] {
            let shell: Vec<String> = served(profile)
                .into_iter()
                .filter(|n| local_tool_class(n) == Some(ToolClass::Shell))
                .collect();
            if profile_is_shell_equivalent(profile) {
                assert!(
                    !shell.is_empty(),
                    "{profile} is marked shell-equivalent; keep it honest"
                );
            } else {
                assert!(
                    shell.is_empty(),
                    "{profile} claims no shell but serves {shell:?}"
                );
                let acting: Vec<String> = served(profile)
                    .into_iter()
                    .filter(|n| local_tool_class(n) != Some(ToolClass::Observe))
                    .collect();
                assert!(
                    acting.is_empty(),
                    "{profile} serves tools that act: {acting:?}"
                );
            }
        }
    }

    #[test]
    fn observe_can_only_look() {
        for tool in ["sys_info", "screenshot"] {
            assert!(local_tool_allowed(tool, "observe"), "{tool}");
        }
        for tool in [
            "bash",
            "mouse",
            "key",
            "exec_start",
            "exec_poll",
            "exec_list",
            "exec_cancel",
            "something_new",
        ] {
            assert!(!local_tool_allowed(tool, "observe"), "{tool}");
        }
        for tool in [
            "browser_navigate",
            "browser_snapshot",
            "browser_take_screenshot",
        ] {
            assert!(!upstream_tool_allowed(tool, "observe"), "{tool}");
        }
        assert!(local_tool_allowed("bash", "desktop"));
        assert!(
            !local_tool_allowed("bash", "nonsense"),
            "unknown profiles get nothing"
        );
    }

    /// The job tools are shell-class and owner-only (#32 item 4): listed and
    /// callable under `owner`, absent and unknown under every other profile.
    #[test]
    fn job_tools_are_shell_class_and_owner_only() {
        for tool in JOB_TOOL_NAMES {
            assert_eq!(local_tool_class(tool), Some(ToolClass::Shell), "{tool}");
            assert!(local_tool_allowed(tool, "owner"), "{tool}");
            for profile in ["desktop", "observe", "sandbox", "nonsense"] {
                assert!(!local_tool_allowed(tool, profile), "{tool} under {profile}");
                assert!(
                    !served(profile).iter().any(|n| n == *tool),
                    "{tool} listed under {profile}"
                );
                let call =
                    json!({"name": tool, "arguments": {"job_id": "job-x", "command": "true"}});
                assert_eq!(
                    handle_tool_call(&call, profile, None).unwrap_err().0,
                    -32601,
                    "{tool} callable under {profile}"
                );
            }
            assert!(!DESKTOP_BROWSER_TOOLS.contains(tool));
            assert!(!OBSERVE_TOOLS.contains(tool));
        }
        assert!(served("owner").iter().any(|n| n == "exec_start"));
    }

    /// With the job tools, a refused long `bash` and `initialize` point at
    /// `exec_start` + `exec_poll`; `desktop` (bash, no jobs) keeps the `nohup` advice.
    #[test]
    fn long_work_advice_follows_the_job_tools() {
        let call = json!({"name": "bash", "arguments": {"command": "true", "timeout_secs": 101}});
        let text = |profile: &str| {
            refuse_long_bash(&call, profile).unwrap()["content"][0]["text"]
                .as_str()
                .unwrap()
                .to_string()
        };
        assert!(text("owner").contains("exec_start") && text("owner").contains("exec_poll"));
        assert!(!text("owner").contains("nohup"));
        assert!(text("desktop").contains("nohup") && !text("desktop").contains("exec_start"));
        assert!(instructions("owner").contains("exec_start"));
        assert!(instructions("owner").contains("exec_poll"));
        assert!(!instructions("desktop").contains("exec_start"));
        assert!(instructions("desktop").contains("nohup"));
        assert!(!instructions("observe").contains("exec_"));
    }
}
