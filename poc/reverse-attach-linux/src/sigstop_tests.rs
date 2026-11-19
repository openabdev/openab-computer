use super::*;
use crate::containment::{Direct, Mechanism, SYSTEMD};
use crate::state::tests::TempDir;
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::time::Instant;

// ---- a CLI that starts a child with a detached grandchild, and is then signalled --------------
//
// The helper is this very test binary, started with `--ignored --exact helper_cli`. It plays the
// CLI of `browser install` (cancel handlers, a launcher, a child that has a detached grandchild)
// so that the outer test can send it real signals and look at what is left.

const HELPER: &str = "sigstop::tests::helper_cli";

fn test_systemd() -> crate::containment::Systemd {
    let mut sd = crate::containment::Systemd::new(None, false);
    sd.selftest_prefix = format!("{}-selftest", crate::test_exec::TEST_UNIT_PREFIX);
    sd.browser_prefix = format!("{}-browser", crate::test_exec::TEST_UNIT_PREFIX);
    sd
}

fn sleeper(dir: &std::path::Path, name: &str) -> std::path::PathBuf {
    crate::sweep::tests::sleeper_at(dir, name)
}

/// Runs only as the helper process: `OAB_L2_HELPER_BASE` names the data base, `OAB_L2_HELPER_MODE`
/// is `plain` or `supervised`.
#[test]
#[ignore = "helper process of the signal tests"]
fn helper_cli() {
    let Some(base) = std::env::var_os("OAB_L2_HELPER_BASE") else {
        return;
    };
    let mode = std::env::var("OAB_L2_HELPER_MODE").unwrap_or_default();
    crate::cancel::install_handlers();
    let root = Root::open(std::path::Path::new(&base), false)
        .unwrap()
        .unwrap();
    let bin = root.abs_path().join("pw-1/node/bin");
    let tag = std::env::var("OAB_L2_HELPER_TAG").unwrap_or_default();
    let (c_name, g_name) = (format!("cli_child_{tag}"), format!("cli_grand_{tag}"));
    let (c_exe, g_exe) = (
        bin.join(&c_name).join("sleep"),
        bin.join(&g_name).join("sleep"),
    );
    // The grandchild starts its own session, as a Chromium helper does.
    let spec = Spec {
        exe: "/bin/sh".into(),
        args: vec![
            "-c".into(),
            format!(
                "(setsid {} 300 </dev/null >/dev/null 2>&1 &) ; exec {} 300",
                g_exe.display(),
                c_exe.display()
            ),
        ],
        env: vec![("PATH".into(), "/usr/bin:/bin".into())],
        cwd: bin.clone(),
    };
    let launcher: Box<dyn Launcher> = match mode.as_str() {
        "supervised" => Box::new(Supervised::new(Arc::new(Direct::new(Ok(SYSTEMD))))),
        // A real transient unit (`oab-l4-test-*`), on a host with a user manager.
        "systemd" => Box::new(Supervised::new(Arc::new(test_systemd()))),
        _ => Box::new(Plain),
    };
    let mut l = launcher
        .launch(&root, &spec, &root.abs_path().join("pw-1"))
        .unwrap();
    // Wait until the grandchild exists, then tell the outer test.
    let end = Instant::now() + Duration::from_secs(10);
    let find = |name: &str| {
        crate::proc::proc_pids().into_iter().find(|p| {
            std::fs::read_link(format!("/proc/{p}/exe"))
                .is_ok_and(|e| e.parent().is_some_and(|d| d.ends_with(name)))
        })
    };
    while Instant::now() < end && (find(&g_name).is_none() || find(&c_name).is_none()) {
        std::thread::sleep(Duration::from_millis(50));
    }
    println!(
        "READY {} {}",
        find(&c_name).unwrap_or(0),
        find(&g_name).unwrap_or(0)
    );
    use std::io::Write;
    let _ = std::io::stdout().flush();
    // The loop of a health check: until cancelled.
    while !crate::cancel::is_cancelled() {
        std::thread::sleep(Duration::from_millis(50));
    }
    l.child.stop();
    drop(l);
    println!("STOPPED");
    let _ = std::io::stdout().flush();
}

