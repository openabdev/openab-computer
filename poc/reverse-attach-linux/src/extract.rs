//! Two-stage archive handling for the managed Playwright tier (ADR linux-browser-tier D3, R8.1;
//! L1a). A port of the Swift `SafeArchiveExtractor`, `TarProcessor` and `ZipProcessor`.
//!
//! Stage 1, `validate`, reads the whole archive and writes nothing. Stage 2, `extract`, re-reads
//! it, checks every entry against the plan again and creates entries below a directory fd, one
//! path component at a time, with `O_NOFOLLOW` and `O_EXCL`, so a symlink swapped into the target
//! cannot lead outside it. Only `tar.gz` (ustar, pax, GNU long names) and `zip` (stored and
//! deflate, no zip64, no encryption) exist; every other shape is refused. No `tar`, `unzip` or
//! other subprocess is ever used.
//!
//! Only a `VerifiedArtifact` (a file whose size and SHA-256 already matched the pin) can be
//! handed in, so unverified bytes cannot be extracted. Errors carry a fixed reason and never an
//! entry name or any archive text.

use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{self, BufRead, BufReader, Read};
use std::os::fd::{AsFd, OwnedFd};
use std::os::unix::fs::{FileExt, MetadataExt};
use std::path::Path;

use flate2::Crc;
use rustix::fs::{Mode, OFlags};
use sha2::{Digest, Sha256};

use crate::download::VerifiedArtifact;
use crate::manifest::Artifact;

/// Why an archive was refused. L1b maps every rejection to the `archive_rejected` code.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reason {
    UnsafePath,
    LinkEscape,
    ForbiddenType,
    Duplicate,
    CaseCollision,
    TooManyEntries,
    TooLarge,
    Ratio,
    Malformed,
    Unsupported,
    Setuid,
    Changed,
    Io,
}

impl Reason {
    pub fn as_str(self) -> &'static str {
        match self {
            Reason::UnsafePath => "unsafe_path",
            Reason::LinkEscape => "link_escape",
            Reason::ForbiddenType => "forbidden_type",
            Reason::Duplicate => "duplicate",
            Reason::CaseCollision => "case_collision",
            Reason::TooManyEntries => "too_many_entries",
            Reason::TooLarge => "too_large",
            Reason::Ratio => "ratio",
            Reason::Malformed => "malformed",
            Reason::Unsupported => "unsupported",
            Reason::Setuid => "setuid",
            Reason::Changed => "changed_between_stages",
            Reason::Io => "io",
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum ExtractError {
    Rejected(Reason),
}

impl ExtractError {
    pub fn reason(&self) -> Reason {
        let ExtractError::Rejected(r) = self;
        *r
    }
}

impl std::fmt::Display for ExtractError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.reason().as_str())
    }
}

type Res<T> = Result<T, ExtractError>;

fn rej<T>(r: Reason) -> Res<T> {
    Err(ExtractError::Rejected(r))
}

/// A reason carried through `io::Error`, so a capped reader can stop a decoder mid-stream.
#[derive(Debug)]
struct ReasonErr(Reason);

impl std::fmt::Display for ReasonErr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0.as_str())
    }
}
impl std::error::Error for ReasonErr {}

fn io_reason(r: Reason) -> io::Error {
    io::Error::other(ReasonErr(r))
}

/// Decoder and short-read errors are a malformed archive; anything else is an I/O failure.
fn map_io(e: io::Error) -> ExtractError {
    if let Some(r) = e.get_ref().and_then(|i| i.downcast_ref::<ReasonErr>()) {
        return ExtractError::Rejected(r.0);
    }
    match e.kind() {
        io::ErrorKind::UnexpectedEof | io::ErrorKind::InvalidInput | io::ErrorKind::InvalidData => {
            ExtractError::Rejected(Reason::Malformed)
        }
        _ => ExtractError::Rejected(Reason::Io),
    }
}

