use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime};

use serde_json::{json, Value};

use super::tools::call_on;
use super::*;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("oab-jobs-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

fn reg(name: &str) -> Registry {
    Registry::open(scratch(name)).unwrap()
}

fn call(reg: &Registry, name: &str, args: Value) -> Value {
    call_on(reg, name, &args).unwrap()
}

fn sc(v: &Value) -> &Value {
    &v["structuredContent"]
}

fn start(reg: &Registry, args: Value) -> String {
    let r = call(reg, "exec_start", args);
    assert_eq!(sc(&r)["state"], "running", "{r}");
    sc(&r)["job_id"].as_str().unwrap().to_string()
}

fn poll(reg: &Registry, id: &str, out_since: u64, err_since: u64) -> Value {
    call(
        reg,
        "exec_poll",
        json!({"job_id": id, "stdout_since": out_since, "stderr_since": err_since}),
    )
}

/// Poll from offset 0 until `done` holds (10 s at most).
fn poll_until(reg: &Registry, id: &str, done: impl Fn(&Value) -> bool) -> Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let p = poll(reg, id, 0, 0);
        if done(sc(&p)) {
            return p;
        }
        assert!(Instant::now() < deadline, "timed out waiting: {p}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn terminal(reg: &Registry, id: &str) -> Value {
    poll_until(reg, id, |s| s["state"] != "running")
}

/// Alive and not a zombie.
fn alive(pid: u32) -> bool {
    std::fs::read_to_string(format!("/proc/{pid}/stat"))
        .map(|s| {
            let state = s.rsplit(')').next().unwrap_or("").trim_start();
            !state.starts_with('Z')
        })
        .unwrap_or(false)
}

#[test]
fn start_then_poll_by_offset_until_exit() {
    let reg = reg("offsets");
    let id = start(
        &reg,
        json!({"command": "printf 'a\\n'; sleep 0.5; printf 'b\\n'; echo \"$FOO $(pwd)\" >&2; exit 3",
               "cwd": "~", "env": {"FOO": "bar"}}),
    );
    assert!(id.starts_with("job-") && id.len() == 40, "{id}");

    let first = poll_until(&reg, &id, |s| s["stdout"] == "a\n");
    assert_eq!(sc(&first)["state"], "running", "{first}");
    let out_next = sc(&first)["stdout_next"].as_u64().unwrap();
    assert_eq!(out_next, 2);

    terminal(&reg, &id);
    let rest = poll(&reg, &id, out_next, 0);
    let s = sc(&rest);
    assert_eq!(s["stdout"], "b\n", "only the new bytes: {rest}");
    assert_eq!(s["stdout_next"], 4);
    let home = std::env::var("HOME").unwrap();
    assert_eq!(s["stderr"], format!("bar {home}\n"));
    assert_eq!(s["state"], "exited");
    assert_eq!(s["exit_code"], 3);
    assert!(s["out_path"]
        .as_str()
        .unwrap()
        .ends_with(&format!("{id}.out")));
    assert!(rest["content"][0]["text"]
        .as_str()
        .unwrap()
        .ends_with("[exited exit 3]"));

    // At the end: nothing new, same offset.
    let again = poll(&reg, &id, 4, s["stderr_next"].as_u64().unwrap());
    assert_eq!(sc(&again)["stdout"], "");
    assert_eq!(sc(&again)["stderr"], "");
    assert_eq!(sc(&again)["stdout_next"], 4);
}

/// The acceptance case of #32 item 4: a 30 s job, two polls with offsets,
/// cancel, one more poll → `killed` with an exit code; and the whole process
/// group is gone, a backgrounded child included.
#[test]
fn cancel_kills_the_whole_process_group() {
    let reg = reg("cancel");
    let id = start(
        &reg,
        json!({"command": "sleep 30 & echo $!; for i in $(seq 1 30); do echo tick $i; sleep 1; done",
               "timeout_secs": 0}),
    );
    let p1 = poll_until(&reg, &id, |s| {
        s["stdout"].as_str().unwrap().contains("tick 1")
    });
    let grandchild: u32 = sc(&p1)["stdout"]
        .as_str()
        .unwrap()
        .lines()
        .next()
        .unwrap()
        .parse()
        .unwrap();
    assert!(alive(grandchild));
    let next = sc(&p1)["stdout_next"].as_u64().unwrap();
    std::thread::sleep(Duration::from_millis(1200));
    let p2 = poll(&reg, &id, next, 0);
    assert_eq!(sc(&p2)["state"], "running");
    assert!(
        sc(&p2)["stdout"].as_str().unwrap().contains("tick 2"),
        "{p2}"
    );
    assert!(!sc(&p2)["stdout"].as_str().unwrap().contains("tick 1"));

    let c = call(&reg, "exec_cancel", json!({"job_id": id}));
    assert_eq!(sc(&c)["signalled"], true, "{c}");
    let done = terminal(&reg, &id);
    assert_eq!(sc(&done)["state"], "killed", "{done}");
    assert_eq!(sc(&done)["exit_code"], 137);

    let deadline = Instant::now() + Duration::from_secs(5);
    while alive(grandchild) {
        assert!(Instant::now() < deadline, "backgrounded child survived");
        std::thread::sleep(Duration::from_millis(50));
    }

    // Cancelling a finished job drops it; it is then unknown.
    let dropped = call(&reg, "exec_cancel", json!({"job_id": id}));
    assert_eq!(sc(&dropped)["dropped"], true, "{dropped}");
    let gone = call(&reg, "exec_poll", json!({"job_id": id}));
    assert_eq!(gone["isError"], true, "{gone}");
    // The log files stay.
    assert!(reg.dir().join(format!("{id}.out")).exists());
}

#[test]
fn term_lets_the_job_clean_up() {
    let reg = reg("term");
    let id = start(
        &reg,
        json!({"command": "trap 'echo bye; exit 0' TERM; echo ready; while :; do sleep 0.1; done"}),
    );
    poll_until(&reg, &id, |s| s["stdout"] == "ready\n");
    let c = call(&reg, "exec_cancel", json!({"job_id": id, "signal": "TERM"}));
    assert_eq!(sc(&c)["signalled"], true, "{c}");
    let done = terminal(&reg, &id);
    assert_eq!(sc(&done)["stdout"], "ready\nbye\n", "{done}");
    assert_eq!(sc(&done)["state"], "exited");
    assert_eq!(sc(&done)["exit_code"], 0);
}

#[test]
fn timeout_kills_and_reports_killed() {
    let reg = reg("timeout");
    let started = Instant::now();
    let id = start(&reg, json!({"command": "sleep 30", "timeout_secs": 0.3}));
    let done = terminal(&reg, &id);
    assert!(started.elapsed() < Duration::from_secs(5));
    assert_eq!(sc(&done)["state"], "killed", "{done}");
    assert_eq!(sc(&done)["exit_code"], 137);
}

#[test]
fn list_shows_running_first_and_keeps_ten_finished() {
    let reg = reg("list");
    let mut finished = Vec::new();
    for i in 0..(KEEP_FINISHED + 2) {
        let id = start(&reg, json!({"command": format!("echo {i}")}));
        terminal(&reg, &id);
        finished.push(id);
    }
    let running = start(&reg, json!({"command": "sleep 30"}));

    let l = call(&reg, "exec_list", json!({}));
    let jobs = sc(&l)["jobs"].as_array().unwrap();
    assert_eq!(jobs.len(), KEEP_FINISHED + 1, "{l}");
    assert_eq!(jobs[0]["job_id"], running.as_str());
    assert_eq!(jobs[0]["state"], "running");
    assert!(jobs[0].get("exit_code").is_none());
    assert!(jobs[0].get("finished_at").is_none());
    let newest = &jobs[1];
    assert_eq!(newest["job_id"], finished.last().unwrap().as_str());
    assert_eq!(newest["state"], "exited");
    assert_eq!(newest["exit_code"], 0);
    assert_eq!(newest["stdout_bytes"], 3);
    assert_eq!(newest["stderr_bytes"], 0);
    let started_at = newest["started_at"].as_str().unwrap();
    assert!(
        started_at.len() == 20 && started_at.ends_with('Z'),
        "{started_at}"
    );
    assert!(newest["finished_at"].is_string());
    assert!(l["content"][0]["text"]
        .as_str()
        .unwrap()
        .ends_with(&format!("[1 running, {KEEP_FINISHED} recent finished]")));

    // The two oldest finished jobs were dropped.
    for id in &finished[..2] {
        let p = call(&reg, "exec_poll", json!({"job_id": id}));
        assert_eq!(p["isError"], true, "{p}");
    }
    call(&reg, "exec_cancel", json!({"job_id": running}));
    terminal(&reg, &running);
}

#[test]
fn old_job_logs_are_collected_and_others_kept() {
    let dir = scratch("gc");
    std::fs::create_dir_all(&dir).unwrap();
    let week_ago = SystemTime::now() - LOG_MAX_AGE - Duration::from_secs(3600);
    let touch = |name: &str, mtime: SystemTime| {
        let f = std::fs::File::create(dir.join(name)).unwrap();
        f.set_modified(mtime).unwrap();
    };
    touch("job-old.out", week_ago);
    touch("job-old.err", week_ago);
    touch("job-new.out", SystemTime::now());
    touch("notes.out", week_ago); // not a job log: never ours to delete
    let reg = Registry::open(dir.clone()).unwrap(); // GC on open
    assert!(!dir.join("job-old.out").exists());
    assert!(!dir.join("job-old.err").exists());
    assert!(dir.join("job-new.out").exists());
    assert!(dir.join("notes.out").exists());

    // A job still in the registry keeps its files whatever their age.
    let id = start(&reg, json!({"command": "sleep 30"}));
    let out = dir.join(format!("{id}.out"));
    std::fs::File::options()
        .append(true)
        .open(&out)
        .unwrap()
        .set_modified(week_ago)
        .unwrap();
    assert_eq!(reg.gc_logs(SystemTime::now()), 0);
    assert!(out.exists());
    // Eight days on, the new file goes too.
    assert_eq!(
        reg.gc_logs(SystemTime::now() + LOG_MAX_AGE + Duration::from_secs(86_400)),
        1
    );
    call(&reg, "exec_cancel", json!({"job_id": id}));
    terminal(&reg, &id);
}

#[test]
fn log_directory_and_files_are_owner_only() {
    let dir = scratch("perms");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
    let reg = Registry::open(dir.clone()).unwrap();
    let mode = |p: &std::path::Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&dir), 0o700, "a widened directory is narrowed");
    let id = start(&reg, json!({"command": "true"}));
    terminal(&reg, &id);
    assert_eq!(mode(&dir.join(format!("{id}.out"))), 0o600);
    assert_eq!(mode(&dir.join(format!("{id}.err"))), 0o600);
}

