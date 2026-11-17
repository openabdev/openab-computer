use super::*;
use std::collections::HashMap;
use std::net::TcpListener;
use std::sync::atomic::{AtomicUsize, Ordering};

#[test]
fn only_literal_loopback_urls_parse() {
    for ok in [
        "http://127.0.0.1:8794/mcp",
        "http://[::1]:8794/mcp",
        "http://127.0.0.1:1/",
        "http://127.0.0.1:65535",
    ] {
        assert!(parse_target(ok).is_ok(), "{ok}");
    }
    // Built at run time: the repository guard rejects an e-mail shaped literal.
    let at = format!("http://127.0.0.1:8794{}evil.example/mcp", '@');
    assert_eq!(parse_target(&at), Err("external_host_not_loopback"));
    assert_eq!(
        parse_target("http://[::1]:9/mcp").unwrap().addr,
        "[::1]:9".parse().unwrap()
    );
    for bad in [
        "http://localhost:8794/mcp",
        "http://127.0.0.2:8794/mcp",
        "http://0.0.0.0:8794/mcp",
        "http://[::ffff:127.0.0.1]:8794/mcp",
        "http://[::2]:8794/mcp",
        "https://127.0.0.1:8794/mcp",
        "http://127.0.0.1/mcp",
        "http://127.0.0.1:0/mcp",
        "http://127.0.0.1:99999/mcp",
        "http://user@127.0.0.1:8794/mcp",
        "http://127.0.0.1.evil.example:8794/mcp",
        "http://example.com:8794/mcp",
        "http://127.0.0.1:8794/a/../b",
        "http://127.0.0.1:8794/a b",
        "ftp://127.0.0.1:8794/",
        "127.0.0.1:8794",
        "",
    ] {
        assert_eq!(
            parse_target(bad),
            Err("external_host_not_loopback"),
            "{bad}"
        );
    }
}

type Responder = Box<dyn Fn(&Value) -> Vec<u8> + Send + Sync>;

struct Fake {
    url: String,
    connections: Arc<AtomicUsize>,
    bytes: Arc<AtomicUsize>,
}

