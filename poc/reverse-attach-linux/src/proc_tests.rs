use super::*;
use crate::state::tests::TempDir;

fn sh(script: &str, cwd: &Path) -> Spec {
    Spec {
        exe: PathBuf::from("/bin/sh"),
        args: vec!["-c".into(), script.into()],
        env: vec![("A".into(), "1".into())],
        cwd: cwd.to_path_buf(),
    }
}

fn gone(pid: &str) -> bool {
    for _ in 0..60 {
        let alive = std::process::Command::new("kill")
            .args(["-0", pid])
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if !alive {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    false
}

fn first_line(c: &mut Child) -> String {
    match c
        .lines
        .as_ref()
        .unwrap()
        .recv_timeout(Duration::from_secs(5))
        .unwrap()
    {
        Line::Data(b) => String::from_utf8(b).unwrap(),
        other => panic!("{other:?}"),
    }
}

#[test]
fn lines_are_split_and_capped() {
    assert_eq!(
        lines_of(b"a\nb\n", 10),
        vec![
            Line::Data(b"a".to_vec()),
            Line::Data(b"b".to_vec()),
            Line::Eof
        ]
    );
    assert_eq!(
        lines_of(b"a\nlast", 10),
        vec![
            Line::Data(b"a".to_vec()),
            Line::Data(b"last".to_vec()),
            Line::Eof
        ]
    );
    assert_eq!(lines_of(b"\n\n", 10)[0], Line::Data(vec![]));
    assert_eq!(
        lines_of(b"abcd\n", 4),
        vec![Line::Data(b"abcd".to_vec()), Line::Eof]
    );
    assert_eq!(lines_of(b"abcde\n", 4), vec![Line::TooLong]);
    assert_eq!(lines_of(b"abcdefgh", 4), vec![Line::TooLong]);
    assert_eq!(lines_of(b"", 4), vec![Line::Eof]);
}

#[test]
fn the_environment_is_exactly_the_allow_list() {
    let t = TempDir::new();
    let spec = Spec {
        exe: PathBuf::from("/usr/bin/env"),
        args: vec![],
        env: vec![("A".into(), "1".into())],
        cwd: t.path.clone(),
    };
    let c = Child::spawn(&spec, false, true, 1024, &t.path).unwrap();
    let mut seen = Vec::new();
    while let Ok(l) = c
        .lines
        .as_ref()
        .unwrap()
        .recv_timeout(Duration::from_secs(5))
    {
        match l {
            Line::Data(b) => seen.push(String::from_utf8(b).unwrap()),
            _ => break,
        }
    }
    assert!(seen.contains(&"A=1".to_string()), "{seen:?}");
    for bad in ["HOME=", "PATH=", "USER=", "SSH_", "GH_", "TOKEN"] {
        assert!(
            !seen.iter().any(|l| l.starts_with(bad)),
            "{bad} leaked: {seen:?}"
        );
    }
}

#[test]
fn stop_ends_the_whole_process_group_and_drop_does_the_same() {
    let t = TempDir::new();
    let mut c = Child::spawn(
        &sh("sleep 300 & echo $!; wait", &t.path),
        false,
        true,
        1024,
        &t.path,
    )
    .unwrap();
    let pid = first_line(&mut c);
    c.stop();
    assert!(gone(&pid), "the group member survived stop");
    c.stop(); // twice is fine

    let mut d = Child::spawn(
        &sh("sleep 300 & echo $!; wait", &t.path),
        false,
        true,
        1024,
        &t.path,
    )
    .unwrap();
    let pid = first_line(&mut d);
    drop(d);
    assert!(gone(&pid), "the group member survived drop");
}

#[test]
fn stderr_stays_in_a_ring_and_only_a_class_leaves() {
    let t = TempDir::new();
    let mut c = Child::spawn(
        &sh(
            "echo 'SECRET-CANARY No usable sandbox' >&2; exit 3",
            &t.path,
        ),
        false,
        true,
        1024,
        &t.path,
    )
    .unwrap();
    for _ in 0..100 {
        if c.has_exited() {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    std::thread::sleep(Duration::from_millis(100));
    assert_eq!(c.stderr_class(), StderrClass::LaunchRefused);
    assert!(c.stderr_contains_any(&["sandbox"]));
    assert_eq!(c.exit_ok(), Some(false));
    // stdout stays empty: stderr is never mixed into it.
    match c
        .lines
        .as_ref()
        .unwrap()
        .recv_timeout(Duration::from_secs(2))
        .unwrap()
    {
        Line::Eof => {}
        other => panic!("stdout got {other:?}"),
    }
}

#[test]
fn the_stderr_ring_keeps_only_the_newest_bytes() {
    let t = TempDir::new();
    let mut c = Child::spawn(
        &sh(
            "head -c 300000 /dev/zero | tr '\\0' x >&2; echo END-MARK >&2",
            &t.path,
        ),
        false,
        false,
        0,
        &t.path,
    )
    .unwrap();
    for _ in 0..200 {
        if c.has_exited() {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    std::thread::sleep(Duration::from_millis(200));
    assert!(c.stderr_contains_any(&["end-mark"]));
    assert!(c.ring.lock().unwrap().len() <= RING_CAP);
    c.stop();
}

#[cfg(target_os = "linux")]
#[test]
fn a_detached_grandchild_under_the_scope_is_killed_and_a_lookalike_outside_survives() {
    let t = TempDir::new();
    let scope = t.path.join("staging");
    let outside = t.path.join("outside");
    std::fs::create_dir_all(&scope).unwrap();
    std::fs::create_dir_all(&outside).unwrap();
    for d in [&scope, &outside] {
        std::fs::create_dir_all(d.join("bleeper")).unwrap();
        let bin = d.join("bleeper").join("sleep");
        crate::test_exec::copy_exec(std::path::Path::new("/bin/sleep"), &bin);
    }
    let mut look = std::process::Command::new(outside.join("bleeper/sleep"))
        .arg("300")
        .spawn()
        .unwrap();
    let script = format!(
        "setsid {}/bleeper/sleep 300 & echo $!; sleep 300",
        scope.display()
    );
    let mut c = Child::spawn(&sh(&script, &t.path), false, true, 1024, &scope).unwrap();
    let pid = first_line(&mut c);
    assert!(!gone_quick(&pid), "the detached grandchild started");
    c.stop();
    assert!(gone(&pid), "the detached grandchild was not killed");
    assert!(
        !gone_quick(&look.id().to_string()),
        "the look-alike outside the scope was killed"
    );
    look.kill().unwrap();
    look.wait().unwrap();
}

#[cfg(target_os = "linux")]
fn gone_quick(pid: &str) -> bool {
    !std::process::Command::new("kill")
        .args(["-0", pid])
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

#[test]
fn has_exited_does_not_reap_and_exit_ok_does() {
    let t = TempDir::new();
    let mut c = Child::spawn(&sh("exit 0", &t.path), false, false, 0, &t.path).unwrap();
    for _ in 0..100 {
        if c.has_exited() {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(c.has_exited());
    assert!(c.has_exited(), "asking twice is fine");
    assert_eq!(c.exit_ok(), Some(true));
    assert!(c.has_exited());
}

#[test]
fn an_unread_flood_of_lines_blocks_the_child_instead_of_filling_memory() {
    let t = TempDir::new();
    let cwd = t.base();
    std::fs::create_dir_all(&cwd).unwrap();
    // 200 lines of about 100 KB (20 MB) and then a marker file. With an unbounded queue the
    // marker appears at once; with the bound the child stays blocked on its pipe.
    let script = "i=0; l=$(head -c 100000 /dev/zero | tr '\\0' a); \
                  while [ $i -lt 200 ]; do echo \"$l\"; i=$((i+1)); done; touch done";
    let mut c = Child::spawn(&sh(script, &cwd), false, true, 1 << 20, &cwd).unwrap();
    std::thread::sleep(Duration::from_millis(1500));
    assert!(
        !cwd.join("done").exists(),
        "the child finished: lines were queued without bound"
    );
    let mut n = 0;
    while let Ok(Line::Data(_)) = c
        .lines
        .as_ref()
        .unwrap()
        .recv_timeout(Duration::from_secs(10))
    {
        n += 1;
    }
    assert_eq!(n, 200, "backpressure must not drop lines");
    assert!(cwd.join("done").exists());
    c.stop();
}

// ---- L2: signalling through a pidfd ---------------------------------------------------------

#[cfg(target_os = "linux")]
fn waits_dead(c: &mut std::process::Child) -> bool {
    for _ in 0..100 {
        if matches!(c.try_wait(), Ok(Some(_))) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(30));
    }
    false
}

/// A PID that now names something else: the recheck after the pidfd exists fails, and nothing is
/// signalled. The look-alike case for the recheck itself is the scope test above.
#[cfg(target_os = "linux")]
#[test]
fn a_process_that_fails_the_recheck_is_never_signalled() {
    let mut c = std::process::Command::new("sleep")
        .arg("30")
        .stdout(Stdio::null())
        .spawn()
        .unwrap();
    assert!(!kill_pid_checked(c.id(), &|_| false));
    std::thread::sleep(Duration::from_millis(200));
    assert!(
        matches!(c.try_wait(), Ok(None)),
        "the process was signalled"
    );
    assert!(kill_pid_checked(c.id(), &|_| true));
    assert!(waits_dead(&mut c));
}

#[cfg(target_os = "linux")]
#[test]
fn a_pid_that_does_not_exist_signals_nothing_and_does_not_panic() {
    assert!(!kill_pid_checked(0, &|_| true));
    assert!(!kill_pid_checked(u32::MAX, &|_| true));
    // The highest PID the kernel allows is never in use on a test host.
    let top: u32 = std::fs::read_to_string("/proc/sys/kernel/pid_max")
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(4_194_304);
    assert!(!kill_pid_checked(top + 1, &|_| true));
}

/// The recheck sees the process the pidfd names, not the one the scan saw: when it is called, the
/// pidfd already exists, so it is the last word before the signal.
#[cfg(target_os = "linux")]
#[test]
fn the_recheck_runs_after_the_pidfd_is_open() {
    let mut c = std::process::Command::new("sleep")
        .arg("30")
        .stdout(Stdio::null())
        .spawn()
        .unwrap();
    let pid = c.id();
    let saw = std::cell::Cell::new(false);
    let ok = kill_pid_checked(pid, &|p| {
        saw.set(true);
        // The process is still the one we started: its exe is `sleep`.
        std::fs::read_link(format!("/proc/{p}/exe"))
            .is_ok_and(|e| e.file_name().is_some_and(|n| n == "sleep"))
    });
    assert!(saw.get() && ok);
    assert!(waits_dead(&mut c));
}

#[cfg(target_os = "linux")]
#[test]
fn kill_matching_honours_protect_and_the_exe_test() {
    let t = TempDir::new();
    let dir = t.path.join("scope/bin");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::create_dir_all(dir.join("sleeper")).unwrap();
    let exe = dir.join("sleeper").join("sleep");
    crate::test_exec::copy_exec(std::path::Path::new("/bin/sleep"), &exe);
    let mut a = std::process::Command::new(&exe).arg("30").spawn().unwrap();
    let mut b = std::process::Command::new(&exe).arg("30").spawn().unwrap();
    let scope = t.path.join("scope");
    let protected = b.id();
    let n = kill_matching(&|e| e.starts_with(&scope), &|p| p == protected);
    assert_eq!(n, 1);
    assert!(waits_dead(&mut a));
    std::thread::sleep(Duration::from_millis(200));
    assert!(matches!(b.try_wait(), Ok(None)), "a protected process died");
    b.kill().unwrap();
    b.wait().unwrap();
}

#[test]
fn the_unit_of_a_cgroup_is_its_last_service_or_scope_component() {
    let cg = |p: &str| unit_of_cgroup(&format!("0::{p}\n"));
    assert_eq!(
        cg("/user.slice/user-1000.slice/app.slice/oab-computer.service").as_deref(),
        Some("oab-computer.service")
    );
    assert_eq!(
        cg("/user.slice/user-1000.slice/session-3.scope").as_deref(),
        Some("session-3.scope")
    );
    assert_eq!(cg("/user.slice/user-1000.slice/app.slice"), None);
    assert_eq!(unit_of_cgroup("12:memory:/x\n"), None);
    assert_eq!(unit_of_cgroup(""), None);
}

#[cfg(target_os = "linux")]
#[test]
fn stat_fields_reads_this_process() {
    let f = stat_fields(std::process::id()).unwrap();
    assert!(f.pgrp > 0 && f.session > 0 && f.ppid > 0);
    assert_eq!(
        Some(f.start),
        crate::state::proc_start_time(std::process::id())
    );
    assert!(stat_fields(u32::MAX).is_none());
}

/// A child is a session leader and has no controlling terminal.
#[cfg(target_os = "linux")]
#[test]
fn a_child_leads_its_own_session() {
    let t = TempDir::new();
    let mut c = Child::spawn(&sh("sleep 30", &t.path), false, false, 1024, &t.path).unwrap();
    let f = stat_fields(c.pid()).unwrap();
    assert_eq!((f.pgrp, f.session), (c.pid(), c.pid()));
    c.stop();
}

/// A unit's stop hook runs before the group is signalled.
#[test]
fn the_unit_stop_hook_runs_first_and_once() {
    let t = TempDir::new();
    let seen = Arc::new(Mutex::new(Vec::<String>::new()));
    let s2 = Arc::clone(&seen);
    let mut c = Child::spawn_with(
        &sh("sleep 30", &t.path),
        false,
        false,
        1024,
        &t.path,
        Some(UnitCtl {
            name: "oab-x.service".into(),
            stop: Box::new(move |u| s2.lock().unwrap().push(u.to_string())),
        }),
    )
    .unwrap();
    c.stop();
    c.stop();
    drop(c);
    assert_eq!(*seen.lock().unwrap(), ["oab-x.service"]);
}

/// A group id is signalled only while the leader is unreaped; after a reap the number may name
/// something else. The tree walk still ends what is under the scope.
#[cfg(target_os = "linux")]
#[test]
fn a_reaped_leaders_group_number_is_not_signalled() {
    let t = TempDir::new();
    // The leader backgrounds a sleeper in its own group and exits at once.
    let mut c = Child::spawn(
        &sh("sleep 300 & echo $!", &t.path),
        false,
        true,
        1024,
        &t.path,
    )
    .unwrap();
    let pid: u32 = first_line(&mut c).parse().unwrap();
    let end = Instant::now() + Duration::from_secs(5);
    while Instant::now() < end && c.exit_ok().is_none() {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(c.has_exited());
    c.stop();
    std::thread::sleep(Duration::from_millis(200));
    // `sleep` lives outside the scope, so only the group number could have reached it.
    assert!(
        crate::state::proc_start_time(pid).is_some(),
        "the group of a reaped leader was signalled by number"
    );
    crate::proc::kill_pid_checked(pid, &|_| true);
}