fn io_err(_: rustix::io::Errno) -> ExtractError {
    ExtractError::Rejected(Reason::Io)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    TarGz,
    Zip,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Limits {
    pub max_entries: u64,
    pub max_total_bytes: u64,
    pub max_entry_bytes: u64,
    pub strip_components: u32,
    /// Output over input bytes, applied once output passes `RATIO_FLOOR`. Defence in depth under
    /// the declared byte caps; not a pin field.
    pub max_ratio: u64,
}

pub const DEFAULT_MAX_RATIO: u64 = 200;
const RATIO_FLOOR: u64 = 1 << 20;

impl Limits {
    pub fn from_artifact(a: &Artifact) -> Limits {
        Limits {
            max_entries: a.entry_count.max(0) as u64,
            max_total_bytes: a.expanded_bytes.max(0) as u64,
            max_entry_bytes: a.max_entry_bytes.max(0) as u64,
            strip_components: a.strip_components.clamp(0, 4) as u32,
            max_ratio: DEFAULT_MAX_RATIO,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    File,
    Directory,
    Symlink,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlannedEntry {
    pub path: String,
    pub kind: Kind,
    pub mode: u32,
    pub size: u64,
    pub link_target: Option<String>,
    // zip only
    local_offset: u64,
    compressed_size: u64,
    method: u16,
    crc: u32,
}

/// What stage 1 learned. Stage 2 must see the same archive and the same entries.
#[derive(Debug)]
pub struct Plan {
    format: Format,
    entries: Vec<PlannedEntry>,
    total_bytes: u64,
    limits: Limits,
    identity: Identity,
}

impl Plan {
    pub fn entries(&self) -> &[PlannedEntry] {
        &self.entries
    }
    pub fn total_bytes(&self) -> u64 {
        self.total_bytes
    }
}

// ---- entry planner (port of Swift EntryPlanner) ---------------------------------------------

/// An entry as the archive names it, before the path rules.
#[derive(Clone, Debug)]
struct RawEntry {
    name: String,
    kind: Kind,
    mode: u32,
    size: u64,
    link_target: Option<String>,
    local_offset: u64,
    compressed_size: u64,
    method: u16,
    crc: u32,
}

impl RawEntry {
    fn simple(
        name: String,
        kind: Kind,
        mode: u32,
        size: u64,
        link_target: Option<String>,
    ) -> RawEntry {
        RawEntry {
            name,
            kind,
            mode,
            size,
            link_target,
            local_offset: 0,
            compressed_size: 0,
            method: 0,
            crc: 0,
        }
    }
}

struct EntryPlanner {
    limits: Limits,
    entries: Vec<PlannedEntry>,
    total_bytes: u64,
    kinds: HashMap<String, Kind>,
    lowered: HashMap<String, String>,
    /// Paths the archive lists as directories itself (not implied by a child's path).
    explicit: HashSet<String>,
    seen: u64,
}

impl EntryPlanner {
    fn new(limits: Limits) -> EntryPlanner {
        EntryPlanner {
            limits,
            entries: Vec::new(),
            total_bytes: 0,
            kinds: HashMap::new(),
            lowered: HashMap::new(),
            explicit: HashSet::new(),
            seen: 0,
        }
    }

    /// The planned entry, or `None` for the stripped top directory.
    fn accept(&mut self, e: RawEntry) -> Res<Option<PlannedEntry>> {
        self.seen += 1;
        if self.seen > self.limits.max_entries {
            return rej(Reason::TooManyEntries);
        }
        let Some(path) = normalize(
            &e.name,
            self.limits.strip_components as usize,
            e.kind == Kind::Directory,
        )?
        else {
            if e.kind != Kind::Directory {
                return rej(Reason::UnsafePath);
            }
            return Ok(None);
        };
        if e.mode & 0o6000 != 0 {
            return rej(Reason::Setuid);
        }
        let comps: Vec<&str> = path.split('/').collect();
        let parents = &comps[..comps.len() - 1];
        // Every parent must be a directory (an explicit one, or one that does not exist yet): an
        // entry never passes through an earlier symlink or file.
        let mut prefix = String::new();
        for c in parents {
            if !prefix.is_empty() {
                prefix.push('/');
            }
            prefix.push_str(c);
            match self.kinds.get(&prefix) {
                Some(k) if *k != Kind::Directory => return rej(Reason::UnsafePath),
                Some(_) => {}
                // A parent the archive never lists is still a directory: a later file or link of
                // that name is a conflict.
                None => {
                    self.kinds.insert(prefix.clone(), Kind::Directory);
                }
            }
            if let Some(other) = self.lowered.get(&prefix.to_lowercase()) {
                if *other != prefix {
                    return rej(Reason::CaseCollision);
                }
            }
        }
        if let Some(prior) = self.kinds.get(&path) {
            // A directory implied by an earlier child may be listed once; any other repeat of a
            // path is a duplicate.
            if *prior != e.kind || e.kind != Kind::Directory || self.explicit.contains(&path) {
                return rej(Reason::Duplicate);
            }
        } else if let Some(other) = self.lowered.get(&path.to_lowercase()) {
            if *other != path {
                return rej(Reason::CaseCollision);
            }
        }
        let mut acc = String::new();
        for c in &comps {
            if !acc.is_empty() {
                acc.push('/');
            }
            acc.push_str(c);
            self.lowered
                .entry(acc.to_lowercase())
                .or_insert_with(|| acc.clone());
        }
        let mut target = None;
        match e.kind {
            Kind::File => {
                if e.size > self.limits.max_entry_bytes {
                    return rej(Reason::TooLarge);
                }
                self.total_bytes = self.total_bytes.saturating_add(e.size);
                if self.total_bytes > self.limits.max_total_bytes {
                    return rej(Reason::TooLarge);
                }
            }
            Kind::Directory => {}
            Kind::Symlink => {
                let Some(t) = e.link_target else {
                    return rej(Reason::LinkEscape);
                };
                check_link(&t, parents.len())?;
                target = Some(t);
            }
        }
        if e.kind == Kind::Directory {
            self.explicit.insert(path.clone());
        }
        self.kinds.insert(path.clone(), e.kind);
        let planned = PlannedEntry {
            path,
            kind: e.kind,
            mode: if e.kind == Kind::Directory {
                0o755
            } else {
                e.mode & 0o755
            },
            size: if e.kind == Kind::File { e.size } else { 0 },
            link_target: target,
            local_offset: e.local_offset,
            compressed_size: e.compressed_size,
            method: e.method,
            crc: e.crc,
        };
        self.entries.push(planned.clone());
        Ok(Some(planned))
    }
}

/// Absolute paths, `..`, empty or NUL-containing names, names over 1024 bytes: refused. `.`
/// components are dropped (`./a`). `None` if nothing is left after stripping.
fn normalize(raw: &str, strip: usize, is_dir: bool) -> Res<Option<String>> {
    if raw.is_empty() || raw.len() > 1024 || raw.as_bytes().contains(&0) || raw.starts_with('/') {
        return rej(Reason::UnsafePath);
    }
    let mut comps: Vec<&str> = raw.split('/').collect();
    if comps.last() == Some(&"") {
        comps.pop(); // directory entries end in a slash
    }
    comps.retain(|c| *c != ".");
    if comps.iter().any(|c| c.is_empty() || *c == "..") {
        return rej(Reason::UnsafePath);
    }
    if comps.len() <= strip {
        if (comps.len() == strip && is_dir) || (comps.is_empty() && is_dir) {
            return Ok(None);
        }
        return rej(Reason::UnsafePath);
    }
    Ok(Some(comps[strip..].join("/")))
}

/// A relative target made of leading `..` components, then plain names, that stays inside the
/// root. Mixed forms such as `a/../b` are refused: a link met halfway could make the physical
/// walk differ from the logical one. `depth` is the number of parent directories of the link.
fn check_link(t: &str, depth: usize) -> Res<()> {
    if t.is_empty() || t.len() > 1024 || t.as_bytes().contains(&0) || t.starts_with('/') {
        return rej(Reason::LinkEscape);
    }
    let mut comps: Vec<&str> = t.split('/').collect();
    if comps.last() == Some(&"") {
        comps.pop();
    }
    let (mut ups, mut names) = (0usize, 0usize);
    for c in comps {
        if c.is_empty() || c == "." {
            return rej(Reason::LinkEscape);
        }
        if c == ".." {
            if names > 0 {
                return rej(Reason::LinkEscape);
            }
            ups += 1;
        } else {
            names += 1;
        }
    }
    if ups > depth {
        return rej(Reason::LinkEscape);
    }
    Ok(())
}

// ---- stage 1 and 2 entry points -------------------------------------------------------------

fn open_archive(path: &Path) -> Res<File> {
    let fd = rustix::fs::open(
        path,
        OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(io_err)?;
    let f = File::from(fd);
    if !f.metadata().map_err(map_io)?.is_file() {
        return rej(Reason::Io);
    }
    Ok(f)
}

/// Device, inode, size, mtime and ctime. ctime moves on every write and cannot be set from user
/// space, so a same-size in-place edit with restored timestamps still changes the identity.
type Identity = (u64, u64, u64, i64, i64, i64, i64);

fn identity(f: &File) -> Res<Identity> {
    let m = f.metadata().map_err(map_io)?;
    Ok((
        m.dev(),
        m.ino(),
        m.size(),
        m.mtime(),
        m.mtime_nsec(),
        m.ctime(),
        m.ctime_nsec(),
    ))
}

/// SHA-256 of the open descriptor's bytes, read with `pread` so the cursor stays at 0.
fn hash_fd(f: &File) -> Res<[u8; 32]> {
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 64 * 1024];
    let mut off = 0u64;
    loop {
        let n = f.read_at(&mut buf, off).map_err(map_io)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
        off += n as u64;
    }
    Ok(h.finalize().into())
}

/// Opens the artifact and proves that the descriptor we are about to parse holds the bytes the
/// download step verified: the digest is recomputed over this very descriptor, and the identity
/// is re-read after the stage so a later in-place write is caught too.
fn open_verified(file: &VerifiedArtifact) -> Res<(File, Identity)> {
    let f = open_archive(file.path())?;
    let id = identity(&f)?;
    if hash_fd(&f)? != file.sha256() {
        return rej(Reason::Changed);
    }
    if identity(&f)? != id {
        return rej(Reason::Changed);
    }
    Ok((f, id))
}

/// Stage 1: reads the whole archive, applies every path and size rule, writes nothing.
pub fn validate(file: &VerifiedArtifact, format: Format, limits: &Limits) -> Res<Plan> {
    let (f, id) = open_verified(file)?;
    let mut planner = EntryPlanner::new(limits.clone());
    match format {
        Format::TarGz => run_tar_gz(
            f.try_clone().map_err(map_io)?,
            limits,
            &mut PlanningSink {
                planner: &mut planner,
            },
        )?,
        Format::Zip => zip_plan(&f, &mut planner)?,
    }
    if identity(&f)? != id {
        return rej(Reason::Changed);
    }
    Ok(Plan {
        format,
        entries: planner.entries,
        total_bytes: planner.total_bytes,
        limits: limits.clone(),
        identity: id,
    })
}

/// Stage 2: re-reads the archive and writes it below `into`, an existing empty directory.
pub fn extract(plan: &Plan, file: &VerifiedArtifact, into: &Path) -> Res<()> {
    extract_with_hook(plan, file, into, &mut |_, _| {})
}

/// `before` runs ahead of every planned entry (tests swap things in the target there).
fn extract_with_hook(
    plan: &Plan,
    file: &VerifiedArtifact,
    into: &Path,
    before: &mut dyn FnMut(usize, &PlannedEntry),
) -> Res<()> {
    let (f, id) = open_verified(file)?;
    if id != plan.identity {
        return rej(Reason::Changed);
    }
    let mut writer = TreeWriter::open(into)?;
    extract_body(plan, &f, &mut writer, before)?;
    if identity(&f)? != id {
        return rej(Reason::Changed);
    }
    Ok(())
}

fn extract_body(
    plan: &Plan,
    f: &File,
    writer: &mut TreeWriter,
    before: &mut dyn FnMut(usize, &PlannedEntry),
) -> Res<()> {
    match plan.format {
        Format::TarGz => {
            let mut sink = ExtractingSink {
                planner: EntryPlanner::new(plan.limits.clone()),
                plan,
                writer,
                index: 0,
                mode: 0,
                before,
            };
            run_tar_gz(f.try_clone().map_err(map_io)?, &plan.limits, &mut sink)?;
            if sink.index != plan.entries.len() {
                return rej(Reason::Changed);
            }
            Ok(())
        }
        Format::Zip => zip_extract(plan, f, writer, before),
    }
}

// ---- tree writer ----------------------------------------------------------------------------

/// Creates entries below a directory fd, one component at a time, never following a link.
struct TreeWriter {
    root: OwnedFd,
    current: Option<File>,
}

impl TreeWriter {
    fn open(into: &Path) -> Res<TreeWriter> {
        let root = rustix::fs::open(
            into,
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        )
        .map_err(io_err)?;
        // A fresh staging directory is the contract: anything already in it is a refusal.
        let dir = rustix::fs::Dir::read_from(&root).map_err(io_err)?;
        for e in dir {
            let e = e.map_err(io_err)?;
            let n = e.file_name().to_bytes();
            if n != b"." && n != b".." {
                return rej(Reason::Io);
            }
        }
        Ok(TreeWriter {
            root,
            current: None,
        })
    }

    fn open_dir(parent: &OwnedFd, name: &str) -> Res<OwnedFd> {
        rustix::fs::openat(
            parent,
            name,
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        )
        .map_err(io_err)
    }

    fn parent_fd(&mut self, comps: &[&str]) -> Res<OwnedFd> {
        if comps.is_empty() {
            return self.root.try_clone().map_err(map_io);
        }
        // Always re-walk from the root with O_NOFOLLOW: a cached directory fd would keep
        // pointing at a directory that was renamed away after its first use.
        let mut cur = self.root.try_clone().map_err(map_io)?;
        for c in comps {
            match rustix::fs::mkdirat(&cur, *c, Mode::from_raw_mode(0o755)) {
                Ok(()) | Err(rustix::io::Errno::EXIST) => {}
                Err(_) => return rej(Reason::Io),
            }
            cur = Self::open_dir(&cur, c)?;
        }
        Ok(cur)
    }

    fn split(path: &str) -> (Vec<&str>, &str) {
        let mut c: Vec<&str> = path.split('/').collect();
        let last = c.pop().unwrap_or("");
        (c, last)
    }

    fn make_directory(&mut self, path: &str) -> Res<()> {
        let (comps, last) = Self::split(path);
        let parent = self.parent_fd(&comps)?;
        match rustix::fs::mkdirat(&parent, last, Mode::from_raw_mode(0o755)) {
            Ok(()) => Ok(()),
            Err(rustix::io::Errno::EXIST) => Self::open_dir(&parent, last).map(|_| ()),
            Err(_) => rej(Reason::Io),
        }
    }

    fn make_symlink(&mut self, path: &str, target: &str) -> Res<()> {
        let (comps, last) = Self::split(path);
        let parent = self.parent_fd(&comps)?;
        rustix::fs::symlinkat(target, &parent, last).map_err(io_err)
    }

    fn begin_file(&mut self, path: &str) -> Res<()> {
        let (comps, last) = Self::split(path);
        let parent = self.parent_fd(&comps)?;
        let fd = rustix::fs::openat(
            &parent,
            last,
            OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::from_raw_mode(0o600),
        )
        .map_err(io_err)?;
        self.current = Some(File::from(fd));
        Ok(())
    }

    fn write(&mut self, buf: &[u8]) -> Res<()> {
        use std::io::Write;
        match self.current.as_mut() {
            Some(f) => f.write_all(buf).map_err(map_io),
            None => rej(Reason::Io),
        }
    }

    fn end_file(&mut self, mode: u32) -> Res<()> {
        let Some(f) = self.current.take() else {
            return Ok(());
        };
        rustix::fs::fchmod(f.as_fd(), Mode::from_bits_truncate((mode & 0o755) as _)).map_err(io_err)
    }
}

// ---- tar ------------------------------------------------------------------------------------

trait TarSink {
    /// A real entry (not a pax or GNU long-name record). `true` asks for its data.
    fn header(&mut self, e: RawEntry) -> Res<bool>;
    fn data(&mut self, b: &[u8]) -> Res<()>;
    fn end_entry(&mut self) -> Res<()>;
}

struct PlanningSink<'a> {
    planner: &'a mut EntryPlanner,
}

impl TarSink for PlanningSink<'_> {
    fn header(&mut self, e: RawEntry) -> Res<bool> {
        self.planner.accept(e)?;
        Ok(false)
    }
    fn data(&mut self, _: &[u8]) -> Res<()> {
        Ok(())
    }
    fn end_entry(&mut self) -> Res<()> {
        Ok(())
    }
}

struct ExtractingSink<'a> {
    planner: EntryPlanner,
    plan: &'a Plan,
    writer: &'a mut TreeWriter,
    index: usize,
    mode: u32,
    before: &'a mut dyn FnMut(usize, &PlannedEntry),
}

impl TarSink for ExtractingSink<'_> {
    fn header(&mut self, e: RawEntry) -> Res<bool> {
        // The same rules run again; the result must equal what stage 1 planned.
        let Some(planned) = self.planner.accept(e)? else {
            return Ok(false);
        };
        if self.index >= self.plan.entries.len() || self.plan.entries[self.index] != planned {
            return rej(Reason::Changed);
        }
        (self.before)(self.index, &planned);
        self.index += 1;
        match planned.kind {
            Kind::Directory => {
                self.writer.make_directory(&planned.path)?;
                Ok(false)
            }
            Kind::Symlink => {
                self.writer
                    .make_symlink(&planned.path, planned.link_target.as_deref().unwrap_or(""))?;
                Ok(false)
            }
            Kind::File => {
                self.writer.begin_file(&planned.path)?;
                self.mode = planned.mode;
                Ok(true)
            }
        }
    }
    fn data(&mut self, b: &[u8]) -> Res<()> {
        self.writer.write(b)
    }
    fn end_entry(&mut self) -> Res<()> {
        self.writer.end_file(self.mode)
    }
}

