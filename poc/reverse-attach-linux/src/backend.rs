//! The upstream interface, the two backends behind it and the router that picks one (ADR
//! linux-browser-tier "Router", D5, D15; R4.1 to R4.5; L2). Counterpart of the Swift
//! `PlaywrightBackend` and `BrowserRouter`.
//!
//! - **Managed**: the stdio child of `child.rs`. `tools/list` is filtered to the 32 catalog names
//!   (D15). The backend is reported available only once containment has verified (R1.2).
//! - **External**: the loopback HTTP upstream of `external.rs`. It forwards every tool it lists.
//! - **The router** answers one question: which one serves `browser_*`. Rules, in order:
//!   1. `OAB_BROWSER=off`: the managed tier is switched off. With nothing installed, a
//!      `MCP_UPSTREAM browser=` line alone still serves as external; with a managed install the line
//!      is ignored (D5: external needs `MCP_BROWSER_BACKEND=external`) and the backend is `off`.
//!   2. A valid managed install is selected, and wins over a `MCP_UPSTREAM browser=` line, which is
//!      ignored with one logged event and a `sys_info` field, unless `MCP_BROWSER_BACKEND=external`.
//!   3. `MCP_BROWSER_BACKEND=external` without such a line is `unavailable: external_not_configured`
//!      and never falls to managed (R4.2).
//!   4. An installed but unusable managed tier (`install_invalid`, containment unverified) is
//!      `unavailable` and never falls to external.
//!   5. With nothing installed, `MCP_UPSTREAM browser=` alone is external, with the new checks.
//!
//! No call is retried on another backend (R4.5).
//!
//! Errors that reach a caller are fixed class strings. Nothing from the child or an upstream is
//! copied into them.

use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::catalog::BROWSER_TOOLS;
use crate::child::{Config, Supervisor};
use crate::containment::{Availability, Mechanism, Systemd, Unavailable, UNVERIFIED};
use crate::external::{External, SameUid};
use crate::state::{self, Root, State};

pub const BROWSER: &str = "browser";
const TOOLS_TTL: Duration = Duration::from_secs(30);
const CALL_TIMEOUT: Duration = Duration::from_secs(90);
const LIST_TIMEOUT: Duration = Duration::from_secs(15);

/// What `sys_info` and logs may say about a backend. Fixed vocabulary only.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BackendStatus {
    /// `managed`, `external`, `unavailable` or `off`.
    pub backend: &'static str,
    pub reason: String,
    pub containment: String,
    pub display: &'static str,
}

pub trait Upstream: Send + Sync {
    /// The tools this upstream serves right now (empty when it is down).
    fn tools(&self) -> Vec<Value>;
    /// Whether `name` is a tool this upstream serves.
    fn owns(&self, name: &str) -> bool {
        self.tools()
            .iter()
            .any(|t| t.get("name").and_then(Value::as_str) == Some(name))
    }
    /// `tools/call`. The error is a fixed class.
    fn call(&self, name: &str, arguments: Value) -> Result<Value, String>;
    fn status(&self) -> BackendStatus;
}

impl Upstream for External {
    fn tools(&self) -> Vec<Value> {
        External::tools(self)
    }
    fn call(&self, name: &str, arguments: Value) -> Result<Value, String> {
        self.rpc(
            "tools/call",
            Some(json!({"name": name, "arguments": arguments})),
        )
    }
    fn status(&self) -> BackendStatus {
        let last = self.last_class();
        BackendStatus {
            backend: "external",
            reason: if last.is_empty() { "ok".into() } else { last },
            containment: "not_applicable".into(),
            display: "not_applicable",
        }
    }
}

// ---- managed --------------------------------------------------------------------------------

pub struct Managed {
    sup: Arc<Supervisor>,
    cache: Mutex<Option<(Instant, Vec<Value>)>>,
    last_logged: Mutex<String>,
}

impl Managed {
    pub fn new(sup: Arc<Supervisor>) -> Managed {
        Managed {
            sup,
            cache: Mutex::new(None),
            last_logged: Mutex::new(String::new()),
        }
    }

    #[cfg(test)]
    pub fn supervisor(&self) -> &Arc<Supervisor> {
        &self.sup
    }

    fn log_class(&self, class: &str) {
        if let Ok(mut g) = self.last_logged.lock() {
            if *g != class {
                *g = class.to_string();
                eprintln!("browser: managed class={class}");
            }
        }
    }
}

impl Upstream for Managed {
    /// Exactly the catalog names the pinned package lists (D15).
    fn tools(&self) -> Vec<Value> {
        if let Ok(c) = self.cache.lock() {
            if let Some((at, t)) = c.as_ref() {
                if at.elapsed() < TOOLS_TTL {
                    return t.clone();
                }
            }
        }
        match self.sup.call("tools/list", json!({}), LIST_TIMEOUT) {
            Ok(r) => {
                self.log_class("ok");
                let list: Vec<Value> = r
                    .get("tools")
                    .and_then(Value::as_array)
                    .map(|a| {
                        a.iter()
                            .filter(|t| {
                                t.get("name")
                                    .and_then(Value::as_str)
                                    .is_some_and(|n| BROWSER_TOOLS.contains(&n))
                            })
                            .cloned()
                            .collect()
                    })
                    .unwrap_or_default();
                if let Ok(mut c) = self.cache.lock() {
                    *c = Some((Instant::now(), list.clone()));
                }
                list
            }
            Err(class) => {
                self.log_class(class);
                if let Ok(mut c) = self.cache.lock() {
                    *c = None;
                }
                Vec::new()
            }
        }
    }

