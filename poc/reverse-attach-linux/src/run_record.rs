//! Run records: one small file per live child under `run/` (ADR linux-browser-tier "Data layout and
//! ownership", R3.3 `browser_running`; L2). `remove` refuses to delete while one names a live
//! process, and the start-time sweep leaves alone what a live record claims.
//!
//! - `run/<kind>-<pid>.json` holds `{"pid":N,"start":T,"kind":"managed"|"cli","unit":"<name>.service"}`.
//!   `T` is field 22 of `/proc/<pid>/stat`, so a reused PID is not mistaken for the recorded process.
//!   `state::live_run_records` reads only `pid` and `start`; the other fields are ours.
//! - Bounded: a record is at most `RUN_RECORD_CAP` (4 KiB), at most `MAX_RECORDS` exist, and dead
//!   ones are pruned on every write. `run/` must carry its marker; without it nothing is written.
//! - Reached only through directory fds with `O_NOFOLLOW` (`state.rs`), created 0600.
//! - A record names no profile path, URL, token or stderr text: a PID, a start time and two fixed
//!   strings.

use std::os::fd::OwnedFd;

use rustix::fs::Stat;
use serde_json::{json, Value};

use crate::state::{self, Fail, Root, IO, OWNED_DATA, R, RUN_RECORD_CAP};

/// The most run records that may exist at once, live or not yet pruned.
pub const MAX_RECORDS: usize = 64;
/// The most directory entries looked at when reading `run/`.
const SCAN_LIMIT: usize = 512;
/// The marker of the five-failure latch (`child.rs`). Not a run record; it holds no PID.
pub const LATCH_NAME: &str = "latch.json";
/// The recorded refusal that D17 needs before `--use-system-chromium` may be offered (L3 reads it).
pub const REFUSAL_NAME: &str = "refusal.json";
/// The only classes a refusal record may hold.
pub const REFUSALS: [&str; 2] = ["launch_refused", "sandbox_unavailable"];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Record {
    pub name: String,
    pub pid: u32,
    pub start: u64,
    pub kind: String,
    pub unit: Option<String>,
}

impl Record {
    /// The recorded process still exists with the recorded start time.
    pub fn is_live(&self) -> bool {
        self.pid > 0 && state::proc_start_time(self.pid) == Some(self.start)
    }
}

/// A unit name that is safe to hand to `systemctl` as an argument.
pub fn is_unit_name(s: &str) -> bool {
    s.len() <= 96
        && s.ends_with(".service")
        && !s.starts_with(['-', '.'])
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-' | b'@' | b':'))
}

fn kind_ok(k: &str) -> bool {
    matches!(k, "managed" | "cli")
}

/// Opens `run/`, refusing a missing marker.
pub fn open_run(root: &Root) -> R<OwnedFd> {
    let run = state::open_dir_at(root.fd(), "run")?;
    if !state::marker_present(&run, OWNED_DATA) {
        return Err(Fail("run_dir_unmarked"));
    }
    Ok(run)
}

fn parse(name: &str, bytes: &[u8]) -> Option<Record> {
    let v: Value = serde_json::from_slice(bytes).ok()?;
    let pid = v.get("pid")?.as_u64()?;
    let start = v.get("start")?.as_u64()?;
    if pid == 0 || pid > u32::MAX as u64 {
        return None;
    }
    let kind = v.get("kind").and_then(Value::as_str).unwrap_or("");
    let unit = v
        .get("unit")
        .and_then(Value::as_str)
        .filter(|u| is_unit_name(u))
        .map(str::to_string);
    Some(Record {
        name: name.to_string(),
        pid: pid as u32,
        start,
        kind: if kind_ok(kind) { kind } else { "" }.to_string(),
        unit,
    })
}

/// Every parsable record in `run/` with the identity of the file that was read.
fn read_all(run: &OwnedFd) -> Vec<(Record, Stat)> {
    let Ok(dir) = rustix::fs::Dir::read_from(run) else {
        return Vec::new();
    };
    let mut names = Vec::new();
    for e in dir.flatten().take(SCAN_LIMIT) {
        let n = e.file_name().to_bytes();
        if n.ends_with(b".json") && n != LATCH_NAME.as_bytes() && n != REFUSAL_NAME.as_bytes() {
            if let Ok(s) = std::str::from_utf8(n) {
                names.push(s.to_string());
            }
        }
    }
    let mut out = Vec::new();
    for n in names {
        if let Ok((bytes, id)) = state::read_file_id(run, &n, RUN_RECORD_CAP) {
            if let Some(r) = parse(&n, &bytes) {
                out.push((r, id));
            }
        }
    }
    out
}

