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

mod paging {
    use super::*;

    const BAD: &str = "upstream_bad_body";
    const TMO: &str = "upstream_timeout";

    fn run(pages: Vec<Value>) -> (Result<Vec<Value>, &'static str>, Vec<Value>) {
        let mut sent = Vec::new();
        let mut it = pages.into_iter();
        let r = list_tools_paged(
            T,
            T,
            |p, _| {
                sent.push(p);
                it.next().ok_or("upstream_unreachable")
            },
            BAD,
            TMO,
        );
        (r, sent)
    }

    fn names(r: Result<Vec<Value>, &'static str>) -> Vec<String> {
        r.unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap().to_string())
            .collect()
    }

    #[test]
    fn follows_next_cursor_and_joins_pages_in_order() {
        let (r, sent) = run(vec![
            json!({"tools": [{"name": "a"}], "nextCursor": "c1"}),
            json!({"tools": [{"name": "b"}], "nextCursor": "c2"}),
            json!({"tools": [{"name": "c"}]}),
        ]);
        assert_eq!(names(r), ["a", "b", "c"]);
        assert_eq!(
            sent,
            vec![json!({}), json!({"cursor": "c1"}), json!({"cursor": "c2"})]
        );
    }

    #[test]
    fn null_absent_and_empty_string_cursors_end_the_list() {
        for end in [
            json!({}),
            json!({"nextCursor": null}),
            json!({"nextCursor": ""}),
        ] {
            let mut page = json!({"tools": [{"name": "a"}]});
            page.as_object_mut()
                .unwrap()
                .extend(end.as_object().unwrap().clone());
            let (r, sent) = run(vec![page]);
            assert_eq!(names(r), ["a"]);
            assert_eq!(sent.len(), 1, "no second request for {end}");
        }
    }

    #[test]
    fn an_empty_page_with_a_cursor_is_followed() {
        let (r, sent) = run(vec![
            json!({"tools": [], "nextCursor": "c1"}),
            json!({"tools": [{"name": "a"}]}),
        ]);
        assert_eq!(names(r), ["a"]);
        assert_eq!(sent.len(), 2);
    }

    #[test]
    fn a_cycle_or_non_string_cursor_fails_closed() {
        let (r, _) = run(vec![
            json!({"tools": [{"name": "a"}], "nextCursor": "x"}),
            json!({"tools": [], "nextCursor": "x"}),
        ]);
        assert_eq!(r, Err(BAD));
        for c in [json!(7), json!(true), json!({}), json!(["x"])] {
            let (r, _) = run(vec![json!({"tools": [], "nextCursor": c})]);
            assert_eq!(r, Err(BAD), "{c}");
        }
    }

    #[test]
    fn page_and_tool_bounds_fail_closed() {
        let pages = (0..=MAX_LIST_PAGES)
            .map(|i| json!({"tools": [], "nextCursor": format!("c{i}")}))
            .collect();
        let (r, sent) = run(pages);
        assert_eq!(r, Err(BAD));
        assert_eq!(sent.len(), MAX_LIST_PAGES);
        let big: Vec<Value> = (0..MAX_LIST_TOOLS + 1)
            .map(|i| json!({"name": i.to_string()}))
            .collect();
        assert_eq!(run(vec![json!({"tools": big})]).0, Err(BAD));
        // Exactly the cap is allowed; the cap counts raw entries across pages.
        let ok: Vec<Value> = (0..MAX_LIST_TOOLS)
            .map(|i| json!({"name": i.to_string()}))
            .collect();
        assert_eq!(
            run(vec![json!({"tools": ok})]).0.unwrap().len(),
            MAX_LIST_TOOLS
        );
        let half: Vec<Value> = (0..MAX_LIST_TOOLS / 2 + 1)
            .map(|_| json!({"name": "same"}))
            .collect();
        let (r, _) = run(vec![
            json!({"tools": half, "nextCursor": "c"}),
            json!({"tools": half}),
        ]);
        assert_eq!(r, Err(BAD), "duplicates count against the raw cap");
    }

    #[test]
    fn a_failing_later_page_drops_the_partial_list() {
        let (r, _) = run(vec![json!({"tools": [{"name": "a"}], "nextCursor": "c1"})]);
        assert_eq!(r, Err("upstream_unreachable"));
    }

    #[test]
    fn tools_are_deduplicated_by_name_first_wins_and_nameless_entries_stay() {
        let (r, _) = run(vec![
            json!({"tools": [{"name": "a", "v": 1}, {"x": 1}], "nextCursor": "c"}),
            json!({"tools": [{"name": "a", "v": 2}, {"name": "b"}, {"x": 1}, {"name": 5}]}),
        ]);
        assert_eq!(
            r.unwrap(),
            vec![
                json!({"name": "a", "v": 1}),
                json!({"x": 1}),
                json!({"name": "b"}),
                json!({"x": 1}),
                json!({"name": 5}),
            ]
        );
    }

    #[test]
    fn the_overall_deadline_bounds_the_walk_and_each_request() {
        let mut seen = Vec::new();
        let r = list_tools_paged(
            Duration::from_secs(10),
            Duration::from_millis(300),
            |_, t| {
                seen.push(t);
                std::thread::sleep(Duration::from_millis(200));
                Ok::<_, &str>(json!({"tools": [], "nextCursor": format!("c{}", seen.len())}))
            },
            BAD,
            TMO,
        );
        assert_eq!(r, Err(TMO));
        assert!(seen.iter().all(|t| *t <= Duration::from_millis(300)));
        assert!(seen.len() <= 2, "{seen:?}");
    }
}

