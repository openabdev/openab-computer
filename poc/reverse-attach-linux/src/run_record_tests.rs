use super::*;
use crate::state::tests::TempDir;
use crate::state::{create_dir_at, write_new_file, MARKER_TEXT};
use std::os::unix::fs::symlink;
use std::process::{Command, Stdio};

/// A root whose `run/` exists with its marker.
pub(crate) fn root_with_run(t: &TempDir) -> Root {
    let root = t.root();
    let run = create_dir_at(root.fd(), "run").unwrap();
    write_new_file(&run, OWNED_DATA, MARKER_TEXT, 0o600).unwrap();
    root
}

fn sleeper() -> std::process::Child {
    Command::new("sleep")
        .arg("30")
        .stdout(Stdio::null())
        .spawn()
        .unwrap()
}

fn run_dir(t: &TempDir) -> std::path::PathBuf {
    t.base().join("oab-computer/playwright/run")
}

#[test]
fn a_record_names_a_live_process_and_goes_with_its_handle() {
    let t = TempDir::new();
    let root = root_with_run(&t);
    let mut c = sleeper();
    let h = write(&root, "managed", c.id(), Some("oab-browser-ab.service")).unwrap();
    let live = live(&root);
    assert_eq!(live.len(), 1);
    assert_eq!(live[0].pid, c.id());
    assert_eq!(live[0].kind, "managed");
    assert_eq!(live[0].unit.as_deref(), Some("oab-browser-ab.service"));
    assert_eq!(
        crate::state::live_run_records(&root),
        1,
        "state.rs reads it too"
    );
    let name = h.name().to_string();
    drop(h);
    assert!(!run_dir(&t).join(name).exists());
    assert!(live_after(&root).is_empty());
    c.kill().unwrap();
    c.wait().unwrap();
}

fn live_after(root: &Root) -> Vec<Record> {
    live(root)
}

#[test]
fn a_record_holds_no_text_but_pid_start_kind_and_unit() {
    let t = TempDir::new();
    let root = root_with_run(&t);
    let mut c = sleeper();
    let h = write(&root, "cli", c.id(), None).unwrap();
    let text = std::fs::read_to_string(run_dir(&t).join(h.name())).unwrap();
    let v: Value = serde_json::from_str(&text).unwrap();
    let mut keys: Vec<&String> = v.as_object().unwrap().keys().collect();
    keys.sort();
    assert_eq!(keys, ["kind", "pid", "start", "unit"]);
    assert!(text.len() < 200);
    use std::os::unix::fs::PermissionsExt;
    let mode = std::fs::metadata(run_dir(&t).join(h.name()))
        .unwrap()
        .permissions()
        .mode();
    assert_eq!(mode & 0o777, 0o600);
    drop(h);
    c.kill().unwrap();
    c.wait().unwrap();
}

#[test]
fn dead_records_are_pruned_on_the_next_write_and_report_their_unit() {
    let t = TempDir::new();
    let root = root_with_run(&t);
    let mut c = sleeper();
    let h = write(&root, "managed", c.id(), Some("oab-browser-dead.service")).unwrap();
    std::mem::forget(h); // the record outlives its handle, as after a SIGKILL
    c.kill().unwrap();
    c.wait().unwrap();
    assert!(live(&root).is_empty());
    let gone = prune_dead(&root);
    assert_eq!(gone.len(), 1);
    assert_eq!(gone[0].1.as_deref(), Some("oab-browser-dead.service"));
    assert!(std::fs::read_dir(run_dir(&t))
        .unwrap()
        .flatten()
        .all(|e| !e.file_name().to_string_lossy().ends_with(".json")));
}

#[test]
fn the_number_of_records_is_bounded() {
    let t = TempDir::new();
    let root = root_with_run(&t);
    let me = std::process::id();
    let start = crate::state::proc_start_time(me).unwrap();
    // 64 live-looking records (they name this process under different file names).
    for i in 0..MAX_RECORDS {
        std::fs::write(
            run_dir(&t).join(format!("cli-{}.json", 1000 + i)),
            json!({"pid": me, "start": start, "kind": "cli", "unit": null}).to_string(),
        )
        .unwrap();
    }
    let mut c = sleeper();
    assert_eq!(
        write(&root, "cli", c.id(), None).err(),
        Some(Fail("run_records_full"))
    );
    c.kill().unwrap();
    c.wait().unwrap();
}

