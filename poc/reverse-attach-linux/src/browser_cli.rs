//! `oab-computer browser <plan|preflight|install|update|remove|status>` (ADR linux-browser-tier
//! decision 1; L1b). Parses the arguments, builds the options from the real environment and the
//! embedded manifest, runs one command and prints its result.
//!
//! Exit codes (the ADR does not define them, so these are the minimal choice): `0` success,
//! including a no-op install, a no-op update and a `remove` that found nothing; `1` the operation
//! failed or the preflight found a blocker, with one fixed line on stderr,
//! `browser: <command>_failed class=<token>`; `2` a usage error.
//!
//! Not in this build, and refused with exit 2: `signin` (L3), `--apply-system-changes` (L3) and
//! `--use-system-chromium` (needs the recorded refusals of L2).

use std::io::{BufRead, IsTerminal, Read};
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::consent;
use crate::containment::{Mechanism, Systemd};
use crate::download::{DownloadPolicy, Limits};
use crate::health::Timeouts;
use crate::install::{self, Done, Files, Io, Opts, Source};
use crate::manifest::{Manifest, PlatformId, LOCKFILE_JSON, PACKAGE_JSON};
use crate::preflight::{self, Facts, Sources};
use crate::sigstop;
use crate::state::{Fail, Root};

#[derive(Debug, PartialEq, Eq)]
pub enum Cmd {
    Plan,
    Preflight,
    Install {
        from_dir: Option<PathBuf>,
    },
    Update {
        yes: bool,
        from_dir: Option<PathBuf>,
    },
    Remove,
    Status {
        json: bool,
        /// Clear the five-failure latch and re-run the containment self-test now (R1.5).
        retry: bool,
    },
}

#[derive(Debug, PartialEq, Eq)]
pub struct Usage(pub String);

const USAGE: &str = "usage: oab-computer browser <plan|preflight|install|update|remove|status> [flags]\n  plan                      print what an install downloads and where it goes\n  preflight                 check this host; installs nothing and never uses root\n  install [--from-dir DIR]  install the pinned browser\n  update [--yes] [--from-dir DIR]\n  remove                    delete what this installer created\n  status [--json] [--retry]  --retry clears the unavailable latch and re-runs the containment check";

pub fn parse(args: &[String]) -> Result<Cmd, Usage> {
    let (sub, rest) = args.split_first().ok_or_else(|| Usage(USAGE.into()))?;
    let mut from_dir: Option<PathBuf> = None;
    let mut yes = false;
    let mut json = false;
    let mut retry = false;
    let mut it = rest.iter();
    while let Some(a) = it.next() {
        match (sub.as_str(), a.as_str()) {
            ("install" | "update", "--from-dir") => {
                let d = it
                    .next()
                    .ok_or_else(|| Usage("--from-dir needs a directory".into()))?;
                if from_dir.replace(PathBuf::from(d)).is_some() {
                    return Err(Usage("--from-dir given twice".into()));
                }
            }
            ("update", "--yes") => yes = true,
            ("status", "--json") => json = true,
            ("status", "--retry") => retry = true,
            (_, "--apply-system-changes" | "--use-system-chromium") => {
                return Err(Usage(format!("{a} is not available in this build")))
            }
            _ => return Err(Usage(format!("unknown argument for browser {sub}"))),
        }
    }
    Ok(match sub.as_str() {
        "plan" => Cmd::Plan,
        "preflight" => Cmd::Preflight,
        "install" => Cmd::Install { from_dir },
        "update" => Cmd::Update { yes, from_dir },
        "remove" => Cmd::Remove,
        "status" => Cmd::Status { json, retry },
        "signin" => {
            return Err(Usage(
                "browser signin is not available in this build".into(),
            ))
        }
        _ => return Err(Usage(USAGE.into())),
    })
}

