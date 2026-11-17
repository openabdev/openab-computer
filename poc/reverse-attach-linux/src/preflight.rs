//! Host checks before and during an install (ADR linux-browser-tier D16, D7; R3.5, R3.6; L1b).
//!
//! `browser preflight` reports libc, the glibc floor, the user-namespace state, disk needed and
//! free, seat presence and every shared library the pinned binaries need that the loader cache does
//! not list, in one run. It never installs a package and never uses root: a root action is printed
//! as the exact command and the reason, and nothing here runs it.
//!
//! What the list means: the pinned `needed` lists and the ELF scan of the staged files cover
//! libraries linked at build time. Libraries a program loads at run time are not covered, so the
//! headless health check at install is the final test and this report never calls the host
//! sufficient.

use std::collections::BTreeSet;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use crate::elf::{self, ElfInfo};
use crate::manifest::{Manifest, PlatformId, Selection};

/// One `ldconfig -p` line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LdEntry {
    pub soname: String,
    pub desc: String,
    pub path: String,
}

/// Parses `ldconfig -p` output: `\tlibc.so.6 (libc6,AArch64, OS ABI: Linux 3.7.0) => /lib/...`.
pub fn parse_ldconfig(out: &str) -> Vec<LdEntry> {
    out.lines()
        .filter_map(|l| {
            let l = l.trim();
            let (head, path) = l.split_once(" => ")?;
            let (soname, rest) = head.split_once(" (")?;
            let desc = rest.strip_suffix(')')?;
            Some(LdEntry {
                soname: soname.trim().to_string(),
                desc: desc.to_string(),
                path: path.trim().to_string(),
            })
        })
        .collect()
}

