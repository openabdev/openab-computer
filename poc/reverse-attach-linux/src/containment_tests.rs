use super::*;
use std::sync::atomic::Ordering;

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
        selftest_prefix: "oab-l2-test-selftest".into(),
        browser_prefix: "oab-l2-test-browser".into(),
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
// Run with `OAB_L2_SYSTEMD=1 cargo test --release containment -- --ignored`. Every unit is named
// `oab-l2-test-*`, and every test ends with none left.

#[cfg(target_os = "linux")]
fn leftovers(sys: &Sys) -> Vec<String> {
    let mut v = sys.list_prefixed("oab-l2-test").unwrap_or_default();
    v.sort();
    v
}

#[cfg(target_os = "linux")]
fn enabled() -> bool {
    std::env::var_os("OAB_L2_SYSTEMD").is_some()
}

#[cfg(target_os = "linux")]
#[test]
#[ignore = "needs a systemd user manager; OAB_L2_SYSTEMD=1"]
fn the_self_test_passes_on_a_host_with_a_user_manager_and_leaves_nothing() {
    if !enabled() {
        return;
    }
    let s = systemd_with(Sys::from_env());
    let started = Instant::now();
    let r = s.verify();
    assert!(r.is_ok(), "{r:?}");
    assert!(started.elapsed() < Duration::from_secs(30));
    assert_eq!(leftovers(&s.sys), Vec::<String>::new());
    // No sleeper of the fixture is left either.
    let me = rustix::process::geteuid().as_raw();
    let stray = proc::proc_pids().into_iter().any(|p| {
        proc::same_uid(p)
            && std::fs::read_to_string(format!("/proc/{p}/cgroup"))
                .is_ok_and(|c| c.contains("oab-l2-test-selftest"))
    });
    assert!(
        !stray,
        "a fixture process outlived the self-test (uid {me})"
    );
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
    let stray = "oab-l2-test-selftest-dead-p";
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
    assert!(leftovers(&sys).iter().any(|u| u.starts_with(stray)));
    let s = systemd_with(sys.clone());
    assert!(s.verify().is_ok());
    assert_eq!(leftovers(&sys), Vec::<String>::new());
}
