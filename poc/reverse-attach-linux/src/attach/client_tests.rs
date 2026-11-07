//! Dial-side negatives for reverse attach, run against a plain TCP listener
//! standing in for the runtime. They pin what the Rust dialer sends on the
//! upgrade and how it reacts to a refused upgrade (the Swift oracle is
//! `ReverseAttachNegativeTests`).
//!
//! The refused-upgrade cases and the wss TLS-failure case run the production
//! `dial_loop`, so a regression that redials after a 401, or that panics or sticks
//! at `dialing` on a TLS failure, fails here. The direct wss case and the
//! missing-header case call `tungstenite::connect` and do not exercise `dial_loop`.

use std::collections::HashMap;
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use tungstenite::handshake::server::{
    ErrorResponse, Request as ServerRequest, Response as ServerResponse,
};
use tungstenite::http::{Request, Response};

use super::*;

/// Accept one upgrade on 127.0.0.1:0. A request whose `Authorization` is not
/// exactly `Bearer <expected>` gets 401. Returns the port and a join handle that
/// yields the Authorization value of each request seen.
fn one_shot_runtime(expected: &'static str) -> (u16, thread::JoinHandle<Vec<Option<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let handle = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let seen = Arc::new(Mutex::new(None));
        let cb_seen = seen.clone();
        let want = format!("Bearer {expected}");
        #[allow(clippy::result_large_err)] // ErrorResponse is fixed by tungstenite's callback type
        let callback = move |req: &ServerRequest,
                             resp: ServerResponse|
              -> Result<ServerResponse, ErrorResponse> {
            let header = req
                .headers()
                .get("authorization")
                .and_then(|v| v.to_str().ok())
                .map(str::to_owned);
            let ok = header.as_deref() == Some(want.as_str());
            *cb_seen.lock().unwrap() = Some(header);
            if ok {
                Ok(resp)
            } else {
                Err(Response::builder().status(401).body(None).unwrap())
            }
        };
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let _ = tungstenite::accept_hdr(stream, callback);
        let authorization = seen.lock().unwrap().clone().flatten();
        vec![authorization]
    });
    (port, handle)
}

/// Accept TCP connections for `linger` and refuse every upgrade whose
/// `Authorization` is not `Bearer <expected>`. Returns the Authorization value of
/// each connection, so a redial shows up as a second entry.
#[allow(clippy::type_complexity)]
fn refusing_runtime(
    expected: &'static str,
    linger: Duration,
) -> (u16, thread::JoinHandle<Vec<Option<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    listener.set_nonblocking(true).unwrap();
    let handle = thread::spawn(move || {
        let mut seen = Vec::new();
        let until = Instant::now() + linger;
        while Instant::now() < until {
            let stream = match listener.accept() {
                Ok((stream, _)) => stream,
                Err(_) => {
                    thread::sleep(Duration::from_millis(20));
                    continue;
                }
            };
            stream.set_nonblocking(false).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let want = format!("Bearer {expected}");
            let authorization = Arc::new(Mutex::new(None));
            let cb_seen = authorization.clone();
            #[allow(clippy::result_large_err)]
            // ErrorResponse is fixed by tungstenite's callback type
            let callback = move |req: &ServerRequest,
                                 resp: ServerResponse|
                  -> Result<ServerResponse, ErrorResponse> {
                let header = req
                    .headers()
                    .get("authorization")
                    .and_then(|v| v.to_str().ok())
                    .map(str::to_owned);
                let ok = header.as_deref() == Some(want.as_str());
                *cb_seen.lock().unwrap() = Some(header);
                if ok {
                    Ok(resp)
                } else {
                    Err(Response::builder().status(401).body(None).unwrap())
                }
            };
            let _ = tungstenite::accept_hdr(stream, callback);
            seen.push(authorization.lock().unwrap().clone().flatten());
        }
        seen
    });
    (port, handle)
}

