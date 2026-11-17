use super::*;
use crate::containment::{SYSTEMD, UNVERIFIED};
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
