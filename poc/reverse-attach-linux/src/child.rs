//! The managed Playwright child: launch vector, start, restart rules and stop (R1.1 to R1.6, R5.1,
//! R5.3, D11, D17; L2). Counterpart of the Swift `ManagedPlaywright`.
//!
//! Start (every time, in this order): the containment gate answers (`containment.rs`; a host where
//! nothing verified starts nothing), `install.json` must be valid, the start-time sweep runs
//! (`sweep.rs`), `pw-config.json` is rewritten, a short private `TMPDIR` is made, the child is
//! spawned through the mechanism from the long-lived spawner thread, its run record is written, and
//! `initialize` proves it is the pinned Playwright. Any failure stops everything that was started.
//!
//! Layers on every child, whichever mechanism holds it: new session and process group,
//! `PR_SET_PDEATHSIG` (spawned from [`Spawner`]'s thread, which never exits, because the signal is
//! tied to the *thread* that forked), stdin EOF on stop, a tree walk through pidfds, and the sweep
//! before the next start. The mechanism is the guarantee; these are not.
//!
//! Restart (R1.5): only on the next call, never in the background. Backoff after a failure is 1, 2,
//! 4, ... up to 30 s. Five failures within two minutes make the backend unavailable until
//! `browser status --retry` (it removes the latch file in `run/`) or the next daemon start.
//! `sandbox_unavailable` and a `profile_locked` whose holder is alive are setup problems and are not
//! retried; `sandbox_unavailable` is also written as the recorded refusal D17 needs.
//!
//! Logs and errors carry fixed classes only: never stderr text, a URL, a token or a tool argument.
//! The child's `HOME` is private, its environment is the allow-list (`env -i` inside the unit), and
//! the launch vector never contains `--no-sandbox`, `--port`, `--host` or `--allowed-hosts`.

use std::os::fd::OwnedFd;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::containment::{Availability, Launch, SpawnKind, Spawned};
use crate::proc::{Child, StderrClass};
use crate::run_record::{self, Handle};
use crate::state::{self, InstallRecord, Root, State, MARKER_TEXT, OWNED_DATA};
use crate::stdio_client::{Class, Client, MAX_LINE};
use crate::sweep;

pub const PASSWORD_STORE: &str = "--password-store=basic";

pub struct Seat {
    pub runtime_dir: PathBuf,
    pub display: String,
}

/// The Wayland socket this user's session offers, if it is there (R5.1).
pub fn seat_now() -> Option<Seat> {
    use std::os::unix::fs::FileTypeExt;
    let sock = crate::platform::linux::seat::wayland_socket();
    std::fs::metadata(&sock)
        .ok()
        .filter(|m| m.file_type().is_socket())?;
    Some(Seat {
        runtime_dir: sock.parent()?.to_path_buf(),
        display: sock.file_name()?.to_str()?.to_string(),
    })
}

/// What a start renders: the program, its arguments, its `pw-config.json`, its environment.
pub struct Vector {
    pub exe: PathBuf,
    pub args: Vec<String>,
    pub config: String,
    pub env: Vec<(String, String)>,
    pub cwd: PathBuf,
    pub version_dir: PathBuf,
}

/// The launch vector (D11, R5.1, R5.3). Pure. Headed when a seat socket exists, else headless.
/// `--password-store=basic` is written into the config's Chromium arguments every time. The server
/// is started with `--sandbox` (Playwright adds `--no-sandbox` otherwise) and never with a port,
/// host or allowed-hosts flag.
pub fn launch_vector(rec: &InstallRecord, root: &Path, tmp: &Path, seat: Option<&Seat>) -> Vector {
    let s = |p: &Path| p.to_string_lossy().into_owned();
    let ver = root.join(&rec.version);
    let node = ver.join("node/bin/node");
    let cli = ver.join("pkg/node_modules/@playwright/mcp/cli.js");
    let chromium = ver.join("chromium").join(&rec.chromium_executable);
    let headless = seat.is_none();
    let mut args: Vec<String> = vec![
        s(&cli),
        "--config".into(),
        s(&root.join(state::CONFIG_NAME)),
        "--user-data-dir".into(),
        s(&root.join("profile")),
        "--output-dir".into(),
        s(&root.join("output")),
        "--idle-timeout".into(),
        "1800000".into(),
        "--browser".into(),
        "chromium".into(),
        "--executable-path".into(),
        s(&chromium),
        "--shared-browser-context".into(),
        "--caps".into(),
        "vision,pdf".into(),
        "--sandbox".into(),
    ];
    if headless {
        args.push("--headless".into());
    }
    let config = json!({
        "_oabInstallerOwned": true,
        "browser": {
            "browserName": "chromium",
            "launchOptions": {
                "headless": headless,
                "args": [PASSWORD_STORE],
            },
        },
    })
    .to_string();
    let mut env: Vec<(String, String)> = vec![
        ("HOME".into(), s(&root.join("home"))),
        ("TMPDIR".into(), s(tmp)),
        ("LANG".into(), "C.UTF-8".into()),
        (
            "PATH".into(),
            format!(
                "{}:/usr/bin:/bin",
                s(node.parent().unwrap_or(Path::new("/")))
            ),
        ),
    ];
    if let Some(seat) = seat {
        env.push(("XDG_RUNTIME_DIR".into(), s(&seat.runtime_dir)));
        env.push(("WAYLAND_DISPLAY".into(), seat.display.clone()));
    }
    Vector {
        exe: node,
        args,
        config,
        env,
        cwd: ver.clone(),
        version_dir: ver,
    }
}

