//! The pinned artifacts of the managed Playwright tier (ADR linux-browser-tier D1, D3; L1a).
//!
//! The data is `release/playwright-pins/pins.json` (schema 2), compiled into the binary. The
//! daemon never fetches pins. `Manifest::validate` is the Rust twin of the Swift
//! `PlaywrightManifest.validate`: both return the same problem names on the same input, and
//! `conformance/pins_vectors.json` (run by `manifest_conformance`) pins that.
//!
//! No `regex` or `url` crate: the patterns are small byte matchers and the URL splitter is strict
//! on purpose (see `parse_url`). Nothing here touches the network or the disk.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::OnceLock;

use serde_json::Value;
use sha2::{Digest, Sha256};

pub const SCHEMA_VERSION: i64 = 2;

pub const PINS_JSON: &str = include_str!("../../../release/playwright-pins/pins.json");
pub const PACKAGE_JSON: &str = include_str!("../../../release/playwright-pins/package.json");
pub const LOCKFILE_JSON: &str = include_str!("../../../release/playwright-pins/package-lock.json");

/// The four pinned platforms. The string form is the key in pins.json.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum PlatformId {
    DarwinArm64,
    DarwinX64,
    LinuxX64,
    LinuxArm64,
}

impl PlatformId {
    pub const ALL: [PlatformId; 4] = [
        PlatformId::DarwinArm64,
        PlatformId::DarwinX64,
        PlatformId::LinuxX64,
        PlatformId::LinuxArm64,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            PlatformId::DarwinArm64 => "darwin-arm64",
            PlatformId::DarwinX64 => "darwin-x64",
            PlatformId::LinuxX64 => "linux-x64",
            PlatformId::LinuxArm64 => "linux-arm64",
        }
    }

    /// Darwin ids parse (the shared pins carry them) but are not installable here.
    pub fn parse(s: &str) -> Option<PlatformId> {
        PlatformId::ALL.into_iter().find(|p| p.as_str() == s)
    }

    pub fn is_linux(self) -> bool {
        matches!(self, PlatformId::LinuxX64 | PlatformId::LinuxArm64)
    }

    /// `os` is `darwin` or `linux`; `arch` is `arm64`/`aarch64` or `x86_64`/`amd64`. Anything else
    /// is not a pinned platform. Same table as the Swift `PlatformID.select`; the vectors pin it.
    pub fn select(os: &str, arch: &str) -> Option<PlatformId> {
        let a = match arch {
            "arm64" | "aarch64" => "arm64",
            "x86_64" | "amd64" => "x64",
            _ => return None,
        };
        if os != "darwin" && os != "linux" {
            return None;
        }
        PlatformId::parse(&format!("{os}-{a}"))
    }

    pub fn host() -> Option<PlatformId> {
        PlatformId::select(std::env::consts::OS, std::env::consts::ARCH)
    }
}

/// A pin is not usable on this host.
#[derive(Debug, PartialEq, Eq)]
pub enum SelectError {
    /// The host is not one of the four pinned platforms.
    UnsupportedHost,
    /// A darwin pin: it parses, but this daemon installs Linux artifacts only.
    NotLinux,
    /// The manifest has no artifact for the platform (validation would have said so).
    Missing,
}

impl std::fmt::Display for SelectError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            SelectError::UnsupportedHost => "unsupported_host",
            SelectError::NotLinux => "not_linux",
            SelectError::Missing => "pin_missing",
        })
    }
}

/// The manifest could not be read at all (wrong JSON shape). Distinct from a validation problem.
#[derive(Debug, PartialEq, Eq)]
pub struct ManifestError(pub String);

