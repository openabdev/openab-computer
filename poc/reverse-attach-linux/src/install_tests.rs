//! Install, update, remove and status against a fake download server and a stub `node`. Every test
//! installs into its own temp root; nothing here touches a real home.

use super::*;
use crate::catalog::BROWSER_TOOLS;
use crate::elf::tests::build_elf;
use crate::extract::tests::{zip_build, TarBuilder, ZEntry};
use crate::manifest::sha256_hex;
use crate::preflight::Userns;
use crate::state::tests::{assert_sentinel, TempDir};
use crate::state::STAGING_PREFIX;
use sha2::{Digest, Sha512};
use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

const CANARY: &str = "SECRET-CANARY";

// ---- a tiny HTTP server ---------------------------------------------------------------------

pub(crate) struct Net {
    port: u16,
    conns: Arc<AtomicU32>,
    routes: Arc<Mutex<HashMap<String, Vec<u8>>>>,
    stop: Arc<AtomicBool>,
}

impl Net {
    fn start() -> Net {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        l.set_nonblocking(true).unwrap();
        let port = l.local_addr().unwrap().port();
        let conns = Arc::new(AtomicU32::new(0));
        let routes: Arc<Mutex<HashMap<String, Vec<u8>>>> = Arc::default();
        let stop = Arc::new(AtomicBool::new(false));
        let (c, r, s) = (conns.clone(), routes.clone(), stop.clone());
        std::thread::spawn(move || {
            while !s.load(Ordering::SeqCst) {
                match l.accept() {
                    Ok((sock, _)) => {
                        c.fetch_add(1, Ordering::SeqCst);
                        let r = r.clone();
                        std::thread::spawn(move || serve(sock, &r));
                    }
                    Err(_) => std::thread::sleep(Duration::from_millis(5)),
                }
            }
        });
        Net {
            port,
            conns,
            routes,
            stop,
        }
    }
    pub(crate) fn conns(&self) -> u32 {
        self.conns.load(Ordering::SeqCst)
    }
}

impl Drop for Net {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}

fn serve(mut s: TcpStream, routes: &Mutex<HashMap<String, Vec<u8>>>) {
    s.set_nonblocking(false).unwrap();
    let mut rd = BufReader::new(s.try_clone().unwrap());
    let mut line = String::new();
    if rd.read_line(&mut line).is_err() {
        return;
    }
    loop {
        let mut h = String::new();
        if rd.read_line(&mut h).is_err() || h.trim().is_empty() {
            break;
        }
    }
    let path = line.split_whitespace().nth(1).unwrap_or("/").to_string();
    let body = routes.lock().unwrap().get(&path).cloned();
    match body {
        Some(b) => {
            let _ = write!(
                s,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                b.len()
            );
            let _ = s.write_all(&b);
        }
        None => {
            let _ = write!(
                s,
                "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            );
        }
    }
}

// ---- fixtures -------------------------------------------------------------------------------

#[derive(Default, Clone)]
pub(crate) struct Tw {
    /// The server sends the right size with one byte changed.
    tamper_chromium: bool,
    /// The server sends fewer bytes than pinned.
    short_chromium: bool,
    /// The Chromium zip holds a `../evil` entry (its digest is pinned, so only extraction objects).
    evil_zip: bool,
    /// The Chromium tree holds an ELF that needs a library nobody has.
    elf_needs: Option<(&'static str, &'static str)>,
}

fn b64(b: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(b)
}

pub(crate) struct Env {
    pub(crate) t: TempDir,
    pub(crate) net: Net,
    pub(crate) registry: Net,
    base_manifest: Manifest,
    pub(crate) pkg_json: String,
    pub(crate) lock_json: String,
    node_tgz: Vec<u8>,
    chrome_zip: Vec<u8>,
    npm: Vec<(String, Vec<u8>)>,
    mode: PathBuf,
    log: PathBuf,
}

fn stub_node(mode: &Path, log: &Path, root: &Path) -> String {
    let tools: Vec<String> = BROWSER_TOOLS
        .iter()
        .map(|t| format!("{{\"name\":\"{t}\"}}"))
        .collect();
    let tools = format!("[{}]", tools.join(","));
    let short_tools: Vec<String> = BROWSER_TOOLS[..31]
        .iter()
        .map(|t| format!("{{\"name\":\"{t}\"}}"))
        .collect();
    let short_tools = format!("[{}]", short_tools.join(","));
    format!(
        r#"#!/bin/sh
echo "$@" >> {log}
MODE=$(cat {mode} 2>/dev/null)
case "$1" in
*npm-cli.js)
  echo {canary} >&2
  case "$2" in
    ci)
      [ "$MODE" = npm_fail ] && exit 1
      mkdir -p node_modules/@playwright/mcp
      echo c > node_modules/@playwright/mcp/cli.js
      exit 0;;
    *) exit 0;;
  esac;;
*cli.js)
  echo "TMPDIRSEEN=$TMPDIR" >> {log}
  echo {canary} >&2
  echo '{{"canary":"{canary}"}}'
  [ "$MODE" = die ] && exit 3
  [ "$MODE" = refuse ] && {{ echo 'No usable sandbox!' >&2; exit 1; }}
  [ "$MODE" = plant_record ] && echo '{{"foreign":true}}' > {root}/install.json
  NAME=Playwright
  [ "$MODE" = bad_name ] && NAME=Chromium
  TOOLS='{tools}'
  [ "$MODE" = no_tool ] && TOOLS='{short_tools}'
  ERR=false
  [ "$MODE" = nav_error ] && ERR=true
  while IFS= read -r line; do
    id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
    case "$line" in
      *'"method":"initialize"'*) printf '{{"jsonrpc":"2.0","id":%s,"result":{{"serverInfo":{{"name":"%s"}},"capabilities":{{}}}}}}\n' "$id" "$NAME";;
      *'"method":"tools/list"'*) printf '{{"jsonrpc":"2.0","id":%s,"result":{{"tools":%s}}}}\n' "$id" "$TOOLS";;
      *'"method":"tools/call"'*) printf '{{"jsonrpc":"2.0","id":%s,"result":{{"content":[],"isError":%s}}}}\n' "$id" "$ERR";;
    esac
  done;;
esac
"#,
        log = log.display(),
        mode = mode.display(),
        root = root.display(),
        canary = CANARY,
    )
}

