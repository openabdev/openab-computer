use super::*;
use crate::state::tests::TempDir;
use crate::test_exec::{write_exec, TEST_UNIT_PREFIX};
use std::sync::atomic::Ordering;

fn selftest_prefix() -> String {
    format!("{TEST_UNIT_PREFIX}-selftest")
}

fn browser_prefix() -> String {
    format!("{TEST_UNIT_PREFIX}-browser")
}

fn blank_sys() -> Sys {
    Sys {
        path: vec![PathBuf::from("/nonexistent-oab-bin")],
        runtime_dir: Some(PathBuf::from("/nonexistent-oab-run")),
        bus: None,
    }
}

fn systemd_with(sys: Sys) -> Systemd {
    Systemd {
        sys,
        selftest_prefix: selftest_prefix(),
        browser_prefix: browser_prefix(),
        require_unit_main: false,
        data_root: None,
    }
}

#[test]
fn the_answer_is_cached_until_reset() {
    let d = Arc::new(Direct::new(Ok(SYSTEMD)));
    let a = Availability::new(d.clone());
    assert_eq!(a.peek(), None);
    assert_eq!(a.get(), Ok(SYSTEMD));
    assert_eq!(a.get(), Ok(SYSTEMD));
    assert_eq!(d.verified.load(Ordering::SeqCst), 1);
    assert_eq!(a.peek(), Some(Ok(SYSTEMD)));
    a.reset();
    assert_eq!(a.peek(), None);
    assert_eq!(a.get(), Ok(SYSTEMD));
    assert_eq!(d.verified.load(Ordering::SeqCst), 2);
    // A failure is cached too: it is not retried on every call.
    let f = Arc::new(Direct::new(Err(UNVERIFIED)));
    let a = Availability::new(f.clone());
    assert_eq!(a.get(), Err(UNVERIFIED));
    assert_eq!(a.get(), Err(UNVERIFIED));
    assert_eq!(f.verified.load(Ordering::SeqCst), 1);
}

#[test]
fn a_host_with_no_systemd_run_is_unverified_and_starts_nothing() {
    let s = systemd_with(blank_sys());
    assert_eq!(s.verify(), Err(UNVERIFIED));
    let l = Launch {
        exe: PathBuf::from("/bin/true"),
        args: vec![],
        env: vec![],
        cwd: PathBuf::from("/"),
        scope: PathBuf::from("/"),
        line_cap: 1024,
        rw_paths: vec![],
        memory_max: 1 << 30,
        tasks_max: 100,
    };
    assert!(s
        .spawn(
            SYSTEMD,
            SpawnKind::Cli {
                runtime_max: Duration::from_secs(5)
            },
            &l
        )
        .is_err());
}

#[test]
fn an_unset_runtime_dir_is_unverified() {
    let mut sys = Sys::from_env();
    sys.runtime_dir = None;
    assert_eq!(systemd_with(sys).verify(), Err(UNVERIFIED));
}

#[test]
fn the_unavailable_mechanism_never_verifies_or_spawns() {
    let u = Unavailable(UNVERIFIED);
    assert_eq!(u.verify(), Err(UNVERIFIED));
    let a = Availability::new(Arc::new(Unavailable(NOT_UNIT_MAIN)));
    assert_eq!(a.get(), Err(NOT_UNIT_MAIN));
}

/// A test process is never the main process of a `.service` this module can see as its own. On a
/// host with a user manager that is `daemon_not_unit_main`; on one without, the tools are missing
/// first and the answer is `containment_unverified`. Either way nothing verifies.
#[cfg(target_os = "linux")]
#[test]
fn a_process_that_is_not_its_units_main_process_is_refused() {
    let mut s = systemd_with(Sys::from_env());
    s.require_unit_main = true;
    assert!(matches!(s.verify(), Err(UNVERIFIED | NOT_UNIT_MAIN)));
    assert!(own_unit(&s.sys).is_none() || std::env::var_os("INVOCATION_ID").is_some());
}