fn hint(class: &str) -> Option<&'static str> {
    Some(match class {
        "use_update" => "a different version is installed; run `oab-computer browser update`",
        "foreign_install" => "install.json was not written by this installer and was left as it is. Remove it yourself if it is stale",
        "foreign_data" => "profile, output, home or run exists and was not created by this installer; it was left as it is and not adopted",
        "install_invalid" => "the install is damaged; run `oab-computer browser remove`, then install again",
        "not_installed" => "nothing is installed; run `oab-computer browser install`",
        "confirmation_required" => "an update needs a yes: run it on a terminal, or pass --yes",
        "lock_held" => "another install, update or remove is running",
        "record_changed" => "a record in the install root changed while this ran; nothing of it was overwritten or deleted. Run the command again",
        "record_changed_left" => "a record changed while this ran and a file written by something else was left under a name like install.json.tmp-<hex>; it was not deleted. Inspect it, then run the command again",
        "record_swap_stuck" => "install.json now names the new version, which is installed and kept; the old version stays in place with its cleanup record. A displaced file could not be put back and is left under a name like install.json.tmp-<hex>; it was not deleted. Look at it, then run `oab-computer browser status`",
        "record_replace_unsupported" => "this file system cannot replace a record atomically (RENAME_EXCHANGE); nothing was changed",
        "browser_running" => "a managed browser is running; stop it first. Nothing was deleted",
        "pins_changed_same_id" => "the embedded pins changed without a new manifest id; this needs a new release, and the installed version was left as it is",
        "root_not_directory" => "the install root or a directory above it is a link, is not yours, or is writable by others; nothing below it was touched",
        _ => return None,
    })
}

fn fail(io: &mut Io<'_>, command: &str, f: Fail) -> i32 {
    let _ = writeln!(io.err, "browser: {command}_failed class={}", f.0);
    if let Some(h) = hint(f.0) {
        let _ = writeln!(io.err, "{h}");
    }
    1
}

/// Runs a parsed command against prepared options. Pure with respect to the environment, so the
/// unit tests drive it with a temp root and a fake server.
pub fn execute(
    cmd: &Cmd,
    o: &Opts<'_>,
    io: &mut Io<'_>,
    ask: &mut dyn FnMut(&str) -> Option<bool>,
) -> i32 {
    match cmd {
        Cmd::Plan => {
            let sel = match o.manifest.select(o.platform) {
                Ok(s) => s,
                Err(_) => return fail(io, "plan", Fail("unsupported_platform")),
            };
            let t = consent::text(
                o.manifest,
                &sel,
                &o.base.join("oab-computer").join("playwright"),
                o.home.as_deref(),
            );
            io.say(&t);
            0
        }
        Cmd::Preflight => {
            let sel = match o.manifest.select(o.platform) {
                Ok(s) => s,
                Err(_) => return fail(io, "preflight", Fail("unsupported_platform")),
            };
            let facts = (o.facts)(&o.base);
            let r = preflight::evaluate(
                o.manifest,
                &sel,
                &facts,
                consent::disk_needed(o.manifest, &sel),
            );
            io.say(preflight::render(&r).trim_end());
            if r.ok() {
                0
            } else {
                1
            }
        }
        Cmd::Install { .. } => match install::install(o, io) {
            Ok(Done::Installed(id)) => {
                io.say(&format!("installed {id}"));
                0
            }
            Ok(Done::AlreadyInstalled(id)) => {
                io.say(&format!("already installed: {id}"));
                0
            }
            Ok(_) => 0,
            Err(f) => fail(io, "install", f),
        },
        Cmd::Update { .. } => match install::update(o, io, ask) {
            Ok(Done::Updated { from, to }) => {
                io.say(&format!(
                    "updated {from} to {to}; the previous version stays until its cleanup record is acted on"
                ));
                0
            }
            Ok(Done::AlreadyUpToDate(id)) => {
                io.say(&format!("already up to date: {id}"));
                0
            }
            Ok(_) => 0,
            Err(f) => fail(io, "update", f),
        },
        Cmd::Remove => match install::remove(o) {
            Ok(None) => {
                io.say("nothing to remove");
                0
            }
            Ok(Some(r)) => {
                for n in &r.report.removed {
                    io.say(&format!("removed: {n}"));
                }
                for (n, why) in &r.report.left {
                    io.say(&format!("left in place: {n} ({why})"));
                }
                io.say(&format!(
                    "left in place: {} (the directory that holds the lock file)",
                    r.root.display()
                ));
                if r.report.removed.is_empty() && !r.report.failed {
                    io.say("nothing to remove");
                }
                if r.report.failed {
                    fail(io, "remove", Fail("remove_failed"))
                } else {
                    0
                }
            }
            Err(f) => fail(io, "remove", f),
        },
        Cmd::Status { json, retry } => match install::status(o, *retry) {
            Ok(s) => {
                if *json {
                    io.say(&s.to_json());
                } else {
                    for l in s.lines() {
                        io.say(&l);
                    }
                }
                0
            }
            Err(f) => fail(io, "status", f),
        },
    }
}