impl std::fmt::Display for ManifestError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "manifest decode: {}", self.0)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Artifact {
    pub url: String,
    pub format: String,
    pub size: i64,
    pub sha256: String,
    pub strip_components: i64,
    pub expanded_bytes: i64,
    pub entry_count: i64,
    pub max_entry_bytes: i64,
    pub executable: Option<String>,
    pub source: Option<String>,
    pub min_glibc: Option<String>,
    pub needed: Option<Vec<String>>,
    pub package_hints_apt: Option<Vec<String>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Mcp {
    pub package_json_sha256: String,
    pub lockfile_sha256: String,
    pub npm_download_bytes: i64,
    /// Space `npm ci` leaves behind. Not a validated pin field here (the vectors do not carry it),
    /// so a manifest without it reads as 0.
    pub npm_installed_bytes: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Node {
    pub version: String,
    pub team_identifier: String,
    pub artifacts: BTreeMap<String, Artifact>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chromium {
    pub revision: String,
    pub browser_version: String,
    pub released_at: String,
    pub host: String,
    pub artifacts: BTreeMap<String, Artifact>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Manifest {
    pub schema: i64,
    pub id: String,
    pub mcp: Mcp,
    pub node: Node,
    pub chromium: Chromium,
    pub hosts: Vec<String>,
    pub stale_after_days: i64,
    pub free_disk_factor: i64,
}

/// Source name -> the one host its URLs may use.
const SOURCE_HOSTS: [(&str, &str); 2] = [
    ("chrome-for-testing", "storage.googleapis.com"),
    ("playwright-cdn", "cdn.playwright.dev"),
];
const CFT_BASE: &str = "https://storage.googleapis.com/chrome-for-testing-public";
const CDN_BASE: &str = "https://cdn.playwright.dev/dbazure/download/playwright/builds/chromium";

fn source_host(src: &str) -> Option<&'static str> {
    SOURCE_HOSTS
        .iter()
        .find(|(s, _)| *s == src)
        .map(|(_, h)| *h)
}

fn cft_dir(p: PlatformId) -> &'static str {
    match p {
        PlatformId::DarwinArm64 => "mac-arm64",
        PlatformId::DarwinX64 => "mac-x64",
        PlatformId::LinuxX64 => "linux64",
        PlatformId::LinuxArm64 => "linux-arm64",
    }
}

fn cdn_file(p: PlatformId) -> Option<&'static str> {
    match p {
        PlatformId::LinuxX64 => Some("chromium-linux.zip"),
        PlatformId::LinuxArm64 => Some("chromium-linux-arm64.zip"),
        _ => None,
    }
}

// ---- decoding ---------------------------------------------------------------------------

fn err<T>(what: &str) -> Result<T, ManifestError> {
    Err(ManifestError(what.to_string()))
}

fn get<'a>(v: &'a Value, k: &str) -> Result<&'a Value, ManifestError> {
    match v.get(k) {
        Some(x) => Ok(x),
        None => err(&format!("missing {k}")),
    }
}
fn string(v: &Value, k: &str) -> Result<String, ManifestError> {
    match get(v, k)?.as_str() {
        Some(s) => Ok(s.to_string()),
        None => err(&format!("{k} is not a string")),
    }
}
fn int(v: &Value, k: &str) -> Result<i64, ManifestError> {
    match get(v, k)?.as_i64() {
        Some(n) => Ok(n),
        None => err(&format!("{k} is not an integer")),
    }
}
fn opt_string(v: &Value, k: &str) -> Result<Option<String>, ManifestError> {
    match v.get(k) {
        None => Ok(None),
        Some(Value::String(s)) => Ok(Some(s.clone())),
        Some(_) => err(&format!("{k} is not a string")),
    }
}
fn string_list(v: &Value, k: &str) -> Result<Vec<String>, ManifestError> {
    let Some(a) = get(v, k)?.as_array() else {
        return err(&format!("{k} is not an array"));
    };
    a.iter()
        .map(|x| match x.as_str() {
            Some(s) => Ok(s.to_string()),
            None => err(&format!("{k} has a non-string item")),
        })
        .collect()
}
fn opt_string_list(v: &Value, k: &str) -> Result<Option<Vec<String>>, ManifestError> {
    if v.get(k).is_none() {
        return Ok(None);
    }
    string_list(v, k).map(Some)
}

fn decode_artifact(v: &Value) -> Result<Artifact, ManifestError> {
    let hints = match v.get("packageHints") {
        None => None,
        Some(h) => Some(string_list(h, "apt")?),
    };
    Ok(Artifact {
        url: string(v, "url")?,
        format: string(v, "format")?,
        size: int(v, "size")?,
        sha256: string(v, "sha256")?,
        strip_components: int(v, "stripComponents")?,
        expanded_bytes: int(v, "expandedBytes")?,
        entry_count: int(v, "entryCount")?,
        max_entry_bytes: int(v, "maxEntryBytes")?,
        executable: opt_string(v, "executable")?,
        source: opt_string(v, "source")?,
        min_glibc: opt_string(v, "minGlibc")?,
        needed: opt_string_list(v, "needed")?,
        package_hints_apt: hints,
    })
}