#[test]
fn the_sys_environment_is_the_minimum_a_user_manager_client_needs() {
    let s = Sys {
        path: vec![PathBuf::from("/usr/bin"), PathBuf::from("/bin")],
        runtime_dir: Some(PathBuf::from("/run/user/1000")),
        bus: Some("unix:path=/run/user/1000/bus".into()),
    };
    let names: Vec<String> = s.env().into_iter().map(|(k, _)| k).collect();
    assert_eq!(
        names,
        ["PATH", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"]
    );
    let none = Sys {
        path: vec![],
        runtime_dir: None,
        bus: None,
    };
    assert_eq!(none.env().len(), 1);
}

// ---- the real mechanism: transient units on a host with a user manager -----------------------
//
// Run with `OAB_L2_SYSTEMD=1 cargo test --release -- --ignored --test-threads=1 containment hardening`.
// Every unit is named `oab-l4-test-*`, and every test ends with none left.

#[cfg(target_os = "linux")]
fn leftovers(sys: &Sys) -> Vec<String> {
    let mut v = sys.list_prefixed(TEST_UNIT_PREFIX).unwrap_or_default();
    v.sort();
    v
}

#[cfg(target_os = "linux")]
fn enabled() -> bool {
    std::env::var_os("OAB_L2_SYSTEMD").is_some()
}

/// The processes of any unit named with the test prefix, by cgroup.
#[cfg(target_os = "linux")]
fn strays() -> Vec<u32> {
    proc::proc_pids()
        .into_iter()
        .filter(|p| {
            proc::same_uid(*p)
                && std::fs::read_to_string(format!("/proc/{p}/cgroup"))
                    .is_ok_and(|c| c.contains(TEST_UNIT_PREFIX))
        })
        .collect()
}

#[cfg(target_os = "linux")]
#[test]
#[ignore = "needs a systemd user manager; OAB_L2_SYSTEMD=1"]
fn the_self_test_passes_with_the_daemon_shape_and_leaves_nothing() {
    if !enabled() {
        return;
    }
    let s = systemd_with(Sys::from_env());
    let started = Instant::now();
    // The fixture itself. (`verify` adds the hardening probes, whose base tier needs every
    // property of the ADR list to start, which depends on the host's systemd.)
    let r = s.selftest_for(None, true);
    assert!(r.is_ok(), "{r:?}");
    assert!(started.elapsed() < Duration::from_secs(40));
    assert_eq!(leftovers(&s.sys), Vec::<String>::new());
    // No process of the fixture is left either: the parent's straggler (`KillMode=process`
    // leaves it behind a kill of the main process) was killed by the cleanup.
    assert_eq!(strays(), Vec::<u32>::new());
}

#[cfg(target_os = "linux")]
#[test]
#[ignore = "needs a systemd user manager; OAB_L2_SYSTEMD=1"]
fn an_unbound_child_makes_the_self_test_fail_and_still_cleans_up() {
    if !enabled() {
        return;
    }
    let s = systemd_with(Sys::from_env());
    // The negative control: without `BindsTo` the child survives the parent's death, so the
    // self-test must say so.
    assert_eq!(s.selftest_for(None, false), Err(UNVERIFIED));
    assert_eq!(leftovers(&s.sys), Vec::<String>::new());
    assert_eq!(strays(), Vec::<u32>::new());
    // And the same fixture with the binding passes.
    assert_eq!(s.selftest_for(None, true), Ok(()));
    assert_eq!(leftovers(&s.sys), Vec::<String>::new());
    assert_eq!(strays(), Vec::<u32>::new());
}

#[cfg(target_os = "linux")]
#[test]
#[ignore = "needs a systemd user manager; OAB_L2_SYSTEMD=1"]
fn the_self_test_fails_closed_without_systemd_run_or_a_runtime_dir() {
    if !enabled() {
        return;
    }
    let real = Sys::from_env();
    // `PATH` without systemd-run.
    let mut no_run = real.clone();
    no_run.path = vec![PathBuf::from("/nonexistent-oab-bin")];
    let s = systemd_with(no_run);
    assert_eq!(s.verify(), Err(UNVERIFIED));
    // `XDG_RUNTIME_DIR` unset.
    let mut no_rt = real.clone();
    no_rt.runtime_dir = None;
    assert_eq!(systemd_with(no_rt).verify(), Err(UNVERIFIED));
    // A bus the client cannot reach.
    let mut bad_bus = real.clone();
    bad_bus.runtime_dir = Some(PathBuf::from("/nonexistent-oab-run"));
    assert_eq!(systemd_with(bad_bus).verify(), Err(UNVERIFIED));
    assert_eq!(leftovers(&real), Vec::<String>::new());
}

#[cfg(target_os = "linux")]
#[test]
#[ignore = "needs a systemd user manager; OAB_L2_SYSTEMD=1"]
fn a_unit_left_by_a_crashed_earlier_self_test_is_stopped_by_the_next() {
    if !enabled() {
        return;
    }
    let sys = Sys::from_env();
    let stray = format!("{}-dead-p", selftest_prefix());
    let (ok, _) = sys
        .run(
            "systemd-run",
            &[
                "--user",
                "--quiet",
                "--collect",
                &format!("--unit={stray}"),
                "-p",
                "RuntimeMaxSec=60",
                "--",
                "/usr/bin/env",
                "sleep",
                "55",
            ],
            Duration::from_secs(15),
        )
        .unwrap();
    assert!(ok);
    assert!(leftovers(&sys).iter().any(|u| u.starts_with(&stray)));
    let s = systemd_with(sys.clone());
    assert!(s.selftest_for(None, true).is_ok());
    assert_eq!(leftovers(&sys), Vec::<String>::new());
}

#[cfg(target_os = "linux")]
#[test]
#[ignore = "needs a systemd user manager; OAB_L2_SYSTEMD=1"]
fn a_leftover_probe_unit_with_a_straggler_is_killed_whole_by_the_next_self_test() {
    if !enabled() {
        return;
    }
    let sys = Sys::from_env();
    let stray = format!("{}-probe-dead", selftest_prefix());
    // `KillMode=process`: stopping it alone would leave the second sleeper behind.
    let (ok, _) = sys
        .run(
            "systemd-run",
            &[
                "--user",
                "--quiet",
                "--collect",
                &format!("--unit={stray}"),
                "-p",
                "RuntimeMaxSec=60",
                "-p",
                "KillMode=process",
                "--",
                "/bin/sh",
                "-c",
                "/usr/bin/env sleep 55 </dev/null >/dev/null 2>&1 & exec /usr/bin/env sleep 56",
            ],
            Duration::from_secs(15),
        )
        .unwrap();
    assert!(ok);
    assert!(leftovers(&sys).iter().any(|u| u.starts_with(&stray)));
    assert!(!strays().is_empty());
    let s = systemd_with(sys.clone());
    assert!(s.selftest_for(None, true).is_ok());
    assert_eq!(leftovers(&sys), Vec::<String>::new());
    assert_eq!(strays(), Vec::<u32>::new());
}

#[cfg(target_os = "linux")]
fn show_tiers(label: &str, t: &Tiers) {
    use crate::hardening::{BASE_TOKENS, MOUNT_TOKENS};
    let word = |v: &crate::hardening::Val| match v {
        crate::hardening::Val::One => "1",
        crate::hardening::Val::Zero => "0",
        crate::hardening::Val::Na => "na",
    };
    eprintln!("probe transcript [{label}]");
    if let Some(b) = &t.base {
        for (n, v) in BASE_TOKENS.iter().zip(b) {
            eprintln!("  base  {n}={}", word(v));
        }
    }
    if let MountTier::Applied(m) = &t.mount {
        for (n, v) in MOUNT_TOKENS.iter().zip(m) {
            eprintln!("  mount {n}={}", word(v));
        }
    }
    eprintln!(
        "  hardening_base={} hardening_mount={} unverified={}",
        t.base_state(),
        t.mount_state(),
        t.unverified_text()
    );
}

/// A data root the unit can reach: below `XDG_RUNTIME_DIR`, which `/tmp`-private units cannot hide.
#[cfg(target_os = "linux")]
struct DataRoot(PathBuf);

#[cfg(target_os = "linux")]
impl DataRoot {
    fn new() -> DataRoot {
        let rt = Sys::from_env().runtime_dir.unwrap();
        let p = rt.join(format!(
            "{TEST_UNIT_PREFIX}-data-{}",
            crate::state::random_hex(4)
        ));
        std::fs::create_dir_all(&p).unwrap();
        DataRoot(p)
    }
}

#[cfg(target_os = "linux")]
impl Drop for DataRoot {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The production base list when this host's systemd can start a unit with it. Some hosts cannot
/// (a user manager that refuses `ProtectKernelModules=yes` with exit 218): the diagnostic runs then
/// use the list without that one property and say so. `verify` itself never does this: on such a
/// host the base probe fails and the answer is `containment_unverified`.
#[cfg(target_os = "linux")]
fn workable_base_props(sys: &Sys) -> Vec<String> {
    let full = unit::base_props(1 << 30, 4096);
    if hardening::probe_base(sys, &selftest_prefix(), &full, 1 << 30, 4096).is_some() {
        return full;
    }
    eprintln!(
        "note: this host cannot start the full base list; probing without ProtectKernelModules"
    );
    full.into_iter()
        .filter(|p| p != "ProtectKernelModules=yes")
        .collect()
}

#[cfg(target_os = "linux")]
#[test]
#[ignore = "needs a systemd user manager; OAB_L2_SYSTEMD=1"]
fn the_base_probe_reports_every_token_it_can_observe_and_prints_a_transcript() {
    if !enabled() {
        return;
    }
    let root = DataRoot::new();
    let mut s = systemd_with(Sys::from_env());
    s.data_root = Some(root.0.clone());
    let props = workable_base_props(&s.sys);
    let Some(base) = hardening::probe_base(&s.sys, &selftest_prefix(), &props, 1 << 30, 4096)
    else {
        // Not even the reduced list starts: the gate must then refuse, never report.
        assert_eq!(s.verify(), Err(UNVERIFIED));
        return;
    };
    let mount = s.probe_mount_tier(&props);
    let mode = mode_for(Tiers {
        base: Some(base),
        mount,
    });
    show_tiers("production lists", &mode.tiers);
    if props.len() == unit::base_props(1 << 30, 4096).len() {
        // The full list starts here, so `verify` agrees with what was just measured.
        let real = s.probe_tiers().expect("the base probe unit starts");
        assert_eq!(real.name, mode.name);
    } else {
        assert_eq!(
            s.verify(),
            Err(UNVERIFIED),
            "a base tier that cannot start gates the answer"
        );
    }
    let b = mode.tiers.base.expect("base probed");
    // What the property lists guarantee wherever the probe unit starts at all.
    assert_eq!(b[0], hardening::Val::One, "no_new_privs");
    assert_eq!(b[2], hardening::Val::One, "umask");
    // The reported state is consistent with the results, whatever the host.
    assert_eq!(
        mode.mount_tier,
        matches!(mode.tiers.mount, MountTier::Applied(_))
    );
    assert_eq!(
        mode.name,
        if mode.mount_tier {
            "systemd+mount"
        } else {
            "systemd"
        }
    );
    if let MountTier::Applied(m) = mode.tiers.mount {
        assert!(
            hardening::mount_applies(&m),
            "an applied tier passed its gate"
        );
    }
    assert_eq!(leftovers(&s.sys), Vec::<String>::new());
    assert_eq!(strays(), Vec::<u32>::new());
}

#[cfg(target_os = "linux")]
#[test]
#[ignore = "needs a systemd user manager; OAB_L2_SYSTEMD=1"]
fn a_probe_with_no_properties_reports_the_effects_absent() {
    use crate::hardening::{probe_base, probe_mount, Val};
    if !enabled() {
        return;
    }
    let sys = Sys::from_env();
    let prefix = selftest_prefix();
    // Negative control: the same probe in a unit without the properties must not read `1`.
    let b = probe_base(&sys, &prefix, &[], 1 << 30, 4096).expect("a bare unit starts");
    show_tiers(
        "no properties, base",
        &Tiers {
            base: Some(b),
            mount: MountTier::NotProbed,
        },
    );
    assert_eq!(
        b[0],
        Val::Zero,
        "no_new_privs is absent without NoNewPrivileges"
    );
    assert_eq!(
        b[1],
        Val::Zero,
        "no seccomp filter without the Restrict* options"
    );
    assert_eq!(b[2], Val::Zero, "umask 0077 is not the manager's default");
    let root = DataRoot::new();
    let tmp = crate::child::RuntimeTmp::create_named(&root.0, "oab-pr").unwrap();
    let rw = vec![root.0.clone(), tmp.path.clone()];
    let m = probe_mount(&sys, &prefix, &[], &rw).expect("a bare unit starts");
    show_tiers(
        "no properties, mount",
        &Tiers {
            base: None,
            mount: MountTier::Applied(m),
        },
    );
    assert_ne!(m[0], Val::One, "private_tmp");
    assert_ne!(m[1], Val::One, "protect_home");
    assert_ne!(m[2], Val::One, "protect_system");
    assert_eq!(
        m[3],
        Val::One,
        "the paths are writable without any restriction"
    );
    assert_eq!(leftovers(&sys), Vec::<String>::new());
}

#[cfg(target_os = "linux")]
#[test]
#[ignore = "needs a systemd user manager; OAB_L2_SYSTEMD=1"]
fn the_mount_tier_is_dropped_when_the_data_root_is_missing_and_reported_not_applicable() {
    if !enabled() {
        return;
    }
    let mut s = systemd_with(Sys::from_env());
    let base = workable_base_props(&s.sys);
    // No install root yet: not applicable, nothing probed, no unit started.
    s.data_root = None;
    assert_eq!(s.probe_mount_tier(&base), MountTier::NotApplicable);
    s.data_root = Some(PathBuf::from("/nonexistent-oab-data-root"));
    assert_eq!(s.probe_mount_tier(&base), MountTier::NotApplicable);
    // A root systemd would split into two words cannot be probed: dropped, and reported so.
    let root = DataRoot::new();
    let spaced = root.0.join("a b");
    std::fs::create_dir_all(&spaced).unwrap();
    s.data_root = Some(spaced);
    assert_eq!(s.probe_mount_tier(&base), MountTier::Dropped);
    assert_eq!(leftovers(&s.sys), Vec::<String>::new());
}

#[cfg(target_os = "linux")]
#[test]
#[ignore = "needs a systemd user manager; OAB_L2_SYSTEMD=1"]
fn a_probe_unit_that_fails_to_start_is_not_a_result_and_leaves_nothing() {
    if !enabled() {
        return;
    }
    let sys = Sys::from_env();
    let bad = vec!["NoSuchPropertyAtAll=1".to_string()];
    assert!(crate::hardening::probe_base(&sys, &selftest_prefix(), &bad, 1 << 30, 4096).is_none());
    assert_eq!(leftovers(&sys), Vec::<String>::new());
    // The gate: a base probe that cannot start makes the whole answer unverified.
    let mut broken = sys.clone();
    broken.path = vec![PathBuf::from("/nonexistent-oab-bin")];
    assert_eq!(systemd_with(broken).verify(), Err(UNVERIFIED));
}

// ---- no systemd needed: a failed `systemctl show` is a failed query (#132) --------------------

/// A directory with a fake `systemctl` and a fake `systemd-run`. `show` exits with `show_exit`,
/// printing `no`; every other `systemctl` call succeeds with nothing. Both log their arguments.
fn fake_tools(t: &TempDir, show_exit: i32) -> Sys {
    let bin = t.path.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    write_exec(
        &bin.join("systemctl"),
        format!(
            "#!/bin/sh\necho \"$*\" >> {log}/systemctl.log\ncase \" $* \" in\n  *\" show \"*) echo no; exit {show_exit};;\n  *) exit 0;;\nesac\n",
            log = t.path.display()
        )
        .as_bytes(),
    );
    write_exec(
        &bin.join("systemd-run"),
        format!(
            "#!/bin/sh\necho \"$*\" >> {}/systemd-run.log\nexit 0\n",
            t.path.display()
        )
        .as_bytes(),
    );
    Sys {
        path: vec![bin],
        runtime_dir: Some(t.path.clone()),
        bus: None,
    }
}

#[test]
fn a_systemctl_that_exits_nonzero_makes_show_none_and_the_shape_check_refuses() {
    let t = TempDir::new();
    let sys = fake_tools(&t, 1);
    assert_eq!(sys.show("oab-computer.service", "RemainAfterExit"), None);
    assert_eq!(sys.active_state("oab-computer.service"), None);
    // The daemon-unit shape check: a failed query is "not ok", and no fixture unit is started.
    let s = systemd_with(sys);
    assert_eq!(
        s.selftest_for(Some("oab-computer.service".into()), true),
        Err(UNVERIFIED)
    );
    assert!(
        !t.path.join("systemd-run.log").exists(),
        "a unit was started although the shape could not be checked"
    );
}

#[test]
fn a_systemctl_that_answers_is_still_read_and_the_wrong_shape_still_refuses() {
    let t = TempDir::new();
    let sys = fake_tools(&t, 0);
    assert_eq!(
        sys.show("oab-computer.service", "RemainAfterExit")
            .as_deref(),
        Some("no")
    );
    // `ExitType` reads `no`, which is neither `main` nor empty: refused, nothing started.
    let s = systemd_with(sys);
    assert_eq!(
        s.selftest_for(Some("oab-computer.service".into()), true),
        Err(UNVERIFIED)
    );
    assert!(!t.path.join("systemd-run.log").exists());
}

#[test]
fn kill_all_names_the_unit_and_never_a_pid_or_a_non_unit_name() {
    let t = TempDir::new();
    let sys = fake_tools(&t, 0);
    assert!(sys.kill_all("oab-l4-test-selftest-ab-p.service"));
    let log = std::fs::read_to_string(t.path.join("systemctl.log")).unwrap();
    assert!(
        log.contains("kill --kill-whom=all --signal=SIGKILL oab-l4-test-selftest-ab-p.service"),
        "{log}"
    );
    for bad in ["123", "--help", "../x.service", "a b.service", ""] {
        assert!(!sys.kill_all(bad), "{bad:?}");
    }
    let after = std::fs::read_to_string(t.path.join("systemctl.log")).unwrap();
    assert_eq!(after, log, "a refused name reached systemctl");
}

/// A fake `systemctl` that answers every `show` with `state` and fails every `kill`.
fn failing_kill_tools(t: &TempDir, state: &str) -> Sys {
    let bin = t.path.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    write_exec(
        &bin.join("systemctl"),
        format!(
            "#!/bin/sh\ncase \" $* \" in\n  *\" show \"*) echo {state}; exit 0;;\n  *\" kill \"*) exit 1;;\n  *) exit 0;;\nesac\n"
        )
        .as_bytes(),
    );
    Sys {
        path: vec![bin],
        runtime_dir: Some(t.path.clone()),
        bus: None,
    }
}

#[test]
fn a_cleanup_whose_kill_failed_and_whose_unit_is_still_active_is_a_failed_cleanup() {
    let t = TempDir::new();
    let sys = failing_kill_tools(&t, "active");
    let mut fx = Fixture {
        sys: &sys,
        units: vec!["oab-l4-test-selftest-ab-p.service".into()],
        recorded: Vec::new(),
        daemon_unit: None,
        bind_child: true,
    };
    assert!(!fx.cleanup(), "a unit that is still active passed cleanup");
    assert!(fx.units.is_empty(), "the unit list is spent either way");
    // A failed `kill` for a unit that is already gone is not a failure: the state check decides.
    let t = TempDir::new();
    let sys = failing_kill_tools(&t, "inactive");
    let mut fx = Fixture {
        sys: &sys,
        units: vec!["oab-l4-test-selftest-ab-p.service".into()],
        recorded: Vec::new(),
        daemon_unit: None,
        bind_child: true,
    };
    assert!(fx.cleanup());
}

#[test]
fn cleanup_fails_while_a_recorded_process_lives() {
    let t = TempDir::new();
    let sys = failing_kill_tools(&t, "inactive");
    let me = std::process::id();
    let mut fx = Fixture {
        sys: &sys,
        units: Vec::new(),
        // This process, by pid and start time: it does not exit, so cleanup must say so.
        recorded: vec![(me, crate::state::proc_start_time(me).unwrap())],
        daemon_unit: None,
        bind_child: true,
    };
    assert!(!fx.cleanup());
}

#[cfg(target_os = "linux")]
#[test]
#[ignore = "needs a systemd user manager; OAB_L2_SYSTEMD=1"]
fn cleanup_records_and_kills_the_straggler_of_the_restarted_parent() {
    if !enabled() {
        return;
    }
    let sys = Sys::from_env();
    // L5 test units carry their own prefix, so a leftover is attributable to this test.
    let prefix = "oab-l5-test-rec";
    let base = format!("{prefix}-{}", crate::state::random_hex(4));
    let parent_u = format!("{base}-p.service");
    let mut fx = Fixture {
        sys: &sys,
        units: Vec::new(),
        recorded: Vec::new(),
        daemon_unit: None,
        bind_child: true,
    };
    assert!(fx.run(&base), "the fixture did not pass");
    // The parent restarted after the kill of its main process (`Restart=always`): its new main
    // process and new straggler were never recorded by the run.
    let mut now: Vec<(u32, u64)> = Vec::new();
    assert!(fx.wait(Duration::from_secs(6), || {
        now = fx.inside(&parent_u);
        now.len() >= 2
    }));
    assert!(
        now.iter().any(|p| !fx.recorded.contains(p)),
        "the restart added nothing to record, so this test shows nothing"
    );
    assert!(fx.cleanup());
    for (p, t) in &now {
        assert_ne!(
            crate::state::proc_start_time(*p),
            Some(*t),
            "a process of the restarted parent outlived cleanup"
        );
    }
    assert_eq!(sys.list_prefixed(prefix), Some(Vec::new()));
}

#[test]
fn the_mode_follows_what_the_mount_probe_applied() {
    use crate::hardening::Val;
    let base = Some([Val::One; 8]);
    for (mount, name, on, state) in [
        (MountTier::NotApplicable, "systemd", false, "not_applicable"),
        (MountTier::Dropped, "systemd", false, "dropped"),
        (
            MountTier::Applied([Val::One; 4]),
            "systemd+mount",
            true,
            "verified",
        ),
        (
            MountTier::Applied([Val::Na, Val::One, Val::One, Val::One]),
            "systemd+mount",
            true,
            "partial",
        ),
    ] {
        let m = mode_for(Tiers { base, mount });
        assert_eq!(
            (m.name, m.mount_tier, m.tiers.mount_state()),
            (name, on, state)
        );
    }
}
