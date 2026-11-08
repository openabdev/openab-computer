//! Liveness of an attached socket (#70, the Linux side of #68). A fake runtime
//! plays the openab-pty liveness rule scaled down: it pings every
//! `ping_every`, counts an interval with no inbound frame as missed, and closes
//! after more than `max_missed`. The production `dial_loop` is the client.
//!
//! The `bash` cases need Linux (`setsid`, `/proc`), like the rest of this crate.

use std::collections::HashMap;
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tungstenite::protocol::frame::coding::CloseCode;
use tungstenite::protocol::CloseFrame;
use tungstenite::Message;

use super::*;

/// What the fake runtime does.
#[derive(Clone)]
struct Plan {
    /// Ping the client this often; `None`: never.
    ping_every: Option<Duration>,
    /// Close with 1000 after more than this many intervals without a frame.
    max_missed: u32,
    /// Sent on the first connection once `initialize` is answered.
    calls: Vec<Value>,
    /// Close the first connection with this code this long after `initialize`
    /// is answered.
    close_first: Option<(Duration, u16)>,
}

/// What the fake runtime saw on one connection.
#[derive(Clone, Debug, Default)]
struct Conn {
    /// Ids of replies, in arrival order. On the first connection the
    /// `initialize` reply (id 1) is not recorded.
    replies: Vec<i64>,
    pongs: u32,
    client_pings: u32,
    evicted: bool,
}

struct Runtime {
    port: u16,
    log: Arc<Mutex<Vec<Conn>>>,
    stop: Arc<AtomicBool>,
    handle: Option<thread::JoinHandle<()>>,
}

impl Runtime {
    fn start(plan: Plan) -> Runtime {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        listener.set_nonblocking(true).unwrap();
        let log = Arc::new(Mutex::new(Vec::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let (t_log, t_stop) = (log.clone(), stop.clone());
        let handle = thread::spawn(move || {
            while !t_stop.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((stream, _)) => {
                        stream.set_nonblocking(false).unwrap();
                        let index = {
                            let mut l = t_log.lock().unwrap();
                            l.push(Conn::default());
                            l.len() - 1
                        };
                        serve(stream, index, &plan, &t_log, &t_stop);
                    }
                    Err(_) => thread::sleep(Duration::from_millis(10)),
                }
            }
        });
        Runtime {
            port,
            log,
            stop,
            handle: Some(handle),
        }
    }

    fn conns(&self) -> Vec<Conn> {
        self.log.lock().unwrap().clone()
    }
}

impl Drop for Runtime {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

fn text(v: Value) -> Message {
    Message::Text(v.to_string())
}

fn serve(
    stream: std::net::TcpStream,
    index: usize,
    plan: &Plan,
    log: &Arc<Mutex<Vec<Conn>>>,
    stop: &AtomicBool,
) {
    let Ok(mut ws) = tungstenite::accept(stream) else {
        return;
    };
    ws.get_mut()
        .set_read_timeout(Some(Duration::from_millis(10)))
        .unwrap();
    let _ = ws.send(text(json!({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                   "clientInfo": {"name": "openab-pty", "version": "t"}}
    })));
    let first = index == 0;
    let mut missed = 0u32;
    let mut next_ping = plan.ping_every.map(|p| Instant::now() + p);
    let mut close_at: Option<(Instant, u16)> = None;
    let mut closing = false;
    let edit = |f: fn(&mut Conn)| f(&mut log.lock().unwrap()[index]);

