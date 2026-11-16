//! Child processes of the installer: the staged `npm` and the health-check Playwright MCP (L1b).
//! L2's managed child is a different, fuller mechanism; this one only has to guarantee that nothing
//! the installer started outlives the installer's staging directory.
//!
//! - The environment is an allow-list (`env_clear` plus the given pairs), stdin and stdout are
//!   pipes or null, stderr goes into a 64 KiB ring that only yes/no signatures leave.
//! - The child is a process-group leader, and on Linux `PR_SET_PDEATHSIG(SIGKILL)` is set, so the
//!   installer being killed takes the leader with it.
//! - `stop` closes stdin, sends `SIGTERM` to the group, waits two seconds, sends `SIGKILL` to the
//!   group, then kills every process of this user whose executable lives under the scope directory
//!   (a detached Chromium helper), re-reading the link before each kill, and finally reaps.
//!   Dropping a `Child` does the same.
//!
//! A `SIGKILL` of the installer cannot run `stop`. The next install's staging sweep removes the
//! leftover directory, and `pdeathsig` has already ended the group leader. That is a known limit
//! until L2's start-time sweep exists.

use std::io::{BufRead, Read};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rustix::process::{Pid, Signal};

pub const RING_CAP: usize = 64 * 1024;

pub struct Spec {
    pub exe: PathBuf,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
    pub cwd: PathBuf,
}

