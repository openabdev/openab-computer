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

/// Longest `XDG_RUNTIME_DIR` accepted as the base of a short temporary directory: Chromium puts a
/// Unix socket below it, and a socket path over about 100 bytes is refused.
const SHORT_BASE_MAX: usize = 40;

/// The directory under which a short private temporary directory is created, opened as an fd so
/// every later step works relative to what was checked.
///
/// `candidate` (the caller reads `XDG_RUNTIME_DIR`) is used only when it is an absolute path of at
/// most 40 bytes that opens without following a link (`O_NOFOLLOW`) and is a directory owned by the
/// effective user that nobody else can write to. Anything else, including a symlinked or
/// group-writable directory, falls back to a per-user private directory `oab-<euid>` below the
/// shared temp directory: created 0700 if absent, and refused unless it is a real directory owned
/// by us with mode exactly 0700. The shared temp directory itself is never the base.
pub fn open_private_base(candidate: Option<&Path>) -> R<(OwnedFd, PathBuf)> {
    open_private_base_in(candidate, Path::new("/tmp"), euid())
}

/// The path `open_private_base` would choose, decided read-only (nothing is created or opened for
/// writing). For `browser status`, which must name the child's `TMPDIR` without making it.
pub fn private_base_path(candidate: Option<&Path>) -> PathBuf {
    private_base_path_in(candidate, Path::new("/tmp"), euid())
}

pub(crate) fn private_base_path_in(
    candidate: Option<&Path>,
    shared_tmp: &Path,
    uid: u32,
) -> PathBuf {
    use std::os::unix::fs::MetadataExt;
    if let Some(c) = candidate.filter(|c| c.is_absolute() && c.as_os_str().len() <= SHORT_BASE_MAX)
    {
        if std::fs::symlink_metadata(c)
            .is_ok_and(|m| m.is_dir() && m.uid() == uid && m.mode() & 0o022 == 0)
        {
            return c.to_path_buf();
        }
    }
    shared_tmp.join(format!("oab-{uid}"))
}

