//! Hardening tiers and their probes (ADR linux-browser-tier "Process containment", V11; R6.2; L4).
//!
//! A property that systemd accepts is not a property that is in force: a user manager without the
//! memory controller delegated accepts `MemoryMax` and enforces nothing, and a host that cannot give
//! a user unit a mount namespace accepts `PrivateTmp` and fails the start. So each tier is
//! checked by its effect, from inside a transient unit that carries exactly the property list the
//! managed child carries for that tier (the lists come from `unit::base_props` and
//! `unit::mount_props`, the same functions `run_args` uses).
//!
//! - **base tier**: every property the ADR always sets. Applied on every host. Individual results
//!   never stop a start; they are reported.
//! - **mount tier**: `PrivateTmp`, `ProtectHome=read-only`, `ProtectSystem=full` and
//!   `ReadWritePaths` (the data root and the child's `TMPDIR`), applied where the probe shows the
//!   child can write what it needs (`rw_paths`) and `ProtectHome=read-only` is not shown to be
//!   without effect (V11, `mount_applies`). Otherwise it is dropped, and status says so.
//!
//! A probe prints `token=1|0|na` lines. `1` is "the effect is observed", `0` "the effect is absent"
//! and `na` "this host cannot show it either way". `0` and `na` both mean *not verified*: a tier is
//! reported `verified` only when every one of its tokens is `1`. Host-supplied values reach the
//! probe script only as positional parameters, never inside the script text.
//!
//! systemd expands `${VAR}` in the arguments of `systemd-run` and reads `$$` as `$`, so every
//! argument is escaped on its way out and the scripts below are written as plain shell. They contain
//! no `%` (whether systemd reads `%%` as `%` in a transient command depends on its version), and a
//! host value with one is not passed.

use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::containment::Sys;
use crate::unit;

/// One probe result.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Val {
    /// The effect is observed.
    One,
    /// The effect is absent.
    Zero,
    /// The host cannot show it either way, or the probe did not answer.
    Na,
}

pub const BASE_TOKENS: [&str; 8] = [
    "no_new_privs",
    "seccomp_filter",
    "umask",
    "memory_max",
    "tasks_max",
    "kernel_tunables",
    "control_groups",
    "kernel_modules",
];

pub const MOUNT_TOKENS: [&str; 4] = ["private_tmp", "protect_home", "protect_system", "rw_paths"];

pub type BaseVals = [Val; BASE_TOKENS.len()];
pub type MountVals = [Val; MOUNT_TOKENS.len()];

/// What is known about the mount tier.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MountTier {
    /// Not probed (a double, or a mechanism that never ran its probes).
    NotProbed,
    /// There is no install root yet, so there is no data root to probe.
    NotApplicable,
    /// Not applied: the probe unit did not start or the child could not write what it needs.
    Dropped,
    /// Applied; the four results.
    Applied(MountVals),
}

/// What the probes found. `Copy`, so `Mode` stays `Copy`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Tiers {
    /// `None`: the base probe did not run.
    pub base: Option<BaseVals>,
    pub mount: MountTier,
}

impl Tiers {
    /// "Not probed". The constants `SYSTEMD` and `SYSTEMD_MOUNT` carry this.
    pub const NONE: Tiers = Tiers {
        base: None,
        mount: MountTier::NotProbed,
    };

