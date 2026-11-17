use super::*;
use crate::proc::{Child, Spec};
use crate::state::tests::TempDir;
use std::path::PathBuf;

/// A shell stub playing the server. Starts a real `Child`, so the 8 MiB line cap, the stderr ring
/// and the pipes are the production ones.
fn stub(script: &str, t: &TempDir) -> (Child, Arc<Client>) {
    let spec = Spec {
        exe: PathBuf::from("/bin/sh"),
        args: vec!["-c".into(), script.into()],
        env: vec![("PATH".into(), "/usr/bin:/bin".into())],
        cwd: t.path.clone(),
    };
    let mut child = Child::spawn(&spec, true, true, MAX_LINE, &t.path).unwrap();
    let stdin = child.stdin.take().unwrap();
    let lines = child.lines.take().unwrap();
    let c = Client::start(Box::new(stdin), lines);
    (child, c)
}

/// Answers every request with `{"ok":true}` and logs every frame to `$1`.
const ECHO: &str = r#"
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$LOG"
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
  [ -n "$id" ] && printf '{"jsonrpc":"2.0","id":%s,"result":{"ok":true}}\n' "$id"
done
"#;

fn echo(t: &TempDir) -> (Child, Arc<Client>, PathBuf) {
    let log = t.path.join("frames.log");
    let script = format!("LOG='{}'\n{ECHO}", log.display());
    let (c, cl) = stub(&script, t);
    (c, cl, log)
}

const T: Duration = Duration::from_secs(5);

#[test]
fn a_call_gets_its_result_and_ping_answers() {
    let t = TempDir::new();
    let (mut child, c, _) = echo(&t);
    assert_eq!(
        c.call("tools/list", json!({}), T).unwrap(),
        json!({"ok": true})
    );
    assert!(c.ping(Duration::from_secs(2)));
    c.close();
    child.stop();
}

#[test]
fn concurrent_calls_are_matched_to_their_ids() {
    let t = TempDir::new();
    let (mut child, c, _) = echo(&t);
    let handles: Vec<_> = (0..12)
        .map(|i| {
            let c = Arc::clone(&c);
            std::thread::spawn(move || c.call("tools/call", json!({"i": i}), T))
        })
        .collect();
    for h in handles {
        assert_eq!(h.join().unwrap().unwrap(), json!({"ok": true}));
    }
    c.close();
    child.stop();
}

#[test]
fn a_response_split_across_writes_is_one_line() {
    let t = TempDir::new();
    let script = r#"
IFS= read -r line
id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
printf '{"jsonrpc":"2.0","id":%s,' "$id"
sleep 0.3
printf '"result":{"split":true}}\n'
sleep 5
"#;
    let (mut child, c) = stub(script, &t);
    assert_eq!(c.call("x", json!({}), T).unwrap(), json!({"split": true}));
    c.close();
    child.stop();
}

#[test]
fn a_line_over_8_mib_ends_the_client_with_a_fixed_class() {
    let t = TempDir::new();
    let script = r#"
IFS= read -r line
head -c 9000000 /dev/zero | tr '\0' 'a'
echo
sleep 5
"#;
    let (mut child, c) = stub(script, &t);
    assert_eq!(c.call("x", json!({}), T), Err(Class::BadBody));
    assert!(c.is_dead());
    assert_eq!(c.call("y", json!({}), T), Err(Class::Unreachable));
    child.stop();
}

#[test]
fn a_child_that_exits_mid_call_is_upstream_unreachable() {
    let t = TempDir::new();
    let (mut child, c) = stub("IFS= read -r line; exit 3", &t);
    assert_eq!(c.call("x", json!({}), T), Err(Class::Unreachable));
    assert!(c.is_dead());
    assert_eq!(c.call("y", json!({}), T), Err(Class::Unreachable));
    child.stop();
}