struct Helper {
    proc: std::process::Child,
    child: u32,
    grand: u32,
    start_child: u64,
    start_grand: u64,
}

fn start_helper(t: &TempDir, mode: &str) -> Helper {
    let root = crate::run_record::tests::root_with_run(t);
    let bin = root.abs_path().join("pw-1/node/bin");
    let tag = crate::state::random_hex(4);
    sleeper(&bin, &format!("cli_child_{tag}"));
    sleeper(&bin, &format!("cli_grand_{tag}"));
    let mut proc = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            HELPER,
            "--ignored",
            "--nocapture",
            "--test-threads=1",
        ])
        .env("OAB_L2_HELPER_BASE", t.base())
        .env("OAB_L2_HELPER_MODE", mode)
        .env("OAB_L2_HELPER_TAG", &tag)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut out = BufReader::new(proc.stdout.take().unwrap());
    let mut line = String::new();
    loop {
        line.clear();
        assert!(
            out.read_line(&mut line).unwrap() > 0,
            "the helper ended early"
        );
        if line.contains("READY ") {
            break;
        }
    }
    // Keep reading so the helper never blocks on a full pipe.
    std::thread::spawn(move || {
        let mut s = String::new();
        while out.read_line(&mut s).unwrap_or(0) > 0 {
            s.clear();
        }
    });
    // libtest prints "test <name> ... " before the helper's own output on the same line.
    let n: Vec<u32> = line[line.find("READY ").unwrap()..]
        .split_whitespace()
        .skip(1)
        .map(|x| x.parse().unwrap())
        .collect();
    let (child, grand) = (n[0], n[1]);
    assert!(child > 0 && grand > 0, "{line}");
    Helper {
        proc,
        child,
        grand,
        start_child: crate::state::proc_start_time(child).unwrap(),
        start_grand: crate::state::proc_start_time(grand).unwrap(),
    }
}