    while !stop.load(Ordering::Acquire) {
        if !closing {
            if let (Some(at), Some(every)) = (next_ping, plan.ping_every) {
                if Instant::now() >= at {
                    missed += 1;
                    if missed > plan.max_missed {
                        edit(|c| c.evicted = true);
                        let _ = ws.close(None);
                        closing = true;
                    } else {
                        let _ = ws.send(Message::Ping(Vec::new()));
                    }
                    next_ping = Some(at + every);
                }
            }
            if let Some((at, code)) = close_at {
                if Instant::now() >= at {
                    let _ = ws.close(Some(CloseFrame {
                        code: CloseCode::from(code),
                        reason: "".into(),
                    }));
                    closing = true;
                }
            }
        }
        match ws.read() {
            Ok(Message::Text(t)) => {
                missed = 0;
                let id = serde_json::from_str::<Value>(&t)
                    .ok()
                    .and_then(|v| v["id"].as_i64())
                    .unwrap_or(-1);
                if first && id == 1 {
                    for call in &plan.calls {
                        let _ = ws.send(text(call.clone()));
                    }
                    close_at = plan
                        .close_first
                        .map(|(after, code)| (Instant::now() + after, code));
                } else {
                    log.lock().unwrap()[index].replies.push(id);
                }
            }
            Ok(Message::Pong(_)) => {
                missed = 0;
                edit(|c| c.pongs += 1);
            }
            Ok(Message::Ping(_)) => {
                missed = 0;
                edit(|c| c.client_pings += 1);
            }
            Ok(_) => missed = 0,
            Err(tungstenite::Error::Io(ref e))
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(_) => return,
        }
    }
}

struct Client {
    registry: Registry,
    cancelled: Arc<AtomicBool>,
    handle: Option<thread::JoinHandle<()>>,
}

const GRANT: &str = "grant-liveness-test";

impl Client {
    fn start(port: u16, keepalive: Option<Duration>) -> Client {
        Client::start_tuned(
            port,
            DialTuning {
                keepalive,
                stable_after: Duration::from_secs(60),
                idle_read_poll: IDLE_READ_POLL,
            },
        )
    }

    fn start_tuned(port: u16, tuning: DialTuning) -> Client {
        let runtime = format!("ws://127.0.0.1:{port}");
        let registry: Registry = Arc::new(Mutex::new(HashMap::new()));
        let cancelled = Arc::new(AtomicBool::new(false));
        registry.lock().unwrap().insert(
            GRANT.to_string(),
            GrantInfo {
                id: GRANT.to_string(),
                runtime: runtime.clone(),
                session: "s1".to_string(),
                profile: "owner".to_string(),
                requested_profile: "owner".to_string(),
                warning: None,
                principal: "a@b".to_string(),
                state: "dialing".to_string(),
                ended: None,
                expires_at_epoch_secs: now_epoch_secs() + 60,
                cancelled: cancelled.clone(),
                secret: "s".to_string(),
            },
        );
        let grant = DialGrant {
            runtime,
            session: "s1".to_string(),
            secret: "s".to_string(),
            profile: "owner".to_string(),
            deadline_epoch_secs: now_epoch_secs() + 60,
            registry: registry.clone(),
            grant_id: GRANT.to_string(),
            cancelled: cancelled.clone(),
            tuning,
        };
        let handle = thread::spawn(move || dial_loop(grant));
        Client {
            registry,
            cancelled,
            handle: Some(handle),
        }
    }

    fn state(&self) -> (String, Option<String>) {
        let map = self.registry.lock().unwrap();
        let g = map.get(GRANT).unwrap();
        (g.state.clone(), g.ended.clone())
    }

    /// DELETE: cancel the grant and wait for `dial_loop` to return.
    fn revoke(&mut self) -> Duration {
        let started = Instant::now();
        self.cancelled.store(true, Ordering::Release);
        if let Some(h) = self.handle.take() {
            h.join().unwrap();
        }
        started.elapsed()
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        self.revoke();
    }
}

fn wait_until(limit: Duration, mut done: impl FnMut() -> bool) -> bool {
    let until = Instant::now() + limit;
    while Instant::now() < until {
        if done() {
            return true;
        }
        thread::sleep(Duration::from_millis(20));
    }
    done()
}

fn bash_call(id: i64, command: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "method": "tools/call",
           "params": {"name": "bash", "arguments": {"command": command}}})
}

/// A scratch file path unique to this test process and `tag`.
fn scratch(tag: &str) -> std::path::PathBuf {
    let p = std::env::temp_dir().join(format!("ra-liveness-{}-{tag}", std::process::id()));
    let _ = std::fs::remove_file(&p);
    p
}