#[test]
fn a_timeout_sends_cancelled_for_that_id_and_a_late_answer_is_dropped() {
    let t = TempDir::new();
    let log = t.path.join("frames.log");
    let script = format!(
        "LOG='{}'\nIFS= read -r a; printf '%s\\n' \"$a\" >> \"$LOG\"\nIFS= read -r b; printf '%s\\n' \"$b\" >> \"$LOG\"\nsleep 5",
        log.display()
    );
    let (mut child, c) = stub(&script, &t);
    assert_eq!(
        c.call("tools/call", json!({}), Duration::from_millis(300)),
        Err(Class::Timeout)
    );
    let end = Instant::now() + T;
    let mut text = String::new();
    while Instant::now() < end {
        text = std::fs::read_to_string(&log).unwrap_or_default();
        if text.lines().count() >= 2 {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let frames: Vec<Value> = text
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert_eq!(frames[0]["method"], "tools/call");
    assert_eq!(frames[1]["method"], "notifications/cancelled");
    assert_eq!(frames[1]["params"]["requestId"], frames[0]["id"]);
    assert!(frames[1].get("id").is_none(), "a notification has no id");
    c.close();
    child.stop();
}

#[test]
fn an_error_answer_is_a_class_with_no_text() {
    let t = TempDir::new();
    let canary = "CANARY-SECRET-7f3a";
    let script = format!(
        r#"IFS= read -r line
id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
printf '{{"jsonrpc":"2.0","id":%s,"error":{{"code":-1,"message":"{canary}"}}}}\n' "$id"
sleep 5"#
    );
    let (mut child, c) = stub(&script, &t);
    let r = c.call("x", json!({}), T);
    assert_eq!(r, Err(Class::RpcError));
    assert!(!format!("{r:?} {}", Class::RpcError.name()).contains(canary));
    c.close();
    child.stop();
}

#[test]
fn stdout_and_stderr_are_never_mixed_and_stderr_text_never_leaves() {
    let t = TempDir::new();
    let canary = "CANARY-STDERR-91bc";
    let script = format!(
        r#"echo {canary} >&2
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
  echo "{canary} not json on stderr" >&2
  printf '{{"jsonrpc":"2.0","id":%s,"result":{{"fine":1}}}}\n' "$id"
done"#
    );
    let (mut child, c) = stub(&script, &t);
    assert_eq!(c.call("x", json!({}), T).unwrap(), json!({"fine": 1}));
    // The text is in the child's own ring (for the yes/no class) and nowhere else.
    std::thread::sleep(Duration::from_millis(100));
    assert!(child.stderr_contains_any(&["canary-stderr"]));
    c.close();
    child.stop();
    // The failure path: an exit gives a class that carries none of it.
    let (mut child2, c2) = stub(&format!("echo {canary} >&2; exit 1"), &t);
    let r = c2.call("x", json!({}), T);
    assert_eq!(r, Err(Class::Unreachable));
    assert!(!format!("{r:?}").contains(canary));
    child2.stop();
}

#[test]
fn a_server_request_gets_an_answer_and_a_notification_is_ignored() {
    let t = TempDir::new();
    let log = t.path.join("frames.log");
    let script = format!(
        r#"LOG='{}'
printf '{{"jsonrpc":"2.0","method":"notifications/message","params":{{}}}}\n'
printf '{{"jsonrpc":"2.0","id":"s1","method":"ping"}}\n'
printf '{{"jsonrpc":"2.0","id":"s2","method":"roots/list"}}\n'
while IFS= read -r line; do printf '%s\n' "$line" >> "$LOG"; done"#,
        log.display()
    );
    let (mut child, c) = stub(&script, &t);
    let end = Instant::now() + T;
    let mut text = String::new();
    while Instant::now() < end {
        text = std::fs::read_to_string(&log).unwrap_or_default();
        if text.lines().count() >= 2 {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let frames: Vec<Value> = text
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert_eq!(frames[0]["id"], "s1");
    assert_eq!(frames[0]["result"], json!({}));
    assert_eq!(frames[1]["id"], "s2");
    assert_eq!(frames[1]["error"]["code"], -32601);
    c.close();
    child.stop();
}

#[test]
fn closing_the_client_closes_the_childs_stdin() {
    let t = TempDir::new();
    // The child exits when its stdin reaches EOF.
    let (mut child, c) = stub("cat >/dev/null; exit 0", &t);
    c.close();
    let end = Instant::now() + T;
    while Instant::now() < end && !child.has_exited() {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(child.has_exited(), "stdin EOF did not reach the child");
    child.stop();
}

#[test]
fn the_number_of_calls_in_flight_is_bounded() {
    let t = TempDir::new();
    let (mut child, c) = stub("sleep 30", &t);
    let mut handles = Vec::new();
    for _ in 0..MAX_PENDING {
        let c = Arc::clone(&c);
        handles.push(std::thread::spawn(move || {
            c.call("x", json!({}), Duration::from_secs(3))
        }));
    }
    let end = Instant::now() + T;
    while Instant::now() < end && c.pending.lock().unwrap().len() < MAX_PENDING {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(c.call("one-more", json!({}), T), Err(Class::Busy));
    c.close();
    for h in handles {
        let _ = h.join();
    }
    child.stop();
}
