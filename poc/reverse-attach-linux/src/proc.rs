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
//! A `SIGKILL` of the installer cannot run `stop`. The next start's sweep (`sweep.rs`) removes what
//! the process-tree layers left, and `pdeathsig` has already ended the group leader.
//!
//! L2: the leader is a session leader (`setsid`), every signal to a process found by walking `/proc`
//! goes through a pidfd (`pidfd_open`, a second check of the process, `pidfd_send_signal`), never a
//! bare PID, and a child can carry the name of the transient unit that contains it so that `stop`
//! stops the unit first. `PR_SET_PDEATHSIG` is tied to the thread that forked the child, so
//! long-lived children are spawned from `child::Spawner`'s thread, which never exits.

use std::io::{BufRead, Read};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
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
    /// Chromium says another process holds the profile (a lock, not a missing sandbox).
    ProfileLocked,
    None,
}

/// The transient unit that contains a child, and how to stop it. `stop` runs first on `Child::stop`.
pub struct UnitCtl {
    pub name: String,
    pub stop: Box<dyn Fn(&str) + Send + Sync>,
}

pub struct Child {
    child: std::process::Child,
    scope: PathBuf,
    unit: Option<UnitCtl>,
    pub stdin: Option<std::process::ChildStdin>,
    pub lines: Option<Receiver<Line>>,
    ring: Arc<Mutex<Vec<u8>>>,
    /// Set by the stderr reader thread at end of file. A classification reads the ring only after
    /// the last line had its chance to arrive (`settle_stderr`).
    stderr_done: Arc<AtomicBool>,
    stopped: bool,
    reaped: bool,
    /// Live run records of *other* children, asked once per stop. A process one of them claims is
    /// not killed by the tree walk, so two children that run from one version directory (the
    /// daemon's and a sign-in) never end each other's grandchildren.
    others: Option<OthersLive>,
}

