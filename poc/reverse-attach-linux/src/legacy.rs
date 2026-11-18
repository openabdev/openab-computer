//! The legacy listing of `browser status` (R6.4, D10, D9; L5): what the external Playwright setup of
//! 0.12.0 and earlier left behind. Read-only by construction: `lstat`, `read_dir` and one bounded
//! read of a drop-in file, never a write, a move, a delete, a `systemctl` call or a symlink
//! followed. Three fixed-vocabulary fields, each `none` when nothing is there:
//!
//! - `legacy_units`: a comma list of the fixed names below (a unit file under
//!   `~/.config/systemd/user/`, or `drop-in:<dir>` for a drop-in directory with a `*.conf` that has a
//!   `MCP_UPSTREAM` line). The content of a drop-in and the URL in it are never reported.
//! - `legacy`: a comma list of `<path>:<size>` for the fixed paths below, `~` for the home
//!   directory. The old profile is marked `:holds_cookies` (D9). A symlink is reported as
//!   `:symlink` and not followed; a size that could not be taken (a permission error, or a tree
//!   past the walk caps) is `:size_unknown`.
//! - `legacy_listener`: `8794` when something listens on the old unit's TCP port (any owner: this is
//!   the unauthenticated port of the old unit, not the managed tree), `none`, or `unknown` when the
//!   tables cannot be read.
//!
//! No URL, token, host name, file content or page data can appear. `unknown` is the answer when the
//! home directory is not known, never `none`.

use std::fs;
use std::io::Read;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use crate::procnet::{parse_inet, Source};

/// Unit files looked for under `~/.config/systemd/user/`, in report order.
pub const UNIT_FILES: [&str; 2] = ["oab-pw-mcp.service", "oab-computer-pw-mcp.service"];
/// Drop-in directories of the daemon units that may carry `MCP_UPSTREAM`.
pub const DROPIN_DIRS: [&str; 2] = ["oab-computer.service.d", "oab-instance-mcp.service.d"];
/// The old unit's port.
pub const LEGACY_PORT: u16 = 8794;

/// `(path below the home directory, holds cookies)`, in report order.
pub const PATHS: [(&str, bool); 7] = [
    (".local/oab-computer/pw-mcp", false),
    (".local/oab-computer/pw-profile", true),
    (".local/oab-computer/pw-output", false),
    (".local/oab-computer/pw-config.json", false),
    (".local/oab-computer/pw-mcp.sh", false),
    (".local/oab-instance-mcp/pw-mcp", false),
    (".cache/ms-playwright", false),
];

/// Walk caps: entries visited and directory depth.
pub const MAX_ENTRIES: usize = 200_000;
pub const MAX_DEPTH: usize = 64;
/// A drop-in is read up to this many bytes.
const DROPIN_CAP: u64 = 64 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Legacy {
    pub units: String,
    pub paths: String,
    pub listener: String,
}

impl Legacy {
    #[cfg(test)]
    pub fn none() -> Legacy {
        Legacy {
            units: "none".into(),
            paths: "none".into(),
            listener: "none".into(),
        }
    }

    /// Something real was found (`unknown` is not a finding).
    pub fn present(&self) -> bool {
        [&self.units, &self.paths, &self.listener]
            .iter()
            .any(|v| v.as_str() != "none" && v.as_str() != "unknown")
    }
}

/// The three fields. `home` is the user's home directory (`None`: unknown, so `units` and `paths` are
/// `unknown`; the listener is still probed). `src` is the `/proc/net` reader that `listeners` uses.
pub fn gather(home: Option<&Path>, src: &dyn Source) -> Legacy {
    let Some(home) = home.filter(|h| !h.as_os_str().is_empty()) else {
        return Legacy {
            units: "unknown".into(),
            paths: "unknown".into(),
            listener: listener(src),
        };
    };
    Legacy {
        units: units(home),
        paths: paths(home),
        listener: listener(src),
    }
}

fn join_or_none(v: Vec<String>) -> String {
    if v.is_empty() {
        "none".into()
    } else {
        v.join(",")
    }
}

/// `Some(true)` present (a link counts), `Some(false)` absent, `None` could not tell.
fn exists(p: &Path) -> Option<bool> {
    match fs::symlink_metadata(p) {
        Ok(_) => Some(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Some(false),
        // A path component that is not a directory also means "not there".
        Err(e) if e.raw_os_error() == Some(20) => Some(false),
        Err(_) => None,
    }
}

fn units(home: &Path) -> String {
    let dir = home.join(".config/systemd/user");
    let mut found = Vec::new();
    for name in UNIT_FILES {
        match exists(&dir.join(name)) {
            Some(true) => found.push(name.to_string()),
            Some(false) => {}
            None => return "unknown".into(),
        }
    }
    for name in DROPIN_DIRS {
        match dropin_has_upstream(&dir.join(name)) {
            Some(true) => found.push(format!("drop-in:{name}")),
            Some(false) => {}
            None => return "unknown".into(),
        }
    }
    join_or_none(found)
}

/// Does a `*.conf` in the drop-in directory `d` hold an active `Environment=MCP_UPSTREAM=` assignment? `Some(false)` when the
/// directory is absent or is a symlink (not followed); `None` when it cannot be read.
fn dropin_has_upstream(d: &Path) -> Option<bool> {
    let meta = match fs::symlink_metadata(d) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Some(false),
        Err(e) if e.raw_os_error() == Some(20) => return Some(false),
        Err(_) => return None,
    };
    if !meta.is_dir() {
        return Some(false);
    }
    let rd = fs::read_dir(d).ok()?;
    let mut names: Vec<_> = rd.flatten().map(|e| e.path()).collect();
    names.sort();
    for p in names {
        if p.extension().and_then(|e| e.to_str()) != Some("conf") {
            continue;
        }
        // Regular files only: a link is not followed.
        match fs::symlink_metadata(&p) {
            Ok(m) if m.is_file() => {}
            _ => continue,
        }
        let mut text = String::new();
        // `O_NOFOLLOW | O_NONBLOCK`: a file swapped for a link or a FIFO after the `lstat` is not read.
        let flags = (rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::NONBLOCK).bits() as i32;
        let Ok(f) = fs::OpenOptions::new()
            .read(true)
            .custom_flags(flags)
            .open(&p)
        else {
            return None;
        };
        if f.take(DROPIN_CAP).read_to_string(&mut text).is_err() {
            // Not text: it cannot be a unit drop-in that sets the variable.
            continue;
        }
        if text.lines().any(sets_upstream) {
            return Some(true);
        }
    }
    Some(false)
}

