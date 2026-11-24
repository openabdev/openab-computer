//! Outbound half of reverse attach: mint an attach secret at the runtime, dial `/tools/attach/{session}` over WebSocket, serve MCP on it with the grant's profile, redial/stop per the disposition table.

use std::io::Read;
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tungstenite::http::Request;
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Message, WebSocket};

use super::*;
use crate::mcp::{answer_attached, error_response, parse_request};

// mint(): replicate the Swift runtimeMintRequest contract (http/ws and https/wss)
// ---------------------------------------------------------------------------

/// Largest mint response read. A real one is a few hundred bytes of JSON.
const MINT_MAX_BODY: u64 = 64 * 1024;
const MINT_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const MINT_READ_TIMEOUT: Duration = Duration::from_secs(15);
const MINT_TOTAL_TIMEOUT: Duration = Duration::from_secs(30);

/// Root certificates a `https` mint verifies the runtime against. There is no way to turn
/// verification off. Production uses `system()`; tests build one around their own root with
/// `with_root_der`, which only exists in test builds.
pub(crate) struct MintTrust {
    roots: ureq::tls::RootCerts,
}

impl MintTrust {
    /// The system root store, the same source the dial's `rustls-tls-native-roots` reads. A
    /// host with no usable system roots falls back to the bundled webpki roots, never to
    /// "trust anything".
    pub(crate) fn system() -> Self {
        let roots = match rustls_native_certs::load_native_certs() {
            Ok(certs) if !certs.is_empty() => ureq::tls::RootCerts::from(
                certs
                    .iter()
                    .map(|c| ureq::tls::Certificate::from_der(c.as_ref()).to_owned()),
            ),
            _ => ureq::tls::RootCerts::WebPki,
        };
        MintTrust { roots }
    }

    #[cfg(test)]
    pub(crate) fn with_root_der(der: &[u8]) -> Self {
        MintTrust {
            roots: ureq::tls::RootCerts::from([ureq::tls::Certificate::from_der(der).to_owned()]),
        }
    }
}

/// Replaces every occurrence of the credential in text that may reach a log or an error.
fn redact(text: &str, credential: &str) -> String {
    if credential.is_empty() {
        text.to_string()
    } else {
        text.replace(credential, "[redacted]")
    }
}

/// Decodes `%XX` escapes, or returns None when an escape is not two hex digits.
fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = bytes.get(i + 1..i + 3)?;
            if !hex.iter().all(u8::is_ascii_hexdigit) {
                return None;
            }
            let byte = u8::from_str_radix(std::str::from_utf8(hex).ok()?, 16).ok()?;
            out.push(byte);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    Some(String::from_utf8_lossy(&out).into_owned())
}

pub(crate) fn mint(
    runtime: &str,
    session: &str,
    admin_credential: &str,
    ttl_secs: u64,
) -> Result<(String, u64), String> {
    mint_with(
        &MintTrust::system(),
        runtime,
        session,
        admin_credential,
        ttl_secs,
    )
}

pub(crate) fn mint_with(
    trust: &MintTrust,
    runtime: &str,
    session: &str,
    admin_credential: &str,
    ttl_secs: u64,
) -> Result<(String, u64), String> {
    // Every error is redacted once more after all caller-derived text (the runtime authority
    // included) is interpolated, so no path can echo the credential.
    mint_inner(trust, runtime, session, admin_credential, ttl_secs)
        .map_err(|e| redact(&e, admin_credential))
}