fn decode_artifacts(v: &Value) -> Result<BTreeMap<String, Artifact>, ManifestError> {
    let Some(o) = get(v, "artifacts")?.as_object() else {
        return err("artifacts is not an object");
    };
    o.iter()
        .map(|(k, a)| Ok((k.clone(), decode_artifact(a)?)))
        .collect()
}

// ---- patterns (hand-written; the Swift side uses the regex in each comment) -----------------

fn all(s: &str, f: impl Fn(u8) -> bool) -> bool {
    s.bytes().all(f)
}
fn lower_hex64(s: &str) -> bool {
    s.len() == 64 && all(s, |b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
/// `^[A-Za-z0-9][A-Za-z0-9._-]*$`, at most 128 bytes.
pub fn is_safe_id(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty()
        && b.len() <= 128
        && b[0].is_ascii_alphanumeric()
        && all(s, |c| {
            c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-')
        })
}
/// `^[A-Z0-9]{10}$`
fn team_id(s: &str) -> bool {
    s.len() == 10 && all(s, |c| c.is_ascii_uppercase() || c.is_ascii_digit())
}
/// `^[0-9]+\.[0-9]+(\.[0-9]+)?$`
fn glibc_version(s: &str) -> bool {
    let parts: Vec<&str> = s.split('.').collect();
    (parts.len() == 2 || parts.len() == 3)
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.bytes().all(|c| c.is_ascii_digit()))
}
/// `^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$`
fn soname(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty()
        && b.len() <= 128
        && b[0].is_ascii_alphanumeric()
        && all(s, |c| {
            c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'+' | b'-')
        })
}
/// `^[a-z0-9][a-z0-9+.-]{1,63}$`
fn apt_name(s: &str) -> bool {
    let b = s.as_bytes();
    let lower = |c: u8| c.is_ascii_lowercase() || c.is_ascii_digit();
    (2..=64).contains(&b.len())
        && lower(b[0])
        && all(s, |c| lower(c) || matches!(c, b'+' | b'.' | b'-'))
}
/// `^chrome-linux[A-Za-z0-9-]*/chrome$`
fn linux_chrome(s: &str) -> bool {
    let Some(rest) = s.strip_prefix("chrome-linux") else {
        return false;
    };
    let Some(mid) = rest.strip_suffix("/chrome") else {
        return false;
    };
    all(mid, |c| c.is_ascii_alphanumeric() || c == b'-')
}
fn sorted_unique(a: &[String]) -> bool {
    a.windows(2).all(|w| w[0] < w[1])
}

/// `YYYY-MM-DD` that is a real calendar day.
pub fn is_calendar_day(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
        return false;
    }
    let digits = |r: std::ops::Range<usize>| b[r].iter().all(u8::is_ascii_digit);
    if !(digits(0..4) && digits(5..7) && digits(8..10)) {
        return false;
    }
    let n = |r: std::ops::Range<usize>| s[r].parse::<u32>().unwrap_or(0);
    let (y, m, d) = (n(0..4), n(5..7), n(8..10));
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let dim = match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap => 29,
        2 => 28,
        _ => return false,
    };
    (1..=dim).contains(&d)
}

// ---- URLs -----------------------------------------------------------------------------------

/// A URL split the strict way. The download policy and the validator both use it, so they cannot
/// disagree about what a URL is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParsedUrl {
    pub scheme: String,
    pub host: String,
    pub port: Option<u16>,
    /// Starts with `/`; query and fragment are cut off.
    pub path: String,
    pub query: Option<String>,
}

impl ParsedUrl {
    /// `scheme://host[:port]/path[?query]`, the form a request is made with.
    pub fn render(&self) -> String {
        let mut s = format!("{}://{}", self.scheme, self.host);
        if let Some(p) = self.port {
            s.push_str(&format!(":{p}"));
        }
        s.push_str(&self.path);
        if let Some(q) = &self.query {
            s.push('?');
            s.push_str(q);
        }
        s
    }

