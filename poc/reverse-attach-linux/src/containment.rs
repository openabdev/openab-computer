//! The kernel-enforced whole-tree stop mechanism and its availability gate (ADR linux-browser-tier
//! decision 3, D4; R1.2, R1.3, R6.1, R6.2; L2).
//!
//! A managed child is started only when a [`Mechanism`] has verified itself on this host. The first
//! (and for L2 only) mechanism is a transient `systemd --user` service with
//! `KillMode=control-group`, `BindsTo` the daemon's own unit. Where it does not verify, the answer is
//! `unavailable: containment_unverified` and no child is started. The process-tree layers in
//! `proc.rs` are always applied on top and are never the only guarantee.
//!
//! # The self-test
//!
//! The ADR says a mechanism must have "succeeded in a self-test on the host" and says nothing about
//! the fixture, so the design here is this module's own, derived from the layer table.
//!
//! The fixture is two transient units, each with `KillMode=control-group`, `--collect` and a
//! `RuntimeMaxSec`, so systemd ends them even if the daemon dies mid-test. Neither is a process of
//! the daemon, so the daemon exiting cannot orphan them.
//!
//! - **parent**: `Restart=always` (the shape of `oab-computer.service`), main process a sleeper.
//! - **child**: `BindsTo=<parent>`, `After=<parent>`; runs a shell that starts a detached grandchild
//!   (own session, as Chromium helpers are) and then a sleeper of its own.
//!
//! The test requires, before killing anything, that the child's cgroup holds at least two processes
//! (so a pass cannot come from a fixture that never started), kills the parent's main process with
//! `SIGKILL`, and requires within 5 s that the child unit is inactive and that every process that
//! was in its cgroup is gone (compared by PID and start time). It then watches the parent restart
//! and requires that the child is not revived (V4). Both units are stopped afterwards on every path,
//! and units left by a crashed earlier run (`<prefix>-*`) are stopped before the next test starts.
//! If the cleanup itself does not leave nothing behind, the test fails. Only pass or fail and the
//! elapsed milliseconds are recorded.
//!
//! The mechanism is also refused unless the daemon is the main process of its own unit
//! (`daemon_not_unit_main`): otherwise `BindsTo` could pull in a second daemon and leave the browser
//! running after a `SIGKILL` (ADR, M5).

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::proc::{self, Child, Spec, UnitCtl};
use crate::run_record::is_unit_name;
use crate::unit::{self, Kind, Req};

pub const UNVERIFIED: &str = "containment_unverified";
pub const NOT_UNIT_MAIN: &str = "daemon_not_unit_main";

/// What verified, for `sys_info` and `status`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Mode {
    pub name: &'static str,
    /// The mount namespace tier (`PrivateTmp`, `ProtectHome`, `ProtectSystem`) works on this host.
    pub mount_tier: bool,
}

