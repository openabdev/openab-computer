use super::*;
use crate::install::tests::{good_facts, Env, Tw};
use crate::preflight::Libc;
use serde_json::Value;

fn args(a: &[&str]) -> Vec<String> {
    a.iter().map(|s| s.to_string()).collect()
}

#[test]
fn arguments_parse_and_everything_else_is_a_usage_error() {
    assert_eq!(parse(&args(&["plan"])), Ok(Cmd::Plan));
    assert_eq!(
        parse(&args(&["preflight"])),
        Ok(Cmd::Preflight {
            root_actions: false
        })
    );
    assert_eq!(
        parse(&args(&["install"])),
        Ok(Cmd::Install { from_dir: None })
    );
    assert_eq!(
        parse(&args(&["install", "--from-dir", "/x"])),
        Ok(Cmd::Install {
            from_dir: Some(PathBuf::from("/x"))
        })
    );
    assert_eq!(
        parse(&args(&["update"])),
        Ok(Cmd::Update {
            yes: false,
            from_dir: None
        })
    );
    assert_eq!(
        parse(&args(&["update", "--yes", "--from-dir", "d"])),
        Ok(Cmd::Update {
            yes: true,
            from_dir: Some(PathBuf::from("d"))
        })
    );
    assert_eq!(parse(&args(&["remove"])), Ok(Cmd::Remove));
    assert_eq!(
        parse(&args(&["status"])),
        Ok(Cmd::Status {
            json: false,
            retry: false
        })
    );
    assert_eq!(
        parse(&args(&["status", "--json"])),
        Ok(Cmd::Status {
            json: true,
            retry: false
        })
    );
    for bad in [
        vec![],
        vec!["nope"],
        vec!["plan", "--yes"],
        vec!["install", "--yes"],
        vec!["install", "--from-dir"],
        vec!["install", "--from-dir", "a", "--from-dir", "b"],
        vec!["remove", "--json"],
        vec!["status", "--from-dir", "x"],
        vec!["signin", "--yes"],
        vec!["signin", "--url"],
        vec!["signin", "--url", "a", "--url", "b"],
        vec!["preflight", "--json"],
        vec!["install", "--apply-system-changes"],
        vec!["install", "--use-system-chromium"],
        vec!["update", "extra"],
    ] {
        assert!(parse(&args(&bad)).is_err(), "{bad:?}");
    }
    assert_eq!(parse(&args(&["signin"])), Ok(Cmd::Signin { url: None }));
    assert_eq!(
        parse(&args(&["signin", "--url", "https://example.com/"])),
        Ok(Cmd::Signin {
            url: Some("https://example.com/".into())
        })
    );
    assert_eq!(
        parse(&args(&["preflight", "--root-actions"])),
        Ok(Cmd::Preflight { root_actions: true })
    );
    // The root actions belong to the installer script, and the message says so.
    let m = parse(&args(&["install", "--apply-system-changes"]))
        .unwrap_err()
        .0;
    assert!(m.contains("install-linux.sh") && m.contains("never runs a root action"));
    assert!(parse(&args(&["install", "--use-system-chromium"]))
        .unwrap_err()
        .0
        .contains("not available"));
}

#[test]
fn a_blocker_prints_the_fixed_stderr_line_and_root_actions_print_one_tab_line_each() {
    let e = Env::new(Tw::default());
    let m = e.manifest("test-id-1");
    let mut bad = good_facts();
    bad.libc = Libc::Musl;
    let r = exec(
        &e,
        &m,
        &Cmd::Preflight {
            root_actions: false,
        },
        None,
        bad,
        None,
    );
    assert_eq!(r.code, 1);
    assert!(
        r.err
            .lines()
            .any(|l| l == "browser: preflight_failed class=musl"),
        "{}",
        r.err
    );
    let mut old = good_facts();
    old.free_disk = Some(1);
    let r = exec(
        &e,
        &m,
        &Cmd::Preflight {
            root_actions: false,
        },
        None,
        old,
        None,
    );
    assert!(
        r.err.contains("preflight_failed class=disk_full"),
        "{}",
        r.err
    );

    // --root-actions: only `command<TAB>reason`, exit 0 whatever else is blocked.
    let mut f = good_facts();
    f.userns.apparmor_restricted = Some(true);
    f.data_base = PathBuf::from("/home/u/.local/share");
    f.libc = Libc::Musl;
    let r = exec(
        &e,
        &m,
        &Cmd::Preflight { root_actions: true },
        None,
        f,
        None,
    );
    assert_eq!(r.code, 0);
    assert!(r.err.is_empty(), "{}", r.err);
    let lines: Vec<&str> = r.out.lines().collect();
    assert_eq!(lines.len(), 1, "{lines:?}");
    let (cmd, why) = lines[0].split_once('\t').expect("one tab");
    assert!(cmd.starts_with("printf ") && cmd.contains("sudo apparmor_parser -r"));
    assert!(!why.is_empty() && !why.contains('\t'));
    // Nothing else is printed when there is no root action.
    let r = exec(
        &e,
        &m,
        &Cmd::Preflight { root_actions: true },
        None,
        good_facts(),
        None,
    );
    assert_eq!((r.code, r.out.as_str()), (0, ""));
}

