//! `oab-computer browser signin [--url URL]` (ADR linux-browser-tier D8, R5.2; L3): a headed
//! Chromium on the persistent profile, so a person can log in once and the managed browser then
//! reuses the cookies.
//!
//! The browser is the pinned Playwright MCP server, started the way the daemon starts it (same
//! launch vector, same `pw-config.json`, `--password-store=basic`), headed, as a child of this CLI
//! in a transient unit with a 30 minute bound (`sigstop::Supervised`). It is *not* a child of the
//! daemon, so a daemon restart does not close the window. The run record has kind `cli`: the start
//! sweep of another child leaves it alone, and its own stop leaves a daemon child's processes alone
//! (`proc::Child::set_others`).
//!
//! Flow: check, start, `initialize`, `browser_navigate` to the URL, print one line, wait for Enter
//! (or a signal, the child ending, or the bound), `browser_close` (it lets Chromium write its
//! cookies), stop the tree. Over SSH the window is on the node's own seat; the person drives it with
//! the existing `screenshot`, `mouse` and `key` tools (D8). Nothing from a page, a tool result or
//! stderr is printed: failures are fixed classes.
//!
//! Classes: `terminal_required`, `not_installed`, `no_seat`, `profile_locked`, `launch_refused`,
//! `spawn_failed`, `invalid_url`, `cancelled`, `browser_exited`, `timed_out`, `close_failed`.

use std::path::Path;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde_json::json;

use crate::child::{self, RuntimeTmp, Seat};
use crate::health::{is_error_result, Rpc};
use crate::install::Io;
use crate::proc::{Child, StderrClass};
use crate::run_record;
use crate::sigstop::Launcher;
use crate::state::{self, Root, State};

/// How long a sign-in may stay open (the unit's `RuntimeMaxSec` and the wait's own bound).
pub const MAX_OPEN: Duration = Duration::from_secs(30 * 60);
const MAX_URL: usize = 2048;
const STEP: Duration = Duration::from_secs(60);

/// A navigation target: `http://` or `https://`, at most 2048 bytes, no whitespace or control
/// character. `about:blank` is the default and is accepted.
pub fn valid_url(u: &str) -> bool {
    if u == "about:blank" {
        return true;
    }
    u.len() <= MAX_URL
        && (u.starts_with("http://") || u.starts_with("https://"))
        && u.len() > "https://".len()
        && !u.chars().any(|c| c.is_whitespace() || c.is_control())
}

/// The Wayland seat for a CLI run over SSH. `WAYLAND_DISPLAY` wins when it is set; otherwise the
/// highest `wayland-N` socket in `runtime` (the rule `install-linux.sh` uses).
pub fn find_seat(display: Option<&str>, runtime: &Path) -> Option<Seat> {
    use std::os::unix::fs::FileTypeExt;
    let is_sock = |p: &Path| {
        std::fs::metadata(p)
            .ok()
            .is_some_and(|m| m.file_type().is_socket())
    };
    if let Some(d) = display.filter(|d| !d.is_empty()) {
        let p = Path::new(d);
        let (dir, name) = if p.is_absolute() {
            (
                p.parent()?.to_path_buf(),
                p.file_name()?.to_str()?.to_string(),
            )
        } else {
            (runtime.to_path_buf(), d.to_string())
        };
        return is_sock(&dir.join(&name)).then_some(Seat {
            runtime_dir: dir,
            display: name,
        });
    }
    let mut best: Option<(u32, String)> = None;
    for e in std::fs::read_dir(runtime).ok()?.flatten().take(4096) {
        let Some(name) = e.file_name().to_str().map(str::to_string) else {
            continue;
        };
        let Some(n) = name
            .strip_prefix("wayland-")
            .and_then(|n| n.parse::<u32>().ok())
        else {
            continue;
        };
        if is_sock(&e.path()) && best.as_ref().is_none_or(|(b, _)| n > *b) {
            best = Some((n, name));
        }
    }
    best.map(|(_, display)| Seat {
        runtime_dir: runtime.to_path_buf(),
        display,
    })
}

/// What the real run uses: the environment's display, or the highest socket of this user's runtime
/// directory.
pub fn seat_from_env() -> Option<Seat> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")
        .map(std::path::PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| {
            std::path::PathBuf::from(format!("/run/user/{}", rustix::process::getuid().as_raw()))
        });
    find_seat(std::env::var("WAYLAND_DISPLAY").ok().as_deref(), &runtime).or_else(child::seat_now)
}

/// Everything a sign-in needs from outside, so tests can run it without a terminal or a seat.
pub struct Setup<'a> {
    pub root: &'a Root,
    pub launcher: &'a dyn Launcher,
    pub is_terminal: bool,
    pub seat: Option<Seat>,
    pub url: &'a str,
    pub timeouts: Timeouts,
}

#[derive(Clone, Copy)]
pub struct Timeouts {
    pub initialize: Duration,
    pub call: Duration,
    pub close: Duration,
}

impl Default for Timeouts {
    fn default() -> Timeouts {
        Timeouts {
            initialize: Duration::from_secs(15),
            call: STEP,
            close: Duration::from_secs(15),
        }
    }
}

/// Why the wait ended. Only `Enter` is a finished sign-in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ended {
    Enter,
    Cancelled,
    ChildExited,
    TimedOut,
}