pub const SYSTEMD: Mode = Mode {
    name: "systemd",
    mount_tier: false,
};
pub const SYSTEMD_MOUNT: Mode = Mode {
    name: "systemd+mount",
    mount_tier: true,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpawnKind {
    /// The daemon's child: bound to the daemon unit.
    Managed,
    /// A CLI child (health check, sign-in): bound to nothing but a runtime bound.
    Cli { runtime_max: Duration },
}

/// What to run.
pub struct Launch {
    pub exe: PathBuf,
    pub args: Vec<String>,
    /// The whole environment of the child.
    pub env: Vec<(String, String)>,
    pub cwd: PathBuf,
    /// The directory whose files the child executes; the tree walk on stop kills below it.
    pub scope: PathBuf,
    pub line_cap: usize,
    /// `ReadWritePaths` of the mount namespace tier: the data root and the child's `TMPDIR`.
    pub rw_paths: Vec<PathBuf>,
    pub memory_max: u64,
    pub tasks_max: u32,
}

pub struct Spawned {
    pub child: Child,
    /// The transient unit that contains it, when there is one.
    pub unit: Option<String>,
}

pub trait Mechanism: Send + Sync {
    /// Runs the self-test. `Err` is a fixed class (`containment_unverified`, `daemon_not_unit_main`).
    fn verify(&self) -> Result<Mode, &'static str>;
    fn spawn(&self, mode: Mode, kind: SpawnKind, l: &Launch) -> std::io::Result<Spawned>;
    /// Stops a transient unit by name, bounded.
    fn stop_unit(&self, unit: &str);
}

/// The cached answer to "may a child be started on this host".
pub struct Availability {
    mech: Arc<dyn Mechanism>,
    cached: Mutex<Option<Result<Mode, &'static str>>>,
}

impl Availability {
    pub fn new(mech: Arc<dyn Mechanism>) -> Availability {
        Availability {
            mech,
            cached: Mutex::new(None),
        }
    }

    pub fn mechanism(&self) -> &Arc<dyn Mechanism> {
        &self.mech
    }

    /// Verifies once and keeps the answer for the life of the daemon, until [`reset`](Self::reset).
    pub fn get(&self) -> Result<Mode, &'static str> {
        let Ok(mut g) = self.cached.lock() else {
            return Err(UNVERIFIED);
        };
        if let Some(r) = *g {
            return r;
        }
        let r = self.mech.verify();
        *g = Some(r);
        r
    }

    /// What is known without running the test.
    pub fn peek(&self) -> Option<Result<Mode, &'static str>> {
        self.cached.lock().ok().and_then(|g| *g)
    }

    /// `browser status --retry`: forget the answer so the next start verifies again.
    pub fn reset(&self) {
        if let Ok(mut g) = self.cached.lock() {
            *g = None;
        }
    }
}

// ---- the systemd mechanism ------------------------------------------------------------------

/// How helper commands (`systemctl`, `systemd-run`) are found and run. Injected so that a test can
/// remove one of them from `PATH` or unset `XDG_RUNTIME_DIR` and see the mechanism fail closed.
#[derive(Clone, Debug)]
pub struct Sys {
    pub path: Vec<PathBuf>,
    pub runtime_dir: Option<PathBuf>,
    pub bus: Option<String>,
}