    /// `not_checked`, `verified` or `partial`.
    pub fn base_state(&self) -> &'static str {
        match &self.base {
            None => "not_checked",
            Some(v) if all_one(v) => "verified",
            Some(_) => "partial",
        }
    }

    /// `not_checked`, `not_applicable`, `dropped`, `verified` or `partial`.
    pub fn mount_state(&self) -> &'static str {
        match &self.mount {
            MountTier::NotProbed => "not_checked",
            MountTier::NotApplicable => "not_applicable",
            MountTier::Dropped => "dropped",
            MountTier::Applied(v) if all_one(v) => "verified",
            MountTier::Applied(_) => "partial",
        }
    }

    /// The tokens of the applied tiers that are not `1`, from the fixed vocabulary only.
    pub fn unverified_tokens(&self) -> Vec<&'static str> {
        let mut out = Vec::new();
        if let Some(b) = &self.base {
            out.extend(unverified(&BASE_TOKENS, b));
        }
        if let MountTier::Applied(m) = &self.mount {
            out.extend(unverified(&MOUNT_TOKENS, m));
        }
        out
    }

    /// `not_checked` when no probe ran, `none` when every token of every applied tier is `1`, else
    /// a comma list of the tokens that are not.
    pub fn unverified_text(&self) -> String {
        if self.base.is_none() && self.mount == MountTier::NotProbed {
            return "not_checked".into();
        }
        let t = self.unverified_tokens();
        if t.is_empty() {
            "none".into()
        } else {
            t.join(",")
        }
    }

    /// The one stderr line the daemon logs after verifying.
    pub fn log_line(&self) -> String {
        format!(
            "browser: hardening base={} mount={} unverified={}",
            self.base_state(),
            self.mount_state(),
            self.unverified_text()
        )
    }
}

fn all_one(v: &[Val]) -> bool {
    v.iter().all(|x| *x == Val::One)
}

fn unverified(names: &[&'static str], v: &[Val]) -> Vec<&'static str> {
    names
        .iter()
        .zip(v)
        .filter(|(_, x)| **x != Val::One)
        .map(|(n, _)| *n)
        .collect()
}

// ---- the probe scripts -----------------------------------------------------------------------
//
// Plain POSIX shell, builtins only (the unit runs under `env -i`, so PATH is unset), except `stat`
// for `private_tmp`. Every value comes in as a positional parameter.

/// `$1` the mountinfo file to read, `$2` memory bytes requested, `$3` tasks requested, `$4` a
/// modules directory that is traversable on the host, or `-` when there is none.
pub const BASE_SCRIPT: &str = r#"
p() { echo "$1=$2"; }
umask_v=$(umask)
nnp=na
sec=na
if [ -r /proc/self/status ]; then
  while read -r k v; do
    case "$k" in NoNewPrivs:) nnp=$v;; Seccomp:) sec=$v;; esac
  done < /proc/self/status
fi
cg=
if [ -r /proc/self/cgroup ]; then
  while read -r line; do
    case "$line" in 0::*) cg=${line#0::};; esac
  done < /proc/self/cgroup
fi
mem=na
pids=na
if [ -n "$cg" ]; then
  if [ -r "/sys/fs/cgroup$cg/memory.max" ]; then read -r mem < "/sys/fs/cgroup$cg/memory.max"; fi
  if [ -r "/sys/fs/cgroup$cg/pids.max" ]; then read -r pids < "/sys/fs/cgroup$cg/pids.max"; fi
fi
kt=na
cgm=na
if [ -r "$1" ]; then
  while read -r a b c root mp opts rest; do
    case "$mp" in
      /proc/sys) case ",$opts," in *,ro,*) kt=1;; *) kt=0;; esac;;
      /sys/fs/cgroup) case ",$opts," in *,ro,*) cgm=1;; *) cgm=0;; esac;;
    esac
  done < "$1"
fi
km=na
if [ "$4" != - ]; then
  if (cd "$4") 2>/dev/null; then km=0; else km=1; fi
fi
case "$nnp" in 1) p no_new_privs 1;; na) p no_new_privs na;; *) p no_new_privs 0;; esac
case "$sec" in 2) p seccomp_filter 1;; na) p seccomp_filter na;; *) p seccomp_filter 0;; esac
case "$umask_v" in 0077|077) p umask 1;; *) p umask 0;; esac
case "$mem" in na) p memory_max na;; "$2") p memory_max 1;; *) p memory_max 0;; esac
case "$pids" in na) p tasks_max na;; "$3") p tasks_max 1;; *) p tasks_max 0;; esac
p kernel_tunables "$kt"
p control_groups "$cgm"
p kernel_modules "$km"
"#;