    /// A catalog name is owned without asking the child, so a call while the child is down answers
    /// with the backend's class and not with "unknown tool".
    fn owns(&self, name: &str) -> bool {
        BROWSER_TOOLS.contains(&name)
    }

    fn call(&self, name: &str, arguments: Value) -> Result<Value, String> {
        if !BROWSER_TOOLS.contains(&name) {
            return Err("upstream_unknown_tool".into());
        }
        let r = self.sup.call(
            "tools/call",
            json!({"name": name, "arguments": arguments}),
            CALL_TIMEOUT,
        );
        match &r {
            Ok(_) => self.log_class("ok"),
            Err(c) => self.log_class(c),
        }
        r.map_err(str::to_string)
    }

    fn status(&self) -> BackendStatus {
        let containment = self.sup.containment();
        let (backend, reason) = match self.sup.availability().peek() {
            None => ("unavailable", "containment_pending".to_string()),
            Some(Err(class)) => ("unavailable", class.to_string()),
            // Available means: verified, and the last start or call did not fail. A backend in
            // backoff, latched or refused is reported as what it is.
            Some(Ok(_)) => match self.sup.reason() {
                r @ ("ok" | "not_started") => ("managed", r.to_string()),
                r => ("unavailable", r.to_string()),
            },
        };
        BackendStatus {
            backend,
            reason,
            containment,
            display: self.sup.display(),
        }
    }
}

// ---- the router -----------------------------------------------------------------------------

/// What the router reads from the environment (raw values).
#[derive(Clone, Debug, Default)]
pub struct EnvIn {
    pub off: Option<String>,
    pub backend: Option<String>,
    /// The raw `MCP_UPSTREAM`.
    pub upstream: Option<String>,
}

