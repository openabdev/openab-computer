use super::*;
use crate::run_record::tests::root_with_run;
use crate::state::tests::TempDir;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// A copy of `sleep` placed at `dir/name/sleep`, so a process started from it has its executable
/// under `dir`. The file keeps the name `sleep` because a multi-call coreutils dispatches on the
/// basename of the program it was started as.
pub(crate) fn sleeper_at(dir: &std::path::Path, name: &str) -> std::path::PathBuf {
    std::fs::create_dir_all(dir.join(name)).unwrap();
    let p = dir.join(name).join("sleep");
    std::fs::copy("/bin/sleep", &p).unwrap();
    std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    p
}

/// Starts `exe 60` detached in its own session, as a helper process that outlived its parent.
pub(crate) fn detached(exe: &std::path::Path) -> std::process::Child {
    let mut c = Command::new(exe);
    c.arg("60").stdout(Stdio::null()).stderr(Stdio::null());
    // SAFETY: setsid is async-signal-safe.
    unsafe {
        c.pre_exec(|| {
            rustix::process::setsid().map_err(std::io::Error::from)?;
            Ok(())
        });
    }
    c.spawn().unwrap()
}

pub(crate) fn dies(c: &mut std::process::Child) -> bool {
    let end = Instant::now() + Duration::from_secs(5);
    while Instant::now() < end {
        if matches!(c.try_wait(), Ok(Some(_))) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

fn alive(c: &mut std::process::Child) -> bool {
    std::thread::sleep(Duration::from_millis(300));
    matches!(c.try_wait(), Ok(None))
}

fn no_units(_: &str) {}

#[test]
fn the_install_dir_rule_names_versions_and_staging_only() {
    let root = std::path::Path::new("/r/oab-computer/playwright");
    let yes = [
        "/r/oab-computer/playwright/pw-1/node/bin/node",
        "/r/oab-computer/playwright/.staging-0123456789abcdef0123456789abcdef/node/bin/node",
    ];
    for p in yes {
        assert!(in_install_dirs(std::path::Path::new(p), root), "{p}");
    }
    let no = [
        "/r/oab-computer/playwright/pw-1",
        "/r/oab-computer/playwright/profile/x/node",
        "/r/oab-computer/playwright/run/x",
        "/r/oab-computer/playwright/.hidden/x",
        "/r/oab-computer/playwright2/pw-1/node",
        "/r/oab-computer/other/pw-1/node",
        "/usr/bin/node",
    ];
    for p in no {
        assert!(!in_install_dirs(std::path::Path::new(p), root), "{p}");
    }
}

#[test]
fn a_detached_helper_under_the_version_dir_is_killed_and_a_look_alike_outside_survives() {
    let t = TempDir::new();
    let root = root_with_run(&t);
    let v = root.abs_path().join("pw-1/node/bin");
    let mut inside = detached(&sleeper_at(&v, "chromium"));
    let outside_dir = t.path.join("elsewhere");
    let mut outside = detached(&sleeper_at(&outside_dir, "chromium"));
    let out = sweep_before_start(&root, &no_units).unwrap();
    assert_eq!(
        out,
        Outcome::Swept {
            killed: 1,
            units_stopped: 0
        }
    );
    assert!(dies(&mut inside));
    assert!(
        alive(&mut outside),
        "a look-alike outside the root was touched"
    );
    outside.kill().unwrap();
    outside.wait().unwrap();
}

#[test]
fn a_staging_directory_is_swept_too() {
    let t = TempDir::new();
    let root = root_with_run(&t);
    let stg = root
        .abs_path()
        .join(format!(".staging-{}", "ab".repeat(16)))
        .join("node/bin");
    let mut c = detached(&sleeper_at(&stg, "node"));
    sweep_before_start(&root, &no_units).unwrap();
    assert!(dies(&mut c));
}

#[test]
fn a_process_claimed_by_a_live_record_survives_and_one_without_a_record_does_not() {
    let t = TempDir::new();
    let root = root_with_run(&t);
    let v = root.abs_path().join("pw-1/node/bin");
    let mut claimed_one = detached(&sleeper_at(&v, "signin"));
    let mut other = detached(&sleeper_at(&v, "stray"));
    // The record names the session leader of the first (it called setsid, so its pid is its sid).
    let _h = run_record::write(&root, "cli", claimed_one.id(), None).unwrap();
    sweep_before_start(&root, &no_units).unwrap();
    assert!(dies(&mut other));
    assert!(
        alive(&mut claimed_one),
        "the live record did not protect it"
    );
    claimed_one.kill().unwrap();
    claimed_one.wait().unwrap();
}

#[test]
fn a_dead_record_has_its_unit_stopped_and_is_removed() {
    let t = TempDir::new();
    let root = root_with_run(&t);
    let mut c = Command::new("sleep").arg("30").spawn().unwrap();
    let h = run_record::write(&root, "managed", c.id(), Some("oab-browser-dead.service")).unwrap();
    std::mem::forget(h);
    c.kill().unwrap();
    c.wait().unwrap();
    let seen = std::sync::Mutex::new(Vec::new());
    let out =
        sweep_before_start(&root, &|u: &str| seen.lock().unwrap().push(u.to_string())).unwrap();
    assert_eq!(
        out,
        Outcome::Swept {
            killed: 0,
            units_stopped: 1
        }
    );
    assert_eq!(*seen.lock().unwrap(), ["oab-browser-dead.service"]);
    assert!(run_record::live(&root).is_empty());
}

#[test]
fn the_sweep_is_skipped_not_blocked_while_another_holds_the_lock() {
    let t = TempDir::new();
    let root = root_with_run(&t);
    let held = state::open_named_lock(&root, SWEEP_LOCK_NAME).unwrap();
    rustix::fs::flock(&held, FlockOperation::NonBlockingLockExclusive).unwrap();
    let started = Instant::now();
    assert_eq!(
        sweep_before_start(&root, &no_units).unwrap(),
        Outcome::Skipped
    );
    assert!(started.elapsed() < Duration::from_secs(1));
    drop(held);
    assert!(matches!(
        sweep_before_start(&root, &no_units).unwrap(),
        Outcome::Swept { .. }
    ));
    assert!(
        root.abs_path().join(SWEEP_LOCK_NAME).exists(),
        "the lock file stays"
    );
}
