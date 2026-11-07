//! Background jobs behind `exec_start` / `exec_poll` / `exec_list` / `exec_cancel`
//! (same contract as the Swift `JobRegistry`).
//!
//! Each job's stdout and stderr go straight to files, `<dir>/<job_id>.out` and
//! `<job_id>.err` (`$XDG_STATE_HOME/oab-instance-mcp/jobs/`, else
//! `~/.local/state/oab-instance-mcp/jobs/`). The files are the single source of
//! truth: `exec_poll` reads them by byte offset, nothing is kept in memory or
//! truncated, and a human can `tail -f` them.
//!
//! Jobs belong to the daemon, not to a connection. A reverse-attach socket that
//! drops cancels its in-flight calls (#72), but a job started over it keeps
//! running and can be polled from the next attach. A daemon restart forgets the
//! jobs (their processes and log files are left alone).
//!
//! Lifetime: every running job, plus the `KEEP_FINISHED` most recently finished
//! ones, stay in the registry. Log files older than `LOG_MAX_AGE` are deleted when
//! the registry opens and on each `exec_start`.

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime};

#[cfg(test)]
mod tests;
pub(crate) mod tools;

/// Running jobs allowed at once.
pub(crate) const MAX_RUNNING: usize = 64;
/// Finished jobs kept for `exec_poll` / `exec_list`; older ones are dropped.
pub(crate) const KEEP_FINISHED: usize = 10;
/// Job log files older than this are deleted.
pub(crate) const LOG_MAX_AGE: Duration = Duration::from_secs(7 * 86_400);
/// Most bytes one `exec_poll` returns per stream; the caller continues from
/// `stdout_next` / `stderr_next`.
pub(crate) const MAX_POLL_BYTES: usize = 1_048_576;
const SUPERVISE_EVERY: Duration = Duration::from_millis(50);

pub(crate) const SIGKILL: i32 = 9;
pub(crate) const SIGTERM: i32 = 15;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum JobState {
    Running,
    /// The job's shell exited on its own.
    Exited,
    /// Cancelled, timed out, or ended by a signal.
    Killed,
}

impl JobState {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            JobState::Running => "running",
            JobState::Exited => "exited",
            JobState::Killed => "killed",
        }
    }
}

struct Inner {
    /// `Some` until the leader is reaped. The process group is signalled only
    /// while this is `Some` and under this lock, and reaping happens only under
    /// it too: until then the leader's pid (= its process group id, `setsid`)
    /// cannot belong to anyone else (same rule as `bash`, #72).
    child: Option<Child>,
    timed_out: bool,
    state: JobState,
    exit_code: Option<i32>,
    finished_at: Option<SystemTime>,
}

pub(crate) struct Job {
    pub(crate) id: String,
    pub(crate) pid: u32,
    pub(crate) command: String,
    pub(crate) cwd: String,
    pub(crate) started_at: SystemTime,
    pub(crate) out_path: PathBuf,
    pub(crate) err_path: PathBuf,
    deadline: Option<Instant>,
    inner: Mutex<Inner>,
}

impl Job {
    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|p| p.into_inner())
    }

    pub(crate) fn state(&self) -> JobState {
        self.lock().state
    }

    pub(crate) fn exit_code(&self) -> Option<i32> {
        self.lock().exit_code
    }

    pub(crate) fn finished_at(&self) -> Option<SystemTime> {
        self.lock().finished_at
    }

    /// Signal the whole process group. False once the leader has been reaped:
    /// its pid may then be recycled, so nothing is sent.
    pub(crate) fn signal(&self, sig: i32) -> bool {
        let g = self.lock();
        if g.child.is_none() {
            return false;
        }
        unsafe { kill(-(self.pid as i32), sig) };
        true
    }

    /// One supervision step: reap the leader if it exited, kill the group at the
    /// deadline. Returns true once the job is terminal.
    fn supervise_once(&self) -> bool {
        let mut g = self.lock();
        let Some(child) = g.child.as_mut() else {
            return true;
        };
        match child.try_wait() {
            Ok(Some(status)) => {
                let timed_out = g.timed_out;
                finish(&mut g, Some(status), timed_out);
                true
            }
            Ok(None) => {
                if !g.timed_out && self.deadline.is_some_and(|d| Instant::now() >= d) {
                    unsafe { kill(-(self.pid as i32), SIGKILL) };
                    g.timed_out = true;
                }
                false
            }
            // Only we reap this child, so this should not happen; end the job
            // rather than signal a pid we can no longer vouch for.
            Err(_) => {
                finish(&mut g, None, false);
                true
            }
        }
    }
}

