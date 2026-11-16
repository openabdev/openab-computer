//! `browser install`, `update`, `remove` and `status` (ADR linux-browser-tier R3.1 to R3.4, R2.5,
//! D17; L1b). Counterpart of the Swift `PlaywrightInstaller`.
//!
//! Install flow, every step inside one lock and one staging directory:
//!
//! 1. validate the embedded manifest, run the preflight (no root, no packages);
//! 2. open the root (a symlink or foreign owner stops here), take `.install.lock`;
//! 3. decide ownership before any network traffic: a foreign `install.json`, or a `profile/`,
//!    `output/`, `home/` or `run/` the installer did not create, stops the run with nothing touched;
//! 4. sweep leftover marked staging directories, build everything in `.staging-<hex>/`: download
//!    and verify (or copy and verify from `--from-dir`), extract, `npm ci`, ELF scan, headless
//!    health check on a throwaway profile;
//! 5. commit: create missing data directories, rename staging to `<manifest id>/`, write
//!    `install.json` last, by write-then-rename.
//!
//! Every error path runs the staging guard: the staging directory is deleted (marker-gated), data
//! directories this run created are removed, a version directory renamed in but not recorded is
//! removed. `install.json` is written last, so before that moment nothing sees a new install, and an
//! update keeps serving the old version until the record changes.
//!
//! Errors are fixed class names; nothing printed carries a URL, a header, tool output or stderr.

use std::io::Write;
use std::os::fd::OwnedFd;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::Value;

use crate::consent;
use crate::download::{self, DownloadPolicy, Pin};
use crate::extract::{self, Format};
use crate::health;
use crate::manifest::{is_safe_id, Artifact, Manifest, PlatformId, Selection};
use crate::npm;
use crate::preflight::{self, Facts, Libc};
use crate::state::{
    self, Fail, InstallRecord, Lock, Report, Root, State, MARKER_TEXT, OWNED, OWNED_DATA, R,
    STAGING_MARK,
};

/// The embedded `package.json` and `package-lock.json`, or test substitutes.
pub struct Files<'a> {
    pub package_json: &'a str,
    pub lockfile: &'a str,
}

pub enum Source<'a> {
    Network(&'a DownloadPolicy),
    /// `--from-dir`: a directory of pre-fetched artifacts. No network is touched.
    Dir(&'a Path),
}

pub struct Opts<'a> {
    pub manifest: &'a Manifest,
    pub files: Files<'a>,
    pub source: Source<'a>,
    /// Run the manifest's own validation. Always true outside the unit tests, which build small
    /// manifests that point at a loopback server.
    pub check_manifest: bool,
    pub limits: download::Limits,
    pub timeouts: health::Timeouts,
    pub npm_timeout: Duration,
    pub lock_wait: Duration,
    /// `<base>/oab-computer/playwright` is the root.
    pub base: PathBuf,
    pub home: Option<PathBuf>,
    pub platform: Option<PlatformId>,
    pub facts: &'a dyn Fn(&Path) -> Facts,
}

pub struct Io<'a> {
    pub out: &'a mut dyn Write,
    pub err: &'a mut dyn Write,
}

impl Io<'_> {
    pub fn say(&mut self, s: &str) {
        let _ = writeln!(self.out, "{s}");
    }
    pub fn note(&mut self, s: &str) {
        let _ = writeln!(self.err, "{s}");
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Done {
    Installed(String),
    AlreadyInstalled(String),
    Updated { from: String, to: String },
    AlreadyUpToDate(String),
}

// ---- shared checks --------------------------------------------------------------------------

fn selection<'a>(o: &'a Opts<'_>) -> R<Selection<'a>> {
    if o.check_manifest {
        let m = o.manifest;
        if !m.validate().is_empty()
            || !m
                .validate_embedded_files(o.files.package_json, o.files.lockfile)
                .is_empty()
            || !m.platform_policy_problems().is_empty()
        {
            return Err(Fail("manifest_invalid"));
        }
    }
    o.manifest
        .select(o.platform)
        .map_err(|_| Fail("unsupported_platform"))
}

/// The text shown before an install or update: what is downloaded, or, for `--from-dir`, that
/// nothing is.
fn consent_text(o: &Opts<'_>, sel: &Selection<'_>) -> String {
    let path = o.base.join("oab-computer").join("playwright");
    match &o.source {
        Source::Network(_) => consent::text(o.manifest, sel, &path, o.home.as_deref()),
        Source::Dir(d) => consent::text_offline(o.manifest, sel, &path, o.home.as_deref(), d),
    }
}

fn digests(m: &Manifest, sel: &Selection<'_>) -> std::collections::BTreeMap<String, String> {
    [
        ("node", sel.node.sha256.clone()),
        ("chromium", sel.chromium.sha256.clone()),
        ("lockfile", m.mcp.lockfile_sha256.clone()),
        ("packageJson", m.mcp.package_json_sha256.clone()),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect()
}

fn chromium_exe<'a>(sel: &Selection<'a>) -> R<&'a str> {
    sel.chromium
        .executable
        .as_deref()
        .ok_or(Fail("manifest_invalid"))
}