/// `$1` the mountinfo file to read, `$2` a home directory that is writable on the host or `-`,
/// `$3` `1` when `/etc` is already a read-only mount on the host, then the `ReadWritePaths`.
///
/// `private_tmp` is read from the mount table: with `PrivateTmp=yes`, `/tmp` is a bind mount of a
/// `systemd-private-*` directory. (No `stat` and no `%`: see `escape`.)
pub const MOUNT_SCRIPT: &str = r#"
p() { echo "$1=$2"; }
pt=na
ps=na
if [ -r "$1" ]; then
  pt=0
  if [ "$3" != 1 ]; then ps=0; fi
  while read -r a b c root mp opts rest; do
    case "$mp" in
      /tmp) case "$root" in *systemd-private-*) pt=1;; *) pt=0;; esac;;
      /etc) if [ "$3" != 1 ]; then case ",$opts," in *,ro,*) ps=1;; *) ps=0;; esac; fi;;
    esac
  done < "$1"
fi
ph=na
if [ "$2" != - ]; then
  if [ -w "$2" ]; then ph=0; else ph=1; fi
fi
shift 3
rw=1
n=0
for q in "$@"; do
  n=$((n + 1))
  [ -w "$q" ] || rw=0
done
[ "$n" -ge 1 ] || rw=na
p private_tmp "$pt"
p protect_home "$ph"
p protect_system "$ps"
p rw_paths "$rw"
"#;

/// Escapes one `systemd-run` argument: systemd expands `${VAR}` in it and reads `$$` as `$`.
///
/// `%` is not escaped, because whether systemd reads `%%` as `%` in a transient unit's command
/// depends on its version (255 leaves it alone, and `%h` too). So no probe argument may contain a
/// `%` at all: the scripts have none, and `probe_argv` refuses a host value that does.
pub fn escape(arg: &str) -> String {
    arg.replace('$', "$$")
}

/// The argv after `systemd-run` for a probe unit: transient, collected, piped, bounded to 20 s,
/// carrying `props`, running `script` with `args` as positional parameters under `env -i`. `None`
/// when any piece contains a `%` (see `escape`).
pub fn probe_argv(
    unit: &str,
    props: &[String],
    script: &str,
    args: &[String],
) -> Option<Vec<String>> {
    if script.contains('%') || args.iter().chain(props).any(|x| x.contains('%')) {
        return None;
    }
    let mut a: Vec<String> = vec![
        "--user".into(),
        "--quiet".into(),
        "--collect".into(),
        "--pipe".into(),
        format!("--unit={unit}"),
        "-p".into(),
        "RuntimeMaxSec=20".into(),
    ];
    for p in props {
        a.push("-p".into());
        a.push(p.clone());
    }
    a.push("--".into());
    a.push(unit::ENV_BIN.into());
    a.push("-i".into());
    a.push("/bin/sh".into());
    a.push("-c".into());
    a.push(escape(script));
    a.push("sh".into());
    a.extend(args.iter().map(|x| escape(x)));
    Some(a)
}

/// Parses a probe's output. `None` unless every line is `token=value` with a known token and a
/// value of `1`, `0` or `na`, no token appears twice, at least one token appears, and the output is
/// under the 64 KiB cap. A token that is missing reads `Na`.
pub fn parse(out: &str, tokens: &[&str]) -> Option<Vec<Val>> {
    if out.len() >= 64 * 1024 {
        return None;
    }
    let mut vals: Vec<Option<Val>> = vec![None; tokens.len()];
    let mut any = false;
    for line in out.lines() {
        let line = line.trim_end();
        if line.is_empty() {
            continue;
        }
        let (k, v) = line.split_once('=')?;
        let i = tokens.iter().position(|t| *t == k)?;
        let v = match v {
            "1" => Val::One,
            "0" => Val::Zero,
            "na" => Val::Na,
            _ => return None,
        };
        if vals[i].replace(v).is_some() {
            return None;
        }
        any = true;
    }
    any.then(|| vals.into_iter().map(|v| v.unwrap_or(Val::Na)).collect())
}

fn to_array<const N: usize>(v: Vec<Val>) -> Option<[Val; N]> {
    v.try_into().ok()
}