impl EnvIn {
    pub fn from_env() -> EnvIn {
        let get = |k: &str| std::env::var(k).ok();
        EnvIn {
            off: get("OAB_BROWSER"),
            backend: get("MCP_BROWSER_BACKEND"),
            upstream: get("MCP_UPSTREAM"),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Installed {
    No,
    /// `install.json` is ours and the files it names are there.
    Yes,
    /// Ours, but a file it needs is missing.
    Invalid,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Choice {
    Off,
    Managed,
    External,
    Unavailable(&'static str),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Decision {
    pub choice: Choice,
    /// A `MCP_UPSTREAM browser=` line exists and was not used because managed won (R4.1).
    pub external_ignored: bool,
}

/// `name=url` entries of a `MCP_UPSTREAM` value, in order. Names are `[A-Za-z0-9_-]+`.
pub fn parse_upstream_line(s: &str) -> Vec<(String, String)> {
    s.split(',')
        .filter_map(|e| e.trim().split_once('='))
        .map(|(n, u)| (n.trim().to_string(), u.trim().to_string()))
        .filter(|(n, u)| {
            !u.is_empty()
                && !n.is_empty()
                && n.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        })
        .collect()
}

/// Pure. The router rules, in order (see the module doc).
pub fn select(env: &EnvIn, installed: Installed) -> Decision {
    let line = env
        .upstream
        .as_deref()
        .map(parse_upstream_line)
        .unwrap_or_default();
    let ext = line.iter().any(|(n, _)| n == BROWSER);
    let off = env.off.as_deref().map(str::trim) == Some("off");
    let want = env
        .backend
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let d = |choice, external_ignored| Decision {
        choice,
        external_ignored,
    };
    match want {
        Some("external") => {
            return if ext {
                d(Choice::External, false)
            } else {
                d(Choice::Unavailable("external_not_configured"), false)
            };
        }
        Some("managed") | None => {}
        Some(_) => return d(Choice::Unavailable("backend_invalid"), false),
    }
    if off {
        // A managed install still wins over a stale line: external needs the explicit flag (D5,
        // R4.1), so with an install the line is ignored and the backend is off.
        return match installed {
            Installed::No if ext && want != Some("managed") => d(Choice::External, false),
            _ => d(Choice::Off, ext),
        };
    }
    match installed {
        Installed::Yes => d(Choice::Managed, ext),
        Installed::Invalid => d(Choice::Unavailable("install_invalid"), ext),
        Installed::No if want == Some("managed") => d(Choice::Unavailable("not_installed"), false),
        Installed::No if ext => d(Choice::External, false),
        Installed::No => d(Choice::Unavailable("not_installed"), false),
    }
}

/// Reads `install.json` through the ownership rules (`state::read_state`).
pub fn installed_at(base: &std::path::Path) -> Installed {
    let Ok(Some(root)) = Root::open(base, false) else {
        return Installed::No;
    };
    match state::read_state(&root) {
        Ok(State::Installed(_)) => Installed::Yes,
        Ok(State::Invalid(_)) => Installed::Invalid,
        _ => Installed::No,
    }
}

/// The result of routing, kept for `sys_info`.
pub struct Router {
    pub decision: Decision,
    pub upstream: Option<Arc<dyn Upstream>>,
}

static ROUTER: OnceLock<Router> = OnceLock::new();

/// `sys_info.browser`: fixed fields, no URL, no path, no token, no page data.
pub fn sys_info_field() -> Value {
    let (st, ignored) = match ROUTER.get() {
        None => (
            BackendStatus {
                backend: "unavailable",
                reason: "not_started".into(),
                containment: "unverified".into(),
                display: "not_applicable",
            },
            false,
        ),
        Some(r) => (
            match (&r.upstream, r.decision.choice) {
                (Some(u), _) => u.status(),
                (None, Choice::Off) => BackendStatus {
                    backend: "off",
                    reason: "off".into(),
                    containment: "not_applicable".into(),
                    display: "not_applicable",
                },
                (None, Choice::Unavailable(why)) => BackendStatus {
                    backend: "unavailable",
                    reason: why.into(),
                    containment: "not_applicable".into(),
                    display: "not_applicable",
                },
                (None, _) => BackendStatus {
                    backend: "unavailable",
                    reason: "not_started".into(),
                    containment: "not_applicable".into(),
                    display: "not_applicable",
                },
            },
            r.decision.external_ignored,
        ),
    };
    json!({
        "backend": st.backend,
        "reason": st.reason,
        "containment": st.containment,
        "display": st.display,
        "external_upstream_ignored": ignored,
    })
}

/// Builds the upstream set for the daemon and records the decision. A non-loopback external host
/// makes the daemon exit 64, so its unit does not restart-loop.
pub fn build_for_daemon(env: &EnvIn) -> Vec<Arc<dyn Upstream>> {
    let base = Root::default_base().unwrap_or_default();
    build_with(env, &base, &|data_root| {
        if cfg!(target_os = "linux") {
            Arc::new(Systemd::new(data_root, true))
        } else {
            Arc::new(Unavailable(UNVERIFIED))
        }
    })
}

/// [`build_for_daemon`] over an explicit data base and mechanism factory (the end-to-end harness
/// names its units with a test prefix).
pub fn build_with(
    env: &EnvIn,
    base: &std::path::Path,
    mechanism: &dyn Fn(Option<std::path::PathBuf>) -> Arc<dyn Mechanism>,
) -> Vec<Arc<dyn Upstream>> {
    let decision = select(env, installed_at(base));
    let line = env
        .upstream
        .as_deref()
        .map(parse_upstream_line)
        .unwrap_or_default();
    if decision.external_ignored {
        eprintln!("browser: external_upstream_ignored");
    }
    let mut ups: Vec<Arc<dyn Upstream>> = Vec::new();
    let mut browser: Option<Arc<dyn Upstream>> = None;
    for (name, url) in &line {
        let used = name != BROWSER || decision.choice == Choice::External;
        if !used {
            continue;
        }
        match External::new(name, url, Arc::new(SameUid::real())) {
            Ok(e) => {
                eprintln!("upstream {name} = external loopback");
                let e: Arc<dyn Upstream> = Arc::new(e);
                if name == BROWSER {
                    browser = Some(Arc::clone(&e));
                }
                ups.push(e);
            }
            Err(class) => {
                eprintln!("browser: {class} upstream={name}");
                std::process::exit(64);
            }
        }
    }
    if decision.choice == Choice::Managed {
        let m: Arc<dyn Upstream> = Arc::new(managed_for(base, mechanism));
        browser = Some(Arc::clone(&m));
        ups.insert(0, m);
    }
    match decision.choice {
        Choice::Unavailable(why) => eprintln!("browser: unavailable reason={why}"),
        Choice::Off => eprintln!("browser: off"),
        _ => {}
    }
    let _ = ROUTER.set(Router {
        decision,
        upstream: browser,
    });
    ups
}

/// The production managed backend. Verification starts now, in the background, so `sys_info` is
/// honest within a few seconds and the first tool call does not pay for it.
fn managed_for(
    base: &std::path::Path,
    mechanism: &dyn Fn(Option<std::path::PathBuf>) -> Arc<dyn Mechanism>,
) -> Managed {
    let data_root = Root::open(base, false)
        .ok()
        .flatten()
        .map(|r| r.abs_path().to_path_buf());
    let mech = mechanism(data_root);
    let avail = Arc::new(Availability::new(mech));
    let sup = Arc::new(Supervisor::new(
        Config::production(base.to_path_buf()),
        Arc::clone(&avail),
    ));
    let sup2 = Arc::clone(&sup);
    std::thread::spawn(move || {
        sup2.verify_now();
        if let Some(Err(class)) = sup2.availability().peek() {
            eprintln!("browser: unavailable reason={class}");
        }
    });
    crate::sigstop::register_stop(Arc::clone(&sup));
    Managed::new(sup)
}

#[cfg(test)]
#[path = "backend_tests.rs"]
mod tests;