/// Gone, or a zombie waiting for its reaper.
fn pid_is_dead(pid: i32) -> bool {
    match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
        Err(_) => true,
        Ok(stat) => stat
            .rsplit_once(") ")
            .is_some_and(|(_, rest)| rest.starts_with('Z')),
    }
}

fn read_pid(path: &std::path::Path) -> Option<i32> {
    std::fs::read_to_string(path).ok()?.trim().parse().ok()
}

/// #70: a tool call longer than the runtime's ping budget must not silence the
/// socket. The runtime evicts after ~0.8 s without an inbound frame and the call
/// takes 2.5 s. Our own keepalive is off, so only answered pings keep the attach
/// alive. Fails on the code before #70, which answered frames inline in the
/// read loop.
#[test]
fn slow_tool_call_survives_the_runtime_ping_budget() {
    let runtime = Runtime::start(Plan {
        ping_every: Some(Duration::from_millis(200)),
        max_missed: 3,
        calls: vec![bash_call(2, "sleep 2.5"), bash_call(3, "echo fast")],
        close_first: None,
    });
    let client = Client::start(runtime.port, None);
    let answered = wait_until(Duration::from_secs(10), || {
        runtime
            .conns()
            .first()
            .is_some_and(|c| c.replies.len() == 2 || c.evicted)
    });
    let conns = runtime.conns();
    assert!(answered, "calls were not answered: {conns:?}");
    let first = &conns[0];
    assert!(
        !first.evicted,
        "the runtime evicted the node during a slow call"
    );
    assert!(
        first.pongs >= 5,
        "pings must be answered while the tool runs: {first:?}"
    );
    assert_eq!(
        first.replies,
        vec![3, 2],
        "the fast call is answered while the slow one runs"
    );
    assert_eq!(conns.len(), 1, "no redial: {conns:?}");
    assert_eq!(client.state().0, "attached");
}

/// The second safeguard: while attached we ping the runtime ourselves.
#[test]
fn client_sends_its_own_keepalive_pings() {
    let runtime = Runtime::start(Plan {
        ping_every: None,
        max_missed: 3,
        calls: vec![],
        close_first: None,
    });
    let _client = Client::start(runtime.port, Some(Duration::from_millis(200)));
    let pinged = wait_until(Duration::from_secs(5), || {
        runtime.conns().first().is_some_and(|c| c.client_pings >= 3)
    });
    assert!(
        pinged,
        "keepalive pings reach the runtime: {:?}",
        runtime.conns()
    );
}

/// 4011 (liveness close, openab-pty CLIENT-CONTRACT §9) is retryable: the grant
/// redials and is served again on the new connection.
#[test]
fn liveness_close_4011_redials() {
    let runtime = Runtime::start(Plan {
        ping_every: None,
        max_missed: 3,
        calls: vec![],
        close_first: Some((Duration::from_millis(200), 4011)),
    });
    let client = Client::start(runtime.port, None);
    let redialled = wait_until(Duration::from_secs(5), || {
        runtime.conns().get(1).is_some_and(|c| c.replies == [1])
    });
    assert!(redialled, "no redial after 4011: {:?}", runtime.conns());
    assert_eq!(client.state(), ("attached".to_string(), None));
}

/// A call still running when its socket closes is cancelled: its process group
/// is killed, and nothing of it reaches the next connection.
#[test]
fn calls_running_when_the_socket_closes_are_cancelled() {
    let pidfile = scratch("closed");
    let command = format!("sleep 30 & echo $! > {}; wait", pidfile.display());
    let runtime = Runtime::start(Plan {
        ping_every: None,
        max_missed: 3,
        calls: vec![bash_call(2, &command)],
        close_first: Some((Duration::from_millis(300), 1000)),
    });
    let _client = Client::start(runtime.port, None);
    let redialled = wait_until(Duration::from_secs(5), || {
        runtime.conns().get(1).is_some_and(|c| c.replies == [1])
    });
    assert!(redialled, "no redial after 1000: {:?}", runtime.conns());
    let pid = read_pid(&pidfile).expect("the call started");
    assert!(
        wait_until(Duration::from_secs(2), || pid_is_dead(pid)),
        "the dropped call's process group was not killed"
    );
    thread::sleep(Duration::from_millis(300));
    let conns = runtime.conns();
    assert!(conns[0].replies.is_empty(), "{conns:?}");
    assert_eq!(
        conns[1].replies,
        vec![1],
        "only the new initialize is answered"
    );
    let _ = std::fs::remove_file(&pidfile);
}