/// Does `profile/`, `output/`, `home/` or `run/` exist without the installer's own marker?
fn foreign_data(root: &Root) -> R<bool> {
    for d in state::DATA_DIRS {
        let Some(st) = state::lstat_at(root.fd(), d)? else {
            continue;
        };
        if !state::is_dir(&st) {
            return Ok(true);
        }
        let Ok(fd) = state::open_dir_at(root.fd(), d) else {
            return Ok(true);
        };
        if !state::marker_present(&fd, OWNED_DATA) {
            return Ok(true);
        }
    }
    Ok(false)
}

fn basename(url: &str) -> R<String> {
    let u = crate::manifest::parse_url(url).ok_or(Fail("manifest_invalid"))?;
    let n = u.path.rsplit('/').next().unwrap_or("");
    if n.is_empty() || n.starts_with('.') || n.contains(['\0', '/']) {
        return Err(Fail("manifest_invalid"));
    }
    Ok(n.to_string())
}

/// The npm tarballs of the lockfile: file name and the 64 raw SHA-512 bytes of `integrity`.
fn lockfile_tarballs(lockfile: &str) -> R<Vec<(String, [u8; 64])>> {
    use base64::Engine;
    let v: Value = serde_json::from_str(lockfile).map_err(|_| Fail("manifest_invalid"))?;
    let pk = v
        .get("packages")
        .and_then(Value::as_object)
        .ok_or(Fail("manifest_invalid"))?;
    let mut out: Vec<(String, [u8; 64])> = Vec::new();
    for (key, p) in pk {
        if key.is_empty() || p.get("dev").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let (Some(resolved), Some(integrity)) = (
            p.get("resolved").and_then(Value::as_str),
            p.get("integrity").and_then(Value::as_str),
        ) else {
            continue;
        };
        let b64 = integrity
            .split_whitespace()
            .find_map(|i| i.strip_prefix("sha512-"))
            .ok_or(Fail("manifest_invalid"))?;
        let raw = base64::engine::general_purpose::STANDARD
            .decode(b64)
            .map_err(|_| Fail("manifest_invalid"))?;
        let digest: [u8; 64] = raw.try_into().map_err(|_| Fail("manifest_invalid"))?;
        let name = basename(resolved)?;
        if out.iter().any(|(n, _)| *n == name) {
            return Err(Fail("manifest_invalid"));
        }
        out.push((name, digest));
    }
    if out.is_empty() {
        return Err(Fail("manifest_invalid"));
    }
    Ok(out)
}

// ---- the staging guard ----------------------------------------------------------------------

/// Undoes a half-finished install on every exit path that does not reach `disarm`.
struct Guard<'a> {
    root: &'a Root,
    staging: Option<String>,
    marker: &'static str,
    created_data: Vec<&'static str>,
    new_version: Option<String>,
    armed: bool,
}

