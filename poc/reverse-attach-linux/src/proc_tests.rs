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
    use std::os::unix::fs::PermissionsExt;
    let t = TempDir::new();
    let scope = t.path.join("staging");
    let outside = t.path.join("outside");
    std::fs::create_dir_all(&scope).unwrap();
    std::fs::create_dir_all(&outside).unwrap();
    for d in [&scope, &outside] {
        let bin = d.join("bleeper");
        std::fs::copy("/bin/sleep", &bin).unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let mut look = std::process::Command::new(outside.join("bleeper"))
        .arg("300")
        .spawn()
        .unwrap();
    let script = format!(
        "setsid {}/bleeper 300 & echo $!; sleep 300",
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