/// Starts one probe unit, returns its stdout, and stops it and checks it is gone, on every path.
/// `None` when the unit did not start, did not finish in time, failed, or could not be shown to be
/// gone afterwards.
fn run_probe(
    sys: &Sys,
    prefix: &str,
    props: &[String],
    script: &str,
    args: &[String],
) -> Option<String> {
    let name = format!("{prefix}-probe-{}", crate::state::random_hex(4));
    let argv = probe_argv(&name, props, script, args)?;
    let refs: Vec<&str> = argv.iter().map(String::as_str).collect();
    let ran = sys.run("systemd-run", &refs, Duration::from_secs(15));
    // Whatever happened, the unit must not outlive the probe.
    let gone = sys.stop(&format!("{name}.service"));
    match ran {
        Some((true, text)) if gone => Some(text),
        _ => None,
    }
}

/// Runs the base-tier probe. The unit carries the production base list with the given limits.
pub fn probe_base(
    sys: &Sys,
    prefix: &str,
    props: &[String],
    memory_max: u64,
    tasks_max: u32,
) -> Option<BaseVals> {
    let modules = ["/usr/lib/modules", "/lib/modules"]
        .into_iter()
        .map(PathBuf::from)
        .find(|p| std::fs::read_dir(p).is_ok());
    let args = [
        "/proc/self/mountinfo".to_string(),
        memory_max.to_string(),
        tasks_max.to_string(),
        modules
            .as_deref()
            .and_then(Path::to_str)
            .filter(|p| unit::path_ok(Path::new(p)))
            .unwrap_or("-")
            .to_string(),
    ];
    let out = run_probe(sys, prefix, props, BASE_SCRIPT, &args)?;
    to_array(parse(&out, &BASE_TOKENS)?)
}

/// Runs the mount-tier probe with `props` (the production base and mount lists) and the paths the
/// child needs to write.
pub fn probe_mount(sys: &Sys, prefix: &str, props: &[String], rw: &[PathBuf]) -> Option<MountVals> {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|h| h.is_absolute() && unit::path_ok(h) && !h.to_string_lossy().contains('$'))
        .filter(|h| rustix::fs::access(h, rustix::fs::Access::WRITE_OK).is_ok());
    let etc_ro = host_mount_is_ro(
        &std::fs::read_to_string("/proc/self/mountinfo").ok()?,
        "/etc",
    );
    let mut args = vec![
        "/proc/self/mountinfo".to_string(),
        home.and_then(|h| h.to_str().map(str::to_string))
            .unwrap_or_else(|| "-".into()),
        if etc_ro { "1" } else { "0" }.to_string(),
    ];
    args.extend(rw.iter().map(|p| p.display().to_string()));
    let out = run_probe(sys, prefix, props, MOUNT_SCRIPT, &args)?;
    to_array(parse(&out, &MOUNT_TOKENS)?)
}

/// Whether the mount tier is applied, given what its probe unit printed. Two conditions, both
/// from the requirements: the child must be able to write its root and its `TMPDIR`
/// (`rw_paths`), and `ProtectHome=read-only` must not be shown to have no effect (V11: "drop the
/// namespace tier on that host"). A user manager that is not allowed a mount namespace starts the
/// unit and silently ignores the three properties; that reads `protect_home=0` here. `na` (the
/// host's home is not writable to begin with) cannot show it either way, so the tier stays and is
/// reported `partial`. At least one mount-namespace effect (`private_tmp` or `protect_system`) must
/// have been observed too: with none, the properties did nothing and the tier is dropped.
pub fn mount_applies(v: &MountVals) -> bool {
    v[3] == Val::One && v[1] != Val::Zero && (v[0] == Val::One || v[2] == Val::One)
}

/// Whether `/proc/self/mountinfo` text shows `mount_point` as a read-only mount (the last entry for
/// that mount point wins, as the topmost mount does).
pub fn host_mount_is_ro(mountinfo: &str, mount_point: &str) -> bool {
    mountinfo
        .lines()
        .filter_map(|l| {
            let mut f = l.split_whitespace();
            let (mp, opts) = (f.nth(4)?, f.next()?);
            (mp == mount_point).then(|| opts.split(',').any(|o| o == "ro"))
        })
        .next_back()
        .unwrap_or(false)
}

#[cfg(test)]
#[path = "hardening_tests.rs"]
mod tests;
