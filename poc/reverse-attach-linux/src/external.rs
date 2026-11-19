//! The external upstream: a Playwright MCP the operator runs, reached over Streamable HTTP on a
//! literal loopback address (ADR "Router", R4.3, macOS R7.5.2 to R7.5.5, R7.8; L2).
//!
//! Loopback is not private: any local user can reach such a listener, and it serves
//! `browser_run_code_unsafe`. This client therefore enforces, and the docs never call it private:
//!
//! - **A literal loopback host.** `http://127.0.0.1:<port>/path` or `http://[::1]:<port>/path`. No
//!   name is resolved. A URL that is anything else is refused at start (`parse_target`), and the
//!   daemon exits 64 so its unit does not restart-loop.
//! - **No redirects.** Any 3xx is `upstream_redirect`; no second request is made.
//! - **Fixed error classes** (`upstream_http_<status>`, `upstream_redirect`, `upstream_bad_body`,
//!   `upstream_rpc_error`, `upstream_unreachable`, `upstream_timeout`, `listener_owner_unknown`).
//!   No upstream text is copied into an error. A successful tool result passes through unchanged.
//! - **The owner of the connection is checked on every connection actually used**, after the
//!   connect and before any request byte is sent: the server end of this very connection must be
//!   owned by this process's uid (`procnet::peer_owner_uid`). A different uid, a missing row or an
//!   unreadable table fails closed. A same-uid impostor is outside this control.
//! - **Bounded I/O.** Response headers at most `HEADER_CAP`, body at most `BODY_CAP`, and one
//!   overall deadline per request.

use std::io::{Read, Write};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, TcpStream};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::procnet;
use crate::tools::sysinfo::AGENT_VERSION;

pub const HEADER_CAP: usize = 64 * 1024;
pub const BODY_CAP: usize = 8 * 1024 * 1024;
const TOOLS_TTL: Duration = Duration::from_secs(30);

/// A parsed, accepted external URL.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    pub addr: SocketAddr,
    /// The request path, starting with `/`.
    pub path: String,
}

/// `Some` only for `http://127.0.0.1:<port>/<path>` and `http://[::1]:<port>/<path>`.
pub fn parse_target(url: &str) -> Result<Target, &'static str> {
    const BAD: &str = "external_host_not_loopback";
    let rest = url.strip_prefix("http://").ok_or(BAD)?;
    let (authority, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    let (ip, port): (IpAddr, &str) = if let Some(r) = authority.strip_prefix("[::1]:") {
        (IpAddr::V6(Ipv6Addr::LOCALHOST), r)
    } else if let Some(r) = authority.strip_prefix("127.0.0.1:") {
        (IpAddr::V4(Ipv4Addr::LOCALHOST), r)
    } else {
        return Err(BAD);
    };
    let port: u16 = port.parse().map_err(|_| BAD)?;
    let path_ok = path.len() <= 256
        && path
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'/' | b'_' | b'.' | b'-' | b'~'));
    if port == 0 || !path_ok || path.contains("..") {
        return Err(BAD);
    }
    Ok(Target {
        addr: SocketAddr::new(ip, port),
        path: path.to_string(),
    })
}

/// Decides whether the owner of a connection is acceptable.
pub trait OwnerCheck: Send + Sync {
    /// `end` is the request deadline: a check that is still waiting then fails as a timeout.
    fn check(
        &self,
        client: SocketAddr,
        server: SocketAddr,
        end: Instant,
    ) -> Result<(), &'static str>;
}

/// The real check: the server end of the connection belongs to this process's uid.
pub struct SameUid {
    pub source: Box<dyn procnet::Source + Send + Sync>,
}

impl SameUid {
    pub fn real() -> SameUid {
        SameUid {
            source: Box::new(procnet::Proc),
        }
    }
}

