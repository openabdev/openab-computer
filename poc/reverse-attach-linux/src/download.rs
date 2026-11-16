//! Bounded synchronous HTTPS download for the managed Playwright tier (ADR linux-browser-tier D3,
//! R2.3; L1a). Counterpart of the Swift `ArtifactDownloader`.
//!
//! - `https` only, to hosts on the manifest's allowlist. Redirects are followed here, one request
//!   per hop, and every hop (the first request included) goes through `DownloadPolicy::permits`.
//!   A downgrade, an off-list host or an unparsable `Location` ends the download.
//! - The declared `Content-Length` and the bytes actually received are both capped at the pinned
//!   size; connect, per-read and total timeouts apply.
//! - SHA-256 is computed while streaming into a private `.part` file (mode 0600, created `O_EXCL`
//!   below an installer-owned directory fd). Size and digest are compared to the pin before the
//!   file gets its final name; only then does a `VerifiedArtifact` exist, and that is the only
//!   thing `extract` accepts. Every failure removes the `.part` file.
//! - Proxy variables are ignored, no cookies and no credentials are sent, and nothing is logged:
//!   errors are fixed classes with no URL, host or body text.

use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::OwnedFd;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use rustix::fs::{AtFlags, Mode, OFlags};
use sha2::{Digest, Sha256};

use crate::manifest::{hex, parse_url, Artifact, Manifest, ParsedUrl};

/// Why a download failed. `Display` and `Debug` print the class name only.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DownloadError {
    /// A URL (first or redirect target) the policy does not allow.
    Policy,
    /// A redirect that could not be followed: no `Location`, a loop, too many hops.
    Redirect,
    /// A non-200 answer.
    Status,
    /// A `Content-Encoding` other than identity.
    Encoding,
    /// More bytes than the pin allows (declared or received).
    TooLarge,
    /// Fewer bytes than the pin says, or a declared length that is not the pinned size.
    SizeMismatch,
    DigestMismatch,
    Timeout,
    Network,
    Io,
}

impl DownloadError {
    pub fn as_str(self) -> &'static str {
        match self {
            DownloadError::Policy => "policy",
            DownloadError::Redirect => "redirect",
            DownloadError::Status => "status",
            DownloadError::Encoding => "encoding",
            DownloadError::TooLarge => "too_large",
            DownloadError::SizeMismatch => "size_mismatch",
            DownloadError::DigestMismatch => "digest_mismatch",
            DownloadError::Timeout => "timeout",
            DownloadError::Network => "network",
            DownloadError::Io => "io",
        }
    }
}

impl std::fmt::Display for DownloadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Which URLs the downloader may touch.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DownloadPolicy {
    allowed_hosts: Vec<String>,
    allow_loopback_http: bool,
}

impl DownloadPolicy {
    /// https only, hosts from the manifest.
    pub fn production(m: &Manifest) -> DownloadPolicy {
        DownloadPolicy {
            allowed_hosts: m.hosts.clone(),
            allow_loopback_http: false,
        }
    }

    /// Tests only: plain http to the literal `127.0.0.1` is allowed when the host is on the list.
    #[cfg(test)]
    pub fn for_tests(hosts: &[&str]) -> DownloadPolicy {
        DownloadPolicy {
            allowed_hosts: hosts.iter().map(|h| h.to_string()).collect(),
            allow_loopback_http: true,
        }
    }

    /// Same rules as the Swift `DownloadPolicy.permits`, with the strict URL splitter. An https
    /// URL may carry no port or 443 (stricter than Swift); a host must match exactly.
    pub fn permits(&self, url: &str) -> bool {
        parse_url(url).is_some_and(|u| self.permits_parsed(&u))
    }

    fn permits_parsed(&self, u: &ParsedUrl) -> bool {
        if u.has_dot_dot() || !self.allowed_hosts.contains(&u.host) {
            return false;
        }
        match u.scheme.as_str() {
            "https" => u.port.is_none() || u.port == Some(443),
            "http" => self.allow_loopback_http && u.host == "127.0.0.1",
            _ => false,
        }
    }
}

/// What a download must match.
pub struct Pin<'a> {
    pub url: &'a str,
    pub size: u64,
    pub sha256: &'a str,
}

impl<'a> Pin<'a> {
    pub fn from_artifact(a: &'a Artifact) -> Pin<'a> {
        Pin {
            url: &a.url,
            size: a.size.max(0) as u64,
            sha256: &a.sha256,
        }
    }
}

impl std::fmt::Debug for Pin<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Pin { .. }")
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub connect: Duration,
    pub read: Duration,
    pub total: Duration,
    pub max_redirects: u8,
}