fn mint_inner(
    trust: &MintTrust,
    runtime: &str,
    session: &str,
    admin_credential: &str,
    ttl_secs: u64,
) -> Result<(String, u64), String> {
    // Map scheme ws->http, wss->https. Plain http stays what it was: any ws:// runtime.
    let (https, rest) = if let Some(rest) = runtime.strip_prefix("wss://") {
        (true, rest)
    } else if let Some(rest) = runtime.strip_prefix("ws://") {
        (false, rest)
    } else {
        return Err("unsupported runtime scheme for mint: use ws:// or wss://".to_string());
    };
    let rest = strip_trailing_slashes(rest);
    // The runtime string is never echoed below: it must not carry userinfo, a query or a
    // fragment, so nothing in it can be a second credential or a redirect of the request.
    // Percent escapes are allowed in the path prefix only. The decoded path must pass the
    // same check, so `%40` or `%3F` cannot smuggle userinfo or a query past it.
    let has_bad_char = |s: &str| {
        s.chars()
            .any(|c| c.is_control() || c.is_whitespace() || matches!(c, '@' | '?' | '#' | '\\'))
    };
    let host_part = rest.split('/').next().unwrap_or(rest);
    let decoded = percent_decode(rest);
    if rest.is_empty()
        || rest.starts_with('/')
        || host_part.contains('%')
        || has_bad_char(rest)
        || decoded.as_deref().is_none_or(|d| {
            d.chars()
                .any(|c| c.is_control() || matches!(c, '@' | '?' | '#' | '\\'))
        })
    {
        return Err(
            "runtime must be ws://host[:port][/prefix] or wss://host[:port][/prefix], \
             with no user info, query or fragment"
                .to_string(),
        );
    }
    if admin_credential.chars().any(|c| c.is_control()) {
        return Err("admin credential contains a control character".to_string());
    }
    // The runtime and session are stored in grants.json and shown by the grant list, so the
    // admin credential must not be a substring of either: refuse before any request, and
    // without echoing either value.
    if !admin_credential.is_empty()
        && (runtime.contains(admin_credential)
            || decoded
                .as_deref()
                .is_some_and(|d| d.contains(admin_credential))
            || session.contains(admin_credential))
    {
        return Err(
            "runtime and session must not contain the admin credential; the runtime address \
             is stored and listed"
                .to_string(),
        );
    }
    let authority = rest.split('/').next().unwrap_or(rest).to_string();
    let url = format!(
        "{}://{}/admin/sessions/{}/tools-attach",
        if https { "https" } else { "http" },
        rest,
        session
    );
    let body = json!({ "ttl_secs": ttl_secs }).to_string();

    let tls = ureq::tls::TlsConfig::builder()
        .root_certs(trust.roots.clone())
        .build();
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .proxy(None)
        .https_only(https)
        .max_redirects(0)
        .max_redirects_will_error(false)
        .http_status_as_error(false)
        .user_agent("oab-computer")
        .accept_encoding("identity")
        .tls_config(tls)
        .timeout_connect(Some(MINT_CONNECT_TIMEOUT))
        .timeout_per_read(Some(MINT_READ_TIMEOUT))
        .timeout_global(Some(MINT_TOTAL_TIMEOUT))
        .build()
        .into();

    let mut response = agent
        .post(&url)
        .header("Authorization", format!("Bearer {admin_credential}"))
        .content_type("application/json")
        .send(body.as_str())
        .map_err(|e| {
            let detail = redact(&e.to_string(), admin_credential);
            if https {
                format!(
                    "mint to {authority} failed: {detail} (the runtime's certificate must be \
                     valid for that host and chain to a system root certificate)"
                )
            } else {
                format!("mint to {authority} failed: {detail}")
            }
        })?;

    let status = response.status().as_u16();
    let mut raw = Vec::new();
    response
        .body_mut()
        .as_reader()
        .take(MINT_MAX_BODY + 1)
        .read_to_end(&mut raw)
        .map_err(|e| {
            format!(
                "mint response read failed: {}",
                redact(&e.to_string(), admin_credential)
            )
        })?;
    if raw.len() as u64 > MINT_MAX_BODY {
        return Err(format!(
            "mint response from {authority} exceeds {MINT_MAX_BODY} bytes; refused"
        ));
    }
    let resp_body = String::from_utf8_lossy(&raw);

    if (300..=399).contains(&status) {
        return Err(format!(
            "mint HTTP {status}: the runtime redirected the request; redirects are never \
             followed, so use the runtime's final address"
        ));
    }
    if !(200..=299).contains(&status) {
        // The body is never returned: a runtime can echo the credential in an escaped form
        // (JSON \\uXXXX, percent-encoding) that a literal redaction does not see.
        let hint = match status {
            401 | 403 => "the runtime refused the admin credential",
            404 => {
                "the runtime has no such session or endpoint; check the runtime address and session"
            }
            _ => "the runtime refused the request",
        };
        return Err(format!("mint HTTP {status}: {hint}"));
    }

    let v: Value = serde_json::from_str(resp_body.trim())
        .map_err(|e| format!("mint response parse error: {e}"))?;

    let secret = v
        .get("secret")
        .and_then(|s| s.as_str())
        .ok_or_else(|| "mint response missing secret".to_string())?
        .to_string();
    // Checked on the decoded value: a JSON-escaped echo of the credential only shows up
    // here, and would otherwise be stored in grants.json as the attach secret.
    if !admin_credential.is_empty() && secret.contains(admin_credential) {
        return Err(
            "mint response carried the admin credential as the attach secret; refused".to_string(),
        );
    }

    let expires_in = v
        .get("expires_in_secs")
        .or_else(|| v.get("expires_in"))
        .or_else(|| v.get("expiresIn"))
        .and_then(|e| e.as_u64())
        .unwrap_or(ttl_secs);

    Ok((secret, expires_in))
}

