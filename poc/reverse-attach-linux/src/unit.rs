//! The `systemd-run --user` command line of a transient browser unit (ADR linux-browser-tier
//! "Process containment", D4, R6.1, R6.2; L2). Pure: it builds a vector and starts nothing, so the
//! whole property list is tested on any host.
//!
//! - The unit is transient (`--collect`, written nowhere) and runs with `--pipe`, so the daemon's
//!   stdin and stdout pipes are the child's.
//! - The command begins `/usr/bin/env -i`, then `-C <cwd>`, then exactly the allow-listed
//!   `NAME=value` pairs. There is no `-E` and no `--setenv`: without `env -i` a user service
//!   inherits the user manager's environment, which can hold bearer, cloud or `GH_*` values. The
//!   working directory is set by `env -C` and not by systemd's `WorkingDirectory=`, which
//!   systemd 257 refuses ("bad unit file setting") together with `ProtectHome`, `ProtectSystem`
//!   or `ReadWritePaths` for some paths (measured on arm64 Debian 13).
//! - Managed (daemon) children are `BindsTo` and `After` the daemon unit, so the kernel ends the
//!   whole control group when the daemon unit goes down, `SIGKILL` and out-of-memory kill included.
//!   CLI children are bound to nothing but a `RuntimeMaxSec`: a sign-in must survive a daemon
//!   restart, and a `SIGKILL` of the CLI is cleaned by the next start's sweep (ADR).
//! - Never set: `RestrictNamespaces`, `MemoryDenyWriteExecute`, `SystemCallFilter`, `PrivateDevices`
//!   (Chromium's sandbox and V8 need them; R6.2).
//!
//! Every value reaches `systemd-run` as its own argv element, so nothing is shell-parsed. Names and
//! paths that systemd would split or reinterpret are refused with `unit_request_invalid`.

use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::run_record::is_unit_name;

pub const ENV_BIN: &str = "/usr/bin/env";

/// The properties both kinds of browser unit carry.
pub const COMMON_PROPS: [&str; 10] = [
    "KillMode=control-group",
    "SendSIGKILL=yes",
    "TimeoutStopSec=10",
    "NoNewPrivileges=yes",
    "RestrictSUIDSGID=yes",
    "LockPersonality=yes",
    "RestrictRealtime=yes",
    "ProtectKernelTunables=yes",
    "ProtectKernelModules=yes",
    "ProtectControlGroups=yes",
];

/// Property names that must never appear (R6.2).
#[cfg(test)]
pub const NEVER: [&str; 4] = [
    "RestrictNamespaces",
    "MemoryDenyWriteExecute",
    "SystemCallFilter",
    "PrivateDevices",
];

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Kind {
    /// `BindsTo` and `After` this unit (name with `.service`).
    Managed { daemon_unit: String },
    /// `RuntimeMaxSec`, bound to nothing.
    Cli { runtime_max: Duration },
}

#[derive(Clone, Debug)]
pub struct Req {
    /// Unit name without the `.service` suffix.
    pub name: String,
    pub kind: Kind,
    pub cwd: PathBuf,
    /// The whole environment of the child, in order.
    pub env: Vec<(String, String)>,
    pub exe: PathBuf,
    pub args: Vec<String>,
    /// Non-empty adds the mount namespace tier, with these as `ReadWritePaths` (the data root and
    /// the child's `TMPDIR`: `ProtectHome=read-only` also covers `/run/user`). Only where a probe
    /// showed the tier works (V11).
    pub mount_rw: Vec<PathBuf>,
    pub memory_max: u64,
    pub tasks_max: u32,
}

pub const INVALID: &str = "unit_request_invalid";

fn env_name_ok(n: &str) -> bool {
    !n.is_empty()
        && n.len() <= 64
        && !n.starts_with(|c: char| c.is_ascii_digit())
        && n.bytes()
            .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'_')
}

/// One word of the command line. `$` and `%` are refused: `systemd-run` expands `${VAR}` and `%`
/// specifiers in the command, which would let a value change what runs.
fn text_ok(s: &str) -> bool {
    s.len() <= 4096 && !s.contains(['\0', '\n', '\r', '$', '%'])
}

/// A path that is one word to systemd: absolute, no whitespace, no `%` specifier, no `:` prefix
/// flags, no control characters.
fn unit_path_ok(p: &Path) -> bool {
    p.to_str().is_some_and(|s| {
        s.starts_with('/')
            && s.len() <= 1024
            && !s
                .chars()
                .any(|c| c.is_whitespace() || c.is_control() || c == '%')
    })
}

/// The argv that follows the `systemd-run` program name. Fails closed on anything unusual.
pub fn run_args(r: &Req) -> Result<Vec<String>, &'static str> {
    if !is_unit_name(&format!("{}.service", r.name))
        || !r.name.starts_with("oab-")
        || !r.cwd.is_absolute()
        || r.cwd.to_str().is_none_or(|s| !text_ok(s))
        || !r.exe.is_absolute()
        || r.exe
            .to_str()
            .is_none_or(|s| !text_ok(s) || s.contains('='))
        || r.args.iter().any(|a| !text_ok(a))
        || r.env.iter().any(|(k, v)| !env_name_ok(k) || !text_ok(v))
    {
        return Err(INVALID);
    }
    let mut a: Vec<String> = vec![
        "--user".into(),
        "--quiet".into(),
        "--collect".into(),
        "--pipe".into(),
        format!("--unit={}", r.name),
    ];
    let mut prop = |p: String| {
        a.push("-p".into());
        a.push(p);
    };
    for p in COMMON_PROPS {
        prop(p.to_string());
    }
    prop("UMask=0077".into());
    prop(format!("MemoryMax={}", r.memory_max));
    prop(format!("TasksMax={}", r.tasks_max));
    match &r.kind {
        Kind::Managed { daemon_unit } => {
            if !is_unit_name(daemon_unit) {
                return Err(INVALID);
            }
            prop(format!("BindsTo={daemon_unit}"));
            prop(format!("After={daemon_unit}"));
        }
        Kind::Cli { runtime_max } => {
            prop(format!("RuntimeMaxSec={}", runtime_max.as_secs().max(1)));
        }
    }
    if !r.mount_rw.is_empty() {
        if r.mount_rw.iter().any(|p| !unit_path_ok(p)) {
            return Err(INVALID);
        }
        let list: Vec<String> = r.mount_rw.iter().map(|p| p.display().to_string()).collect();
        prop("PrivateTmp=yes".into());
        prop("ProtectHome=read-only".into());
        prop("ProtectSystem=full".into());
        prop(format!("ReadWritePaths={}", list.join(" ")));
    }
    a.push("--".into());
    a.push(ENV_BIN.into());
    a.push("-i".into());
    a.push("-C".into());
    a.push(r.cwd.display().to_string());
    for (k, v) in &r.env {
        a.push(format!("{k}={v}"));
    }
    a.push(r.exe.display().to_string());
    a.extend(r.args.iter().cloned());
    Ok(a)
}

#[cfg(test)]
#[path = "unit_tests.rs"]
mod tests;