impl Sys {
    pub fn from_env() -> Sys {
        Sys {
            path: std::env::var_os("PATH")
                .map(|p| std::env::split_paths(&p).collect())
                .unwrap_or_default(),
            runtime_dir: std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from),
            bus: std::env::var("DBUS_SESSION_BUS_ADDRESS").ok(),
        }
    }

    pub fn find(&self, program: &str) -> Option<PathBuf> {
        use std::os::unix::fs::PermissionsExt;
        self.path
            .iter()
            .filter(|d| d.is_absolute())
            .map(|d| d.join(program))
            .find(|p| {
                std::fs::metadata(p)
                    .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
            })
    }

    /// The environment helper commands run with: nothing inherited.
    pub fn env(&self) -> Vec<(String, String)> {
        let mut e = vec![(
            "PATH".to_string(),
            self.path
                .iter()
                .filter_map(|p| p.to_str())
                .collect::<Vec<_>>()
                .join(":"),
        )];
        if let Some(r) = self.runtime_dir.as_ref().and_then(|p| p.to_str()) {
            e.push(("XDG_RUNTIME_DIR".into(), r.into()));
        }
        if let Some(b) = &self.bus {
            e.push(("DBUS_SESSION_BUS_ADDRESS".into(), b.clone()));
        }
        e
    }

    /// Runs `program args` with a deadline and returns `(success, stdout)`. stdout is capped at
    /// 64 KiB, stderr is discarded, stdin is empty. `None` when it could not start or timed out.
    fn run(&self, program: &str, args: &[&str], timeout: Duration) -> Option<(bool, String)> {
        let exe = self.find(program)?;
        let mut cmd = Command::new(exe);
        cmd.args(args)
            .env_clear()
            .envs(self.env())
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut child = cmd.spawn().ok()?;
        let mut out = child.stdout.take()?;
        let reader = std::thread::spawn(move || {
            let mut s = Vec::new();
            let _ = (&mut out).take(64 * 1024).read_to_end(&mut s);
            s
        });
        let end = Instant::now() + timeout;
        let status = loop {
            match child.try_wait() {
                Ok(Some(st)) => break st,
                Ok(None) if Instant::now() < end => {
                    std::thread::sleep(Duration::from_millis(10));
                }
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    let _ = reader.join();
                    return None;
                }
            }
        };
        let text = String::from_utf8_lossy(&reader.join().unwrap_or_default()).into_owned();
        Some((status.success(), text))
    }

    fn systemctl(&self, args: &[&str], timeout: Duration) -> Option<(bool, String)> {
        let mut a = vec!["--user", "--no-pager"];
        a.extend_from_slice(args);
        self.run("systemctl", &a, timeout)
    }

    fn show(&self, unit: &str, prop: &str) -> Option<String> {
        let (_, t) = self.systemctl(
            &["show", "--value", "-p", prop, unit],
            Duration::from_secs(5),
        )?;
        Some(t.trim().to_string())
    }

    fn active_state(&self, unit: &str) -> Option<String> {
        self.show(unit, "ActiveState")
    }

    /// `true` once the unit is stopped (or never existed).
    fn stop(&self, unit: &str) -> bool {
        if !is_unit_name(unit) {
            return false;
        }
        self.systemctl(&["stop", unit], Duration::from_secs(20));
        self.systemctl(&["reset-failed", unit], Duration::from_secs(5));
        matches!(
            self.active_state(unit).as_deref(),
            Some("inactive" | "failed")
        )
    }

    /// Names of units that match `<prefix>-*`. `None` when `systemctl` failed or more than
    /// `MAX_LISTED` match: an incomplete list cannot show that none are left.
    pub(crate) fn list_prefixed(&self, prefix: &str) -> Option<Vec<String>> {
        const MAX_LISTED: usize = 256;
        let pat = format!("{prefix}-*");
        let (ok, t) = self.systemctl(
            &["list-units", "--all", "--plain", "--no-legend", &pat],
            Duration::from_secs(10),
        )?;
        if !ok {
            return None;
        }
        let v: Vec<String> = t
            .lines()
            .filter_map(|l| l.split_whitespace().next())
            .filter(|n| is_unit_name(n) && n.starts_with(prefix))
            .take(MAX_LISTED + 1)
            .map(str::to_string)
            .collect();
        (v.len() <= MAX_LISTED).then_some(v)
    }

    /// The pids in a unit's cgroup.
    fn cgroup_pids(&self, unit: &str) -> Option<Vec<u32>> {
        let cg = self.show(unit, "ControlGroup")?;
        if !cg.starts_with('/') || cg.split('/').any(|c| c == "..") || cg.contains('\0') {
            return None;
        }
        let mut s = String::new();
        std::fs::File::open(format!("/sys/fs/cgroup{cg}/cgroup.procs"))
            .ok()?
            .take(64 * 1024)
            .read_to_string(&mut s)
            .ok()?;
        Some(
            s.lines()
                .filter_map(|l| l.trim().parse().ok())
                .take(256)
                .collect(),
        )
    }
}

/// The unit that is this process's own service, when this process is its main process.
fn own_unit(sys: &Sys) -> Option<String> {
    let mut text = String::new();
    std::fs::File::open("/proc/self/cgroup")
        .ok()?
        .take(8192)
        .read_to_string(&mut text)
        .ok()?;
    let unit =
        proc::unit_of_cgroup(&text).filter(|u| u.ends_with(".service") && is_unit_name(u))?;
    let main: u32 = sys.show(&unit, "MainPID")?.parse().ok()?;
    (main == std::process::id()).then_some(unit)
}