#[test]
fn bad_arguments_are_reported() {
    let reg = reg("args");
    let code = |name: &str, args: Value| call_on(&reg, name, &args).unwrap_err().0;
    assert_eq!(code("exec_start", json!({})), -32602);
    assert_eq!(code("exec_start", json!({"command": ""})), -32602);
    assert_eq!(
        code(
            "exec_start",
            json!({"command": "true", "env": {"A=B": "x"}})
        ),
        -32602
    );
    assert_eq!(code("exec_poll", json!({})), -32602);
    assert_eq!(code("exec_cancel", json!({})), -32602);
    assert_eq!(
        code("exec_cancel", json!({"job_id": "job-x", "signal": "INT"})),
        -32602
    );

    let bad_cwd = call(
        &reg,
        "exec_start",
        json!({"command": "true", "cwd": "/nonexistent/dir"}),
    );
    assert_eq!(bad_cwd["isError"], true, "{bad_cwd}");
    let unknown = call(&reg, "exec_poll", json!({"job_id": "job-nope"}));
    assert_eq!(unknown["isError"], true);
    assert!(unknown["content"][0]["text"]
        .as_str()
        .unwrap()
        .contains(reg.dir().to_str().unwrap()));
    let unknown = call(&reg, "exec_cancel", json!({"job_id": "job-nope"}));
    assert_eq!(unknown["isError"], true);
    let empty = call(&reg, "exec_list", json!({}));
    assert_eq!(empty["content"][0]["text"], "no jobs");
}

