//! `mint` against local fake runtimes on loopback ephemeral ports. The TLS ones present a
//! certificate signed by a throwaway CA generated in memory with `rcgen`, and the client
//! trusts exactly that CA through the test-only `MintTrust::with_root_der`. Nothing a
//! production process reads (environment, files) can select that trust.

use std::io::{Read, Write};
use std::net::{IpAddr, Ipv4Addr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use rcgen::{BasicConstraints, CertificateParams, DnType, IsCa, KeyPair, KeyUsagePurpose, SanType};
use rustls::pki_types::{CertificateDer, PrivateKeyDer};

use super::{mint_with, MintTrust};

const CRED: &str = "adm-9f3c-SECRET-credential";

/// A throwaway CA and one leaf it signed, generated in memory with `rcgen` (pure Rust, no
/// `openssl` command line tool). Test only: the keys exist for the life of one test.
struct Pki {
    ca_der: Vec<u8>,
    cert_der: Vec<u8>,
    key_der: Vec<u8>,
}

/// A fresh CA and a leaf for 127.0.0.1 signed by it.
fn pki() -> Pki {
    pki_for(SanType::IpAddress(IpAddr::V4(Ipv4Addr::LOCALHOST)))
}

/// A fresh CA and a leaf carrying only the given subject alternative name.
fn pki_for(san: SanType) -> Pki {
    let ca_key = KeyPair::generate().unwrap();
    let mut ca_params = CertificateParams::new(Vec::new()).unwrap();
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    ca_params.key_usages = vec![KeyUsagePurpose::KeyCertSign];
    ca_params
        .distinguished_name
        .push(DnType::CommonName, "oab-mint-test-ca");
    let ca = ca_params.self_signed(&ca_key).unwrap();

    let key = KeyPair::generate().unwrap();
    let mut params = CertificateParams::new(Vec::new()).unwrap();
    params.subject_alt_names = vec![san];
    params
        .distinguished_name
        .push(DnType::CommonName, "oab-mint-test");
    let cert = params.signed_by(&key, &ca, &ca_key).unwrap();
    Pki {
        ca_der: ca.der().to_vec(),
        cert_der: cert.der().to_vec(),
        key_der: key.serialize_der(),
    }
}

struct Fake {
    port: u16,
    seen: Arc<Mutex<Vec<String>>>,
    stop: Arc<AtomicBool>,
    handle: Option<thread::JoinHandle<()>>,
}

impl Fake {
    fn requests(&self) -> Vec<String> {
        self.seen.lock().unwrap().clone()
    }
}

impl Drop for Fake {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

/// Reads one request (headers plus Content-Length body), at most 64 KiB.
fn read_request(stream: &mut dyn Read) -> Option<String> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 1024];
    loop {
        let n = stream.read(&mut chunk).ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&buf[..end]).to_string();
            let want = head
                .lines()
                .find_map(|l| {
                    l.to_ascii_lowercase()
                        .strip_prefix("content-length:")
                        .and_then(|v| v.trim().parse::<usize>().ok())
                })
                .unwrap_or(0);
            while buf.len() < end + 4 + want {
                let n = stream.read(&mut chunk).ok()?;
                if n == 0 {
                    break;
                }
                buf.extend_from_slice(&chunk[..n]);
            }
            return Some(String::from_utf8_lossy(&buf).to_string());
        }
        if buf.len() > 65536 {
            return None;
        }
    }
}