impl Env {
    pub(crate) fn new(tw: Tw) -> Env {
        let t = TempDir::new();
        let net = Net::start();
        let registry = Net::start();
        let mode = t.path.join("mode");
        let log = t.path.join("stub.log");
        std::fs::write(&mode, "ok").unwrap();
        let root = t.base().join("oab-computer/playwright");

        let node_tgz = TarBuilder::default()
            .file(
                "node-test/bin/node",
                stub_node(&mode, &log, &root).as_bytes(),
                0o755,
            )
            .file(
                "node-test/lib/node_modules/npm/bin/npm-cli.js",
                b"// npm",
                0o644,
            )
            .gz();
        let mut z = vec![
            ZEntry::file("chrome-test/chrome", b"#!/bin/sh\n", false, 0o755),
            ZEntry::file("chrome-test/data.bin", &[7u8; 2000], true, 0o644),
        ];
        if let Some((need, ver)) = tw.elf_needs {
            z.push(ZEntry::file(
                "chrome-test/libx.so",
                &build_elf(None, &[need], &[("libc.so.6", &[ver])], &[]),
                false,
                0o644,
            ));
        }
        if tw.evil_zip {
            z.push(ZEntry::file("../evil", b"x", false, 0o644));
        }
        let chrome_zip = zip_build(&z);

        let npm: Vec<(String, Vec<u8>)> =
            ["mcp-1.tgz", "playwright-1.tgz", "playwright-core-1.tgz"]
                .iter()
                .enumerate()
                .map(|(i, n)| (n.to_string(), vec![i as u8 + 1; 700 + i]))
                .collect();
        let pkg_json = r#"{"name":"t","dependencies":{"@playwright/mcp":"1"}}"#.to_string();
        let mut pk = String::new();
        for (i, (n, b)) in npm.iter().enumerate() {
            let key = ["@playwright/mcp", "playwright", "playwright-core"][i];
            let scope = key;
            pk.push_str(&format!(
                r#","node_modules/{key}":{{"version":"1","resolved":"https://registry.npmjs.org/{scope}/-/{n}","integrity":"sha512-{}"}}"#,
                b64(&Sha512::digest(b))
            ));
        }
        let lock_json = format!(r#"{{"lockfileVersion":3,"packages":{{"":{{"name":"t"}}{pk}}}}}"#);

        let mut served = chrome_zip.clone();
        if tw.tamper_chromium {
            let n = served.len() / 2;
            served[n] ^= 0xff;
        }
        if tw.short_chromium {
            served.truncate(served.len() - 10);
        }
        net.routes
            .lock()
            .unwrap()
            .insert("/node-test.tar.gz".into(), node_tgz.clone());
        net.routes
            .lock()
            .unwrap()
            .insert("/chrome-test.zip".into(), served);

        let mut m = Manifest::embedded().clone();
        m.id = "test-id-1".into();
        m.hosts = vec!["127.0.0.1".into()];
        m.free_disk_factor = 1;
        m.mcp.package_json_sha256 = sha256_hex(pkg_json.as_bytes());
        m.mcp.lockfile_sha256 = sha256_hex(lock_json.as_bytes());
        m.mcp.npm_download_bytes = npm.iter().map(|(_, b)| b.len() as i64).sum();
        m.mcp.npm_installed_bytes = 1000;
        let url = |p: &str| format!("http://127.0.0.1:{}{p}", net.port);
        let node = m.node.artifacts.get_mut("linux-x64").unwrap();
        node.url = url("/node-test.tar.gz");
        node.format = "tar.gz".into();
        node.size = node_tgz.len() as i64;
        node.sha256 = sha256_hex(&node_tgz);
        node.strip_components = 1;
        node.expanded_bytes = 1_000_000;
        node.entry_count = 50;
        node.max_entry_bytes = 1_000_000;
        node.needed = Some(vec!["libc.so.6".into()]);
        node.package_hints_apt = Some(vec!["libc6".into()]);
        let ch = m.chromium.artifacts.get_mut("linux-x64").unwrap();
        ch.url = url("/chrome-test.zip");
        ch.format = "zip".into();
        ch.size = chrome_zip.len() as i64;
        ch.sha256 = sha256_hex(&chrome_zip);
        ch.strip_components = 0;
        ch.expanded_bytes = 1_000_000;
        ch.entry_count = 50;
        ch.max_entry_bytes = 1_000_000;
        ch.executable = Some("chrome-test/chrome".into());
        ch.needed = Some(vec!["libc.so.6".into()]);
        ch.package_hints_apt = Some(vec!["libc6".into()]);
        Env {
            t,
            net,
            registry,
            base_manifest: m,
            pkg_json,
            lock_json,
            node_tgz,
            chrome_zip,
            npm,
            mode,
            log,
        }
    }

    pub(crate) fn manifest(&self, id: &str) -> Manifest {
        let mut m = self.base_manifest.clone();
        m.id = id.into();
        m
    }

    pub(crate) fn set_mode(&self, m: &str) {
        std::fs::write(&self.mode, m).unwrap();
    }

    pub(crate) fn root(&self) -> PathBuf {
        self.t.base().join("oab-computer/playwright")
    }

    /// Runs `f` with options for `m`. `dir` selects `--from-dir`.
    pub(crate) fn with<R>(
        &self,
        m: &Manifest,
        dir: Option<&Path>,
        facts: Facts,
        f: impl FnOnce(&Opts<'_>) -> R,
    ) -> R {
        let policy = DownloadPolicy::for_tests(&["127.0.0.1"]);
        let facts_fn = move |_: &Path| facts.clone();
        let o = Opts {
            manifest: m,
            files: Files {
                package_json: &self.pkg_json,
                lockfile: &self.lock_json,
            },
            source: match dir {
                Some(d) => Source::Dir(d),
                None => Source::Network(&policy),
            },
            check_manifest: false,
            limits: download::Limits {
                connect: Duration::from_secs(2),
                read: Duration::from_secs(5),
                total: Duration::from_secs(30),
                max_redirects: 3,
            },
            timeouts: health::Timeouts {
                initialize: Duration::from_secs(10),
                call: Duration::from_secs(10),
                close: Duration::from_secs(2),
            },
            npm_timeout: Duration::from_secs(30),
            lock_wait: Duration::from_millis(300),
            base: self.t.base(),
            home: None,
            platform: Some(PlatformId::LinuxX64),
            facts: &facts_fn,
            launcher: &crate::sigstop::Plain,
            extras: &|_: &Path, _: bool| crate::probe::Extras::none(),
        };
        f(&o)
    }

    fn install(&self, m: &Manifest) -> (R<Done>, String, String) {
        self.install_with(m, None, good_facts())
    }

    fn install_with(
        &self,
        m: &Manifest,
        dir: Option<&Path>,
        facts: Facts,
    ) -> (R<Done>, String, String) {
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let r = self.with(m, dir, facts, |o| {
            install(
                o,
                &mut Io {
                    out: &mut out,
                    err: &mut err,
                },
            )
        });
        (
            r,
            String::from_utf8(out).unwrap(),
            String::from_utf8(err).unwrap(),
        )
    }

    fn update(
        &self,
        m: &Manifest,
        answer: Option<bool>,
        dir: Option<&Path>,
    ) -> (R<Done>, String, String) {
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let r = self.with(m, dir, good_facts(), |o| {
            update(
                o,
                &mut Io {
                    out: &mut out,
                    err: &mut err,
                },
                &mut |_| answer,
            )
        });
        (
            r,
            String::from_utf8(out).unwrap(),
            String::from_utf8(err).unwrap(),
        )
    }

    fn status(&self, m: &Manifest) -> Status {
        self.with(m, None, good_facts(), |o| status(o, false).unwrap())
    }

    fn remove(&self, m: &Manifest) -> R<Option<Removal>> {
        self.with(m, None, good_facts(), remove)
    }

    fn names(&self) -> Vec<String> {
        match std::fs::read_dir(self.root()) {
            Ok(rd) => {
                let mut v: Vec<String> = rd
                    .flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect();
                v.sort();
                v
            }
            Err(_) => vec![],
        }
    }

    /// Nothing but the lock file may be left after a failed first install.
    fn assert_clean_failure(&self, what: &str) {
        let names = self.names();
        assert!(
            names.iter().all(|n| n == ".install.lock"),
            "{what}: a failed install left {names:?}"
        );
    }
}

pub(crate) fn good_facts() -> Facts {
    Facts {
        libc: Libc::Glibc(Some((2, 41))),
        ld: None,
        os_release: "ID=debian\n".into(),
        userns: Userns::default(),
        free_disk: Some(u64::MAX / 4),
        seat: false,
        data_base: PathBuf::from("/home/u/.local/share"),
    }
}

fn fail(c: &'static str) -> R<Done> {
    Err(Fail(c))
}

fn all_files_under(p: &Path, out: &mut Vec<PathBuf>) {
    if let Ok(rd) = std::fs::read_dir(p) {
        for e in rd.flatten() {
            let path = e.path();
            let md = std::fs::symlink_metadata(&path).unwrap();
            if md.is_dir() {
                all_files_under(&path, out);
            } else if md.is_file() {
                out.push(path);
            }
        }
    }
}

// ---- install --------------------------------------------------------------------------------

#[test]
fn a_full_install_commits_records_and_leaves_no_trace_of_the_build() {
    let e = Env::new(Tw::default());
    let m = e.manifest("test-id-1");
    let (r, out, err) = e.install(&m);
    assert_eq!(r, Ok(Done::Installed("test-id-1".into())), "{out}{err}");
    let names = e.names();
    for n in [
        ".install.lock",
        "install.json",
        "test-id-1",
        "profile",
        "output",
        "home",
        "run",
    ] {
        assert!(names.contains(&n.to_string()), "{n} in {names:?}");
    }
    assert!(!names.iter().any(|n| n.starts_with(".staging-")));
    let mode = |p: PathBuf| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(e.root().join("install.json")), 0o600);
    for d in ["profile", "output", "home", "run", "test-id-1"] {
        assert_eq!(mode(e.root().join(d)), 0o700, "{d}");
    }
    for d in ["profile", "output", "home", "run"] {
        assert!(e.root().join(d).join(OWNED_DATA).is_file(), "{d} marker");
    }
    let v = e.root().join("test-id-1");
    assert!(v.join(OWNED).is_file());
    assert!(!v.join(STAGING_MARK).exists());
    for gone in [
        "dl",
        "hc",
        "npm-cache",
        "home",
        "tmp",
        "user.npmrc",
        "global.npmrc",
    ] {
        assert!(
            !v.join(gone).exists(),
            "{gone} must not be in the version directory"
        );
    }
    assert!(v.join("node/bin/node").is_file() && v.join("chromium/chrome-test/chrome").is_file());
    assert!(v.join("pkg/node_modules/@playwright/mcp/cli.js").is_file());
    assert!(v.join("pkg/package.json").is_file() && v.join("pkg/package-lock.json").is_file());

    let rec = InstallRecord::parse(&std::fs::read(e.root().join("install.json")).unwrap()).unwrap();
    assert_eq!(
        (rec.version.as_str(), rec.manifest_id.as_str()),
        ("test-id-1", "test-id-1")
    );
    assert_eq!(rec.platform, "linux-x64");
    assert_eq!(rec.chromium_executable, "chrome-test/chrome");
    assert_eq!(rec.previous, None);
    assert_eq!(rec.digests["node"], m.node.artifacts["linux-x64"].sha256);
    assert_eq!(rec.digests["lockfile"], m.mcp.lockfile_sha256);

    // Output: the consent text first, a preflight line, the progress on stderr only.
    assert!(out.starts_with("Downloads about"), "{out}");
    assert!(out.contains("preflight: ok"));
    assert!(!out.to_lowercase().contains("safe"));
    assert!(
        err.contains("downloading Node.js") || err.contains("running the headless health check"),
        "{err}"
    );
    // The canary printed by the stub on stdout and stderr appears nowhere.
    assert!(!out.contains(CANARY) && !err.contains(CANARY));
    let mut files = Vec::new();
    all_files_under(&e.root(), &mut files);
    for f in files {
        let b = std::fs::read(&f).unwrap_or_default();
        let is_stub = f.ends_with("bin/node");
        assert!(
            is_stub || !String::from_utf8_lossy(&b).contains(CANARY),
            "{f:?}"
        );
    }
    // npm ran online and without --offline.
    let log = std::fs::read_to_string(&e.log).unwrap();
    assert!(log.contains(" ci ") && !log.contains("--offline"), "{log}");
    // The health check ran the sandboxed launch vector, with a short TMPDIR outside staging that
    // is gone again afterwards (Chromium's socket path limit, found on a real host).
    let cli_line = log
        .lines()
        .find(|l| l.contains("--headless"))
        .expect("health check ran");
    assert!(
        cli_line.contains(" --sandbox ") && !cli_line.contains("--no-sandbox"),
        "{cli_line}"
    );
    let tmp = log
        .lines()
        .find_map(|l| l.strip_prefix("TMPDIRSEEN="))
        .unwrap();
    assert!(
        tmp.len() < 40 && !tmp.contains(".staging-") && tmp.contains("oab-hc-"),
        "{tmp}"
    );
    assert!(
        !Path::new(tmp).exists(),
        "the short temporary directory was removed"
    );

    // A second install is a no-op that makes no connection.
    let conns = e.net.conns();
    assert_eq!(
        e.install(&m).0,
        Ok(Done::AlreadyInstalled("test-id-1".into()))
    );
    assert_eq!(e.net.conns(), conns);
    // Status.
    let s = e.status(&m);
    assert_eq!(
        (s.state, s.update_available, s.pins_match),
        ("installed", Some(false), Some(true))
    );
    let j: Value = serde_json::from_str(&s.to_json()).unwrap();
    let keys: Vec<&str> = j.as_object().unwrap().keys().map(String::as_str).collect();
    let mut want = vec![
        "state",
        "manifest_id",
        "installed_id",
        "previous",
        "platform",
        "update_available",
        "install_path",
        "chromium_revision",
        "pins_match",
        "pending_cleanup",
        // L2, R6.4.
        "containment",
        "external_configured",
        "listeners",
        "refusal",
        // L4, R6.4.
        "hardening_base",
        "hardening_mount",
        "hardening_unverified",
        "run_records",
    ];
    want.sort_unstable();
    let mut got = keys.clone();
    got.sort_unstable();
    assert_eq!(got, want);
    assert!(!s.to_json().contains("http"));
    // The human lines keep the existing order and end with the four L4 fields.
    let names: Vec<String> = s
        .lines()
        .iter()
        .map(|l| l.split(": ").next().unwrap().to_string())
        .collect();
    assert_eq!(
        names[names.len() - 8..],
        [
            "containment",
            "external_configured",
            "listeners",
            "refusal",
            "hardening_base",
            "hardening_mount",
            "hardening_unverified",
            "run_records",
        ]
    );
    // Every value of the new fields is a fixed token: no path, URL or text.
    for v in [
        &s.extras.hardening_base,
        &s.extras.hardening_mount,
        &s.extras.hardening_unverified,
        &s.extras.run_records,
    ] {
        assert!(
            v.bytes()
                .all(|b| b.is_ascii_lowercase() || b == b'_' || b == b','),
            "{v}"
        );
    }
}

#[test]
fn every_failure_stage_leaves_nothing_behind() {
    let cases: Vec<(&str, Tw, &str, &'static str)> = vec![
        (
            "digest mismatch",
            Tw {
                tamper_chromium: true,
                ..Tw::default()
            },
            "ok",
            "digest_mismatch",
        ),
        (
            "size mismatch",
            Tw {
                short_chromium: true,
                ..Tw::default()
            },
            "ok",
            "size_mismatch",
        ),
        (
            "rejected archive",
            Tw {
                evil_zip: true,
                ..Tw::default()
            },
            "ok",
            "archive_rejected",
        ),
        ("npm failure", Tw::default(), "npm_fail", "npm_failed"),
        (
            "wrong identity",
            Tw::default(),
            "bad_name",
            "health_check_failed",
        ),
        (
            "missing tool",
            Tw::default(),
            "no_tool",
            "health_check_failed",
        ),
        (
            "navigation error",
            Tw::default(),
            "nav_error",
            "health_check_failed",
        ),
        ("server dies", Tw::default(), "die", "health_check_failed"),
        ("sandbox refusal", Tw::default(), "refuse", "launch_refused"),
    ];
    for (what, tw, mode, class) in cases {
        let e = Env::new(tw);
        e.set_mode(mode);
        let m = e.manifest("test-id-1");
        let (_, sentinel) = e.t.sentinel();
        let (r, out, err) = e.install(&m);
        assert_eq!(r, fail(class), "{what}\n{out}\n{err}");
        e.assert_clean_failure(what);
        assert_sentinel(&sentinel);
        assert!(
            !out.contains(CANARY) && !err.contains(CANARY),
            "{what}: canary leaked"
        );
        // The next run is not blocked by what failed.
        e.set_mode("ok");
        if class == "digest_mismatch" || class == "size_mismatch" || class == "archive_rejected" {
            continue;
        }
        let (r2, _, _) = e.install(&m);
        assert_eq!(r2, Ok(Done::Installed("test-id-1".into())), "{what}: retry");
    }
}

#[test]
fn a_blocked_preflight_creates_nothing_and_downloads_nothing() {
    let e = Env::new(Tw::default());
    let m = e.manifest("test-id-1");
    let mut f = good_facts();
    f.libc = Libc::Musl;
    let (r, out, _) = e.install_with(&m, None, f);
    assert_eq!(r, fail("preflight_failed"));
    assert!(out.contains("musl"));
    assert!(
        !e.t.base().join("oab-computer").exists(),
        "no directory was created"
    );
    assert_eq!(e.net.conns(), 0);
    let mut f = good_facts();
    f.free_disk = Some(10);
    assert_eq!(e.install_with(&m, None, f).0, fail("preflight_failed"));
    assert_eq!(e.net.conns(), 0);
}

#[test]
fn a_foreign_profile_or_data_directory_is_never_adopted_and_stops_before_any_download() {
    for dir in ["profile", "output", "home", "run"] {
        let e = Env::new(Tw::default());
        let m = e.manifest("test-id-1");
        drop(e.t.root());
        let d = e.root().join(dir);
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("cookies"), "mine").unwrap();
        let (r, _, _) = e.install(&m);
        assert_eq!(r, fail("foreign_data"), "{dir}");
        assert_eq!(e.net.conns(), 0, "{dir}: nothing was downloaded");
        assert_eq!(std::fs::read(d.join("cookies")).unwrap(), b"mine");
        assert!(!d.join(OWNED_DATA).exists(), "{dir}: not adopted");
        let names = e.names();
        assert!(
            !names
                .iter()
                .any(|n| n.starts_with(".staging-") || n == "test-id-1" || n == "install.json"),
            "{names:?}"
        );
    }
    // A data directory that is a symlink is foreign too.
    let e = Env::new(Tw::default());
    let m = e.manifest("test-id-1");
    drop(e.t.root());
    let (out, sentinel) = e.t.sentinel();
    std::os::unix::fs::symlink(&out, e.root().join("profile")).unwrap();
    assert_eq!(e.install(&m).0, fail("foreign_data"));
    assert_sentinel(&sentinel);
}

