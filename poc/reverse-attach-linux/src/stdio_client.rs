//! The long-lived JSON-RPC client over the managed child's stdin and stdout (R1.4; L2). Counterpart
//! of the Swift `StdioMCPClient`; `health.rs` keeps its own one-shot client for the installer.
//!
//! - Wire: newline-delimited JSON-RPC. A line is at most `MAX_LINE` (8 MiB); a longer one ends the
//!   client with `upstream_bad_body`. stdout carries protocol only; the child's stderr is read by
//!   `proc::Child` into its own 64 KiB ring and never reaches this module.
//! - Many callers at once: calls get ids and a pending map (at most `MAX_PENDING`); one reader
//!   thread routes answers by id. A frame is queued to one writer thread (at most `WRITE_BUDGET`
//!   bytes queued, each frame under `MAX_LINE`), so a child that stops reading its stdin can stall
//!   the writer but never a caller, whose own timeout still runs.
//! - A call that times out sends `notifications/cancelled` for its id and returns `upstream_timeout`.
//! - A child that exits (EOF) or breaks the framing fails every pending call and ends the client.
//! - Errors are fixed classes (`Class`). No text of the child, of stderr or of a tool result is ever
//!   copied into an error. A successful result is returned as it came.

use std::collections::HashMap;
use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender, SyncSender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::proc::Line;

pub const MAX_LINE: usize = crate::health::MAX_LINE;
pub const MAX_PENDING: usize = 64;
/// Bytes that may wait for the writer thread at once.
const WRITE_BUDGET: usize = 32 * 1024 * 1024;
/// Lines that are not JSON-RPC at all, tolerated before the client gives up.
const MAX_STRAY_LINES: usize = 1000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Class {
    Timeout,
    BadBody,
    RpcError,
    Unreachable,
    Busy,
}

impl Class {
    pub fn name(self) -> &'static str {
        match self {
            Class::Timeout => "upstream_timeout",
            Class::BadBody => "upstream_bad_body",
            Class::RpcError => "upstream_rpc_error",
            Class::Unreachable => "upstream_unreachable",
            Class::Busy => "upstream_busy",
        }
    }
}

type Reply = Result<Value, Class>;

pub struct Client {
    writer: Mutex<Option<Sender<Vec<u8>>>>,
    queued: AtomicUsize,
    pending: Mutex<HashMap<u64, SyncSender<Reply>>>,
    next: AtomicU64,
    dead: AtomicBool,
    last_rx: Mutex<Instant>,
}

impl Client {
    /// Starts the reader and writer threads over a child's stdin and line receiver.
    pub fn start(writer: Box<dyn Write + Send>, lines: Receiver<Line>) -> Arc<Client> {
        let (tx, wrx) = mpsc::channel::<Vec<u8>>();
        let c = Arc::new(Client {
            writer: Mutex::new(Some(tx)),
            queued: AtomicUsize::new(0),
            pending: Mutex::new(HashMap::new()),
            next: AtomicU64::new(1),
            dead: AtomicBool::new(false),
            last_rx: Mutex::new(Instant::now()),
        });
        let wc = Arc::clone(&c);
        std::thread::spawn(move || {
            let mut w = writer;
            while let Ok(frame) = wrx.recv() {
                let n = frame.len();
                let wrote = w.write_all(&frame).and_then(|_| w.flush());
                wc.queued.fetch_sub(n, Ordering::SeqCst);
                if wrote.is_err() {
                    wc.die(Class::Unreachable);
                    return;
                }
            }
            // The sender is gone: dropping `w` closes the child's stdin (EOF).
        });
        let rc = Arc::clone(&c);
        std::thread::spawn(move || rc.read_loop(lines));
        c
    }

    pub fn is_dead(&self) -> bool {
        self.dead.load(Ordering::SeqCst)
    }

    /// Time since the child last wrote a line.
    pub fn idle_for(&self) -> Duration {
        self.last_rx
            .lock()
            .map(|t| t.elapsed())
            .unwrap_or(Duration::ZERO)
    }

    /// Ends the client: pending calls fail with `class`, and the child's stdin is closed.
    fn die(&self, class: Class) {
        self.dead.store(true, Ordering::SeqCst);
        if let Ok(mut w) = self.writer.lock() {
            *w = None;
        }
        let drained: Vec<_> = self
            .pending
            .lock()
            .map(|mut p| p.drain().collect())
            .unwrap_or_default();
        for (_, tx) in drained {
            let _ = tx.try_send(Err(class));
        }
    }