    /// A `..` path segment, plain or percent-encoded.
    pub fn has_dot_dot(&self) -> bool {
        self.path
            .split('/')
            .any(|seg| seg.to_ascii_lowercase().replace("%2e", ".") == "..")
    }
}

/// Splits `scheme://host[:port][/path][?query][#fragment]`. Only `http` and `https` (lowercase),
/// no userinfo, no backslash, no whitespace or control bytes, a host made of ASCII letters,
/// digits, `.` and `-` that does not start or end with `.` or `-`, a numeric port. Anything else
/// is `None`. IPv6 literals are not accepted.
pub fn parse_url(url: &str) -> Option<ParsedUrl> {
    if url.is_empty() || url.len() > 2048 || !all(url, |c| c > 0x20 && c < 0x7f && c != b'\\') {
        return None;
    }
    let (scheme, rest) = url.split_once("://")?;
    if scheme != "http" && scheme != "https" {
        return None;
    }
    let rest = rest.split('#').next().unwrap_or("");
    let (auth, tail) = match rest.find(['/', '?']) {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, ""),
    };
    if auth.contains('@') || auth.is_empty() {
        return None;
    }
    let (host, port) = match auth.split_once(':') {
        Some((h, p)) => {
            if p.is_empty() || p.len() > 5 || !all(p, |c| c.is_ascii_digit()) {
                return None;
            }
            (h, Some(p.parse::<u16>().ok()?))
        }
        None => (auth, None),
    };
    let edge_ok = |c: u8| c.is_ascii_alphanumeric();
    let hb = host.as_bytes();
    if hb.is_empty()
        || hb.len() > 253
        || !edge_ok(hb[0])
        || !edge_ok(hb[hb.len() - 1])
        || !all(host, |c| {
            c.is_ascii_alphanumeric() || c == b'.' || c == b'-'
        })
        || host.contains("..")
    {
        return None;
    }
    let (path, query) = match tail.split_once('?') {
        Some((p, q)) => (p.to_string(), Some(q.to_string())),
        None => (tail.to_string(), None),
    };
    let path = if path.is_empty() {
        "/".to_string()
    } else {
        path
    };
    Some(ParsedUrl {
        scheme: scheme.to_string(),
        host: host.to_string(),
        port,
        path,
        query,
    })
}

// ---- Manifest -------------------------------------------------------------------------------

impl Manifest {
    pub fn decode(json: &str) -> Result<Manifest, ManifestError> {
        let v: Value =
            serde_json::from_str(json).map_err(|e| ManifestError(format!("json: {e}")))?;
        let mcp = get(&v, "mcp")?;
        let node = get(&v, "node")?;
        let chromium = get(&v, "chromium")?;
        Ok(Manifest {
            schema: int(&v, "schema")?,
            id: string(&v, "id")?,
            mcp: Mcp {
                package_json_sha256: string(mcp, "packageJsonSHA256")?,
                lockfile_sha256: string(mcp, "lockfileSHA256")?,
                npm_download_bytes: int(mcp, "npmDownloadBytes")?,
                npm_installed_bytes: mcp
                    .get("npmInstalledBytes")
                    .and_then(Value::as_i64)
                    .unwrap_or(0),
            },
            node: Node {
                version: string(node, "version")?,
                team_identifier: string(node, "teamIdentifier")?,
                artifacts: decode_artifacts(node)?,
            },
            chromium: Chromium {
                revision: string(chromium, "revision")?,
                browser_version: string(chromium, "browserVersion")?,
                released_at: string(chromium, "releasedAt")?,
                host: string(chromium, "host")?,
                artifacts: decode_artifacts(chromium)?,
            },
            hosts: string_list(&v, "hosts")?,
            stale_after_days: int(&v, "staleAfterDays")?,
            free_disk_factor: int(&v, "freeDiskFactor")?,
        })
    }