impl<'a> Guard<'a> {
    fn new(root: &'a Root) -> Guard<'a> {
        Guard {
            root,
            staging: None,
            marker: STAGING_MARK,
            created_data: Vec::new(),
            new_version: None,
            armed: true,
        }
    }
}

impl Drop for Guard<'_> {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let mut report = Report::default();
        if let Some(n) = &self.staging {
            let _ = state::remove_marked_tree(self.root.fd(), n, self.marker, &mut report);
        }
        if let Some(v) = &self.new_version {
            let _ = state::remove_marked_tree(self.root.fd(), v, OWNED, &mut report);
        }
        for d in self.created_data.iter().rev() {
            let _ = state::remove_marked_tree(self.root.fd(), d, OWNED_DATA, &mut report);
        }
    }
}

// ---- the short temporary directory of the health check -------------------------------------------

/// A private directory with a short path for the health check's `TMPDIR`. Removed on drop, on every
/// path, after the children that used it have been stopped.
struct ShortTmp {
    parent: OwnedFd,
    name: String,
    path: PathBuf,
}

impl ShortTmp {
    fn create() -> R<ShortTmp> {
        // `XDG_RUNTIME_DIR` is private to the user where it exists; `/tmp` otherwise. Either is a
        // short path.
        let runtime = std::env::var_os("XDG_RUNTIME_DIR")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute() && p.as_os_str().len() <= 40 && p.is_dir());
        let base = runtime.unwrap_or_else(|| PathBuf::from("/tmp"));
        let parent = rustix::fs::open(
            &base,
            rustix::fs::OFlags::RDONLY
                | rustix::fs::OFlags::DIRECTORY
                | rustix::fs::OFlags::CLOEXEC,
            rustix::fs::Mode::empty(),
        )
        .map_err(|_| state::IO)?;
        let name = format!("oab-hc-{}", state::random_hex(6));
        let fd = state::create_dir_at(&parent, &name)?;
        if let Err(e) = state::write_new_file(&fd, OWNED_DATA, MARKER_TEXT, 0o600) {
            let _ = rustix::fs::unlinkat(&parent, name.as_str(), rustix::fs::AtFlags::REMOVEDIR);
            return Err(e);
        }
        let path = base.join(&name);
        Ok(ShortTmp { parent, name, path })
    }
}

impl Drop for ShortTmp {
    fn drop(&mut self) {
        let mut rep = Report::default();
        let _ = state::remove_marked_tree(&self.parent, &self.name, OWNED_DATA, &mut rep);
    }
}

// ---- building the staged install ------------------------------------------------------------

struct Staged {
    name: String,
}

fn mb_line(verb: &str, what: &str, done: u64, total: u64) -> String {
    format!(
        "{verb} {what}: {} of {} MB",
        done / 1_000_000,
        total.div_ceil(1_000_000)
    )
}

fn get_archive(
    o: &Opts<'_>,
    io: &mut Io<'_>,
    what: &str,
    a: &Artifact,
    dl: &Path,
    dst: &str,
) -> R<download::VerifiedArtifact> {
    let pin = Pin::from_artifact(a);
    let verb = match &o.source {
        Source::Network(_) => "downloading",
        Source::Dir(_) => "copying and checking",
    };
    let mut last = u64::MAX;
    let mut progress = |n: u64| {
        let step = n / 5_000_000;
        if step != last {
            last = step;
            io.note(&mb_line(verb, what, n, pin.size));
        }
    };
    let res = match &o.source {
        Source::Network(policy) => download::fetch(policy, &pin, dl, dst, &o.limits, &mut progress),
        Source::Dir(dir) => {
            download::verify_local(dir, &basename(&a.url)?, &pin, dl, dst, &mut progress)
        }
    };
    res.map_err(|e| Fail(e.as_str()))
}

fn check_cancel() -> R<()> {
    if crate::cancel::is_cancelled() {
        Err(Fail("cancelled"))
    } else {
        Ok(())
    }
}

fn extract_into(
    staging_fd: &OwnedFd,
    staging_abs: &Path,
    dir: &str,
    art: &download::VerifiedArtifact,
    a: &Artifact,
) -> R<()> {
    let format = match a.format.as_str() {
        "tar.gz" => Format::TarGz,
        "zip" => Format::Zip,
        _ => return Err(Fail("manifest_invalid")),
    };
    state::create_dir_at(staging_fd, dir)?;
    let limits = extract::Limits::from_artifact(a);
    let map = |e: extract::ExtractError| {
        if e.reason() == extract::Reason::Io {
            Fail("extract_io")
        } else {
            Fail("archive_rejected")
        }
    };
    let plan = extract::validate(art, format, &limits).map_err(map)?;
    extract::extract(&plan, art, &staging_abs.join(dir)).map_err(map)
}

