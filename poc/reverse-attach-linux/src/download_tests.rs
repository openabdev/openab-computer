//! The downloader against a fake server bound to 127.0.0.1 (tests only, plain HTTP, one thread per
//! connection). The production TLS stack is covered by the `#[ignore]` real-pin check at the end.
//! Every failure row asserts that neither the `.part` file nor the final name is left behind.

use super::*;
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};

struct Shared {
    body: Vec<u8>,
    port: u16,
    other_port: u16,
    hits: Mutex<HashMap<String, u32>>,
    headers: Mutex<Vec<(String, String)>>,
    conns: AtomicU32,
    sent: AtomicU64,
}

struct FakeServer {
    shared: Arc<Shared>,
    stop: Arc<AtomicBool>,
    accept: Option<JoinHandle<()>>,
}

fn send(s: &mut TcpStream, head: &str, body: &[u8]) -> bool {
    s.write_all(head.as_bytes()).is_ok() && s.write_all(body).is_ok()
}

fn serve(shared: &Shared, mut s: TcpStream) {
    s.set_nonblocking(false).ok();
    s.set_read_timeout(Some(Duration::from_secs(5))).ok();
    let mut r = BufReader::new(s.try_clone().unwrap());
    let mut line = String::new();
    if r.read_line(&mut line).is_err() {
        return;
    }
    let target = line.split_whitespace().nth(1).unwrap_or("/").to_string();
    loop {
        let mut h = String::new();
        if r.read_line(&mut h).is_err() || h == "\r\n" || h.is_empty() {
            break;
        }
        if let Some((k, v)) = h.trim_end().split_once(':') {
            shared
                .headers
                .lock()
                .unwrap()
                .push((k.to_ascii_lowercase(), v.trim().to_string()));
        }
    }
    let path = target.split('?').next().unwrap_or("/").to_string();
    *shared.hits.lock().unwrap().entry(path.clone()).or_default() += 1;
    let body = &shared.body;
    let n = body.len();
    let ok = |len: usize| {
        format!("HTTP/1.1 200 OK\r\nContent-Length: {len}\r\nConnection: close\r\n\r\n")
    };
    let redirect = |code: u16, to: &str| {
        format!("HTTP/1.1 {code} Moved\r\nLocation: {to}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    };
    let (port, other) = (shared.port, shared.other_port);
    match path.as_str() {
        "/ok" => {
            send(&mut s, &ok(n), body);
        }
        "/corrupt" => {
            let mut b = body.clone();
            b[0] ^= 0xFF;
            send(&mut s, &ok(n), &b);
        }
        "/short" => {
            send(&mut s, &ok(n), &body[..n / 2]);
        }
        "/extra" => {
            let mut b = body.clone();
            b.extend_from_slice(&[b'x'; 5000]);
            send(&mut s, &ok(n), &b);
        }
        "/lie" => {
            send(&mut s, &ok(n / 2), body);
        }
        "/big" => {
            send(&mut s, &ok(n + 1), &body[..10]);
        }
        "/nolen" => {
            if !send(
                &mut s,
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
                b"",
            ) {
                return;
            }
            let chunk = vec![b'z'; 16 * 1024];
            while shared.sent.load(Ordering::SeqCst) < 64 << 20 {
                let ok = s
                    .write_all(format!("{:x}\r\n", chunk.len()).as_bytes())
                    .is_ok()
                    && s.write_all(&chunk).is_ok()
                    && s.write_all(b"\r\n").is_ok();
                if !ok {
                    return;
                }
                shared.sent.fetch_add(chunk.len() as u64, Ordering::SeqCst);
            }
        }
        "/slow" => {
            if !send(&mut s, &ok(n), b"") {
                return;
            }
            for b in body {
                if s.write_all(&[*b]).is_err() {
                    return;
                }
                thread::sleep(Duration::from_millis(40));
            }
        }
        "/gzip" => {
            send(&mut s, &format!("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: {n}\r\nConnection: close\r\n\r\n"), body);
        }
        "/redir-allowed" => {
            send(
                &mut s,
                &redirect(302, &format!("http://127.0.0.1:{port}/ok")),
                b"",
            );
        }
        "/redir-twice" => {
            send(&mut s, &redirect(301, "/redir-allowed"), b"");
        }
        "/redir-rel" => {
            send(&mut s, &redirect(301, "/ok"), b"");
        }
        "/redir-rel2" => {
            send(&mut s, &redirect(307, "ok"), b"");
        }
        "/redir-other" => {
            send(
                &mut s,
                &redirect(302, &format!("http://localhost:{other}/ok")),
                b"",
            );
        }
        "/redir-loop" => {
            send(&mut s, &redirect(302, "/redir-loop"), b"");
        }
        "/redir-noloc" => {
            send(
                &mut s,
                "HTTP/1.1 302 Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                b"",
            );
        }
        "/redir-userinfo" => {
            send(
                &mut s,
                &redirect(302, &format!("http://user@127.0.0.1:{port}/ok")),
                b"",
            );
        }
        "/redir-dotdot" => {
            send(&mut s, &redirect(302, "/a/../ok"), b"");
        }
        "/redir-off-list-https" => {
            send(&mut s, &redirect(302, "https://example.invalid/ok"), b"");
        }
        "/redir-ftp" => {
            send(&mut s, &redirect(302, "ftp://127.0.0.1/ok"), b"");
        }
        "/redir-scheme-relative" => {
            send(
                &mut s,
                &redirect(302, &format!("//localhost:{other}/ok")),
                b"",
            );
        }
        "/hop1" | "/hop2" | "/hop3" => {
            // Each hop is slow on its own; only the sum of them breaks the operation deadline.
            thread::sleep(Duration::from_millis(300));
            let next = match path.as_str() {
                "/hop1" => "/hop2",
                "/hop2" => "/hop3",
                _ => "/ok",
            };
            send(&mut s, &redirect(302, next), b"");
        }
        "/status404" => {
            send(
                &mut s,
                "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                b"",
            );
        }
        "/status500" => {
            let b = b"canary-body-secret";
            send(
                &mut s,
                &format!(
                    "HTTP/1.1 500 Oops\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    b.len()
                ),
                b,
            );
        }
        _ => {
            send(
                &mut s,
                "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                b"",
            );
        }
    }
    let _ = s.flush();
}

impl FakeServer {
    fn start(body: Vec<u8>, other_port: u16) -> FakeServer {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        l.set_nonblocking(true).unwrap();
        let port = l.local_addr().unwrap().port();
        let shared = Arc::new(Shared {
            body,
            port,
            other_port,
            hits: Mutex::default(),
            headers: Mutex::default(),
            conns: AtomicU32::new(0),
            sent: AtomicU64::new(0),
        });
        let stop = Arc::new(AtomicBool::new(false));
        let (sh, st) = (shared.clone(), stop.clone());
        let accept = thread::spawn(move || {
            let mut workers: Vec<JoinHandle<()>> = Vec::new();
            while !st.load(Ordering::SeqCst) {
                match l.accept() {
                    Ok((s, _)) => {
                        sh.conns.fetch_add(1, Ordering::SeqCst);
                        let sh2 = sh.clone();
                        workers.push(thread::spawn(move || serve(&sh2, s)));
                    }
                    Err(_) => thread::sleep(Duration::from_millis(2)),
                }
            }
            for w in workers {
                let _ = w.join();
            }
        });
        FakeServer {
            shared,
            stop,
            accept: Some(accept),
        }
    }
    fn port(&self) -> u16 {
        self.shared.port
    }
    fn conns(&self) -> u32 {
        self.shared.conns.load(Ordering::SeqCst)
    }
    fn hits(&self, path: &str) -> u32 {
        self.shared
            .hits
            .lock()
            .unwrap()
            .get(path)
            .copied()
            .unwrap_or(0)
    }
}

impl Drop for FakeServer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        // Workers end when the client closes or their read times out; the accept loop joins them.
        if let Some(h) = self.accept.take() {
            let _ = h.join();
        }
    }
}