    /// The manifest built into this binary. A decode failure is a build error, caught by the
    /// tests, never a runtime condition.
    pub fn embedded() -> &'static Manifest {
        static M: OnceLock<Manifest> = OnceLock::new();
        M.get_or_init(|| Manifest::decode(PINS_JSON).expect("embedded pins.json decodes"))
    }

    pub fn node_artifact(&self, p: PlatformId) -> Option<&Artifact> {
        self.node.artifacts.get(p.as_str())
    }
    pub fn chromium_artifact(&self, p: PlatformId) -> Option<&Artifact> {
        self.chromium.artifacts.get(p.as_str())
    }

    /// The pins for the host this binary runs on.
    #[allow(dead_code)] // `browser_cli` selects through `select(PlatformId::host())` so it can report both
    pub fn select_for_host(&self) -> Result<Selection<'_>, SelectError> {
        self.select(PlatformId::host())
    }

    /// Same as `select_for_host` for a given platform; `None` is an unsupported host. Darwin ids
    /// parse but are not selectable on Linux, and nothing is skipped silently.
    pub fn select(&self, p: Option<PlatformId>) -> Result<Selection<'_>, SelectError> {
        let p = p.ok_or(SelectError::UnsupportedHost)?;
        if !p.is_linux() {
            return Err(SelectError::NotLinux);
        }
        Ok(Selection {
            platform: p,
            node: self.node_artifact(p).ok_or(SelectError::Missing)?,
            chromium: self.chromium_artifact(p).ok_or(SelectError::Missing)?,
        })
    }

    /// One entry per problem; empty means valid. Rules and names are pinned by the shared vectors.
    pub fn validate(&self) -> Vec<String> {
        self.validate_with(false)
    }

    /// `allow_loopback_http` lets tests serve fixtures from `http://127.0.0.1`. Production code
    /// calls `validate()`.
    pub(crate) fn validate_with(&self, allow_loopback_http: bool) -> Vec<String> {
        let mut p: Vec<String> = Vec::new();
        if self.schema != SCHEMA_VERSION {
            p.push("schema".into());
        }
        if !is_safe_id(&self.id) {
            p.push("id".into());
        }
        if !team_id(&self.node.team_identifier) {
            p.push("node.teamIdentifier".into());
        }
        let mut want_hosts: BTreeSet<String> = ["nodejs.org", "registry.npmjs.org"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        for a in self.chromium.artifacts.values() {
            if let Some(u) = parse_url(&a.url) {
                want_hosts.insert(u.host);
            }
        }
        let have: BTreeSet<String> = self.hosts.iter().cloned().collect();
        if have != want_hosts || have.len() != self.hosts.len() {
            p.push("hosts".into());
        }
        if !lower_hex64(&self.mcp.package_json_sha256) || !lower_hex64(&self.mcp.lockfile_sha256) {
            p.push("mcp digests".into());
        }
        if self.free_disk_factor < 3 {
            p.push("freeDiskFactor".into());
        }
        if self.stale_after_days < 1 {
            p.push("staleAfterDays".into());
        }
        if !is_calendar_day(&self.chromium.released_at) {
            p.push("chromium.releasedAt".into());
        }
        for (label, arts) in [
            ("node", &self.node.artifacts),
            ("chromium", &self.chromium.artifacts),
        ] {
            let keys: BTreeSet<&str> = arts.keys().map(String::as_str).collect();
            let want: BTreeSet<&str> = PlatformId::ALL.iter().map(|p| p.as_str()).collect();
            if keys != want {
                p.push(format!("{label} platforms"));
            }
            for (key, a) in arts {
                let Some(plat) = PlatformId::parse(key) else {
                    continue;
                };
                let tag = format!("{label}/{key}");
                let url_ok = parse_url(&a.url).filter(|u| {
                    self.hosts.contains(&u.host)
                        && (u.scheme == "https"
                            || (allow_loopback_http && u.scheme == "http" && u.host == "127.0.0.1"))
                        && !u.has_dot_dot()
                });
                let Some(u) = url_ok else {
                    p.push(format!("{tag} url"));
                    continue;
                };
                if !lower_hex64(&a.sha256) {
                    p.push(format!("{tag} sha256"));
                }
                let want_format = if label == "node" { "tar.gz" } else { "zip" };
                if a.format != want_format {
                    p.push(format!("{tag} format"));
                }
                if a.size <= 0
                    || a.expanded_bytes <= 0
                    || a.entry_count <= 0
                    || a.max_entry_bytes <= 0
                {
                    p.push(format!("{tag} limits"));
                }
                if !(0..=4).contains(&a.strip_components) {
                    p.push(format!("{tag} stripComponents"));
                }
                if label == "node" {
                    // The loopback switch is for tests that serve fixtures; real pins always follow the version.
                    let v = &self.node.version;
                    let want = format!("https://nodejs.org/dist/v{v}/node-v{v}-{key}.tar.gz");
                    if !allow_loopback_http && a.url != want {
                        p.push(format!("{tag} url"));
                    }
                } else {
                    let mut source_ok = false;
                    if let Some(src) = a.source.as_deref() {
                        if let Some(want) = source_host(src) {
                            if want == u.host || (allow_loopback_http && u.host == "127.0.0.1") {
                                source_ok = true;
                                if !allow_loopback_http
                                    && self.expected_chromium_url(plat, src).as_deref()
                                        != Some(a.url.as_str())
                                {
                                    p.push(format!("{tag} url"));
                                }
                            }
                        }
                    }
                    if !source_ok {
                        p.push(format!("{tag} source"));
                    }
                    let exe_ok = match a.executable.as_deref() {
                        Some(e)
                            if !e.is_empty()
                                && !e.starts_with('/')
                                && !e.split('/').any(|c| c == "..") =>
                        {
                            !plat.is_linux() || linux_chrome(e)
                        }
                        _ => false,
                    };
                    if !exe_ok {
                        p.push(format!("{tag} executable"));
                    }
                }
                p.extend(linux_field_problems(&tag, plat, a));
            }
        }
        p
    }

    fn expected_chromium_url(&self, plat: PlatformId, source: &str) -> Option<String> {
        match source {
            "chrome-for-testing" => {
                let d = cft_dir(plat);
                Some(format!(
                    "{CFT_BASE}/{}/{d}/chrome-{d}.zip",
                    self.chromium.browser_version
                ))
            }
            "playwright-cdn" => {
                cdn_file(plat).map(|f| format!("{CDN_BASE}/{}/{f}", self.chromium.revision))
            }
            _ => None,
        }
    }

    /// The embedded package.json and lockfile must hash to the values in this manifest.
    pub fn validate_embedded_files(&self, package_json: &str, lockfile_json: &str) -> Vec<String> {
        let mut p = Vec::new();
        if sha256_hex(package_json.as_bytes()) != self.mcp.package_json_sha256 {
            p.push("package.json digest".to_string());
        }
        if sha256_hex(lockfile_json.as_bytes()) != self.mcp.lockfile_sha256 {
            p.push("lockfile digest".to_string());
        }
        p
    }

    /// Rust-only rules that are stricter than the shared vectors (the Swift validator does not
    /// have them yet, ADR follow-up #132): the Linux Chromium executable must live in the
    /// directory the platform's archive uses. Kept out of `validate()` so both validators keep
    /// giving the same answers on the same vectors.
    pub fn platform_policy_problems(&self) -> Vec<String> {
        let mut p = Vec::new();
        for plat in PlatformId::ALL.into_iter().filter(|p| p.is_linux()) {
            let Some(a) = self.chromium_artifact(plat) else {
                continue;
            };
            let want = match (a.source.as_deref(), plat) {
                (Some("chrome-for-testing"), PlatformId::LinuxX64) => "chrome-linux64/chrome",
                (Some("chrome-for-testing"), PlatformId::LinuxArm64) => "chrome-linux-arm64/chrome",
                (Some("playwright-cdn"), _) => "chrome-linux/chrome",
                _ => "",
            };
            if a.executable.as_deref() != Some(want) {
                p.push(format!("chromium/{} executable platform", plat.as_str()));
            }
        }
        p
    }
}

