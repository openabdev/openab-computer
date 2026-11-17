use super::*;
use crate::containment::{SYSTEMD, UNVERIFIED};
use crate::hardening::{MountTier, Val};
use crate::state::tests::TempDir;
use std::collections::HashMap;

struct Tables(HashMap<&'static str, String>);

impl Source for Tables {
    fn table(&self, name: &str) -> std::io::Result<String> {
        self.0
            .get(name)
            .cloned()
            .ok_or_else(|| std::io::Error::other("none"))
    }
}

fn nothing() -> Result<Mode, &'static str> {
    panic!("the self-test must not run without --retry")
}

#[test]
fn by_default_nothing_runs_and_the_vocabulary_is_fixed() {
    let t = TempDir::new();
    let x = gather(&t.base(), false, None, &Tables(HashMap::new()), &nothing);
    assert_eq!(x, Extras::none());
    assert_eq!(x.containment, "not_checked");
    assert_eq!(x.external_configured, "no");
    assert_eq!(x.listeners, "not_running");
    assert_eq!(x.refusal, "none");
    // L4: nothing was probed, and there is no install root yet.
    assert_eq!(x.hardening_base, "not_checked");
    assert_eq!(x.hardening_mount, "not_checked");
    assert_eq!(x.hardening_unverified, "not_checked");
    assert_eq!(x.run_records, "unavailable");
    // L5: `gather` does not look at the home directory, so the legacy fields stay `none`.
    assert_eq!(
        (
            x.legacy_units.as_str(),
            x.legacy.as_str(),
            x.legacy_listener.as_str()
        ),
        ("none", "none", "none")
    );
    assert!(!x.legacy_present());
}

#[test]
fn the_legacy_fields_are_set_apart_from_the_probe() {
    let mut x = Extras::none();
    x.set_legacy(crate::legacy::Legacy {
        units: "oab-pw-mcp.service".into(),
        paths: "~/.cache/ms-playwright:1 MiB".into(),
        listener: "8794".into(),
    });
    assert!(x.legacy_present());
    assert_eq!(x.legacy_units, "oab-pw-mcp.service");
    assert_eq!(x.legacy, "~/.cache/ms-playwright:1 MiB");
    assert_eq!(x.legacy_listener, "8794");
}

#[test]
fn external_configured_is_yes_or_no_and_never_the_url() {
    let t = TempDir::new();
    let none = Tables(HashMap::new());
    for (env, want) in [
        (Some("browser=http://127.0.0.1:8794/mcp"), "yes"),
        (Some("other=http://127.0.0.1:1/x"), "no"),
        (Some(""), "no"),
        (None, "no"),
    ] {
        let x = gather(&t.base(), false, env, &none, &nothing);
        assert_eq!(x.external_configured, want, "{env:?}");
        assert!(!format!("{x:?}").contains("8794"));
    }
}

#[test]
fn retry_reruns_the_self_test_and_clears_the_latch() {
    let t = TempDir::new();
    let root = crate::run_record::tests::root_with_run(&t);
    crate::run_record::latch_set(&root).unwrap();
    let none = Tables(HashMap::new());
    let x = gather(&t.base(), true, None, &none, &|| Ok(SYSTEMD));
    assert_eq!(x.containment, "systemd");
    assert!(!crate::run_record::latch_is_set(&root));
    let x = gather(&t.base(), true, None, &none, &|| Err(UNVERIFIED));
    assert_eq!(x.containment, "unverified");
}

#[test]
fn the_recorded_refusal_is_reported_by_class() {
    let t = TempDir::new();
    let root = crate::run_record::tests::root_with_run(&t);
    crate::run_record::refusal_set(&root, "launch_refused").unwrap();
    let x = gather(&t.base(), false, None, &Tables(HashMap::new()), &nothing);
    assert_eq!(x.refusal, "launch_refused");
}

#[cfg(target_os = "linux")]
#[test]
fn a_tree_that_listens_is_reported_by_kind_and_a_silent_one_as_none() {
    use crate::sweep::tests::{detached, sleeper_at};
    let t = TempDir::new();
    let root = crate::run_record::tests::root_with_run(&t);
    // A stub playing the managed tree: a process whose executable is below a version directory.
    let dir = root.abs_path().join("pw-1/node/bin");
    let mut c = detached(&sleeper_at(&dir, "node"));
    let real = crate::procnet::Proc;
    let x = gather(&t.base(), false, None, &real, &nothing);
    assert_eq!(x.listeners, "none", "{x:?}");
    c.kill().unwrap();
    c.wait().unwrap();
    // A table that cannot be read is `unknown`, never `none`.
    let mut c = detached(&sleeper_at(&dir, "node2"));
    let x = gather(&t.base(), false, None, &Tables(HashMap::new()), &nothing);
    assert_eq!(x.listeners, "unknown");
    c.kill().unwrap();
    c.wait().unwrap();
}

