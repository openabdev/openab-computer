//! Signals and the CLI-child supervisor (ADR "Process containment", D4; L2).
//!
//! # The daemon
//!
//! `install_daemon_handlers` routes `SIGTERM`, `SIGINT` and `SIGHUP` to a self-pipe. A thread reads
//! it, stops the managed child (unit stop, then process group, then the `/proc` tree walk, all in
//! `Supervisor::stop`), removes its run record and exits. A watchdog ends the process anyway after
//! `EXIT_BOUND`. The handler itself only writes one byte (async-signal-safe).
//!
//! # CLI children
//!
//! The health check of `browser install|update` and the child of `browser signin` are children of
//! the CLI. Each is bound to nothing but a `RuntimeMaxSec` (300 s for the check, 30 minutes for the
//! sign-in): a sign-in must survive a daemon restart. `SIGHUP`,
//! `SIGTERM` and `SIGINT` set the cancel flag (`cancel.rs`); the loops return, `Child::stop` stops
//! the unit and the process tree, and the run record goes with the guard. A `SIGKILL` of the CLI
//! cannot run any of that: the child's `PDEATHSIG` ends the leader, `RuntimeMaxSec` ends the unit,
//! and the next child start's sweep removes the rest (and stops the unit a dead run record names).
//! This is the documented limit, not a guarantee.
//!
//! Where no mechanism verifies, the CLI child still runs on the process-tree layers alone (R3.1
//! keeps working on a host without a user manager); only the managed daemon child requires the
//! kernel mechanism.

use std::any::Any;
use std::os::fd::{AsFd, BorrowedFd, RawFd};
use std::path::Path;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::child::Supervisor;
use crate::containment::{Availability, Launch, Mechanism, SpawnKind, Spawned};
use crate::proc::{Child, Spec};
use crate::run_record;
use crate::state::Root;

/// How long a stop may take before the process ends regardless.
pub const EXIT_BOUND: Duration = Duration::from_secs(25);
/// The bound on a CLI child's life in a unit (the health check's own timeouts sum to under this).
pub const CLI_RUNTIME_MAX: Duration = Duration::from_secs(300);

// ---- daemon signals -------------------------------------------------------------------------

static WRITE_FD: AtomicI32 = AtomicI32::new(-1);

extern "C" {
    fn signal(signum: i32, handler: usize) -> usize;
}

extern "C" fn on_signal(sig: i32) {
    let fd = WRITE_FD.load(Ordering::Relaxed);
    if fd >= 0 {
        // SAFETY: the fd stays open for the life of the process; `write` is async-signal-safe and a
        // full pipe (EAGAIN) is ignored on purpose.
        let b = unsafe { BorrowedFd::borrow_raw(fd as RawFd) };
        let _ = rustix::io::write(b, &[sig as u8]);
    }
}

/// Routes SIGHUP, SIGINT and SIGTERM to `on_stop`, which runs once on its own thread, and then the
/// process exits. Called once, by the daemon.
pub fn install_daemon_handlers(on_stop: impl Fn() + Send + 'static) -> std::io::Result<()> {
    let (rd, wr) = rustix::pipe::pipe().map_err(std::io::Error::from)?;
    for fd in [&rd, &wr] {
        rustix::io::fcntl_setfd(fd, rustix::io::FdFlags::CLOEXEC).map_err(std::io::Error::from)?;
    }
    rustix::fs::fcntl_setfl(&wr, rustix::fs::OFlags::NONBLOCK).map_err(std::io::Error::from)?;
    // The write end is never closed: the handler may run at any time.
    let wfd = std::os::fd::IntoRawFd::into_raw_fd(wr);
    WRITE_FD.store(wfd, Ordering::SeqCst);
    for sig in [1, 2, 15] {
        // SAFETY: `on_signal` only writes one byte to a pipe.
        unsafe {
            signal(sig, on_signal as extern "C" fn(i32) as usize);
        }
    }
    std::thread::Builder::new()
        .name("oab-signals".into())
        .spawn(move || {
            let mut b = [0u8; 1];
            loop {
                match rustix::io::read(rd.as_fd(), &mut b) {
                    Ok(1) => break,
                    Err(rustix::io::Errno::INTR) => {}
                    _ => return,
                }
            }
            eprintln!("browser: stopping signal={}", b[0]);
            std::thread::spawn(|| {
                std::thread::sleep(EXIT_BOUND);
                std::process::exit(1);
            });
            on_stop();
            std::process::exit(0);
        })?;
    Ok(())
}

static STOPPERS: Mutex<Vec<Arc<Supervisor>>> = Mutex::new(Vec::new());