/// Serves `reply(request)` bytes to every connection, over TLS when `pki` is given.
fn fake(pki: Option<&Pki>, reply: impl Fn(&str) -> Vec<u8> + Send + 'static) -> Fake {
    let tls = pki.map(|p| {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        Arc::new(
            rustls::ServerConfig::builder_with_provider(provider)
                .with_safe_default_protocol_versions()
                .unwrap()
                .with_no_client_auth()
                .with_single_cert(
                    vec![CertificateDer::from(p.cert_der.clone())],
                    PrivateKeyDer::try_from(p.key_der.clone()).unwrap(),
                )
                .unwrap(),
        )
    });
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let port = listener.local_addr().unwrap().port();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let stop = Arc::new(AtomicBool::new(false));
    let (seen2, stop2) = (seen.clone(), stop.clone());
    let handle = thread::spawn(move || {
        while !stop2.load(Ordering::Acquire) {
            let tcp: TcpStream = match listener.accept() {
                Ok((s, _)) => s,
                Err(_) => {
                    thread::sleep(Duration::from_millis(10));
                    continue;
                }
            };
            tcp.set_nonblocking(false).unwrap();
            tcp.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            tcp.set_write_timeout(Some(Duration::from_secs(5))).unwrap();
            let serve = |io: &mut dyn ReadWrite| {
                if let Some(req) = read_request(io.as_read()) {
                    let out = reply(&req);
                    seen2.lock().unwrap().push(req);
                    let _ = io.as_write().write_all(&out);
                    let _ = io.as_write().flush();
                }
            };
            match &tls {
                Some(cfg) => {
                    let conn = rustls::ServerConnection::new(cfg.clone()).unwrap();
                    let mut s = rustls::StreamOwned::new(conn, tcp);
                    serve(&mut s);
                    s.conn.send_close_notify();
                    let _ = s.flush();
                }
                None => {
                    let mut s = tcp;
                    serve(&mut s);
                }
            }
        }
    });
    Fake {
        port,
        seen,
        stop,
        handle: Some(handle),
    }
}

trait ReadWrite {
    fn as_read(&mut self) -> &mut dyn Read;
    fn as_write(&mut self) -> &mut dyn Write;
}
impl<T: Read + Write> ReadWrite for T {
    fn as_read(&mut self) -> &mut dyn Read {
        self
    }
    fn as_write(&mut self) -> &mut dyn Write {
        self
    }
}