/// The node and chromium pins for one installable platform.
#[derive(Debug)]
pub struct Selection<'a> {
    pub platform: PlatformId,
    pub node: &'a Artifact,
    pub chromium: &'a Artifact,
}

/// `minGlibc`, `needed` and `packageHints` exist on Linux artifacts and nowhere else.
fn linux_field_problems(tag: &str, plat: PlatformId, a: &Artifact) -> Vec<String> {
    let mut p = Vec::new();
    if !plat.is_linux() {
        if a.min_glibc.is_some() {
            p.push(format!("{tag} minGlibc"));
        }
        if a.needed.is_some() {
            p.push(format!("{tag} needed"));
        }
        if a.package_hints_apt.is_some() {
            p.push(format!("{tag} packageHints"));
        }
        return p;
    }
    if !a.min_glibc.as_deref().is_some_and(glibc_version) {
        p.push(format!("{tag} minGlibc"));
    }
    let needed_ok = a
        .needed
        .as_ref()
        .is_some_and(|n| !n.is_empty() && sorted_unique(n) && n.iter().all(|s| soname(s)));
    if !needed_ok {
        p.push(format!("{tag} needed"));
    }
    let hints_ok = a
        .package_hints_apt
        .as_ref()
        .is_some_and(|h| sorted_unique(h) && h.iter().all(|s| apt_name(s)));
    if !hints_ok {
        p.push(format!("{tag} packageHints"));
    }
    p
}