/// Counts decompressed bytes and stops a bomb at the cap or at the ratio limit.
struct Capped<R> {
    inner: R,
    produced: u64,
    cap: u64,
    ratio_cap: u64,
}

impl<R: Read> Read for Capped<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.produced += n as u64;
        if self.produced > self.cap {
            return Err(io_reason(Reason::TooLarge));
        }
        if self.produced > RATIO_FLOOR && self.produced > self.ratio_cap {
            return Err(io_reason(Reason::Ratio));
        }
        Ok(n)
    }
}

/// Decompress `file` (one gzip member, nothing after it) and parse it as tar into `sink`.
fn run_tar_gz(file: File, limits: &Limits, sink: &mut dyn TarSink) -> Res<()> {
    let compressed = file.metadata().map_err(map_io)?.len();
    let cap = limits
        .max_total_bytes
        .saturating_add(limits.max_entries.saturating_add(16).saturating_mul(4096))
        .saturating_add(1 << 20);
    let gz = flate2::bufread::GzDecoder::new(BufReader::with_capacity(64 * 1024, file));
    let mut r = Capped {
        inner: gz,
        produced: 0,
        cap,
        ratio_cap: compressed.saturating_mul(limits.max_ratio),
    };
    parse_tar(&mut r, sink)?;
    // Read to the end of the member so flate2 checks the CRC and length trailer, then require
    // that nothing follows the member in the file.
    let mut sink_buf = [0u8; 8192];
    loop {
        match r.read(&mut sink_buf).map_err(map_io)? {
            0 => break,
            n => {
                if sink_buf[..n].iter().any(|b| *b != 0) {
                    return rej(Reason::Malformed);
                }
            }
        }
    }
    let mut rest = r.inner.into_inner();
    if !rest.fill_buf().map_err(map_io)?.is_empty() {
        return rej(Reason::Malformed);
    }
    Ok(())
}