#[test]
fn an_oversize_or_garbage_record_is_not_read() {
    let t = TempDir::new();
    let root = root_with_run(&t);
    let me = std::process::id();
    let start = crate::state::proc_start_time(me).unwrap();
    let big = format!(
        "{{\"pid\":{me},\"start\":{start},\"pad\":\"{}\"}}",
        "x".repeat(5000)
    );
    std::fs::write(run_dir(&t).join("cli-1.json"), big).unwrap();
    std::fs::write(run_dir(&t).join("cli-2.json"), "garbage").unwrap();
    std::fs::write(run_dir(&t).join("cli-3.json"), r#"{"pid":0,"start":1}"#).unwrap();
    assert!(live(&root).is_empty());
}

#[test]
fn without_the_marker_nothing_is_written_or_read() {
    let t = TempDir::new();
    let root = t.root();
    create_dir_at(root.fd(), "run").unwrap();
    let mut c = sleeper();
    assert_eq!(
        write(&root, "managed", c.id(), None).err(),
        Some(Fail("run_dir_unmarked"))
    );
    assert!(std::fs::read_dir(run_dir(&t)).unwrap().next().is_none());
    c.kill().unwrap();
    c.wait().unwrap();
}

#[test]
fn a_symlinked_run_directory_stops_the_write() {
    let t = TempDir::new();
    let root = t.root();
    let (outside, sentinel) = t.sentinel();
    symlink(&outside, run_dir(&t)).unwrap();
    let mut c = sleeper();
    assert!(write(&root, "managed", c.id(), None).is_err());
    assert_eq!(std::fs::read_dir(&outside).unwrap().count(), 1);
    crate::state::tests::assert_sentinel(&sentinel);
    c.kill().unwrap();
    c.wait().unwrap();
}

#[test]
fn bad_kinds_pids_and_unit_names_are_refused() {
    let t = TempDir::new();
    let root = root_with_run(&t);
    let me = std::process::id();
    for (kind, pid, unit) in [
        ("other", me, None),
        ("managed", 0, None),
        ("managed", me, Some("-x.service")),
        ("managed", me, Some("a b.service")),
        ("managed", me, Some("x.socket")),
        ("managed", me, Some("../x.service")),
    ] {
        assert_eq!(
            write(&root, kind, pid, unit).err(),
            Some(Fail("run_record_invalid")),
            "{kind} {pid} {unit:?}"
        );
    }
    assert!(is_unit_name("oab-browser-0a1b.service"));
    assert!(!is_unit_name("x"));
}

#[test]
fn the_latch_is_a_file_that_another_process_can_clear() {
    let t = TempDir::new();
    let root = root_with_run(&t);
    assert!(!latch_is_set(&root));
    latch_set(&root).unwrap();
    latch_set(&root).unwrap();
    assert!(latch_is_set(&root));
    assert!(live(&root).is_empty(), "the latch is not a run record");
    assert!(latch_clear(&root));
    assert!(!latch_is_set(&root));
    assert!(!latch_clear(&root));
}

#[test]
fn a_refusal_is_one_of_two_classes_and_is_not_a_run_record() {
    let t = TempDir::new();
    let root = root_with_run(&t);
    assert_eq!(refusal_get(&root), None);
    assert_eq!(
        refusal_set(&root, "anything else").err(),
        Some(Fail("run_record_invalid"))
    );
    refusal_set(&root, "launch_refused").unwrap();
    assert_eq!(refusal_get(&root).as_deref(), Some("launch_refused"));
    refusal_set(&root, "sandbox_unavailable").unwrap();
    assert_eq!(refusal_get(&root).as_deref(), Some("sandbox_unavailable"));
    assert!(live(&root).is_empty());
    assert_eq!(crate::state::live_run_records(&root), 0);
    let text = std::fs::read_to_string(run_dir(&t).join(REFUSAL_NAME)).unwrap();
    assert!(text.len() < 100, "{text}");
}

#[test]
fn unparsable_files_count_toward_the_cap_and_a_flood_fails_closed() {
    let t = TempDir::new();
    let root = root_with_run(&t);
    // Garbage that comes first in any listing cannot push real records out of view.
    for i in 0..MAX_RECORDS {
        std::fs::write(run_dir(&t).join(format!("a-{i}.json")), b"not json").unwrap();
    }
    assert!(saturated(&root));
    let mut c = sleeper();
    assert_eq!(
        write(&root, "cli", c.id(), None).err(),
        Some(Fail("run_records_full"))
    );
    c.kill().unwrap();
    c.wait().unwrap();
}

#[test]
fn more_entries_than_the_scan_limit_is_saturated_even_without_json_names() {
    let t = TempDir::new();
    let root = root_with_run(&t);
    assert!(!saturated(&root));
    for i in 0..(SCAN_LIMIT + 8) {
        std::fs::write(run_dir(&t).join(format!("x{i}")), b"").unwrap();
    }
    assert!(saturated(&root));
}