mod served {
    //! The same rules over a real stdio child that plays a paging server.
    use super::*;

    /// A server whose `tools/list` answer is picked by the request cursor. `arms` are shell `case`
    /// arms over `$cur` that set `r` to the result, or to `ERR` for a JSON-RPC error.
    fn pager(arms: &str, t: &TempDir) -> (Child, Arc<Client>, PathBuf) {
        let log = t.path.join("lists.log");
        let script = format!(
            r#"LOG='{}'
n=0
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"tools/list"'*)
      echo x >> "$LOG"
      n=$((n+1))
      cur=$(printf '%s' "$line" | sed -n 's/.*"cursor":"\([^"]*\)".*/\1/p')
      case "$cur" in
{arms}
      esac
      if [ "$r" = ERR ]; then
        printf '{{"jsonrpc":"2.0","id":%s,"error":{{"code":-32000,"message":"no"}}}}\n' "$id"
      else
        printf '{{"jsonrpc":"2.0","id":%s,"result":%s}}\n' "$id" "$r"
      fi;;
  esac
done
"#,
            log.display()
        );
        let (c, cl) = stub(&script, t);
        (c, cl, log)
    }

    fn requests(log: &PathBuf) -> usize {
        std::fs::read_to_string(log).map_or(0, |s| s.lines().count())
    }

    fn names(v: Vec<Value>) -> Vec<String> {
        v.iter()
            .map(|t| t["name"].as_str().unwrap().to_string())
            .collect()
    }

    #[test]
    fn three_pages_are_joined_in_order() {
        let t = TempDir::new();
        let (mut child, c, log) = pager(
            r#"      "") r='{"tools":[{"name":"a"}],"nextCursor":"p2"}';;
      p2) r='{"tools":[{"name":"b"},{"name":"a"}],"nextCursor":"p3"}';;
      *) r='{"tools":[{"name":"c"}]}';;"#,
            &t,
        );
        assert_eq!(names(c.list_tools(T).unwrap()), ["a", "b", "c"]);
        assert_eq!(requests(&log), 3);
        c.close();
        child.stop();
    }

    #[test]
    fn a_single_page_is_unchanged_and_asks_once() {
        let t = TempDir::new();
        let (mut child, c, log) = pager(
            r#"      *) r='{"tools":[{"name":"a"},{"name":"b"}]}';;"#,
            &t,
        );
        assert_eq!(names(c.list_tools(T).unwrap()), ["a", "b"]);
        assert_eq!(requests(&log), 1);
        c.close();
        child.stop();
    }

    #[test]
    fn null_and_empty_string_cursors_end_the_list() {
        for end in ["null", r#""""#] {
            let t = TempDir::new();
            let arms = format!(r#"      *) r='{{"tools":[{{"name":"a"}}],"nextCursor":{end}}}';;"#);
            let (mut child, c, log) = pager(&arms, &t);
            assert_eq!(names(c.list_tools(T).unwrap()), ["a"], "{end}");
            assert_eq!(requests(&log), 1, "{end}");
            c.close();
            child.stop();
        }
    }

    #[test]
    fn an_empty_page_with_a_cursor_is_followed() {
        let t = TempDir::new();
        let (mut child, c, _) = pager(
            r#"      "") r='{"tools":[],"nextCursor":"p2"}';;
      *) r='{"tools":[{"name":"a"}]}';;"#,
            &t,
        );
        assert_eq!(names(c.list_tools(T).unwrap()), ["a"]);
        c.close();
        child.stop();
    }

    #[test]
    fn a_never_ending_cursor_stops_at_the_page_cap_and_the_client_stays_usable() {
        let t = TempDir::new();
        let (mut child, c, log) = pager(
            r#"      *) r="{\"tools\":[],\"nextCursor\":\"c$n\"}";;"#,
            &t,
        );
        assert_eq!(c.list_tools(T), Err(Class::BadBody));
        assert_eq!(requests(&log), MAX_LIST_PAGES);
        // A paging violation is the server's, not a broken pipe: the client is not dead.
        assert!(!c.is_dead());
        c.close();
        child.stop();
    }

    #[test]
    fn a_cursor_cycle_fails_closed() {
        let t = TempDir::new();
        let (mut child, c, log) = pager(
            r#"      "") r='{"tools":[{"name":"a"}],"nextCursor":"x"}';;
      *) r='{"tools":[{"name":"b"}],"nextCursor":"x"}';;"#,
            &t,
        );
        assert_eq!(c.list_tools(T), Err(Class::BadBody));
        assert_eq!(requests(&log), 2);
        assert!(!c.is_dead());
        c.close();
        child.stop();
    }

    #[test]
    fn a_failing_second_page_drops_the_first() {
        let t = TempDir::new();
        let (mut child, c, _) = pager(
            r#"      "") r='{"tools":[{"name":"a"}],"nextCursor":"p2"}';;
      *) r=ERR;;"#,
            &t,
        );
        assert_eq!(c.list_tools(T), Err(Class::RpcError));
        c.close();
        child.stop();
    }
}

