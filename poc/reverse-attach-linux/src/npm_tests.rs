use super::*;
use crate::state::tests::TempDir;
use std::os::unix::fs::PermissionsExt;

fn staging(t: &TempDir, node_script: &str) -> PathBuf {
    let s = t.path.join("stg");
    std::fs::create_dir_all(s.join("node/bin")).unwrap();
    std::fs::create_dir_all(s.join("pkg")).unwrap();
    let n = s.join("node/bin/node");
    crate::test_exec::write_exec(&n, node_script.as_bytes());
    s
}

#[test]
fn the_command_is_confined_to_staging_and_never_inherits() {
    let s = Path::new("/stg");
    let c = command(s, &["ci"], false);
    assert_eq!(c.exe, Path::new("/stg/node/bin/node"));
    assert_eq!(c.cwd, Path::new("/stg/pkg"));
    assert_eq!(c.args[0], "/stg/node/lib/node_modules/npm/bin/npm-cli.js");
    assert_eq!(c.args[1], "ci");
    for must in [
        "--ignore-scripts",
        "--omit=dev",
        "--no-audit",
        "--no-fund",
        "--userconfig",
        "--globalconfig",
        "--registry",
        "--cache",
    ] {
        assert!(c.args.iter().any(|a| a == must), "{must}");
    }
    assert!(c.args.contains(&"/stg/user.npmrc".to_string()));
    assert!(c.args.contains(&"/stg/npm-cache".to_string()));
    assert!(c.args.contains(&REGISTRY.to_string()));
    assert!(!c.args.iter().any(|a| a == "--offline"));
    let keys: Vec<&str> = c.env.iter().map(|(k, _)| k.as_str()).collect();
    assert_eq!(keys, ["HOME", "TMPDIR", "LANG", "PATH"]);
    assert!(c
        .env
        .iter()
        .all(|(k, v)| k == "LANG" || v.starts_with("/stg/")));
    let off = command(s, &["cache", "add", "/x.tgz"], true);
    assert!(off.args.iter().any(|a| a == "--offline"));
    assert_eq!(&off.args[1..4], ["cache", "add", "/x.tgz"]);
}

#[test]
fn prepare_makes_the_private_directories_and_empty_configs() {
    let t = TempDir::new();
    let dir = t.path.join("s");
    std::fs::create_dir(&dir).unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    let fd = rustix::fs::open(
        &dir,
        rustix::fs::OFlags::RDONLY | rustix::fs::OFlags::DIRECTORY,
        rustix::fs::Mode::empty(),
    )
    .unwrap();
    prepare(&fd).unwrap();
    for d in ["home", "tmp", "npm-cache"] {
        assert_eq!(
            std::fs::metadata(dir.join(d)).unwrap().permissions().mode() & 0o777,
            0o700
        );
    }
    for f in ["user.npmrc", "global.npmrc"] {
        let m = std::fs::metadata(dir.join(f)).unwrap();
        assert_eq!((m.len(), m.permissions().mode() & 0o777), (0, 0o600));
    }
    assert!(prepare(&fd).is_err(), "never reuses what exists");
}

#[test]
fn outcomes_are_fixed_classes() {
    let t = TempDir::new();
    let run_with = |script: &str, to: u64| {
        run(
            &staging(&t, script),
            &["ci"],
            false,
            Duration::from_millis(to),
        )
    };
    assert_eq!(run_with("#!/bin/sh\nexit 0\n", 5000), Outcome::Ok);
    assert_eq!(
        run_with(
            "#!/bin/sh\necho 'npm ERR! code EINTEGRITY' >&2\nexit 1\n",
            5000
        ),
        Outcome::Integrity
    );
    assert_eq!(
        run_with(
            "#!/bin/sh\necho 'npm ERR! code ENOTFOUND' >&2\nexit 1\n",
            5000
        ),
        Outcome::Offline
    );
    assert_eq!(
        run_with(
            "#!/bin/sh\necho 'SECRET-CANARY' >&2\necho SECRET-CANARY\nexit 1\n",
            5000
        ),
        Outcome::Failed
    );
    let started = std::time::Instant::now();
    assert_eq!(run_with("#!/bin/sh\nsleep 30\n", 300), Outcome::TimedOut);
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "a timeout stops the child promptly"
    );
    assert_eq!(Outcome::TimedOut.class(), "npm_timed_out");
    assert!(require_ok(Outcome::Ok).is_ok());
    assert_eq!(require_ok(Outcome::Integrity), Err(Fail("npm_integrity")));
}

#[test]
fn a_missing_node_is_a_failure_not_a_panic() {
    let t = TempDir::new();
    assert_eq!(
        run(&t.path.join("nope"), &["ci"], false, Duration::from_secs(1)),
        Outcome::Failed
    );
}

#[test]
fn the_child_sees_only_the_allow_list() {
    let t = TempDir::new();
    let log = t.path.join("env.log");
    let s = staging(&t, &format!("#!/bin/sh\nenv > {}\nexit 0\n", log.display()));
    assert_eq!(run(&s, &["ci"], false, Duration::from_secs(5)), Outcome::Ok);
    let env = std::fs::read_to_string(&log).unwrap();
    for l in env.lines() {
        let k = l.split('=').next().unwrap();
        assert!(
            ["HOME", "TMPDIR", "LANG", "PATH", "PWD", "SHLVL", "_", "OLDPWD"].contains(&k),
            "unexpected variable {k}"
        );
    }
    assert!(env.contains(&format!("HOME={}", s.join("home").display())));
}