fn http(status: &str, extra: &str, body: &[u8]) -> Vec<u8> {
    let mut out = format!(
        "HTTP/1.1 {status}\r\n{extra}Content-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )
    .into_bytes();
    out.extend_from_slice(body);
    out
}

const OK_BODY: &[u8] = br#"{"secret":"attach-secret-1","expires_in_secs":600}"#;

fn ok_reply(_: &str) -> Vec<u8> {
    http("200 OK", "Content-Type: application/json\r\n", OK_BODY)
}

fn trust_for(p: &Pki) -> MintTrust {
    MintTrust::with_root_der(&p.ca_der)
}

fn assert_no_credential(text: &str) {
    assert!(!text.contains(CRED), "credential leaked into: {text}");
}

#[test]
fn wss_mint_succeeds_and_sends_the_contract_request() {
    let p = pki();
    let server = fake(Some(&p), ok_reply);
    let runtime = format!("wss://127.0.0.1:{}", server.port);
    let got = mint_with(&trust_for(&p), &runtime, "sess-1", CRED, 300).expect("wss mint");
    assert_eq!(got, ("attach-secret-1".to_string(), 600));
    let reqs = server.requests();
    assert_eq!(reqs.len(), 1);
    let r = &reqs[0];
    assert!(r.starts_with("POST /admin/sessions/sess-1/tools-attach HTTP/1.1\r\n"));
    assert!(
        r.contains(&format!("authorization: Bearer {CRED}\r\n"))
            || r.contains(&format!("Authorization: Bearer {CRED}\r\n"))
    );
    assert!(r.ends_with(r#"{"ttl_secs":300}"#), "{r}");
}

#[test]
fn wss_mint_keeps_a_runtime_path_prefix_and_trailing_slash() {
    let p = pki();
    let server = fake(Some(&p), ok_reply);
    let runtime = format!("wss://127.0.0.1:{}/pod-a/", server.port);
    mint_with(&trust_for(&p), &runtime, "s", CRED, 60).expect("wss mint");
    assert!(server.requests()[0].starts_with("POST /pod-a/admin/sessions/s/tools-attach "));
}

#[test]
fn a_certificate_the_client_does_not_trust_is_refused() {
    let trusted = pki();
    let served = pki();
    let server = fake(Some(&served), ok_reply);
    let runtime = format!("wss://127.0.0.1:{}", server.port);
    let err = mint_with(&trust_for(&trusted), &runtime, "s", CRED, 60).unwrap_err();
    assert!(err.contains("certificate"), "{err}");
    assert!(err.contains("127.0.0.1"), "{err}");
    assert_no_credential(&err);
    assert!(
        server.requests().is_empty(),
        "the request went out over an unverified connection"
    );
}

#[test]
fn a_certificate_for_another_host_from_a_trusted_root_is_refused() {
    // Chains to the trusted CA, but names 127.0.0.2 and a DNS name, not the 127.0.0.1 dialed.
    for san in [
        SanType::IpAddress(IpAddr::V4(Ipv4Addr::new(127, 0, 0, 2))),
        SanType::DnsName("wrong.invalid".try_into().unwrap()),
    ] {
        let p = pki_for(san);
        let server = fake(Some(&p), ok_reply);
        let runtime = format!("wss://127.0.0.1:{}", server.port);
        let err = mint_with(&trust_for(&p), &runtime, "s", CRED, 60).unwrap_err();
        assert!(err.contains("certificate"), "{err}");
        assert_no_credential(&err);
        assert!(
            server.requests().is_empty(),
            "the request went out to a host the certificate does not name"
        );
    }
}

#[test]
fn wss_to_a_plaintext_server_fails_without_sending_the_credential() {
    let p = pki();
    let server = fake(None, ok_reply);
    let runtime = format!("wss://127.0.0.1:{}", server.port);
    let err = mint_with(&trust_for(&p), &runtime, "s", CRED, 60).unwrap_err();
    assert_no_credential(&err);
    assert!(server.requests().is_empty());
}

#[test]
fn a_redirect_to_another_host_is_refused_and_not_followed() {
    let p = pki();
    let elsewhere = fake(Some(&p), ok_reply);
    let target = format!("https://127.0.0.1:{}/steal", elsewhere.port);
    for status in [
        "301 Moved Permanently",
        "302 Found",
        "307 Temporary Redirect",
    ] {
        let location = format!("Location: {target}\r\n");
        let server = fake(Some(&p), {
            let status = status.to_string();
            move |_| http(&status, &location, b"")
        });
        let runtime = format!("wss://127.0.0.1:{}", server.port);
        let err = mint_with(&trust_for(&p), &runtime, "s", CRED, 60).unwrap_err();
        assert!(err.contains("redirect"), "{status}: {err}");
        assert_no_credential(&err);
        assert_eq!(server.requests().len(), 1);
    }
    assert!(
        elsewhere.requests().is_empty(),
        "a redirect target received a request"
    );
}

#[test]
fn a_redirect_from_a_plain_http_runtime_is_refused_too() {
    let p = pki();
    let elsewhere = fake(None, ok_reply);
    let location = format!("Location: http://127.0.0.1:{}/x\r\n", elsewhere.port);
    let server = fake(None, move |_| http("302 Found", &location, b""));
    let runtime = format!("ws://127.0.0.1:{}", server.port);
    let err = mint_with(&trust_for(&p), &runtime, "s", CRED, 60).unwrap_err();
    assert!(err.contains("redirect"), "{err}");
    assert!(elsewhere.requests().is_empty());
}

#[test]
fn an_oversized_response_is_refused() {
    let p = pki();
    let big = vec![b'x'; 1024 * 1024];
    let server = fake(Some(&p), move |_| http("200 OK", "", &big));
    let runtime = format!("wss://127.0.0.1:{}", server.port);
    let err = mint_with(&trust_for(&p), &runtime, "s", CRED, 60).unwrap_err();
    assert!(err.contains("exceeds"), "{err}");
    assert_no_credential(&err);
}

#[test]
fn an_oversized_plain_http_response_is_refused() {
    let p = pki();
    let big = vec![b'x'; 1024 * 1024];
    let server = fake(None, move |_| http("200 OK", "", &big));
    let runtime = format!("ws://127.0.0.1:{}", server.port);
    let err = mint_with(&trust_for(&p), &runtime, "s", CRED, 60).unwrap_err();
    assert!(err.contains("exceeds"), "{err}");
}

#[test]
fn the_credential_never_appears_in_an_error_even_when_the_runtime_echoes_it() {
    let p = pki();
    let echo = |req: &str| {
        let line = req
            .lines()
            .find(|l| l.to_ascii_lowercase().starts_with("authorization:"))
            .unwrap_or("")
            .to_string();
        http("401 Unauthorized", "", format!("bad {line}").as_bytes())
    };
    let tls = fake(Some(&p), echo);
    let err = mint_with(
        &trust_for(&p),
        &format!("wss://127.0.0.1:{}", tls.port),
        "s",
        CRED,
        60,
    )
    .unwrap_err();
    assert!(err.starts_with("mint HTTP 401: "), "{err}");
    assert_no_credential(&err);

    let plain = fake(None, echo);
    let err = mint_with(
        &trust_for(&p),
        &format!("ws://127.0.0.1:{}", plain.port),
        "s",
        CRED,
        60,
    )
    .unwrap_err();
    assert_no_credential(&err);

    // Echoed in a 2xx body that then fails to parse.
    let junk = fake(Some(&p), |req: &str| {
        http("200 OK", "", format!("{{\"secret\": {req:?} ").as_bytes())
    });
    let err = mint_with(
        &trust_for(&p),
        &format!("wss://127.0.0.1:{}", junk.port),
        "s",
        CRED,
        60,
    )
    .unwrap_err();
    assert_no_credential(&err);

    // Refused connection and malformed runtimes.
    let closed = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = closed.local_addr().unwrap().port();
    drop(closed);
    for runtime in [
        format!("wss://127.0.0.1:{port}"),
        format!("ws://127.0.0.1:{port}"),
        format!("wss://{CRED}@127.0.0.1:{port}"),
        format!("wss://127.0.0.1:{port}/?k={CRED}"),
    ] {
        let err = mint_with(&trust_for(&p), &runtime, "s", CRED, 60).unwrap_err();
        assert_no_credential(&err);
    }
}

fn json_escape_all(text: &str) -> String {
    text.chars()
        .map(|c| format!("\\u{:04x}", c as u32))
        .collect()
}

#[test]
fn a_json_escaped_credential_is_refused_as_secret_and_not_echoed_in_errors() {
    let p = pki();
    let esc = json_escape_all(CRED);
    let body = format!("{{\"secret\":\"{esc}\"}}");
    let ok = fake(Some(&p), move |_| http("200 OK", "", body.as_bytes()));
    let err = mint_with(
        &trust_for(&p),
        &format!("wss://127.0.0.1:{}", ok.port),
        "s",
        CRED,
        60,
    )
    .unwrap_err();
    assert!(err.contains("refused"), "{err}");
    assert_no_credential(&err);

    let body = format!("{{\"secret\":\"pre-{esc}\"}}");
    let sub = fake(None, move |_| http("200 OK", "", body.as_bytes()));
    let err = mint_with(
        &trust_for(&p),
        &format!("ws://127.0.0.1:{}", sub.port),
        "s",
        CRED,
        60,
    )
    .unwrap_err();
    assert!(err.contains("refused"), "{err}");

    let body = format!("{{\"error\":\"{esc}\"}} {}", CRED.replace('-', "%2D"));
    let bad = fake(Some(&p), move |_| {
        http("400 Bad Request", "", body.as_bytes())
    });
    let err = mint_with(
        &trust_for(&p),
        &format!("wss://127.0.0.1:{}", bad.port),
        "s",
        CRED,
        60,
    )
    .unwrap_err();
    assert_eq!(err, "mint HTTP 400: the runtime refused the request");
    assert!(!err.contains(&esc), "{err}");
}

#[test]
fn a_credential_inside_the_runtime_or_session_is_refused_before_any_request() {
    // The runtime and session are persisted in grants.json, so a credential embedded in
    // either must never reach a request, a grant or an error string.
    let p = pki();
    let server = fake(None, ok_reply);
    for (runtime, session) in [
        (format!("ws://{CRED}.invalid:9"), "s".to_string()),
        (format!("wss://{CRED}.invalid:9"), "s".to_string()),
        (
            format!("ws://127.0.0.1:{}/{CRED}", server.port),
            "s".to_string(),
        ),
        (
            format!("ws://127.0.0.1:{}", server.port),
            format!("x{CRED}"),
        ),
    ] {
        let err = mint_with(&trust_for(&p), &runtime, &session, CRED, 60).unwrap_err();
        assert!(err.contains("must not contain"), "{err}");
        assert_no_credential(&err);
    }
    assert!(server.requests().is_empty());

    // A credential that is not part of the connected address still mints and is redacted
    // from an oversized-response error.
    let big = vec![b'x'; 1024 * 1024];
    let big_server = fake(Some(&p), move |_| http("200 OK", "", &big));
    let err = mint_with(
        &trust_for(&p),
        &format!("wss://127.0.0.1:{}", big_server.port),
        "s",
        CRED,
        60,
    )
    .unwrap_err();
    assert!(err.contains("exceeds"), "{err}");
    assert_no_credential(&err);
}

#[test]
fn a_credential_with_a_control_character_is_refused_before_any_request() {
    let server = fake(None, ok_reply);
    let runtime = format!("ws://127.0.0.1:{}", server.port);
    let p = pki();
    let err = mint_with(&trust_for(&p), &runtime, "s", "a\r\nX-Evil: 1", 60).unwrap_err();
    assert!(err.contains("control character"), "{err}");
    assert!(server.requests().is_empty());
}

#[test]
fn plain_http_behaviour_is_unchanged() {
    let p = pki();
    let server = fake(None, ok_reply);
    let runtime = format!("ws://127.0.0.1:{}/", server.port);
    let got = mint_with(&trust_for(&p), &runtime, "sess-2", CRED, 120).expect("ws mint");
    assert_eq!(got, ("attach-secret-1".to_string(), 600));
    let r = &server.requests()[0];
    assert!(r.starts_with("POST /admin/sessions/sess-2/tools-attach HTTP/1.1\r\n"));
    assert!(r.ends_with(r#"{"ttl_secs":120}"#));

    let denied = fake(None, |_| http("403 Forbidden", "", b" nope \n"));
    let err = mint_with(
        &trust_for(&p),
        &format!("ws://127.0.0.1:{}", denied.port),
        "s",
        CRED,
        60,
    )
    .unwrap_err();
    assert_eq!(
        err,
        "mint HTTP 403: the runtime refused the admin credential"
    );

    let no_secret = fake(None, |_| http("200 OK", "", b"{}"));
    let err = mint_with(
        &trust_for(&p),
        &format!("ws://127.0.0.1:{}", no_secret.port),
        "s",
        CRED,
        60,
    )
    .unwrap_err();
    assert_eq!(err, "mint response missing secret");

    // expires_in_secs defaults to the requested ttl.
    let bare = fake(None, |_| http("200 OK", "", br#"{"secret":"z"}"#));
    let got = mint_with(
        &trust_for(&p),
        &format!("ws://127.0.0.1:{}", bare.port),
        "s",
        CRED,
        77,
    )
    .unwrap();
    assert_eq!(got, ("z".to_string(), 77));
}

#[test]
fn only_ws_and_wss_runtimes_are_accepted() {
    let p = pki();
    for runtime in [
        "http://127.0.0.1:1",
        "https://127.0.0.1:1",
        "127.0.0.1:1",
        "",
    ] {
        let err = mint_with(&trust_for(&p), runtime, "s", CRED, 60).unwrap_err();
        assert!(err.contains("unsupported runtime scheme"), "{err}");
    }
}

#[test]
fn wss_mint_accepts_a_percent_encoded_runtime_prefix() {
    // A valid percent-encoded path prefix is sent as written, not refused.
    let p = pki();
    let server = fake(Some(&p), ok_reply);
    let runtime = format!("wss://127.0.0.1:{}/pod%20a", server.port);
    mint_with(&trust_for(&p), &runtime, "s", CRED, 60).expect("wss mint with %20 prefix");
    assert!(server.requests()[0].starts_with("POST /pod%20a/admin/sessions/s/tools-attach "));
}

#[test]
fn a_percent_encoded_credential_inside_the_runtime_is_refused_before_any_request() {
    // The runtime is persisted in grants.json, so the credential must be caught in its
    // decoded form too.
    let p = pki();
    let server = fake(None, ok_reply);
    let encoded: String = CRED.bytes().map(|b| format!("%{b:02X}")).collect();
    let runtime = format!("ws://127.0.0.1:{}/{encoded}", server.port);
    let err = mint_with(&trust_for(&p), &runtime, "s", CRED, 60).unwrap_err();
    assert!(err.contains("must not contain"), "{err}");
    assert_no_credential(&err);
    assert!(server.requests().is_empty());
}

#[test]
fn a_malformed_or_smuggling_percent_escape_in_the_runtime_is_refused() {
    let p = pki();
    let server = fake(None, ok_reply);
    for runtime in [
        format!("ws://127.0.0.1:{}/pod%zz", server.port),
        format!("ws://127.0.0.1:{}/pod%2", server.port),
        format!("ws://127.0.0.1:{}/pod%40evil", server.port),
        format!("ws://127.0.0.1:{}/pod%3Fq", server.port),
        format!("ws://127.0.0.1:{}/pod%00", server.port),
        format!("ws://127.0.0.1%3A{}", server.port),
    ] {
        let err = mint_with(&trust_for(&p), &runtime, "s", CRED, 60).unwrap_err();
        assert!(err.contains("no user info, query or fragment"), "{err}");
    }
    assert!(server.requests().is_empty());
}