fn octal(b: &[u8]) -> Res<u64> {
    if b.first().is_some_and(|f| f & 0x80 != 0) {
        return rej(Reason::Unsupported);
    }
    let mut v: u64 = 0;
    let mut any = false;
    for &c in b {
        if c == 0 || c == b' ' {
            if any {
                break;
            }
            continue;
        }
        if !(b'0'..=b'7').contains(&c) {
            return rej(Reason::Malformed);
        }
        v = v.wrapping_mul(8).wrapping_add(u64::from(c - b'0'));
        any = true;
        if v > (1 << 40) {
            return rej(Reason::TooLarge);
        }
    }
    Ok(v)
}

/// The size field: octal, or GNU base-256 (a leading 0x80 byte). Huge values are `too_large`.
fn tar_size(b: &[u8]) -> Res<u64> {
    match b.first() {
        Some(0x80) => {
            let mut v: u64 = 0;
            for &c in &b[1..] {
                if v > (1 << 40) {
                    return rej(Reason::TooLarge);
                }
                v = (v << 8) | u64::from(c);
            }
            if v > (1 << 40) {
                return rej(Reason::TooLarge);
            }
            Ok(v)
        }
        Some(f) if f & 0x80 != 0 => rej(Reason::Malformed), // negative or unknown encoding
        _ => octal(b),
    }
}

