use super::*;
use crate::state::tests::TempDir;
use std::path::PathBuf;

fn tools_json(skip_last: bool) -> String {
    let n = if skip_last { 31 } else { 32 };
    let items: Vec<String> = BROWSER_TOOLS[..n]
        .iter()
        .map(|t| format!("{{\"name\":\"{t}\"}}"))
        .collect();
    format!("[{}]", items.join(","))
}

/// A stub MCP server in sh. `pre` runs before the loop; `name` is the serverInfo name.
fn server(pre: &str, name: &str, skip_last: bool, nav_error: bool) -> String {
    format!(
        r#"{pre}
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"initialize"'*) printf '{{"jsonrpc":"2.0","id":%s,"result":{{"serverInfo":{{"name":"{name}","version":"1"}},"capabilities":{{}}}}}}\n' "$id";;
    *'"method":"tools/list"'*) printf '{{"jsonrpc":"2.0","id":%s,"result":{{"tools":{tools}}}}}\n' "$id";;
    *'"method":"tools/call"'*) printf '{{"jsonrpc":"2.0","id":%s,"result":{{"content":[],"isError":{err}}}}}\n' "$id";;
  esac
done
"#,
        tools = tools_json(skip_last),
        err = nav_error,
    )
}

/// Names `BROWSER_TOOLS[from..to]` as a JSON array.
fn tools_between(from: usize, to: usize) -> String {
    let items: Vec<String> = BROWSER_TOOLS[from..to]
        .iter()
        .map(|t| format!("{{\"name\":\"{t}\"}}"))
        .collect();
    format!("[{}]", items.join(","))
}

/// A stub that passes identity and navigation, and whose `tools/list` answer is picked by the
/// request cursor: `arms` are shell `case` arms over `$cur` that set `r` to the result, or to `ERR`
/// for a JSON-RPC error.
fn paged_server(arms: &str) -> String {
    format!(
        r#"n=0
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"initialize"'*) printf '{{"jsonrpc":"2.0","id":%s,"result":{{"serverInfo":{{"name":"Playwright","version":"1"}},"capabilities":{{}}}}}}\n' "$id";;
    *'"method":"tools/list"'*)
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
    *'"method":"tools/call"'*) printf '{{"jsonrpc":"2.0","id":%s,"result":{{"content":[],"isError":false}}}}\n' "$id";;
  esac
done
"#
    )
}

fn spec(script: &str, cwd: &Path) -> Spec {
    Spec {
        exe: PathBuf::from("/bin/sh"),
        args: vec!["-c".into(), script.into()],
        env: vec![],
        cwd: cwd.to_path_buf(),
    }
}

fn quick() -> Timeouts {
    Timeouts {
        initialize: Duration::from_millis(1500),
        call: Duration::from_millis(1500),
        close: Duration::from_millis(500),
    }
}

fn run(script: &str) -> Result<(), Failure> {
    let t = TempDir::new();
    check(&spec(script, &t.path), &t.path, &quick())
}

#[test]
fn a_correct_server_passes() {
    assert_eq!(run(&server("", "Playwright", false, false)), Ok(()));
    assert_eq!(run(&server("", "playwright-mcp", false, false)), Ok(()));
}

#[test]
fn noise_partial_lines_and_stderr_lookalikes_do_not_confuse_it() {
    let pre = r#"echo 'not json at all'
echo '{"jsonrpc":"2.0","method":"notifications/message","params":{}}'
echo '{"jsonrpc":"2.0","id":99,"result":{}}'
echo '{"id":1,"result":{"serverInfo":{"name":"evil"}}}' >&2"#;
    assert_eq!(run(&server(pre, "Playwright", false, false)), Ok(()));
    // A reply that arrives in two writes.
    let script = r#"
IFS= read -r line
printf '{"jsonrpc":"2.0","id":1,'
sleep 0.3
printf '"result":{"serverInfo":{"name":"Playwright"}}}\n'
"#
    .to_string()
        + &server("", "Playwright", false, false);
    // The partial reply answers the first request; the loop then serves the rest.
    assert_eq!(run(&script), Ok(()));
}