// ---------------------------------------------------------------------------
// WebSocket dial loop
// ---------------------------------------------------------------------------

pub(crate) struct DialGrant {
    pub(crate) runtime: String,
    pub(crate) session: String,
    pub(crate) secret: String,
    pub(crate) profile: String,
    pub(crate) deadline_epoch_secs: u64,
    pub(crate) registry: Registry,
    pub(crate) grant_id: String,
    pub(crate) cancelled: Arc<AtomicBool>,
    pub(crate) tuning: DialTuning,
}

/// Timers of one attached socket. Production uses `Default`; tests change them.
#[derive(Clone, Copy)]
pub(crate) struct DialTuning {
    /// How often we ping the runtime while attached, below its 20 s ping
    /// interval (any inbound frame counts as alive there). `None` turns our own
    /// pings off (tests).
    pub(crate) keepalive: Option<Duration>,
    /// A connection that stayed up this long resets the redial backoff.
    pub(crate) stable_after: Duration,
    /// How long one read may block while no call runs (`IDLE_READ_POLL`).
    pub(crate) idle_read_poll: Duration,
}

impl Default for DialTuning {
    fn default() -> Self {
        DialTuning {
            keepalive: Some(Duration::from_secs(15)),
            stable_after: Duration::from_secs(60),
            idle_read_poll: IDLE_READ_POLL,
        }
    }
}

/// How long one `read` may block while a call is running. The attached loop is
/// also the socket's only writer, so this bounds how long a finished call's reply
/// waits to be sent.
const READ_POLL: Duration = Duration::from_millis(20);

/// How long one `read` may block on an idle attach (no call running), capped at
/// the next keepalive ping. Inbound frames, including the runtime's pings, end
/// the read at once; this only bounds how long a DELETE waits to close the
/// socket.
const IDLE_READ_POLL: Duration = Duration::from_millis(250);

pub(crate) fn dial_loop(config: DialGrant) {
    let DialGrant {
        runtime,
        session,
        secret,
        profile,
        deadline_epoch_secs,
        registry,
        grant_id,
        cancelled,
        tuning,
    } = config;
    let mut backoff: u64 = 1;
    let cap: u64 = 30;

    loop {
        if cancelled.load(Ordering::Acquire) {
            return;
        }
        if now_epoch_secs() >= deadline_epoch_secs {
            break;
        }

        set_state(&registry, &grant_id, "dialing");
        let url = attach_url(&runtime, &session);

        let req = match build_ws_request(&url, &secret) {
            Ok(r) => r,
            Err(_) => {
                set_state(&registry, &grant_id, "redialing");
                if !sleep_until_backoff(deadline_epoch_secs, &mut backoff, cap, cancelled.as_ref())
                {
                    break;
                }
                continue;
            }
        };

        match tungstenite::connect(req) {
            Ok((mut socket, _resp)) => {
                let connected_at = Instant::now();
                set_state(&registry, &grant_id, "attached");
                let end = serve_socket(&mut socket, &profile, cancelled.as_ref(), &tuning);
                // Only a connection that stayed up resets the backoff, so a
                // runtime that accepts and drops at once is not redialled every
                // second.
                if connected_at.elapsed() >= tuning.stable_after {
                    backoff = 1;
                }
                match end {
                    SocketEnd::Cancelled => return,
                    SocketEnd::Stop(reason) => {
                        set_ended(&registry, &grant_id, &reason);
                        return;
                    }
                    SocketEnd::Redial => {}
                }
            }
            Err(error) => {
                if let Some(status) = handshake_status(&error) {
                    match disposition_handshake(status) {
                        Disposition::Stop(reason) => {
                            set_ended(&registry, &grant_id, &reason);
                            return;
                        }
                        Disposition::Redial => {}
                    }
                }
            }
        }

        set_state(&registry, &grant_id, "redialing");
        if !sleep_until_backoff(deadline_epoch_secs, &mut backoff, cap, cancelled.as_ref()) {
            break;
        }
    }

    if !cancelled.load(Ordering::Acquire) {
        set_ended(&registry, &grant_id, "deadline");
    }
}

/// How one attached socket ended.
enum SocketEnd {
    /// DELETE: the grant was revoked locally.
    Cancelled,
    /// A terminal close code (§9.2): end the grant with this reason.
    Stop(String),
    /// A retryable close (1000, 4006, 4011 liveness, …), a read or a send error.
    Redial,
}

/// Sets the flag when dropped: every exit from `serve_socket` cancels the calls
/// still running on that socket. The runtime has already failed them for the
/// caller, so nothing they return can be delivered, and a `bash` left running
/// would outlive the attach.
struct CancelOnDrop(Arc<AtomicBool>);

impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Release);
    }
}

/// Serve MCP on one attached socket until it ends.
///
/// The runtime pings every 20 s and closes an attach that stays silent for more
/// than three intervals (4011). So this loop never waits on a tool: each frame is
/// answered on its own thread, replies come back over a channel, and this loop,
/// the socket's only writer, sends them between reads. Reads keep going while a
/// tool runs, which answers the runtime's pings, and we also ping the runtime
/// every `tuning.keepalive`. A read blocks for `READ_POLL` while a call runs and
/// up to `IDLE_READ_POLL` (or the next keepalive) when none does, so an idle
/// attach wakes a few times a second rather than fifty.
fn serve_socket(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
    profile: &str,
    cancelled: &AtomicBool,
    tuning: &DialTuning,
) -> SocketEnd {
    let (replies, outbox) = mpsc::channel::<String>();
    let calls_cancelled = Arc::new(AtomicBool::new(false));
    let _cancel_calls = CancelOnDrop(calls_cancelled.clone());
    let in_flight = Arc::new(AtomicUsize::new(0));
    let mut next_ping = tuning.keepalive.map(|every| Instant::now() + every);
    let mut read_timeout: Option<Duration> = None;

    loop {
        if cancelled.load(Ordering::Acquire) {
            let _ = socket.close(None);
            let _ = socket.flush();
            return SocketEnd::Cancelled;
        }
        // Read before draining the outbox: a call sends its reply before it
        // stops counting, so a count of zero means its reply is already queued.
        let busy = in_flight.load(Ordering::Acquire) > 0;
        while let Ok(reply) = outbox.try_recv() {
            if socket.send(Message::Text(reply)).is_err() {
                return SocketEnd::Redial;
            }
        }
        if let (Some(at), Some(every)) = (next_ping, tuning.keepalive) {
            if Instant::now() >= at {
                if socket.send(Message::Ping(Vec::new())).is_err() {
                    return SocketEnd::Redial;
                }
                next_ping = Some(Instant::now() + every);
            }
        }
        let wait = if busy {
            READ_POLL
        } else {
            next_ping
                .map(|at| at.saturating_duration_since(Instant::now()))
                .map_or(tuning.idle_read_poll, |left| {
                    left.min(tuning.idle_read_poll)
                })
                .max(Duration::from_millis(1))
        };
        if read_timeout != Some(wait) {
            set_read_timeout(socket, wait);
            read_timeout = Some(wait);
        }
        let calls = Calls {
            profile,
            replies: &replies,
            cancel: &calls_cancelled,
            in_flight: &in_flight,
        };
        match socket.read() {
            Ok(Message::Text(t)) => spawn_call(t, &calls),
            Ok(Message::Binary(b)) => spawn_call(String::from_utf8_lossy(&b).into_owned(), &calls),
            Ok(Message::Ping(p)) => {
                let _ = socket.send(Message::Pong(p));
            }
            Ok(Message::Pong(_)) => {}
            Ok(Message::Close(frame)) => {
                let _ = socket.flush();
                let code = frame.as_ref().map(|f| u16::from(f.code)).unwrap_or(1000);
                return match disposition_close(code) {
                    Disposition::Stop(reason) => SocketEnd::Stop(reason),
                    Disposition::Redial => SocketEnd::Redial,
                };
            }
            Ok(Message::Frame(_)) => {}
            Err(tungstenite::Error::Io(ref error))
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(_) => return SocketEnd::Redial,
        }
    }
}

/// What a call thread needs from its socket's loop.
struct Calls<'a> {
    profile: &'a str,
    replies: &'a Sender<String>,
    cancel: &'a Arc<AtomicBool>,
    in_flight: &'a Arc<AtomicUsize>,
}

/// Counts one call as running until dropped, also when the call panics or its
/// thread never starts.
struct InFlight(Arc<AtomicUsize>);

impl Drop for InFlight {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::Release);
    }
}

/// Answer one frame on its own thread. No per-socket cap: the runtime already
/// bounds calls in flight. Calls pipelined on one socket may finish out of
/// order; each reply carries its id. If the thread cannot start, a request gets
/// a JSON-RPC error at once instead of waiting out the runtime's timeout.
fn spawn_call(text: String, calls: &Calls) {
    spawn_call_on(text, calls, |call| {
        thread::Builder::new()
            .name("attach-call".into())
            .spawn(call)
            .map(drop)
    });
}

/// A call thread's body, handed to the thread starter.
type CallJob = Box<dyn FnOnce() + Send + 'static>;