impl OwnerCheck for SameUid {
    fn check(
        &self,
        client: SocketAddr,
        server: SocketAddr,
        end: Instant,
    ) -> Result<(), &'static str> {
        // The kernel lists a connection that the server has not accepted yet with uid 0 (the owner
        // of a socket is read from its file, which an unaccepted socket does not have), and a
        // connection that has only just completed may not be listed at all; `/proc/net/tcp` is also
        // produced in chunks while sockets come and go, so one read can skip a row that is there.
        // On a loaded host the server thread can take well over a moment to accept. So the owner is
        // read again, up to `READS` times 20 ms apart (half a second), until it is this uid. Only
        // our own uid is accepted, and nothing is sent before it is: the retries cost time on a
        // refusal and never widen what is accepted.
        // This is the production check, not a test aid: the same read guards every external
        // connection. Pinned by `a_row_that_is_not_there_yet_is_read_again_and_another_owner_is_never_accepted`.
        const READS: u32 = 25;
        for read in 1..=READS {
            if procnet::peer_owner_uid(&*self.source, client, server)
                == Ok(rustix::process::geteuid().as_raw())
            {
                return Ok(());
            }
            if read < READS {
                // The request deadline bounds the retries and the pauses between them.
                let left = end.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    return Err("upstream_timeout");
                }
                std::thread::sleep(Duration::from_millis(20).min(left));
            }
        }
        Err(procnet::UNKNOWN)
    }
}

/// Test-only: accepts every owner.
#[cfg(test)]
pub struct AllowAll;

#[cfg(test)]
impl OwnerCheck for AllowAll {
    fn check(&self, _: SocketAddr, _: SocketAddr, _: Instant) -> Result<(), &'static str> {
        Ok(())
    }
}

struct Reply {
    status: u16,
    session: Option<String>,
    body: String,
}

pub struct External {
    name: String,
    target: Target,
    session_id: Mutex<Option<String>>,
    cache: Mutex<Option<(Instant, Vec<Value>)>>,
    owner: Arc<dyn OwnerCheck>,
    deadline: Duration,
    last_logged: Mutex<String>,
}

fn status_class(status: u16) -> String {
    if (300..400).contains(&status) {
        "upstream_redirect".into()
    } else {
        format!("upstream_http_{status}")
    }
}