#[test]
fn identity_tools_and_navigation_are_all_required() {
    assert_eq!(
        run(&server("", "Chromium", false, false)),
        Err(Failure::Check)
    );
    assert_eq!(
        run(&server("", "Playwright", true, false)),
        Err(Failure::Check)
    );
    assert_eq!(
        run(&server("", "Playwright", false, true)),
        Err(Failure::Check)
    );
}

#[test]
fn a_child_that_exits_or_hangs_fails_by_the_deadline() {
    assert_eq!(run("read line; exit 0"), Err(Failure::Check));
    assert_eq!(run("exit 1"), Err(Failure::Check));
    let started = std::time::Instant::now();
    assert_eq!(run("sleep 60"), Err(Failure::Check));
    assert!(
        started.elapsed() < Duration::from_secs(12),
        "{:?}",
        started.elapsed()
    );
    assert_eq!(run("/nonexistent-binary-xyz"), Err(Failure::Check));
}

#[test]
fn a_line_over_the_cap_ends_the_check() {
    let script = format!(
        "head -c {} /dev/zero | tr '\\0' a; echo\nsleep 5\n",
        MAX_LINE + 4096
    );
    let started = std::time::Instant::now();
    assert_eq!(run(&script), Err(Failure::Check));
    assert!(started.elapsed() < Duration::from_secs(10));
}

#[test]
fn a_sandbox_refusal_is_classified_and_the_text_stays_inside() {
    let r = run("echo 'SECRET-CANARY: No usable sandbox! (stderr)' >&2; exit 1");
    assert_eq!(r, Err(Failure::Refused));
    assert_eq!(Failure::Refused.class(), "launch_refused");
    assert_eq!(
        run("echo 'SECRET-CANARY plain failure' >&2; exit 1"),
        Err(Failure::Check)
    );
    let dbg = format!("{:?} {}", Failure::Refused, Failure::Check.class());
    assert!(!dbg.contains("SECRET"));
}

#[test]
fn the_launch_vector_has_no_listener_and_no_sandbox_bypass() {
    let s = launch_spec(
        Path::new("/s/node/bin/node"),
        Path::new("/s/pkg/node_modules/@playwright/mcp/cli.js"),
        Path::new("/s/chromium/c/chrome"),
        Path::new("/s/hc/profile"),
        Path::new("/s/hc/output"),
        Path::new("/s"),
        Path::new("/tmp/oab-hc-x"),
    );
    for bad in ["--no-sandbox", "--port", "--host", "--allowed-hosts"] {
        assert!(!s.args.iter().any(|a| a == bad), "{bad}");
    }
    for want in [
        "--sandbox",
        "--headless",
        "--user-data-dir",
        "--output-dir",
        "--executable-path",
        "--shared-browser-context",
        "--idle-timeout",
    ] {
        assert!(s.args.iter().any(|a| a == want), "{want}");
    }
    let keys: Vec<&str> = s.env.iter().map(|(k, _)| k.as_str()).collect();
    assert_eq!(keys, ["HOME", "TMPDIR", "LANG", "PATH"]);
    assert_eq!(s.cwd, Path::new("/s"));
    assert!(s
        .env
        .contains(&("TMPDIR".to_string(), "/tmp/oab-hc-x".to_string())));
}

#[cfg(target_os = "linux")]
#[test]
fn a_detached_grandchild_under_staging_does_not_outlive_the_check() {
    let t = TempDir::new();
    let scope = t.path.join("staging");
    std::fs::create_dir_all(&scope).unwrap();
    let bin = scope.join("bleeper");
    crate::test_exec::copy_exec(std::path::Path::new("/bin/sleep"), &bin);
    let pidfile = t.path.join("pid");
    let script = format!(
        "setsid {} 300 & echo $! > {}; exit 1",
        bin.display(),
        pidfile.display()
    );
    assert_eq!(
        check(&spec(&script, &t.path), &scope, &quick()),
        Err(Failure::Check)
    );
    let pid = std::fs::read_to_string(&pidfile).unwrap();
    let pid = pid.trim();
    let mut dead = false;
    for _ in 0..60 {
        if !std::path::Path::new(&format!("/proc/{pid}")).exists() {
            dead = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(dead, "the grandchild is still running");
}

#[test]
fn a_required_tool_on_a_later_page_is_found() {
    let first = tools_between(0, 20);
    let rest = tools_between(20, 32);
    let arms = format!(
        r#"      "") r='{{"tools":{first},"nextCursor":"p2"}}';;
      p2) r='{{"tools":{rest}}}';;"#
    );
    assert_eq!(run(&paged_server(&arms)), Ok(()));
}

#[test]
fn a_missing_tool_is_still_missing_after_every_page() {
    let first = tools_between(0, 20);
    let rest = tools_between(20, 31);
    let arms = format!(
        r#"      "") r='{{"tools":{first},"nextCursor":"p2"}}';;
      p2) r='{{"tools":{rest}}}';;"#
    );
    assert_eq!(run(&paged_server(&arms)), Err(Failure::Check));
}