struct Run {
    code: i32,
    out: String,
    err: String,
}

fn exec(
    e: &Env,
    m: &Manifest,
    cmd: &Cmd,
    ask: Option<bool>,
    facts: Facts,
    dir: Option<&Path>,
) -> Run {
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let code = e.with(m, dir, facts, |o| {
        execute(
            cmd,
            o,
            &mut Io {
                out: &mut out,
                err: &mut err,
            },
            &mut |_| ask,
        )
    });
    Run {
        code,
        out: String::from_utf8(out).unwrap(),
        err: String::from_utf8(err).unwrap(),
    }
}

#[test]
fn the_commands_end_to_end_with_exit_codes_and_fixed_messages() {
    let e = Env::new(Tw::default());
    let m = e.manifest("test-id-1");
    let m2 = e.manifest("test-id-2");

    // plan: the consent text, no network, nothing written.
    let r = exec(&e, &m, &Cmd::Plan, None, good_facts(), None);
    assert_eq!(r.code, 0);
    assert!(r.out.starts_with("Downloads about ") && r.out.contains("test-id-1"));
    assert!(!r.out.to_lowercase().contains("safe"));
    assert_eq!(e.net.conns(), 0);
    assert!(!e.t.base().exists());

    // preflight: ok, then blocked.
    let r = exec(
        &e,
        &m,
        &Cmd::Preflight {
            root_actions: false,
        },
        None,
        good_facts(),
        None,
    );
    assert_eq!(r.code, 0);
    assert!(r.out.contains("preflight: ok"));
    let mut bad = good_facts();
    bad.libc = Libc::Musl;
    let r = exec(
        &e,
        &m,
        &Cmd::Preflight {
            root_actions: false,
        },
        None,
        bad,
        None,
    );
    assert_eq!(r.code, 1);
    assert!(r.out.contains("musl"));
    assert!(!e.t.base().exists(), "preflight creates nothing");

    // status before anything.
    let r = exec(
        &e,
        &m,
        &Cmd::Status {
            json: false,
            retry: false,
        },
        None,
        good_facts(),
        None,
    );
    assert_eq!(r.code, 0);
    assert!(r.out.contains("state: not_installed"));
    let r = exec(&e, &m, &Cmd::Remove, None, good_facts(), None);
    assert_eq!((r.code, r.out.trim()), (0, "nothing to remove"));

    // install.
    let r = exec(
        &e,
        &m,
        &Cmd::Install { from_dir: None },
        None,
        good_facts(),
        None,
    );
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    assert!(r.out.contains("installed test-id-1"));
    let r = exec(
        &e,
        &m,
        &Cmd::Install { from_dir: None },
        None,
        good_facts(),
        None,
    );
    assert_eq!((r.code, r.out.trim()), (0, "already installed: test-id-1"));

    // status, human and machine readable.
    let r = exec(
        &e,
        &m,
        &Cmd::Status {
            json: false,
            retry: false,
        },
        None,
        good_facts(),
        None,
    );
    assert_eq!(r.out.lines().count(), 14);
    assert!(r.out.lines().all(|l| l.contains(": ")));
    assert!(r.out.contains("state: installed") && r.out.contains("installed_id: test-id-1"));
    let r = exec(
        &e,
        &m,
        &Cmd::Status {
            json: true,
            retry: false,
        },
        None,
        good_facts(),
        None,
    );
    let v: Value = serde_json::from_str(r.out.trim()).unwrap();
    assert_eq!(v["state"], "installed");
    assert_eq!(v["update_available"], false);
    assert_eq!(v["pins_match"], true);
    assert_eq!(v["previous"], Value::Null);
    assert_eq!(v.as_object().unwrap().len(), 14);

    // update without a yes, then declined, then confirmed.
    let u = Cmd::Update {
        yes: false,
        from_dir: None,
    };
    let r = exec(&e, &m2, &u, None, good_facts(), None);
    assert_eq!(r.code, 1);
    assert!(
        r.err
            .contains("browser: update_failed class=confirmation_required"),
        "{}",
        r.err
    );
    assert!(r.err.contains("--yes"));
    let r = exec(&e, &m2, &u, Some(false), good_facts(), None);
    assert_eq!((r.code, r.err.contains("class=declined")), (1, true));
    let r = exec(&e, &m2, &u, Some(true), good_facts(), None);
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    assert!(r.out.contains("updated test-id-1 to test-id-2"));
    let r = exec(&e, &m2, &u, Some(true), good_facts(), None);
    assert_eq!((r.code, r.out.trim()), (0, "already up to date: test-id-2"));

    // a different version than installed: install points at update.
    let r = exec(
        &e,
        &m,
        &Cmd::Install { from_dir: None },
        None,
        good_facts(),
        None,
    );
    assert_eq!(r.code, 1);
    assert!(
        r.err.contains("class=use_update") && r.err.contains("browser update"),
        "{}",
        r.err
    );

    // remove: what went, what stayed.
    std::fs::write(e.root().join("mine.txt"), "m").unwrap();
    let r = exec(&e, &m2, &Cmd::Remove, None, good_facts(), None);
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    for n in [
        "install.json",
        "test-id-2",
        "test-id-1",
        "profile",
        "pending-cleanup.json",
    ] {
        assert!(r.out.contains(&format!("removed: {n}")), "{n}\n{}", r.out);
    }
    assert!(r.out.contains("left in place: mine.txt"));
    assert!(r.out.contains("left in place: .install.lock"));
    assert!(r
        .out
        .lines()
        .any(|l| l.starts_with("left in place: ") && l.contains("holds the lock file")));
    assert!(e.root().join("mine.txt").exists());
    for s in [&r.out, &r.err] {
        assert!(!s.contains("SECRET-CANARY") && !s.contains("http://") && !s.contains("https://"));
    }
}