pub struct Systemd {
    pub sys: Sys,
    /// Prefix of the self-test units. Tests use `oab-l2-test-selftest`.
    pub selftest_prefix: String,
    /// Prefix of the browser units. Tests use `oab-l2-test-browser`.
    pub browser_prefix: String,
    /// Refuse unless this process is the main process of its own unit. The daemon sets it; the
    /// `browser status --retry` CLI, which starts no managed child, does not.
    pub require_unit_main: bool,
    /// The data root, for the mount tier probe.
    pub data_root: Option<PathBuf>,
}

impl Systemd {
    pub fn new(data_root: Option<PathBuf>, require_unit_main: bool) -> Systemd {
        Systemd {
            sys: Sys::from_env(),
            selftest_prefix: "oab-selftest".into(),
            browser_prefix: "oab-browser".into(),
            require_unit_main,
            data_root,
        }
    }

    /// Everything that must exist before a fixture is started: the tools, a runtime dir, a running
    /// user manager, cgroup v2 and an `env` that has `-C`.
    fn precheck(&self) -> Result<(), &'static str> {
        let s = &self.sys;
        let fail = Err(UNVERIFIED);
        for tool in ["systemd-run", "systemctl", "sleep"] {
            if s.find(tool).is_none() {
                return fail;
            }
        }
        if !Path::new(unit::ENV_BIN).exists()
            || !Path::new("/sys/fs/cgroup/cgroup.controllers").exists()
        {
            return fail;
        }
        // The unit's command uses `env -i -C <dir>`; an `env` without `-C` would start nothing.
        let env_c = Command::new(unit::ENV_BIN)
            .args(["-i", "-C", "/", "/bin/true"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        if !env_c.is_ok_and(|s| s.success()) {
            return fail;
        }
        let Some(rt) = &s.runtime_dir else {
            return fail;
        };
        if !rt.is_dir() {
            return fail;
        }
        let state = s.run(
            "systemctl",
            &["--user", "is-system-running"],
            Duration::from_secs(10),
        );
        if !state.is_some_and(|(_, t)| matches!(t.trim(), "running" | "degraded")) {
            return fail;
        }
        Ok(())
    }

    fn selftest(&self) -> Result<(), &'static str> {
        let s = &self.sys;
        let fail = Err(UNVERIFIED);
        // Leftovers of a crashed earlier run.
        let Some(old) = s.list_prefixed(&self.selftest_prefix) else {
            return fail;
        };
        for u in old {
            if !s.stop(&u) {
                return fail;
            }
        }
        let daemon_unit = if self.require_unit_main {
            own_unit(s)
        } else {
            None
        };
        // The fixture is bound to the daemon's unit, so that unit must be one that ends with its
        // main process: not `RemainAfterExit`, not `ExitType=cgroup`, and a plain `simple`/`exec`
        // service. Anything else would keep the binding alive after the daemon is gone.
        if let Some(u) = &daemon_unit {
            let shape_ok = s.show(u, "RemainAfterExit").as_deref() == Some("no")
                && s.show(u, "ExitType")
                    .is_some_and(|t| t == "main" || t.is_empty())
                && s.show(u, "Type")
                    .is_some_and(|t| matches!(t.as_str(), "simple" | "exec" | "notify"));
            if !shape_ok {
                return fail;
            }
        }
        let base = format!("{}-{}", self.selftest_prefix, crate::state::random_hex(4));
        let mut fx = Fixture {
            sys: s,
            units: Vec::new(),
            // The daemon's own unit: the fixture parent is bound to it, so a daemon that dies
            // during the test takes the fixture with it at once, not at `RuntimeMaxSec`.
            daemon_unit,
        };
        let r = fx.run(&base);
        let clean = fx.cleanup();
        // A test that leaves anything behind did not pass.
        if r && clean && s.list_prefixed(&base).is_some_and(|l| l.is_empty()) {
            Ok(())
        } else {
            fail
        }
    }

