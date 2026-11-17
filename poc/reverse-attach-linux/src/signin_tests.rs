use super::*;
use crate::child::tests::Fx;
use crate::containment::{Direct, SYSTEMD};
use crate::sigstop::Supervised;
use crate::state::tests::TempDir;
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::Arc;

/// A stub Playwright MCP server. It logs every line it receives and its arguments beside itself, and
/// answers like `child_tests::GOOD`. `nav` is the body of the `tools/call` answer.
fn node(nav: &str, stderr: &str) -> String {
    node_close(nav, stderr, r#"{"content":[]}"#)
}

/// Like `node`, with `close` as the whole `result` or `error` member of the `browser_close` answer.
fn node_close(nav: &str, stderr: &str, close: &str) -> String {
    let close = if close.starts_with("{\"code\"") {
        format!("\"error\":{close}")
    } else {
        format!("\"result\":{close}")
    };
    format!(
        r#"#!/bin/sh
d=$(dirname "$0")
printf '%s\n' "$@" > "$d/args.txt"
{stderr}
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$d/rx.txt"
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"initialize"'*) printf '{{"jsonrpc":"2.0","id":%s,"result":{{"serverInfo":{{"name":"Playwright"}}}}}}\n' "$id";;
    *'"name":"browser_close"'*) printf '{{"jsonrpc":"2.0","id":%s,%s}}\n' "$id" '{close}';;
    *'"method":"tools/call"'*) printf '{{"jsonrpc":"2.0","id":%s,"result":{nav}}}\n' "$id";;
  esac
done
"#
    )
}

const OK_NAV: &str = r#"{"content":[{"type":"text","text":"ok"}]}"#;

fn seat() -> Option<Seat> {
    Some(Seat {
        runtime_dir: PathBuf::from("/run/user/1000"),
        display: "wayland-1".into(),
    })
}

fn launcher() -> Supervised {
    Supervised::new(Arc::new(Direct::new(Ok(SYSTEMD))))
}

struct Out {
    result: Result<(), &'static str>,
    out: String,
    waits: usize,
}

fn go(fx: &Fx, terminal: bool, seat: Option<Seat>, url: &str) -> Out {
    go_ended(fx, terminal, seat, url, Ended::Enter)
}

fn go_ended(fx: &Fx, terminal: bool, seat: Option<Seat>, url: &str, ended: Ended) -> Out {
    let root = fx.root();
    let l = launcher();
    let s = Setup {
        root: &root,
        launcher: &l,
        is_terminal: terminal,
        seat,
        url,
        timeouts: Timeouts {
            initialize: Duration::from_secs(5),
            call: Duration::from_secs(5),
            close: Duration::from_secs(2),
        },
    };
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let mut n = 0usize;
    let result = run(
        &s,
        &mut Io {
            out: &mut out,
            err: &mut err,
        },
        &mut |_c| {
            n += 1;
            ended
        },
    );
    assert!(err.is_empty(), "signin wrote to stderr itself");
    Out {
        result,
        out: String::from_utf8(out).unwrap(),
        waits: n,
    }
}

fn version_dir(fx: &Fx) -> PathBuf {
    fx.root().abs_path().join("pw-1/node/bin")
}

#[test]
fn a_sign_in_navigates_waits_closes_and_leaves_no_record_or_process() {
    let fx = Fx::new(&node(OK_NAV, ""));
    let r = go(&fx, true, seat(), "https://example.com/login");
    assert_eq!(r.result, Ok(()));
    assert_eq!(r.waits, 1);
    assert!(
        r.out.contains("Press Enter here when finished."),
        "{}",
        r.out
    );
    // Nothing from the page or the tool result is printed.
    assert!(!r.out.contains("ok") || r.out.contains("Press Enter"));
    let rx = std::fs::read_to_string(version_dir(&fx).join("rx.txt")).unwrap();
    let lines: Vec<&str> = rx.lines().collect();
    let nav = lines
        .iter()
        .position(|l| l.contains("browser_navigate") && l.contains("https://example.com/login"))
        .expect("navigate was sent");
    let close = lines
        .iter()
        .position(|l| l.contains("browser_close"))
        .expect("close was sent");
    assert!(nav < close, "the browser is closed after the wait");
    assert!(
        crate::run_record::live(&fx.root()).is_empty(),
        "the run record outlived the sign-in"
    );
}