/// What the stdout reader thread delivers.
#[derive(Debug, PartialEq, Eq)]
pub enum Line {
    Data(Vec<u8>),
    /// A line longer than the cap. The reader stops after sending this.
    TooLong,
    Eof,
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum StderrClass {
    LaunchRefused,
    None,
}

pub struct Child {
    child: std::process::Child,
    scope: PathBuf,
    pub stdin: Option<std::process::ChildStdin>,
    pub lines: Option<Receiver<Line>>,
    ring: Arc<Mutex<Vec<u8>>>,
    stopped: bool,
    reaped: bool,
}

/// Reads one newline-terminated line of at most `cap` bytes (the newline excluded).
fn read_line_capped<R: BufRead>(r: &mut R, cap: usize) -> std::io::Result<Line> {
    let mut out: Vec<u8> = Vec::new();
    loop {
        let (done, used) = {
            let buf = r.fill_buf()?;
            if buf.is_empty() {
                return Ok(if out.is_empty() {
                    Line::Eof
                } else {
                    Line::Data(out)
                });
            }
            match buf.iter().position(|b| *b == b'\n') {
                Some(i) => {
                    if out.len() + i > cap {
                        return Ok(Line::TooLong);
                    }
                    out.extend_from_slice(&buf[..i]);
                    (true, i + 1)
                }
                None => {
                    if out.len() + buf.len() > cap {
                        return Ok(Line::TooLong);
                    }
                    out.extend_from_slice(buf);
                    (false, buf.len())
                }
            }
        };
        r.consume(used);
        if done {
            return Ok(Line::Data(out));
        }
    }
}

/// `read_line_capped` over a whole stream, for tests.
#[cfg(test)]
pub fn lines_of(data: &[u8], cap: usize) -> Vec<Line> {
    let mut r = std::io::BufReader::new(data);
    let mut v = Vec::new();
    loop {
        let l = read_line_capped(&mut r, cap).unwrap();
        let stop = matches!(l, Line::Eof | Line::TooLong);
        v.push(l);
        if stop {
            return v;
        }
    }
}

/// Parsed lines that may wait unread. A child that writes faster than the caller reads blocks on
/// its own pipe instead of growing memory (each line may be up to the line cap).
const LINE_QUEUE: usize = 4;

impl Child {
    /// Starts the child. `scope` is the directory whose files the child executes (staging); it is
    /// resolved now so the later `/proc` walk compares real paths.
    pub fn spawn(
        spec: &Spec,
        stdin_pipe: bool,
        stdout_pipe: bool,
        line_cap: usize,
        scope: &Path,
    ) -> std::io::Result<Child> {
        let scope = std::fs::canonicalize(scope)?;
        let mut cmd = Command::new(&spec.exe);
        cmd.args(&spec.args)
            .env_clear()
            .envs(spec.env.iter().map(|(k, v)| (k, v)))
            .current_dir(&spec.cwd)
            .stdin(if stdin_pipe {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(if stdout_pipe {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stderr(Stdio::piped())
            .process_group(0);
        #[cfg(target_os = "linux")]
        {
            // SAFETY: the closure only calls prctl through rustix, which is async-signal-safe.
            unsafe {
                cmd.pre_exec(|| {
                    rustix::process::set_parent_process_death_signal(Some(Signal::KILL))
                        .map_err(std::io::Error::from)
                });
            }
        }
        let mut child = cmd.spawn()?;
        let ring: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(Vec::new()));
        if let Some(mut err) = child.stderr.take() {
            let ring = Arc::clone(&ring);
            std::thread::spawn(move || {
                let mut buf = [0u8; 4096];
                while let Ok(n) = err.read(&mut buf) {
                    if n == 0 {
                        break;
                    }
                    if let Ok(mut r) = ring.lock() {
                        r.extend_from_slice(&buf[..n]);
                        if r.len() > RING_CAP {
                            let cut = r.len() - RING_CAP;
                            r.drain(..cut);
                        }
                    }
                }
            });
        }
        let lines = child.stdout.take().map(|out| {
            let (tx, rx) = mpsc::sync_channel(LINE_QUEUE);
            std::thread::spawn(move || {
                let mut r = std::io::BufReader::with_capacity(64 * 1024, out);
                loop {
                    match read_line_capped(&mut r, line_cap) {
                        Ok(Line::Data(l)) => {
                            if tx.send(Line::Data(l)).is_err() {
                                return;
                            }
                        }
                        Ok(other) => {
                            let _ = tx.send(other);
                            return;
                        }
                        Err(_) => {
                            let _ = tx.send(Line::Eof);
                            return;
                        }
                    }
                }
            });
            rx
        });
        let stdin = child.stdin.take();
        Ok(Child {
            child,
            scope,
            stdin,
            lines,
            ring,
            stopped: false,
            reaped: false,
        })
    }

    /// Has the leader exited? Does not reap it.
    pub fn has_exited(&self) -> bool {
        if self.reaped {
            return true;
        }
        let Some(pid) = Pid::from_raw(self.child.id() as i32) else {
            return true;
        };
        matches!(
            rustix::process::waitid(
                rustix::process::WaitId::Pid(pid),
                rustix::process::WaitIdOptions::EXITED
                    | rustix::process::WaitIdOptions::NOHANG
                    | rustix::process::WaitIdOptions::NOWAIT,
            ),
            Ok(Some(_))
        )
    }

    /// Exit status once the leader has exited. Reaps it.
    pub fn exit_ok(&mut self) -> Option<bool> {
        let st = self.child.try_wait().ok().flatten()?;
        self.reaped = true;
        Some(st.success())
    }

    /// A yes/no read of the stderr ring. The text never leaves.
    pub fn stderr_class(&self) -> StderrClass {
        let text = self
            .ring
            .lock()
            .map(|r| String::from_utf8_lossy(&r).to_lowercase())
            .unwrap_or_default();
        const REFUSED: [&str; 5] = [
            "no usable sandbox",
            "operation not permitted",
            "eacces",
            "user namespace",
            "failed to move to new namespace",
        ];
        if REFUSED.iter().any(|s| text.contains(s)) {
            StderrClass::LaunchRefused
        } else {
            StderrClass::None
        }
    }

    pub fn stderr_contains_any(&self, needles: &[&str]) -> bool {
        let text = self
            .ring
            .lock()
            .map(|r| String::from_utf8_lossy(&r).to_lowercase())
            .unwrap_or_default();
        needles.iter().any(|n| text.contains(n))
    }

    /// Stops the whole tree and reaps the leader. Safe to call more than once.
    pub fn stop(&mut self) {
        if self.stopped {
            return;
        }
        self.stopped = true;
        self.stdin = None;
        let pgid = Pid::from_raw(self.child.id() as i32);
        if let Some(g) = pgid {
            let _ = rustix::process::kill_process_group(g, Signal::TERM);
        }
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline && !self.has_exited() {
            std::thread::sleep(Duration::from_millis(20));
        }
        // The leader has not been reaped yet, so its process group id cannot have been reused.
        if let Some(g) = pgid {
            let _ = rustix::process::kill_process_group(g, Signal::KILL);
        }
        kill_under(&self.scope);
        let _ = self.child.wait();
    }
}

impl Drop for Child {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Kills every process of this user, other than this one, whose executable is below `scope`. The
/// link is read again immediately before each kill.
pub fn kill_under(scope: &Path) {
    let me = std::process::id();
    let uid = rustix::process::geteuid().as_raw();
    let Ok(rd) = std::fs::read_dir("/proc") else {
        return;
    };
    for e in rd.flatten() {
        let Some(pid) = e.file_name().to_str().and_then(|s| s.parse::<u32>().ok()) else {
            continue;
        };
        if pid == me {
            continue;
        }
        let under = |pid: u32| {
            std::fs::read_link(format!("/proc/{pid}/exe")).is_ok_and(|p| p.starts_with(scope))
        };
        use std::os::unix::fs::MetadataExt;
        let ours = std::fs::metadata(format!("/proc/{pid}")).is_ok_and(|m| m.uid() == uid);
        if ours && under(pid) && under(pid) {
            if let Some(p) = Pid::from_raw(pid as i32) {
                let _ = rustix::process::kill_process(p, Signal::KILL);
            }
        }
    }
}

#[cfg(test)]
#[path = "proc_tests.rs"]
mod tests;