#[test]
fn an_empty_page_with_a_cursor_does_not_end_the_list() {
    let all = tools_between(0, 32);
    let arms = format!(
        r#"      "") r='{{"tools":[],"nextCursor":"p2"}}';;
      p2) r='{{"tools":{all}}}';;"#
    );
    assert_eq!(run(&paged_server(&arms)), Ok(()));
}

#[test]
fn an_empty_string_cursor_ends_the_list() {
    let all = tools_between(0, 32);
    let arms = format!(r#"      *) r='{{"tools":{all},"nextCursor":""}}';;"#);
    assert_eq!(run(&paged_server(&arms)), Ok(()));
}

#[test]
fn a_cursor_that_never_ends_or_repeats_fails_the_check() {
    let all = tools_between(0, 32);
    // Every page names a new cursor: the walk stops at the page cap.
    let endless = format!(r#"      *) r='{{"tools":{all},"nextCursor":"n'"$n"'"}}';;"#);
    assert_eq!(run(&paged_server(&endless)), Err(Failure::Check));
    // The cursor of page two points back at page one.
    let cycle = format!(
        r#"      "") r='{{"tools":{all},"nextCursor":"a"}}';;
      a) r='{{"tools":[],"nextCursor":"b"}}';;
      b) r='{{"tools":[],"nextCursor":"a"}}';;"#
    );
    assert_eq!(run(&paged_server(&cycle)), Err(Failure::Check));
}

#[test]
fn a_failing_later_page_fails_the_check() {
    let all = tools_between(0, 32);
    let arms = format!(
        r#"      "") r='{{"tools":{all},"nextCursor":"p2"}}';;
      *) r=ERR;;"#
    );
    assert_eq!(run(&paged_server(&arms)), Err(Failure::Check));
}

#[test]
fn a_child_that_stops_reading_ends_the_check_by_the_deadline() {
    // Page one names a cursor larger than the pipe; the child then reads nothing more, so the
    // request for page two cannot be written. The call deadline must still end the check.
    let script = r#"IFS= read -r line
printf '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"Playwright"},"capabilities":{}}}\n'
IFS= read -r line
IFS= read -r line
printf '{"jsonrpc":"2.0","id":2,"result":{"tools":[],"nextCursor":"'
head -c 1048576 /dev/zero | tr '\0' a
printf '"}}\n'
exec sleep 30
"#;
    let started = Instant::now();
    assert_eq!(run(script), Err(Failure::Check));
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "{:?}",
        started.elapsed()
    );
}

#[test]
fn a_child_that_drains_slowly_ends_the_check_by_the_deadline() {
    // Page one names a cursor of 1 MiB; the child then takes its input a few KiB at a time, so the
    // request for page two goes on making progress without ever finishing.
    let script = r#"IFS= read -r line
printf '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"Playwright"},"capabilities":{}}}\n'
IFS= read -r line
IFS= read -r line
printf '{"jsonrpc":"2.0","id":2,"result":{"tools":[],"nextCursor":"'
head -c 1048576 /dev/zero | tr '\0' a
printf '"}}\n'
while sleep 0.05; do head -c 4096 >/dev/null; done
"#;
    let started = Instant::now();
    assert_eq!(run(script), Err(Failure::Check));
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "{:?}",
        started.elapsed()
    );
}