/// `spawn_call` with the thread start passed in, so a test can make it fail.
/// `start` drops the job when it cannot run it, as `thread::Builder::spawn`
/// does.
fn spawn_call_on(text: String, calls: &Calls, start: impl FnOnce(CallJob) -> std::io::Result<()>) {
    let text: Arc<str> = text.into();
    let frame = text.clone();
    let profile = calls.profile.to_string();
    let replies = calls.replies.clone();
    let cancel = calls.cancel.clone();
    calls.in_flight.fetch_add(1, Ordering::AcqRel);
    let running = InFlight(calls.in_flight.clone());
    let spawned = start(Box::new(move || {
        let _running = running;
        if let Some(reply) = answer_attached(&text, &profile, &cancel) {
            // A cancelled call's socket is gone; its reply goes nowhere.
            if !cancel.load(Ordering::Acquire) {
                let _ = replies.send(reply);
            }
        }
    }));
    if let Err(e) = spawned {
        eprintln!("attach: could not start a call thread: {e}");
        if let Some(reply) = spawn_failed_reply(&frame) {
            let _ = calls.replies.send(reply);
        }
    }
}

/// The JSON-RPC reply for a frame whose call thread could not start, the same
/// as `answer` would give where `answer` needs no thread: the envelope error
/// for a frame that does not parse, `None` for a notification, and an internal
/// error carrying the id for a request.
fn spawn_failed_reply(text: &str) -> Option<String> {
    let id = match parse_request(text) {
        Ok(req) => req.id?,
        Err((code, message)) => return Some(error_response(&Value::Null, code, &message)),
    };
    Some(error_response(
        &id,
        -32603,
        "node busy: could not start the call",
    ))
}

/// Bound how long one read on the attached socket blocks, on ws:// and wss://.
fn set_read_timeout(socket: &mut WebSocket<MaybeTlsStream<TcpStream>>, timeout: Duration) {
    let stream: &TcpStream = match socket.get_mut() {
        MaybeTlsStream::Plain(s) => s,
        MaybeTlsStream::Rustls(s) => &s.sock,
        _ => return,
    };
    let _ = stream.set_read_timeout(Some(timeout));
}

// Sleep min(backoff, remaining_to_deadline), checking DELETE cancellation every
// 100 ms; grow backoff. Returns false at deadline or cancellation.
fn sleep_until_backoff(
    deadline_epoch_secs: u64,
    backoff: &mut u64,
    cap: u64,
    cancelled: &AtomicBool,
) -> bool {
    let now = now_epoch_secs();
    if now >= deadline_epoch_secs || cancelled.load(Ordering::Acquire) {
        return false;
    }
    let remaining = deadline_epoch_secs - now;
    let nap = (*backoff).min(remaining);
    for _ in 0..nap.saturating_mul(10) {
        if cancelled.load(Ordering::Acquire) {
            return false;
        }
        thread::sleep(Duration::from_millis(100));
    }
    *backoff = (*backoff * 2).min(cap);
    now_epoch_secs() < deadline_epoch_secs && !cancelled.load(Ordering::Acquire)
}

fn build_ws_request(url: &str, secret: &str) -> Result<Request<()>, String> {
    use tungstenite::handshake::client::generate_key;

    // Determine host authority for the Host header.
    let after_scheme = url
        .strip_prefix("wss://")
        .or_else(|| url.strip_prefix("ws://"))
        .ok_or_else(|| "attach url missing ws scheme".to_string())?;
    let authority = match after_scheme.find('/') {
        Some(idx) => &after_scheme[..idx],
        None => after_scheme,
    };
    let host = authority
        .rsplit_once(':')
        .map(|(h, _)| h)
        .unwrap_or(authority);
    let _ = host;

    Request::builder()
        .method("GET")
        .uri(url)
        .header("Host", authority)
        .header("Connection", "Upgrade")
        .header("Upgrade", "websocket")
        .header("Sec-WebSocket-Version", "13")
        .header("Sec-WebSocket-Key", generate_key())
        .header("Authorization", format!("Bearer {secret}"))
        .body(())
        .map_err(|e| format!("failed to build request: {e}"))
}

// Extract an HTTP status code from a tungstenite handshake error, if present.
fn handshake_status(err: &tungstenite::Error) -> Option<u16> {
    match err {
        tungstenite::Error::Http(resp) => Some(resp.status().as_u16()),
        _ => None,
    }
}

#[cfg(test)]
#[path = "client_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "mint_tests.rs"]
mod mint_tests;

#[cfg(test)]
#[path = "liveness_tests.rs"]
mod liveness_tests;

// ---------------------------------------------------------------------------