/// The entry point `main` calls for `oab-computer browser ...`.
pub fn run(args: &[String]) -> i32 {
    let mut out = std::io::stdout();
    let mut err = std::io::stderr();
    let mut io = Io {
        out: &mut out,
        err: &mut err,
    };
    let cmd = match parse(args) {
        Ok(c) => c,
        Err(Usage(m)) => {
            let _ = writeln!(io.err, "{m}");
            return 2;
        }
    };
    crate::cancel::install_handlers();
    let base = match Root::default_base() {
        Ok(b) => b,
        Err(f) => return fail(&mut io, "browser", f),
    };
    let manifest: &Manifest = Manifest::embedded();
    let policy = DownloadPolicy::production(manifest);
    let from_dir = match &cmd {
        Cmd::Install { from_dir } | Cmd::Update { from_dir, .. } => from_dir.clone(),
        _ => None,
    };
    let platform = PlatformId::host();
    let sources = Sources::system();
    let facts =
        move |p: &Path| Facts::gather(&sources, platform.unwrap_or(PlatformId::LinuxX64), p);
    // The health check of an install runs in a transient unit with a runtime bound when the
    // mechanism verifies (L2), and on the process-tree layers alone when it does not.
    let launcher = sigstop::Supervised::new(std::sync::Arc::new(Systemd::new(None, false)));
    let extras = |base: &Path, retry: bool| {
        crate::probe::gather(
            base,
            retry,
            std::env::var("MCP_UPSTREAM").ok().as_deref(),
            &crate::procnet::Proc,
            &|| Systemd::new(None, false).verify(),
        )
    };
    let o = Opts {
        manifest,
        files: Files {
            package_json: PACKAGE_JSON,
            lockfile: LOCKFILE_JSON,
        },
        source: match &from_dir {
            Some(d) => Source::Dir(d),
            None => Source::Network(&policy),
        },
        check_manifest: true,
        limits: Limits::default(),
        timeouts: Timeouts::default(),
        npm_timeout: Duration::from_secs(600),
        lock_wait: Duration::from_secs(30),
        base,
        home: std::env::var_os("HOME").map(PathBuf::from),
        platform,
        facts: &facts,
        launcher: &launcher,
        extras: &extras,
    };
    let yes = matches!(cmd, Cmd::Update { yes: true, .. });
    let mut ask = |q: &str| -> Option<bool> {
        if yes {
            return Some(true);
        }
        if !std::io::stdin().is_terminal() {
            return None;
        }
        eprint!("{q}");
        let mut line = String::new();
        // At most 64 bytes: an answer is "y" or "yes"; anything longer is not one.
        std::io::stdin().lock().take(64).read_line(&mut line).ok()?;
        Some(matches!(line.trim().to_lowercase().as_str(), "y" | "yes"))
    };
    execute(&cmd, &o, &mut io, &mut ask)
}

#[cfg(test)]
#[path = "browser_cli_tests.rs"]
mod tests;