/// A supervisor the signal thread must stop before the process exits.
pub fn register_stop(s: Arc<Supervisor>) {
    if let Ok(mut g) = STOPPERS.lock() {
        g.push(s);
    }
}

/// Stops every registered managed child, each bounded by the unit's own stop timeout.
pub fn stop_all() {
    let all: Vec<Arc<Supervisor>> = STOPPERS.lock().map(|g| g.clone()).unwrap_or_default();
    for s in all {
        s.stop();
    }
}

// ---- CLI children ---------------------------------------------------------------------------

/// A started CLI child and what must live as long as it does (its run record).
pub struct Launched {
    pub child: Child,
    _guard: Option<Box<dyn Any + Send>>,
}

impl Launched {
    #[cfg(test)]
    pub fn plain(child: Child) -> Launched {
        Launched {
            child,
            _guard: None,
        }
    }
}

/// How `browser install|update` starts the health check's child.
pub trait Launcher {
    fn launch(&self, root: &Root, spec: &Spec, scope: &Path) -> std::io::Result<Launched>;
}

/// The process-tree layers of `proc.rs` only.
pub struct Plain;

impl Launcher for Plain {
    fn launch(&self, root: &Root, spec: &Spec, scope: &Path) -> std::io::Result<Launched> {
        let mut child = Child::spawn(spec, true, true, crate::health::MAX_LINE, scope)?;
        // The same record and sibling protection as the unit path: two same-version CLI children
        // without a unit must not kill each other's tree when one stops. Best effort, like there.
        let rec = run_record::write(root, "cli", child.pid(), None).ok();
        child.set_others(crate::sweep::others_live(root, child.pid()));
        Ok(Launched {
            child,
            _guard: rec.map(|r| Box::new(r) as Box<dyn Any + Send>),
        })
    }
}

/// Sweep, then a transient unit with `RuntimeMaxSec` when the mechanism verifies; the plain layers
/// when it does not.
pub struct Supervised {
    avail: Arc<Availability>,
    runtime_max: Duration,
}

impl Supervised {
    pub fn new(mech: Arc<dyn Mechanism>) -> Supervised {
        Supervised {
            avail: Arc::new(Availability::new(mech)),
            runtime_max: CLI_RUNTIME_MAX,
        }
    }

    /// A longer (or shorter) bound on the unit's life than the health check's.
    pub fn with_runtime_max(mut self, d: Duration) -> Supervised {
        self.runtime_max = d;
        self
    }
}

impl Launcher for Supervised {
    fn launch(&self, root: &Root, spec: &Spec, scope: &Path) -> std::io::Result<Launched> {
        let mech = Arc::clone(self.avail.mechanism());
        // Recovery from an earlier CLI that was killed. Waits (bounded) for another start's sweep
        // and keeps the sweep lock until this child's record is written, so a second start cannot
        // kill the new child while no record claims it. `.install.lock` is not taken here: `install`
        // and `update` call this launcher while holding it exclusively, in this same process.
        let sweep_guard = crate::sweep::sweep_holding(
            root,
            &|u| mech.stop_unit(u),
            std::time::Duration::from_secs(10),
        )
        .ok()
        .and_then(|(_, guard)| guard);
        let Ok(mode) = self.avail.get() else {
            eprintln!("browser: cli_child containment=none");
            return Plain.launch(root, spec, scope);
        };
        let l = Launch {
            exe: spec.exe.clone(),
            args: spec.args.clone(),
            env: spec.env.clone(),
            cwd: spec.cwd.clone(),
            scope: scope.to_path_buf(),
            line_cap: crate::health::MAX_LINE,
            rw_paths: Vec::new(),
            memory_max: crate::child::memory_max_for(None),
            tasks_max: crate::child::TASKS_MAX,
        };
        let kind = SpawnKind::Cli {
            runtime_max: self.runtime_max,
        };
        // A unit that cannot be made (a path systemd would split, a manager that went away) leaves
        // the CLI child on the process-tree layers: only the daemon's child needs the kernel.
        let Ok(Spawned { mut child, unit }) = mech.spawn(mode, kind, &l) else {
            eprintln!("browser: cli_child containment=none");
            return Plain.launch(root, spec, scope);
        };
        // Best effort: a first install has no `run/` yet, and then there is nothing to protect.
        let rec = run_record::write(root, "cli", child.pid(), unit.as_deref()).ok();
        drop(sweep_guard);
        child.set_others(crate::sweep::others_live(root, child.pid()));
        Ok(Launched {
            child,
            _guard: rec.map(|r| Box::new(r) as Box<dyn Any + Send>),
        })
    }
}

#[cfg(test)]
#[path = "sigstop_tests.rs"]
mod tests;