    /// Does the mount namespace tier work for a transient user unit here? (V11)
    fn mount_probe(&self) -> bool {
        let (Some(root), Some(_)) = (&self.data_root, self.sys.find("systemd-run")) else {
            return false;
        };
        let Some(rw) = root
            .to_str()
            .filter(|r| r.starts_with('/') && !r.contains(char::is_whitespace))
        else {
            return false;
        };
        let rw_prop = format!("ReadWritePaths={rw}");
        // Named under the self-test prefix so a leftover is found by the next sweep of leftovers,
        // and bounded so it cannot outlive its probe.
        let name = format!(
            "{}-mount-{}",
            self.selftest_prefix,
            crate::state::random_hex(4)
        );
        let unit_arg = format!("--unit={name}");
        let probe = self.sys.run(
            "systemd-run",
            &[
                "--user",
                "--quiet",
                "--collect",
                "--wait",
                &unit_arg,
                "-p",
                "RuntimeMaxSec=20",
                "-p",
                "PrivateTmp=yes",
                "-p",
                "ProtectHome=read-only",
                "-p",
                "ProtectSystem=full",
                "-p",
                &rw_prop,
                "--",
                "/usr/bin/env",
                "test",
                "-w",
                rw,
            ],
            Duration::from_secs(15),
        );
        let gone = self.sys.stop(&format!("{name}.service"));
        probe.is_some_and(|(ok, _)| ok) && gone
    }
}

struct Fixture<'a> {
    sys: &'a Sys,
    units: Vec<String>,
    daemon_unit: Option<String>,
}