#[test]
fn the_signin_vector_is_headed_with_the_password_store_and_none_of_the_forbidden_flags() {
    let fx = Fx::new(&node(OK_NAV, ""));
    assert_eq!(go(&fx, true, seat(), "about:blank").result, Ok(()));
    let args = std::fs::read_to_string(version_dir(&fx).join("args.txt")).unwrap();
    for bad in [
        "--headless",
        "--no-sandbox",
        "--port",
        "--host",
        "--allowed-hosts",
    ] {
        assert!(!args.lines().any(|a| a == bad), "{bad} is in {args}");
    }
    assert!(args.lines().any(|a| a == "--sandbox"));
    let cfg = std::fs::read_to_string(fx.root().abs_path().join("pw-config.json")).unwrap();
    assert!(cfg.contains(crate::child::PASSWORD_STORE), "{cfg}");
    assert!(cfg.contains("\"headless\":false"), "{cfg}");
}

#[test]
fn the_failures_are_fixed_classes_and_nothing_is_started_for_the_first_four() {
    let fx = Fx::new(&node(OK_NAV, ""));
    let started = |fx: &Fx| version_dir(fx).join("args.txt").exists();
    assert_eq!(
        go(&fx, false, seat(), "about:blank").result,
        Err("terminal_required")
    );
    assert_eq!(go(&fx, true, None, "about:blank").result, Err("no_seat"));
    assert_eq!(
        go(&fx, true, seat(), "file:///etc/passwd").result,
        Err("invalid_url")
    );
    assert!(!started(&fx), "a browser was started for a refused request");
    // Not installed.
    let empty = TempDir::new();
    let _ = empty.root();
    let root = empty.root();
    let l = launcher();
    let s = Setup {
        root: &root,
        launcher: &l,
        is_terminal: true,
        seat: seat(),
        url: "about:blank",
        timeouts: Timeouts::default(),
    };
    let (mut o, mut e) = (Vec::new(), Vec::new());
    let r = run(
        &s,
        &mut Io {
            out: &mut o,
            err: &mut e,
        },
        &mut |_| Ended::Enter,
    );
    assert_eq!(r, Err("not_installed"));
}

#[test]
fn a_live_run_record_means_the_profile_is_held() {
    let fx = Fx::new(&node(OK_NAV, ""));
    let mut holder = std::process::Command::new("sleep")
        .arg("30")
        .spawn()
        .unwrap();
    let h = crate::run_record::write(&fx.root(), "managed", holder.id(), None).unwrap();
    let r = go(&fx, true, seat(), "about:blank");
    assert_eq!(r.result, Err("profile_locked"));
    assert!(
        !version_dir(&fx).join("args.txt").exists(),
        "a second browser was started on a held profile"
    );
    drop(h);
    holder.kill().unwrap();
    holder.wait().unwrap();
}