/// DELETE reaches calls in flight and ends the attach promptly.
#[test]
fn revoking_the_grant_cancels_calls_in_flight() {
    let pidfile = scratch("revoked");
    let command = format!("sleep 30 & echo $! > {}; wait", pidfile.display());
    let runtime = Runtime::start(Plan {
        ping_every: None,
        max_missed: 3,
        calls: vec![bash_call(2, &command)],
        close_first: None,
    });
    let mut client = Client::start(runtime.port, None);
    assert!(
        wait_until(Duration::from_secs(5), || read_pid(&pidfile).is_some()),
        "the call did not start"
    );
    let pid = read_pid(&pidfile).unwrap();
    let took = client.revoke();
    assert!(took < Duration::from_secs(1), "revoke took {took:?}");
    assert!(
        wait_until(Duration::from_secs(2), || pid_is_dead(pid)),
        "the revoked grant's call was not killed"
    );
    let _ = std::fs::remove_file(&pidfile);
}

/// On an attach a `bash` over 100 s is refused as a tool error (the runtime
/// fails any call after 120 s); 100 s is allowed, and the local HTTP `/mcp`
/// path keeps its 600 s ceiling.
#[test]
fn attached_bash_over_100_seconds_is_refused() {
    use crate::mcp::{answer, answer_attached};
    let call = |timeout: u64| {
        json!({"jsonrpc": "2.0", "id": 7, "method": "tools/call",
               "params": {"name": "bash",
                          "arguments": {"command": "true", "timeout_secs": timeout}}})
        .to_string()
    };
    let cancel = AtomicBool::new(false);
    let parse = |s: Option<String>| serde_json::from_str::<Value>(&s.unwrap()).unwrap();

    let refused = parse(answer_attached(&call(101), "owner", &cancel));
    assert_eq!(refused["id"], 7);
    assert_eq!(refused["result"]["isError"], true, "{refused}");
    let message = refused["result"]["content"][0]["text"].as_str().unwrap();
    assert!(
        message.contains("100 s") && message.contains("background"),
        "{message}"
    );

    let allowed = parse(answer_attached(&call(100), "owner", &cancel));
    assert_eq!(
        allowed["result"]["structuredContent"]["exit_code"], 0,
        "{allowed}"
    );

    let http = parse(answer(&call(101), "owner"));
    assert_eq!(
        http["result"]["structuredContent"]["exit_code"], 0,
        "{http}"
    );
}

/// Every profile is told to keep calls short; profiles with input tools are
/// told to issue them one at a time.
#[test]
fn initialize_carries_the_long_call_and_ui_order_instructions() {
    let init = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#;
    let instructions = |profile: &str| {
        let v: Value = serde_json::from_str(&crate::mcp::answer(init, profile).unwrap()).unwrap();
        v["result"]["instructions"].as_str().unwrap().to_string()
    };
    let owner = instructions("owner");
    assert!(owner.contains("60 seconds"), "{owner}");
    assert!(owner.contains("one at a time"), "{owner}");
    let observe = instructions("observe");
    assert!(observe.contains("60 seconds"), "{observe}");
    assert!(!observe.contains("bash"), "observe has no bash: {observe}");
}

