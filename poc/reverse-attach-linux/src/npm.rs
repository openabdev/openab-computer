//! `npm ci` (and, for `--from-dir`, `npm cache add`) with the staged Node (R2.5, D17; L1b). Mirrors
//! the Swift `NpmRunner`: Node runs `npm-cli.js` directly, the environment is an allow-list, `HOME`
//! and `TMPDIR` are inside staging so no user `.npmrc` is read, scripts are ignored, and only a
//! fixed outcome class leaves. Nothing from the child's output is kept or printed.

use std::os::fd::OwnedFd;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::proc::{Child, Spec};
use crate::state::{self, Fail, R};

pub const REGISTRY: &str = "https://registry.npmjs.org/";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Ok,
    Offline,
    Integrity,
    Failed,
    TimedOut,
    Cancelled,
}

impl Outcome {
    pub fn class(self) -> &'static str {
        match self {
            Outcome::Ok => "ok",
            Outcome::Offline => "npm_offline",
            Outcome::Integrity => "npm_integrity",
            Outcome::Failed => "npm_failed",
            Outcome::TimedOut => "npm_timed_out",
            Outcome::Cancelled => "cancelled",
        }
    }
}

/// Creates the private `HOME`, `TMPDIR` and cache directories and the two empty config files the
/// command refers to, all below the staging directory.
pub fn prepare(staging: &OwnedFd) -> R<()> {
    for d in ["home", "tmp", "npm-cache"] {
        state::create_dir_at(staging, d)?;
    }
    for f in ["user.npmrc", "global.npmrc"] {
        state::write_new_file(staging, f, b"", 0o600)?;
    }
    Ok(())
}

/// The command for `npm <verb...>`. `offline` adds `--offline` (D17). `staging` is absolute.
pub fn command(staging: &Path, verb: &[&str], offline: bool) -> Spec {
    let p = |rel: &str| staging.join(rel).to_string_lossy().into_owned();
    let mut args = vec![p("node/lib/node_modules/npm/bin/npm-cli.js")];
    args.extend(verb.iter().map(|s| s.to_string()));
    args.extend(
        [
            "--ignore-scripts",
            "--omit=dev",
            "--no-audit",
            "--no-fund",
            "--userconfig",
        ]
        .map(String::from),
    );
    args.push(p("user.npmrc"));
    args.push("--globalconfig".into());
    args.push(p("global.npmrc"));
    args.push("--registry".into());
    args.push(REGISTRY.into());
    args.push("--cache".into());
    args.push(p("npm-cache"));
    if offline {
        args.push("--offline".into());
    }
    Spec {
        exe: PathBuf::from(p("node/bin/node")),
        args,
        env: vec![
            ("HOME".into(), p("home")),
            ("TMPDIR".into(), p("tmp")),
            ("LANG".into(), "C.UTF-8".into()),
            ("PATH".into(), format!("{}:/usr/bin:/bin", p("node/bin"))),
        ],
        cwd: staging.join("pkg"),
    }
}

/// Runs the command to completion, a deadline and the cancel flag permitting.
pub fn run(staging: &Path, verb: &[&str], offline: bool, timeout: Duration) -> Outcome {
    let spec = command(staging, verb, offline);
    let Ok(mut child) = Child::spawn(&spec, false, false, 0, staging) else {
        return Outcome::Failed;
    };
    let deadline = Instant::now() + timeout;
    let outcome = loop {
        if crate::cancel::is_cancelled() {
            break Some(Outcome::Cancelled);
        }
        if Instant::now() >= deadline {
            break Some(Outcome::TimedOut);
        }
        if child.has_exited() {
            break None;
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    if let Some(o) = outcome {
        child.stop();
        return o;
    }
    let ok = child.exit_ok().unwrap_or(false);
    // Let the stderr reader finish the last bytes before they are read.
    std::thread::sleep(Duration::from_millis(100));
    let integrity = child.stderr_contains_any(&["eintegrity"]);
    let offline_err = child.stderr_contains_any(&[
        "enotfound",
        "etimedout",
        "econnrefused",
        "eai_again",
        "econnreset",
        "enetunreach",
        "enotcached",
    ]);
    // Stopping also sweeps anything the exited child left behind.
    child.stop();
    if ok {
        Outcome::Ok
    } else if integrity {
        Outcome::Integrity
    } else if offline_err {
        Outcome::Offline
    } else {
        Outcome::Failed
    }
}

/// A helper for callers that want a `Fail` instead of an outcome.
pub fn require_ok(o: Outcome) -> R<()> {
    match o {
        Outcome::Ok => Ok(()),
        other => Err(Fail(other.class())),
    }
}

#[cfg(test)]
#[path = "npm_tests.rs"]
mod tests;
