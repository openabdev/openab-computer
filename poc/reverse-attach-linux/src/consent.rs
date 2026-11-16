//! The consent text of `browser plan` and the figures behind it (R2.3; L1b). Every number comes from
//! the embedded manifest. The word "safe" never appears: the text says what is checked, not what is
//! guaranteed. `install-linux.sh` (L3) shows exactly this text, so it lives in one function.

use std::path::Path;

use crate::manifest::{Manifest, Selection};

/// Node, Chromium and the npm packages, in bytes.
pub fn download_bytes(m: &Manifest, sel: &Selection<'_>) -> u64 {
    (sel.node.size.max(0) + sel.chromium.size.max(0) + m.mcp.npm_download_bytes.max(0)) as u64
}

/// Space the extracted install takes: downloads, both expanded trees and the installed npm tree.
pub fn disk_bytes(m: &Manifest, sel: &Selection<'_>) -> u64 {
    download_bytes(m, sel)
        + (sel.node.expanded_bytes.max(0)
            + sel.chromium.expanded_bytes.max(0)
            + m.mcp.npm_installed_bytes.max(0)) as u64
}

/// Free space an install needs: the larger of the factor times the download and the disk figure.
pub fn disk_needed(m: &Manifest, sel: &Selection<'_>) -> u64 {
    disk_bytes(m, sel)
        .max((m.free_disk_factor.max(0) as u64).saturating_mul(download_bytes(m, sel)))
}

/// "about N MB", decimal megabytes rounded up so the figure is never lower than the download.
pub fn megabytes(bytes: u64) -> String {
    format!("{} MB", bytes.div_ceil(1_000_000))
}

/// The install path with the home directory shown as `~`.
pub fn display_path(path: &Path, home: Option<&Path>) -> String {
    if let Some(h) = home.filter(|h| !h.as_os_str().is_empty()) {
        if path == h {
            return "~".into();
        }
        if let Ok(rest) = path.strip_prefix(h) {
            return format!("~/{}", rest.display());
        }
    }
    path.display().to_string()
}

/// "a", "a and b", "a, b and c".
fn join_names(names: &[String]) -> String {
    match names.len() {
        0 => String::new(),
        1 => names[0].clone(),
        n => format!("{} and {}", names[..n - 1].join(", "), names[n - 1]),
    }
}

/// The text `browser plan` prints and the installer script shows before it asks.
pub fn text(m: &Manifest, sel: &Selection<'_>, install_path: &Path, home: Option<&Path>) -> String {
    format!(
        "Downloads about {dl}: Node.js {node}, the Playwright MCP server and a separate Chromium {chromium}, from {hosts}. \
Installs to {path}. \
Each download is checked against sizes and digests built into this program: SHA-256 for Node.js and Chromium, the lockfile integrity values for the npm packages. \
It uses its own browser profile, not your Chrome or Firefox. \
Needs an internet connection and about {disk} of free disk.\n\
Pinned set: {id} ({platform}).",
        dl = megabytes(download_bytes(m, sel)),
        node = m.node.version,
        chromium = m.chromium.browser_version,
        hosts = join_names(&m.hosts),
        path = display_path(install_path, home),
        disk = megabytes(disk_needed(m, sel)),
        id = m.id,
        platform = sel.platform.as_str(),
    )
}

/// The text for `--from-dir`: nothing is downloaded, and it says so.
pub fn text_offline(
    m: &Manifest,
    sel: &Selection<'_>,
    install_path: &Path,
    home: Option<&Path>,
    dir: &Path,
) -> String {
    format!(
        "Installs Node.js {node}, the Playwright MCP server and a separate Chromium {chromium} from the files in {dir}. \
Nothing is downloaded and the network is not used. \
Each file is checked against sizes and digests built into this program: SHA-256 for Node.js and Chromium, the lockfile integrity values for the npm packages. \
Installs to {path}. \
It uses its own browser profile, not your Chrome or Firefox. \
Needs about {disk} of free disk.\n\
Pinned set: {id} ({platform}).",
        node = m.node.version,
        chromium = m.chromium.browser_version,
        dir = dir.display(),
        path = display_path(install_path, home),
        disk = megabytes(disk_needed(m, sel)),
        id = m.id,
        platform = sel.platform.as_str(),
    )
}

#[cfg(test)]
#[path = "consent_tests.rs"]
mod tests;