impl External {
    pub fn new(
        name: &str,
        url: &str,
        owner: Arc<dyn OwnerCheck>,
    ) -> Result<External, &'static str> {
        Ok(External {
            name: name.to_string(),
            target: parse_target(url)?,
            session_id: Mutex::new(None),
            cache: Mutex::new(None),
            owner,
            deadline: Duration::from_secs(90),
            last_logged: Mutex::new(String::new()),
        })
    }

    /// For the conformance and unit tests: an owner check that accepts everything.
    #[cfg(test)]
    pub fn for_test(name: &str, url: &str) -> External {
        External::new(name, url, Arc::new(AllowAll)).expect("loopback url")
    }

    #[cfg(test)]
    pub fn with_deadline(mut self, d: Duration) -> External {
        self.deadline = d;
        self
    }

    /// The last outcome as a fixed class, for `sys_info`.
    pub fn last_class(&self) -> String {
        self.last_logged
            .lock()
            .map(|g| g.clone())
            .unwrap_or_default()
    }

    fn note(&self, class: &str) {
        if let Ok(mut g) = self.last_logged.lock() {
            if *g != class {
                *g = class.to_string();
                if class != "ok" {
                    // One line per change of class, fixed fields only.
                    eprintln!("browser: external name={} class={class}", self.name);
                }
            }
        }
    }

    /// One POST on a fresh connection. Every error is a fixed class.
    /// With `limit` (the paged listing) the request ends by `limit` at the latest, and by the
    /// client's own deadline in any case; every step waits only for what is left of that end. With
    /// `None` (an ordinary call) each POST has the client's deadline and the timing and error classes
    /// it always had: a 10 s connect, a 10 s write bound reported as `upstream_unreachable`.
    fn post(&self, msg: &Value, limit: Option<Duration>) -> Result<Reply, String> {
        let end = Instant::now() + limit.map_or(self.deadline, |l| self.deadline.min(l));
        let connect = limit.map_or(Duration::from_secs(10), |l| {
            Duration::from_secs(10).min(l).max(Duration::from_millis(1))
        });
        let sid = self.session_id.lock().ok().and_then(|g| g.clone());
        let body = msg.to_string();
        let mut stream = TcpStream::connect_timeout(&self.target.addr, connect).map_err(|e| {
            if e.kind() == std::io::ErrorKind::TimedOut {
                "upstream_timeout".to_string()
            } else {
                "upstream_unreachable".to_string()
            }
        })?;
        let local = stream
            .local_addr()
            .map_err(|_| "upstream_unreachable".to_string())?;
        // Before a single request byte: whose is the other end of this connection?
        self.owner
            .check(local, self.target.addr, end)
            .map_err(str::to_string)?;
        if limit.is_none() {
            let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));
        }
        let host = match self.target.addr {
            SocketAddr::V4(a) => format!("127.0.0.1:{}", a.port()),
            SocketAddr::V6(a) => format!("[::1]:{}", a.port()),
        };
        let mut head = format!(
            "POST {} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\n\
             Accept: application/json, text/event-stream\r\nContent-Length: {}\r\n\
             Connection: close\r\n",
            self.target.path,
            body.len()
        );
        if let Some(s) = sid.as_deref().filter(|s| header_value_ok(s)) {
            head.push_str(&format!("Mcp-Session-Id: {s}\r\n"));
        }
        head.push_str("\r\n");
        if limit.is_some() {
            // One absolute deadline for connect, owner check, write and read: each write waits only
            // for what is left of `end`, so a server that stops reading cannot hold the request
            // past it.
            write_before(&mut stream, head.as_bytes(), end)?;
            write_before(&mut stream, body.as_bytes(), end)?;
        } else {
            stream
                .write_all(head.as_bytes())
                .and_then(|_| stream.write_all(body.as_bytes()))
                .map_err(|_| "upstream_unreachable".to_string())?;
        }
        read_reply(&mut stream, end)
    }

    fn initialize(&self, limit: Option<Duration>) -> Result<(), String> {
        let start = Instant::now();
        // Never send a stale id on initialize: the upstream answers 404 to it.
        if let Ok(mut g) = self.session_id.lock() {
            *g = None;
        }
        let r = self.post(
            &json!({
                "jsonrpc": "2.0", "id": 0, "method": "initialize",
                "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                           "clientInfo": {"name": "oab-computer-rpi", "version": AGENT_VERSION}}
            }),
            limit,
        )?;
        let limit = limit.map(|l| l.saturating_sub(start.elapsed()));
        if !(200..300).contains(&r.status) {
            return Err(status_class(r.status));
        }
        if let Ok(mut g) = self.session_id.lock() {
            *g = r.session.filter(|s| header_value_ok(s));
        }
        let _ = self.post(
            &json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
            limit,
        );
        if let Ok(mut c) = self.cache.lock() {
            *c = None;
        }
        Ok(())
    }

    pub fn rpc(&self, method: &str, params: Option<Value>) -> Result<Value, String> {
        self.rpc_within(method, params, None)
    }

    /// [`External::rpc`]; with `limit` (a page of the listing) every request, a re-initialisation
    /// included, ends within `limit`. Without it each POST keeps its own deadline.
    fn rpc_within(
        &self,
        method: &str,
        params: Option<Value>,
        limit: Option<Duration>,
    ) -> Result<Value, String> {
        let r = self.rpc_inner(method, params, limit);
        match &r {
            Ok(_) => self.note("ok"),
            Err(e) => self.note(e),
        }
        r
    }

    fn rpc_inner(
        &self,
        method: &str,
        params: Option<Value>,
        limit: Option<Duration>,
    ) -> Result<Value, String> {
        let start = Instant::now();
        let left = || limit.map(|l| l.saturating_sub(start.elapsed()));
        if self.session_id.lock().ok().is_none_or(|g| g.is_none()) {
            self.initialize(left())?;
        }
        let mut msg = json!({"jsonrpc": "2.0", "id": 1, "method": method});
        if let Some(p) = &params {
            msg["params"] = p.clone();
        }
        let mut r = self.post(&msg, left())?;
        if r.status == 404 || r.status == 400 {
            // The upstream lost our session (restart). One re-init, one retry.
            self.initialize(left())?;
            r = self.post(&msg, left())?;
        }
        if !(200..300).contains(&r.status) {
            return Err(status_class(r.status));
        }
        let v = parse_mcp_body(&r.body).ok_or("upstream_bad_body")?;
        if v.get("error").is_some() {
            return Err("upstream_rpc_error".into());
        }
        Ok(v.get("result").cloned().unwrap_or(Value::Null))
    }

    pub fn tools(&self) -> Vec<Value> {
        if let Ok(c) = self.cache.lock() {
            if let Some((at, t)) = c.as_ref() {
                if at.elapsed() < TOOLS_TTL {
                    return t.clone();
                }
            }
        }
        // Every page, with the rules of the managed backend (`stdio_client::list_tools_paged`): the
        // walk shares one deadline, and a failing or misbehaving page drops the whole listing.
        let list = match crate::stdio_client::list_tools_paged(
            self.deadline,
            self.deadline,
            |p, t| {
                self.rpc_within("tools/list", Some(p), Some(t))
                    .map_err(|_| ListFail::Rpc)
            },
            ListFail::Bad,
            ListFail::Timeout,
        ) {
            Ok(list) => list,
            Err(fail) => {
                // `rpc_within` has noted its own class; the two walk failures are noted here.
                match fail {
                    ListFail::Rpc => {}
                    ListFail::Bad => self.note("upstream_bad_body"),
                    ListFail::Timeout => self.note("upstream_timeout"),
                }
                // Do not cache a failure: the next tools/list retries immediately.
                if let Ok(mut c) = self.cache.lock() {
                    *c = None;
                }
                return Vec::new();
            }
        };
        if let Ok(mut c) = self.cache.lock() {
            *c = Some((Instant::now(), list.clone()));
        }
        list
    }

    /// The last list `tools` cached, at any age, without a request. Empty when nothing is cached.
    pub fn cached_tools(&self) -> Vec<Value> {
        self.cache
            .lock()
            .ok()
            .and_then(|c| c.as_ref().map(|(_, t)| t.clone()))
            .unwrap_or_default()
    }
}