/// #75: a finished call's reply goes out within a busy read, not after the next
/// idle read timeout. The idle read is stretched to 5 s and nothing else
/// (runtime ping, keepalive) ends it, so a reply that waits for it arrives about
/// 5 s after the call starts instead of about 0.3 s.
#[test]
fn a_finished_call_is_answered_before_the_idle_read_timeout() {
    let runtime = Runtime::start(Plan {
        ping_every: None,
        max_missed: 3,
        calls: vec![bash_call(2, "sleep 0.3")],
        close_first: None,
    });
    let started = Instant::now();
    let _client = Client::start_tuned(
        runtime.port,
        DialTuning {
            keepalive: None,
            stable_after: Duration::from_secs(60),
            idle_read_poll: Duration::from_secs(5),
        },
    );
    let answered = wait_until(Duration::from_secs(8), || {
        runtime.conns().first().is_some_and(|c| c.replies == [2])
    });
    let took = started.elapsed();
    assert!(answered, "the call was not answered: {:?}", runtime.conns());
    assert!(
        took < Duration::from_secs(2),
        "the reply waited for the idle read timeout: {took:?}"
    );
}

/// #75: the socket loop reads the in-flight count, then drains the outbox, and
/// relies on a call queuing its reply before it stops counting. Applies the
/// loop's rule to many quick calls: once the count reads zero the reply must
/// already be queued.
#[test]
fn a_call_queues_its_reply_before_it_stops_counting() {
    let (replies, outbox) = mpsc::channel::<String>();
    let cancel = Arc::new(AtomicBool::new(false));
    let in_flight = Arc::new(AtomicUsize::new(0));
    let calls = Calls {
        profile: "owner",
        replies: &replies,
        cancel: &cancel,
        in_flight: &in_flight,
    };
    for id in 0..500 {
        let frame = json!({"jsonrpc": "2.0", "id": id, "method": "tools/list"});
        spawn_call(frame.to_string(), &calls);
        while in_flight.load(Ordering::Acquire) > 0 {
            std::hint::spin_loop();
        }
        let reply = outbox
            .try_recv()
            .unwrap_or_else(|_| panic!("call {id}: count was zero before its reply was queued"));
        let v: Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["id"], id, "{v}");
    }
}

/// #75: a request whose call thread cannot start is answered at once with a
/// JSON-RPC internal error carrying its id, and stops counting as in flight.
#[test]
fn a_call_thread_that_cannot_start_is_answered_with_an_error() {
    let (replies, outbox) = mpsc::channel::<String>();
    let cancel = Arc::new(AtomicBool::new(false));
    let in_flight = Arc::new(AtomicUsize::new(0));
    let calls = Calls {
        profile: "owner",
        replies: &replies,
        cancel: &cancel,
        in_flight: &in_flight,
    };
    let fail = |_job: CallJob| Err(std::io::Error::other("injected spawn failure"));

    for id in [json!(7), json!("call-7")] {
        let frame = json!({"jsonrpc": "2.0", "id": id, "method": "tools/list"});
        spawn_call_on(frame.to_string(), &calls, fail);
        let reply: Value =
            serde_json::from_str(&outbox.try_recv().expect("an error reply")).unwrap();
        assert_eq!(reply["jsonrpc"], "2.0", "{reply}");
        assert_eq!(reply["id"], id, "{reply}");
        assert_eq!(reply["error"]["code"], -32603, "{reply}");
        assert!(reply.get("result").is_none(), "{reply}");
        assert_eq!(
            in_flight.load(Ordering::Acquire),
            0,
            "the busy count leaked"
        );
    }

    // A notification gets no reply, as from `answer`.
    let note = json!({"jsonrpc": "2.0", "method": "notifications/initialized"}).to_string();
    spawn_call_on(note.clone(), &calls, fail);
    assert!(outbox.try_recv().is_err(), "{note} was answered");
    assert_eq!(
        in_flight.load(Ordering::Acquire),
        0,
        "the busy count leaked"
    );

    // A frame that does not parse gets the envelope error `answer` gives it,
    // with a null id (#78).
    for (frame, code) in [("not json", -32700), (r#"[{"jsonrpc":"2.0"}]"#, -32600)] {
        spawn_call_on(frame.to_string(), &calls, fail);
        let reply: Value =
            serde_json::from_str(&outbox.try_recv().expect("an error reply")).unwrap();
        assert_eq!(reply["id"], Value::Null, "{reply}");
        assert_eq!(reply["error"]["code"], code, "{reply}");
        assert_eq!(
            in_flight.load(Ordering::Acquire),
            0,
            "the busy count leaked"
        );
    }
}