/// Rewrites `pw-config.json` before a start so that an edit that dropped a flag cannot survive. A
/// file without the installer's marker key is somebody else's and is never replaced.
pub fn write_config(root: &Root, config: &str) -> Result<(), &'static str> {
    use state::{lstat_at, read_file_capped, write_record, write_record_cas, CONFIG_NAME};
    const CAP: u64 = 256 * 1024;
    match lstat_at(root.fd(), CONFIG_NAME) {
        Ok(None) => {
            write_record(root.fd(), CONFIG_NAME, config.as_bytes()).map_err(|_| "config_unwritable")
        }
        Ok(Some(_)) => {
            let cur =
                read_file_capped(root.fd(), CONFIG_NAME, CAP).map_err(|_| "config_foreign")?;
            if cur == config.as_bytes() {
                return Ok(());
            }
            if !state::config_bytes_ours(&cur) {
                return Err("config_foreign");
            }
            write_record_cas(root.fd(), CONFIG_NAME, config.as_bytes(), &cur)
                .map_err(|_| "config_unwritable")
        }
        Err(_) => Err("config_unwritable"),
    }
}

// ---- restart rules (R1.5) -------------------------------------------------------------------

pub const FAILURE_WINDOW: Duration = Duration::from_secs(120);
pub const FAILURES_TO_LATCH: usize = 5;
pub const BACKOFF_CAP: Duration = Duration::from_secs(30);

/// Failure bookkeeping, on an injected clock (time since the supervisor was made).
#[derive(Default)]
pub struct Health {
    fails: Vec<Duration>,
    consecutive: u32,
    next_ok: Duration,
    latched: bool,
    permanent: Option<&'static str>,
}

impl Health {
    pub fn failure(&mut self, now: Duration) {
        self.fails.push(now);
        self.fails
            .retain(|t| now.saturating_sub(*t) <= FAILURE_WINDOW);
        self.consecutive = self.consecutive.saturating_add(1);
        let secs = 1u64 << (self.consecutive - 1).min(5);
        self.next_ok = now + Duration::from_secs(secs).min(BACKOFF_CAP);
        if self.fails.len() >= FAILURES_TO_LATCH {
            self.latched = true;
        }
    }

    pub fn success(&mut self) {
        self.consecutive = 0;
        self.next_ok = Duration::ZERO;
    }

    /// A setup problem: not retried until `reset`.
    pub fn permanent(&mut self, class: &'static str) {
        self.permanent = Some(class);
    }

    pub fn reset(&mut self) {
        *self = Health::default();
    }

    pub fn is_latched(&self) -> bool {
        self.latched || self.permanent.is_some()
    }

    /// May a start be attempted now?
    pub fn gate(&self, now: Duration) -> Result<(), &'static str> {
        if let Some(p) = self.permanent {
            return Err(p);
        }
        if self.latched {
            return Err("unavailable_after_failures");
        }
        if now < self.next_ok {
            return Err("backoff");
        }
        Ok(())
    }
}

// ---- the thread that spawns ------------------------------------------------------------------

type Job = Box<dyn FnOnce() + Send>;