fn utf8(b: &[u8]) -> Res<String> {
    String::from_utf8(b.to_vec()).or_else(|_| rej(Reason::Malformed))
}

fn cstr(b: &[u8]) -> Res<String> {
    let end = b.iter().position(|c| *c == 0).unwrap_or(b.len());
    utf8(&b[..end])
}

const META_MAX: u64 = 65536;

/// A pull parser for ustar, pax (`path`, `linkpath`) and GNU long names. Hardlinks, devices,
/// FIFOs, contiguous and sparse files are refused, and so is any unknown type flag.
fn parse_tar<R: Read>(r: &mut R, sink: &mut dyn TarSink) -> Res<()> {
    let mut block = [0u8; 512];
    let mut buf = vec![0u8; 64 * 1024];
    let mut pending_path: Option<String> = None;
    let mut pending_link: Option<String> = None;
    loop {
        // A missing end marker (stream ends where a header should be) is a truncated archive.
        r.read_exact(&mut block).map_err(map_io)?;
        if block.iter().all(|b| *b == 0) {
            r.read_exact(&mut block).map_err(map_io)?;
            if block.iter().any(|b| *b != 0) {
                return rej(Reason::Malformed);
            }
            return Ok(());
        }
        // Checksum: sum of all bytes with the checksum field read as spaces.
        let sum: u64 = block
            .iter()
            .enumerate()
            .map(|(i, b)| {
                if (148..156).contains(&i) {
                    0x20
                } else {
                    u64::from(*b)
                }
            })
            .sum();
        if octal(&block[148..156])? != sum {
            return rej(Reason::Malformed);
        }
        let typ = block[156];
        let size = tar_size(&block[124..136])?;
        let mode = octal(&block[100..108])?;
        let padding = ((512 - size % 512) % 512) as usize;
        match typ {
            b'x' | b'g' | b'L' | b'K' => {
                if size > META_MAX {
                    return rej(Reason::TooLarge);
                }
                let mut meta = vec![0u8; size as usize];
                r.read_exact(&mut meta).map_err(map_io)?;
                r.read_exact(&mut buf[..padding]).map_err(map_io)?;
                apply_meta(typ, &meta, &mut pending_path, &mut pending_link)?;
            }
            b'0' | 0 | b'5' | b'2' => {
                let mut name = cstr(&block[0..100])?;
                if &block[257..263] == b"ustar\0" {
                    let prefix = cstr(&block[345..500])?;
                    if !prefix.is_empty() {
                        name = format!("{prefix}/{name}");
                    }
                }
                let mut link = cstr(&block[157..257])?;
                if let Some(p) = pending_path.take() {
                    name = p;
                }
                if let Some(l) = pending_link.take() {
                    link = l;
                }
                let kind = match typ {
                    b'5' => Kind::Directory,
                    b'2' => Kind::Symlink,
                    _ => Kind::File,
                };
                if (kind == Kind::File && name.ends_with('/')) || (kind != Kind::File && size != 0)
                {
                    return rej(Reason::Malformed);
                }
                let deliver = sink.header(RawEntry::simple(
                    name,
                    kind,
                    (mode & 0xFFFF) as u32,
                    size,
                    (kind == Kind::Symlink).then_some(link),
                ))?;
                if kind == Kind::File {
                    let mut left = size;
                    while left > 0 {
                        let n = left.min(buf.len() as u64) as usize;
                        r.read_exact(&mut buf[..n]).map_err(map_io)?;
                        if deliver {
                            sink.data(&buf[..n])?;
                        }
                        left -= n as u64;
                    }
                    r.read_exact(&mut buf[..padding]).map_err(map_io)?;
                    sink.end_entry()?;
                }
            }
            b'1' | b'3' | b'4' | b'6' | b'7' | b'S' => return rej(Reason::ForbiddenType),
            _ => return rej(Reason::Unsupported),
        }
    }
}