fn finish(g: &mut Inner, status: Option<ExitStatus>, timed_out: bool) {
    g.child = None;
    let signal = status.and_then(|s| s.signal());
    g.exit_code = Some(match (status, signal) {
        (_, Some(sig)) => 128 + sig,
        (Some(s), None) => s.code().unwrap_or(-1),
        (None, None) => -1,
    });
    g.state = if timed_out || signal.is_some() {
        JobState::Killed
    } else {
        JobState::Exited
    };
    g.finished_at = Some(SystemTime::now());
}

/// What `exec_start` asks for. `cwd` is already resolved and checked.
pub(crate) struct StartSpec<'a> {
    pub(crate) command: &'a str,
    pub(crate) cwd: &'a str,
    pub(crate) env: Vec<(String, String)>,
    /// `None` = no timeout (stop it with `exec_cancel`).
    pub(crate) timeout: Option<Duration>,
}

pub(crate) struct Registry {
    dir: PathBuf,
    jobs: Mutex<HashMap<String, Arc<Job>>>,
}

static REGISTRY: OnceLock<Result<Registry, String>> = OnceLock::new();

/// The daemon's registry, opened on first use.
pub(crate) fn registry() -> Result<&'static Registry, String> {
    REGISTRY
        .get_or_init(|| {
            let dir = default_dir().ok_or("no XDG_STATE_HOME or HOME for the job log directory")?;
            Registry::open(dir)
        })
        .as_ref()
        .map_err(|e| e.clone())
}

#[cfg(not(test))]
fn default_dir() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_STATE_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/state")))?;
    Some(base.join("oab-instance-mcp/jobs"))
}

/// Unit tests never write into the real state directory.
#[cfg(test)]
fn default_dir() -> Option<PathBuf> {
    Some(std::env::temp_dir().join(format!("oab-jobs-test-{}", std::process::id())))
}