impl Fixture<'_> {
    fn start(&mut self, name: &str, props: &[&str], command: &[&str]) -> bool {
        let unit = format!("--unit={name}");
        let mut a: Vec<&str> = vec!["--user", "--quiet", "--collect", &unit];
        for p in props {
            a.push("-p");
            a.push(p);
        }
        a.push("--");
        a.extend_from_slice(command);
        self.units.push(format!("{name}.service"));
        self.sys
            .run("systemd-run", &a, Duration::from_secs(15))
            .is_some_and(|(ok, _)| ok)
    }

    fn wait(&self, timeout: Duration, mut f: impl FnMut() -> bool) -> bool {
        let end = Instant::now() + timeout;
        loop {
            if f() {
                return true;
            }
            if Instant::now() >= end {
                return false;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    fn run(&mut self, base: &str) -> bool {
        let started = Instant::now();
        let ok = self.run_inner(base);
        eprintln!(
            "browser: containment_selftest pass={ok} elapsed_ms={}",
            started.elapsed().as_millis()
        );
        ok
    }

    fn run_inner(&mut self, base: &str) -> bool {
        let s = self.sys;
        let (parent, child) = (format!("{base}-p"), format!("{base}-c"));
        let (parent_u, child_u) = (format!("{parent}.service"), format!("{child}.service"));
        let sleep = s.find("sleep").unwrap_or_default();
        let sleep = sleep.to_string_lossy().into_owned();
        // The parent plays the daemon: it restarts after a kill, like `oab-computer.service`. The
        // start limit and `RuntimeMaxSec` bound it if this process dies before cleanup.
        let mut parent_props: Vec<String> = [
            "KillMode=control-group",
            "Restart=always",
            "RestartSec=1",
            "StartLimitIntervalSec=30",
            "StartLimitBurst=3",
            "RuntimeMaxSec=20",
        ]
        .map(String::from)
        .into();
        if let Some(d) = &self.daemon_unit {
            parent_props.push(format!("BindsTo={d}"));
            parent_props.push(format!("After={d}"));
        }
        let parent_props: Vec<&str> = parent_props.iter().map(String::as_str).collect();
        if !self.start(&parent, &parent_props, &["/usr/bin/env", "-i", &sleep, "8"]) {
            return false;
        }
        if !self.wait(Duration::from_secs(3), || {
            s.active_state(&parent_u).as_deref() == Some("active")
        }) {
            return false;
        }
        let bind = format!("BindsTo={parent_u}");
        let after = format!("After={parent_u}");
        let child_props = [
            "KillMode=control-group",
            "RuntimeMaxSec=20",
            bind.as_str(),
            after.as_str(),
        ];
        let script = format!(
            "if command -v setsid >/dev/null 2>&1; then setsid {sleep} 30 </dev/null >/dev/null 2>&1 & \
             else ( {sleep} 30 </dev/null >/dev/null 2>&1 & ); fi; exec {sleep} 30"
        );
        if !self.start(&child, &child_props, &["/bin/sh", "-c", &script]) {
            return false;
        }
        // The fixture must really hold a detached grandchild, or a pass would mean nothing.
        let mut inside: Vec<(u32, u64)> = Vec::new();
        let ready = self.wait(Duration::from_secs(3), || {
            inside = s
                .cgroup_pids(&child_u)
                .unwrap_or_default()
                .into_iter()
                .filter_map(|p| crate::state::proc_start_time(p).map(|t| (p, t)))
                .collect();
            inside.len() >= 2 && s.active_state(&child_u).as_deref() == Some("active")
        });
        if !ready {
            return false;
        }
        // SIGKILL of the parent's main process: no handler runs, as with a daemon `kill -9`.
        if !s
            .systemctl(
                &["kill", "--kill-whom=main", "--signal=SIGKILL", &parent_u],
                Duration::from_secs(10),
            )
            .is_some_and(|(ok, _)| ok)
        {
            return false;
        }
        let gone = self.wait(Duration::from_secs(5), || {
            matches!(
                s.active_state(&child_u).as_deref(),
                Some("inactive" | "failed")
            ) && inside
                .iter()
                .all(|(p, t)| crate::state::proc_start_time(*p) != Some(*t))
        });
        if !gone {
            return false;
        }
        // The parent restarts (Restart=always). The child must stay down.
        let watch_end = Instant::now() + Duration::from_secs(4);
        let mut parent_back = false;
        while Instant::now() < watch_end {
            if s.active_state(&child_u).as_deref() == Some("active") {
                return false;
            }
            if s.active_state(&parent_u).as_deref() == Some("active") {
                if parent_back {
                    break;
                }
                parent_back = true;
            }
            std::thread::sleep(Duration::from_millis(300));
        }
        !matches!(
            s.active_state(&child_u).as_deref(),
            Some("active" | "activating")
        )
    }

    /// Stops every unit that was started, child first. True when none is left active.
    fn cleanup(&mut self) -> bool {
        let mut all = true;
        for u in self.units.iter().rev() {
            all &= self.sys.stop(u);
        }
        self.units.clear();
        all
    }
}

impl Drop for Fixture<'_> {
    fn drop(&mut self) {
        self.cleanup();
    }
}

impl Mechanism for Systemd {
    fn verify(&self) -> Result<Mode, &'static str> {
        if !cfg!(target_os = "linux") {
            return Err(UNVERIFIED);
        }
        // Tools and a user manager first: without them the answer is `containment_unverified`,
        // whatever else is true.
        self.precheck()?;
        if self.require_unit_main && own_unit(&self.sys).is_none() {
            return Err(NOT_UNIT_MAIN);
        }
        self.selftest()?;
        Ok(if self.mount_probe() {
            SYSTEMD_MOUNT
        } else {
            SYSTEMD
        })
    }

    fn spawn(&self, mode: Mode, kind: SpawnKind, l: &Launch) -> std::io::Result<Spawned> {
        let other = |m: &'static str| std::io::Error::other(m);
        let sr = self
            .sys
            .find("systemd-run")
            .ok_or_else(|| other(UNVERIFIED))?;
        let (name, k) = match kind {
            SpawnKind::Managed => {
                let daemon = own_unit(&self.sys).ok_or_else(|| other(NOT_UNIT_MAIN))?;
                (
                    format!("{}-{}", self.browser_prefix, crate::state::random_hex(4)),
                    Kind::Managed {
                        daemon_unit: daemon,
                    },
                )
            }
            SpawnKind::Cli { runtime_max } => (
                format!(
                    "{}-cli-{}",
                    self.browser_prefix,
                    crate::state::random_hex(4)
                ),
                Kind::Cli { runtime_max },
            ),
        };
        let req = Req {
            name: name.clone(),
            kind: k,
            cwd: l.cwd.clone(),
            env: l.env.clone(),
            exe: l.exe.clone(),
            args: l.args.clone(),
            mount_rw: if mode.mount_tier {
                l.rw_paths.clone()
            } else {
                Vec::new()
            },
            memory_max: l.memory_max,
            tasks_max: l.tasks_max,
        };
        let args = unit::run_args(&req).map_err(other)?;
        let spec = Spec {
            exe: sr,
            args,
            env: self.sys.env(),
            cwd: l.cwd.clone(),
        };
        let unit = format!("{name}.service");
        let sys = self.sys.clone();
        let ctl = UnitCtl {
            name: unit.clone(),
            stop: Box::new(move |u| {
                sys.stop(u);
            }),
        };
        let child = Child::spawn_with(&spec, true, true, l.line_cap, &l.scope, Some(ctl))?;
        Ok(Spawned {
            child,
            unit: Some(unit),
        })
    }

    fn stop_unit(&self, unit: &str) {
        // A run record is a file an application could rewrite: only a unit this daemon names.
        if unit.starts_with(&format!("{}-", self.browser_prefix)) {
            self.sys.stop(unit);
        }
    }
}