fn apply_meta(
    kind: u8,
    meta: &[u8],
    path: &mut Option<String>,
    link: &mut Option<String>,
) -> Res<()> {
    match kind {
        b'L' | b'K' => {
            let end = meta.iter().position(|c| *c == 0).unwrap_or(meta.len());
            if meta[end..].iter().any(|c| *c != 0) {
                return rej(Reason::Malformed);
            }
            let s = utf8(&meta[..end])?;
            if kind == b'L' {
                *path = Some(s);
            } else {
                *link = Some(s);
            }
        }
        _ => {
            // pax local ("x") or global ("g"): `<len> <key>=<value>\n` records.
            let mut i = 0usize;
            while i < meta.len() {
                let Some(sp) = meta[i..].iter().position(|c| *c == b' ').map(|p| p + i) else {
                    return rej(Reason::Malformed);
                };
                let len_txt = std::str::from_utf8(&meta[i..sp]).ok().filter(|s| {
                    !s.is_empty() && s.len() <= 8 && s.bytes().all(|c| c.is_ascii_digit())
                });
                let len: usize = len_txt.and_then(|s| s.parse().ok()).unwrap_or(0);
                if len == 0
                    || i + len > meta.len()
                    || meta[i + len - 1] != b'\n'
                    || sp + 1 > i + len - 1
                {
                    return rej(Reason::Malformed);
                }
                let rec = &meta[sp + 1..i + len - 1];
                let Some(eq) = rec.iter().position(|c| *c == b'=') else {
                    return rej(Reason::Malformed);
                };
                let (key, val) = (&rec[..eq], &rec[eq + 1..]);
                if val.contains(&0) && (key == b"path" || key == b"linkpath") {
                    return rej(Reason::UnsafePath);
                }
                match key {
                    b"path" | b"linkpath" => {
                        if kind != b'x' {
                            return rej(Reason::Unsupported);
                        }
                        let v = utf8(val)?;
                        if key == b"path" {
                            *path = Some(v);
                        } else {
                            *link = Some(v);
                        }
                    }
                    b"size" => return rej(Reason::Unsupported),
                    _ => {}
                }
                i += len;
            }
        }
    }
    Ok(())
}

// ---- zip ------------------------------------------------------------------------------------

const ZIP_CD_MAX: u64 = 16 * 1024 * 1024;

#[derive(Clone, Debug)]
struct Central {
    name: String,
    flags: u16,
    method: u16,
    crc: u32,
    csize: u64,
    usize: u64,
    local_offset: u64,
    host_unix: bool,
    attr: u32,
}

fn u16le(b: &[u8], o: usize) -> u16 {
    u16::from_le_bytes([b[o], b[o + 1]])
}
fn u32le(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
}

fn pread(f: &File, off: u64, buf: &mut [u8]) -> Res<()> {
    f.read_exact_at(buf, off).map_err(map_io)
}

fn zip_plan(f: &File, planner: &mut EntryPlanner) -> Res<()> {
    let size = f.metadata().map_err(map_io)?.len();
    let entries = read_central(f, size, planner.limits.max_entries)?;
    let mut ranges: Vec<(u64, u64)> = Vec::new();
    let mut scratch = vec![0u8; 64 * 1024];
    for c in &entries {
        let data_start = local_data(f, size, c)?;
        ranges.push((c.local_offset, data_start + c.csize));
        let unix_mode = if c.host_unix {
            (c.attr >> 16) & 0xFFFF
        } else {
            0
        };
        let fmt = unix_mode & 0o170000;
        let kind = match fmt {
            0 | 0o100000 => {
                if c.name.ends_with('/') {
                    Kind::Directory
                } else {
                    Kind::File
                }
            }
            0o040000 => Kind::Directory,
            0o120000 => Kind::Symlink,
            _ => return rej(Reason::ForbiddenType),
        };
        if c.name.ends_with('/') && kind != Kind::Directory {
            return rej(Reason::Malformed);
        }
        let mut mode = unix_mode & 0o7777;
        if fmt == 0 {
            mode = if kind == Kind::Directory {
                0o755
            } else {
                0o644
            };
        }
        let mut target = None;
        if kind == Kind::Symlink {
            if c.usize == 0 || c.usize > 1024 {
                return rej(Reason::LinkEscape);
            }
            target = Some(read_small(f, c, data_start)?);
        }
        if kind == Kind::Directory && c.usize != 0 {
            return rej(Reason::Malformed);
        }
        if kind == Kind::File
            && c.usize > RATIO_FLOOR
            && c.usize > c.csize.saturating_mul(planner.limits.max_ratio)
        {
            return rej(Reason::Ratio);
        }
        planner.accept(RawEntry {
            name: c.name.clone(),
            kind,
            mode,
            size: c.usize,
            link_target: target,
            local_offset: c.local_offset,
            compressed_size: c.csize,
            method: c.method,
            crc: c.crc,
        })?;
        if kind == Kind::File {
            // Inflate and check the whole payload now, writing nothing, so a wrong CRC or a
            // lying length is refused before stage 2 creates anything.
            zip_stream(
                f,
                data_start,
                c.csize,
                c.method,
                c.usize,
                c.crc,
                &mut scratch,
                &mut |_| Ok(()),
            )?;
        }
    }
    ranges.sort();
    for w in ranges.windows(2) {
        if w[1].0 < w[0].1 {
            return rej(Reason::Malformed);
        }
    }
    Ok(())
}