/// Returns the live run records of every child but this one.
/// `None` means the live records could not be read: the walk then does not run (fail closed).
pub type OthersLive = Box<dyn Fn() -> Option<Vec<crate::run_record::Record>> + Send + Sync>;

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
        Child::spawn_with(spec, stdin_pipe, stdout_pipe, line_cap, scope, None)
    }

    /// [`Child::spawn`] for a child that runs inside a transient unit.
    pub fn spawn_with(
        spec: &Spec,
        stdin_pipe: bool,
        stdout_pipe: bool,
        line_cap: usize,
        scope: &Path,
        unit: Option<UnitCtl>,
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
            .stderr(Stdio::piped());
        #[cfg(not(target_os = "linux"))]
        cmd.process_group(0);
        #[cfg(target_os = "linux")]
        {
            // SAFETY: the closure only calls setsid and prctl through rustix, both raw system calls
            // and async-signal-safe.
            unsafe {
                cmd.pre_exec(|| {
                    // A new session and process group: `killpg` reaches node and its non-detached
                    // helpers, and the child has no controlling terminal.
                    rustix::process::setsid().map_err(std::io::Error::from)?;
                    rustix::process::set_parent_process_death_signal(Some(Signal::KILL))
                        .map_err(std::io::Error::from)
                });
            }
        }
        let mut child = cmd.spawn()?;
        let ring: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(Vec::new()));
        let stderr_done = Arc::new(AtomicBool::new(false));
        if let Some(mut err) = child.stderr.take() {
            let ring = Arc::clone(&ring);
            let done = Arc::clone(&stderr_done);
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
                done.store(true, Ordering::Release);
            });
        } else {
            stderr_done.store(true, Ordering::Release);
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
            unit,
            stdin,
            lines,
            ring,
            stderr_done,
            stopped: false,
            reaped: false,
            others: None,
        })
    }

    pub fn pid(&self) -> u32 {
        self.child.id()
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

    /// Waits (at most 250 ms) for the stderr reader to reach end of file. A child that printed its
    /// refusal and exited closes stdout before the reader thread has necessarily queued that last
    /// line, so a classification made at once could read an empty ring and call a refusal a plain
    /// failure. A child that is still running never reaches end of file, so this is a bounded delay
    /// on a failure path, never on a success. This is production code, not a test aid: every
    /// classification of a failed child goes through it. Pinned by
    /// `a_child_that_prints_nothing_on_stderr_is_classified_without_waiting_for_a_timeout`.
    fn settle_stderr(&self) {
        let end = Instant::now() + Duration::from_millis(250);
        while !self.stderr_done.load(Ordering::Acquire) && Instant::now() < end {
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    /// A yes/no read of the stderr ring. The text never leaves.
    pub fn stderr_class(&self) -> StderrClass {
        self.settle_stderr();
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
        const LOCKED: [&str; 2] = ["profile appears to be in use", "singletonlock"];
        if REFUSED.iter().any(|s| text.contains(s)) {
            StderrClass::LaunchRefused
        } else if LOCKED.iter().any(|s| text.contains(s)) {
            StderrClass::ProfileLocked
        } else {
            StderrClass::None
        }
    }

    /// Did Chromium say it has no usable sandbox? Narrower than [`stderr_class`]: the installer's
    /// health check may call any permission error a refusal, but a runtime refusal latches the
    /// backend and is recorded for D17, so it needs the sandbox's own words. A yes/no; no text leaves.
    pub fn stderr_sandbox_refused(&self) -> bool {
        self.stderr_contains_any(&[
            "no usable sandbox",
            "failed to move to new namespace",
            "user namespace",
        ])
    }

    pub fn stderr_contains_any(&self, needles: &[&str]) -> bool {
        self.settle_stderr();
        let text = self
            .ring
            .lock()
            .map(|r| String::from_utf8_lossy(&r).to_lowercase())
            .unwrap_or_default();
        needles.iter().any(|n| text.contains(n))
    }

    /// Makes the tree walk of `stop` leave alone what another live run record claims.
    pub fn set_others(&mut self, f: OthersLive) {
        self.others = Some(f);
    }

    /// Stops the whole tree and reaps the leader. Safe to call more than once.
    pub fn stop(&mut self) {
        if self.stopped {
            return;
        }
        self.stopped = true;
        self.stdin = None;
        if let Some(u) = &self.unit {
            (u.stop)(&u.name);
        }
        // A group id is a number: it names this group only while the leader is not reaped (an
        // unreaped leader, even a zombie, keeps its PID from being reused). After a reap the number
        // could belong to anything, so it is not signalled; the tree walk below, which goes through
        // pidfds, still finds every process of the tree.
        let pgid = if self.reaped {
            None
        } else {
            Pid::from_raw(self.child.id() as i32)
        };
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
        let scope = self.scope.clone();
        match &self.others {
            None => kill_under(&scope),
            // Unknown live records: the walk could end a sibling's helpers, so it is skipped. The
            // process group and the unit are already stopped, and the next sweep finds the rest.
            Some(f) => {
                if let Some(live) = f() {
                    kill_matching(&|exe| exe.starts_with(&scope), &|pid| {
                        crate::sweep::claimed(pid, &live)
                    });
                }
            }
        }
        let _ = self.child.wait();
    }
}

impl Drop for Child {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Kills every process of this user, other than this one, whose executable is below `scope`.
pub fn kill_under(scope: &Path) {
    kill_matching(&|exe| exe.starts_with(scope), &|_| false);
}

pub fn same_uid(pid: u32) -> bool {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(format!("/proc/{pid}"))
        .is_ok_and(|m| m.uid() == rustix::process::geteuid().as_raw())
}

/// Every numeric entry of `/proc`, at most `PROC_LIMIT`.
pub fn proc_pids() -> Vec<u32> {
    let Ok(rd) = std::fs::read_dir("/proc") else {
        return Vec::new();
    };
    rd.flatten()
        .take(PROC_LIMIT)
        .filter_map(|e| e.file_name().to_str().and_then(|s| s.parse::<u32>().ok()))
        .collect()
}

const PROC_LIMIT: usize = 4_000_000;

/// Kills every process of this user, other than this one, whose executable satisfies `matches` and
/// that `protect` does not claim. Returns how many were signalled. The test is applied to what the
/// pidfd names (see [`kill_pid_checked`]), not to the PID the scan saw.
pub fn kill_matching(matches: &dyn Fn(&Path) -> bool, protect: &dyn Fn(u32) -> bool) -> usize {
    let me = std::process::id();
    let wanted = |pid: u32| {
        pid != me
            && same_uid(pid)
            && std::fs::read_link(format!("/proc/{pid}/exe")).is_ok_and(|p| matches(&p))
            && !protect(pid)
    };
    let mut n = 0;
    for pid in proc_pids() {
        if wanted(pid) && kill_pid_checked(pid, &wanted) {
            n += 1;
        }
    }
    n
}

/// Sends `SIGKILL` to `pid` only if `recheck(pid)` still holds after a pidfd for it exists.
///
/// A number read from `/proc` can name a different process by the time it is used. `pidfd_open`
/// pins the process the number names *now*; `recheck` then examines that same number, which cannot
/// be reused until the process is reaped, and `pidfd_send_signal` can only reach the pinned process
/// (or fail with `ESRCH` if it has exited). A process that fails the recheck is never signalled.
#[cfg(target_os = "linux")]
pub fn kill_pid_checked(pid: u32, recheck: &dyn Fn(u32) -> bool) -> bool {
    let Some(p) = Pid::from_raw(pid as i32) else {
        return false;
    };
    let Ok(fd) = rustix::process::pidfd_open(p, rustix::process::PidfdFlags::empty()) else {
        return false;
    };
    recheck(pid) && rustix::process::pidfd_send_signal(&fd, Signal::KILL).is_ok()
}

/// There is no `/proc` walk off Linux, so nothing reaches this.
#[cfg(not(target_os = "linux"))]
pub fn kill_pid_checked(_pid: u32, _recheck: &dyn Fn(u32) -> bool) -> bool {
    false
}

/// Fields of `/proc/<pid>/stat` the sweep needs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StatFields {
    pub ppid: u32,
    pub pgrp: u32,
    pub session: u32,
    pub start: u64,
}

pub fn stat_fields(pid: u32) -> Option<StatFields> {
    let mut buf = Vec::new();
    std::fs::File::open(format!("/proc/{pid}/stat"))
        .ok()?
        .take(4096)
        .read_to_end(&mut buf)
        .ok()?;
    let s = String::from_utf8_lossy(&buf);
    // Fields start after the last ')': state ppid pgrp session ... starttime is the 20th.
    let rest: Vec<&str> = s[s.rfind(')')? + 1..].split_whitespace().collect();
    Some(StatFields {
        ppid: rest.get(1)?.parse().ok()?,
        pgrp: rest.get(2)?.parse().ok()?,
        session: rest.get(3)?.parse().ok()?,
        start: rest.get(19)?.parse().ok()?,
    })
}

/// The `*.service` or `*.scope` the process is in (last component of its cgroup v2 path).
pub fn cgroup_unit(pid: u32) -> Option<String> {
    let mut buf = Vec::new();
    std::fs::File::open(format!("/proc/{pid}/cgroup"))
        .ok()?
        .take(8192)
        .read_to_end(&mut buf)
        .ok()?;
    unit_of_cgroup(&String::from_utf8_lossy(&buf))
}

pub fn unit_of_cgroup(text: &str) -> Option<String> {
    let line = text.lines().find_map(|l| l.strip_prefix("0::"))?;
    let last = line.rsplit('/').next()?;
    (last.ends_with(".service") || last.ends_with(".scope")).then(|| last.to_string())
}

#[cfg(test)]
#[path = "proc_tests.rs"]
mod tests;
