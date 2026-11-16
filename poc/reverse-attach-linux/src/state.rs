//! On-disk state of the managed Playwright install: the root directory, ownership markers, the
//! install lock, the records and the marker-gated delete walker (ADR linux-browser-tier "Data layout
//! and ownership", R3.3, R3.4; L1b). Counterpart of the file handling in the Swift
//! `PlaywrightInstaller`.
//!
//! Rules this module enforces for every caller:
//!
//! - Everything below the root is reached through directory fds with `O_NOFOLLOW` and `lstat`
//!   semantics. No path string below the root is ever handed to `std::fs`.
//! - The root, `oab-computer/` above it and every directory the installer creates must be plain
//!   directories owned by the effective user, with no group or other write bit. A symlink at any of
//!   those positions stops the operation. (The base directory above `oab-computer/`, normally
//!   `~/.local/share`, is the user's own and is resolved normally.)
//! - A directory is deleted only when it carries the marker file the installer wrote into it. The
//!   marker and the `lstat` are re-checked immediately before the final unlink, and a symlink child
//!   is unlinked as a link and never followed.
//! - Every read of a file the installer did not just write is capped.
//! - `.install.lock` is a `flock` target that is never unlinked or renamed. The kernel drops the
//!   lock with the process, so there is no stale-lock judgement and no reclaim code.
//! - Errors are fixed class names (`Fail`). No file system text reaches a message.
//!
//! Contracts L2 must honour when it lands, because `remove` and `status` read them:
//! `run/<name>.json` holds `{"pid":N,"start":T}` where `T` is field 22 of `/proc/<pid>/stat`, and
//! `pw-config.json` carries the key `_oabInstallerOwned: true`.

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::{AsFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use rustix::fs::{AtFlags, FileType, FlockOperation, Mode, OFlags, RenameFlags, Stat};
use serde_json::{json, Value};

use crate::manifest::is_safe_id;

pub const OWNED: &str = ".oab-owned";
pub const OWNED_DATA: &str = ".oab-owned-data";
pub const STAGING_MARK: &str = ".oab-staging";
pub const MARKER_TEXT: &[u8] = b"oab-computer playwright install\n";
pub const LOCK_NAME: &str = ".install.lock";
pub const SWEEP_LOCK_NAME: &str = ".sweep.lock";
pub const RECORD_NAME: &str = "install.json";
pub const PENDING_NAME: &str = "pending-cleanup.json";
pub const CONFIG_NAME: &str = "pw-config.json";
pub const DATA_DIRS: [&str; 4] = ["profile", "output", "home", "run"];
pub const STAGING_PREFIX: &str = ".staging-";

/// Largest `install.json` or `pending-cleanup.json` that is read at all.
pub const RECORD_CAP: u64 = 64 * 1024;
/// Largest run record that is read.
pub const RUN_RECORD_CAP: u64 = 4 * 1024;
const CONFIG_CAP: u64 = 256 * 1024;
const MAX_DEPTH: usize = 64;
const MAX_ENTRIES: u64 = 1_000_000;

/// A fixed failure class. `Display` prints the class name and nothing else.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Fail(pub &'static str);

impl std::fmt::Display for Fail {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}

pub type R<T> = Result<T, Fail>;

pub const IO: Fail = Fail("io");

fn io<T>(_: rustix::io::Errno) -> R<T> {
    Err(IO)
}

fn euid() -> u32 {
    rustix::process::geteuid().as_raw()
}

// ---- small fd helpers -----------------------------------------------------------------------

pub fn lstat_at(dir: &impl AsFd, name: &str) -> R<Option<Stat>> {
    match rustix::fs::statat(dir, name, AtFlags::SYMLINK_NOFOLLOW) {
        Ok(st) => Ok(Some(st)),
        Err(rustix::io::Errno::NOENT) => Ok(None),
        Err(_) => Err(IO),
    }
}

pub fn file_type(st: &Stat) -> FileType {
    FileType::from_raw_mode(st.st_mode as _)
}

pub fn is_dir(st: &Stat) -> bool {
    file_type(st) == FileType::Directory
}

pub fn is_regular(st: &Stat) -> bool {
    file_type(st) == FileType::RegularFile
}

// The casts are needed on macOS, where `st_mode` and `st_dev` have other widths, and are no-ops on
// Linux (the target); the allow keeps clippy quiet on Linux.
#[allow(clippy::unnecessary_cast)]
fn mode_bits(st: &Stat) -> u32 {
    st.st_mode as u32 & 0o7777
}

#[allow(clippy::unnecessary_cast)]
fn dev_of(st: &Stat) -> u64 {
    st.st_dev as u64
}

/// A directory we own that nobody else can write to.
fn private_dir(st: &Stat) -> bool {
    is_dir(st) && st.st_uid == euid() && mode_bits(st) & 0o022 == 0
}

fn same_object(a: &Stat, b: &Stat) -> bool {
    a.st_dev == b.st_dev && a.st_ino == b.st_ino
}

/// Opens `name` below `dir` as a directory without following a link and applies the private
/// directory rule to what was opened.
pub fn open_dir_at(dir: &impl AsFd, name: &str) -> R<OwnedFd> {
    let fd = rustix::fs::openat(
        dir,
        name,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(|_| IO)?;
    let st = rustix::fs::fstat(&fd).map_err(|_| IO)?;
    if !private_dir(&st) {
        return Err(Fail("root_not_directory"));
    }
    Ok(fd)
}

/// `mkdirat` (mode 0700 unless told otherwise) then `open_dir_at`. The directory is fresh, so a
/// refusal here means somebody raced us.
pub fn create_dir_at(dir: &impl AsFd, name: &str) -> R<OwnedFd> {
    rustix::fs::mkdirat(dir, name, Mode::from_raw_mode(0o700)).map_err(|_| IO)?;
    open_dir_at(dir, name)
}

/// Writes a new file, failing if the name exists. Mode 0600 unless given.
pub fn write_new_file(dir: &impl AsFd, name: &str, bytes: &[u8], mode: u32) -> R<()> {
    let fd = rustix::fs::openat(
        dir,
        name,
        OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::from_raw_mode(mode as _),
    )
    .map_err(|_| IO)?;
    let mut f = File::from(fd);
    if f.write_all(bytes).is_err() || f.sync_all().is_err() {
        drop(f);
        let _ = rustix::fs::unlinkat(dir, name, AtFlags::empty());
        return Err(IO);
    }
    Ok(())
}

/// Reads a regular file below `dir`, at most `cap` bytes. A symlink, a FIFO or anything else that
/// is not a regular file, and a file over the cap, are errors.
pub fn read_file_capped(dir: &impl AsFd, name: &str, cap: u64) -> R<Vec<u8>> {
    let fd = rustix::fs::openat(
        dir,
        name,
        OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(|_| IO)?;
    let st = rustix::fs::fstat(&fd).map_err(|_| IO)?;
    if !is_regular(&st) || st.st_size as u64 > cap {
        return Err(Fail("record_unreadable"));
    }
    let mut out = Vec::new();
    File::from(fd)
        .take(cap + 1)
        .read_to_end(&mut out)
        .map_err(|_| IO)?;
    if out.len() as u64 > cap {
        return Err(Fail("record_unreadable"));
    }
    Ok(out)
}

/// Write-then-rename of a small record: temp file (`O_EXCL`, 0600, fsync) renamed over `name`.
/// With `replace == false` the rename refuses to overwrite.
pub fn write_record(dir: &impl AsFd, name: &str, bytes: &[u8], replace: bool) -> R<()> {
    let tmp = format!("{name}.tmp-{}", random_hex(8));
    write_new_file(dir, &tmp, bytes, 0o600)?;
    let res = if replace {
        rustix::fs::renameat(dir, tmp.as_str(), dir, name)
    } else {
        rustix::fs::renameat_with(dir, tmp.as_str(), dir, name, RenameFlags::NOREPLACE)
    };
    if res.is_err() {
        let _ = rustix::fs::unlinkat(dir, tmp.as_str(), AtFlags::empty());
        return Err(IO);
    }
    Ok(())
}

/// Stats a relative path below `dir`, component by component, opening every intermediate
/// directory with `O_NOFOLLOW`. A link anywhere on the way gives `None`.
pub fn stat_rel(dir: &impl AsFd, rel: &str) -> Option<Stat> {
    let comps: Vec<&str> = rel.split('/').collect();
    if comps
        .iter()
        .any(|c| c.is_empty() || *c == "." || *c == "..")
    {
        return None;
    }
    let (last, parents) = comps.split_last()?;
    let mut cur: Option<OwnedFd> = None;
    for p in parents {
        let base = cur.as_ref().map(|f| f.as_fd()).unwrap_or(dir.as_fd());
        let fd = rustix::fs::openat(
            base,
            *p,
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        )
        .ok()?;
        cur = Some(fd);
    }
    let base = cur.as_ref().map(|f| f.as_fd()).unwrap_or(dir.as_fd());
    rustix::fs::statat(base, *last, AtFlags::SYMLINK_NOFOLLOW).ok()
}

/// A regular file with the owner execute bit.
pub fn is_exec_file(st: &Stat) -> bool {
    is_regular(st) && mode_bits(st) & 0o100 != 0
}

/// True when `dir/name` is a regular file owned by us (the marker rule).
pub fn marker_present(dir: &impl AsFd, name: &str) -> bool {
    matches!(lstat_at(dir, name), Ok(Some(st)) if is_regular(&st) && st.st_uid == euid())
}

/// Lowercase hex of `n` random bytes from the kernel.
pub fn random_hex(n: usize) -> String {
    let mut buf = vec![0u8; n];
    let ok = File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut buf))
        .is_ok();
    if !ok {
        // Never expected. Fall back to a clock-derived value so a name is still unique enough
        // for an `O_EXCL` create to fail loudly rather than collide silently.
        let t = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        for (i, b) in buf.iter_mut().enumerate() {
            *b = (t >> ((i % 16) * 8)) as u8 ^ (std::process::id() as u8).wrapping_add(i as u8);
        }
    }
    crate::manifest::hex(&buf)
}

/// `.staging-<32 lowercase hex>`
pub fn is_staging_name(name: &str) -> bool {
    name.strip_prefix(STAGING_PREFIX).is_some_and(|r| {
        r.len() == 32
            && r.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

pub fn new_staging_name() -> String {
    format!("{STAGING_PREFIX}{}", random_hex(16))
}

// ---- the root -------------------------------------------------------------------------------

/// The opened install root. Holding it keeps the directory fd, so a later swap of the path cannot
/// redirect anything.
pub struct Root {
    fd: OwnedFd,
    display: PathBuf,
    abs: PathBuf,
}

impl Root {
    /// `${XDG_DATA_HOME:-$HOME/.local/share}`. A relative or empty `XDG_DATA_HOME` is ignored, as
    /// the XDG specification says.
    pub fn default_base() -> R<PathBuf> {
        let xdg = std::env::var_os("XDG_DATA_HOME").map(PathBuf::from);
        if let Some(x) = xdg.filter(|p| p.is_absolute()) {
            return Ok(x);
        }
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .ok_or(Fail("no_home"))?;
        Ok(home.join(".local/share"))
    }

    /// Opens `<base>/oab-computer/playwright`. With `create` the two directories are made (0700);
    /// without it a missing root is `Ok(None)`. A link, a foreign owner or a group- or
    /// other-writable directory at either position is `root_not_directory`.
    pub fn open(base: &Path, create: bool) -> R<Option<Root>> {
        if create {
            std::fs::create_dir_all(base).map_err(|_| IO)?;
        }
        let basefd = match rustix::fs::open(
            base,
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
            Mode::empty(),
        ) {
            Ok(fd) => fd,
            Err(rustix::io::Errno::NOENT) if !create => return Ok(None),
            Err(_) => return Err(IO),
        };
        let mut cur = basefd;
        for name in ["oab-computer", "playwright"] {
            match lstat_at(&cur, name)? {
                None if !create => return Ok(None),
                None => {
                    cur = create_dir_at(&cur, name)?;
                }
                Some(st) => {
                    if !private_dir(&st) {
                        return Err(Fail("root_not_directory"));
                    }
                    cur = open_dir_at(&cur, name)?;
                }
            }
        }
        let display = base.join("oab-computer").join("playwright");
        let abs = std::fs::canonicalize(&display).unwrap_or_else(|_| display.clone());
        Ok(Some(Root {
            fd: cur,
            display,
            abs,
        }))
    }

    pub fn fd(&self) -> &OwnedFd {
        &self.fd
    }

    /// For messages only. Never used to reach a file.
    pub fn display_path(&self) -> &Path {
        &self.display
    }

    /// The resolved absolute path, used to build the command lines of child processes. It is
    /// never used to open or delete anything.
    pub fn abs_path(&self) -> &Path {
        &self.abs
    }

    /// Names directly below the root, with their `lstat`. Reads at most `MAX_ENTRIES`.
    pub fn entries(&self) -> R<Vec<(String, Stat)>> {
        let dir = rustix::fs::Dir::read_from(&self.fd).or_else(io)?;
        let mut out = Vec::new();
        for e in dir {
            let e = e.map_err(|_| IO)?;
            let n = e.file_name().to_bytes();
            if n == b"." || n == b".." {
                continue;
            }
            if out.len() as u64 >= MAX_ENTRIES {
                return Err(Fail("too_many_entries"));
            }
            let name = String::from_utf8_lossy(n).into_owned();
            if let Some(st) = lstat_at(&self.fd, &name)? {
                out.push((name, st));
            }
        }
        out.sort_by(|a, b| a.0.cmp(&b.0));
        Ok(out)
    }
}

// ---- lock -----------------------------------------------------------------------------------

/// The exclusive install lock. Dropping it (or exiting) releases it. The file stays.
pub struct Lock {
    _fd: OwnedFd,
}

impl Lock {
    /// Takes `.install.lock`, retrying a non-blocking `flock` every 100 ms for `wait`.
    pub fn acquire(root: &Root, wait: Duration) -> R<Lock> {
        let fd = open_lock_file(root)?;
        let started = Instant::now();
        loop {
            match rustix::fs::flock(&fd, FlockOperation::NonBlockingLockExclusive) {
                Ok(()) => return Ok(Lock { _fd: fd }),
                Err(rustix::io::Errno::WOULDBLOCK) | Err(rustix::io::Errno::INTR) => {}
                Err(_) => return Err(IO),
            }
            if started.elapsed() >= wait || crate::cancel::is_cancelled() {
                return Err(Fail("lock_held"));
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}

fn open_lock_file(root: &Root) -> R<OwnedFd> {
    let fd = rustix::fs::openat(
        root.fd(),
        LOCK_NAME,
        OFlags::RDWR | OFlags::CREATE | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::from_raw_mode(0o600),
    )
    .map_err(|_| IO)?;
    let st = rustix::fs::fstat(&fd).map_err(|_| IO)?;
    if !is_regular(&st) || st.st_uid != euid() {
        return Err(Fail("root_not_directory"));
    }
    Ok(fd)
}

// ---- records --------------------------------------------------------------------------------

/// `install.json`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InstallRecord {
    pub manifest_id: String,
    pub version: String,
    pub platform: String,
    pub chromium_executable: String,
    pub chromium_revision: String,
    pub chromium_released_at: String,
    pub installed_at: String,
    pub previous: Option<String>,
    pub digests: BTreeMap<String, String>,
}

impl InstallRecord {
    pub fn to_json(&self) -> String {
        json!({
            "schema": 1,
            "manifestId": self.manifest_id,
            "version": self.version,
            "platform": self.platform,
            "chromiumExecutable": self.chromium_executable,
            "chromiumRevision": self.chromium_revision,
            "chromiumReleasedAt": self.chromium_released_at,
            "installedAt": self.installed_at,
            "previous": self.previous,
            "digests": self.digests,
        })
        .to_string()
    }

    /// Parses and validates every field that is later used as a path component or a path.
    pub fn parse(bytes: &[u8]) -> Option<InstallRecord> {
        let v: Value = serde_json::from_slice(bytes).ok()?;
        let o = v.as_object()?;
        if o.get("schema")?.as_i64()? != 1 {
            return None;
        }
        let s = |k: &str| o.get(k)?.as_str().map(str::to_string);
        let previous = match o.get("previous")? {
            Value::Null => None,
            Value::String(p) if is_safe_id(p) => Some(p.clone()),
            _ => return None,
        };
        let mut digests = BTreeMap::new();
        for (k, d) in o.get("digests")?.as_object()? {
            digests.insert(k.clone(), d.as_str()?.to_string());
        }
        let rec = InstallRecord {
            manifest_id: s("manifestId")?,
            version: s("version")?,
            platform: s("platform")?,
            chromium_executable: s("chromiumExecutable")?,
            chromium_revision: s("chromiumRevision")?,
            chromium_released_at: s("chromiumReleasedAt")?,
            installed_at: s("installedAt")?,
            previous,
            digests,
        };
        let rel_ok = |p: &str| {
            !p.is_empty()
                && p.len() <= 256
                && !p.starts_with('/')
                && !p.contains('\0')
                && p.split('/').all(|c| !c.is_empty() && c != "." && c != "..")
        };
        if !is_safe_id(&rec.version)
            || !is_safe_id(&rec.manifest_id)
            || !rel_ok(&rec.chromium_executable)
        {
            return None;
        }
        Some(rec)
    }
}

/// Where an install stands. "Foreign" is an `install.json` this installer did not write, or one it
/// cannot read; nothing in it is trusted and nothing it names is touched.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum State {
    NotInstalled,
    Installed(InstallRecord),
    /// Ours, but a file the install needs is missing or not what it should be.
    Invalid(InstallRecord),
    Foreign(&'static str),
}

impl State {
    pub fn name(&self) -> &'static str {
        match self {
            State::NotInstalled => "not_installed",
            State::Installed(_) => "installed",
            State::Invalid(_) => "invalid",
            State::Foreign(_) => "foreign_install",
        }
    }
}

/// The macOS rule: `install.json` is ours when it parses, `manifestId == version`, and the version
/// directory carries a regular `.oab-owned`. A hand-written file cannot fake the last part.
pub fn record_is_ours(root: &Root, rec: &InstallRecord) -> bool {
    if rec.manifest_id != rec.version || !is_safe_id(&rec.version) {
        return false;
    }
    match open_dir_at(root.fd(), &rec.version) {
        Ok(vd) => marker_present(&vd, OWNED),
        Err(_) => false,
    }
}

/// Reads and classifies `install.json`. No network, no child process.
pub fn read_state(root: &Root) -> R<State> {
    if lstat_at(root.fd(), RECORD_NAME)?.is_none() {
        return Ok(State::NotInstalled);
    }
    let Ok(bytes) = read_file_capped(root.fd(), RECORD_NAME, RECORD_CAP) else {
        return Ok(State::Foreign("unreadable"));
    };
    let Some(rec) = InstallRecord::parse(&bytes) else {
        return Ok(State::Foreign("not_written_by_this_installer"));
    };
    if !record_is_ours(root, &rec) {
        return Ok(State::Foreign("not_written_by_this_installer"));
    }
    let Ok(vd) = open_dir_at(root.fd(), &rec.version) else {
        return Ok(State::Invalid(rec));
    };
    let exec_ok = |rel: &str| stat_rel(&vd, rel).is_some_and(|st| is_exec_file(&st));
    let cli_ok =
        stat_rel(&vd, "pkg/node_modules/@playwright/mcp/cli.js").is_some_and(|st| is_regular(&st));
    let chrome = format!("chromium/{}", rec.chromium_executable);
    if exec_ok("node/bin/node") && cli_ok && exec_ok(&chrome) {
        Ok(State::Installed(rec))
    } else {
        Ok(State::Invalid(rec))
    }
}

/// The `install.json` bytes as they are now, for compare-before-write. `None` when absent.
pub fn record_bytes(root: &Root) -> R<Option<Vec<u8>>> {
    match lstat_at(root.fd(), RECORD_NAME)? {
        None => Ok(None),
        Some(_) => read_file_capped(root.fd(), RECORD_NAME, RECORD_CAP).map(Some),
    }
}

/// `pending-cleanup.json`: `{"schema":1,"previous":"<id>"}`.
pub fn pending_previous(root: &Root) -> Option<String> {
    let bytes = read_file_capped(root.fd(), PENDING_NAME, RECORD_CAP).ok()?;
    let v: Value = serde_json::from_slice(&bytes).ok()?;
    if v.get("schema")?.as_i64()? != 1 {
        return None;
    }
    let p = v.get("previous")?.as_str()?;
    is_safe_id(p).then(|| p.to_string())
}

pub fn pending_json(previous: &str) -> String {
    json!({"schema": 1, "previous": previous}).to_string()
}

/// `<base>.tmp-<16 lowercase hex>` where `<base>` is a record name this installer writes.
fn tmp_base(name: &str) -> Option<&'static str> {
    for base in [RECORD_NAME, PENDING_NAME] {
        if let Some(sfx) = name
            .strip_prefix(base)
            .and_then(|r| r.strip_prefix(".tmp-"))
        {
            let hex =
                sfx.len() == 16 && sfx.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
            return hex.then_some(base);
        }
    }
    None
}

/// A leftover temp file is ours only with the exact generated name and content that parses as
/// the record it would have become. Anything else (a note someone named `install.json.tmp-x`) is
/// left in place.
fn tmp_is_ours(root: &Root, name: &str) -> bool {
    let Some(base) = tmp_base(name) else {
        return false;
    };
    let Ok(bytes) = read_file_capped(root.fd(), name, RECORD_CAP) else {
        return false;
    };
    if base == RECORD_NAME {
        return InstallRecord::parse(&bytes).is_some();
    }
    serde_json::from_slice::<Value>(&bytes)
        .ok()
        .is_some_and(|v| {
            v.get("schema").and_then(Value::as_i64) == Some(1)
                && v.get("previous")
                    .and_then(Value::as_str)
                    .is_some_and(is_safe_id)
        })
}

/// `pw-config.json` is ours only when it is a JSON object with `_oabInstallerOwned: true`.
fn config_is_ours(root: &Root) -> bool {
    let Ok(bytes) = read_file_capped(root.fd(), CONFIG_NAME, CONFIG_CAP) else {
        return false;
    };
    serde_json::from_slice::<Value>(&bytes)
        .ok()
        .and_then(|v| v.get("_oabInstallerOwned").and_then(Value::as_bool))
        == Some(true)
}

// ---- run records ----------------------------------------------------------------------------

/// Field 22 of `/proc/<pid>/stat` (start time in clock ticks), or `None` when the process is gone
/// or the file does not parse.
pub fn proc_start_time(pid: u32) -> Option<u64> {
    let mut buf = Vec::new();
    File::open(format!("/proc/{pid}/stat"))
        .ok()?
        .take(4096)
        .read_to_end(&mut buf)
        .ok()?;
    let s = String::from_utf8_lossy(&buf);
    // The command name is in parentheses and may contain spaces; fields start after the last ')'.
    let rest = &s[s.rfind(')')? + 1..];
    rest.split_whitespace().nth(19)?.parse().ok()
}

/// Run records whose `pid` still exists with the recorded start time. Anything unreadable,
/// oversize or stale counts as dead. `run/` must carry its marker to be read at all.
pub fn live_run_records(root: &Root) -> usize {
    let Ok(run) = open_dir_at(root.fd(), "run") else {
        return 0;
    };
    if !marker_present(&run, OWNED_DATA) {
        return 0;
    }
    let Ok(dir) = rustix::fs::Dir::read_from(&run) else {
        return 0;
    };
    let mut names = Vec::new();
    for e in dir.flatten().take(10_000) {
        let n = e.file_name().to_bytes();
        if n.ends_with(b".json") {
            names.push(String::from_utf8_lossy(n).into_owned());
        }
    }
    let mut live = 0;
    for n in names {
        let Ok(bytes) = read_file_capped(&run, &n, RUN_RECORD_CAP) else {
            continue;
        };
        let Ok(v) = serde_json::from_slice::<Value>(&bytes) else {
            continue;
        };
        let (Some(pid), Some(start)) = (
            v.get("pid").and_then(Value::as_u64),
            v.get("start").and_then(Value::as_u64),
        ) else {
            continue;
        };
        if pid > 0 && pid <= u32::MAX as u64 && proc_start_time(pid as u32) == Some(start) {
            live += 1;
        }
    }
    live
}

// ---- delete walker --------------------------------------------------------------------------

/// What a removal did, for the report.
#[derive(Debug, Default)]
pub struct Report {
    pub removed: Vec<String>,
    /// `(name, reason)`
    pub left: Vec<(String, String)>,
    /// A deletion that was attempted and failed.
    pub failed: bool,
}

impl Report {
    pub fn leave(&mut self, name: &str, reason: &str) {
        self.left.push((name.to_string(), reason.to_string()));
    }
}

struct Walk<'a> {
    entries: u64,
    dev: u64,
    hook: &'a mut dyn FnMut(&str),
    incomplete: Option<&'static str>,
}

/// Removes `parent/name` and everything below it, but only if it is a plain directory carrying
/// `marker`. Returns `Ok(true)` when the directory is gone. Anything not removed is added to the
/// report with a reason. A symlink child is unlinked as a link; a mount point or a child on
/// another device is left; depth and entry count are capped.
pub fn remove_marked_tree(
    parent: &impl AsFd,
    name: &str,
    marker: &str,
    report: &mut Report,
) -> R<bool> {
    remove_tree_with_hook(parent, name, Some(marker), report, &mut |_| {})
}

/// Removes a child of a directory that is itself marked and owned by the installer (a staging
/// directory). The child needs no marker of its own; everything else is the same as
/// `remove_marked_tree`. Callers must only pass a `parent` they have just created or verified.
pub fn remove_staged_child(parent: &impl AsFd, name: &str, report: &mut Report) -> R<bool> {
    remove_tree_with_hook(parent, name, None, report, &mut |_| {})
}

#[cfg(test)]
pub fn remove_marked_tree_with_hook(
    parent: &impl AsFd,
    name: &str,
    marker: &str,
    report: &mut Report,
    hook: &mut dyn FnMut(&str),
) -> R<bool> {
    remove_tree_with_hook(parent, name, Some(marker), report, hook)
}

/// `hook` runs before every child is examined; tests swap things in the tree there.
fn remove_tree_with_hook(
    parent: &impl AsFd,
    name: &str,
    marker: Option<&str>,
    report: &mut Report,
    hook: &mut dyn FnMut(&str),
) -> R<bool> {
    let Some(st) = lstat_at(parent, name)? else {
        return Ok(true);
    };
    if !is_dir(&st) {
        report.leave(name, "not a plain directory");
        return Ok(false);
    }
    let Ok(fd) = rustix::fs::openat(
        parent,
        name,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    ) else {
        report.leave(name, "not a plain directory");
        return Ok(false);
    };
    let opened = rustix::fs::fstat(&fd).map_err(|_| IO)?;
    if !same_object(&st, &opened) || opened.st_uid != euid() {
        report.leave(name, "not owned by this user");
        return Ok(false);
    }
    if let Some(m) = marker {
        if !marker_present(&fd, m) {
            report.leave(name, "no installer marker");
            return Ok(false);
        }
    }
    let mut walk = Walk {
        entries: 0,
        dev: dev_of(&opened),
        hook,
        incomplete: None,
    };
    let top_ok = purge_children(&fd, 0, &mut walk, report, marker)?;
    if !top_ok || walk.incomplete.is_some() {
        report.leave(
            name,
            walk.incomplete.unwrap_or("contains items that were left"),
        );
        return Ok(false);
    }
    // The marker goes last, so an interrupted removal can be repeated.
    if let Some(m) = marker {
        match rustix::fs::unlinkat(&fd, m, AtFlags::empty()) {
            Ok(()) | Err(rustix::io::Errno::NOENT) => {}
            Err(_) => {
                report.failed = true;
                report.leave(name, "could not delete");
                return Ok(false);
            }
        }
    }
    // Re-check what the name points at, immediately before the unlink.
    match lstat_at(parent, name)? {
        Some(now) if same_object(&now, &opened) && is_dir(&now) => {}
        _ => {
            report.leave(name, "changed while being removed");
            return Ok(false);
        }
    }
    match rustix::fs::unlinkat(parent, name, AtFlags::REMOVEDIR) {
        Ok(()) => Ok(true),
        Err(_) => {
            report.failed = true;
            report.leave(name, "could not delete");
            Ok(false)
        }
    }
}

/// Deletes the children of `dir`. Returns false if anything was left or failed.
fn purge_children(
    dir: &OwnedFd,
    depth: usize,
    walk: &mut Walk<'_>,
    report: &mut Report,
    skip: Option<&str>,
) -> R<bool> {
    if depth >= MAX_DEPTH {
        walk.incomplete = Some("directory tree too deep");
        return Ok(false);
    }
    let reader = rustix::fs::Dir::read_from(dir).or_else(io)?;
    let mut names: Vec<Vec<u8>> = Vec::new();
    for e in reader {
        let e = e.map_err(|_| IO)?;
        let n = e.file_name().to_bytes();
        if n == b"." || n == b".." || Some(n) == skip.map(str::as_bytes) {
            continue;
        }
        walk.entries += 1;
        if walk.entries > MAX_ENTRIES {
            walk.incomplete = Some("too many entries");
            return Ok(false);
        }
        names.push(n.to_vec());
    }
    let mut all_gone = true;
    for raw in names {
        let name = String::from_utf8_lossy(OsStr::from_bytes(&raw).as_bytes()).into_owned();
        // A name that is not valid UTF-8 cannot be addressed through the &str API; leave it.
        if name.as_bytes() != raw.as_slice() {
            all_gone = false;
            continue;
        }
        (walk.hook)(&name);
        let Some(st) = lstat_at(dir, &name)? else {
            continue;
        };
        if is_dir(&st) {
            if dev_of(&st) != walk.dev {
                walk.incomplete = Some("contains another file system");
                all_gone = false;
                continue;
            }
            let Ok(sub) = rustix::fs::openat(
                dir,
                name.as_str(),
                OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
                Mode::empty(),
            ) else {
                // Swapped for a link or removed between the lstat and the open: not followed.
                all_gone = false;
                walk.incomplete = Some("changed while being removed");
                continue;
            };
            let sst = rustix::fs::fstat(&sub).map_err(|_| IO)?;
            if !same_object(&st, &sst) {
                all_gone = false;
                walk.incomplete = Some("changed while being removed");
                continue;
            }
            if !purge_children(&sub, depth + 1, walk, report, None)? {
                all_gone = false;
                continue;
            }
            if rustix::fs::unlinkat(dir, name.as_str(), AtFlags::REMOVEDIR).is_err() {
                report.failed = true;
                all_gone = false;
            }
        } else if rustix::fs::unlinkat(dir, name.as_str(), AtFlags::empty()).is_err() {
            report.failed = true;
            all_gone = false;
        }
    }
    Ok(all_gone)
}

/// Removes one marked directory below the root and records the outcome in the report.
fn drop_dir(root: &Root, name: &str, marker: &str, report: &mut Report) -> R<()> {
    if remove_marked_tree(root.fd(), name, marker, report)? {
        report.removed.push(name.to_string());
    }
    Ok(())
}

/// Removes a regular file below the root (never a directory or a link target).
fn drop_file(root: &Root, name: &str, report: &mut Report) {
    match lstat_at(root.fd(), name) {
        Ok(Some(st)) if is_regular(&st) => {
            if rustix::fs::unlinkat(root.fd(), name, AtFlags::empty()).is_ok() {
                report.removed.push(name.to_string());
            } else {
                report.failed = true;
                report.leave(name, "could not delete");
            }
        }
        Ok(Some(_)) => report.leave(name, "not a regular file"),
        _ => {}
    }
}

// ---- staging --------------------------------------------------------------------------------

/// Removes leftover `.staging-<hex>/` directories that carry `.oab-staging`. Call under the lock.
pub fn sweep_staging(root: &Root) -> R<Report> {
    let mut report = Report::default();
    for (name, st) in root.entries()? {
        if is_staging_name(&name) && is_dir(&st) {
            drop_dir(root, &name, STAGING_MARK, &mut report)?;
        }
    }
    Ok(report)
}

/// Removes one version directory that carries `.oab-owned`.
pub fn remove_version_dir(root: &Root, id: &str, report: &mut Report) -> R<()> {
    if !is_safe_id(id) {
        report.leave(id, "not a valid version name");
        return Ok(());
    }
    drop_dir(root, id, OWNED, report)
}

/// The `pending-cleanup.json` step of `update` (R3.2). Deletes `<previous>/` only when it carries
/// `.oab-owned`, is not the installed version and no live run record exists, then removes the
/// pending file. Returns the previous id when it was cleaned up. Call under the lock.
pub fn run_pending_cleanup(root: &Root) -> R<Option<String>> {
    let Some(prev) = pending_previous(root) else {
        return Ok(None);
    };
    let current = match read_state(root)? {
        State::Installed(r) | State::Invalid(r) => Some(r.version),
        _ => None,
    };
    if current.as_deref() == Some(prev.as_str()) || live_run_records(root) > 0 {
        return Ok(None);
    }
    if !matches!(read_state(root)?, State::Installed(_)) {
        // Only an install that can serve makes the old one disposable.
        return Ok(None);
    }
    let mut report = Report::default();
    remove_version_dir(root, &prev, &mut report)?;
    if report.failed || !report.left.is_empty() {
        return Ok(None);
    }
    match rustix::fs::unlinkat(root.fd(), PENDING_NAME, AtFlags::empty()) {
        Ok(()) | Err(rustix::io::Errno::NOENT) => {}
        Err(_) => return Err(IO),
    }
    Ok(Some(prev))
}

// ---- remove ---------------------------------------------------------------------------------

/// `browser remove` (R3.3). All ownership decisions are made before the first deletion. Returns
/// the report; the caller prints it. Fails with `browser_running` (deleting nothing) when a run
/// record names a live process.
pub fn remove_all(root: &Root) -> R<Report> {
    let mut report = Report::default();
    let state = read_state(root)?;
    let ours: Option<InstallRecord> = match &state {
        State::Installed(r) | State::Invalid(r) => Some(r.clone()),
        _ => None,
    };
    if live_run_records(root) > 0 {
        return Err(Fail("browser_running"));
    }

    // Decide first.
    let entries = root.entries()?;
    #[derive(PartialEq)]
    enum Plan {
        Version,
        Staging,
        Record,
        Pending,
        Config,
        Tmp,
        Data,
        Skip(&'static str),
    }
    let mut plan: Vec<(String, Plan)> = Vec::new();
    for (name, st) in &entries {
        let n = name.as_str();
        let item = if n == LOCK_NAME || n == SWEEP_LOCK_NAME {
            Plan::Skip("lock file, kept by design")
        } else if n == RECORD_NAME {
            if ours.is_some() {
                Plan::Record
            } else {
                Plan::Skip("install record not written by this installer")
            }
        } else if n == PENDING_NAME {
            if ours.is_some() && pending_previous(root).is_some() {
                Plan::Pending
            } else {
                Plan::Skip("not a pending-cleanup record of this installer")
            }
        } else if n == CONFIG_NAME {
            if ours.is_some() && config_is_ours(root) {
                Plan::Config
            } else {
                Plan::Skip("launch options not written by this installer")
            }
        } else if n.starts_with("install.json.tmp-") || n.starts_with("pending-cleanup.json.tmp-") {
            // A record temp file that an interrupted write left behind. Ours only when a record
            // of ours exists, the name is exactly what `write_record` generates, and the content
            // parses as a record this installer writes.
            if ours.is_some() && is_regular(st) && tmp_is_ours(root, n) {
                Plan::Tmp
            } else {
                Plan::Skip("not created by this installer")
            }
        } else if DATA_DIRS.contains(&n) {
            if ours.is_none() {
                Plan::Skip("install record missing or not ours, so the directory is not claimed")
            } else if is_dir(st) {
                Plan::Data
            } else {
                Plan::Skip("not a plain directory")
            }
        } else if is_staging_name(n) {
            Plan::Staging
        } else if is_dir(st) && is_safe_id(n) {
            Plan::Version
        } else {
            Plan::Skip("not created by this installer")
        };
        plan.push((name.clone(), item));
    }

    // The record goes first, so nothing can start the child from a directory being deleted.
    for (name, p) in &plan {
        if *p == Plan::Record {
            drop_file(root, name, &mut report);
        }
    }
    for (name, p) in &plan {
        match p {
            Plan::Record => {}
            Plan::Skip(why) => report.leave(name, why),
            Plan::Pending | Plan::Config | Plan::Tmp => drop_file(root, name, &mut report),
            Plan::Data => drop_dir(root, name, OWNED_DATA, &mut report)?,
            Plan::Staging => drop_dir(root, name, STAGING_MARK, &mut report)?,
            Plan::Version => drop_dir(root, name, OWNED, &mut report)?,
        }
    }
    Ok(report)
}

// ---- time -----------------------------------------------------------------------------------

/// `YYYY-MM-DDTHH:MM:SSZ` for a Unix time.
pub fn iso8601(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    // Civil-from-days (Howard Hinnant).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

pub fn now_iso8601() -> String {
    iso8601(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0),
    )
}

#[cfg(test)]
#[path = "state_tests.rs"]
pub(crate) mod tests;