pub fn sha256_hex(data: &[u8]) -> String {
    hex(&Sha256::digest(data))
}

pub fn hex(bytes: &[u8]) -> String {
    const D: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(D[(b >> 4) as usize] as char);
        s.push(D[(b & 15) as usize] as char);
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_embedded_pins_decode_and_validate() {
        let m = Manifest::embedded();
        assert_eq!(m.validate(), Vec::<String>::new());
        assert_eq!(
            m.validate_embedded_files(PACKAGE_JSON, LOCKFILE_JSON),
            Vec::<String>::new()
        );
        assert_eq!(m.platform_policy_problems(), Vec::<String>::new());
    }

    #[test]
    fn a_wrong_json_shape_is_a_decode_error_not_a_problem() {
        assert!(Manifest::decode("[]").is_err());
        assert!(Manifest::decode("{").is_err());
        let bad = PINS_JSON.replacen("\"schema\": 2", "\"schema\": \"2\"", 1);
        assert!(Manifest::decode(&bad).is_err());
        let bad = PINS_JSON.replacen("\"size\": 58330843", "\"size\": 5.5", 1);
        assert!(Manifest::decode(&bad).is_err());
    }

    #[test]
    fn platform_selection_table() {
        let t = [
            ("linux", "x86_64", Some(PlatformId::LinuxX64)),
            ("linux", "amd64", Some(PlatformId::LinuxX64)),
            ("linux", "aarch64", Some(PlatformId::LinuxArm64)),
            ("linux", "arm64", Some(PlatformId::LinuxArm64)),
            ("darwin", "arm64", Some(PlatformId::DarwinArm64)),
            ("darwin", "aarch64", Some(PlatformId::DarwinArm64)),
            ("darwin", "x86_64", Some(PlatformId::DarwinX64)),
            ("linux", "riscv64", None),
            ("windows", "x86_64", None),
            ("Linux", "x86_64", None),
        ];
        for (os, arch, want) in t {
            assert_eq!(PlatformId::select(os, arch), want, "{os}/{arch}");
        }
        for p in PlatformId::ALL {
            assert_eq!(PlatformId::parse(p.as_str()), Some(p));
        }
        assert_eq!(PlatformId::parse("arm64"), None);
    }

    #[test]
    fn linux_pins_are_selectable_and_darwin_pins_are_not() {
        let m = Manifest::embedded();
        for p in [PlatformId::LinuxX64, PlatformId::LinuxArm64] {
            let s = m.select(Some(p)).expect("selectable");
            assert_eq!(s.platform, p);
            assert!(s.node.url.contains(p.as_str()));
            assert!(s.chromium.executable.is_some());
        }
        for p in [PlatformId::DarwinArm64, PlatformId::DarwinX64] {
            assert_eq!(m.select(Some(p)).unwrap_err(), SelectError::NotLinux);
            assert!(
                m.node_artifact(p).is_some(),
                "darwin ids still parse and resolve"
            );
        }
        assert_eq!(m.select(None).unwrap_err(), SelectError::UnsupportedHost);
        // The host this test runs on is one of the two or the call is an explicit error.
        match m.select_for_host() {
            Ok(s) => assert!(s.platform.is_linux()),
            Err(e) => assert!(matches!(
                e,
                SelectError::NotLinux | SelectError::UnsupportedHost
            )),
        }
    }

    #[test]
    fn executable_must_match_the_platform_directory() {
        let mut m = Manifest::embedded().clone();
        let a = m.chromium.artifacts.get_mut("linux-x64").unwrap();
        a.executable = Some("chrome-linux-arm64/chrome".into());
        assert!(m.validate().is_empty(), "the shared rules accept it");
        assert_eq!(
            m.platform_policy_problems(),
            vec!["chromium/linux-x64 executable platform"]
        );
    }

    #[test]
    fn pattern_boundaries() {
        assert!(
            lower_hex64(&"a".repeat(64))
                && !lower_hex64(&"a".repeat(63))
                && !lower_hex64(&"A".repeat(64))
        );
        assert!(is_safe_id("a") && is_safe_id(&"a".repeat(128)) && !is_safe_id(&"a".repeat(129)));
        assert!(!is_safe_id("") && !is_safe_id(".x") && !is_safe_id("a/b") && !is_safe_id("a b"));
        assert!(team_id("HX7739G8FX") && !team_id("hx7739g8fx") && !team_id("HX7739G8F"));
        assert!(
            glibc_version("2.28")
                && glibc_version("2.28.1")
                && !glibc_version("2")
                && !glibc_version("2.")
                && !glibc_version("a.b")
        );
        assert!(!glibc_version("2.28.1.1") && !glibc_version(".2.3"));
        assert!(
            soname("libc.so.6")
                && soname("libstdc++.so.6")
                && !soname("../libc.so.6")
                && !soname("-x")
                && !soname(&"a".repeat(129))
        );
        assert!(
            apt_name("libc6")
                && apt_name("a+")
                && !apt_name("a")
                && !apt_name("Lib")
                && !apt_name("bad name;x")
                && !apt_name(&"a".repeat(65))
        );
        assert!(
            linux_chrome("chrome-linux64/chrome")
                && linux_chrome("chrome-linux/chrome")
                && linux_chrome("chrome-linux-arm64/chrome")
        );
        assert!(
            !linux_chrome("chrome-linux/x/chrome")
                && !linux_chrome("chrome-linux64/other")
                && !linux_chrome("chrome-mac/chrome")
        );
        assert!(
            sorted_unique(&[])
                && !sorted_unique(&["b".into(), "a".into()])
                && !sorted_unique(&["a".into(), "a".into()])
        );
    }

    #[test]
    fn calendar_days() {
        for ok in ["2026-09-01", "2024-02-29", "2000-02-29", "2026-12-31"] {
            assert!(is_calendar_day(ok), "{ok}");
        }
        for bad in [
            "2026-02-29",
            "1900-02-29",
            "2026-13-01",
            "2026-00-10",
            "2026-04-31",
            "2026-9-1",
            "tomorrow",
            "2026-09-01x",
            "",
            "2026/09/01",
        ] {
            assert!(!is_calendar_day(bad), "{bad}");
        }
    }

    #[test]
    fn url_splitter_table() {
        let ok = parse_url("https://nodejs.org/dist/v1/x.tar.gz").unwrap();
        assert_eq!(
            (
                ok.scheme.as_str(),
                ok.host.as_str(),
                ok.port,
                ok.path.as_str()
            ),
            ("https", "nodejs.org", None, "/dist/v1/x.tar.gz")
        );
        assert_eq!(
            parse_url("http://127.0.0.1:8080/a?b=1#f").unwrap().render(),
            "http://127.0.0.1:8080/a?b=1"
        );
        assert_eq!(parse_url("https://a.example").unwrap().path, "/");
        assert!(parse_url("https://a.example/a/%2e%2E/b")
            .unwrap()
            .has_dot_dot());
        assert!(parse_url("https://a.example/a/../b").unwrap().has_dot_dot());
        assert!(!parse_url("https://a.example/a/..b/c")
            .unwrap()
            .has_dot_dot());
        for bad in [
            "",
            "ftp://a.example/x",
            "HTTPS://a.example/x",
            "https:/a.example",
            "//a.example/x",
            "/relative",
            concat!("https://user", "@a.example/x"),
            concat!("https://user:pw", "@a.example/x"),
            "https://a.example\\@b.example/x",
            "https://a.example:/x",
            "https://a.example:99999/x",
            "https://a.example:80a/x",
            "https://.a.example/x",
            "https://a.example./x",
            "https://a..example/x",
            "https://-a.example/x",
            "https://[::1]/x",
            "https://a example/x",
            "https://a.example/x\u{7f}",
            "https:///x",
            "https://a_b.example/x",
        ] {
            assert!(parse_url(bad).is_none(), "{bad:?}");
        }
        assert!(parse_url(&format!("https://a.example/{}", "x".repeat(3000))).is_none());
    }
}