/// Everything from the empty staging directory to a verified, finished tree. On `Err` the guard
/// removes the directory.
fn build(
    o: &Opts<'_>,
    sel: &Selection<'_>,
    root: &Root,
    io: &mut Io<'_>,
    facts: &Facts,
    guard: &mut Guard<'_>,
) -> R<Staged> {
    let name = state::new_staging_name();
    rustix::fs::mkdirat(
        root.fd(),
        name.as_str(),
        rustix::fs::Mode::from_raw_mode(0o700),
    )
    .map_err(|_| state::IO)?;
    let fd = match state::open_dir_at(root.fd(), &name) {
        Ok(fd) => fd,
        Err(e) => {
            let _ = rustix::fs::unlinkat(root.fd(), name.as_str(), rustix::fs::AtFlags::REMOVEDIR);
            return Err(e);
        }
    };
    if let Err(e) = state::write_new_file(&fd, STAGING_MARK, MARKER_TEXT, 0o600) {
        let _ = rustix::fs::unlinkat(root.fd(), name.as_str(), rustix::fs::AtFlags::REMOVEDIR);
        return Err(e);
    }
    guard.staging = Some(name.clone());
    guard.marker = STAGING_MARK;
    let abs = root.abs_path().join(&name);

    // Downloads (or the local copies), verified before anything reads them.
    let dl_fd = state::create_dir_at(&fd, "dl")?;
    let dl = abs.join("dl");
    let node_art = get_archive(o, io, "Node.js", sel.node, &dl, "node-archive")?;
    let chrome_art = get_archive(o, io, "Chromium", sel.chromium, &dl, "chromium-archive")?;

    // Package files, whose digests were checked against the manifest in `selection`.
    let pkg_fd = state::create_dir_at(&fd, "pkg")?;
    state::write_new_file(
        &pkg_fd,
        "package.json",
        o.files.package_json.as_bytes(),
        0o600,
    )?;
    state::write_new_file(
        &pkg_fd,
        "package-lock.json",
        o.files.lockfile.as_bytes(),
        0o600,
    )?;

    check_cancel()?;
    extract_into(&fd, &abs, "node", &node_art, sel.node)?;
    check_cancel()?;
    extract_into(&fd, &abs, "chromium", &chrome_art, sel.chromium)?;
    check_cancel()?;
    drop(node_art);
    drop(chrome_art);

    let exe_rel = format!("chromium/{}", chromium_exe(sel)?);
    let exec_ok = |rel: &str| state::stat_rel(&fd, rel).is_some_and(|st| state::is_exec_file(&st));
    let cli_rel = "pkg/node_modules/@playwright/mcp/cli.js";
    let npm_cli = "node/lib/node_modules/npm/bin/npm-cli.js";
    if !exec_ok("node/bin/node")
        || !exec_ok(&exe_rel)
        || !state::stat_rel(&fd, npm_cli).is_some_and(|st| state::is_regular(&st))
    {
        return Err(Fail("layout_invalid"));
    }

    // Packages.
    npm::prepare(&fd)?;
    let offline = matches!(o.source, Source::Dir(_));
    if let Source::Dir(dir) = &o.source {
        let tar_fd = state::create_dir_at(&dl_fd, "npm")?;
        drop(tar_fd);
        let tar_dir = dl.join("npm");
        for (file, digest) in lockfile_tarballs(o.files.lockfile)? {
            download::verify_local_sha512(
                dir,
                &file,
                &digest,
                o.manifest.mcp.npm_download_bytes.max(0) as u64,
                &tar_dir,
                &file,
            )
            .map_err(|e| Fail(e.as_str()))?;
            let path = tar_dir.join(&file).to_string_lossy().into_owned();
            npm::require_ok(npm::run(
                &abs,
                &["cache", "add", &path],
                true,
                o.npm_timeout,
            ))?;
        }
    } else {
        io.note(&format!(
            "installing the npm packages (about {})",
            consent::megabytes(o.manifest.mcp.npm_download_bytes.max(0) as u64)
        ));
    }
    npm::require_ok(npm::run(&abs, &["ci"], offline, o.npm_timeout))?;
    if !state::stat_rel(&fd, cli_rel).is_some_and(|st| state::is_regular(&st)) {
        return Err(Fail("layout_invalid"));
    }

    check_cancel()?;
    // Libraries the staged binaries link against.
    if let Some(ld) = &facts.ld {
        let scan = preflight::scan_trees(
            &[&abs.join("node"), &abs.join("chromium")],
            ld,
            preflight::arch_tag(sel.platform),
        );
        if !scan.missing.is_empty() {
            io.say(&format!(
                "missing libraries ({}): {}",
                scan.missing.len(),
                scan.missing.join(", ")
            ));
            return Err(Fail("missing_libraries"));
        }
        if let (Libc::Glibc(Some(host)), Some(need)) = (&facts.libc, scan.glibc_need) {
            if need > *host {
                return Err(Fail("glibc_too_old"));
            }
        }
    }

    // Headless health check on a throwaway profile that never touches the real one.
    let hc_fd = state::create_dir_at(&fd, "hc")?;
    state::write_new_file(&hc_fd, OWNED_DATA, MARKER_TEXT, 0o600)?;
    state::create_dir_at(&hc_fd, "profile")?;
    state::create_dir_at(&hc_fd, "output")?;
    drop(hc_fd);
    let short_tmp = ShortTmp::create()?;
    let spec = health::launch_spec(
        &abs.join("node/bin/node"),
        &abs.join(cli_rel),
        &abs.join(&exe_rel),
        &abs.join("hc/profile"),
        &abs.join("hc/output"),
        &abs,
        &short_tmp.path,
    );
    io.note("running the headless health check");
    // The children are stopped inside `check`; the temporary directory goes when `short_tmp` drops.
    let checked = health::check(&spec, &abs, &o.timeouts);
    drop(short_tmp);
    checked.map_err(|f| Fail(f.class()))?;

    // Throwaways out, marker in, then the directory is a version directory.
    let mut rep = Report::default();
    for d in ["hc", "npm-cache", "home", "tmp", "dl"] {
        if !state::remove_staged_child(&fd, d, &mut rep)? {
            return Err(Fail("cleanup_failed"));
        }
    }
    for f in ["user.npmrc", "global.npmrc"] {
        rustix::fs::unlinkat(&fd, f, rustix::fs::AtFlags::empty()).map_err(|_| state::IO)?;
    }
    drop(dl_fd);
    state::write_new_file(&fd, OWNED, MARKER_TEXT, 0o600)?;
    guard.marker = OWNED;
    rustix::fs::unlinkat(&fd, STAGING_MARK, rustix::fs::AtFlags::empty()).map_err(|_| state::IO)?;
    Ok(Staged { name })
}