/// A mechanism that never verifies: non-Linux hosts and hosts with no user manager.
pub struct Unavailable(pub &'static str);

impl Mechanism for Unavailable {
    fn verify(&self) -> Result<Mode, &'static str> {
        Err(self.0)
    }
    fn spawn(&self, _: Mode, _: SpawnKind, _: &Launch) -> std::io::Result<Spawned> {
        Err(std::io::Error::other(self.0))
    }
    fn stop_unit(&self, _: &str) {}
}

/// A test double: spawns the program directly (no unit), with a scripted self-test result.
#[cfg(test)]
pub struct Direct {
    pub result: Result<Mode, &'static str>,
    pub verified: std::sync::atomic::AtomicUsize,
    pub spawned: std::sync::atomic::AtomicUsize,
    pub stopped: Mutex<Vec<String>>,
}

#[cfg(test)]
impl Direct {
    pub fn new(result: Result<Mode, &'static str>) -> Direct {
        Direct {
            result,
            verified: Default::default(),
            spawned: Default::default(),
            stopped: Mutex::new(Vec::new()),
        }
    }
}

#[cfg(test)]
impl Mechanism for Direct {
    fn verify(&self) -> Result<Mode, &'static str> {
        self.verified
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        self.result
    }
    fn spawn(&self, _: Mode, _: SpawnKind, l: &Launch) -> std::io::Result<Spawned> {
        self.spawned
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let spec = Spec {
            exe: l.exe.clone(),
            args: l.args.clone(),
            env: l.env.clone(),
            cwd: l.cwd.clone(),
        };
        Ok(Spawned {
            child: Child::spawn(&spec, true, true, l.line_cap, &l.scope)?,
            unit: None,
        })
    }
    fn stop_unit(&self, unit: &str) {
        if let Ok(mut g) = self.stopped.lock() {
            g.push(unit.to_string());
        }
    }
}

#[cfg(test)]
#[path = "containment_tests.rs"]
mod tests;