/// The records whose process is alive. A missing or unmarked `run/` gives none.
pub fn live(root: &Root) -> Vec<Record> {
    let Ok(run) = open_run(root) else {
        return Vec::new();
    };
    read_all(&run)
        .into_iter()
        .map(|(r, _)| r)
        .filter(Record::is_live)
        .collect()
}

/// Dead records, as `(name, unit)`, removed. The unit is returned so the caller can stop it.
pub fn prune_dead(root: &Root) -> Vec<(String, Option<String>)> {
    let Ok(run) = open_run(root) else {
        return Vec::new();
    };
    prune_in(&run)
}

fn prune_in(run: &OwnedFd) -> Vec<(String, Option<String>)> {
    let mut gone = Vec::new();
    for (r, id) in read_all(run) {
        if !r.is_live() && state::unlink_if_same(run, &r.name, &id).is_ok() {
            gone.push((r.name, r.unit));
        }
    }
    gone
}

/// A written record. Dropping it removes the file, only while it is still the file that was written.
pub struct Handle {
    run: OwnedFd,
    name: String,
    id: Stat,
}

impl Handle {
    #[cfg(test)]
    pub fn name(&self) -> &str {
        &self.name
    }
}

impl Drop for Handle {
    fn drop(&mut self) {
        let _ = state::unlink_if_same(&self.run, &self.name, &self.id);
    }
}

/// Writes the record of a child that was just started. Dead records are pruned first; with
/// `MAX_RECORDS` already present the write is refused.
pub fn write(root: &Root, kind: &str, pid: u32, unit: Option<&str>) -> R<Handle> {
    if !kind_ok(kind) || pid == 0 || unit.is_some_and(|u| !is_unit_name(u)) {
        return Err(Fail("run_record_invalid"));
    }
    let start = state::proc_start_time(pid).ok_or(Fail("run_record_invalid"))?;
    let run = open_run(root)?;
    prune_in(&run);
    if read_all(&run).len() >= MAX_RECORDS {
        return Err(Fail("run_records_full"));
    }
    let name = format!("{kind}-{pid}.json");
    let bytes = json!({"pid": pid, "start": start, "kind": kind, "unit": unit}).to_string();
    debug_assert!(bytes.len() as u64 <= RUN_RECORD_CAP);
    state::write_record(&run, &name, bytes.as_bytes())?;
    let id = match state::lstat_at(&run, &name) {
        Ok(Some(st)) => st,
        _ => return Err(IO),
    };
    Ok(Handle { run, name, id })
}

/// The latch of five failures in two minutes (R1.5), as a file so that `browser status --retry`,
/// a different process, can clear it.
pub fn latch_set(root: &Root) -> R<()> {
    let run = open_run(root)?;
    match state::write_record(&run, LATCH_NAME, br#"{"latched":true}"#) {
        Ok(()) => Ok(()),
        // Already latched.
        Err(_) if matches!(state::lstat_at(&run, LATCH_NAME), Ok(Some(_))) => Ok(()),
        Err(e) => Err(e),
    }
}

pub fn latch_is_set(root: &Root) -> bool {
    open_run(root).is_ok_and(|run| matches!(state::lstat_at(&run, LATCH_NAME), Ok(Some(_))))
}

/// Removes the latch. True when there was one.
pub fn latch_clear(root: &Root) -> bool {
    let Ok(run) = open_run(root) else {
        return false;
    };
    match state::read_file_id(&run, LATCH_NAME, 256) {
        Ok((_, id)) => state::unlink_if_same(&run, LATCH_NAME, &id).is_ok(),
        Err(_) => false,
    }
}

/// Records that the pinned Chromium was refused on this host (`launch_refused`,
/// `sandbox_unavailable`), replacing an earlier record. Holds the class and the time, nothing else.
pub fn refusal_set(root: &Root, class: &str) -> R<()> {
    if !REFUSALS.contains(&class) {
        return Err(Fail("run_record_invalid"));
    }
    let run = open_run(root)?;
    if let Ok((_, id)) = state::read_file_id(&run, REFUSAL_NAME, RUN_RECORD_CAP) {
        state::unlink_if_same(&run, REFUSAL_NAME, &id)?;
    }
    let body = json!({"class": class, "at": state::now_iso8601()}).to_string();
    state::write_record(&run, REFUSAL_NAME, body.as_bytes())
}

/// The recorded refusal class, if one exists and is one of the two fixed classes.
pub fn refusal_get(root: &Root) -> Option<String> {
    let run = open_run(root).ok()?;
    let (bytes, _) = state::read_file_id(&run, REFUSAL_NAME, RUN_RECORD_CAP).ok()?;
    let v: Value = serde_json::from_slice(&bytes).ok()?;
    let c = v.get("class")?.as_str()?;
    REFUSALS.contains(&c).then(|| c.to_string())
}

#[cfg(test)]
#[path = "run_record_tests.rs"]
pub(crate) mod tests;