#[test]
fn a_cut_off_utf8_sequence_waits_for_the_next_read() {
    assert_eq!(incomplete_utf8_tail(b"ab"), 0);
    assert_eq!(incomplete_utf8_tail("你".as_bytes()), 0);
    assert_eq!(incomplete_utf8_tail(&"你".as_bytes()[..2]), 2);
    assert_eq!(incomplete_utf8_tail(&"a你".as_bytes()[..2]), 1);

    let dir = scratch("utf8");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("job-x.out");
    let mut bytes = b"ok ".to_vec();
    bytes.extend_from_slice(&"你".as_bytes()[..2]);
    std::fs::write(&path, &bytes).unwrap();
    assert_eq!(read_log(&path, 0, true), (b"ok ".to_vec(), 3));
    // A finished job's file is returned as it is.
    assert_eq!(read_log(&path, 0, false), (bytes.clone(), 5));
    // Past the end: nothing, and the size.
    assert_eq!(read_log(&path, 99, true), (Vec::new(), 5));
}

#[test]
fn iso8601_matches_known_instants() {
    let at = |s: u64| iso8601(SystemTime::UNIX_EPOCH + Duration::from_secs(s));
    assert_eq!(at(0), "1970-01-01T00:00:00Z");
    assert_eq!(at(951_782_400), "2000-02-29T00:00:00Z");
    assert_eq!(at(1_793_017_845), "2026-10-26T12:30:45Z");
}

/// Unlike an in-flight call (#72), a job started over a reverse attach keeps
/// running after that socket ends, and the next attach can still poll it.
#[test]
fn a_job_survives_the_attach_that_started_it() {
    use crate::mcp::{answer, answer_attached};
    let rpc = |id: u64, name: &str, args: Value| {
        json!({"jsonrpc": "2.0", "id": id, "method": "tools/call",
               "params": {"name": name, "arguments": args}})
        .to_string()
    };
    let parse = |s: Option<String>| serde_json::from_str::<Value>(&s.unwrap()).unwrap();
    let socket_gone = AtomicBool::new(false);
    let started = parse(answer_attached(
        &rpc(1, "exec_start", json!({"command": "sleep 30"})),
        "owner",
        &socket_gone,
    ));
    let id = started["result"]["structuredContent"]["job_id"]
        .as_str()
        .unwrap()
        .to_string();
    socket_gone.store(true, Ordering::Release); // what a dropped attach does
    std::thread::sleep(Duration::from_millis(300));

    let next_attach = AtomicBool::new(false);
    let polled = parse(answer_attached(
        &rpc(2, "exec_poll", json!({"job_id": id})),
        "owner",
        &next_attach,
    ));
    assert_eq!(
        polled["result"]["structuredContent"]["state"], "running",
        "{polled}"
    );
    parse(answer(
        &rpc(3, "exec_cancel", json!({"job_id": id})),
        "owner",
    ));
}