    /// Closes the child's stdin and fails what is pending. Safe to call more than once.
    pub fn close(&self) {
        self.die(Class::Unreachable);
    }

    fn send_frame(&self, v: &Value) -> Result<(), Class> {
        let mut frame = serde_json::to_vec(v).map_err(|_| Class::BadBody)?;
        if frame.len() >= MAX_LINE {
            return Err(Class::BadBody);
        }
        frame.push(b'\n');
        let g = self.writer.lock().map_err(|_| Class::Unreachable)?;
        let Some(tx) = g.as_ref() else {
            return Err(Class::Unreachable);
        };
        let n = frame.len();
        if self.queued.fetch_add(n, Ordering::SeqCst) + n > WRITE_BUDGET {
            self.queued.fetch_sub(n, Ordering::SeqCst);
            return Err(Class::Busy);
        }
        tx.send(frame).map_err(|_| {
            self.queued.fetch_sub(n, Ordering::SeqCst);
            Class::Unreachable
        })
    }

    pub fn notify(&self, method: &str, params: Value) -> Result<(), Class> {
        if self.is_dead() {
            return Err(Class::Unreachable);
        }
        self.send_frame(&json!({"jsonrpc": "2.0", "method": method, "params": params}))
    }

    /// One request. Returns the `result` value, or a fixed class.
    pub fn call(&self, method: &str, params: Value, timeout: Duration) -> Result<Value, Class> {
        if self.is_dead() {
            return Err(Class::Unreachable);
        }
        let id = self.next.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = mpsc::sync_channel::<Reply>(1);
        {
            let mut p = self.pending.lock().map_err(|_| Class::Unreachable)?;
            if p.len() >= MAX_PENDING {
                return Err(Class::Busy);
            }
            p.insert(id, tx);
        }
        let sent = self
            .send_frame(&json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}));
        if let Err(c) = sent {
            self.forget(id);
            return Err(c);
        }
        match rx.recv_timeout(timeout) {
            Ok(r) => r,
            Err(RecvTimeoutError::Timeout) => {
                self.forget(id);
                // A late answer is dropped; the server is told to stop working on it.
                let _ = self.notify(
                    "notifications/cancelled",
                    json!({"requestId": id, "reason": "timeout"}),
                );
                Err(Class::Timeout)
            }
            Err(RecvTimeoutError::Disconnected) => Err(Class::Unreachable),
        }
    }

    /// `ping` with its own deadline: the health check (2 s in the router).
    pub fn ping(&self, timeout: Duration) -> bool {
        self.call("ping", json!({}), timeout).is_ok()
    }

    fn forget(&self, id: u64) {
        if let Ok(mut p) = self.pending.lock() {
            p.remove(&id);
        }
    }

    fn answer_server_request(&self, id: Value, method: &str) {
        let v = if method == "ping" {
            json!({"jsonrpc": "2.0", "id": id, "result": {}})
        } else {
            json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "Method not found"}})
        };
        let _ = self.send_frame(&v);
    }

    fn read_loop(&self, lines: Receiver<Line>) {
        let mut stray = 0usize;
        loop {
            let line = match lines.recv() {
                Ok(l) => l,
                Err(_) => return self.die(Class::Unreachable),
            };
            let bytes = match line {
                Line::Data(b) => b,
                Line::TooLong => return self.die(Class::BadBody),
                Line::Eof => return self.die(Class::Unreachable),
            };
            if let Ok(mut t) = self.last_rx.lock() {
                *t = Instant::now();
            }
            let Ok(v) = serde_json::from_slice::<Value>(&bytes) else {
                stray += 1;
                if stray > MAX_STRAY_LINES {
                    return self.die(Class::BadBody);
                }
                continue;
            };
            if let Some(m) = v.get("method").and_then(Value::as_str) {
                // A request from the server has an id and wants an answer; a notification is dropped.
                if let Some(id) = v.get("id").filter(|i| !i.is_null()) {
                    self.answer_server_request(id.clone(), m);
                }
                continue;
            }
            let Some(id) = v.get("id").and_then(Value::as_u64) else {
                continue;
            };
            let Some(tx) = self.pending.lock().ok().and_then(|mut p| p.remove(&id)) else {
                continue;
            };
            let reply = if v.get("error").is_some() {
                Err(Class::RpcError)
            } else {
                v.get("result").cloned().ok_or(Class::BadBody)
            };
            let _ = tx.try_send(reply);
        }
    }
}

#[cfg(test)]
#[path = "stdio_client_tests.rs"]
mod tests;