impl Default for Limits {
    fn default() -> Limits {
        Limits {
            connect: Duration::from_secs(15),
            read: Duration::from_secs(30),
            total: Duration::from_secs(3600),
            max_redirects: 5,
        }
    }
}

/// A file whose size and SHA-256 matched a pin. Only `fetch` constructs one (tests can build one
/// for a file they made themselves), and `extract` takes nothing else.
#[derive(Debug)]
pub struct VerifiedArtifact {
    path: PathBuf,
    size: u64,
    sha256: [u8; 32],
}

impl VerifiedArtifact {
    pub fn path(&self) -> &Path {
        &self.path
    }
    pub fn size(&self) -> u64 {
        self.size
    }
    pub fn sha256_hex(&self) -> String {
        hex(&self.sha256)
    }

    /// Tests only: wraps a file the test wrote, without a download.
    #[cfg(test)]
    pub fn unchecked_for_tests(path: &Path) -> VerifiedArtifact {
        let size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
        VerifiedArtifact {
            path: path.to_path_buf(),
            size,
            sha256: [0; 32],
        }
    }
}

fn plain_file_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 200
        && !name.starts_with('.')
        && !name.contains(['/', '\0'])
        && name != ".."
}

/// The installer-owned directory, opened without following a link, and refused unless it is a
/// directory owned by us that nobody else can write to.
fn open_private_dir(dir: &Path) -> Result<OwnedFd, DownloadError> {
    let fd = rustix::fs::open(
        dir,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(|_| DownloadError::Io)?;
    let st = rustix::fs::fstat(&fd).map_err(|_| DownloadError::Io)?;
    if st.st_uid != rustix::process::geteuid().as_raw() || (st.st_mode as u32) & 0o022 != 0 {
        return Err(DownloadError::Io);
    }
    Ok(fd)
}

/// Removes the `.part` file unless the download finished.
struct PartGuard<'a> {
    dir: &'a OwnedFd,
    name: String,
    armed: bool,
}

impl Drop for PartGuard<'_> {
    fn drop(&mut self) {
        if self.armed {
            let _ = rustix::fs::unlinkat(self.dir, self.name.as_str(), AtFlags::empty());
        }
    }
}

fn agent(https_only: bool, limits: &Limits) -> ureq::Agent {
    let config = ureq::Agent::config_builder()
        .proxy(None)
        .https_only(https_only)
        .max_redirects(0)
        .max_redirects_will_error(false)
        .http_status_as_error(false)
        .user_agent("oab-computer-browser-install")
        .accept_encoding("identity")
        .timeout_connect(Some(limits.connect))
        .timeout_per_read(Some(limits.read))
        .timeout_global(Some(limits.total))
        .build();
    ureq::Agent::new_with_config(config)
}

fn map_ureq(e: &ureq::Error) -> DownloadError {
    match e {
        ureq::Error::Timeout(_) | ureq::Error::BodyStalled => DownloadError::Timeout,
        ureq::Error::Io(io) if io.kind() == std::io::ErrorKind::TimedOut => DownloadError::Timeout,
        ureq::Error::RequireHttpsOnly(_) => DownloadError::Policy,
        _ => DownloadError::Network,
    }
}

fn map_read(e: &std::io::Error) -> DownloadError {
    if let Some(u) = e.get_ref().and_then(|i| i.downcast_ref::<ureq::Error>()) {
        return map_ureq(u);
    }
    match e.kind() {
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => DownloadError::Timeout,
        std::io::ErrorKind::UnexpectedEof => DownloadError::SizeMismatch,
        _ => DownloadError::Network,
    }
}

/// Resolves a `Location` against the URL it came from. Only absolute, scheme-relative,
/// absolute-path and relative-path forms exist; the result is parsed and policy-checked by the
/// caller.
fn resolve_location(base: &ParsedUrl, loc: &str) -> String {
    if loc.contains("://") {
        loc.to_string()
    } else if let Some(rest) = loc.strip_prefix("//") {
        format!("{}://{rest}", base.scheme)
    } else if loc.starts_with('/') {
        format!(
            "{}://{}{}{loc}",
            base.scheme,
            base.host,
            base.port.map(|p| format!(":{p}")).unwrap_or_default()
        )
    } else {
        let dir = &base.path[..base.path.rfind('/').map_or(0, |i| i + 1)];
        format!(
            "{}://{}{}{dir}{loc}",
            base.scheme,
            base.host,
            base.port.map(|p| format!(":{p}")).unwrap_or_default()
        )
    }
}