/// One long-lived thread that forks every long-lived child. `PR_SET_PDEATHSIG` fires when the
/// *thread* that created the child exits, not the process, so a child forked from a request thread
/// would die when that thread ended. This thread never exits.
pub struct Spawner {
    tx: Mutex<mpsc::Sender<Job>>,
}

impl Spawner {
    pub fn new() -> Spawner {
        let (tx, rx) = mpsc::channel::<Job>();
        std::thread::Builder::new()
            .name("oab-spawner".into())
            .spawn(move || {
                for job in rx {
                    job();
                }
            })
            .ok();
        Spawner { tx: Mutex::new(tx) }
    }

    pub fn global() -> &'static Spawner {
        static S: OnceLock<Spawner> = OnceLock::new();
        S.get_or_init(Spawner::new)
    }

    /// Runs `f` on the spawner thread and returns its result.
    pub fn run<T: Send + 'static>(&self, f: impl FnOnce() -> T + Send + 'static) -> Option<T> {
        let (rtx, rrx) = mpsc::channel();
        let job: Job = Box::new(move || {
            let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(f));
            let _ = rtx.send(r.ok());
        });
        self.tx.lock().ok()?.send(job).ok()?;
        rrx.recv().ok().flatten()
    }
}

impl Default for Spawner {
    fn default() -> Self {
        Spawner::new()
    }
}

// ---- the short TMPDIR -----------------------------------------------------------------------

/// A private directory with a short path for the child's `TMPDIR` (Chromium puts a Unix socket
/// below it, and a socket path over about 100 bytes is refused). One fixed name per install root,
/// so a directory a killed child left behind is found, and removed, by the next start. The base is
/// `XDG_RUNTIME_DIR` when that is a private directory of ours and `/tmp/oab-<euid>` (0700, ours)
/// otherwise; see `state::open_private_base`.
pub(crate) struct RuntimeTmp {
    parent: OwnedFd,
    name: String,
    pub(crate) path: PathBuf,
}

impl RuntimeTmp {
    pub(crate) fn create(root_abs: &Path) -> Result<RuntimeTmp, &'static str> {
        RuntimeTmp::create_named(root_abs, "oab-pw")
    }

    /// Same, under another fixed prefix of the same length. `browser signin` uses its own so that
    /// starting it never removes the directory of a managed child that started a moment earlier:
    /// the profile lock decides who may run, and each side only ever touches its own directory.
    pub(crate) fn create_named(root_abs: &Path, prefix: &str) -> Result<RuntimeTmp, &'static str> {
        let runtime = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from);
        let (parent, base) =
            state::open_private_base(runtime.as_deref()).map_err(|_| "tmp_unavailable")?;
        let h = Sha256::digest(root_abs.as_os_str().as_encoded_bytes());
        let name = format!("{prefix}-{}", crate::manifest::hex(&h[..4]));
        let mut rep = state::Report::default();
        // A directory of ours that an earlier child left: marker-gated removal.
        let _ = state::remove_marked_tree(&parent, &name, OWNED_DATA, &mut rep);
        let fd = state::create_dir_at(&parent, &name).map_err(|_| "tmp_unavailable")?;
        if state::write_new_file(&fd, OWNED_DATA, MARKER_TEXT, 0o600).is_err() {
            let _ = rustix::fs::unlinkat(&parent, name.as_str(), rustix::fs::AtFlags::REMOVEDIR);
            return Err("tmp_unavailable");
        }
        let path = base.join(&name);
        Ok(RuntimeTmp { parent, name, path })
    }
}

impl Drop for RuntimeTmp {
    fn drop(&mut self) {
        let mut rep = state::Report::default();
        let _ = state::remove_marked_tree(&self.parent, &self.name, OWNED_DATA, &mut rep);
    }
}

// ---- limits ---------------------------------------------------------------------------------

/// `MemoryMax` for the browser unit: 60% of the host's memory, between 512 MiB and 4 GiB.
pub fn memory_max_for(mem_total_kib: Option<u64>) -> u64 {
    const MIB: u64 = 1 << 20;
    match mem_total_kib {
        Some(k) => (k * 1024 / 10 * 6).clamp(512 * MIB, 4096 * MIB),
        None => 2048 * MIB,
    }
}

pub(crate) fn host_memory_kib() -> Option<u64> {
    let t = std::fs::read_to_string("/proc/meminfo").ok()?;
    t.lines()
        .find_map(|l| l.strip_prefix("MemTotal:"))?
        .split_whitespace()
        .next()?
        .parse()
        .ok()
}