/// Accept one connection and read what arrives first. Used to see whether a
/// `wss://` dial sends anything that looks like HTTP to a plaintext listener.
fn plaintext_listener() -> (u16, thread::JoinHandle<Vec<u8>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let handle = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut buf = vec![0u8; 512];
        let n = std::io::Read::read(&mut stream, &mut buf).unwrap_or(0);
        buf.truncate(n);
        buf
    });
    (port, handle)
}

fn upgrade_url(port: u16) -> String {
    format!("ws://127.0.0.1:{port}/tools/attach/s1")
}

/// The same request `build_ws_request` builds, minus the `Authorization` header.
fn upgrade_without_authorization(url: &str) -> Request<()> {
    Request::builder()
        .method("GET")
        .uri(url)
        .header(
            "Host",
            url.trim_start_matches("ws://").split('/').next().unwrap(),
        )
        .header("Connection", "Upgrade")
        .header("Upgrade", "websocket")
        .header("Sec-WebSocket-Version", "13")
        .header(
            "Sec-WebSocket-Key",
            tungstenite::handshake::client::generate_key(),
        )
        .body(())
        .unwrap()
}

/// Run the production `dial_loop` once against a runtime that expects `s3cret`,
/// with `secret` as the grant's bearer. Returns the grant state and end reason
/// after the loop returns, and the Authorization value of every connection.
///
/// The runtime lingers 2.5 s. The grant deadline is 4 whole seconds away (more
/// than 3 s), so it outlasts the linger window. A redial would start after the
/// 1 s first backoff, so it would land inside the linger window and show up as a
/// second entry. Without a redial the loop returns at once with a
/// handshake end reason.
fn dial_loop_against_refusing_runtime(
    secret: &str,
) -> (Option<String>, Option<String>, Vec<Option<String>>) {
    let (port, server) = refusing_runtime("s3cret", Duration::from_millis(2500));
    let runtime = format!("ws://127.0.0.1:{port}");
    let registry: Registry = Arc::new(Mutex::new(HashMap::new()));
    let grant_id = "grant-dial-test".to_string();
    registry.lock().unwrap().insert(
        grant_id.clone(),
        GrantInfo {
            id: grant_id.clone(),
            runtime: runtime.clone(),
            session: "s1".to_string(),
            profile: "owner".to_string(),
            principal: "a@b".to_string(),
            state: "dialing".to_string(),
            ended: None,
            expires_at_epoch_secs: now_epoch_secs() + 600,
            cancelled: Arc::new(AtomicBool::new(false)),
            secret: secret.to_string(),
        },
    );
    dial_loop(DialGrant {
        runtime,
        session: "s1".to_string(),
        secret: secret.to_string(),
        profile: "owner".to_string(),
        deadline_epoch_secs: now_epoch_secs() + 4,
        registry: registry.clone(),
        grant_id: grant_id.clone(),
        cancelled: Arc::new(AtomicBool::new(false)),
        tuning: DialTuning::default(),
    });
    let (state, ended) = {
        let map = registry.lock().unwrap();
        let g = map.get(&grant_id).unwrap();
        (Some(g.state.clone()), g.ended.clone())
    };
    (state, ended, server.join().unwrap())
}

#[test]
fn right_bearer_is_sent_and_upgrades() {
    let (port, server) = one_shot_runtime("s3cret");
    let req = build_ws_request(&upgrade_url(port), "s3cret").unwrap();
    let (_socket, resp) = match tungstenite::connect(req) {
        Ok(ok) => ok,
        Err(e) => panic!("upgrade with the right bearer was refused: {e}"),
    };
    assert_eq!(resp.status().as_u16(), 101);
    let seen = server.join().unwrap();
    assert_eq!(seen, vec![Some("Bearer s3cret".to_string())]);
}

