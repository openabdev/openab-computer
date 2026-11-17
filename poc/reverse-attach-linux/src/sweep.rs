//! The sweep before every child start (ADR linux-browser-tier "Process containment", last layer of
//! the table; L2). It recovers from a crash: after a daemon `SIGKILL` the kernel mechanism has
//! normally ended the managed tree already, and this finds what any other route left behind. It
//! runs only at the next start, so it is never the guarantee.
//!
//! - It takes `.sweep.lock` with a non-blocking `flock`. While another start holds it the sweep is
//!   skipped, not waited for: that start is doing the same work.
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

use rustix::fs::FlockOperation;

use crate::manifest::is_safe_id;
use crate::proc;
use crate::run_record::{self, Record};
use crate::state::{self, Root, DATA_DIRS, IO, R, SWEEP_LOCK_NAME};

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
fn claimed(pid: u32, live: &[Record]) -> bool {
    if live.is_empty() {
        return false;
    }
    let sf = proc::stat_fields(pid);
    let unit = proc::cgroup_unit(pid);
    live.iter().any(|r| {
        pid == r.pid
            || sf.is_some_and(|f| f.pgrp == r.pid || f.session == r.pid)
            || (r.unit.is_some() && r.unit == unit)
    })
}

/// Runs the sweep. `stop_unit` stops a transient unit by name (a no-op where there is no
/// mechanism). Never blocks on the lock.
pub fn sweep_before_start(root: &Root, stop_unit: &dyn Fn(&str)) -> R<Outcome> {
    let lock = state::open_named_lock(root, SWEEP_LOCK_NAME)?;
    match rustix::fs::flock(&lock, FlockOperation::NonBlockingLockExclusive) {
        Ok(()) => {}
        Err(rustix::io::Errno::WOULDBLOCK) => return Ok(Outcome::Skipped),
        Err(_) => return Err(IO),
    }
    // Units of dead records first: a unit is a cgroup, and stopping it ends what is in it.
    let mut units_stopped = 0;
    for (_, unit) in run_record::prune_dead(root) {
        if let Some(u) = unit {
            stop_unit(&u);
            units_stopped += 1;
        }
    }
    let live = run_record::live(root);
    let abs = root.abs_path().to_path_buf();
    let killed = proc::kill_matching(&|exe| in_install_dirs(exe, &abs), &|pid| {
        claimed(pid, &live)
    });
    drop(lock);
    Ok(Outcome::Swept {
        killed,
        units_stopped,
    })
}

#[cfg(test)]
#[path = "sweep_tests.rs"]
pub(crate) mod tests;