// Tests only: runs between the rename into place and the record write.
#[cfg(test)]
thread_local! {
    pub(crate) static AFTER_RENAME: std::cell::RefCell<Option<Box<dyn Fn(&Root)>>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
fn after_rename(root: &Root) {
    AFTER_RENAME.with(|h| {
        if let Some(f) = h.borrow().as_ref() {
            f(root);
        }
    });
}

#[cfg(not(test))]
fn after_rename(_: &Root) {}

/// Creates the data directories that do not exist, each with its marker. A directory that exists
/// must carry the marker (checked before the build; checked again here).
fn ensure_data_dirs(root: &Root, guard: &mut Guard<'_>) -> R<()> {
    for d in state::DATA_DIRS {
        match state::lstat_at(root.fd(), d)? {
            Some(_) => {
                let ok = state::open_dir_at(root.fd(), d)
                    .map(|fd| state::marker_present(&fd, OWNED_DATA))
                    .unwrap_or(false);
                if !ok {
                    return Err(Fail("foreign_data"));
                }
            }
            None => {
                let fd = state::create_dir_at(root.fd(), d)?;
                guard.created_data.push(d);
                state::write_new_file(&fd, OWNED_DATA, MARKER_TEXT, 0o600)?;
            }
        }
    }
    Ok(())
}

fn new_record(m: &Manifest, sel: &Selection<'_>, previous: Option<String>) -> R<InstallRecord> {
    Ok(InstallRecord {
        manifest_id: m.id.clone(),
        version: m.id.clone(),
        platform: sel.platform.as_str().to_string(),
        chromium_executable: chromium_exe(sel)?.to_string(),
        chromium_revision: m.chromium.revision.clone(),
        chromium_released_at: m.chromium.released_at.clone(),
        installed_at: state::now_iso8601(),
        previous,
        digests: digests(m, sel),
    })
}

/// Opens (or creates) the root, takes the lock and sweeps leftover staging. Everything that
/// follows runs under the returned lock.
fn locked_root(o: &Opts<'_>, io: &mut Io<'_>, create: bool) -> R<(Root, Lock)> {
    let root = Root::open(&o.base, create)?.ok_or(Fail("not_installed"))?;
    let lock = Lock::acquire(&root, o.lock_wait)?;
    let swept = state::sweep_staging(&root)?;
    for n in &swept.removed {
        io.note(&format!("removed leftover staging directory {n}"));
    }
    Ok((root, lock))
}

/// Runs the preflight, prints it, and fails on a blocker.
fn run_preflight(o: &Opts<'_>, sel: &Selection<'_>, io: &mut Io<'_>) -> R<Facts> {
    let facts = (o.facts)(&o.base);
    let report = preflight::evaluate(
        o.manifest,
        sel,
        &facts,
        consent::disk_needed(o.manifest, sel),
    );
    io.say(&preflight::render(&report));
    if !report.ok() {
        return Err(Fail("preflight_failed"));
    }
    Ok(facts)
}

fn pins_match(rec: &InstallRecord, m: &Manifest, sel: &Selection<'_>) -> bool {
    rec.digests == digests(m, sel)
}

/// Removes a leftover `<id>/` that is not the installed version: marked ones go, unmarked ones
/// are a collision and stop the run.
fn clear_target(root: &Root, id: &str, installed: Option<&str>) -> R<()> {
    if installed == Some(id) {
        return Ok(());
    }
    match state::lstat_at(root.fd(), id)? {
        None => Ok(()),
        Some(_) => {
            let mut rep = Report::default();
            state::remove_version_dir(root, id, &mut rep)?;
            if rep.left.is_empty() && !rep.failed {
                Ok(())
            } else {
                Err(Fail("commit_collision"))
            }
        }
    }
}

// ---- install --------------------------------------------------------------------------------

pub fn install(o: &Opts<'_>, io: &mut Io<'_>) -> R<Done> {
    let sel = selection(o)?;
    let id = o.manifest.id.as_str();
    if !is_safe_id(id) {
        return Err(Fail("manifest_invalid"));
    }
    // An install that is already in place needs no preflight and creates nothing. Checked again
    // under the lock below.
    if let Some(root) = Root::open(&o.base, false)? {
        if let State::Installed(rec) = state::read_state(&root)? {
            if rec.version == id && pins_match(&rec, o.manifest, &sel) {
                return Ok(Done::AlreadyInstalled(rec.version));
            }
        }
    }
    io.say(&consent_text(o, &sel));
    let facts = run_preflight(o, &sel, io)?;
    let (root, _lock) = locked_root(o, io, true)?;
    let before = state::record_bytes(&root)?;
    match state::read_state(&root)? {
        State::Foreign(_) => return Err(Fail("foreign_install")),
        State::Invalid(_) => return Err(Fail("install_invalid")),
        State::Installed(rec) => {
            if rec.version != id {
                return Err(Fail("use_update"));
            }
            if !pins_match(&rec, o.manifest, &sel) {
                return Err(Fail("pins_changed_same_id"));
            }
            return Ok(Done::AlreadyInstalled(rec.version));
        }
        State::NotInstalled => {}
    }
    if foreign_data(&root)? {
        return Err(Fail("foreign_data"));
    }
    state::run_pending_cleanup(&root)?;
    clear_target(&root, id, None)?;

    let mut guard = Guard::new(&root);
    let staged = build(o, &sel, &root, io, &facts, &mut guard)?;
    ensure_data_dirs(&root, &mut guard)?;
    // Compare-before-write: nothing else may have changed the record while we built.
    if state::record_bytes(&root)? != before {
        return Err(Fail("record_changed"));
    }
    rustix::fs::renameat_with(
        root.fd(),
        staged.name.as_str(),
        root.fd(),
        id,
        rustix::fs::RenameFlags::NOREPLACE,
    )
    .map_err(|_| Fail("commit_collision"))?;
    guard.staging = None;
    guard.new_version = Some(id.to_string());
    after_rename(&root);
    let rec = new_record(o.manifest, &sel, None)?;
    state::write_record(root.fd(), state::RECORD_NAME, rec.to_json().as_bytes())?;
    guard.armed = false;
    Ok(Done::Installed(id.to_string()))
}

// ---- update ---------------------------------------------------------------------------------

/// `ask` gets the question and answers `Some(true|false)`, or `None` when no one can be asked.
pub fn update(o: &Opts<'_>, io: &mut Io<'_>, ask: &mut dyn FnMut(&str) -> Option<bool>) -> R<Done> {
    let sel = selection(o)?;
    let id = o.manifest.id.as_str();
    if !is_safe_id(id) {
        return Err(Fail("manifest_invalid"));
    }
    let (root, _lock) = locked_root(o, io, false)?;
    let before = state::record_bytes(&root)?;
    let old = match state::read_state(&root)? {
        State::Foreign(_) => return Err(Fail("foreign_install")),
        State::NotInstalled => return Err(Fail("not_installed")),
        State::Invalid(_) => return Err(Fail("install_invalid")),
        State::Installed(rec) => rec,
    };
    if old.version == id {
        return if pins_match(&old, o.manifest, &sel) {
            Ok(Done::AlreadyUpToDate(old.version))
        } else {
            Err(Fail("pins_changed_same_id"))
        };
    }
    io.say(&consent_text(o, &sel));
    io.say(&format!(
        "Installed: {}. This build carries: {id}. If the update fails, the installed version keeps working. Your browser profile and sign-ins are kept.",
        old.version
    ));
    match ask(&format!("Update to {id}? [y/N] ")) {
        Some(true) => {}
        Some(false) => return Err(Fail("declined")),
        None => return Err(Fail("confirmation_required")),
    }
    let facts = run_preflight(o, &sel, io)?;
    if foreign_data(&root)? {
        return Err(Fail("foreign_data"));
    }
    state::run_pending_cleanup(&root)?;
    clear_target(&root, id, Some(&old.version))?;

    let mut guard = Guard::new(&root);
    let staged = build(o, &sel, &root, io, &facts, &mut guard)?;
    ensure_data_dirs(&root, &mut guard)?;
    if state::record_bytes(&root)? != before {
        return Err(Fail("record_changed"));
    }
    rustix::fs::renameat_with(
        root.fd(),
        staged.name.as_str(),
        root.fd(),
        id,
        rustix::fs::RenameFlags::NOREPLACE,
    )
    .map_err(|_| Fail("commit_collision"))?;
    guard.staging = None;
    guard.new_version = Some(id.to_string());
    after_rename(&root);
    let rec = new_record(o.manifest, &sel, Some(old.version.clone()))?;
    // The record is replaced only if it still holds the bytes read under the lock at the start.
    let expected = before.as_deref().ok_or(Fail("record_changed"))?;
    state::write_record_cas(
        root.fd(),
        state::RECORD_NAME,
        rec.to_json().as_bytes(),
        expected,
    )?;
    guard.armed = false;
    // The old version stays until `pending-cleanup.json` is acted on. A failure to write it leaves
    // the old directory in place, which `status` and `remove` report.
    // `pending-cleanup.json` is written only when no such entry exists (`NOREPLACE`). A record
    // that is already there, ours or not, is never replaced or dropped: it is reported instead.
    if state::write_record(
        root.fd(),
        state::PENDING_NAME,
        state::pending_json(&old.version).as_bytes(),
    )
    .is_err()
    {
        io.say(&format!(
            "left in place: {} (the previous version; its cleanup record could not be written: {} already exists or the write failed)",
            old.version,
            state::PENDING_NAME
        ));
    }
    Ok(Done::Updated {
        from: old.version,
        to: id.to_string(),
    })
}

// ---- remove ---------------------------------------------------------------------------------

pub struct Removal {
    pub report: Report,
    pub root: PathBuf,
}

/// `Ok(None)` when there is no root at all.
pub fn remove(o: &Opts<'_>) -> R<Option<Removal>> {
    let Some(root) = Root::open(&o.base, false)? else {
        return Ok(None);
    };
    let _lock = Lock::acquire(&root, o.lock_wait)?;
    let report = state::remove_all(&root)?;
    Ok(Some(Removal {
        report,
        root: root.display_path().to_path_buf(),
    }))
}

// ---- status ---------------------------------------------------------------------------------

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    pub state: &'static str,
    pub manifest_id: String,
    pub installed_id: Option<String>,
    pub previous: Option<String>,
    pub platform: String,
    pub update_available: Option<bool>,
    pub install_path: String,
    pub chromium_revision: Option<String>,
    pub pins_match: Option<bool>,
    pub pending_cleanup: Option<String>,
}