#[cfg(target_os = "linux")]
mod managed_child {
    //! A server that pages wrongly is a bad body of the listing, not a crash of the child.
    use super::*;
    use crate::backend::{Managed, Upstream};
    use crate::child::tests::{sup, Fx};
    use crate::child::{Config, Supervisor};
    use crate::containment::Availability;
    use crate::containment::SYSTEMD;
    use std::sync::atomic::Ordering;

    fn node(arms: &str) -> String {
        format!(
            r#"#!/bin/sh
n=0
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"initialize"'*) printf '{{"jsonrpc":"2.0","id":%s,"result":{{"serverInfo":{{"name":"Playwright"}}}}}}\n' "$id";;
    *'"method":"ping"'*) printf '{{"jsonrpc":"2.0","id":%s,"result":{{}}}}\n' "$id";;
    *'"method":"tools/list"'*)
      n=$((n+1))
      cur=$(printf '%s' "$line" | sed -n 's/.*"cursor":"\([^"]*\)".*/\1/p')
      case "$cur" in
{arms}
      esac
      printf '{{"jsonrpc":"2.0","id":%s,"result":%s}}\n' "$id" "$r";;
  esac
done
"#
        )
    }

    /// The fixture's "node", rewritten with write, fsync and close before anything execs it (#147).
    fn fixture(arms: &str) -> Fx {
        let fx = Fx::new(&node(arms));
        let exe = fx.root().abs_path().join("pw-1/node/bin/node");
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .truncate(true)
            .open(&exe)
            .unwrap();
        f.write_all(node(arms).as_bytes()).unwrap();
        f.sync_all().unwrap();
        drop(f);
        fx
    }

    fn managed(fx: &Fx) -> (Arc<Managed>, crate::child::tests::Sup) {
        let s = sup(fx, Ok(SYSTEMD));
        let sup2 = Arc::new(Supervisor::new(
            {
                let mut c = Config::production(fx.t.base());
                c.seat = Arc::new(|| None);
                c
            },
            Arc::new(Availability::new(s.mech.clone())),
        ));
        (Arc::new(Managed::new(sup2)), s)
    }

    fn listed(m: &Managed) -> Vec<String> {
        m.tools()
            .iter()
            .map(|t| t["name"].as_str().unwrap().to_string())
            .collect()
    }

    #[test]
    fn a_paged_catalog_is_listed_across_pages() {
        let fx = fixture(
            r#"      "") r='{"tools":[{"name":"extra_tool"}],"nextCursor":"p2"}';;
      *) r='{"tools":[{"name":"browser_navigate"},{"name":"browser_navigate"}]}';;"#,
        );
        let (m, s) = managed(&fx);
        assert_eq!(listed(&m), ["browser_navigate"]);
        assert_eq!(s.mech.spawned.load(Ordering::SeqCst), 1);
        m.supervisor().stop();
    }

    #[test]
    fn a_cursor_cycle_lists_nothing_and_leaves_the_child_running() {
        let fx = fixture(
            r#"      "") r='{"tools":[{"name":"browser_navigate"}],"nextCursor":"x"}';;
      *) r='{"tools":[],"nextCursor":"x"}';;"#,
        );
        let (m, s) = managed(&fx);
        assert!(listed(&m).is_empty(), "no truncated list");
        assert!(m.supervisor().is_running(), "a paging error is not a crash");
        assert_eq!(s.mech.spawned.load(Ordering::SeqCst), 1, "no restart");
        assert!(m.supervisor().call("ping", json!({}), T).is_ok());
        m.supervisor().stop();
    }
}