/// Chromium counts threads as tasks, so this stays generous (ADR).
pub const TASKS_MAX: u32 = 8192;

// ---- the supervisor -------------------------------------------------------------------------

pub type Clock = Arc<dyn Fn() -> Duration + Send + Sync>;

pub struct Config {
    /// `${XDG_DATA_HOME:-$HOME/.local/share}`; the root is `<base>/oab-computer/playwright`.
    pub base: PathBuf,
    pub clock: Clock,
    pub seat: Arc<dyn Fn() -> Option<Seat> + Send + Sync>,
    pub init_timeout: Duration,
    pub ping_timeout: Duration,
    /// A child that has said nothing for this long is pinged before a call is sent to it.
    pub idle_ping_after: Duration,
}

impl Config {
    pub fn production(base: PathBuf) -> Config {
        let epoch = Instant::now();
        Config {
            base,
            clock: Arc::new(move || epoch.elapsed()),
            seat: Arc::new(seat_now),
            init_timeout: Duration::from_secs(15),
            ping_timeout: Duration::from_secs(2),
            idle_ping_after: Duration::from_secs(30),
        }
    }
}

struct Running {
    child: Child,
    client: Arc<Client>,
    _record: Handle,
    _tmp: RuntimeTmp,
}

#[derive(Default)]
struct Inner {
    running: Option<Running>,
    health: Health,
    /// Set by a timeout: the next use pings first.
    suspect: bool,
}

pub struct Supervisor {
    cfg: Config,
    avail: Arc<Availability>,
    inner: Mutex<Inner>,
    stopping: AtomicBool,
    reason: Mutex<&'static str>,
}

impl Supervisor {
    pub fn new(cfg: Config, avail: Arc<Availability>) -> Supervisor {
        Supervisor {
            cfg,
            avail,
            inner: Mutex::new(Inner::default()),
            stopping: AtomicBool::new(false),
            reason: Mutex::new("not_started"),
        }
    }

    fn set_reason(&self, r: &'static str) {
        if let Ok(mut g) = self.reason.lock() {
            *g = r;
        }
    }