#[test]
fn failures_print_one_fixed_line_and_a_hint_and_nothing_else() {
    let e = Env::new(Tw::default());
    let m = e.manifest("test-id-1");
    e.set_mode("bad_name");
    let r = exec(
        &e,
        &m,
        &Cmd::Install { from_dir: None },
        None,
        good_facts(),
        None,
    );
    assert_eq!(r.code, 1);
    assert!(
        r.err
            .contains("browser: install_failed class=health_check_failed"),
        "{}",
        r.err
    );
    assert!(!r.err.contains("SECRET-CANARY") && !r.out.contains("SECRET-CANARY"));
    // A foreign record gets its explanation.
    let e = Env::new(Tw::default());
    let m = e.manifest("test-id-1");
    drop(e.t.root());
    std::fs::write(e.root().join("install.json"), "{}").unwrap();
    let r = exec(
        &e,
        &m,
        &Cmd::Install { from_dir: None },
        None,
        good_facts(),
        None,
    );
    assert_eq!(r.code, 1);
    assert!(r.err.contains("class=foreign_install") && r.err.contains("left as it is"));
    let r = exec(
        &e,
        &m,
        &Cmd::Status {
            json: true,
            retry: false,
        },
        None,
        good_facts(),
        None,
    );
    assert!(r.out.contains("foreign_install"));
}

#[test]
fn an_unsupported_platform_is_reported() {
    let e = Env::new(Tw::default());
    let m = e.manifest("test-id-1");
    let policy = crate::download::DownloadPolicy::for_tests(&["127.0.0.1"]);
    let facts = |_: &Path| good_facts();
    let o = Opts {
        manifest: &m,
        files: Files {
            package_json: &e.pkg_json,
            lockfile: &e.lock_json,
        },
        source: Source::Network(&policy),
        check_manifest: false,
        limits: Limits::default(),
        timeouts: Timeouts::default(),
        npm_timeout: Duration::from_secs(1),
        lock_wait: Duration::from_millis(10),
        base: e.t.base(),
        home: None,
        platform: None,
        facts: &facts,
        launcher: &crate::sigstop::Plain,
        extras: &|_: &Path, _: bool| crate::probe::Extras::none(),
    };
    for cmd in [
        Cmd::Plan,
        Cmd::Preflight {
            root_actions: false,
        },
    ] {
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let code = execute(
            &cmd,
            &o,
            &mut Io {
                out: &mut out,
                err: &mut err,
            },
            &mut |_| None,
        );
        assert_eq!(code, 1);
        assert!(String::from_utf8(err)
            .unwrap()
            .contains("class=unsupported_platform"));
    }
}
