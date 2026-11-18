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
//!   `tcp=N udp=N unix=N unix_outside=N tmpdir=S result=pass|fail` (see `listeners_word`) or
//!   `unknown` when a table cannot be read.
//! - `refusal`: `none`, `launch_refused` or `sandbox_unavailable`.
//!
//! L4 adds four more, appended after those so existing readers keep their order:
//!
//! - `hardening_base`: `not_checked` (no `--retry`), `verified`, `partial` or `unverified` (the
//!   self-test or the base probe failed). `verified` means every base probe token read `1`.
//! - `hardening_mount`: `not_checked`, `verified`, `partial` (applied, some token not `1`),
//!   `dropped` (the tier does not apply on this host), `not_applicable` (no install root yet) or
//!   `unverified` (a `--retry` check ran and failed).
//! - `hardening_unverified`: `not_checked`, `unverified` (a failed `--retry`), `none`, or a comma list of the probe tokens that did
//!   not read `1` in an applied tier (`hardening.rs` holds the fixed vocabulary).
//! - `run_records`: `ok`, `full` (a managed start would refuse with `run_records_full`) or
//!   `unavailable` (`run/` missing, unmarked or unreadable).
//!
//! L5 appends three more, the legacy listing of `legacy.rs`: `legacy_units`, `legacy` and
//! `legacy_listener`. They are filled by `Extras::set_legacy`, outside `gather`, because they look at
//! the home directory and not at the data root.

use std::path::Path;

use crate::backend::{parse_upstream_line, BROWSER};
use crate::containment::Mode;
use crate::hardening::Tiers;
use crate::procnet::{self, Source};
use crate::run_record::{self, RunRecords};
use crate::state::Root;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Extras {
    pub containment: String,
    pub external_configured: &'static str,
    pub listeners: String,
    pub refusal: String,
    pub hardening_base: String,
    pub hardening_mount: String,
    pub hardening_unverified: String,
    pub run_records: String,
    pub legacy_units: String,
    pub legacy: String,
    pub legacy_listener: String,
}

impl Extras {
    pub fn none() -> Extras {
        Extras {
            containment: "not_checked".into(),
            external_configured: "no",
            listeners: "not_running".into(),
            refusal: "none".into(),
            hardening_base: Tiers::NONE.base_state().into(),
            hardening_mount: Tiers::NONE.mount_state().into(),
            hardening_unverified: Tiers::NONE.unverified_text(),
            // Without an install root there is no `run/`.
            run_records: RunRecords::Unavailable.word().into(),
            legacy_units: "none".into(),
            legacy: "none".into(),
            legacy_listener: "none".into(),
        }
    }

    /// Fills the three legacy fields (L5).
    pub fn set_legacy(&mut self, l: crate::legacy::Legacy) {
        self.legacy_units = l.units;
        self.legacy = l.paths;
        self.legacy_listener = l.listener;
    }

    /// Something of the old external setup was found (`unknown` is not a finding).
    pub fn legacy_present(&self) -> bool {
        crate::legacy::Legacy {
            units: self.legacy_units.clone(),
            paths: self.legacy.clone(),
            listener: self.legacy_listener.clone(),
        }
        .present()
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

/// The `listeners` field. `none`, `unknown`, or the counts with the V2 verdict:
/// `tcp=N udp=N unix=N unix_outside=N tmpdir=<state> result=pass|fail` (R1.1 as decided: only
/// Unix listeners inside the child's verified private `TMPDIR` pass).
pub(crate) fn listeners_word(
    l: Result<procnet::Listeners, &'static str>,
    tmp: procnet::TmpState,
) -> String {
    match l {
        Ok(l) if l.total() == 0 => "none".into(),
        Ok(l) => format!(
            "tcp={} udp={} unix={} unix_outside={} tmpdir={} result={}",
            l.tcp,
            l.udp,
            l.unix,
            l.unix_outside,
            tmp.word(),
            if l.passes_v2() { "pass" } else { "fail" }
        ),
        Err(_) => "unknown".into(),
    }
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
        x.run_records = run_record::state(&root).word().into();
        let pids = tree_pids(root.abs_path());
        if !pids.is_empty() {
            let tmp = crate::child::RuntimeTmp::expected_path(root.abs_path());
            let tmp_state = procnet::tmp_state(&tmp, rustix::process::geteuid().as_raw());
            // The directory is resolved once here; a link in its path is followed (V2).
            let private = (tmp_state == procnet::TmpState::Ok)
                .then(|| std::fs::canonicalize(&tmp).ok())
                .flatten();
            x.listeners = listeners_word(
                procnet::listeners_of_tree_in(src, &pids, private.as_deref()),
                tmp_state,
            );
        }
    }
    if retry {
        match verify() {
            Ok(m) => {
                x.containment = m.name.to_string();
                x.hardening_base = m.tiers.base_state().into();
                x.hardening_mount = m.tiers.mount_state().into();
                x.hardening_unverified = m.tiers.unverified_text();
            }
            Err(_) => {
                x.containment = "unverified".to_string();
                x.hardening_base = "unverified".to_string();
                x.hardening_mount = "unverified".to_string();
                x.hardening_unverified = "unverified".to_string();
            }
        }
    }
    x
}

#[cfg(test)]
#[path = "probe_tests.rs"]
mod tests;