    /// The last reason, a fixed class: `ok`, `not_started`, or what made the last start fail.
    pub fn reason(&self) -> &'static str {
        self.reason.lock().map(|g| *g).unwrap_or("not_started")
    }

    pub fn availability(&self) -> &Arc<Availability> {
        &self.avail
    }

    /// `headed` or `headless`, from whether a seat socket is there now.
    pub fn display(&self) -> &'static str {
        if (self.cfg.seat)().is_some() {
            "headed"
        } else {
            "headless"
        }
    }

    /// The mode that verified, or `unverified`. Never runs the self-test.
    pub fn containment(&self) -> String {
        match self.avail.peek() {
            Some(Ok(m)) => m.name.to_string(),
            _ => "unverified".to_string(),
        }
    }

    fn root(&self) -> Result<Root, &'static str> {
        Root::open(&self.cfg.base, false)
            .map_err(|_| "state_unavailable")?
            .ok_or("not_installed")
    }

    /// The running client, started first if needed. Errors are fixed classes.
    pub fn ensure(&self) -> Result<Arc<Client>, &'static str> {
        if self.stopping.load(Ordering::SeqCst) {
            return Err("stopping");
        }
        let mut g = self.inner.lock().map_err(|_| "state_unavailable")?;
        let now = (self.cfg.clock)();
        // `browser status --retry` removed the latch file: forget the failures and the answer.
        if g.health.is_latched() {
            let cleared = self
                .root()
                .map(|r| !run_record::latch_is_set(&r))
                .unwrap_or(false);
            if cleared {
                g.health.reset();
                self.avail.reset();
            }
        }
        let verdict = g.running.as_ref().map(|run| {
            let dead = run.client.is_dead() || run.child.has_exited();
            let stale = !dead
                && (g.suspect || run.client.idle_for() > self.cfg.idle_ping_after)
                && !run.client.ping(self.cfg.ping_timeout);
            (dead || stale, Arc::clone(&run.client))
        });
        match verdict {
            Some((false, client)) => {
                g.suspect = false;
                return Ok(client);
            }
            Some((true, _)) => {
                Self::stop_running(&mut g);
                g.health.failure(now);
                self.latch_if_needed(&g);
            }
            None => {}
        }
        g.health.gate(now).inspect_err(|r| self.set_reason(r))?;
        match self.start(&mut g) {
            Ok(c) => {
                g.health.success();
                g.suspect = false;
                self.set_reason("ok");
                Ok(c)
            }
            Err(class) => {
                self.set_reason(class);
                Err(class)
            }
        }
    }

    fn latch_if_needed(&self, g: &Inner) {
        if g.health.is_latched() {
            if let Ok(root) = self.root() {
                let _ = run_record::latch_set(&root);
            }
        }
    }

    fn stop_running(g: &mut Inner) {
        if let Some(mut r) = g.running.take() {
            r.client.close();
            r.child.stop();
        }
    }

    fn start(&self, g: &mut Inner) -> Result<Arc<Client>, &'static str> {
        let now = (self.cfg.clock)();
        let mode = match self.avail.get() {
            Ok(m) => m,
            Err(class) => {
                // Not a failure of the child: a host with no verified mechanism starts nothing.
                if let Ok(root) = self.root() {
                    let _ = run_record::latch_set(&root);
                }
                g.health.permanent(class);
                return Err(class);
            }
        };
        let root = self.root()?;
        let rec = match state::read_state(&root) {
            Ok(State::Installed(r)) => r,
            Ok(State::NotInstalled) => return Err("not_installed"),
            Ok(_) => return Err("install_invalid"),
            Err(_) => return Err("state_unavailable"),
        };
        let mech = Arc::clone(self.avail.mechanism());
        let _ = sweep::sweep_before_start(&root, &|u| mech.stop_unit(u));
        let tmp = RuntimeTmp::create(root.abs_path())?;
        let seat = (self.cfg.seat)();
        let v = launch_vector(&rec, root.abs_path(), &tmp.path, seat.as_ref());
        write_config(&root, &v.config)?;
        let launch = Launch {
            exe: v.exe.clone(),
            args: v.args.clone(),
            env: v.env.clone(),
            cwd: v.cwd.clone(),
            scope: v.version_dir.clone(),
            line_cap: MAX_LINE,
            rw_paths: vec![root.abs_path().to_path_buf(), tmp.path.clone()],
            memory_max: memory_max_for(host_memory_kib()),
            tasks_max: TASKS_MAX,
        };
        let spawned = {
            let mech = Arc::clone(&mech);
            Spawner::global().run(move || mech.spawn(mode, SpawnKind::Managed, &launch))
        };
        let Spawned { mut child, unit } = match spawned {
            Some(Ok(s)) => s,
            _ => {
                g.health.failure(now);
                self.latch_if_needed(g);
                return Err("spawn_failed");
            }
        };
        let record = match run_record::write(&root, "managed", child.pid(), unit.as_deref()) {
            Ok(h) => h,
            Err(_) => {
                child.stop();
                g.health.failure(now);
                return Err("run_record_failed");
            }
        };
        child.set_others(sweep::others_live(&root, child.pid()));
        let (Some(stdin), Some(lines)) = (child.stdin.take(), child.lines.take()) else {
            child.stop();
            return Err("spawn_failed");
        };
        let client = Client::start(Box::new(stdin), lines);
        match self.handshake(&client) {
            Ok(()) => {
                g.running = Some(Running {
                    child,
                    client: Arc::clone(&client),
                    _record: record,
                    _tmp: tmp,
                });
                Ok(client)
            }
            Err(()) => {
                let (sandbox, locked) = (
                    child.stderr_sandbox_refused(),
                    child.stderr_class() == StderrClass::ProfileLocked,
                );
                client.close();
                child.stop();
                drop(record);
                Err(self.classify_failure(g, &root, sandbox, locked, now))
            }
        }
    }

    /// `initialize`, then `notifications/initialized`; the server must identify as Playwright.
    fn handshake(&self, c: &Client) -> Result<(), ()> {
        let init = c
            .call(
                "initialize",
                json!({
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "oab-computer", "version": "managed"},
                }),
                self.cfg.init_timeout,
            )
            .map_err(|_| ())?;
        let ok = init
            .get("serverInfo")
            .and_then(|s| s.get("name"))
            .and_then(Value::as_str)
            .is_some_and(|n| n.to_lowercase().contains("playwright"));
        if !ok {
            return Err(());
        }
        c.notify("notifications/initialized", json!({}))
            .map_err(|_| ())
    }

    /// A failure after the child ran: what class is it, and may it be retried? `sandbox` and
    /// `locked` are yes/no reads of the child's stderr; no text is kept.
    fn classify_failure(
        &self,
        g: &mut Inner,
        root: &Root,
        sandbox: bool,
        locked: bool,
        now: Duration,
    ) -> &'static str {
        if sandbox {
            let _ = run_record::refusal_set(root, "sandbox_unavailable");
            let _ = run_record::latch_set(root);
            g.health.permanent("sandbox_unavailable");
            "sandbox_unavailable"
        } else if locked && !run_record::live(root).is_empty() {
            let _ = run_record::latch_set(root);
            g.health.permanent("profile_locked");
            "profile_locked"
        } else {
            g.health.failure(now);
            self.latch_if_needed(g);
            "start_failed"
        }
    }

    /// A tool call came back as an error result. Chromium is started by the first navigation, not by
    /// `initialize`, so this is where a missing sandbox or a locked profile shows. The result is
    /// returned to the caller as it is; the backend then stops the child and, for those two
    /// classes, is not retried.
    fn after_tool_error(&self, client: &Arc<Client>) {
        let Ok(mut g) = self.inner.lock() else {
            return;
        };
        let Some(run) = g
            .running
            .as_ref()
            .filter(|r| Arc::ptr_eq(&r.client, client))
        else {
            return;
        };
        let (sandbox, locked) = (
            run.child.stderr_sandbox_refused(),
            run.child.stderr_class() == StderrClass::ProfileLocked,
        );
        if !sandbox && !locked {
            return;
        }
        let Ok(root) = self.root() else {
            return;
        };
        Self::stop_running(&mut g);
        let class = self.classify_failure(&mut g, &root, sandbox, locked, (self.cfg.clock)());
        self.set_reason(class);
    }

    /// One request to the child, started on demand. A child that dies or breaks the framing is
    /// stopped and counted as a failure; the next call decides about a restart. A timeout marks the
    /// child suspect, so the next call pings it first.
    pub fn call(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, &'static str> {
        let client = self.ensure()?;
        match client.call(method, params, timeout) {
            Ok(v) => {
                if method == "tools/call" && v.get("isError") == Some(&Value::Bool(true)) {
                    self.after_tool_error(&client);
                }
                Ok(v)
            }
            Err(c @ (Class::Unreachable | Class::BadBody)) => {
                self.child_failed(&client);
                Err(c.name())
            }
            Err(c) => {
                if c == Class::Timeout {
                    if let Ok(mut g) = self.inner.lock() {
                        g.suspect = true;
                    }
                }
                Err(c.name())
            }
        }
    }

    fn child_failed(&self, client: &Arc<Client>) {
        let Ok(mut g) = self.inner.lock() else {
            return;
        };
        let same = g
            .running
            .as_ref()
            .is_some_and(|r| Arc::ptr_eq(&r.client, client));
        if same {
            Self::stop_running(&mut g);
            g.health.failure((self.cfg.clock)());
            self.latch_if_needed(&g);
        }
    }

    /// Stops the child and everything it started. Safe to call more than once, and from the
    /// signal-handling thread: no further start happens afterwards.
    pub fn stop(&self) {
        self.stopping.store(true, Ordering::SeqCst);
        if let Ok(mut g) = self.inner.lock() {
            Self::stop_running(&mut g);
        }
    }

    /// Runs the containment self-test now if it has not run, and records a failure as the latch
    /// (`browser status --retry` clears it) so the answer is the same whether a call came first.
    pub fn verify_now(&self) {
        if let Err(class) = self.avail.get() {
            if let Ok(root) = self.root() {
                let _ = run_record::latch_set(&root);
            }
            if let Ok(mut g) = self.inner.lock() {
                g.health.permanent(class);
            }
            self.set_reason(class);
        }
    }

    /// Is a child running right now?
    #[cfg(test)]
    pub fn is_running(&self) -> bool {
        self.inner.lock().is_ok_and(|g| g.running.is_some())
    }

    /// The pid of the running leader.
    #[cfg(test)]
    pub fn leader_pid(&self) -> Option<u32> {
        self.inner
            .lock()
            .ok()
            .and_then(|g| g.running.as_ref().map(|r| r.child.pid()))
    }
}

impl Drop for Supervisor {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
#[path = "child_tests.rs"]
pub(crate) mod tests;