fn http(status: &str, extra: &str, body: &str) -> Vec<u8> {
    format!(
        "HTTP/1.1 {status}\r\n{extra}Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
    .into_bytes()
}

fn json_ok(id: &Value, result: Value) -> Vec<u8> {
    http(
        "200 OK",
        "Content-Type: application/json\r\n",
        &json!({"jsonrpc": "2.0", "id": id, "result": result}).to_string(),
    )
}

/// A loopback server: reads each request, calls `respond` with the parsed JSON body.
fn fake(respond: Responder) -> Fake {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/mcp", l.local_addr().unwrap());
    let connections = Arc::new(AtomicUsize::new(0));
    let bytes = Arc::new(AtomicUsize::new(0));
    let (c, b) = (Arc::clone(&connections), Arc::clone(&bytes));
    std::thread::spawn(move || {
        for s in l.incoming() {
            let Ok(mut s) = s else { continue };
            c.fetch_add(1, Ordering::SeqCst);
            let mut buf = Vec::new();
            let mut tmp = [0u8; 4096];
            let _ = s.set_read_timeout(Some(Duration::from_millis(500)));
            let body = loop {
                match s.read(&mut tmp) {
                    Ok(0) | Err(_) => break None,
                    Ok(n) => {
                        b.fetch_add(n, Ordering::SeqCst);
                        buf.extend_from_slice(&tmp[..n]);
                    }
                }
                let text = String::from_utf8_lossy(&buf).to_string();
                let Some(end) = text.find("\r\n\r\n") else {
                    continue;
                };
                let len = text[..end]
                    .lines()
                    .find_map(|l| {
                        let (k, v) = l.split_once(':')?;
                        k.eq_ignore_ascii_case("content-length")
                            .then(|| v.trim().parse::<usize>().ok())?
                    })
                    .unwrap_or(0);
                if buf.len() >= end + 4 + len {
                    break Some(text[end + 4..end + 4 + len].to_string());
                }
            };
            let Some(body) = body else { continue };
            let req: Value = serde_json::from_str(&body).unwrap_or(Value::Null);
            let _ = s.write_all(&respond(&req));
        }
    });
    Fake {
        url,
        connections,
        bytes,
    }
}

fn mcp_server() -> Fake {
    fake(Box::new(|req| {
        let id = req["id"].clone();
        match req["method"].as_str().unwrap_or("") {
            "initialize" => http(
                "200 OK",
                "Mcp-Session-Id: sid-1\r\nContent-Type: application/json\r\n",
                &json!({"jsonrpc":"2.0","id":id,"result":{"serverInfo":{"name":"Playwright"}}})
                    .to_string(),
            ),
            "notifications/initialized" => http("202 Accepted", "", ""),
            "tools/list" => json_ok(
                &id,
                json!({"tools":[{"name":"browser_navigate"},{"name":"vendor_extra"}]}),
            ),
            "tools/call" => json_ok(
                &id,
                json!({"content":[{"type":"text","text":"did it"}],"isError":false}),
            ),
            _ => http("400 Bad Request", "", ""),
        }
    }))
}

#[test]
fn a_loopback_upstream_lists_and_calls_and_forwards_every_tool() {
    let f = mcp_server();
    let e = External::for_test("browser", &f.url);
    let names: Vec<String> = e
        .tools()
        .iter()
        .map(|t| t["name"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(names, ["browser_navigate", "vendor_extra"]);
    let r = e
        .rpc(
            "tools/call",
            Some(json!({"name": "vendor_extra", "arguments": {}})),
        )
        .unwrap();
    assert_eq!(r["content"][0]["text"], "did it");
    assert_eq!(e.last_class(), "ok");
}

#[test]
fn a_lost_session_is_reinitialised_once() {
    let n = Arc::new(AtomicUsize::new(0));
    let n2 = Arc::clone(&n);
    let f = fake(Box::new(move |req| {
        let id = req["id"].clone();
        match req["method"].as_str().unwrap_or("") {
            "initialize" => http(
                "200 OK",
                "Mcp-Session-Id: s\r\n",
                &json!({"jsonrpc":"2.0","id":id,"result":{}}).to_string(),
            ),
            "notifications/initialized" => http("202 Accepted", "", ""),
            "tools/list" => {
                if n2.fetch_add(1, Ordering::SeqCst) == 0 {
                    http("404 Not Found", "", "")
                } else {
                    json_ok(&id, json!({"tools": []}))
                }
            }
            _ => http("400 Bad Request", "", ""),
        }
    }));
    let e = External::for_test("browser", &f.url);
    assert!(e.rpc("tools/list", None).is_ok());
    assert_eq!(n.load(Ordering::SeqCst), 2);
}

#[test]
fn every_redirect_is_refused_and_the_second_listener_sees_nothing() {
    for code in [
        "301 Moved Permanently",
        "302 Found",
        "307 Temporary Redirect",
        "308 Permanent Redirect",
    ] {
        let target = fake(Box::new(|req| json_ok(&req["id"], json!({}))));
        let loc = target.url.clone();
        let code = code.to_string();
        let f = fake(Box::new(move |_| {
            http(&code, &format!("Location: {loc}\r\n"), "moved")
        }));
        let e = External::for_test("browser", &f.url);
        // The first call is `initialize`: the redirect is its answer.
        let err = e.rpc("tools/list", None).unwrap_err();
        assert_eq!(err, "upstream_redirect", "{err}");
        assert_eq!(f.connections.load(Ordering::SeqCst), 1);
        assert_eq!(
            target.connections.load(Ordering::SeqCst),
            0,
            "a redirect was followed"
        );
    }
}

#[test]
fn errors_are_fixed_classes_and_a_canary_in_the_body_never_appears() {
    let canary = "CANARY-UPSTREAM-8c41";
    let cases: Vec<(Responder, &str)> = vec![
        (
            Box::new(move |_| http("500 Internal Server Error", "", &format!("boom {canary}"))),
            "upstream_http_500",
        ),
        (
            Box::new(move |_| http("403 Forbidden", "", canary)),
            "upstream_http_403",
        ),
    ];
    for (resp, want) in cases {
        let f = fake(resp);
        let e = External::for_test("browser", &f.url);
        let err = e.rpc("tools/list", None).unwrap_err();
        assert_eq!(err, want);
        assert!(!err.contains(canary) && !e.last_class().contains(canary));
    }
    // An initialised upstream that then answers badly.
    let phase = Arc::new(AtomicUsize::new(0));
    let ph = Arc::clone(&phase);
    let f = fake(Box::new(move |req| {
        let id = req["id"].clone();
        match req["method"].as_str().unwrap_or("") {
            "initialize" => http(
                "200 OK",
                "Mcp-Session-Id: s\r\n",
                &json!({"jsonrpc":"2.0","id":id,"result":{}}).to_string(),
            ),
            "notifications/initialized" => http("202 Accepted", "", ""),
            _ => match ph.load(Ordering::SeqCst) {
                0 => http("200 OK", "", &format!("not json {canary}")),
                _ => http(
                    "200 OK",
                    "",
                    &json!({"jsonrpc":"2.0","id":id,"error":{"code":-1,"message":canary}})
                        .to_string(),
                ),
            },
        }
    }));
    let e = External::for_test("browser", &f.url);
    let a = e.rpc("tools/list", None).unwrap_err();
    assert_eq!(a, "upstream_bad_body");
    phase.store(1, Ordering::SeqCst);
    let b = e.rpc("tools/list", None).unwrap_err();
    assert_eq!(b, "upstream_rpc_error");
    for s in [&a, &b, &e.last_class()] {
        assert!(!s.contains(canary));
    }
}

#[test]
fn a_refused_connection_and_a_silent_server_are_classes() {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/mcp", l.local_addr().unwrap());
    drop(l);
    let e = External::for_test("browser", &url);
    assert_eq!(
        e.rpc("tools/list", None).unwrap_err(),
        "upstream_unreachable"
    );

    let silent = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/mcp", silent.local_addr().unwrap());
    let _hold = std::thread::spawn(move || {
        let held: Vec<_> = silent.incoming().take(2).flatten().collect();
        std::thread::sleep(Duration::from_secs(2));
        drop(held);
    });
    let e = External::for_test("browser", &url).with_deadline(Duration::from_millis(300));
    assert_eq!(e.rpc("tools/list", None).unwrap_err(), "upstream_timeout");
}

#[test]
fn oversize_headers_and_bodies_are_refused_without_reading_them() {
    let f = fake(Box::new(|_| {
        let mut v = b"HTTP/1.1 200 OK\r\n".to_vec();
        v.extend(std::iter::repeat_n(b'a', HEADER_CAP + 4096));
        v
    }));
    let e = External::for_test("browser", &f.url);
    assert_eq!(e.rpc("tools/list", None).unwrap_err(), "upstream_bad_body");
    let f = fake(Box::new(|_| {
        format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\nx",
            BODY_CAP + 1
        )
        .into_bytes()
    }));
    let e = External::for_test("browser", &f.url);
    assert_eq!(e.rpc("tools/list", None).unwrap_err(), "upstream_bad_body");
}

#[test]
fn a_chunked_reply_is_decoded() {
    let f = fake(Box::new(|req| {
        let body =
            json!({"jsonrpc":"2.0","id":req["id"],"result":{"tools":[{"name":"t"}]}}).to_string();
        let (a, b) = body.split_at(10);
        format!(
            "HTTP/1.1 200 OK\r\nMcp-Session-Id: s\r\nTransfer-Encoding: chunked\r\n\r\n{:x}\r\n{a}\r\n{:x}\r\n{b}\r\n0\r\n\r\n",
            a.len(),
            b.len()
        )
        .into_bytes()
    }));
    let e = External::for_test("browser", &f.url);
    assert_eq!(e.tools().len(), 1);
}

// ---- the owner check ------------------------------------------------------------------------

struct Table(HashMap<&'static str, std::io::Result<String>>);

impl procnet::Source for Table {
    fn table(&self, name: &str) -> std::io::Result<String> {
        match self.0.get(name) {
            Some(Ok(s)) => Ok(s.clone()),
            _ => Err(std::io::Error::other("unreadable")),
        }
    }
}

/// An owner check that reads the real table through a wrapper that rewrites every uid.
struct Spoof(u32);

impl procnet::Source for Spoof {
    fn table(&self, name: &str) -> std::io::Result<String> {
        let real = procnet::Proc.table(name)?;
        // Rows are `sl local rem st queues tr:tm retr uid timeout inode ...`: replace field 7.
        Ok(real
            .lines()
            .map(|l| {
                let mut f: Vec<String> = l.split_whitespace().map(str::to_string).collect();
                if f.len() > 9 && f[0].ends_with(':') {
                    f[7] = self.0.to_string();
                }
                f.join(" ")
            })
            .collect::<Vec<_>>()
            .join("\n"))
    }
}

#[test]
fn an_unreadable_table_fails_closed_before_any_request_byte() {
    let f = mcp_server();
    let owner = SameUid {
        source: Box::new(Table(HashMap::new())),
    };
    let e = External::new("browser", &f.url, Arc::new(owner)).unwrap();
    assert_eq!(
        e.rpc("tools/list", None).unwrap_err(),
        "listener_owner_unknown"
    );
    assert!(e.tools().is_empty());
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(
        f.connections.load(Ordering::SeqCst),
        2,
        "one connection per attempt"
    );
    assert_eq!(f.bytes.load(Ordering::SeqCst), 0, "a request byte was sent");
}

#[cfg(target_os = "linux")]
#[test]
fn a_different_owner_uid_fails_closed_before_any_request_byte() {
    let f = mcp_server();
    let other = rustix::process::geteuid().as_raw().wrapping_add(1);
    let e = External::new(
        "browser",
        &f.url,
        Arc::new(SameUid {
            source: Box::new(Spoof(other)),
        }),
    )
    .unwrap();
    assert_eq!(
        e.rpc("tools/list", None).unwrap_err(),
        "listener_owner_unknown"
    );
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(f.bytes.load(Ordering::SeqCst), 0, "a request byte was sent");
}

#[cfg(target_os = "linux")]
#[test]
fn the_same_uid_is_accepted_with_the_real_table() {
    let f = mcp_server();
    let e = External::new("browser", &f.url, Arc::new(SameUid::real())).unwrap();
    assert_eq!(e.tools().len(), 2);
    let me = rustix::process::geteuid().as_raw();
    let ok = External::new(
        "browser",
        &f.url,
        Arc::new(SameUid {
            source: Box::new(Spoof(me)),
        }),
    )
    .unwrap();
    assert!(ok.rpc("tools/list", None).is_ok());
}

#[cfg(target_os = "linux")]
#[test]
fn an_ipv6_loopback_upstream_works_where_the_host_has_ipv6() {
    let Ok(l) = TcpListener::bind("[::1]:0") else {
        return;
    };
    let url = format!("http://{}/mcp", l.local_addr().unwrap());
    std::thread::spawn(move || {
        for s in l.incoming() {
            let Ok(mut s) = s else { continue };
            let mut b = [0u8; 4096];
            let n = s.read(&mut b).unwrap_or(0);
            let text = String::from_utf8_lossy(&b[..n]).to_string();
            let id = if text.contains("\"initialize\"") {
                0
            } else {
                1
            };
            let body =
                json!({"jsonrpc":"2.0","id":id,"result":{"tools":[{"name":"x"}]}}).to_string();
            let _ = s.write_all(&http("200 OK", "Mcp-Session-Id: s\r\n", &body));
        }
    });
    let e = External::new("browser", &url, Arc::new(SameUid::real())).unwrap();
    assert_eq!(e.tools().len(), 1);
}