impl Helper {
    fn signal(&self, sig: &str) {
        let st = Command::new("kill")
            .args([&format!("-{sig}"), &self.proc.id().to_string()])
            .status()
            .unwrap();
        assert!(st.success());
    }
    fn child_alive(&self) -> bool {
        crate::state::proc_start_time(self.child) == Some(self.start_child)
    }
    fn grand_alive(&self) -> bool {
        crate::state::proc_start_time(self.grand) == Some(self.start_grand)
    }
    fn wait_exit(&mut self) {
        let end = Instant::now() + Duration::from_secs(20);
        while Instant::now() < end {
            if self.proc.try_wait().unwrap().is_some() {
                return;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        panic!("the helper did not exit");
    }
    fn until(&self, f: impl Fn(&Helper) -> bool) -> bool {
        let end = Instant::now() + Duration::from_secs(10);
        while Instant::now() < end {
            if f(self) {
                return true;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        false
    }
}

impl Drop for Helper {
    fn drop(&mut self) {
        let _ = self.proc.kill();
        let _ = self.proc.wait();
        for (p, s) in [
            (self.child, self.start_child),
            (self.grand, self.start_grand),
        ] {
            if crate::state::proc_start_time(p) == Some(s) {
                crate::proc::kill_pid_checked(p, &|_| true);
            }
        }
    }
}

#[cfg(target_os = "linux")]
#[test]
fn sighup_and_sigterm_stop_the_cli_child_and_its_detached_grandchild() {
    for mode in ["plain", "supervised"] {
        for sig in ["HUP", "TERM", "INT"] {
            let t = TempDir::new();
            let mut h = start_helper(&t, mode);
            assert!(h.child_alive() && h.grand_alive());
            let root = Root::open(&t.base(), false).unwrap().unwrap();
            assert_eq!(run_record::live(&root).len(), 1, "{mode}: the run record");
            h.signal(sig);
            h.wait_exit();
            assert!(h.until(|h| !h.child_alive()), "{mode} {sig}: child");
            assert!(
                h.until(|h| !h.grand_alive()),
                "{mode} {sig}: detached grandchild"
            );
            let root = Root::open(&t.base(), false).unwrap().unwrap();
            assert!(run_record::live(&root).is_empty());
            assert!(
                std::fs::read_dir(root.abs_path().join("run"))
                    .unwrap()
                    .flatten()
                    .all(|e| e.file_name().to_string_lossy().starts_with(".")),
                "{mode} {sig}: the run record was not removed"
            );
        }
    }
}

#[cfg(target_os = "linux")]
#[test]
fn sigkill_of_the_cli_leaves_the_grandchild_and_the_next_start_sweeps_it() {
    let t = TempDir::new();
    let mut h = start_helper(&t, "supervised");
    let root = Root::open(&t.base(), false).unwrap().unwrap();
    // A look-alike outside the root, and a live sign-in protected by its own record.
    let outside = t.path.join("elsewhere");
    let mut lookalike = crate::sweep::tests::detached(&sleeper(&outside, "cli_grand_lookalike"));
    let bin = root.abs_path().join("pw-1/node/bin");
    let mut signin = crate::sweep::tests::detached(&sleeper(&bin, "signin"));
    let _protect = run_record::write(&root, "cli", signin.id(), None).unwrap();

    h.signal("KILL");
    h.wait_exit();
    // PDEATHSIG ends the group leader; the detached grandchild is not in its tree.
    assert!(
        h.until(|h| !h.child_alive()),
        "PDEATHSIG did not end the leader"
    );
    assert!(
        h.grand_alive(),
        "the grandchild was expected to outlive a SIGKILL of the CLI"
    );
    // The next start's sweep.
    let out = crate::sweep::sweep_before_start(&root, &|_| {}).unwrap();
    assert!(
        matches!(out, crate::sweep::Outcome::Swept { killed: 1.., .. }),
        "{out:?}"
    );
    assert!(h.until(|h| !h.grand_alive()), "the sweep left the survivor");
    std::thread::sleep(Duration::from_millis(300));
    assert!(
        matches!(lookalike.try_wait(), Ok(None)),
        "a look-alike outside the root died"
    );
    assert!(matches!(signin.try_wait(), Ok(None)), "a live sign-in died");
    // The dead run record of the CLI went with the sweep.
    assert!(run_record::live(&root).iter().all(|r| r.pid == signin.id()));
    for c in [&mut lookalike, &mut signin] {
        c.kill().unwrap();
        c.wait().unwrap();
    }
}

// ---- the same, with a real transient unit (`OAB_L2_SYSTEMD=1 cargo test sigstop -- --ignored`) ----

/// Whether this host starts the full base-list probe unit. Where it does not (a runner whose user
/// manager refuses a property such as `ProtectKernelModules`), `verify` fails closed and a CLI child
/// runs plain, which the containment tests assert; a unit-mode test has nothing to observe there.
#[cfg(target_os = "linux")]
fn host_starts_the_base_probe() -> bool {
    let ok = test_systemd().verify().is_ok();
    if !ok {
        eprintln!("skipped: this host's user manager cannot start the full base probe; the child runs plain");
    }
    ok
}

/// The fallback the two unit-mode tests would otherwise skip over: where the base probe cannot
/// start, `verify` fails closed and a CLI child runs plain (#132). Asserted instead of returned
/// from: the child has a run record with no unit, no unit was made, and SIGTERM still ends the
/// child and its detached grandchild through the process-tree layers.
#[cfg(target_os = "linux")]
fn assert_unit_mode_falls_back_to_plain() {
    let t = TempDir::new();
    let mut h = start_helper(&t, "systemd");
    let root = Root::open(&t.base(), false).unwrap().unwrap();
    let live = run_record::live(&root);
    assert_eq!(live.len(), 1, "the run record");
    assert_eq!(
        live[0].unit, None,
        "a unit was made on a host that cannot verify"
    );
    assert_eq!(units_left(), 0, "a unit is left");
    assert!(h.child_alive() && h.grand_alive());
    h.signal("TERM");
    h.wait_exit();
    assert!(h.until(|h| !h.child_alive()), "plain: child");
    assert!(h.until(|h| !h.grand_alive()), "plain: detached grandchild");
    assert!(run_record::live(&root).is_empty());
}

#[cfg(target_os = "linux")]
fn units_left() -> usize {
    test_systemd()
        .sys
        .list_prefixed(crate::test_exec::TEST_UNIT_PREFIX)
        .map_or(usize::MAX, |v| v.len())
}

#[cfg(target_os = "linux")]
#[test]
#[ignore = "needs a systemd user manager; OAB_L2_SYSTEMD=1"]
fn a_cli_child_in_a_real_unit_is_stopped_by_hup_term_and_int() {
    if std::env::var_os("OAB_L2_SYSTEMD").is_none() {
        return;
    }
    if !host_starts_the_base_probe() {
        assert_unit_mode_falls_back_to_plain();
        return;
    }
    for sig in ["HUP", "TERM", "INT"] {
        let t = TempDir::new();
        let mut h = start_helper(&t, "systemd");
        let root = Root::open(&t.base(), false).unwrap().unwrap();
        let live = run_record::live(&root);
        assert_eq!(live.len(), 1, "the run record");
        let unit = live[0].unit.clone().expect("the record names the unit");
        assert!(
            unit.starts_with(&format!(
                "{}-browser-cli-",
                crate::test_exec::TEST_UNIT_PREFIX
            )),
            "{unit}"
        );
        assert!(h.child_alive() && h.grand_alive());
        h.signal(sig);
        h.wait_exit();
        assert!(h.until(|h| !h.child_alive()), "{sig}: child");
        assert!(h.until(|h| !h.grand_alive()), "{sig}: detached grandchild");
        assert_eq!(units_left(), 0, "{sig}: a unit is left");
        assert!(run_record::live(&root).is_empty());
    }
}

#[cfg(target_os = "linux")]
#[test]
#[ignore = "needs a systemd user manager; OAB_L2_SYSTEMD=1"]
fn sigkill_of_a_cli_leaves_its_unit_and_the_next_starts_sweep_stops_it() {
    if std::env::var_os("OAB_L2_SYSTEMD").is_none() {
        return;
    }
    if !host_starts_the_base_probe() {
        assert_unit_mode_falls_back_to_plain();
        return;
    }
    let t = TempDir::new();
    let mut h = start_helper(&t, "systemd");
    let root = Root::open(&t.base(), false).unwrap().unwrap();
    h.signal("KILL");
    h.wait_exit();
    // The unit is bound to nothing: it outlives the CLI, as the ADR says, until its bound or the
    // next start's sweep.
    std::thread::sleep(Duration::from_millis(500));
    assert!(
        h.grand_alive() || h.child_alive(),
        "the unit was expected to outlive a SIGKILL"
    );
    assert_eq!(units_left(), 1);
    let sd = test_systemd();
    let out = crate::sweep::sweep_before_start(&root, &|u| sd.stop_unit(u)).unwrap();
    assert!(
        matches!(
            out,
            crate::sweep::Outcome::Swept {
                units_stopped: 1..,
                ..
            }
        ),
        "{out:?}"
    );
    assert!(
        h.until(|h| !h.child_alive() && !h.grand_alive()),
        "survivors after the sweep"
    );
    assert_eq!(units_left(), 0);
}

#[cfg(target_os = "linux")]
#[test]
fn a_cli_launch_that_cannot_get_the_sweep_lock_is_refused_and_spawns_nothing() {
    // A busy sweep lock is a refusal of the launch (as in `Supervisor::start`), not a start that
    // goes on unswept. The launch would run `touch`, so a marker file shows whether it started.
    let t = TempDir::new();
    let root = t.root();
    let held = crate::state::open_named_lock(&root, crate::state::SWEEP_LOCK_NAME).unwrap();
    rustix::fs::flock(&held, rustix::fs::FlockOperation::NonBlockingLockExclusive).unwrap();
    let marker = t.path.join("spawned");
    let spec = crate::proc::Spec {
        exe: std::path::PathBuf::from("/bin/sh"),
        args: vec![
            "-c".into(),
            format!("touch '{}'; sleep 30", marker.display()),
        ],
        env: vec![],
        cwd: t.path.clone(),
    };
    let sup = Supervised::new(Arc::new(Direct::new(Ok(SYSTEMD))))
        .with_sweep_wait(Duration::from_millis(100));
    let err = sup
        .launch(&root, &spec, &t.path)
        .err()
        .expect("the launch is refused");
    assert_eq!(err.to_string(), "sweep_busy");
    std::thread::sleep(Duration::from_millis(300));
    assert!(!marker.exists(), "a child was started without a sweep");
    drop(held);
}