pub fn status(o: &Opts<'_>) -> R<Status> {
    let sel = selection(o)?;
    let path = o.base.join("oab-computer").join("playwright");
    let mut s = Status {
        state: "not_installed",
        manifest_id: o.manifest.id.clone(),
        installed_id: None,
        previous: None,
        platform: sel.platform.as_str().to_string(),
        update_available: None,
        install_path: consent::display_path(&path, o.home.as_deref()),
        chromium_revision: None,
        pins_match: None,
        pending_cleanup: None,
    };
    let Some(root) = Root::open(&o.base, false)? else {
        return Ok(s);
    };
    let st = state::read_state(&root)?;
    s.state = st.name();
    s.pending_cleanup = state::pending_previous(&root);
    if let State::Installed(rec) | State::Invalid(rec) = st {
        s.update_available = Some(rec.version != o.manifest.id);
        s.pins_match = Some(pins_match(&rec, o.manifest, &sel));
        s.chromium_revision = Some(rec.chromium_revision);
        s.previous = rec.previous;
        s.installed_id = Some(rec.version);
    }
    Ok(s)
}

fn jstr(v: &Option<String>) -> Value {
    v.clone().map(Value::String).unwrap_or(Value::Null)
}

fn jbool(v: Option<bool>) -> Value {
    v.map(Value::Bool).unwrap_or(Value::Null)
}

