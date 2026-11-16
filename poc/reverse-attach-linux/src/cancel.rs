//! Cooperative cancellation for the `browser` subcommands (L1b). SIGINT, SIGTERM and SIGHUP set one
//! flag. Download, npm and health-check loops look at it, return a fixed `cancelled` class, and the
//! staging guard then runs on the normal unwind path. SIGKILL cannot be caught; the next run's
//! sweep removes what it leaves.

use std::sync::atomic::{AtomicBool, Ordering};

static CANCELLED: AtomicBool = AtomicBool::new(false);

extern "C" {
    fn signal(signum: i32, handler: usize) -> usize;
}

extern "C" fn on_signal(_: i32) {
    // An atomic store is async-signal-safe.
    CANCELLED.store(true, Ordering::SeqCst);
}

/// Routes SIGHUP, SIGINT and SIGTERM to the flag. Called once by the `browser` entry point.
pub fn install_handlers() {
    for sig in [1, 2, 15] {
        // SAFETY: `on_signal` only performs an atomic store; `signal` has no other preconditions.
        unsafe {
            signal(sig, on_signal as extern "C" fn(i32) as usize);
        }
    }
}

pub fn is_cancelled() -> bool {
    CANCELLED.load(Ordering::Relaxed)
}