#[test]
fn chromiums_own_words_become_a_class_and_no_text() {
    let locked = Fx::new(&node(
        r#"{"isError":true,"content":[{"type":"text","text":"CANARY-PAGE-TEXT"}]}"#,
        "echo 'The profile appears to be in use by another process CANARY-STDERR' >&2",
    ));
    let r = go(&locked, true, seat(), "about:blank");
    assert_eq!(r.result, Err("profile_locked"));
    assert!(!r.out.contains("CANARY"));
    let refused = Fx::new(&node(
        r#"{"isError":true,"content":[]}"#,
        "echo 'No usable sandbox! CANARY-STDERR' >&2",
    ));
    let r = go(&refused, true, seat(), "about:blank");
    assert_eq!(r.result, Err("launch_refused"));
    assert!(!r.out.contains("CANARY"));
    // An error with nothing recognisable is a plain start failure.
    let plain = Fx::new(&node(r#"{"isError":true,"content":[]}"#, ""));
    assert_eq!(
        go(&plain, true, seat(), "about:blank").result,
        Err("spawn_failed")
    );
    for fx in [&locked, &refused, &plain] {
        assert!(crate::run_record::live(&fx.root()).is_empty());
    }
}

#[test]
fn a_server_that_is_not_playwright_is_not_used() {
    let fx = Fx::new(&node(OK_NAV, "").replace("\"Playwright\"", "\"Evil\""));
    let r = go(&fx, true, seat(), "about:blank");
    assert!(r.result.is_err());
    assert_eq!(r.waits, 0);
}

#[test]
fn urls_are_http_https_or_about_blank_and_bounded() {
    for ok in [
        "about:blank",
        "http://127.0.0.1:3000/x",
        "https://example.com/a?b=c#d",
    ] {
        assert!(valid_url(ok), "{ok}");
    }
    let long = format!("https://e.com/{}", "a".repeat(2048));
    for bad in [
        "",
        "https://",
        "ftp://example.com",
        "file:///etc/passwd",
        "javascript:alert(1)",
        "data:text/html,x",
        "https://exa mple.com",
        "https://example.com/\n",
        "https://example.com/\u{7}",
        "HTTPS://EXAMPLE.COM",
        long.as_str(),
    ] {
        assert!(!valid_url(bad), "{bad:?}");
    }
}

fn sock(dir: &std::path::Path, name: &str) -> UnixListener {
    UnixListener::bind(dir.join(name)).unwrap()
}

#[test]
fn the_seat_is_the_environments_display_or_the_highest_numbered_socket() {
    let t = TempDir::new();
    let d = t.path.join("rt");
    std::fs::create_dir_all(&d).unwrap();
    assert!(
        find_seat(None, &d).is_none(),
        "an empty runtime dir has no seat"
    );
    let _a = sock(&d, "wayland-0");
    let _b = sock(&d, "wayland-2");
    let _c = sock(&d, "wayland-10");
    // A regular file and a look-alike name are not seats.
    std::fs::write(d.join("wayland-99"), "x").unwrap();
    let _e = sock(&d, "wayland-x");
    let s = find_seat(None, &d).unwrap();
    assert_eq!(
        (s.display.as_str(), s.runtime_dir.as_path()),
        ("wayland-10", d.as_path())
    );
    // The environment's display wins when its socket is there, and is not guessed otherwise.
    assert_eq!(
        find_seat(Some("wayland-0"), &d).unwrap().display,
        "wayland-0"
    );
    assert!(find_seat(Some("wayland-7"), &d).is_none());
    let abs = d.join("wayland-2");
    let s = find_seat(Some(abs.to_str().unwrap()), &d).unwrap();
    assert_eq!(
        (s.display.as_str(), s.runtime_dir.as_path()),
        ("wayland-2", d.as_path())
    );
}

#[test]
fn only_enter_counts_as_a_finished_sign_in() {
    use std::sync::mpsc;
    let tick = Duration::from_millis(5);
    let far = Instant::now() + Duration::from_secs(5);
    let (tx, rx) = mpsc::channel::<bool>();
    tx.send(true).unwrap();
    assert_eq!(wait_loop(|| false, &rx, far, tick), Ended::Enter);
    let (_tx2, rx2) = mpsc::channel::<bool>();
    assert_eq!(wait_loop(|| true, &rx2, far, tick), Ended::ChildExited);
    assert_eq!(
        wait_loop(
            || false,
            &rx2,
            Instant::now() + Duration::from_millis(30),
            tick
        ),
        Ended::TimedOut
    );
}

#[test]
fn end_of_input_without_a_line_is_not_enter() {
    use std::sync::mpsc;
    let tick = Duration::from_millis(5);
    let far = Instant::now() + Duration::from_secs(5);
    let (tx, rx) = mpsc::channel::<bool>();
    tx.send(false).unwrap();
    assert_eq!(wait_loop(|| false, &rx, far, tick), Ended::Cancelled);
    let (tx2, rx2) = mpsc::channel::<bool>();
    drop(tx2);
    assert_eq!(wait_loop(|| false, &rx2, far, tick), Ended::Cancelled);
}

#[test]
fn a_wait_that_did_not_end_on_enter_is_not_success() {
    for (ended, class) in [
        (Ended::Cancelled, "cancelled"),
        (Ended::ChildExited, "browser_exited"),
        (Ended::TimedOut, "timed_out"),
    ] {
        let fx = Fx::new(&node(OK_NAV, ""));
        let o = go_ended(&fx, true, seat(), "about:blank", ended);
        assert_eq!(o.result, Err(class));
        assert_eq!(o.waits, 1);
        assert!(crate::run_record::live(&fx.root()).is_empty());
    }
}

#[test]
fn a_close_that_failed_is_not_reported_as_a_finished_sign_in() {
    for close in [
        r#"{"isError":true,"content":[]}"#,
        r#"{"code":-32000,"message":"no"}"#,
    ] {
        let fx = Fx::new(&node_close(OK_NAV, "", close));
        let r = go(&fx, true, seat(), "about:blank");
        assert_eq!(r.result, Err("close_failed"), "{close}");
        assert!(crate::run_record::live(&fx.root()).is_empty());
    }
}