/// The next URL to request after a redirect from `current`, or why not.
fn next_hop(
    policy: &DownloadPolicy,
    current: &ParsedUrl,
    location: Option<&str>,
) -> Result<String, DownloadError> {
    let loc = location
        .filter(|l| !l.is_empty() && l.len() <= 2048)
        .ok_or(DownloadError::Redirect)?;
    let next = parse_url(&resolve_location(current, loc)).ok_or(DownloadError::Policy)?;
    if current.scheme == "https" && next.scheme != "https" {
        return Err(DownloadError::Policy); // downgrade
    }
    if !policy.permits_parsed(&next) {
        return Err(DownloadError::Policy);
    }
    Ok(next.render())
}

/// Downloads `pin.url` into `dir/name`, checking size and SHA-256 against the pin first. `dir`
/// must be an installer-owned directory (owned by the effective user, no group or other write).
pub fn fetch(
    policy: &DownloadPolicy,
    pin: &Pin<'_>,
    dir: &Path,
    name: &str,
    limits: &Limits,
    progress: &mut dyn FnMut(u64),
) -> Result<VerifiedArtifact, DownloadError> {
    if !plain_file_name(name) {
        return Err(DownloadError::Io);
    }
    let mut url = parse_url(pin.url)
        .filter(|u| policy.permits_parsed(u))
        .ok_or(DownloadError::Policy)?;
    let dirfd = open_private_dir(dir)?;
    let part_name = format!(".{name}.part");
    let part_fd = rustix::fs::openat(
        &dirfd,
        part_name.as_str(),
        OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::from_raw_mode(0o600),
    )
    .map_err(|_| DownloadError::Io)?;
    let mut guard = PartGuard {
        dir: &dirfd,
        name: part_name.clone(),
        armed: true,
    };
    let mut part = File::from(part_fd);

    let started = Instant::now();
    let agent = agent(!policy.allow_loopback_http, limits);
    let mut hops = 0u8;
    let response = loop {
        // Every request, the first one included, was checked against the policy just before.
        let resp = agent.get(&url.render()).call().map_err(|e| map_ureq(&e))?;
        let status = resp.status().as_u16();
        if matches!(status, 301 | 302 | 303 | 307 | 308) {
            if hops >= limits.max_redirects {
                return Err(DownloadError::Redirect);
            }
            hops += 1;
            let loc = resp
                .headers()
                .get("location")
                .and_then(|v| v.to_str().ok())
                .map(str::to_string);
            let next = next_hop(policy, &url, loc.as_deref())?;
            url = parse_url(&next).ok_or(DownloadError::Policy)?;
            continue;
        }
        if status != 200 {
            return Err(DownloadError::Status);
        }
        break resp;
    };

    if let Some(enc) = response.headers().get("content-encoding") {
        let enc = enc.to_str().map_err(|_| DownloadError::Encoding)?.trim();
        if !enc.is_empty() && !enc.eq_ignore_ascii_case("identity") {
            return Err(DownloadError::Encoding);
        }
    }
    let chunked = response.headers().get("transfer-encoding").is_some();
    if let Some(len) = response
        .headers()
        .get("content-length")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.trim().parse::<u64>().ok())
    {
        if len > pin.size {
            return Err(DownloadError::TooLarge);
        }
        if len != pin.size && !chunked {
            return Err(DownloadError::SizeMismatch);
        }
    }

    let mut body = response.into_body().into_reader();
    let mut hasher = Sha256::new();
    let mut received: u64 = 0;
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        if started.elapsed() > limits.total {
            return Err(DownloadError::Timeout);
        }
        let n = match body.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => return Err(map_read(&e)),
        };
        received += n as u64;
        if received > pin.size {
            return Err(DownloadError::TooLarge);
        }
        hasher.update(&buf[..n]);
        part.write_all(&buf[..n]).map_err(|_| DownloadError::Io)?;
        progress(received);
    }
    drop(body);
    if received != pin.size {
        return Err(DownloadError::SizeMismatch);
    }
    let digest: [u8; 32] = hasher.finalize().into();
    if hex(&digest) != pin.sha256 {
        return Err(DownloadError::DigestMismatch);
    }
    // Verified. Only now does the file get its final name.
    part.sync_all().map_err(|_| DownloadError::Io)?;
    drop(part);
    rustix::fs::renameat(&dirfd, part_name.as_str(), &dirfd, name)
        .map_err(|_| DownloadError::Io)?;
    guard.armed = false;
    Ok(VerifiedArtifact {
        path: dir.join(name),
        size: received,
        sha256: digest,
    })
}

#[cfg(test)]
#[path = "download_tests.rs"]
mod tests;