/// Is this line an active `Environment=` assignment of `MCP_UPSTREAM`? A comment, `UnsetEnvironment=`,
/// another variable that merely contains the name, and other settings do not count. The cutover guide
/// uses the same rule (`grep -nE`), so the hint and the runbook agree.
fn sets_upstream(line: &str) -> bool {
    let Some(value) = line.trim_start().strip_prefix("Environment=") else {
        return false;
    };
    let value = value.split(['#', ';']).next().unwrap_or("");
    let mut from = 0;
    while let Some(i) = value[from..].find("MCP_UPSTREAM=") {
        let at = from + i;
        match value[..at].chars().next_back() {
            None | Some('"') => return true,
            Some(c) if c.is_whitespace() => return true,
            _ => {}
        }
        from = at + 1;
    }
    false
}

fn paths(home: &Path) -> String {
    let mut found = Vec::new();
    for (rel, cookies) in PATHS {
        let p = home.join(rel);
        let meta = match fs::symlink_metadata(&p) {
            Ok(m) => m,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound || e.raw_os_error() == Some(20) => {
                continue
            }
            Err(_) => {
                found.push(entry(home, &p, "size_unknown", cookies));
                continue;
            }
        };
        let size = if meta.file_type().is_symlink() {
            "symlink".to_string()
        } else if meta.is_dir() {
            match dir_size(&p) {
                Some(n) => format_size(n),
                None => "size_unknown".into(),
            }
        } else {
            format_size(meta.len())
        };
        found.push(entry(home, &p, &size, cookies));
    }
    join_or_none(found)
}

fn entry(home: &Path, p: &Path, size: &str, cookies: bool) -> String {
    let name = crate::consent::display_path(p, Some(home));
    if cookies {
        format!("{name}:{size}:holds_cookies")
    } else {
        format!("{name}:{size}")
    }
}

/// Sum of the apparent sizes below `root`, by `lstat`: a symlink counts as its own length and is
/// never entered, nothing is read. `None` past the entry or depth cap, or on any error.
fn dir_size(root: &Path) -> Option<u64> {
    dir_size_with(root, MAX_ENTRIES, MAX_DEPTH)
}

fn dir_size_with(root: &Path, max_entries: usize, max_depth: usize) -> Option<u64> {
    let mut total: u64 = 0;
    let mut seen = 0usize;
    let mut stack = vec![(root.to_path_buf(), 0usize)];
    while let Some((dir, depth)) = stack.pop() {
        if depth > max_depth {
            return None;
        }
        for e in fs::read_dir(&dir).ok()? {
            let e = e.ok()?;
            seen += 1;
            if seen > max_entries {
                return None;
            }
            let m = e.metadata().ok()?;
            total = total.saturating_add(m.len());
            if m.is_dir() {
                stack.push((e.path(), depth + 1));
            }
        }
    }
    Some(total)
}

/// A fixed unit per size class, rounded up: `B`, `KiB`, `MiB`, `GiB`.
pub fn format_size(n: u64) -> String {
    const K: u64 = 1024;
    if n < K {
        format!("{n} B")
    } else if n < K * K {
        format!("{} KiB", n.div_ceil(K))
    } else if n < K * K * K {
        format!("{} MiB", n.div_ceil(K * K))
    } else {
        format!("{} GiB", n.div_ceil(K * K * K))
    }
}

/// `8794` when a TCP socket listens on the old unit's port, whoever owns it.
fn listener(src: &dyn Source) -> String {
    let mut hit = false;
    for (name, v6, required) in [("tcp", false, true), ("tcp6", true, false)] {
        match src.table(name) {
            Ok(t) => {
                hit |= parse_inet(&t, v6)
                    .iter()
                    .any(|r| r.state == 0x0A && r.local.port() == LEGACY_PORT);
            }
            Err(_) if required => return "unknown".into(),
            Err(_) => {}
        }
    }
    if hit {
        LEGACY_PORT.to_string()
    } else {
        "none".into()
    }
}

#[cfg(test)]
#[path = "legacy_tests.rs"]
mod tests;