#[test]
fn right_bearer_upgrade_sends_websocket_headers() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let headers = Arc::new(Mutex::new((None, None)));
        let cb = headers.clone();
        #[allow(clippy::result_large_err)] // ErrorResponse is fixed by tungstenite's callback type
        let callback = move |req: &ServerRequest,
                             resp: ServerResponse|
              -> Result<ServerResponse, ErrorResponse> {
            let get = |name: &str| {
                req.headers()
                    .get(name)
                    .and_then(|v| v.to_str().ok())
                    .map(str::to_owned)
            };
            *cb.lock().unwrap() = (get("upgrade"), get("connection"));
            Ok(resp)
        };
        let _ = tungstenite::accept_hdr(stream, callback);
        let h = headers.lock().unwrap().clone();
        h
    });
    let req = build_ws_request(&upgrade_url(port), "s3cret").unwrap();
    tungstenite::connect(req).expect("upgrade should succeed");
    let (upgrade, connection) = server.join().unwrap();
    assert_eq!(
        upgrade.as_deref().map(str::to_ascii_lowercase).as_deref(),
        Some("websocket")
    );
    assert!(connection
        .as_deref()
        .unwrap_or("")
        .to_ascii_lowercase()
        .contains("upgrade"));
}

#[test]
fn same_length_wrong_bearer_is_refused_once_and_stops() {
    let (state, ended, seen) = dial_loop_against_refusing_runtime("s3crXt");
    assert_eq!(state.as_deref(), Some("ended"));
    assert_eq!(ended.as_deref(), Some("handshake_rejected_401"));
    assert_eq!(seen, vec![Some("Bearer s3crXt".to_string())]);
    assert!(matches!(
        disposition_handshake(401),
        Disposition::Stop(ref r) if r == "handshake_rejected_401"
    ));
}

#[test]
fn empty_bearer_is_refused_once_and_stops() {
    let (state, ended, seen) = dial_loop_against_refusing_runtime("");
    assert_eq!(state.as_deref(), Some("ended"));
    assert_eq!(ended.as_deref(), Some("handshake_rejected_401"));
    assert_eq!(seen.len(), 1, "a redial happened: {seen:?}");
}

/// Runtime-side refusal only: `build_ws_request` always sends Authorization, so
/// the dialer never produces this request. The test checks that a runtime which
/// gets an upgrade with no Authorization refuses it, and that one connection was
/// made.
#[test]
fn upgrade_without_authorization_is_refused_with_one_connection() {
    let (port, server) = refusing_runtime("s3cret", Duration::from_millis(300));
    let req = upgrade_without_authorization(&upgrade_url(port));
    let err = match tungstenite::connect(req) {
        Err(e) => e,
        Ok(_) => panic!("an upgrade without Authorization must not succeed"),
    };
    assert_eq!(handshake_status(&err), Some(401));
    assert_eq!(server.join().unwrap(), vec![None]);
}

/// Calls `tungstenite::connect` directly, not `dial_loop`. With the ring provider
/// installed (#66) the dial must return a TLS or I/O error: a panic fails the test.
#[test]
fn wss_to_a_plaintext_listener_fails_without_falling_back() {
    crate::install_crypto_provider();
    let (port, server) = plaintext_listener();
    let url = format!("wss://127.0.0.1:{port}/tools/attach/s1");
    let req = build_ws_request(&url, "s3cret").unwrap();
    let err = match tungstenite::connect(req) {
        Ok(_) => panic!("wss to a plaintext listener upgraded"),
        Err(e) => e,
    };
    assert!(
        matches!(err, tungstenite::Error::Tls(_) | tungstenite::Error::Io(_)),
        "expected a TLS or I/O error, got {err:?}"
    );
    let bytes = server.join().unwrap();
    assert!(
        !bytes.starts_with(b"GET "),
        "dialer fell back to plaintext HTTP"
    );
    assert!(
        !bytes.windows(4).any(|w| w == b"HTTP"),
        "dialer sent an HTTP request"
    );
}