/// Runs one sign-in. `wait` returns when the person is done (Enter, a signal, the bound). Errors
/// are fixed classes.
pub fn run(
    s: &Setup<'_>,
    io: &mut Io<'_>,
    wait: &mut dyn FnMut(&mut Child) -> Ended,
) -> Result<(), &'static str> {
    if !valid_url(s.url) {
        return Err("invalid_url");
    }
    if !s.is_terminal {
        return Err("terminal_required");
    }
    let rec = match state::read_state(s.root) {
        Ok(State::Installed(r)) => r,
        Ok(State::NotInstalled) => return Err("not_installed"),
        Ok(_) => return Err("install_invalid"),
        Err(_) => return Err("state_unavailable"),
    };
    let Some(seat) = s.seat.as_ref() else {
        return Err("no_seat");
    };
    // Any live run record means a browser holds the profile (the daemon's child, a health check or
    // another sign-in). Starting a second one would only fail on the lock. The short TMPDIR below has
    // its own name, so a managed start that races this check never loses its directory; the
    // profile lock then stops whichever browser comes second.
    if !run_record::live(s.root).is_empty() {
        return Err("profile_locked");
    }
    let tmp = RuntimeTmp::create_named(s.root.abs_path(), "oab-ps")?;
    let v = child::launch_vector(&rec, s.root.abs_path(), &tmp.path, Some(seat));
    child::write_config(s.root, &v.config)?;
    let spec = crate::proc::Spec {
        exe: v.exe.clone(),
        args: v.args.clone(),
        env: v.env.clone(),
        cwd: v.cwd.clone(),
    };
    let mut launched = s
        .launcher
        .launch(s.root, &spec, &v.version_dir)
        .map_err(|_| "spawn_failed")?;
    let result = drive(&mut launched.child, s, io, wait);
    launched.child.stop();
    drop(launched);
    drop(tmp);
    result
}

fn drive(
    child: &mut Child,
    s: &Setup<'_>,
    io: &mut Io<'_>,
    wait: &mut dyn FnMut(&mut Child) -> Ended,
) -> Result<(), &'static str> {
    let mut rpc = Rpc { child, next: 0 };
    let class_of = |c: &Child| match c.stderr_class() {
        StderrClass::ProfileLocked => "profile_locked",
        StderrClass::LaunchRefused => "launch_refused",
        StderrClass::None => "spawn_failed",
    };
    let init = rpc.call(
        "initialize",
        json!({
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "oab-computer", "version": "signin"},
        }),
        s.timeouts.initialize,
    );
    let init = match init {
        Ok(v) => v,
        Err(crate::health::RpcError::Cancelled) => return Err("cancelled"),
        Err(_) => return Err(class_of(rpc.child)),
    };
    if !crate::health::identity_ok(&init) {
        return Err("spawn_failed");
    }
    rpc.notify("notifications/initialized")
        .map_err(|_| "spawn_failed")?;
    // The first navigation starts Chromium; a missing sandbox or a held profile shows here.
    let nav = rpc.call(
        "tools/call",
        json!({"name": "browser_navigate", "arguments": {"url": s.url}}),
        s.timeouts.call,
    );
    match nav {
        Ok(r) if !is_error_result(&r) => {}
        Err(crate::health::RpcError::Cancelled) => return Err("cancelled"),
        _ => return Err(class_of(rpc.child)),
    }
    io.say("Sign in in the browser window. Press Enter here when finished.");
    let ended = wait(rpc.child);
    // `browser_close` lets Chromium flush its cookies before the tree is stopped.
    let closed = rpc.call(
        "tools/call",
        json!({"name": "browser_close", "arguments": {}}),
        s.timeouts.close,
    );
    let closed_ok = matches!(&closed, Ok(r) if !is_error_result(r));
    match ended {
        // A close that failed was not confirmed to have flushed the cookies, so it is not a success.
        Ended::Enter if closed_ok => Ok(()),
        Ended::Enter => Err("close_failed"),
        Ended::Cancelled => Err("cancelled"),
        Ended::ChildExited => Err("browser_exited"),
        Ended::TimedOut => Err("timed_out"),
    }
}

/// The production wait: a line on stdin, a signal, the child ending, or the bound.
pub fn wait_for_enter(child: &mut Child) -> Ended {
    let (tx, rx) = mpsc::channel::<bool>();
    std::thread::spawn(move || {
        use std::io::{BufRead, Read};
        let mut line = String::new();
        // At most 64 bytes: only "a line" matters, not what it says.
        // `true` only when a line was read; end of input (a dropped session) is not Enter.
        let got = matches!(
            std::io::stdin().lock().take(64).read_line(&mut line),
            Ok(n) if n > 0
        );
        let _ = tx.send(got);
    });
    wait_loop(
        || child.has_exited(),
        &rx,
        Instant::now() + MAX_OPEN,
        Duration::from_millis(100),
    )
}

/// The decision part of the wait, apart from stdin and the real child so it can be tested.
fn wait_loop(
    mut child_exited: impl FnMut() -> bool,
    rx: &mpsc::Receiver<bool>,
    end: Instant,
    tick: Duration,
) -> Ended {
    while Instant::now() < end {
        if crate::cancel::is_cancelled() {
            return Ended::Cancelled;
        }
        if child_exited() {
            return Ended::ChildExited;
        }
        match rx.recv_timeout(tick) {
            Ok(true) => return Ended::Enter,
            // Input ended without a line: nobody pressed Enter, so the sign-in is not confirmed.
            Ok(false) | Err(mpsc::RecvTimeoutError::Disconnected) => return Ended::Cancelled,
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
    }
    Ended::TimedOut
}

#[cfg(test)]
#[path = "signin_tests.rs"]
mod tests;