pub(crate) fn open_private_base_in(
    candidate: Option<&Path>,
    shared_tmp: &Path,
    uid: u32,
) -> R<(OwnedFd, PathBuf)> {
    if let Some(c) = candidate.filter(|c| c.is_absolute() && c.as_os_str().len() <= SHORT_BASE_MAX)
    {
        let opened = rustix::fs::open(
            c,
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        );
        if let Ok(fd) = opened {
            if rustix::fs::fstat(&fd).is_ok_and(|st| st.st_uid == uid && private_dir(&st)) {
                return Ok((fd, c.to_path_buf()));
            }
        }
    }
    let tmp = rustix::fs::open(
        shared_tmp,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(|_| Fail("tmp_unavailable"))?;
    let name = format!("oab-{uid}");
    match rustix::fs::mkdirat(&tmp, name.as_str(), Mode::from_raw_mode(0o700)) {
        Ok(()) => {}
        Err(e) if e == rustix::io::Errno::EXIST => {}
        Err(_) => return Err(Fail("tmp_unavailable")),
    }
    let fd = rustix::fs::openat(
        &tmp,
        name.as_str(),
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(|_| Fail("tmp_unavailable"))?;
    let st = rustix::fs::fstat(&fd).map_err(|_| Fail("tmp_unavailable"))?;
    if !is_dir(&st) || st.st_uid != uid || mode_bits(&st) != 0o700 {
        return Err(Fail("tmp_unavailable"));
    }
    Ok((fd, shared_tmp.join(name)))
}

/// `mkdirat` (mode 0700 unless told otherwise) then `open_dir_at`. The directory is fresh, so a
/// refusal here means somebody raced us.
pub fn create_dir_at(dir: &impl AsFd, name: &str) -> R<OwnedFd> {
    rustix::fs::mkdirat(dir, name, Mode::from_raw_mode(0o700)).map_err(|_| IO)?;
    open_dir_at(dir, name)
}

/// Writes a new file, failing if the name exists. Mode 0600 unless given.
pub fn write_new_file(dir: &impl AsFd, name: &str, bytes: &[u8], mode: u32) -> R<()> {
    write_new_file_id(dir, name, bytes, mode).map(|_| ())
}

/// Like [`write_new_file`], and returns the identity (`fstat` of the open file) of what it
/// created, so a later cleanup can prove it is deleting its own file and not a replacement.
pub fn write_new_file_id(dir: &impl AsFd, name: &str, bytes: &[u8], mode: u32) -> R<Stat> {
    let fd = rustix::fs::openat(
        dir,
        name,
        OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::from_raw_mode(mode as _),
    )
    .map_err(|_| IO)?;
    // `O_EXCL` made the file, so `fstat` of the open descriptor is its identity.
    let st = rustix::fs::fstat(&fd).map_err(|_| IO)?;
    let mut f = File::from(fd);
    if f.write_all(bytes).is_err() || f.sync_all().is_err() {
        drop(f);
        let _ = unlink_if_same(dir, name, &st);
        return Err(IO);
    }
    Ok(st)
}

/// Reads a regular file below `dir`, at most `cap` bytes. A symlink, a FIFO or anything else that
/// is not a regular file, and a file over the cap, are errors.
pub fn read_file_capped(dir: &impl AsFd, name: &str, cap: u64) -> R<Vec<u8>> {
    read_file_id(dir, name, cap).map(|(b, _)| b)
}

/// [`read_file_capped`] that also returns the identity of the object that was read (`fstat` of
/// the open descriptor). A caller that decides ownership from the bytes and then deletes must pass
/// this identity to [`unlink_if_same`].
pub fn read_file_id(dir: &impl AsFd, name: &str, cap: u64) -> R<(Vec<u8>, Stat)> {
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
    Ok((out, st))
}

#[cfg(test)]
type Hook = std::cell::RefCell<Option<Box<dyn Fn(&std::path::Path)>>>;

#[cfg(test)]
thread_local! {
    /// Runs between the temp file being written and the swap; tests plant files here.
    pub(crate) static BEFORE_SWAP: Hook = const { std::cell::RefCell::new(None) };
    /// Runs after the first exchange and before the displaced file is examined.
    pub(crate) static AFTER_SWAP: Hook = const { std::cell::RefCell::new(None) };
    /// Runs between a record unlink's ownership decision and its identity recheck.
    pub(crate) static BEFORE_UNLINK: Hook = const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
fn fire(hook: &'static std::thread::LocalKey<Hook>, dir: &impl AsFd) {
    hook.with(|h| {
        if let (Some(f), Ok(p)) = (
            h.borrow().as_ref(),
            std::fs::read_link(format!(
                "/proc/self/fd/{}",
                std::os::fd::AsRawFd::as_raw_fd(&dir.as_fd())
            )),
        ) {
            f(&p);
        }
    });
}

/// Deletes `dir/name` only while it is still the object `id` names (same device and inode, by
/// `lstat`). A replacement, a link or a vanished name is left alone and reported as
/// `record_changed`. The gap between the `lstat` and the `unlinkat` is a few instructions long;
/// POSIX has no unlink-if-same-inode, and every caller also holds the install lock.
pub fn unlink_if_same(dir: &impl AsFd, name: &str, id: &Stat) -> R<()> {
    #[cfg(test)]
    fire(&BEFORE_UNLINK, dir);
    match lstat_at(dir, name)? {
        Some(cur) if same_object(&cur, id) => {
            rustix::fs::unlinkat(dir, name, AtFlags::empty()).map_err(|_| IO)
        }
        _ => Err(Fail("record_changed")),
    }
}

/// Write-then-rename of a small record: temp file (`O_EXCL`, 0600, fsync) renamed onto `name` with
/// `RENAME_NOREPLACE`, so it never overwrites anything. To replace a record that exists use
/// [`write_record_cas`].
pub fn write_record(dir: &impl AsFd, name: &str, bytes: &[u8]) -> R<()> {
    let tmp = format!("{name}.tmp-{}", random_hex(8));
    let id = write_new_file_id(dir, &tmp, bytes, 0o600)?;
    if rustix::fs::renameat_with(dir, tmp.as_str(), dir, name, RenameFlags::NOREPLACE).is_err() {
        let _ = unlink_if_same(dir, &tmp, &id);
        return Err(IO);
    }
    Ok(())
}

/// Replaces `name` only when it still holds exactly `expected` at the moment of the swap.
///
/// The new bytes are written to a temp file and swapped in with `RENAME_EXCHANGE`. The file that
/// was displaced is then read from the temp name (its identity is kept) and compared with
/// `expected`. When it differs (or cannot be read) the swap is undone, so a record that appeared
/// after the caller's own read is put back and `record_changed` is reported.
///
/// Fail-closed rules, each tested:
/// - The temp name is unlinked only while `lstat` still shows the object this function expects
///   there: its own temp file after a swap back, the displaced original after a verified swap.
///   Anything else found there (a third writer's file) is left, and the class is
///   `record_changed_left` so the caller can say a stray file remains. When the swap cannot be
///   undone the class is `record_swap_stuck`: the new record is in place and the displaced file
///   stays under the temp name.
/// - A file system without `RENAME_EXCHANGE` gives `record_replace_unsupported`. There is no
///   compare-then-rename fallback, because it would reopen the overwrite race. Nothing is
///   replaced and the temp file is removed.
pub fn write_record_cas(dir: &impl AsFd, name: &str, bytes: &[u8], expected: &[u8]) -> R<()> {
    let tmp = format!("{name}.tmp-{}", random_hex(8));
    let mine = write_new_file_id(dir, &tmp, bytes, 0o600)?;
    #[cfg(test)]
    fire(&BEFORE_SWAP, dir);
    match rustix::fs::renameat_with(dir, tmp.as_str(), dir, name, RenameFlags::EXCHANGE) {
        Ok(()) => {}
        Err(rustix::io::Errno::INVAL | rustix::io::Errno::NOSYS | rustix::io::Errno::OPNOTSUPP) => {
            let _ = unlink_if_same(dir, &tmp, &mine);
            return Err(Fail("record_replace_unsupported"));
        }
        Err(_) => {
            let _ = unlink_if_same(dir, &tmp, &mine);
            return Err(IO);
        }
    }
    #[cfg(test)]
    fire(&AFTER_SWAP, dir);
    // `tmp` now names what used to be `name`. Read it by descriptor so the identity and the bytes
    // are of the same object.
    let displaced = read_file_id(dir, &tmp, RECORD_CAP);
    if let Ok((old, old_id)) = &displaced {
        if old == expected {
            // Verified: remove exactly the object that was read.
            // The record is replaced. If the displaced copy cannot be removed (it changed or
            // vanished) it stays as a `.tmp-` file that `remove` recognises by name and content.
            let _ = unlink_if_same(dir, &tmp, old_id);
            return Ok(());
        }
    }
    // Put the displaced entry back, then remove our own temp file if it is what came back.
    if rustix::fs::renameat_with(dir, tmp.as_str(), dir, name, RenameFlags::EXCHANGE).is_err() {
        // Could not undo: `name` holds our new record and the other file stays under `tmp`.
        return Err(Fail("record_swap_stuck"));
    }
    match unlink_if_same(dir, &tmp, &mine) {
        Ok(()) => Err(Fail("record_changed")),
        // Something other than our temp file was swapped in meanwhile: it is not ours to delete.
        Err(_) => Err(Fail("record_changed_left")),
    }
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

/// A shared hold on `.install.lock`, for a process that starts a child while `install`, `update`
/// and `remove` (which take the exclusive [`Lock`]) must not run. Any number may hold it at once.
/// Dropping it releases it.
pub struct SharedLock {
    _fd: OwnedFd,
}

impl SharedLock {
    /// Takes `.install.lock` shared, retrying a non-blocking `flock` every 100 ms for `wait`.
    /// `lock_held` when an exclusive holder (or a cancel) outlasts it.
    pub fn try_acquire(root: &Root, wait: Duration) -> R<SharedLock> {
        let fd = open_lock_file(root)?;
        let started = Instant::now();
        loop {
            match rustix::fs::flock(&fd, FlockOperation::NonBlockingLockShared) {
                Ok(()) => return Ok(SharedLock { _fd: fd }),
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
    open_named_lock(root, LOCK_NAME)
}

/// Opens (creating) a lock file directly below the root: a regular file we own, never followed
/// through a link. The file is kept permanently; only the `flock` on it comes and goes.
pub fn open_named_lock(root: &Root, name: &str) -> R<OwnedFd> {
    let fd = rustix::fs::openat(
        root.fd(),
        name,
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

/// Parses the bytes of `pending-cleanup.json`: `{"schema":1,"previous":"<id>"}`.
fn parse_pending(bytes: &[u8]) -> Option<String> {
    let v: Value = serde_json::from_slice(bytes).ok()?;
    if v.get("schema")?.as_i64()? != 1 {
        return None;
    }
    let p = v.get("previous")?.as_str()?;
    is_safe_id(p).then(|| p.to_string())
}

/// `pending-cleanup.json`: `{"schema":1,"previous":"<id>"}`.
pub fn pending_previous(root: &Root) -> Option<String> {
    let bytes = read_file_capped(root.fd(), PENDING_NAME, RECORD_CAP).ok()?;
    parse_pending(&bytes)
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
/// the record it would have become. For `install.json` that is the rule of the record itself
/// (`record_is_ours`: the version directory it names carries the installer's marker), so a file a
/// third party left under that name, or that `write_record_cas` parked there, is not claimed on the
/// strength of its shape alone (#132). Anything else (a note someone named `install.json.tmp-x`) is
/// left in place.
fn tmp_bytes_ours(root: &Root, name: &str, bytes: &[u8]) -> bool {
    match tmp_base(name) {
        Some(RECORD_NAME) => InstallRecord::parse(bytes).is_some_and(|r| record_is_ours(root, &r)),
        Some(_) => parse_pending(bytes).is_some(),
        None => false,
    }
}

/// `pw-config.json` is ours only when it is a JSON object with `_oabInstallerOwned: true`.
pub fn config_bytes_ours(bytes: &[u8]) -> bool {
    serde_json::from_slice::<Value>(bytes)
        .ok()
        .and_then(|v| v.get("_oabInstallerOwned").and_then(Value::as_bool))
        == Some(true)
}

fn config_is_ours(root: &Root) -> bool {
    read_file_capped(root.fd(), CONFIG_NAME, CONFIG_CAP).is_ok_and(|b| config_bytes_ours(&b))
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
        // Cannot be listed: not shown to be empty.
        return 1;
    };
    let mut names = Vec::new();
    for (i, e) in dir.flatten().enumerate() {
        // More entries than can be read: records may be hidden, so count one as live (fail closed).
        if i >= 10_000 {
            return 1;
        }
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

/// Removes a regular file below the root that proves to be ours. The file is opened without
/// following a link, read (capped), judged by `ours`, and then unlinked only while `lstat` still
/// shows that same object. A file that fails the judgement, or was replaced between judgement and
/// unlink, is left and reported.
fn drop_checked(
    root: &Root,
    name: &str,
    cap: u64,
    ours: &dyn Fn(&[u8]) -> bool,
    report: &mut Report,
) {
    match lstat_at(root.fd(), name) {
        Ok(Some(st)) if is_regular(&st) => match read_file_id(root.fd(), name, cap) {
            Ok((bytes, id)) if ours(&bytes) => match unlink_if_same(root.fd(), name, &id) {
                Ok(()) => report.removed.push(name.to_string()),
                Err(Fail("record_changed")) => {
                    report.leave(name, "changed while it was being removed")
                }
                Err(_) => {
                    report.failed = true;
                    report.leave(name, "could not delete");
                }
            },
            Ok(_) => report.leave(name, "not created by this installer"),
            Err(_) => report.leave(name, "not readable as a record of this installer"),
        },
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
    // Delete the pending record only if it is still the one that named `prev`.
    match read_file_id(root.fd(), PENDING_NAME, RECORD_CAP) {
        Ok((bytes, id)) if parse_pending(&bytes).as_deref() == Some(prev.as_str()) => {
            match unlink_if_same(root.fd(), PENDING_NAME, &id) {
                Ok(()) | Err(Fail("record_changed")) => {}
                Err(_) => return Err(IO),
            }
        }
        _ => {}
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
            if ours.is_some() && is_regular(st) {
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

    // The record goes first, so nothing can start the child from a directory being deleted. Every
    // file is judged again from the bytes of the object that is unlinked (`drop_checked`), so a
    // file swapped in after planning is left, not deleted.
    let ours_version = ours.as_ref().map(|r| r.version.clone());
    let record_ours = |b: &[u8]| {
        InstallRecord::parse(b)
            .is_some_and(|r| Some(&r.version) == ours_version.as_ref() && record_is_ours(root, &r))
    };
    for (name, p) in &plan {
        if *p == Plan::Record {
            drop_checked(root, name, RECORD_CAP, &record_ours, &mut report);
        }
    }
    // Files first: a record's rule (`record_is_ours`) reads the version directory it names, which
    // must still be there. Directories after.
    for (name, p) in &plan {
        match p {
            Plan::Record | Plan::Data | Plan::Staging | Plan::Version => {}
            Plan::Skip(why) => report.leave(name, why),
            Plan::Pending => drop_checked(
                root,
                name,
                RECORD_CAP,
                &|b| parse_pending(b).is_some(),
                &mut report,
            ),
            Plan::Config => drop_checked(root, name, CONFIG_CAP, &config_bytes_ours, &mut report),
            Plan::Tmp => {
                let nm = name.clone();
                drop_checked(
                    root,
                    name,
                    RECORD_CAP,
                    &move |b| tmp_bytes_ours(root, &nm, b),
                    &mut report,
                )
            }
        }
    }
    for (name, p) in &plan {
        let marker = match p {
            Plan::Data => OWNED_DATA,
            Plan::Staging => STAGING_MARK,
            Plan::Version => OWNED,
            _ => continue,
        };
        // A walker error after the record was deleted must not hide the report.
        if drop_dir(root, name, marker, &mut report).is_err() {
            report.failed = true;
            report.leave(name, "could not be fully removed");
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