/// Why a paged listing failed: a request failed (already noted), or the pages were not acceptable.
#[derive(Clone, Copy)]
enum ListFail {
    Rpc,
    Bad,
    Timeout,
}

fn header_value_ok(s: &str) -> bool {
    !s.is_empty() && s.len() <= 256 && s.bytes().all(|b| (0x21..=0x7e).contains(&b))
}

/// JSON body, or the first `data:` line of an SSE body that parses.
fn parse_mcp_body(body: &str) -> Option<Value> {
    let t = body.trim();
    if let Ok(v) = serde_json::from_str::<Value>(t) {
        return Some(v);
    }
    t.lines()
        .filter_map(|l| l.strip_prefix("data:"))
        .find_map(|d| serde_json::from_str::<Value>(d.trim()).ok())
}

/// Writes all of `data` before `end`. The write timeout is set again from the time left before every
/// write, so partial progress does not extend the bound. Expiry is `upstream_timeout`.
fn write_before(stream: &mut TcpStream, mut data: &[u8], end: Instant) -> Result<(), String> {
    use std::io::ErrorKind;
    while !data.is_empty() {
        if timed_out(end) {
            return Err("upstream_timeout".into());
        }
        let left = end
            .saturating_duration_since(Instant::now())
            .max(Duration::from_millis(1));
        stream
            .set_write_timeout(Some(left))
            .map_err(|_| "upstream_unreachable".to_string())?;
        match stream.write(data) {
            Ok(0) => return Err("upstream_unreachable".into()),
            Ok(n) => data = &data[n..],
            Err(e) if e.kind() == ErrorKind::Interrupted => {}
            Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
                return Err("upstream_timeout".into())
            }
            Err(_) => return Err("upstream_unreachable".into()),
        }
    }
    Ok(())
}

fn timed_out(end: Instant) -> bool {
    Instant::now() >= end
}