/// Accept TCP connections for `linger`, read what arrives first on each and close
/// it. Returns those first bytes per connection, so a redial is a second entry.
fn plaintext_runtime(linger: Duration) -> (u16, thread::JoinHandle<Vec<Vec<u8>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    listener.set_nonblocking(true).unwrap();
    let handle = thread::spawn(move || {
        let mut seen = Vec::new();
        let until = Instant::now() + linger;
        while Instant::now() < until {
            let mut stream = match listener.accept() {
                Ok((stream, _)) => stream,
                Err(_) => {
                    thread::sleep(Duration::from_millis(20));
                    continue;
                }
            };
            stream.set_nonblocking(false).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut buf = vec![0u8; 512];
            let n = std::io::Read::read(&mut stream, &mut buf).unwrap_or(0);
            buf.truncate(n);
            seen.push(buf);
        }
        seen
    });
    (port, handle)
}

/// The production `dial_loop` against a `wss://` runtime that speaks plaintext.
/// Each TLS failure must lead to `redialing` and a backoff redial, the dial thread
/// must not panic, and the grant must end at its deadline instead of staying at
/// `dialing` (#66).
///
/// The runtime lingers 2.5 s and the deadline is 3 whole seconds away, so the
/// redial after the 1 s first backoff lands inside the linger window.
#[test]
fn wss_tls_failure_in_dial_loop_redials_and_ends_at_deadline() {
    crate::install_crypto_provider();
    let (port, server) = plaintext_runtime(Duration::from_millis(2500));
    let runtime = format!("wss://127.0.0.1:{port}");
    let registry: Registry = Arc::new(Mutex::new(HashMap::new()));
    let grant_id = "grant-wss-test".to_string();
    registry.lock().unwrap().insert(
        grant_id.clone(),
        GrantInfo {
            id: grant_id.clone(),
            runtime: runtime.clone(),
            session: "s1".to_string(),
            profile: "owner".to_string(),
            principal: "a@b".to_string(),
            state: "dialing".to_string(),
            ended: None,
            expires_at_epoch_secs: now_epoch_secs() + 600,
            cancelled: Arc::new(AtomicBool::new(false)),
            secret: "s3cret".to_string(),
        },
    );
    let grant = DialGrant {
        runtime,
        session: "s1".to_string(),
        secret: "s3cret".to_string(),
        profile: "owner".to_string(),
        deadline_epoch_secs: now_epoch_secs() + 3,
        registry: registry.clone(),
        grant_id: grant_id.clone(),
        cancelled: Arc::new(AtomicBool::new(false)),
        tuning: DialTuning::default(),
    };
    let dialer = thread::spawn(move || dial_loop(grant));
    let mut states = Vec::new();
    // The deadline is at most 3 s away; a dial_loop still running 10 s later is
    // stuck, so fail instead of hanging the suite.
    let give_up = Instant::now() + Duration::from_secs(10);
    while !dialer.is_finished() {
        assert!(
            Instant::now() < give_up,
            "dial_loop did not end at its deadline; states seen: {states:?}"
        );
        let state = registry
            .lock()
            .unwrap()
            .get(&grant_id)
            .unwrap()
            .state
            .clone();
        if states.last() != Some(&state) {
            states.push(state);
        }
        thread::sleep(Duration::from_millis(10));
    }
    assert!(dialer.join().is_ok(), "the dial thread panicked");
    let (state, ended) = {
        let map = registry.lock().unwrap();
        let g = map.get(&grant_id).unwrap();
        (g.state.clone(), g.ended.clone())
    };
    assert_eq!(state, "ended", "states seen: {states:?}");
    assert_eq!(ended.as_deref(), Some("deadline"));
    assert!(
        states.iter().any(|s| s == "redialing"),
        "never reached redialing: {states:?}"
    );
    let seen = server.join().unwrap();
    assert!(seen.len() >= 2, "no redial after the TLS failure: {seen:?}");
    for bytes in &seen {
        assert!(
            !bytes.starts_with(b"GET ") && !bytes.windows(4).any(|w| w == b"HTTP"),
            "dialer sent plaintext HTTP"
        );
    }
}