fn read_central(f: &File, size: u64, max_entries: u64) -> Res<Vec<Central>> {
    if size < 22 {
        return rej(Reason::Malformed);
    }
    let tail_len = size.min(22 + 65535) as usize;
    let mut tail = vec![0u8; tail_len];
    pread(f, size - tail_len as u64, &mut tail)?;
    let mut eocd = None;
    let mut i = tail_len - 22;
    loop {
        if tail[i..i + 4] == [0x50, 0x4b, 5, 6]
            && i + 22 + usize::from(u16le(&tail, i + 20)) == tail_len
        {
            eocd = Some(i);
            break;
        }
        if i == 0 {
            break;
        }
        i -= 1;
    }
    let Some(eocd) = eocd else {
        return rej(Reason::Malformed);
    };
    // A zip64 locator sits just before the end record.
    if eocd >= 20 && tail[eocd - 20..eocd - 16] == [0x50, 0x4b, 6, 7] {
        return rej(Reason::Unsupported);
    }
    let (disk, cd_disk) = (u16le(&tail, eocd + 4), u16le(&tail, eocd + 6));
    let (on_disk, total) = (u16le(&tail, eocd + 8), u16le(&tail, eocd + 10));
    let (cd_size, cd_offset) = (
        u64::from(u32le(&tail, eocd + 12)),
        u64::from(u32le(&tail, eocd + 16)),
    );
    if disk != 0 || cd_disk != 0 || on_disk != total {
        return rej(Reason::Unsupported);
    }
    if total == 0xFFFF || cd_size == 0xFFFF_FFFF || cd_offset == 0xFFFF_FFFF {
        return rej(Reason::Unsupported);
    }
    if u64::from(total) > max_entries {
        return rej(Reason::TooManyEntries);
    }
    if cd_offset + cd_size > size - tail_len as u64 + eocd as u64 || cd_size >= ZIP_CD_MAX {
        return rej(Reason::Malformed);
    }
    let mut cd = vec![0u8; cd_size as usize];
    pread(f, cd_offset, &mut cd)?;
    let mut out = Vec::new();
    let mut p = 0usize;
    for _ in 0..total {
        if p + 46 > cd.len() || u32le(&cd, p) != 0x0201_4b50 {
            return rej(Reason::Malformed);
        }
        let made = u16le(&cd, p + 4);
        let (flags, method) = (u16le(&cd, p + 8), u16le(&cd, p + 10));
        let (crc, csize, usize_) = (u32le(&cd, p + 16), u32le(&cd, p + 20), u32le(&cd, p + 24));
        let (nlen, elen, clen) = (
            usize::from(u16le(&cd, p + 28)),
            usize::from(u16le(&cd, p + 30)),
            usize::from(u16le(&cd, p + 32)),
        );
        let (disk_start, attr, lho) = (u16le(&cd, p + 34), u32le(&cd, p + 38), u32le(&cd, p + 42));
        if p + 46 + nlen + elen + clen > cd.len() {
            return rej(Reason::Malformed);
        }
        if flags & 0x1 != 0 || flags & 0x40 != 0 || flags & 0x2000 != 0 {
            return rej(Reason::Unsupported);
        }
        if method != 0 && method != 8 {
            return rej(Reason::Unsupported);
        }
        if csize == 0xFFFF_FFFF || usize_ == 0xFFFF_FFFF || lho == 0xFFFF_FFFF || disk_start != 0 {
            return rej(Reason::Unsupported);
        }
        let name = utf8(&cd[p + 46..p + 46 + nlen])?;
        out.push(Central {
            name,
            flags,
            method,
            crc,
            csize: u64::from(csize),
            usize: u64::from(usize_),
            local_offset: u64::from(lho),
            host_unix: (made >> 8) == 3,
            attr,
        });
        p += 46 + nlen + elen + clen;
    }
    if p != cd.len() {
        return rej(Reason::Malformed);
    }
    Ok(out)
}