/// Reads status, headers and a body bounded by `HEADER_CAP` and `BODY_CAP`, before `end`.
fn read_reply(stream: &mut TcpStream, end: Instant) -> Result<Reply, String> {
    let unreachable = || "upstream_unreachable".to_string();
    let timeout = || "upstream_timeout".to_string();
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 8192];
    let head_end = loop {
        if let Some(i) = find(&buf, b"\r\n\r\n") {
            break i;
        }
        if buf.len() > HEADER_CAP {
            return Err("upstream_bad_body".into());
        }
        let n = read_some(stream, &mut chunk, end)
            .map_err(|e| e.map_or_else(timeout, |_| unreachable()))?;
        if n == 0 {
            return Err("upstream_bad_body".into());
        }
        buf.extend_from_slice(&chunk[..n]);
    };
    let head = String::from_utf8_lossy(&buf[..head_end]).into_owned();
    let mut lines = head.lines();
    let status = lines
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|s| s.parse::<u16>().ok())
        .filter(|s| (100..600).contains(s))
        .ok_or("upstream_bad_body")?;
    let mut session = None;
    let mut length: Option<usize> = None;
    let mut chunked = false;
    for l in lines {
        let Some((k, v)) = l.split_once(':') else {
            continue;
        };
        let (k, v) = (k.trim().to_ascii_lowercase(), v.trim());
        match k.as_str() {
            "mcp-session-id" => session = Some(v.to_string()),
            "content-length" => length = v.parse().ok(),
            "transfer-encoding" => chunked = v.to_ascii_lowercase().contains("chunked"),
            _ => {}
        }
    }
    // A redirect is refused with no further read and no second request.
    if (300..400).contains(&status) {
        return Ok(Reply {
            status,
            session: None,
            body: String::new(),
        });
    }
    if length.is_some_and(|n| n > BODY_CAP) {
        return Err("upstream_bad_body".into());
    }
    let mut body: Vec<u8> = buf[head_end + 4..].to_vec();
    // Read until the framing says the body is complete; with neither a length nor chunks, until EOF.
    loop {
        let complete = if chunked {
            chunk_end(&body)
        } else {
            length.is_some_and(|n| body.len() >= n)
        };
        if complete {
            break;
        }
        if body.len() > BODY_CAP + 16 * 1024 {
            return Err("upstream_bad_body".into());
        }
        let n = read_some(stream, &mut chunk, end)
            .map_err(|e| e.map_or_else(timeout, |_| unreachable()))?;
        if n == 0 {
            if chunked || length.is_some() {
                return Err("upstream_bad_body".into());
            }
            break;
        }
        body.extend_from_slice(&chunk[..n]);
    }
    let body = if chunked {
        dechunk(&body).ok_or("upstream_bad_body")?
    } else {
        if let Some(n) = length {
            body.truncate(n);
        }
        body
    };
    if body.len() > BODY_CAP {
        return Err("upstream_bad_body".into());
    }
    Ok(Reply {
        status,
        session,
        body: String::from_utf8_lossy(&body).into_owned(),
    })
}

/// `Err(None)` for a deadline, `Err(Some(_))` for an I/O error.
fn read_some(
    s: &mut TcpStream,
    buf: &mut [u8],
    end: Instant,
) -> Result<usize, Option<std::io::Error>> {
    if timed_out(end) {
        return Err(None);
    }
    let left = end
        .saturating_duration_since(Instant::now())
        .max(Duration::from_millis(1));
    let _ = s.set_read_timeout(Some(left));
    loop {
        match s.read(buf) {
            Ok(n) => return Ok(n),
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                return Err(None)
            }
            Err(e) => return Err(Some(e)),
        }
    }
}

fn find(h: &[u8], n: &[u8]) -> Option<usize> {
    h.windows(n.len()).position(|w| w == n)
}

/// Is the chunked body complete (the terminating zero-size chunk is present)?
fn chunk_end(b: &[u8]) -> bool {
    // Cheap test first: a long body is not re-decoded on every read.
    b.ends_with(b"0\r\n\r\n") && dechunk(b).is_some()
}

/// Decodes a chunked body, `None` if it is malformed or not yet complete. Bounded by `BODY_CAP`.
fn dechunk(mut b: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    loop {
        let nl = find(b, b"\r\n")?;
        let size_text = std::str::from_utf8(&b[..nl]).ok()?;
        let size = usize::from_str_radix(size_text.split(';').next()?.trim(), 16).ok()?;
        b = &b[nl + 2..];
        if size == 0 {
            return Some(out);
        }
        if out.len() + size > BODY_CAP || b.len() < size + 2 {
            return None;
        }
        out.extend_from_slice(&b[..size]);
        if &b[size..size + 2] != b"\r\n" {
            return None;
        }
        b = &b[size + 2..];
    }
}

#[cfg(test)]
#[path = "external_tests.rs"]
mod tests;