impl Status {
    /// Exactly these keys, in this order; no URL, token or page data can appear.
    pub fn to_json(&self) -> String {
        let mut m = serde_json::Map::new();
        m.insert("state".into(), self.state.into());
        m.insert("manifest_id".into(), self.manifest_id.clone().into());
        m.insert("installed_id".into(), jstr(&self.installed_id));
        m.insert("previous".into(), jstr(&self.previous));
        m.insert("platform".into(), self.platform.clone().into());
        m.insert("update_available".into(), jbool(self.update_available));
        m.insert("install_path".into(), self.install_path.clone().into());
        m.insert("chromium_revision".into(), jstr(&self.chromium_revision));
        m.insert("pins_match".into(), jbool(self.pins_match));
        m.insert("pending_cleanup".into(), jstr(&self.pending_cleanup));
        Value::Object(m).to_string()
    }

    pub fn lines(&self) -> Vec<String> {
        let opt = |v: &Option<String>| v.clone().unwrap_or_else(|| "-".into());
        let ob = |v: Option<bool>| v.map(|b| b.to_string()).unwrap_or_else(|| "-".into());
        vec![
            format!("state: {}", self.state),
            format!("manifest_id: {}", self.manifest_id),
            format!("installed_id: {}", opt(&self.installed_id)),
            format!("previous: {}", opt(&self.previous)),
            format!("platform: {}", self.platform),
            format!("update_available: {}", ob(self.update_available)),
            format!("install_path: {}", self.install_path),
            format!("chromium_revision: {}", opt(&self.chromium_revision)),
            format!("pins_match: {}", ob(self.pins_match)),
            format!("pending_cleanup: {}", opt(&self.pending_cleanup)),
        ]
    }
}

#[cfg(test)]
#[path = "install_tests.rs"]
pub(crate) mod tests;