#[test]
fn a_foreign_install_record_is_left_alone() {
    let e = Env::new(Tw::default());
    let m = e.manifest("test-id-1");
    drop(e.t.root());
    std::fs::write(e.root().join("install.json"), r#"{"someone":"else"}"#).unwrap();
    let (r, _, _) = e.install(&m);
    assert_eq!(r, fail("foreign_install"));
    assert_eq!(
        std::fs::read(e.root().join("install.json")).unwrap(),
        br#"{"someone":"else"}"#
    );
    assert_eq!(e.net.conns(), 0);
    assert_eq!(e.status(&m).state, "foreign_install");
    // Update refuses it too, and remove leaves it.
    assert_eq!(e.update(&m, Some(true), None).0, fail("foreign_install"));
    let rep = e.remove(&m).unwrap().unwrap().report;
    assert!(rep.left.iter().any(|(n, _)| n == "install.json"));
    assert!(e.root().join("install.json").exists());
}

#[test]
fn a_symlinked_root_stops_install_update_remove_and_status() {
    let e = Env::new(Tw::default());
    let m = e.manifest("test-id-1");
    let (out, sentinel) = e.t.sentinel();
    std::fs::create_dir_all(e.t.base()).unwrap();
    std::os::unix::fs::symlink(&out, e.t.base().join("oab-computer")).unwrap();
    assert_eq!(e.install(&m).0, fail("root_not_directory"));
    assert_eq!(e.update(&m, Some(true), None).0, fail("root_not_directory"));
    assert_eq!(e.remove(&m).err(), Some(Fail("root_not_directory")));
    assert!(e
        .with(&m, None, good_facts(), |o| status(o, false))
        .is_err());
    assert_sentinel(&sentinel);
    assert_eq!(std::fs::read_dir(&out).unwrap().count(), 1);
    assert_eq!(e.net.conns(), 0);
}

#[test]
fn a_record_that_appears_during_the_build_is_not_overwritten() {
    let e = Env::new(Tw::default());
    let m = e.manifest("test-id-1");
    e.set_mode("plant_record");
    let (r, _, _) = e.install(&m);
    assert_eq!(r, fail("record_changed"));
    assert_eq!(
        std::fs::read(e.root().join("install.json")).unwrap(),
        b"{\"foreign\":true}\n"
    );
    let names = e.names();
    assert_eq!(
        names,
        [".install.lock", "install.json"],
        "staging, version and data dirs are gone"
    );
}

#[test]
fn a_failed_record_write_after_the_rename_removes_the_new_version_and_the_data_dirs() {
    let e = Env::new(Tw::default());
    let m = e.manifest("test-id-1");
    AFTER_RENAME.with(|h| {
        *h.borrow_mut() = Some(Box::new(|root: &Root| {
            let _ = std::fs::write(root.display_path().join("install.json"), "planted");
        }));
    });
    let (r, _, _) = e.install(&m);
    AFTER_RENAME.with(|h| *h.borrow_mut() = None);
    assert_eq!(r.err().map(|f| f.0), Some("io"));
    assert_eq!(
        std::fs::read(e.root().join("install.json")).unwrap(),
        b"planted"
    );
    assert_eq!(e.names(), [".install.lock", "install.json"]);
    let leftovers: Vec<_> = std::fs::read_dir(e.root())
        .unwrap()
        .flatten()
        .filter(|d| d.file_name().to_string_lossy().contains(".tmp-"))
        .collect();
    assert!(leftovers.is_empty());
}

#[test]
fn install_over_another_version_says_use_update_and_pin_changes_are_refused() {
    let e = Env::new(Tw::default());
    let m1 = e.manifest("test-id-1");
    assert!(e.install(&m1).0.is_ok());
    let m2 = e.manifest("test-id-2");
    assert_eq!(e.install(&m2).0, fail("use_update"));
    assert_eq!(
        e.names()
            .iter()
            .filter(|n| n.starts_with("test-id"))
            .count(),
        1
    );
    // The same id with different pinned digests is a release mistake: reported, not applied.
    let mut m1b = m1.clone();
    m1b.node.artifacts.get_mut("linux-x64").unwrap().sha256 = "0".repeat(64);
    assert_eq!(e.install(&m1b).0, fail("pins_changed_same_id"));
    assert_eq!(
        e.update(&m1b, Some(true), None).0,
        fail("pins_changed_same_id")
    );
    assert_eq!(e.status(&m1b).pins_match, Some(false));
    assert_eq!(e.status(&m1).pins_match, Some(true));
}

#[test]
fn leftover_marked_staging_is_swept_and_a_lookalike_is_not() {
    let e = Env::new(Tw::default());
    let m = e.manifest("test-id-1");
    drop(e.t.root());
    let marked = format!("{STAGING_PREFIX}{}", "c".repeat(32));
    let unmarked = format!("{STAGING_PREFIX}{}", "d".repeat(32));
    std::fs::create_dir_all(e.root().join(&marked).join("dl")).unwrap();
    std::fs::write(e.root().join(&marked).join(STAGING_MARK), "m").unwrap();
    std::fs::write(e.root().join(&marked).join("dl/.node.part"), "partial").unwrap();
    std::fs::create_dir_all(e.root().join(&unmarked)).unwrap();
    std::fs::write(e.root().join(&unmarked).join("keep"), "k").unwrap();
    let (r, _, err) = e.install(&m);
    assert!(r.is_ok());
    assert!(err.contains("removed leftover staging directory"));
    assert!(!e.root().join(&marked).exists());
    assert!(e.root().join(&unmarked).join("keep").exists());
}

#[test]
fn a_held_lock_stops_the_run_without_creating_anything_else() {
    let e = Env::new(Tw::default());
    let m = e.manifest("test-id-1");
    let root = e.t.root();
    let _held = Lock::acquire(&root, Duration::from_millis(0)).unwrap();
    assert_eq!(e.install(&m).0, fail("lock_held"));
    assert_eq!(e.names(), [".install.lock"]);
    assert_eq!(e.remove(&m).err(), Some(Fail("lock_held")));
    assert_eq!(e.update(&m, Some(true), None).0, fail("lock_held"));
}

#[test]
fn an_unmarked_directory_with_the_version_name_is_a_collision_not_deleted() {
    let e = Env::new(Tw::default());
    let m = e.manifest("test-id-1");
    drop(e.t.root());
    std::fs::create_dir_all(e.root().join("test-id-1")).unwrap();
    std::fs::write(e.root().join("test-id-1/theirs"), "t").unwrap();
    assert_eq!(e.install(&m).0, fail("commit_collision"));
    assert!(e.root().join("test-id-1/theirs").exists());
    assert_eq!(
        e.names()
            .iter()
            .filter(|n| n.starts_with(".staging-"))
            .count(),
        0
    );
    // A marked leftover with that name is cleared and rebuilt.
    std::fs::write(e.root().join("test-id-1").join(OWNED), "m").unwrap();
    assert!(e.install(&m).0.is_ok());
    assert!(!e.root().join("test-id-1/theirs").exists());
}

#[test]
fn the_elf_scan_of_the_staged_files_lists_what_is_missing_and_cleans_up() {
    let e = Env::new(Tw {
        elf_needs: Some(("libnope.so.1", "GLIBC_2.20")),
        ..Tw::default()
    });
    let m = e.manifest("test-id-1");
    let mut f = good_facts();
    f.ld = Some(preflight::parse_ldconfig(
        "\tlibc.so.6 (libc6,x86-64) => /lib/libc.so.6\n",
    ));
    let (r, out, _) = e.install_with(&m, None, f.clone());
    assert_eq!(r, fail("missing_libraries"));
    assert!(out.contains("missing libraries (1): libnope.so.1"), "{out}");
    e.assert_clean_failure("elf scan");
    // The same file with a satisfied need installs; a glibc newer than the host does not.
    let e2 = Env::new(Tw {
        elf_needs: Some(("libc.so.6", "GLIBC_2.99")),
        ..Tw::default()
    });
    let (r, _, _) = e2.install_with(&e2.manifest("test-id-1"), None, f.clone());
    assert_eq!(r, fail("glibc_too_old"));
    e2.assert_clean_failure("glibc too old");
    let e3 = Env::new(Tw {
        elf_needs: Some(("libc.so.6", "GLIBC_2.20")),
        ..Tw::default()
    });
    assert!(e3
        .install_with(&e3.manifest("test-id-1"), None, f)
        .0
        .is_ok());
}

// ---- update ---------------------------------------------------------------------------------

#[test]
fn update_is_prompted_keeps_the_old_version_on_failure_and_cleans_up_later() {
    let e = Env::new(Tw::default());
    let m1 = e.manifest("test-id-1");
    let m2 = e.manifest("test-id-2");
    assert!(e.install(&m1).0.is_ok());
    let record_before = std::fs::read(e.root().join("install.json")).unwrap();
    let conns = e.net.conns();

    // No terminal and no --yes: refused, nothing changes, nothing downloaded.
    let (r, out, _) = e.update(&m2, None, None);
    assert_eq!(r, fail("confirmation_required"));
    assert!(out.contains("Installed: test-id-1") && out.contains("test-id-2"));
    assert_eq!(e.net.conns(), conns);
    assert_eq!(e.update(&m2, Some(false), None).0, fail("declined"));
    assert_eq!(e.net.conns(), conns);
    assert_eq!(
        std::fs::read(e.root().join("install.json")).unwrap(),
        record_before
    );

    // A failing health check keeps the old version serving, record and directory untouched.
    for mode in ["bad_name", "die", "npm_fail"] {
        e.set_mode(mode);
        let (r, _, _) = e.update(&m2, Some(true), None);
        assert!(r.is_err(), "{mode}");
        assert_eq!(
            std::fs::read(e.root().join("install.json")).unwrap(),
            record_before,
            "{mode}"
        );
        assert!(
            e.root().join("test-id-1").is_dir() && !e.root().join("test-id-2").exists(),
            "{mode}"
        );
        assert!(!e.root().join("pending-cleanup.json").exists(), "{mode}");
        assert_eq!(
            e.names()
                .iter()
                .filter(|n| n.starts_with(".staging-"))
                .count(),
            0,
            "{mode}"
        );
        assert_eq!(e.status(&m2).state, "installed");
    }

    // A good one switches over, remembers the previous version and leaves it in place.
    e.set_mode("ok");
    let (r, out, _) = e.update(&m2, Some(true), None);
    assert_eq!(
        r,
        Ok(Done::Updated {
            from: "test-id-1".into(),
            to: "test-id-2".into()
        }),
        "{out}"
    );
    let rec = InstallRecord::parse(&std::fs::read(e.root().join("install.json")).unwrap()).unwrap();
    assert_eq!(
        (rec.version.as_str(), rec.previous.as_deref()),
        ("test-id-2", Some("test-id-1"))
    );
    assert!(e.root().join("test-id-1").is_dir() && e.root().join("test-id-2").is_dir());
    let pending = std::fs::read_to_string(e.root().join("pending-cleanup.json")).unwrap();
    assert_eq!(pending, r#"{"previous":"test-id-1","schema":1}"#);
    assert!(!pending.contains("http"));
    let s = e.status(&m2);
    assert_eq!(
        (
            s.installed_id.as_deref(),
            s.previous.as_deref(),
            s.pending_cleanup.as_deref()
        ),
        (Some("test-id-2"), Some("test-id-1"), Some("test-id-1"))
    );
    assert_eq!(s.update_available, Some(false));
    // The profile and its data survive an update.
    assert!(e.root().join("profile").join(OWNED_DATA).exists());

    // Later, the cleanup removes the previous version and only that.
    let root = Root::open(&e.t.base(), false).unwrap().unwrap();
    assert_eq!(
        state::run_pending_cleanup(&root).unwrap(),
        Some("test-id-1".into())
    );
    assert!(!e.root().join("test-id-1").exists() && e.root().join("test-id-2").is_dir());

    // Updating again to the same id is a no-op.
    assert_eq!(
        e.update(&m2, Some(true), None).0,
        Ok(Done::AlreadyUpToDate("test-id-2".into()))
    );
}

#[test]
fn update_without_an_install_says_so() {
    let e = Env::new(Tw::default());
    let m = e.manifest("test-id-2");
    assert_eq!(e.update(&m, Some(true), None).0, fail("not_installed"));
    assert!(
        !e.t.base().join("oab-computer").exists(),
        "update does not create the root"
    );
}

#[test]
fn an_update_that_cannot_record_removes_only_what_it_added() {
    let e = Env::new(Tw::default());
    let m1 = e.manifest("test-id-1");
    let m2 = e.manifest("test-id-2");
    assert!(e.install(&m1).0.is_ok());
    let before = std::fs::read(e.root().join("install.json")).unwrap();
    // The record write replaces, so plant something that makes the *rename* fail instead: a
    // directory named like the temp target cannot be known, so use the pre-commit hook point and
    // remove the old record to make the compare fail.
    AFTER_RENAME.with(|h| {
        *h.borrow_mut() = Some(Box::new(|root: &Root| {
            // Make `install.json` a non-empty directory: the rename onto it fails.
            let p = root.display_path().join("install.json");
            std::fs::remove_file(&p).unwrap();
            std::fs::create_dir(&p).unwrap();
            std::fs::write(p.join("x"), "x").unwrap();
        }));
    });
    let (r, _, _) = e.update(&m2, Some(true), None);
    AFTER_RENAME.with(|h| *h.borrow_mut() = None);
    assert!(r.is_err());
    assert!(
        !e.root().join("test-id-2").exists(),
        "the new version directory is removed"
    );
    assert!(
        e.root().join("test-id-1").is_dir(),
        "the old version is untouched"
    );
    assert!(e.root().join("profile").is_dir() && e.root().join("output").is_dir());
    assert!(!before.is_empty());
}

#[test]
fn a_foreign_record_planted_at_the_last_moment_of_an_update_is_not_overwritten() {
    let e = Env::new(Tw::default());
    let m1 = e.manifest("test-id-1");
    let m2 = e.manifest("test-id-2");
    assert!(e.install(&m1).0.is_ok());
    crate::state::BEFORE_SWAP.with(|h| {
        *h.borrow_mut() = Some(Box::new(|p: &std::path::Path| {
            std::fs::remove_file(p.join("install.json")).unwrap();
            std::fs::write(p.join("install.json"), "foreign").unwrap();
        }));
    });
    let (r, _, _) = e.update(&m2, Some(true), None);
    crate::state::BEFORE_SWAP.with(|h| *h.borrow_mut() = None);
    assert_eq!(r.err().map(|f| f.0), Some("record_changed"));
    assert_eq!(
        std::fs::read(e.root().join("install.json")).unwrap(),
        b"foreign"
    );
    assert!(!e.root().join("test-id-2").exists());
    assert!(e.root().join("test-id-1").is_dir());
    assert!(!e.root().join("pending-cleanup.json").exists());
    assert!(e
        .names()
        .iter()
        .all(|n| !n.contains(".tmp-") && !n.starts_with(".staging-")));
}

#[test]
fn an_existing_pending_record_is_never_replaced_by_an_update() {
    let e = Env::new(Tw::default());
    let m1 = e.manifest("test-id-1");
    let m2 = e.manifest("test-id-2");
    assert!(e.install(&m1).0.is_ok());
    std::fs::write(e.root().join("pending-cleanup.json"), "foreign").unwrap();
    let (r, out, _) = e.update(&m2, Some(true), None);
    assert!(r.is_ok());
    assert_eq!(
        std::fs::read(e.root().join("pending-cleanup.json")).unwrap(),
        b"foreign"
    );
    assert!(out.contains("left in place: test-id-1"));
    assert!(e.root().join("test-id-1").is_dir());
}

// ---- remove ---------------------------------------------------------------------------------

#[test]
fn remove_deletes_what_it_made_and_reports_what_it_left() {
    let e = Env::new(Tw::default());
    let m = e.manifest("test-id-1");
    assert!(e.install(&m).0.is_ok());
    std::fs::write(e.root().join("foreign.txt"), "f").unwrap();
    std::fs::create_dir_all(e.root().join("foreign-profile")).unwrap();
    std::fs::write(e.root().join("foreign-profile/cookies"), "c").unwrap();
    let rem = e.remove(&m).unwrap().unwrap();
    for gone in [
        "install.json",
        "test-id-1",
        "profile",
        "output",
        "home",
        "run",
    ] {
        assert!(!e.root().join(gone).exists(), "{gone}");
        assert!(
            rem.report.removed.contains(&gone.to_string()),
            "{gone} reported removed"
        );
    }
    assert_eq!(std::fs::read(e.root().join("foreign.txt")).unwrap(), b"f");
    assert_eq!(
        std::fs::read(e.root().join("foreign-profile/cookies")).unwrap(),
        b"c"
    );
    let left: Vec<&str> = rem.report.left.iter().map(|(n, _)| n.as_str()).collect();
    assert!(
        left.contains(&"foreign.txt")
            && left.contains(&"foreign-profile")
            && left.contains(&".install.lock"),
        "{left:?}"
    );
    assert!(!rem.report.failed);
    assert_eq!(
        e.names(),
        [".install.lock", "foreign-profile", "foreign.txt"]
    );
    // Idempotent, and status says not installed.
    assert!(e.remove(&m).unwrap().unwrap().report.removed.is_empty());
    assert_eq!(e.status(&m).state, "not_installed");
    // Without a root there is nothing to do and nothing is created.
    let e2 = Env::new(Tw::default());
    assert!(e2.remove(&e2.manifest("x-1")).unwrap().is_none());
    assert!(!e2.t.base().join("oab-computer").exists());
}

// ---- --from-dir -----------------------------------------------------------------------------

fn offline_dir(e: &Env) -> PathBuf {
    let d = e.t.path.join("pre-fetched");
    std::fs::create_dir_all(&d).unwrap();
    std::fs::write(d.join("node-test.tar.gz"), &e.node_tgz).unwrap();
    std::fs::write(d.join("chrome-test.zip"), &e.chrome_zip).unwrap();
    for (n, b) in &e.npm {
        std::fs::write(d.join(n), b).unwrap();
    }
    d
}

#[test]
fn from_dir_installs_without_any_connection_and_runs_npm_offline() {
    let e = Env::new(Tw::default());
    let m = e.manifest("test-id-1");
    let d = offline_dir(&e);
    let (r, out, err) = e.install_with(&m, Some(&d), good_facts());
    assert_eq!(r, Ok(Done::Installed("test-id-1".into())), "{out}{err}");
    assert!(
        !out.contains("Downloads about") && !out.contains("internet connection"),
        "{out}"
    );
    assert!(out.contains("Nothing is downloaded"), "{out}");
    assert!(
        err.contains("copying and checking") && !err.contains("downloading"),
        "{err}"
    );
    assert_eq!(e.net.conns(), 0, "the download server saw a connection");
    assert_eq!(e.registry.conns(), 0, "the registry saw a connection");
    let log = std::fs::read_to_string(&e.log).unwrap();
    assert_eq!(log.matches(" cache add ").count(), 3, "{log}");
    let ci = log.lines().find(|l| l.contains(" ci ")).unwrap();
    assert!(ci.contains("--offline"), "{ci}");
    assert!(log
        .lines()
        .filter(|l| l.contains(" cache add "))
        .all(|l| l.contains("--offline")));
    // The files in the directory are untouched.
    assert_eq!(
        std::fs::read(d.join("node-test.tar.gz")).unwrap(),
        e.node_tgz
    );
}

#[test]
fn from_dir_rejects_a_bad_file_before_it_is_used_and_cleans_up() {
    #[allow(clippy::type_complexity)]
    let breakers: Vec<(&str, Box<dyn Fn(&Path)>, &str)> = vec![
        (
            "flipped byte in node",
            Box::new(|d| {
                let mut b = std::fs::read(d.join("node-test.tar.gz")).unwrap();
                let n = b.len() / 2;
                b[n] ^= 1;
                std::fs::write(d.join("node-test.tar.gz"), b).unwrap();
            }),
            "digest_mismatch",
        ),
        (
            "short chromium",
            Box::new(|d| {
                let b = std::fs::read(d.join("chrome-test.zip")).unwrap();
                std::fs::write(d.join("chrome-test.zip"), &b[..b.len() - 5]).unwrap();
            }),
            "size_mismatch",
        ),
        (
            "long chromium",
            Box::new(|d| {
                let mut b = std::fs::read(d.join("chrome-test.zip")).unwrap();
                b.extend_from_slice(b"extra");
                std::fs::write(d.join("chrome-test.zip"), b).unwrap();
            }),
            "too_large",
        ),
        (
            "symlink",
            Box::new(|d| {
                let real = d.join("real.zip");
                std::fs::rename(d.join("chrome-test.zip"), &real).unwrap();
                std::os::unix::fs::symlink(&real, d.join("chrome-test.zip")).unwrap();
            }),
            "io",
        ),
        (
            "directory",
            Box::new(|d| {
                std::fs::remove_file(d.join("chrome-test.zip")).unwrap();
                std::fs::create_dir(d.join("chrome-test.zip")).unwrap();
            }),
            "io",
        ),
        (
            "fifo",
            Box::new(|d| {
                std::fs::remove_file(d.join("node-test.tar.gz")).unwrap();
                assert!(std::process::Command::new("mkfifo")
                    .arg(d.join("node-test.tar.gz"))
                    .status()
                    .unwrap()
                    .success());
            }),
            "io",
        ),
        (
            "missing",
            Box::new(|d| std::fs::remove_file(d.join("chrome-test.zip")).unwrap()),
            "io",
        ),
        (
            "npm tarball with another digest",
            Box::new(|d| {
                let mut b = std::fs::read(d.join("playwright-1.tgz")).unwrap();
                b[0] ^= 1;
                std::fs::write(d.join("playwright-1.tgz"), b).unwrap();
            }),
            "digest_mismatch",
        ),
        (
            "oversize npm tarball",
            Box::new(|d| std::fs::write(d.join("mcp-1.tgz"), vec![1u8; 100_000]).unwrap()),
            "too_large",
        ),
    ];
    for (what, breaker, class) in breakers {
        let e = Env::new(Tw::default());
        let d = offline_dir(&e);
        breaker(&d);
        let m = e.manifest("test-id-1");
        let (r, out, err) = e.install_with(&m, Some(&d), good_facts());
        assert_eq!(r, fail(class), "{what}\n{out}\n{err}");
        e.assert_clean_failure(what);
        assert_eq!(
            e.net.conns() + e.registry.conns(),
            0,
            "{what}: a connection was made"
        );
    }
}

#[test]
fn from_dir_update_also_uses_no_network() {
    let e = Env::new(Tw::default());
    let d = offline_dir(&e);
    assert!(e
        .install_with(&e.manifest("test-id-1"), Some(&d), good_facts())
        .0
        .is_ok());
    let (r, _, _) = e.update(&e.manifest("test-id-2"), Some(true), Some(&d));
    assert!(r.is_ok());
    assert_eq!(e.net.conns() + e.registry.conns(), 0);
}

#[test]
fn lockfile_tarballs_are_read_from_the_lockfile() {
    let e = Env::new(Tw::default());
    let t = lockfile_tarballs(&e.lock_json).unwrap();
    let names: Vec<&str> = t.iter().map(|(n, _)| n.as_str()).collect();
    assert_eq!(
        names,
        ["mcp-1.tgz", "playwright-1.tgz", "playwright-core-1.tgz"]
    );
    assert!(lockfile_tarballs("{}").is_err());
    assert!(lockfile_tarballs(r#"{"packages":{"":{}}}"#).is_err());
    let dup = r#"{"packages":{"a":{"resolved":"https://r.example/x/-/a.tgz","integrity":"sha512-AAAA"},"b":{"resolved":"https://r.example/y/-/a.tgz","integrity":"sha512-AAAA"}}}"#;
    assert!(lockfile_tarballs(dup).is_err());
    let sha1 = format!(
        r#"{{"packages":{{"a":{{"resolved":"https://r.example/x/-/a.tgz","integrity":"sha1-{}"}}}}}}"#,
        "AAAA"
    );
    assert!(lockfile_tarballs(&sha1).is_err());
}

// ---- real pins ------------------------------------------------------------------------------

#[test]
fn the_embedded_manifest_passes_its_own_validation_for_both_linux_platforms() {
    let m = Manifest::embedded();
    assert!(m.validate().is_empty());
    assert!(m
        .validate_embedded_files(
            crate::manifest::PACKAGE_JSON,
            crate::manifest::LOCKFILE_JSON
        )
        .is_empty());
    assert!(m.platform_policy_problems().is_empty());
    for p in [PlatformId::LinuxArm64, PlatformId::LinuxX64] {
        let sel = m.select(Some(p)).unwrap();
        assert!(chromium_exe(&sel).is_ok());
        assert!(consent::disk_needed(m, &sel) > consent::download_bytes(m, &sel));
    }
    let t = lockfile_tarballs(crate::manifest::LOCKFILE_JSON).unwrap();
    assert_eq!(t.len(), 3);
    for (n, _) in t {
        assert!(n.ends_with(".tgz"));
    }
}

#[test]
fn the_selection_check_refuses_a_bad_manifest_when_checking_is_on() {
    let e = Env::new(Tw::default());
    let m = e.manifest("test-id-1");
    // The fixture uses loopback http, which the production validator refuses.
    let policy = DownloadPolicy::for_tests(&["127.0.0.1"]);
    let facts = |_: &Path| good_facts();
    let o = Opts {
        manifest: &m,
        files: Files {
            package_json: &e.pkg_json,
            lockfile: &e.lock_json,
        },
        source: Source::Network(&policy),
        check_manifest: true,
        limits: download::Limits::default(),
        timeouts: health::Timeouts::default(),
        npm_timeout: Duration::from_secs(1),
        lock_wait: Duration::from_millis(10),
        base: e.t.base(),
        home: None,
        platform: Some(PlatformId::LinuxX64),
        facts: &facts,
        launcher: &crate::sigstop::Plain,
        extras: &|_: &Path, _: bool| crate::probe::Extras::none(),
    };
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let r = install(
        &o,
        &mut Io {
            out: &mut out,
            err: &mut err,
        },
    );
    assert_eq!(r, fail("manifest_invalid"));
    assert!(!e.t.base().exists() || !e.t.base().join("oab-computer").exists());
    let mut o2 = o;
    o2.platform = Some(PlatformId::DarwinArm64);
    o2.check_manifest = false;
    assert_eq!(
        install(
            &o2,
            &mut Io {
                out: &mut out,
                err: &mut err
            }
        ),
        fail("unsupported_platform")
    );
}