fn tiers_all(v: Val) -> Tiers {
    Tiers {
        base: Some([v; 8]),
        mount: MountTier::Applied([v; 4]),
    }
}

fn mode_with(tiers: Tiers) -> Mode {
    Mode {
        name: "systemd+mount",
        mount_tier: true,
        tiers,
    }
}

#[test]
fn a_retry_fills_the_hardening_fields_from_what_the_probes_found() {
    let t = TempDir::new();
    let _root = crate::run_record::tests::root_with_run(&t);
    let none = Tables(HashMap::new());
    let x = gather(&t.base(), true, None, &none, &|| {
        Ok(mode_with(tiers_all(Val::One)))
    });
    assert_eq!(
        (
            x.hardening_base.as_str(),
            x.hardening_mount.as_str(),
            x.hardening_unverified.as_str(),
            x.run_records.as_str()
        ),
        ("verified", "verified", "none", "ok")
    );
    // One token not shown: partial, and the token is named from the fixed vocabulary.
    let mut tiers = tiers_all(Val::One);
    if let Some(b) = tiers.base.as_mut() {
        b[3] = Val::Na;
    }
    tiers.mount = MountTier::Dropped;
    let x = gather(&t.base(), true, None, &none, &|| Ok(mode_with(tiers)));
    assert_eq!(x.hardening_base, "partial");
    assert_eq!(x.hardening_mount, "dropped");
    assert_eq!(x.hardening_unverified, "memory_max");
    // A failed self-test or base probe: unverified, and nothing else is claimed.
    let x = gather(&t.base(), true, None, &none, &|| Err(UNVERIFIED));
    assert_eq!(x.hardening_base, "unverified");
    assert_eq!(x.hardening_mount, "unverified");
    assert_eq!(x.hardening_unverified, "unverified");
    // Without --retry the CLI never reports a tier it did not probe.
    let x = gather(&t.base(), false, None, &none, &nothing);
    assert_eq!(x.hardening_base, "not_checked");
}

#[test]
fn a_full_run_directory_is_named_in_the_status() {
    let t = TempDir::new();
    let root = crate::run_record::tests::root_with_run(&t);
    let none = Tables(HashMap::new());
    assert_eq!(
        gather(&t.base(), false, None, &none, &nothing).run_records,
        "ok"
    );
    let me = std::process::id();
    let start = crate::state::proc_start_time(me).unwrap();
    for i in 0..crate::run_record::MAX_RECORDS {
        std::fs::write(
            root.abs_path().join(format!("run/cli-{}.json", 1000 + i)),
            format!("{{\"pid\":{me},\"start\":{start},\"kind\":\"cli\"}}"),
        )
        .unwrap();
    }
    assert_eq!(
        gather(&t.base(), false, None, &none, &nothing).run_records,
        "full"
    );
}

#[test]
fn the_listeners_word_carries_the_v2_verdict() {
    use crate::procnet::{Listeners, TmpState};
    let w = |l: Listeners, t| listeners_word(Ok(l), t);
    assert_eq!(w(Listeners::default(), TmpState::Missing), "none");
    let two = Listeners {
        unix: 2,
        ..Default::default()
    };
    assert_eq!(
        w(two, TmpState::Ok),
        "tcp=0 udp=0 unix=2 unix_outside=0 tmpdir=ok result=pass"
    );
    let out = Listeners {
        unix: 2,
        unix_outside: 1,
        ..Default::default()
    };
    assert!(w(out, TmpState::Ok).ends_with("unix_outside=1 tmpdir=ok result=fail"));
    let all_out = Listeners {
        unix: 2,
        unix_outside: 2,
        ..Default::default()
    };
    assert_eq!(
        w(all_out, TmpState::Mode),
        "tcp=0 udp=0 unix=2 unix_outside=2 tmpdir=mode result=fail"
    );
    let tcp = Listeners {
        tcp: 1,
        ..Default::default()
    };
    assert!(w(tcp, TmpState::Ok).ends_with("result=fail"));
    assert_eq!(listeners_word(Err("x"), TmpState::Ok), "unknown");
}