impl Registry {
    /// Create (mode 700) or narrow the log directory, then delete old logs.
    pub(crate) fn open(dir: PathBuf) -> Result<Registry, String> {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir)
            .map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
        // Job output can hold secrets: owner only, even if the directory existed.
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))
            .map_err(|e| format!("cannot chmod {}: {e}", dir.display()))?;
        let reg = Registry {
            dir,
            jobs: Mutex::new(HashMap::new()),
        };
        reg.gc_logs(SystemTime::now());
        Ok(reg)
    }

    pub(crate) fn dir(&self) -> &Path {
        &self.dir
    }

    /// The job map with finished jobs beyond `KEEP_FINISHED` dropped.
    fn jobs(&self) -> MutexGuard<'_, HashMap<String, Arc<Job>>> {
        let mut map = self.jobs.lock().unwrap_or_else(|p| p.into_inner());
        let mut finished: Vec<(SystemTime, String)> = map
            .values()
            .filter_map(|j| j.finished_at().map(|t| (t, j.id.clone())))
            .collect();
        if finished.len() > KEEP_FINISHED {
            finished.sort_by_key(|a| std::cmp::Reverse(a.0));
            for (_, id) in finished.drain(KEEP_FINISHED..) {
                map.remove(&id);
            }
        }
        map
    }

    pub(crate) fn start(&self, spec: StartSpec<'_>) -> Result<Arc<Job>, String> {
        let mut map = self.jobs();
        self.gc_logs_except(SystemTime::now(), &map);
        let running = map
            .values()
            .filter(|j| j.state() == JobState::Running)
            .count();
        if running >= MAX_RUNNING {
            return Err(format!(
                "too many running jobs ({MAX_RUNNING}); cancel some or let them finish first"
            ));
        }
        let id = new_job_id()?;
        let out_path = self.dir.join(format!("{id}.out"));
        let err_path = self.dir.join(format!("{id}.err"));
        let out = create_log(&out_path)?;
        let err = match create_log(&err_path) {
            Ok(f) => f,
            Err(e) => {
                let _ = std::fs::remove_file(&out_path);
                return Err(e);
            }
        };

        let mut cmd = Command::new("bash");
        cmd.arg("-c")
            .arg(spec.command)
            .current_dir(spec.cwd)
            .stdin(Stdio::null())
            .stdout(out)
            .stderr(err);
        if std::env::var_os("TERM").is_none() {
            cmd.env("TERM", "dumb");
        }
        for (k, v) in &spec.env {
            cmd.env(k, v);
        }
        // A new session makes the job's pid its process group id, so a cancel or
        // timeout reaches everything it started (unless something left the group).
        unsafe {
            cmd.pre_exec(|| {
                if setsid() < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let started_at = SystemTime::now();
        let child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                let _ = std::fs::remove_file(&out_path);
                let _ = std::fs::remove_file(&err_path);
                return Err(format!("spawn: {e}"));
            }
        };
        let job = Arc::new(Job {
            id: id.clone(),
            pid: child.id(),
            command: spec.command.to_string(),
            cwd: spec.cwd.to_string(),
            started_at,
            out_path,
            err_path,
            deadline: spec.timeout.and_then(|t| Instant::now().checked_add(t)),
            inner: Mutex::new(Inner {
                child: Some(child),
                timed_out: false,
                state: JobState::Running,
                exit_code: None,
                finished_at: None,
            }),
        });
        map.insert(id, job.clone());
        drop(map);

        let supervised = job.clone();
        thread::Builder::new()
            .name(format!("job-{}", job.pid))
            .spawn(move || {
                while !supervised.supervise_once() {
                    thread::sleep(SUPERVISE_EVERY);
                }
            })
            .map_err(|e| {
                // Without a supervisor nobody would reap it: stop it and forget it.
                job.signal(SIGKILL);
                self.jobs().remove(&job.id);
                format!("cannot supervise the job: {e}")
            })?;
        Ok(job)
    }

    pub(crate) fn get(&self, id: &str) -> Option<Arc<Job>> {
        self.jobs().get(id).cloned()
    }

    /// Running jobs (newest first), then the finished ones kept (newest first).
    pub(crate) fn list(&self) -> Vec<Arc<Job>> {
        let map = self.jobs();
        let mut running: Vec<Arc<Job>> = map
            .values()
            .filter(|j| j.state() == JobState::Running)
            .cloned()
            .collect();
        running.sort_by_key(|a| std::cmp::Reverse(a.started_at));
        let mut finished: Vec<Arc<Job>> = map
            .values()
            .filter(|j| j.state() != JobState::Running)
            .cloned()
            .collect();
        finished.sort_by_key(|a| std::cmp::Reverse(a.finished_at()));
        running.extend(finished.into_iter().take(KEEP_FINISHED));
        running
    }

    /// Forget a finished job (its log files stay on disk). False if unknown or running.
    pub(crate) fn drop_finished(&self, id: &str) -> bool {
        let mut map = self.jobs();
        match map.get(id) {
            Some(j) if j.state() != JobState::Running => {
                map.remove(id);
                true
            }
            _ => false,
        }
    }

    /// Delete job log files last modified more than `LOG_MAX_AGE` before `now`.
    /// Returns how many were deleted.
    pub(crate) fn gc_logs(&self, now: SystemTime) -> usize {
        let map = self.jobs();
        self.gc_logs_except(now, &map)
    }

    /// Files of jobs still in the registry are kept whatever their age (a quiet
    /// job with no timeout can run for longer than a week).
    fn gc_logs_except(&self, now: SystemTime, known: &HashMap<String, Arc<Job>>) -> usize {
        let Some(cutoff) = now.checked_sub(LOG_MAX_AGE) else {
            return 0;
        };
        let Ok(entries) = std::fs::read_dir(&self.dir) else {
            return 0;
        };
        let mut removed = 0;
        for entry in entries.flatten() {
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            let Some(stem) = name
                .strip_suffix(".out")
                .or_else(|| name.strip_suffix(".err"))
            else {
                continue;
            };
            if !stem.starts_with("job-") || known.contains_key(stem) {
                continue;
            }
            let old = entry
                .metadata()
                .and_then(|m| m.modified())
                .is_ok_and(|t| t < cutoff);
            if old && std::fs::remove_file(entry.path()).is_ok() {
                removed += 1;
            }
        }
        removed
    }
}

