//! The fixed `browser status` fields L2 adds (R6.4): `containment`, `external_configured`,
//! `listeners` and the recorded `refusal` (D17). Every value is one of a small fixed vocabulary:
//! no URL, no path, no address, no token and no page data can appear.
//!
//! - `containment`: `not_checked` by default (the CLI is not the daemon, and the daemon's own answer
//!   is in `sys_info`); with `--retry` the self-test runs now, in this process, and the answer is
//!   `systemd`, `systemd+mount` or `unverified`. `--retry` also removes the latch file in `run/`,
//!   which is how the daemon is told to forget its five-failure latch and its cached answer (R1.5).
//! - `external_configured`: `yes` when this process's `MCP_UPSTREAM` has a `browser=` entry.
//! - `listeners`: what the managed tree (every same-uid process whose executable is below a version
//!   or staging directory of the root, the sweep's own rule) holds. `not_running`, `none`,
//!   `tcp=N udp=N unix=N` or `unknown` when a table cannot be read.
//! - `refusal`: `none`, `launch_refused` or `sandbox_unavailable`.

use std::path::Path;

use crate::backend::{parse_upstream_line, BROWSER};
use crate::containment::Mode;
use crate::procnet::{self, Source};
use crate::run_record;
use crate::state::Root;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Extras {
    pub containment: String,
    pub external_configured: &'static str,
    pub listeners: String,
    pub refusal: String,
}

impl Extras {
    pub fn none() -> Extras {
        Extras {
            containment: "not_checked".into(),
            external_configured: "no",
            listeners: "not_running".into(),
            refusal: "none".into(),
        }
    }
}

/// The pids of the managed tree, by the sweep's rule.
fn tree_pids(root_abs: &Path) -> Vec<u32> {
    let me = std::process::id();
    crate::proc::proc_pids()
        .into_iter()
        .filter(|p| *p != me)
        .filter(|p| {
            crate::proc::same_uid(*p)
                && std::fs::read_link(format!("/proc/{p}/exe"))
                    .is_ok_and(|e| crate::sweep::in_install_dirs(&e, root_abs))
        })
        .collect()
}

/// `verify` runs the containment self-test (only called with `retry`).
pub fn gather(
    base: &Path,
    retry: bool,
    upstream_env: Option<&str>,
    src: &dyn Source,
    verify: &dyn Fn() -> Result<Mode, &'static str>,
) -> Extras {
    let mut x = Extras::none();
    x.external_configured = if upstream_env
        .map(parse_upstream_line)
        .is_some_and(|l| l.iter().any(|(n, _)| n == BROWSER))
    {
        "yes"
    } else {
        "no"
    };
    if let Ok(Some(root)) = Root::open(base, false) {
        if retry {
            run_record::latch_clear(&root);
        }
        x.refusal = run_record::refusal_get(&root).unwrap_or_else(|| "none".into());
        let pids = tree_pids(root.abs_path());
        if !pids.is_empty() {
            x.listeners = match procnet::listeners_of_tree(src, &pids) {
                Ok(l) if l.total() == 0 => "none".into(),
                Ok(l) => format!("tcp={} udp={} unix={}", l.tcp, l.udp, l.unix),
                Err(_) => "unknown".into(),
            };
        }
    }
    if retry {
        x.containment = match verify() {
            Ok(m) => m.name.to_string(),
            Err(_) => "unverified".to_string(),
        };
    }
    x
}

#[cfg(test)]
#[path = "probe_tests.rs"]
mod tests;