/// The tag `ldconfig -p` prints for an architecture.
pub fn arch_tag(p: PlatformId) -> &'static str {
    match p {
        PlatformId::LinuxArm64 => "AArch64",
        _ => "x86-64",
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Libc {
    /// glibc, and its version when it could be read.
    Glibc(Option<(u32, u32)>),
    Musl,
}

/// musl when the running binary's interpreter is a musl loader, or (for a static binary with no
/// interpreter) a musl loader exists on the host and no glibc loader does.
pub fn detect_libc(interp: Option<&str>, ld: &[LdEntry], musl_loader_present: bool) -> Libc {
    if let Some(i) = interp {
        if i.contains("ld-musl") {
            return Libc::Musl;
        }
    } else if musl_loader_present && !ld.iter().any(|e| e.soname.starts_with("ld-linux")) {
        return Libc::Musl;
    }
    Libc::Glibc(None)
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Userns {
    /// `kernel.unprivileged_userns_clone`
    pub clone: Option<bool>,
    /// `user.max_user_namespaces`
    pub max: Option<u64>,
    /// `kernel.apparmor_restrict_unprivileged_userns`
    pub apparmor_restricted: Option<bool>,
}

impl Userns {
    pub fn disabled(&self) -> bool {
        self.clone == Some(false) || self.max == Some(0)
    }
}

/// Everything the evaluation looks at. `gather` fills it from the host; tests build it by hand.
#[derive(Clone, Debug)]
pub struct Facts {
    pub libc: Libc,
    /// `None` when `ldconfig -p` could not be run.
    pub ld: Option<Vec<LdEntry>>,
    pub os_release: String,
    pub userns: Userns,
    pub free_disk: Option<u64>,
    pub seat: bool,
    /// The data base directory (`$XDG_DATA_HOME` or `~/.local/share`). Names the install root in
    /// the AppArmor command.
    pub data_base: PathBuf,
}

/// Where the host facts come from. Tests point these at fixture files and a fake `ldconfig`.
pub struct Sources {
    pub ldconfig: Vec<PathBuf>,
    pub self_exe: PathBuf,
    pub os_release: PathBuf,
    pub userns_clone: PathBuf,
    pub max_userns: PathBuf,
    pub apparmor_userns: PathBuf,
    pub musl_loaders: Vec<PathBuf>,
}

impl Sources {
    pub fn system() -> Sources {
        Sources {
            ldconfig: ["/sbin/ldconfig", "/usr/sbin/ldconfig", "/usr/bin/ldconfig"]
                .iter()
                .map(PathBuf::from)
                .collect(),
            self_exe: PathBuf::from("/proc/self/exe"),
            os_release: PathBuf::from("/etc/os-release"),
            userns_clone: PathBuf::from("/proc/sys/kernel/unprivileged_userns_clone"),
            max_userns: PathBuf::from("/proc/sys/user/max_user_namespaces"),
            apparmor_userns: PathBuf::from(
                "/proc/sys/kernel/apparmor_restrict_unprivileged_userns",
            ),
            musl_loaders: ["/lib/ld-musl-x86_64.so.1", "/lib/ld-musl-aarch64.so.1"]
                .iter()
                .map(PathBuf::from)
                .collect(),
        }
    }
}

fn read_small(path: &Path, cap: u64) -> Option<String> {
    let mut s = String::new();
    std::fs::File::open(path)
        .ok()?
        .take(cap)
        .read_to_string(&mut s)
        .ok()?;
    Some(s)
}

/// How long `ldconfig -p` may run before it is killed and the check reports "not checked".
pub const LDCONFIG_DEADLINE: Duration = Duration::from_secs(10);

/// Runs the first `ldconfig` that exists with `-p`, with an empty environment, a bounded read and a
/// deadline. A run that does not end in time is killed and reaped, and gives `None`.
fn run_ldconfig(candidates: &[PathBuf]) -> Option<String> {
    run_ldconfig_within(candidates, LDCONFIG_DEADLINE)
}

fn run_ldconfig_within(candidates: &[PathBuf], deadline: Duration) -> Option<String> {
    let exe = candidates.iter().find(|p| p.is_file())?;
    let mut child = Command::new(exe)
        .arg("-p")
        .env_clear()
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut stdout = child.stdout.take()?;
    let (tx, rx) = mpsc::channel::<Option<String>>();
    std::thread::spawn(move || {
        let mut out = String::new();
        let ok = (&mut stdout).take(8 << 20).read_to_string(&mut out).is_ok();
        let _ = tx.send(ok.then_some(out));
    });
    let end = Instant::now() + deadline;
    let status = loop {
        match child.try_wait() {
            Ok(Some(st)) => break st,
            Ok(None) if Instant::now() < end => std::thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    };
    if !status.success() {
        return None;
    }
    // The child has ended, so its end of the pipe is closed unless it left a process holding it.
    rx.recv_timeout(Duration::from_secs(2)).ok().flatten()
}

/// `path` with every link resolved. A path that does not exist yet is resolved up to its nearest
/// existing ancestor and the rest is appended, so the AppArmor profile names the path the kernel
/// sees when the base (for example `~/.local/share`) is a symlink.
pub fn resolved_base(path: &Path) -> PathBuf {
    let mut rest: Vec<&std::ffi::OsStr> = Vec::new();
    let mut p = path;
    loop {
        if let Ok(c) = std::fs::canonicalize(p) {
            return rest.iter().rev().fold(c, |acc, n| acc.join(n));
        }
        match (p.parent(), p.file_name()) {
            (Some(parent), Some(name)) => {
                rest.push(name);
                p = parent;
            }
            _ => return path.to_path_buf(),
        }
    }
}

/// Free bytes on the file system holding `path`, or on its nearest existing ancestor.
pub fn free_disk(path: &Path) -> Option<u64> {
    let mut p = path;
    loop {
        if let Ok(v) = rustix::fs::statvfs(p) {
            return Some(v.f_bavail.saturating_mul(v.f_frsize));
        }
        p = p.parent()?;
    }
}

impl Facts {
    pub fn gather(src: &Sources, platform: PlatformId, disk_probe: &Path) -> Facts {
        let ld = run_ldconfig(&src.ldconfig).map(|o| parse_ldconfig(&o));
        let interp = elf::read_elf(&src.self_exe).ok().and_then(|i| i.interp);
        let musl_present = src.musl_loaders.iter().any(|p| p.exists());
        let mut libc = detect_libc(
            interp.as_deref(),
            ld.as_deref().unwrap_or(&[]),
            musl_present,
        );
        if let Libc::Glibc(ver) = &mut libc {
            let tag = arch_tag(platform);
            let libc_path = ld.as_deref().and_then(|l| {
                l.iter()
                    .find(|e| e.soname == "libc.so.6" && e.desc.contains(tag))
                    .map(|e| PathBuf::from(&e.path))
            });
            *ver = libc_path
                .and_then(|p| elf::read_elf(&p).ok())
                .and_then(|i: ElfInfo| i.glibc_def);
        }
        let flag = |p: &PathBuf| read_small(p, 16).map(|s| s.trim() != "0");
        Facts {
            libc,
            ld,
            os_release: read_small(&src.os_release, 16 * 1024).unwrap_or_default(),
            userns: Userns {
                clone: flag(&src.userns_clone),
                max: read_small(&src.max_userns, 32).and_then(|s| s.trim().parse().ok()),
                apparmor_restricted: flag(&src.apparmor_userns),
            },
            free_disk: free_disk(disk_probe),
            seat: crate::platform::linux::seat::wayland_socket().exists(),
            data_base: resolved_base(disk_probe),
        }
    }
}

/// `ID` and `ID_LIKE` of an os-release file, lowercased.
fn os_ids(os_release: &str) -> Vec<String> {
    let mut ids = Vec::new();
    for l in os_release.lines() {
        for key in ["ID=", "ID_LIKE="] {
            if let Some(v) = l.strip_prefix(key) {
                ids.extend(
                    v.trim_matches(|c| c == '"' || c == '\'')
                        .split_whitespace()
                        .map(str::to_lowercase),
                );
            }
        }
    }
    ids
}

fn is_debian_family(os_release: &str) -> bool {
    os_ids(os_release)
        .iter()
        .any(|i| i == "debian" || i == "ubuntu" || i == "raspbian")
}

/// `2.28` to `(2, 28)`.
pub fn parse_version(s: &str) -> Option<(u32, u32)> {
    let mut it = s.split('.');
    Some((it.next()?.parse().ok()?, it.next()?.parse().ok()?))
}

fn fmt_ver(v: (u32, u32)) -> String {
    format!("{}.{}", v.0, v.1)
}

/// A root action that is printed and never run.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RootAction {
    pub command: String,
    pub reason: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Report {
    pub lines: Vec<String>,
    pub blockers: Vec<String>,
    pub missing: Vec<String>,
    pub root_actions: Vec<RootAction>,
    /// One fixed class per blocker, in the same order: `musl`, `glibc_too_old`, `disk_full`,
    /// `libraries_missing`.
    pub blocker_classes: Vec<&'static str>,
}

impl Report {
    pub fn ok(&self) -> bool {
        self.blockers.is_empty()
    }
}

/// Soname present for the architecture in the loader cache?
fn in_cache(ld: &[LdEntry], tag: &str, soname: &str) -> bool {
    ld.iter()
        .any(|e| e.soname == soname && e.desc.contains(tag))
}

/// The libraries in `needed` that the loader cache does not list, sorted, once each.
pub fn missing_libraries(ld: &[LdEntry], tag: &str, needed: &[&str]) -> Vec<String> {
    let set: BTreeSet<&str> = needed.iter().copied().collect();
    set.into_iter()
        .filter(|s| !in_cache(ld, tag, s))
        .map(str::to_string)
        .collect()
}

fn mb(bytes: u64) -> u64 {
    bytes.div_ceil(1_000_000)
}

/// Prefix of the AppArmor profile name and file. The full name carries a short hash of the install
/// path (`apparmor_name`), so two users on one host get two profiles and one never replaces the other.
pub const APPARMOR_PROFILE: &str = "oab-computer-chromium";

/// `oab-computer-chromium-<8 hex digits of FNV-1a over the install path>`.
pub fn apparmor_name(root: &str) -> String {
    let mut h: u32 = 0x811c_9dc5;
    for b in root.bytes() {
        h = (h ^ u32::from(b)).wrapping_mul(0x0100_0193);
    }
    format!("{APPARMOR_PROFILE}-{h:08x}")
}

/// The profile text for the installing user's own data path. It covers every version directory
/// under that path, so one load serves `install` and every later `update`. `None` when the path
/// holds a character that is unsafe in a profile or in the shell command.
pub fn apparmor_profile(data_base: &Path) -> Option<Vec<String>> {
    let root = data_base.join("oab-computer/playwright");
    let p = root.to_str()?;
    let simple = p.starts_with('/')
        && !p.contains("//")
        && p.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'/' | b'_' | b'.' | b'-'));
    simple.then(|| {
        vec![
            "abi <abi/4.0>,".to_string(),
            "include <tunables/global>".to_string(),
            format!("profile {} {p}/*/chromium/**/chrome flags=(unconfined) {{", apparmor_name(p)),
            "  userns,".to_string(),
            "}".to_string(),
        ]
    })
}

/// The exact command that loads the profile. Printed, never run.
pub fn apparmor_action(data_base: &Path) -> Option<RootAction> {
    let lines = apparmor_profile(data_base)?;
    let args: Vec<String> = lines.iter().map(|l| format!("'{l}'")).collect();
    let root = data_base.join("oab-computer/playwright");
    let file = format!("/etc/apparmor.d/{}", apparmor_name(root.to_str()?));
    Some(RootAction {
        command: format!(
            "printf '%s\\n' {} | sudo tee {file} >/dev/null && sudo apparmor_parser -r {file}",
            args.join(" ")
        ),
        reason: "kernel.apparmor_restrict_unprivileged_userns is 1, so Chromium cannot create its sandbox; this profile allows user namespaces only for the Chromium under your own install path, and it covers every version directory, so it also serves later updates"
            .into(),
    })
}

/// `needed_disk` is the figure the install needs free (`install::disk_needed`).
pub fn evaluate(m: &Manifest, sel: &Selection<'_>, f: &Facts, needed_disk: u64) -> Report {
    let _ = m;
    let mut r = Report::default();
    let tag = arch_tag(sel.platform);

    // libc and the floor
    let floor = [&sel.node.min_glibc, &sel.chromium.min_glibc]
        .iter()
        .filter_map(|v| v.as_deref().and_then(parse_version))
        .max();
    match &f.libc {
        Libc::Musl => {
            r.lines.push("libc: musl".into());
            r.blocker_classes.push("musl");
            r.blockers.push(
                "this host uses musl libc; the managed browser needs glibc (Debian, Ubuntu or Raspberry Pi OS)"
                    .into(),
            );
        }
        Libc::Glibc(ver) => {
            match ver {
                Some(v) => r.lines.push(format!("libc: glibc {}", fmt_ver(*v))),
                None => r.lines.push("libc: glibc (version not readable)".into()),
            }
            if let Some(fl) = floor {
                match ver {
                    Some(v) if *v >= fl => {
                        r.lines.push(format!("glibc floor: {} (ok)", fmt_ver(fl)));
                    }
                    Some(v) => {
                        r.lines.push(format!(
                            "glibc floor: {} (host {} is too old)",
                            fmt_ver(fl),
                            fmt_ver(*v)
                        ));
                        r.blocker_classes.push("glibc_too_old");
                        r.blockers.push(format!(
                            "glibc {} is older than the {} these binaries need",
                            fmt_ver(*v),
                            fmt_ver(fl)
                        ));
                    }
                    None => r.lines.push(format!(
                        "glibc floor: {} (host version unknown, the health check decides)",
                        fmt_ver(fl)
                    )),
                }
            }
        }
    }

    // user namespaces
    let ns = if f.userns.disabled() {
        "disabled by the kernel settings; Chromium will probably refuse to start"
    } else if f.userns.clone.is_none() && f.userns.max.is_none() {
        "unknown (settings not readable)"
    } else {
        "available"
    };
    r.lines.push(format!("user namespaces: {ns}"));
    match f.userns.apparmor_restricted {
        Some(true) => {
            r.lines
                .push("apparmor user namespace restriction: on".into());
            match apparmor_action(&f.data_base) {
                Some(a) => r.root_actions.push(a),
                None => r.lines.push(
                    "apparmor: the install path has characters this tool will not write into a profile; write a profile that allows `userns` for the installed Chromium by hand"
                        .into(),
                ),
            }
        }
        Some(false) => r
            .lines
            .push("apparmor user namespace restriction: off".into()),
        None => r
            .lines
            .push("apparmor user namespace restriction: not present".into()),
    }

    // disk
    match f.free_disk {
        Some(free) => {
            let ok = free >= needed_disk;
            r.lines.push(format!(
                "disk: needs about {} MB, {} MB free ({})",
                mb(needed_disk),
                free / 1_000_000,
                if ok { "ok" } else { "not enough" }
            ));
            if !ok {
                r.blocker_classes.push("disk_full");
                r.blockers.push(format!(
                    "not enough free disk: needs about {} MB, {} MB free",
                    mb(needed_disk),
                    free / 1_000_000
                ));
            }
        }
        None => r.lines.push(format!(
            "disk: needs about {} MB, free space unknown",
            mb(needed_disk)
        )),
    }

    r.lines.push(format!(
        "seat: {}",
        if f.seat {
            "present (a Wayland socket exists)"
        } else {
            "absent (headless)"
        }
    ));

    // libraries
    match &f.ld {
        Some(ld) => {
            let needed: Vec<&str> = [sel.node, sel.chromium]
                .iter()
                .flat_map(|a| a.needed.iter().flatten().map(String::as_str))
                .collect();
            r.missing = missing_libraries(ld, tag, &needed);
            if r.missing.is_empty() {
                r.lines
                    .push("missing libraries: none of the build-time libraries is missing".into());
            } else {
                r.lines.push(format!(
                    "missing libraries ({}): {}",
                    r.missing.len(),
                    r.missing.join(", ")
                ));
                r.blocker_classes.push("libraries_missing");
                r.blockers
                    .push(format!("{} shared libraries are missing", r.missing.len()));
            }
        }
        None => r.lines.push(
            "missing libraries: not checked (ldconfig -p could not be run); the health check at install decides"
                .into(),
        ),
    }
    if matches!(f.libc, Libc::Glibc(_)) && is_debian_family(&f.os_release) && !r.missing.is_empty()
    {
        let pkgs: BTreeSet<&str> = [sel.node, sel.chromium]
            .iter()
            .flat_map(|a| a.package_hints_apt.iter().flatten().map(String::as_str))
            .collect();
        r.root_actions.push(RootAction {
            command: format!(
                "sudo apt-get install -y {}",
                pkgs.into_iter().collect::<Vec<_>>().join(" ")
            ),
            reason: "package names for the libraries this build links against; packages already installed are skipped"
                .into(),
        });
    } else if !r.missing.is_empty() {
        r.lines.push(
            "package hints exist for Debian-family hosts only; install the libraries above with your package manager"
                .into(),
        );
    }
    if !matches!(f.libc, Libc::Musl) && !is_debian_family(&f.os_release) {
        r.lines
            .push("distribution: not Debian-family; the checks are best effort".into());
    }
    r.lines.push(
        "note: this list covers libraries linked at build time, not libraries loaded at run time; the headless health check at install is the final test"
            .into(),
    );
    r
}

/// Prints a report the way `browser preflight` and `browser install` show it.
pub fn render(r: &Report) -> String {
    let mut out = String::new();
    for l in &r.lines {
        out.push_str(l);
        out.push('\n');
    }
    for a in &r.root_actions {
        out.push_str(&format!(
            "needs root (not run by this tool): {} ({})\n",
            a.command, a.reason
        ));
    }
    if r.ok() {
        out.push_str("preflight: ok\n");
    } else {
        for b in &r.blockers {
            out.push_str(&format!("preflight: blocked: {b}\n"));
        }
    }
    out
}

// ---- staged-file scan -----------------------------------------------------------------------

/// Result of reading the ELF files of an extracted tree.
#[derive(Debug, Default)]
pub struct Scan {
    pub files: usize,
    /// Needed libraries that neither the loader cache nor the scanned trees provide.
    pub missing: Vec<String>,
    pub glibc_need: Option<(u32, u32)>,
}

const SCAN_MAX_FILES: usize = 20_000;
const SCAN_MAX_DEPTH: usize = 32;

/// Reads the ELF files under `roots` (regular files only, links are skipped) and reports the needed
/// libraries nothing provides. A needed name provided by a file of the same name inside the scanned
/// trees counts as present.
pub fn scan_trees(roots: &[&Path], ld: &[LdEntry], tag: &str) -> Scan {
    let mut provided: BTreeSet<String> = BTreeSet::new();
    let mut elfs: Vec<ElfInfo> = Vec::new();
    let mut scan = Scan::default();
    let mut stack: Vec<(PathBuf, usize)> = roots.iter().map(|r| (r.to_path_buf(), 0)).collect();
    while let Some((dir, depth)) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&dir) else {
            continue;
        };
        for e in rd.flatten() {
            let Ok(md) = std::fs::symlink_metadata(e.path()) else {
                continue;
            };
            if md.is_dir() {
                if depth < SCAN_MAX_DEPTH {
                    stack.push((e.path(), depth + 1));
                }
                continue;
            }
            if !md.is_file() {
                continue;
            }
            scan.files += 1;
            if scan.files > SCAN_MAX_FILES {
                return scan;
            }
            if let Some(n) = e.file_name().to_str() {
                provided.insert(n.to_string());
            }
            if let Ok(info) = elf::read_elf(&e.path()) {
                scan.glibc_need = scan.glibc_need.max(info.glibc_need);
                elfs.push(info);
            }
        }
    }
    let mut missing: BTreeSet<String> = BTreeSet::new();
    for i in &elfs {
        for n in &i.needed {
            if !provided.contains(n) && !in_cache(ld, tag, n) {
                missing.insert(n.clone());
            }
        }
    }
    scan.missing = missing.into_iter().collect();
    scan
}

#[cfg(test)]
#[path = "preflight_tests.rs"]
mod tests;