fn create_log(path: &Path) -> Result<File, String> {
    OpenOptions::new()
        .create_new(true)
        .append(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| format!("cannot create {}: {e}", path.display()))
}

/// `job-` + a random (v4) UUID, lowercase, like the Swift daemon.
fn new_job_id() -> Result<String, String> {
    let mut b = [0u8; 16];
    File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut b))
        .map_err(|e| format!("cannot read /dev/urandom: {e}"))?;
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let mut h = String::with_capacity(32);
    for x in b {
        use std::fmt::Write;
        let _ = write!(h, "{x:02x}");
    }
    Ok(format!(
        "job-{}-{}-{}-{}-{}",
        &h[0..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..32]
    ))
}

/// Bytes of the log at `path` from offset `from`, at most `MAX_POLL_BYTES`, and
/// the offset to continue from. At or past the end: nothing, and the file's size.
/// `may_grow`: the job is still running, so a UTF-8 sequence cut off at the end
/// is left for the next read instead of being returned as U+FFFD.
pub(crate) fn read_log(path: &Path, from: u64, may_grow: bool) -> (Vec<u8>, u64) {
    let Ok(mut f) = File::open(path) else {
        return (Vec::new(), from);
    };
    let size = f.metadata().map(|m| m.len()).unwrap_or(0);
    if from >= size {
        return (Vec::new(), size);
    }
    let want = (size - from).min(MAX_POLL_BYTES as u64) as usize;
    let mut buf = vec![0u8; want];
    let got = f
        .seek(SeekFrom::Start(from))
        .and_then(|_| read_full(&mut f, &mut buf))
        .unwrap_or(0);
    buf.truncate(got);
    let capped = from + (got as u64) < size;
    if may_grow || capped {
        let cut = incomplete_utf8_tail(&buf);
        buf.truncate(buf.len() - cut);
    }
    let next = from + buf.len() as u64;
    (buf, next)
}

fn read_full(f: &mut File, buf: &mut [u8]) -> std::io::Result<usize> {
    let mut n = 0;
    while n < buf.len() {
        match f.read(&mut buf[n..])? {
            0 => break,
            k => n += k,
        }
    }
    Ok(n)
}

/// Length of an incomplete UTF-8 sequence at the end of `b` (0 if none).
pub(crate) fn incomplete_utf8_tail(b: &[u8]) -> usize {
    for back in 1..=b.len().min(4) {
        let c = b[b.len() - back];
        if c & 0xC0 == 0x80 {
            continue;
        }
        let need = match c {
            0xF0.. => 4,
            0xE0.. => 3,
            0xC0.. => 2,
            _ => 1,
        };
        return if need > back { back } else { 0 };
    }
    0
}

pub(crate) fn file_size(path: &Path) -> u64 {
    std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}

/// `2026-11-05T12:34:56Z` (UTC), like Swift's `ISO8601DateFormatter`.
pub(crate) fn iso8601(t: SystemTime) -> String {
    let secs = t
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

extern "C" {
    fn kill(pid: i32, sig: i32) -> i32;
    fn setsid() -> i32;
}