/// Validates the local header against the central entry; returns where the data starts.
fn local_data(f: &File, size: u64, c: &Central) -> Res<u64> {
    let mut h = [0u8; 30];
    if c.local_offset + 30 > size {
        return rej(Reason::Malformed);
    }
    pread(f, c.local_offset, &mut h)?;
    if u32le(&h, 0) != 0x0403_4b50 {
        return rej(Reason::Malformed);
    }
    let (nlen, elen) = (usize::from(u16le(&h, 26)), u64::from(u16le(&h, 28)));
    // The local header must agree with the central directory (flags, method and, unless a data
    // descriptor follows, CRC and sizes), so the two views of one entry cannot differ.
    if u16le(&h, 6) != c.flags || u16le(&h, 8) != c.method {
        return rej(Reason::Malformed);
    }
    if c.flags & 0x8 == 0
        && (u32le(&h, 14) != c.crc
            || u64::from(u32le(&h, 18)) != c.csize
            || u64::from(u32le(&h, 22)) != c.usize)
    {
        return rej(Reason::Malformed);
    }
    if nlen != c.name.len() {
        return rej(Reason::Malformed);
    }
    let mut nb = vec![0u8; nlen];
    pread(f, c.local_offset + 30, &mut nb)?;
    if nb != c.name.as_bytes() {
        return rej(Reason::Malformed);
    }
    let start = c.local_offset + 30 + nlen as u64 + elen;
    if start + c.csize > size {
        return rej(Reason::Malformed);
    }
    if c.method == 0 && c.csize != c.usize {
        return rej(Reason::Malformed);
    }
    Ok(start)
}

/// A small entry's content (a symlink target), decoded, bounded to 1024 bytes.
fn read_small(f: &File, c: &Central, data_start: u64) -> Res<String> {
    if c.csize > 65536 {
        return rej(Reason::Malformed);
    }
    let mut raw = vec![0u8; c.csize as usize];
    pread(f, data_start, &mut raw)?;
    let out = if c.method == 0 {
        raw
    } else {
        let mut dec = flate2::bufread::DeflateDecoder::new(&raw[..]);
        let mut out = Vec::new();
        (&mut dec)
            .take(1025)
            .read_to_end(&mut out)
            .map_err(map_io)?;
        if out.len() > 1024 {
            return rej(Reason::TooLarge);
        }
        if !dec.into_inner().is_empty() {
            return rej(Reason::Malformed);
        }
        out
    };
    if out.len() as u64 != c.usize {
        return rej(Reason::Malformed);
    }
    utf8(&out)
}

/// Reads a bounded window of the archive with `pread`.
struct Window<'a> {
    f: &'a File,
    off: u64,
    left: u64,
}

impl Read for Window<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = (buf.len() as u64).min(self.left) as usize;
        if n == 0 {
            return Ok(0);
        }
        let got = self.f.read_at(&mut buf[..n], self.off)?;
        if got == 0 {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        self.off += got as u64;
        self.left -= got as u64;
        Ok(got)
    }
}

/// Streams one entry's data through `sink`, bounded by the declared size, and checks the real
/// length, the CRC and that the deflate stream ends where the entry's data ends. Stage 1 runs it
/// with a sink that discards, so a lying header is refused before anything is created.
#[allow(clippy::too_many_arguments)]
fn zip_stream(
    f: &File,
    start: u64,
    csize: u64,
    method: u16,
    usize_: u64,
    want_crc: u32,
    buf: &mut [u8],
    sink: &mut dyn FnMut(&[u8]) -> Res<()>,
) -> Res<()> {
    let win = Window {
        f,
        off: start,
        left: csize,
    };
    let mut crc = Crc::new();
    let mut written = 0u64;
    let mut emit = |piece: &[u8]| -> Res<()> {
        written += piece.len() as u64;
        if written > usize_ {
            return rej(Reason::TooLarge);
        }
        crc.update(piece);
        sink(piece)
    };
    if method == 8 {
        let mut dec =
            flate2::bufread::DeflateDecoder::new(BufReader::with_capacity(64 * 1024, win));
        loop {
            let n = dec.read(buf).map_err(map_io)?;
            if n == 0 {
                break;
            }
            emit(&buf[..n])?;
        }
        let mut rest = dec.into_inner();
        if !rest.fill_buf().map_err(map_io)?.is_empty() {
            return rej(Reason::Malformed);
        }
    } else {
        let mut win = win;
        loop {
            let n = win.read(buf).map_err(map_io)?;
            if n == 0 {
                break;
            }
            emit(&buf[..n])?;
        }
    }
    if written != usize_ || crc.sum() != want_crc {
        return rej(Reason::Malformed);
    }
    Ok(())
}

fn zip_extract(
    plan: &Plan,
    f: &File,
    writer: &mut TreeWriter,
    before: &mut dyn FnMut(usize, &PlannedEntry),
) -> Res<()> {
    // Re-read the central directory and require the same entries in the same order.
    let mut again = EntryPlanner::new(plan.limits.clone());
    zip_plan(f, &mut again)?;
    if again.entries != plan.entries {
        return rej(Reason::Changed);
    }
    let mut buf = vec![0u8; 64 * 1024];
    for (idx, e) in plan.entries.iter().enumerate() {
        before(idx, e);
        match e.kind {
            Kind::Directory => writer.make_directory(&e.path)?,
            Kind::Symlink => {
                writer.make_symlink(&e.path, e.link_target.as_deref().unwrap_or(""))?
            }
            Kind::File => {
                let mut h = [0u8; 30];
                pread(f, e.local_offset, &mut h)?;
                if u32le(&h, 0) != 0x0403_4b50 {
                    return rej(Reason::Changed);
                }
                // The local header's name was checked against the central name when planning; the
                // data start is recomputed from the local header's own lengths.
                let start =
                    e.local_offset + 30 + u64::from(u16le(&h, 26)) + u64::from(u16le(&h, 28));
                writer.begin_file(&e.path)?;
                zip_stream(
                    f,
                    start,
                    e.compressed_size,
                    e.method,
                    e.size,
                    e.crc,
                    &mut buf,
                    &mut |piece| writer.write(piece),
                )?;
                writer.end_file(e.mode)?;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
#[path = "extract_tests.rs"]
mod tests;
