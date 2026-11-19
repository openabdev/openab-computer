//! The sweep before every child start (ADR linux-browser-tier "Process containment", last layer of
//! the table; L2). It recovers from a crash: after a daemon `SIGKILL` the kernel mechanism has
//! normally ended the managed tree already, and this finds what any other route left behind. It
//! runs only at the next start, so it is never the guarantee.
//!
//! - It takes `.sweep.lock` with a non-blocking `flock`. While another start holds it the sweep is
//!   skipped, not waited for: that start is doing the same work. A start that goes on to spawn a
//!   child (`sweep_holding`) waits for the lock instead, and keeps it until its run record is
//!   written: a second start's sweep would otherwise kill the first one's new child, which no
//!   record claims yet.
//! - It kills every same-uid process whose executable lives under a version directory or a
//!   `.staging-*` directory of this root, through a pidfd (`proc::kill_matching`). A look-alike
//!   outside the root is never touched.
//! - A process claimed by a live run record is left alone: the PID itself, its process group or
//!   session, or the transient unit the record names. That is what keeps a running sign-in, or a
//!   running managed child, safe from the start of another one.
//! - Units named by dead run records are stopped, and those records are removed.
//!
//! The sweep kills a same-uid process whose executable is there even when the user started it by
//! hand from that directory. The ADR records this and `status` says so.

use std::path::Path;
use std::time::{Duration, Instant};

use rustix::fs::FlockOperation;

use crate::manifest::is_safe_id;
use crate::proc;
use crate::run_record::{self, Record};
use crate::state::{self, Fail, Root, DATA_DIRS, IO, R, SWEEP_LOCK_NAME};

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Another start holds the lock.
    Skipped,
    Swept {
        killed: usize,
        units_stopped: usize,
    },
}

/// True when `exe` is a file below a version directory or a staging directory of `root_abs`.
pub fn in_install_dirs(exe: &Path, root_abs: &Path) -> bool {
    let Ok(rest) = exe.strip_prefix(root_abs) else {
        return false;
    };
    let mut comps = rest.components();
    let Some(first) = comps.next().and_then(|c| c.as_os_str().to_str()) else {
        return false;
    };
    comps.next().is_some()
        && (state::is_staging_name(first) || (is_safe_id(first) && !DATA_DIRS.contains(&first)))
}

/// Does a live record claim `pid`?
pub(crate) fn claimed(pid: u32, live: &[Record]) -> bool {
    if live.is_empty() {
        return false;
    }
    let sf = proc::stat_fields(pid);
    let unit = proc::cgroup_unit(pid);
    live.iter().any(|r| {
        pid == r.pid
            || sf.is_some_and(|f| f.pgrp == r.pid || f.session == r.pid)
            || (r.unit.is_some() && r.unit == unit)
            || descends_from(pid, r.pid)
    })
}

/// Is `leader` an ancestor of `pid`? Without a unit (the plain fallback) a helper that called
/// `setsid` is in neither the leader's group nor its session, but while the leader lives it is
/// still in its parent chain. The walk is bounded, and stops at init.
fn descends_from(pid: u32, leader: u32) -> bool {
    let mut cur = pid;
    for _ in 0..64 {
        let Some(f) = proc::stat_fields(cur) else {
            return false;
        };
        if f.ppid == leader {
            return true;
        }
        if f.ppid <= 1 {
            return false;
        }
        cur = f.ppid;
    }
    false
}

/// The live run records of every child but `own_pid`, read afresh each time it is called. A
/// `Child::stop` asks for them so that its tree walk spares a sibling's processes. The root is
/// reopened from its path, so the closure owns no descriptor; if it cannot be reopened the answer
/// is `None` and the walk is skipped (fail closed: it could end a sibling's helpers; the next sweep
/// finds any straggler).
pub fn others_live(root: &Root, own_pid: u32) -> proc::OthersLive {
    let base = root
        .abs_path()
        .parent()
        .and_then(Path::parent)
        .map(Path::to_path_buf);
    Box::new(move || {
        let Some(base) = &base else {
            return None;
        };
        let Ok(Some(root)) = Root::open(base, false) else {
            return None;
        };
        Some(
            run_record::live(&root)
                .into_iter()
                .filter(|r| r.pid != own_pid)
                .collect(),
        )
    })
}

/// The sweep lock, held. A start that sweeps keeps it until its own run record is written, so that
/// another start's sweep cannot see its new child while it has no record and kill it (#132).
pub struct SweepGuard {
    _lock: std::os::fd::OwnedFd,
}

/// The non-blocking form of the sweep, as the requirements describe it (3.1 item 7): it takes
/// `.sweep.lock` without blocking and is `Skipped`, not blocked, while another sweep holds it. The
/// lock is released on return. Production starts use [`sweep_holding`], which makes the same first
/// attempt, waits a bounded time instead of giving up, and keeps the lock; this is that function
/// with no wait, and the tests pin its behaviour.
#[cfg(test)]
pub fn sweep_before_start(root: &Root, stop_unit: &dyn Fn(&str)) -> R<Outcome> {
    sweep_holding(root, stop_unit, Duration::ZERO).map(|(o, _)| o)
}

/// Runs the sweep. `stop_unit` stops a transient unit by name (a no-op where there is no
/// mechanism). Waits up to `wait` for the lock (zero: skip at once) and hands it back, so the caller
/// holds it until its child's record exists. `Skipped` with no
/// guard when the lock stayed held for the whole wait (a pathological case: the caller goes on
/// without a sweep, as before). A sweep error releases the lock.
pub fn sweep_holding(
    root: &Root,
    stop_unit: &dyn Fn(&str),
    wait: Duration,
) -> R<(Outcome, Option<SweepGuard>)> {
    let lock = state::open_named_lock(root, SWEEP_LOCK_NAME)?;
    let started = Instant::now();
    loop {
        match rustix::fs::flock(&lock, FlockOperation::NonBlockingLockExclusive) {
            Ok(()) => break,
            Err(rustix::io::Errno::WOULDBLOCK | rustix::io::Errno::INTR) => {}
            Err(_) => return Err(IO),
        }
        if started.elapsed() >= wait || crate::cancel::is_cancelled() {
            return Ok((Outcome::Skipped, None));
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    // The lock is released if the sweep fails: `lock` drops on the early return.
    let outcome = sweep_locked(root, stop_unit)?;
    Ok((outcome, Some(SweepGuard { _lock: lock })))
}

/// The sweep itself; the caller holds the sweep lock.
fn sweep_locked(root: &Root, stop_unit: &dyn Fn(&str)) -> R<Outcome> {
    // Units of dead records first: a unit is a cgroup, and stopping it ends what is in it.
    let mut units_stopped = 0;
    for (_, unit) in run_record::prune_dead(root) {
        if let Some(u) = unit {
            stop_unit(&u);
            units_stopped += 1;
        }
    }
    // Fail closed: with a `run/` too full to list, a live record could be hidden and its child swept.
    if run_record::saturated(root) {
        return Err(Fail("run_records_full"));
    }
    let live = run_record::live(root);
    let abs = root.abs_path().to_path_buf();
    let killed = proc::kill_matching(&|exe| in_install_dirs(exe, &abs), &|pid| {
        claimed(pid, &live)
    });
    Ok(Outcome::Swept {
        killed,
        units_stopped,
    })
}

#[cfg(test)]
#[path = "sweep_tests.rs"]
pub(crate) mod tests;