struct Harness {
    srv: FakeServer,
    other: FakeServer,
    dir: PathBuf,
    sha: String,
}

impl Harness {
    fn new() -> Harness {
        static N: AtomicU32 = AtomicU32::new(0);
        let mut x: u32 = 0x1234_5678;
        let body: Vec<u8> = (0..300_000)
            .map(|_| {
                x = x.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                (x >> 24) as u8
            })
            .collect();
        let other = FakeServer::start(body.clone(), 0);
        let srv = FakeServer::start(body.clone(), other.port());
        let dir = std::env::temp_dir().join(format!(
            "oab-l1a-d-{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        Harness {
            sha: crate::manifest::sha256_hex(&body),
            srv,
            other,
            dir,
        }
    }
    fn size(&self) -> u64 {
        self.srv.shared.body.len() as u64
    }
    fn url(&self, path: &str) -> String {
        format!("http://127.0.0.1:{}{path}", self.srv.port())
    }
    fn limits() -> Limits {
        Limits {
            connect: Duration::from_secs(2),
            read: Duration::from_secs(5),
            total: Duration::from_secs(20),
            max_redirects: 3,
        }
    }
    fn get(&self, path: &str) -> Result<VerifiedArtifact, DownloadError> {
        self.get_with(path, &Harness::limits(), self.size(), &self.sha)
    }
    fn get_with(
        &self,
        path: &str,
        limits: &Limits,
        size: u64,
        sha: &str,
    ) -> Result<VerifiedArtifact, DownloadError> {
        let url = self.url(path);
        let pin = Pin {
            url: &url,
            size,
            sha256: sha,
        };
        fetch(
            &DownloadPolicy::for_tests(&["127.0.0.1"]),
            &pin,
            &self.dir,
            "artifact.bin",
            limits,
            &mut |_| {},
        )
    }
    /// Nothing at all is left in the directory: no final name, no `.part`.
    fn clean(&self) -> bool {
        fs::read_dir(&self.dir).unwrap().count() == 0
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn fails(path: &str, want: DownloadError) {
    let h = Harness::new();
    assert_eq!(h.get(path).unwrap_err(), want, "{path}");
    assert!(h.clean(), "{path} left files behind");
}

// ---- success --------------------------------------------------------------------------------

#[test]
fn a_correct_download_is_verified_and_private() {
    let h = Harness::new();
    let mut last = 0;
    let url = h.url("/ok");
    let pin = Pin {
        url: &url,
        size: h.size(),
        sha256: &h.sha,
    };
    let v = fetch(
        &DownloadPolicy::for_tests(&["127.0.0.1"]),
        &pin,
        &h.dir,
        "artifact.bin",
        &Harness::limits(),
        &mut |n| last = n,
    )
    .unwrap();
    assert_eq!(fs::read(v.path()).unwrap(), h.srv.shared.body);
    assert_eq!(
        fs::metadata(v.path()).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!((v.size(), v.sha256_hex()), (h.size(), h.sha.clone()));
    assert_eq!(last, h.size());
    let names: Vec<_> = fs::read_dir(&h.dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    assert_eq!(names, vec!["artifact.bin"], "no .part left");
    // Bytes the server sends past its declared length are never read.
    assert!(h
        .get_with("/extra", &Harness::limits(), h.size(), &h.sha)
        .is_ok());
}

// ---- size and digest ------------------------------------------------------------------------

#[test]
fn size_digest_and_length_failures() {
    fails("/corrupt", DownloadError::DigestMismatch);
    fails("/short", DownloadError::SizeMismatch);
    fails("/lie", DownloadError::SizeMismatch);
    fails("/big", DownloadError::TooLarge);
    // The pin is smaller than what the server really sends: declared length over the pin.
    let h = Harness::new();
    assert_eq!(
        h.get_with("/ok", &Harness::limits(), h.size() - 1, &h.sha)
            .unwrap_err(),
        DownloadError::TooLarge
    );
    assert!(h.clean());
    // The pin is larger than the body: a short body.
    assert_eq!(
        h.get_with("/ok", &Harness::limits(), h.size() + 1, &h.sha)
            .unwrap_err(),
        DownloadError::SizeMismatch
    );
    assert!(h.clean());
    // Wrong digest with the right size.
    assert_eq!(
        h.get_with("/ok", &Harness::limits(), h.size(), &"0".repeat(64))
            .unwrap_err(),
        DownloadError::DigestMismatch
    );
    assert!(h.clean());
}

#[test]
fn an_endless_body_with_no_length_stops_at_the_pinned_size() {
    let h = Harness::new();
    assert_eq!(h.get("/nolen").unwrap_err(), DownloadError::TooLarge);
    assert!(h.clean());
    // The client closed early: the server noticed well before its 64 MiB budget ran out (what it
    // wrote past the pin is socket buffer, which differs per kernel).
    thread::sleep(Duration::from_millis(200));
    let sent = h.srv.shared.sent.load(Ordering::SeqCst);
    assert!(sent < 32 << 20, "server wrote {sent} bytes");
}

#[test]
fn a_content_encoding_is_refused() {
    fails("/gzip", DownloadError::Encoding);
}

#[test]
fn statuses_other_than_200() {
    fails("/status404", DownloadError::Status);
    fails("/status500", DownloadError::Status);
    fails("/redir-noloc", DownloadError::Redirect);
}

// ---- redirects ------------------------------------------------------------------------------

#[test]
fn redirects_to_the_allowed_host_are_followed() {
    for p in [
        "/redir-allowed",
        "/redir-rel",
        "/redir-rel2",
        "/redir-twice",
    ] {
        let h = Harness::new();
        assert!(h.get(p).is_ok(), "{p}");
        assert!(h.srv.hits("/ok") >= 1, "{p}");
    }
    let h = Harness::new();
    h.get("/redir-twice").unwrap();
    assert_eq!(
        (
            h.srv.hits("/redir-twice"),
            h.srv.hits("/redir-allowed"),
            h.srv.hits("/ok")
        ),
        (1, 1, 1)
    );
}

#[test]
fn a_redirect_off_the_allowlist_is_refused_before_any_connection() {
    for p in [
        "/redir-other",
        "/redir-scheme-relative",
        "/redir-off-list-https",
        "/redir-userinfo",
        "/redir-dotdot",
        "/redir-ftp",
    ] {
        let h = Harness::new();
        assert_eq!(h.get(p).unwrap_err(), DownloadError::Policy, "{p}");
        assert_eq!(
            h.other.conns(),
            0,
            "{p}: the other host must not see a connection"
        );
        assert_eq!(h.srv.hits("/ok"), 0, "{p}");
        assert!(h.clean(), "{p}");
    }
}

#[test]
fn redirect_loops_and_chains_are_capped() {
    let h = Harness::new();
    assert_eq!(h.get("/redir-loop").unwrap_err(), DownloadError::Redirect);
    assert_eq!(
        h.srv.hits("/redir-loop"),
        4,
        "first request plus three hops"
    );
    assert!(h.clean());
    // A cap of one is too small for a two-hop chain.
    let h = Harness::new();
    let l = Limits {
        max_redirects: 1,
        ..Harness::limits()
    };
    assert_eq!(
        h.get_with("/redir-twice", &l, h.size(), &h.sha)
            .unwrap_err(),
        DownloadError::Redirect
    );
    assert!(h.clean());
}

#[test]
fn next_hop_refuses_downgrades_and_off_list_hosts() {
    let p = DownloadPolicy::for_tests(&["nodejs.org", "127.0.0.1"]);
    let cur = parse_url("https://nodejs.org/dist/v1/a.tar.gz").unwrap();
    let hop = |loc: Option<&str>| next_hop(&p, &cur, loc);
    assert_eq!(hop(Some("/x/y")).unwrap(), "https://nodejs.org/x/y");
    assert_eq!(
        hop(Some("b.tar.gz")).unwrap(),
        "https://nodejs.org/dist/v1/b.tar.gz"
    );
    assert_eq!(hop(Some("//nodejs.org/z")).unwrap(), "https://nodejs.org/z");
    assert_eq!(
        hop(Some("https://nodejs.org/q?a=1")).unwrap(),
        "https://nodejs.org/q?a=1"
    );
    for bad in [
        "http://nodejs.org/x",
        "http://127.0.0.1:1/x",
        "//evil.example/x",
        "https://evil.example/x",
        "https://nodejs.org/a/../b",
        "https://nodejs.org:8443/x",
        concat!("https://nodejs.org", "@evil.example/x"),
        "ftp://nodejs.org/x",
        "https://NODEJS.ORG/x",
    ] {
        assert_eq!(hop(Some(bad)), Err(DownloadError::Policy), "{bad}");
    }
    assert_eq!(hop(None), Err(DownloadError::Redirect));
    assert_eq!(hop(Some("")), Err(DownloadError::Redirect));
    // From plain loopback http the hop may stay on loopback, never leave the list.
    let lo = parse_url("http://127.0.0.1:9/x").unwrap();
    assert!(next_hop(&p, &lo, Some("/y")).is_ok());
    assert_eq!(
        next_hop(&p, &lo, Some("http://localhost:9/y")),
        Err(DownloadError::Policy)
    );
}

// ---- policy ---------------------------------------------------------------------------------

#[test]
fn policy_table() {
    let p = DownloadPolicy::for_tests(&["127.0.0.1", "nodejs.org"]);
    for ok in [
        "https://nodejs.org/dist/x",
        "https://nodejs.org:443/x",
        "http://127.0.0.1:8080/x",
        "https://nodejs.org/a..b/c",
    ] {
        assert!(p.permits(ok), "{ok}");
    }
    for bad in [
        "http://nodejs.org/x",
        "https://nodejs.org:8443/x",
        "https://NODEJS.ORG/x",
        "https://nodejs.org./x",
        "https://127.0.0.1.evil.example/x",
        concat!("https://user", "@nodejs.org/x"),
        "https://nodejs.org/a/../b",
        "https://nodejs.org/a/%2e%2e/b",
        "//nodejs.org/x",
        "ftp://nodejs.org/x",
        "https://nodejs.org\\@evil.example/x",
        "http://localhost:1/x",
        "https://evil.example/x",
        "http://127.0.0.1.evil.example/x",
        "",
    ] {
        assert!(!p.permits(bad), "{bad}");
    }
    let prod = DownloadPolicy::production(crate::manifest::Manifest::embedded());
    assert!(prod.permits("https://storage.googleapis.com/chrome-for-testing-public/x.zip"));
    assert!(prod.permits("https://nodejs.org/dist/v1/x.tar.gz"));
    assert!(
        !prod.permits("http://127.0.0.1:8080/x"),
        "loopback http is a test switch only"
    );
    assert!(!prod.permits("http://nodejs.org/x"));
    assert!(
        !prod.permits("https://cdn.playwright.dev/x"),
        "not listed in the shipped pins"
    );
}

#[test]
fn nothing_is_requested_for_a_url_the_policy_refuses() {
    let h = Harness::new();
    for u in [
        "http://example.invalid/x".to_string(),
        format!("https://127.0.0.1:{}/ok", h.srv.port()),
        format!("http://localhost:{}/ok", h.srv.port()),
    ] {
        let pin = Pin {
            url: &u,
            size: h.size(),
            sha256: &h.sha,
        };
        let r = fetch(
            &DownloadPolicy::for_tests(&["127.0.0.1"]),
            &pin,
            &h.dir,
            "artifact.bin",
            &Harness::limits(),
            &mut |_| {},
        );
        assert_eq!(r.unwrap_err(), DownloadError::Policy, "{u}");
    }
    assert_eq!(h.srv.conns(), 0);
    assert!(h.clean(), "not even a .part file");
    // The production policy refuses a plain http loopback URL outright.
    let u = h.url("/ok");
    let pin = Pin {
        url: &u,
        size: h.size(),
        sha256: &h.sha,
    };
    let prod = DownloadPolicy::production(crate::manifest::Manifest::embedded());
    assert_eq!(
        fetch(
            &prod,
            &pin,
            &h.dir,
            "artifact.bin",
            &Harness::limits(),
            &mut |_| {}
        )
        .unwrap_err(),
        DownloadError::Policy
    );
    assert_eq!(h.srv.conns(), 0);
}

// ---- time, network, environment -------------------------------------------------------------

#[test]
fn a_slow_body_ends_at_the_total_deadline() {
    let h = Harness::new();
    let l = Limits {
        total: Duration::from_millis(400),
        ..Harness::limits()
    };
    let t = Instant::now();
    assert_eq!(
        h.get_with("/slow", &l, h.size(), &h.sha).unwrap_err(),
        DownloadError::Timeout
    );
    assert!(t.elapsed() < Duration::from_secs(5));
    assert!(h.clean());
}

#[test]
fn the_deadline_covers_the_whole_redirect_chain_not_each_hop() {
    let h = Harness::new();
    let l = Limits {
        total: Duration::from_millis(700),
        max_redirects: 5,
        ..Harness::limits()
    };
    let t = Instant::now();
    // Three hops of 300 ms each fit in 700 ms one by one, but not together.
    assert_eq!(
        h.get_with("/hop1", &l, h.size(), &h.sha).unwrap_err(),
        DownloadError::Timeout
    );
    assert!(t.elapsed() < Duration::from_secs(4), "{:?}", t.elapsed());
    assert!(h.clean());
    // With room for all hops it still works.
    let ok = Limits {
        total: Duration::from_secs(20),
        max_redirects: 5,
        ..Harness::limits()
    };
    assert!(h.get_with("/hop1", &ok, h.size(), &h.sha).is_ok());
}

// ---- local files (--from-dir) ---------------------------------------------------------------

fn local_fixture(bytes: &[u8]) -> (PathBuf, PathBuf) {
    static N: AtomicU32 = AtomicU32::new(0);
    let base = std::env::temp_dir().join(format!(
        "oab-l1b-local-{}-{}",
        std::process::id(),
        N.fetch_add(1, Ordering::SeqCst)
    ));
    let _ = fs::remove_dir_all(&base);
    let (src, dst) = (base.join("src"), base.join("dst"));
    fs::create_dir_all(&src).unwrap();
    fs::create_dir_all(&dst).unwrap();
    fs::set_permissions(&dst, fs::Permissions::from_mode(0o700)).unwrap();
    fs::write(src.join("a.bin"), bytes).unwrap();
    (src, dst)
}

#[test]
fn a_local_file_is_hashed_while_copied_and_only_then_named() {
    let bytes: Vec<u8> = (0..200_000u32).map(|i| (i * 7 % 251) as u8).collect();
    let sha = crate::manifest::sha256_hex(&bytes);
    let (src, dst) = local_fixture(&bytes);
    let pin = |size: u64, sha: &str| (size, sha.to_string());
    let run = |name: &str, p: (u64, String)| {
        let url = "http://127.0.0.1/x";
        let pin = Pin {
            url,
            size: p.0,
            sha256: &p.1,
        };
        verify_local(&src, name, &pin, &dst, "out.bin", &mut |_| {})
    };
    let a = run("a.bin", pin(bytes.len() as u64, &sha)).unwrap();
    assert_eq!(a.size(), bytes.len() as u64);
    assert_eq!(a.sha256_hex(), sha);
    assert_eq!(fs::read(dst.join("out.bin")).unwrap(), bytes);
    assert_eq!(
        fs::metadata(dst.join("out.bin"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    fs::remove_file(dst.join("out.bin")).unwrap();

    for (what, name, p, want) in [
        (
            "digest",
            "a.bin",
            pin(bytes.len() as u64, &"0".repeat(64)),
            DownloadError::DigestMismatch,
        ),
        (
            "pinned smaller",
            "a.bin",
            pin(bytes.len() as u64 - 1, &sha),
            DownloadError::TooLarge,
        ),
        (
            "pinned larger",
            "a.bin",
            pin(bytes.len() as u64 + 1, &sha),
            DownloadError::SizeMismatch,
        ),
        ("missing", "none.bin", pin(1, &sha), DownloadError::Io),
        ("path in name", "../a.bin", pin(1, &sha), DownloadError::Io),
        ("dot name", ".a.bin", pin(1, &sha), DownloadError::Io),
    ] {
        assert_eq!(run(name, p).unwrap_err(), want, "{what}");
        assert_eq!(
            fs::read_dir(&dst).unwrap().count(),
            0,
            "{what}: nothing may be left behind"
        );
    }
    // A link, a directory and a FIFO are not read.
    std::os::unix::fs::symlink(src.join("a.bin"), src.join("link.bin")).unwrap();
    fs::create_dir(src.join("dir.bin")).unwrap();
    assert!(std::process::Command::new("mkfifo")
        .arg(src.join("fifo.bin"))
        .status()
        .unwrap()
        .success());
    for n in ["link.bin", "dir.bin", "fifo.bin"] {
        assert_eq!(
            run(n, pin(bytes.len() as u64, &sha)).unwrap_err(),
            DownloadError::Io,
            "{n}"
        );
    }
    // A source directory that is itself a link is refused.
    let linked = src.parent().unwrap().join("linked-src");
    std::os::unix::fs::symlink(&src, &linked).unwrap();
    let url = "http://127.0.0.1/x";
    let p = Pin {
        url,
        size: bytes.len() as u64,
        sha256: &sha,
    };
    assert!(verify_local(&linked, "a.bin", &p, &dst, "out.bin", &mut |_| {}).is_err());
    // A part file that already exists is never reused.
    fs::write(dst.join(".out.bin.part"), "stale").unwrap();
    assert_eq!(
        run("a.bin", pin(bytes.len() as u64, &sha)).unwrap_err(),
        DownloadError::Io
    );
    assert_eq!(fs::read(dst.join(".out.bin.part")).unwrap(), b"stale");
    let _ = fs::remove_dir_all(src.parent().unwrap());
}

#[test]
fn a_local_npm_tarball_is_checked_against_its_sha512() {
    use sha2::Sha512;
    let bytes = vec![9u8; 5000];
    let good: [u8; 64] = Sha512::digest(&bytes).into();
    let (src, dst) = local_fixture(&bytes);
    assert!(verify_local_sha512(&src, "a.bin", &good, 10_000, &dst, "t.tgz").is_ok());
    assert_eq!(fs::read(dst.join("t.tgz")).unwrap(), bytes);
    fs::remove_file(dst.join("t.tgz")).unwrap();
    let mut bad = good;
    bad[0] ^= 1;
    assert_eq!(
        verify_local_sha512(&src, "a.bin", &bad, 10_000, &dst, "t.tgz").unwrap_err(),
        DownloadError::DigestMismatch
    );
    assert_eq!(
        verify_local_sha512(&src, "a.bin", &good, 4999, &dst, "t.tgz").unwrap_err(),
        DownloadError::TooLarge
    );
    assert_eq!(fs::read_dir(&dst).unwrap().count(), 0);
    let _ = fs::remove_dir_all(src.parent().unwrap());
}

#[test]
fn a_refused_connection_is_a_network_error() {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = l.local_addr().unwrap().port();
    drop(l);
    let h = Harness::new();
    let u = format!("http://127.0.0.1:{port}/ok");
    let pin = Pin {
        url: &u,
        size: h.size(),
        sha256: &h.sha,
    };
    let r = fetch(
        &DownloadPolicy::for_tests(&["127.0.0.1"]),
        &pin,
        &h.dir,
        "artifact.bin",
        &Harness::limits(),
        &mut |_| {},
    );
    assert_eq!(r.unwrap_err(), DownloadError::Network);
    assert!(h.clean());
}

#[test]
fn proxy_variables_are_ignored() {
    static ENV: Mutex<()> = Mutex::new(());
    let _g = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let vars = [
        "HTTP_PROXY",
        "http_proxy",
        "HTTPS_PROXY",
        "https_proxy",
        "ALL_PROXY",
        "all_proxy",
    ];
    let saved: Vec<_> = vars.iter().map(|v| (*v, std::env::var_os(v))).collect();
    for v in vars {
        std::env::set_var(v, "http://127.0.0.1:1");
    }
    let h = Harness::new();
    let r = h.get("/ok");
    for (v, old) in saved {
        match old {
            Some(o) => std::env::set_var(v, o),
            None => std::env::remove_var(v),
        }
    }
    assert!(
        r.is_ok(),
        "a dead proxy would have broken this: {:?}",
        r.err()
    );
    assert_eq!(h.srv.hits("/ok"), 1);
}

#[test]
fn no_credentials_or_cookies_are_sent_even_across_a_redirect() {
    let h = Harness::new();
    h.get("/redir-allowed").unwrap();
    let seen = h.srv.shared.headers.lock().unwrap().clone();
    assert!(seen.len() >= 4, "{} header lines", seen.len());
    for (k, _) in &seen {
        assert!(
            !matches!(
                k.as_str(),
                "authorization" | "cookie" | "proxy-authorization"
            ),
            "{k}"
        );
    }
    assert!(seen
        .iter()
        .any(|(k, v)| k == "accept-encoding" && v == "identity"));
    assert!(seen
        .iter()
        .any(|(k, v)| k == "user-agent" && v == "oab-computer-browser-install"));
}

// ---- no text leaks --------------------------------------------------------------------------

#[test]
fn errors_carry_no_url_host_or_body_text() {
    let h = Harness::new();
    let u = format!(
        "http://127.0.0.1:{}/status500?token=canary-url-secret",
        h.srv.port()
    );
    let pin = Pin {
        url: &u,
        size: h.size(),
        sha256: &h.sha,
    };
    let e = fetch(
        &DownloadPolicy::for_tests(&["127.0.0.1"]),
        &pin,
        &h.dir,
        "artifact.bin",
        &Harness::limits(),
        &mut |_| {},
    )
    .unwrap_err();
    for s in [format!("{e}"), format!("{e:?}"), format!("{pin:?}")] {
        assert!(
            !s.contains("canary") && !s.contains("127.0.0.1") && !s.contains("secret"),
            "{s}"
        );
    }
    for e in [
        DownloadError::Policy,
        DownloadError::Redirect,
        DownloadError::Status,
        DownloadError::Encoding,
        DownloadError::TooLarge,
        DownloadError::SizeMismatch,
        DownloadError::DigestMismatch,
        DownloadError::Timeout,
        DownloadError::Network,
        DownloadError::Io,
    ] {
        assert_eq!(format!("{e}"), e.as_str());
        assert!(!format!("{e:?}").contains(' '), "unit variants only");
    }
}

// ---- the installer directory and the file names ----------------------------------------------

#[test]
fn file_names_must_be_plain() {
    let h = Harness::new();
    for bad in ["", "../x", "a/b", ".hidden", "..", "a\0b", &"n".repeat(201)] {
        let u = h.url("/ok");
        let pin = Pin {
            url: &u,
            size: h.size(),
            sha256: &h.sha,
        };
        let r = fetch(
            &DownloadPolicy::for_tests(&["127.0.0.1"]),
            &pin,
            &h.dir,
            bad,
            &Harness::limits(),
            &mut |_| {},
        );
        assert_eq!(r.unwrap_err(), DownloadError::Io, "{bad:?}");
    }
    assert!(h.clean());
    assert_eq!(h.srv.conns(), 0);
}

#[test]
fn a_part_file_that_already_exists_is_never_followed_or_reused() {
    let h = Harness::new();
    // A plain leftover.
    fs::write(h.dir.join(".artifact.bin.part"), b"old").unwrap();
    assert_eq!(h.get("/ok").unwrap_err(), DownloadError::Io);
    assert_eq!(
        fs::read(h.dir.join(".artifact.bin.part")).unwrap(),
        b"old",
        "someone else's file is left alone"
    );
    fs::remove_file(h.dir.join(".artifact.bin.part")).unwrap();
    // A symlink at the .part name pointing at a file we must not touch.
    let victim = h.dir.join("victim");
    fs::write(&victim, b"keep").unwrap();
    std::os::unix::fs::symlink(&victim, h.dir.join(".artifact.bin.part")).unwrap();
    assert_eq!(h.get("/ok").unwrap_err(), DownloadError::Io);
    assert_eq!(fs::read(&victim).unwrap(), b"keep");
    assert_eq!(h.srv.conns(), 0, "refused before any request");
}

#[test]
fn the_directory_must_be_private_and_not_a_link() {
    let h = Harness::new();
    let l = h.dir.with_extension("link");
    std::os::unix::fs::symlink(&h.dir, &l).unwrap();
    let u = h.url("/ok");
    let pin = Pin {
        url: &u,
        size: h.size(),
        sha256: &h.sha,
    };
    let pol = DownloadPolicy::for_tests(&["127.0.0.1"]);
    assert_eq!(
        fetch(
            &pol,
            &pin,
            &l,
            "artifact.bin",
            &Harness::limits(),
            &mut |_| {}
        )
        .unwrap_err(),
        DownloadError::Io
    );
    fs::remove_file(&l).unwrap();
    for mode in [0o770, 0o707, 0o777] {
        fs::set_permissions(&h.dir, fs::Permissions::from_mode(mode)).unwrap();
        assert_eq!(
            fetch(
                &pol,
                &pin,
                &h.dir,
                "artifact.bin",
                &Harness::limits(),
                &mut |_| {}
            )
            .unwrap_err(),
            DownloadError::Io,
            "{mode:o}"
        );
    }
    fs::set_permissions(&h.dir, fs::Permissions::from_mode(0o750)).unwrap();
    assert!(
        fetch(
            &pol,
            &pin,
            &h.dir,
            "artifact.bin",
            &Harness::limits(),
            &mut |_| {}
        )
        .is_ok(),
        "group read is fine"
    );
    assert!(fetch(
        &pol,
        &pin,
        &h.dir.join("missing"),
        "artifact.bin",
        &Harness::limits(),
        &mut |_| {}
    )
    .is_err());
}

#[test]
fn a_failed_download_never_replaces_an_earlier_good_file() {
    let h = Harness::new();
    h.get("/ok").unwrap();
    assert_eq!(
        h.get("/corrupt").unwrap_err(),
        DownloadError::DigestMismatch
    );
    assert_eq!(
        fs::read(h.dir.join("artifact.bin")).unwrap(),
        h.srv.shared.body
    );
    let names: Vec<_> = fs::read_dir(&h.dir)
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect();
    assert_eq!(names.len(), 1);
}

// ---- real pins (not run in CI) --------------------------------------------------------------

/// `OAB_REAL_PIN_PLATFORM=linux-x64 OAB_REAL_PIN_DIR=<private dir> OAB_REAL_PIN_WHAT=node|chromium
/// cargo test --release real_pins_download -- --ignored --nocapture`. Downloads the real pinned
/// artifact over TLS, verifies it through the production path, then validates and extracts it.
#[test]
#[ignore]
fn real_pins_download() {
    crate::install_crypto_provider();
    let plat = std::env::var("OAB_REAL_PIN_PLATFORM").expect("OAB_REAL_PIN_PLATFORM");
    let dir = PathBuf::from(std::env::var("OAB_REAL_PIN_DIR").expect("OAB_REAL_PIN_DIR"));
    let what = std::env::var("OAB_REAL_PIN_WHAT").unwrap_or_else(|_| "node".into());
    let m = crate::manifest::Manifest::embedded();
    let p = crate::manifest::PlatformId::parse(&plat).expect("platform id");
    let (a, format) = if what == "chromium" {
        (m.chromium_artifact(p).unwrap(), crate::extract::Format::Zip)
    } else {
        (m.node_artifact(p).unwrap(), crate::extract::Format::TarGz)
    };
    let policy = DownloadPolicy::production(m);
    let t = Instant::now();
    let v = fetch(
        &policy,
        &Pin::from_artifact(a),
        &dir,
        &format!("{what}-{plat}.bin"),
        &Limits::default(),
        &mut |_| {},
    )
    .expect("real download verifies");
    println!(
        "downloaded {} bytes in {:?}, sha256 {}",
        v.size(),
        t.elapsed(),
        v.sha256_hex()
    );
    assert_eq!(v.sha256_hex(), a.sha256);
    let limits = crate::extract::Limits::from_artifact(a);
    let plan = crate::extract::validate(&v, format, &limits).expect("real archive validates");
    let stage = dir.join(format!("stage-{what}"));
    fs::create_dir(&stage).unwrap();
    crate::extract::extract(&plan, &v, &stage).expect("real archive extracts");
    println!(
        "extracted {} entries, {} bytes",
        plan.entries().len(),
        plan.total_bytes()
    );
    assert!(plan.total_bytes() <= a.expanded_bytes as u64);
}
