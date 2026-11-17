//! State, ownership, lock and delete-walker tests. Everything runs below a per-test temp
//! directory; a sentinel outside the root must survive every refusal.

use super::*;
use std::os::unix::fs::{symlink, PermissionsExt};

/// A temp directory removed on drop. `base` is where `oab-computer/playwright` goes; `outside`
/// holds the sentinel that no operation may touch.
pub(crate) struct TempDir {
    pub path: PathBuf,
}

impl TempDir {
    pub fn new() -> TempDir {
        let p = std::env::temp_dir().join(format!("l1b-{}", random_hex(8)));
        std::fs::create_dir_all(&p).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o700)).unwrap();
        TempDir { path: p }
    }
    pub fn base(&self) -> PathBuf {
        self.path.join("base")
    }
    pub fn root(&self) -> Root {
        Root::open(&self.base(), true).unwrap().unwrap()
    }
    /// A directory outside the root with a file that must stay unchanged.
    pub fn sentinel(&self) -> (PathBuf, PathBuf) {
        let d = self.path.join("outside");
        std::fs::create_dir_all(&d).unwrap();
        let f = d.join("sentinel");
        std::fs::write(&f, b"keep").unwrap();
        (d, f)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

pub(crate) fn assert_sentinel(f: &Path) {
    assert_eq!(std::fs::read(f).unwrap(), b"keep", "sentinel changed");
}

fn rootp(t: &TempDir) -> PathBuf {
    t.base().join("oab-computer/playwright")
}

fn put(p: &Path, content: &str) {
    if let Some(d) = p.parent() {
        std::fs::create_dir_all(d).unwrap();
    }
    std::fs::write(p, content).unwrap();
}

/// A version directory that looks like a complete install.
fn make_version(t: &TempDir, id: &str, marked: bool) {
    let v = rootp(t).join(id);
    put(&v.join("node/bin/node"), "n");
    put(&v.join("pkg/node_modules/@playwright/mcp/cli.js"), "c");
    put(&v.join("chromium/chrome-x/chrome"), "x");
    for f in ["node/bin/node", "chromium/chrome-x/chrome"] {
        std::fs::set_permissions(v.join(f), std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    if marked {
        put(&v.join(OWNED), "m");
    }
    // The umask of the host must not decide the test: the installer's own directories are 0700.
    std::fs::set_permissions(&v, std::fs::Permissions::from_mode(0o700)).unwrap();
}

fn record(id: &str) -> InstallRecord {
    InstallRecord {
        manifest_id: id.into(),
        version: id.into(),
        platform: "linux-arm64".into(),
        chromium_executable: "chrome-x/chrome".into(),
        chromium_revision: "1".into(),
        chromium_released_at: "2026-01-01".into(),
        installed_at: "2026-01-01T00:00:00Z".into(),
        previous: None,
        digests: BTreeMap::new(),
    }
}

fn write_record_file(t: &TempDir, rec: &InstallRecord) {
    put(&rootp(t).join(RECORD_NAME), &rec.to_json());
}

fn data_dir(t: &TempDir, name: &str, marked: bool) {
    let d = rootp(t).join(name);
    std::fs::create_dir_all(&d).unwrap();
    put(&d.join("payload"), "p");
    if marked {
        put(&d.join(OWNED_DATA), "m");
    }
    std::fs::set_permissions(&d, std::fs::Permissions::from_mode(0o700)).unwrap();
}

fn exists(p: &Path) -> bool {
    p.symlink_metadata().is_ok()
}

#[test]
fn remove_deletes_only_exact_generated_temp_files_with_record_content() {
    let t = TempDir::new();
    let root = t.root();
    make_version(&t, "id-1", true);
    write_record_file(&t, &record("id-1"));
    let rec = record("id-1").to_json();
    let ours = [
        ("install.json.tmp-0123456789abcdef", rec.clone()),
        (
            "pending-cleanup.json.tmp-fedcba9876543210",
            pending_json("old-1"),
        ),
    ];
    let foreign = [
        ("install.json.tmp-notes", "my notes".to_string()),
        ("install.json.tmp-0123456789ABCDEF", rec.clone()),
        ("install.json.tmp-0123456789abcde", rec.clone()),
        ("install.json.tmp-0123456789abcdef0", rec.clone()),
        ("install.json.tmp-aaaaaaaaaaaaaaaa", "not json".to_string()),
        ("install.json.tmp-bbbbbbbbbbbbbbbb", pending_json("old-1")),
        ("pending-cleanup.json.tmp-cccccccccccccccc", rec.clone()),
        (
            "pending-cleanup.json.tmp-dddddddddddddddd",
            "{\"schema\":1,\"previous\":\"../x\"}".to_string(),
        ),
    ];
    for (n, c) in ours.iter().chain(foreign.iter()) {
        put(&rootp(&t).join(n), c);
    }
    let rep = remove_all(&root).unwrap();
    for (n, _) in &ours {
        assert!(!exists(&rootp(&t).join(n)), "{n} should be removed");
    }
    for (n, c) in &foreign {
        assert_eq!(
            std::fs::read_to_string(rootp(&t).join(n)).unwrap(),
            *c,
            "{n} must stay"
        );
        assert!(rep.left.iter().any(|(l, _)| l == n), "{n} reported");
    }
}

#[test]
fn the_root_is_created_private_and_reopened() {
    let t = TempDir::new();
    assert!(Root::open(&t.base(), false).unwrap().is_none());
    let r = Root::open(&t.base(), true).unwrap().unwrap();
    for p in [t.base().join("oab-computer"), rootp(&t)] {
        let m = std::fs::metadata(&p).unwrap().permissions().mode() & 0o777;
        assert_eq!(m, 0o700, "{p:?}");
    }
    drop(r);
    assert!(Root::open(&t.base(), false).unwrap().is_some());
}

#[test]
fn a_symlinked_root_component_stops_everything() {
    for which in ["oab-computer", "playwright"] {
        let t = TempDir::new();
        let (out, sentinel) = t.sentinel();
        let base = t.base();
        std::fs::create_dir_all(&base).unwrap();
        if which == "oab-computer" {
            symlink(&out, base.join("oab-computer")).unwrap();
        } else {
            std::fs::create_dir_all(base.join("oab-computer")).unwrap();
            symlink(&out, base.join("oab-computer/playwright")).unwrap();
        }
        for create in [true, false] {
            let r = Root::open(&base, create);
            assert_eq!(
                r.err(),
                Some(Fail("root_not_directory")),
                "{which} create={create}"
            );
        }
        assert_sentinel(&sentinel);
        assert_eq!(
            std::fs::read_dir(&out).unwrap().count(),
            1,
            "nothing was created through the link"
        );
    }
}

#[test]
fn a_root_writable_by_others_or_foreign_is_refused() {
    let t = TempDir::new();
    drop(t.root());
    std::fs::set_permissions(rootp(&t), std::fs::Permissions::from_mode(0o770)).unwrap();
    assert_eq!(
        Root::open(&t.base(), false).err(),
        Some(Fail("root_not_directory"))
    );
    std::fs::set_permissions(rootp(&t), std::fs::Permissions::from_mode(0o700)).unwrap();
    assert!(Root::open(&t.base(), false).unwrap().is_some());
}

#[test]
fn xdg_data_home_must_be_absolute() {
    // The function reads the process environment, so only check the parts that do not depend on it.
    assert!(Root::default_base()
        .map(|p| p.is_absolute())
        .unwrap_or(true));
}

#[test]
fn markers_decide_what_remove_deletes_and_it_says_what_it_left() {
    let t = TempDir::new();
    let (_, sentinel) = t.sentinel();
    let root = t.root();
    make_version(&t, "ours-1", true);
    write_record_file(&t, &record("ours-1"));
    make_version(&t, "unmarked", false);
    data_dir(&t, "profile", true);
    data_dir(&t, "output", false); // looks like ours, carries no marker
    put(&rootp(&t).join("foreign.txt"), "f");
    std::fs::create_dir_all(rootp(&t).join("foreign-dir")).unwrap();
    put(&rootp(&t).join("foreign-dir/x"), "x");
    // Marker that is a directory, and a marker that is a symlink, do not count.
    let v = rootp(&t).join("fakemark");
    std::fs::create_dir_all(v.join(OWNED)).unwrap();
    let v2 = rootp(&t).join("linkmark");
    std::fs::create_dir_all(&v2).unwrap();
    symlink(&sentinel, v2.join(OWNED)).unwrap();

    let _lock = Lock::acquire(&root, Duration::from_millis(0)).unwrap();
    let rep = remove_all(&root).unwrap();
    assert!(!exists(&rootp(&t).join("ours-1")));
    assert!(!exists(&rootp(&t).join(RECORD_NAME)));
    assert!(!exists(&rootp(&t).join("profile")));
    for kept in [
        "unmarked",
        "output",
        "foreign.txt",
        "foreign-dir",
        "fakemark",
        "linkmark",
        LOCK_NAME,
    ] {
        assert!(exists(&rootp(&t).join(kept)), "{kept} must stay");
    }
    assert!(rootp(&t).join("output/payload").exists());
    assert_sentinel(&sentinel);
    let left: Vec<&str> = rep.left.iter().map(|(n, _)| n.as_str()).collect();
    for n in [
        "unmarked",
        "output",
        "foreign.txt",
        "foreign-dir",
        "fakemark",
        "linkmark",
        LOCK_NAME,
    ] {
        assert!(
            left.contains(&n),
            "{n} is reported as left in place: {left:?}"
        );
    }
    assert!(rep.removed.contains(&"ours-1".to_string()));
    assert!(!rep.failed);
    // Idempotent: a second run finds nothing marked and removes nothing.
    let again = remove_all(&root).unwrap();
    assert!(again.removed.is_empty());
}

#[test]
fn a_foreign_or_unreadable_install_record_keeps_the_profile_but_marked_versions_go() {
    for kind in [
        "foreign",
        "oversize",
        "garbage",
        "unowned_version",
        "mismatch",
    ] {
        let t = TempDir::new();
        let root = t.root();
        make_version(&t, "ours-1", true);
        data_dir(&t, "profile", true);
        let p = rootp(&t).join(RECORD_NAME);
        match kind {
            "foreign" => put(&p, r#"{"hello":"world"}"#),
            "oversize" => put(&p, &"x".repeat(70_000)),
            "garbage" => put(&p, "not json"),
            "unowned_version" => {
                make_version(&t, "theirs", false);
                put(&p, &record("theirs").to_json());
            }
            _ => {
                let mut r = record("ours-1");
                r.manifest_id = "other".into();
                put(&p, &r.to_json());
            }
        }
        let before = std::fs::read(&p).unwrap();
        let st = read_state(&root).unwrap();
        assert!(matches!(st, State::Foreign(_)), "{kind}: {st:?}");
        let rep = remove_all(&root).unwrap();
        assert_eq!(
            std::fs::read(&p).unwrap(),
            before,
            "{kind}: record untouched"
        );
        assert!(
            rootp(&t).join("profile/payload").exists(),
            "{kind}: profile untouched"
        );
        assert!(
            !exists(&rootp(&t).join("ours-1")),
            "{kind}: a marked version directory still goes"
        );
        assert!(rep.left.iter().any(|(n, _)| n == "profile"), "{kind}");
        assert!(rep.left.iter().any(|(n, _)| n == RECORD_NAME), "{kind}");
    }
}

#[test]
fn symlinks_below_the_root_are_never_followed_or_deleted_through() {
    let t = TempDir::new();
    let (out, sentinel) = t.sentinel();
    let root = t.root();
    make_version(&t, "ours-1", true);
    write_record_file(&t, &record("ours-1"));
    // profile is a link to the outside; a version-shaped name is a link; a link inside a version.
    symlink(&out, rootp(&t).join("profile")).unwrap();
    symlink(&out, rootp(&t).join("linked-version")).unwrap();
    symlink(&out, rootp(&t).join("ours-1/pkg/escape")).unwrap();
    symlink(&sentinel, rootp(&t).join("ours-1/node/file-link")).unwrap();
    let rep = remove_all(&root).unwrap();
    assert_sentinel(&sentinel);
    assert!(out.exists());
    assert!(
        exists(&rootp(&t).join("profile")),
        "a linked profile is left"
    );
    assert!(exists(&rootp(&t).join("linked-version")));
    assert!(
        !exists(&rootp(&t).join("ours-1")),
        "links inside an owned tree go as links"
    );
    assert!(rep.left.iter().any(|(n, _)| n == "profile"));
}

#[test]
fn a_symlink_swapped_in_while_removing_is_unlinked_as_a_link() {
    let t = TempDir::new();
    let (out, sentinel) = t.sentinel();
    let root = t.root();
    make_version(&t, "ours-1", true);
    let target = rootp(&t).join("ours-1/node");
    let mut rep = Report::default();
    let mut swapped = false;
    let tp = target.clone();
    let o = out.clone();
    let mut hook = |n: &str| {
        if n == "node" && !swapped {
            swapped = true;
            std::fs::remove_dir_all(&tp).unwrap();
            symlink(&o, &tp).unwrap();
        }
    };
    let gone =
        remove_marked_tree_with_hook(root.fd(), "ours-1", OWNED, &mut rep, &mut hook).unwrap();
    assert!(gone);
    assert_sentinel(&sentinel);
    assert!(out.exists());
    assert!(!exists(&rootp(&t).join("ours-1")));
}

#[test]
fn a_directory_swapped_for_a_link_after_the_check_is_not_followed() {
    // The top-level name is replaced between the `lstat` and the `open`: `O_NOFOLLOW` refuses.
    let t = TempDir::new();
    let (out, sentinel) = t.sentinel();
    let root = t.root();
    make_version(&t, "ours-1", true);
    std::fs::rename(rootp(&t).join("ours-1"), t.path.join("moved")).unwrap();
    symlink(&out, rootp(&t).join("ours-1")).unwrap();
    let mut rep = Report::default();
    let gone = remove_marked_tree(root.fd(), "ours-1", OWNED, &mut rep).unwrap();
    assert!(!gone);
    assert_sentinel(&sentinel);
    assert!(exists(&rootp(&t).join("ours-1")));
}

#[test]
fn depth_is_capped() {
    let t = TempDir::new();
    let root = t.root();
    let mut p = rootp(&t).join("deep");
    std::fs::create_dir_all(&p).unwrap();
    put(&p.join(OWNED), "m");
    for _ in 0..80 {
        p = p.join("d");
    }
    std::fs::create_dir_all(&p).unwrap();
    let mut rep = Report::default();
    let gone = remove_marked_tree(root.fd(), "deep", OWNED, &mut rep).unwrap();
    assert!(!gone);
    assert!(
        rep.left
            .iter()
            .any(|(n, why)| n == "deep" && why.contains("deep")),
        "{:?}",
        rep.left
    );
    assert!(
        exists(&rootp(&t).join("deep")),
        "an incomplete removal keeps the marked top directory"
    );
    assert!(
        rootp(&t).join("deep").join(OWNED).exists(),
        "and its marker, so a repeat can finish"
    );
}

#[test]
fn staging_without_a_marker_is_never_swept() {
    let t = TempDir::new();
    let root = t.root();
    let ok = format!("{STAGING_PREFIX}{}", "a".repeat(32));
    let unmarked = format!("{STAGING_PREFIX}{}", "b".repeat(32));
    let lookalike = format!("{STAGING_PREFIX}zzz");
    for (n, marked) in [(&ok, true), (&unmarked, false), (&lookalike, true)] {
        put(&rootp(&t).join(n).join("f"), "x");
        if marked {
            put(&rootp(&t).join(n).join(STAGING_MARK), "m");
        }
    }
    let rep = sweep_staging(&root).unwrap();
    assert!(!exists(&rootp(&t).join(&ok)));
    assert!(exists(&rootp(&t).join(&unmarked)));
    assert!(exists(&rootp(&t).join(&lookalike)));
    assert_eq!(rep.removed, [ok]);
}

#[test]
fn the_lock_excludes_a_second_holder_and_the_file_is_never_unlinked() {
    let t = TempDir::new();
    let root = t.root();
    let lock = Lock::acquire(&root, Duration::from_millis(0)).unwrap();
    let ino = std::fs::metadata(rootp(&t).join(LOCK_NAME)).unwrap();
    let root2 = Root::open(&t.base(), false).unwrap().unwrap();
    assert_eq!(
        Lock::acquire(&root2, Duration::from_millis(150)).err(),
        Some(Fail("lock_held"))
    );
    drop(lock);
    // Not at once: a `flock` is released when the last copy of the descriptor closes, and another
    // test thread's fork can hold a copy for a moment before its exec.
    let l2 = Lock::acquire(&root2, Duration::from_secs(5)).unwrap();
    // remove deletes everything it owns and leaves the lock file, the same inode.
    make_version(&t, "ours-1", true);
    write_record_file(&t, &record("ours-1"));
    remove_all(&root2).unwrap();
    drop(l2);
    use std::os::unix::fs::MetadataExt;
    let after = std::fs::metadata(rootp(&t).join(LOCK_NAME)).unwrap();
    assert_eq!(after.ino(), ino.ino());
    assert_eq!(after.dev(), ino.dev());
}

#[test]
fn a_lock_file_that_is_a_symlink_is_refused() {
    let t = TempDir::new();
    let (_, sentinel) = t.sentinel();
    let root = t.root();
    symlink(&sentinel, rootp(&t).join(LOCK_NAME)).unwrap();
    assert!(Lock::acquire(&root, Duration::from_millis(0)).is_err());
    assert_sentinel(&sentinel);
}

#[test]
fn reads_are_capped_and_only_regular_files() {
    let t = TempDir::new();
    let root = t.root();
    let (_, sentinel) = t.sentinel();
    put(&rootp(&t).join("big"), &"x".repeat(5000));
    assert!(read_file_capped(root.fd(), "big", 4096).is_err());
    assert_eq!(
        read_file_capped(root.fd(), "big", 5000).unwrap().len(),
        5000
    );
    symlink(&sentinel, rootp(&t).join("lnk")).unwrap();
    assert!(read_file_capped(root.fd(), "lnk", 4096).is_err());
    let st = std::process::Command::new("mkfifo")
        .arg(rootp(&t).join("fifo"))
        .status();
    if st.map(|s| s.success()).unwrap_or(false) {
        assert!(
            read_file_capped(root.fd(), "fifo", 4096).is_err(),
            "a FIFO neither hangs nor reads"
        );
    }
    std::fs::create_dir_all(rootp(&t).join("adir")).unwrap();
    assert!(read_file_capped(root.fd(), "adir", 4096).is_err());
}

#[test]
fn records_round_trip_and_reject_unsafe_fields() {
    let mut r = record("mcp1-node2-cr3-abcd1234");
    r.previous = Some("old-1".into());
    r.digests.insert("node".into(), "ab".repeat(32));
    let parsed = InstallRecord::parse(r.to_json().as_bytes()).unwrap();
    assert_eq!(parsed, r);
    let bad = |f: &dyn Fn(&mut Value)| {
        let mut v: Value = serde_json::from_str(&record("id-1").to_json()).unwrap();
        f(&mut v);
        InstallRecord::parse(v.to_string().as_bytes())
    };
    assert!(bad(&|_| {}).is_some());
    assert!(bad(&|v| v["version"] = "../x".into()).is_none());
    assert!(bad(&|v| v["version"] = "a/b".into()).is_none());
    assert!(bad(&|v| v["previous"] = "../x".into()).is_none());
    assert!(bad(&|v| v["chromiumExecutable"] = "/bin/sh".into()).is_none());
    assert!(bad(&|v| v["chromiumExecutable"] = "a/../../b".into()).is_none());
    assert!(bad(&|v| v["chromiumExecutable"] = "".into()).is_none());
    assert!(bad(&|v| v["schema"] = 2.into()).is_none());
    assert!(InstallRecord::parse(b"[]").is_none());
}

#[test]
fn state_is_installed_invalid_or_not_installed() {
    let t = TempDir::new();
    let root = t.root();
    assert_eq!(read_state(&root).unwrap(), State::NotInstalled);
    make_version(&t, "ours-1", true);
    write_record_file(&t, &record("ours-1"));
    assert!(matches!(read_state(&root).unwrap(), State::Installed(_)));
    // Missing payload makes it invalid, still ours.
    std::fs::remove_file(rootp(&t).join("ours-1/pkg/node_modules/@playwright/mcp/cli.js")).unwrap();
    assert!(matches!(read_state(&root).unwrap(), State::Invalid(_)));
    // A binary without the execute bit is invalid too.
    put(
        &rootp(&t).join("ours-1/pkg/node_modules/@playwright/mcp/cli.js"),
        "c",
    );
    std::fs::set_permissions(
        rootp(&t).join("ours-1/node/bin/node"),
        std::fs::Permissions::from_mode(0o644),
    )
    .unwrap();
    assert!(matches!(read_state(&root).unwrap(), State::Invalid(_)));
}

#[test]
fn write_record_replaces_or_refuses() {
    let t = TempDir::new();
    let root = t.root();
    write_record(root.fd(), "x.json", b"1").unwrap();
    assert!(write_record(root.fd(), "x.json", b"2").is_err());
    assert_eq!(std::fs::read(rootp(&t).join("x.json")).unwrap(), b"1");
    write_record_cas(root.fd(), "x.json", b"3", b"1").unwrap();
    assert_eq!(std::fs::read(rootp(&t).join("x.json")).unwrap(), b"3");
    let mode = std::fs::metadata(rootp(&t).join("x.json"))
        .unwrap()
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(mode, 0o600);
    let leftovers: Vec<_> = std::fs::read_dir(rootp(&t))
        .unwrap()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().contains(".tmp-"))
        .collect();
    assert!(leftovers.is_empty(), "a failed write leaves no temp file");
}

#[test]
fn cas_never_overwrites_a_record_that_appeared_after_the_caller_read_it() {
    let t = TempDir::new();
    let root = t.root();
    write_record(root.fd(), "x.json", b"1").unwrap();
    BEFORE_SWAP.with(|h| {
        *h.borrow_mut() = Some(Box::new(|p: &std::path::Path| {
            std::fs::remove_file(p.join("x.json")).unwrap();
            std::fs::write(p.join("x.json"), "foreign").unwrap();
        }));
    });
    let r = write_record_cas(root.fd(), "x.json", b"3", b"1");
    BEFORE_SWAP.with(|h| *h.borrow_mut() = None);
    assert_eq!(r, Err(Fail("record_changed")));
    assert_eq!(std::fs::read(rootp(&t).join("x.json")).unwrap(), b"foreign");
    let leftovers = std::fs::read_dir(rootp(&t))
        .unwrap()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().contains(".tmp-"))
        .count();
    assert_eq!(leftovers, 0);
    // A record that vanished is not recreated by the replace path, and a non-file is put back.
    std::fs::remove_file(rootp(&t).join("x.json")).unwrap();
    assert!(write_record_cas(root.fd(), "x.json", b"3", b"foreign").is_err());
    assert!(!rootp(&t).join("x.json").exists());
    std::fs::create_dir(rootp(&t).join("x.json")).unwrap();
    assert!(write_record_cas(root.fd(), "x.json", b"3", b"foreign").is_err());
    assert!(rootp(&t).join("x.json").is_dir());
}

#[test]
fn pending_cleanup_removes_only_a_marked_previous_that_is_not_current() {
    let t = TempDir::new();
    let root = t.root();
    make_version(&t, "new-2", true);
    let mut r = record("new-2");
    r.previous = Some("old-1".into());
    write_record_file(&t, &r);
    make_version(&t, "old-1", true);
    put(&rootp(&t).join(PENDING_NAME), &pending_json("old-1"));
    assert_eq!(run_pending_cleanup(&root).unwrap(), Some("old-1".into()));
    assert!(!exists(&rootp(&t).join("old-1")));
    assert!(!exists(&rootp(&t).join(PENDING_NAME)));
    assert!(exists(&rootp(&t).join("new-2")));

    // previous equal to the current version is never deleted.
    put(&rootp(&t).join(PENDING_NAME), &pending_json("new-2"));
    assert_eq!(run_pending_cleanup(&root).unwrap(), None);
    assert!(exists(&rootp(&t).join("new-2")));

    // An unmarked previous stays.
    make_version(&t, "old-3", false);
    put(&rootp(&t).join(PENDING_NAME), &pending_json("old-3"));
    assert_eq!(run_pending_cleanup(&root).unwrap(), None);
    assert!(exists(&rootp(&t).join("old-3")));
    assert!(
        exists(&rootp(&t).join(PENDING_NAME)),
        "a refused cleanup keeps the record"
    );

    // A pending record naming a path is ignored.
    put(
        &rootp(&t).join(PENDING_NAME),
        r#"{"schema":1,"previous":"../outside"}"#,
    );
    assert_eq!(run_pending_cleanup(&root).unwrap(), None);
}

#[test]
fn pending_cleanup_waits_until_the_install_can_serve() {
    let t = TempDir::new();
    let root = t.root();
    make_version(&t, "new-2", true);
    write_record_file(&t, &record("new-2"));
    std::fs::remove_file(rootp(&t).join("new-2/node/bin/node")).unwrap();
    make_version(&t, "old-1", true);
    put(&rootp(&t).join(PENDING_NAME), &pending_json("old-1"));
    assert_eq!(run_pending_cleanup(&root).unwrap(), None);
    assert!(
        exists(&rootp(&t).join("old-1")),
        "the old version is the only working one"
    );
}

#[test]
fn a_foreign_pending_record_and_config_are_left() {
    let t = TempDir::new();
    let root = t.root();
    make_version(&t, "ours-1", true);
    write_record_file(&t, &record("ours-1"));
    put(&rootp(&t).join(PENDING_NAME), "not ours");
    put(&rootp(&t).join(CONFIG_NAME), r#"{"launch":1}"#);
    let rep = remove_all(&root).unwrap();
    assert!(exists(&rootp(&t).join(PENDING_NAME)));
    assert!(exists(&rootp(&t).join(CONFIG_NAME)));
    assert!(rep.left.iter().any(|(n, _)| n == CONFIG_NAME));
    // With the key, the config is ours.
    let t2 = TempDir::new();
    let root2 = t2.root();
    make_version(&t2, "ours-1", true);
    write_record_file(&t2, &record("ours-1"));
    put(
        &rootp(&t2).join(CONFIG_NAME),
        r#"{"_oabInstallerOwned":true}"#,
    );
    remove_all(&root2).unwrap();
    assert!(!exists(&rootp(&t2).join(CONFIG_NAME)));
}

#[test]
fn data_directories_are_not_claimed_without_an_install_record_of_ours() {
    let t = TempDir::new();
    let root = t.root();
    data_dir(&t, "profile", true);
    data_dir(&t, "run", true);
    let rep = remove_all(&root).unwrap();
    assert!(rootp(&t).join("profile/payload").exists());
    assert!(rep.left.iter().any(|(n, _)| n == "profile"));
    assert!(rep.removed.is_empty());
}

#[cfg(target_os = "linux")]
#[test]
fn a_live_run_record_blocks_remove_and_a_stale_one_does_not() {
    let t = TempDir::new();
    let root = t.root();
    make_version(&t, "ours-1", true);
    write_record_file(&t, &record("ours-1"));
    data_dir(&t, "run", true);
    let mut child = std::process::Command::new("sleep")
        .arg("30")
        .spawn()
        .unwrap();
    let pid = child.id();
    let start = proc_start_time(pid).expect("start time");
    put(
        &rootp(&t).join("run/a.json"),
        &format!(r#"{{"pid":{pid},"start":{start}}}"#),
    );
    assert_eq!(live_run_records(&root), 1);
    assert_eq!(remove_all(&root).err(), Some(Fail("browser_running")));
    assert!(exists(&rootp(&t).join("ours-1")), "nothing was deleted");
    assert!(exists(&rootp(&t).join(RECORD_NAME)));
    // The same pid with a different start time is a reused pid: stale.
    put(
        &rootp(&t).join("run/a.json"),
        &format!(r#"{{"pid":{pid},"start":{}}}"#, start + 1),
    );
    put(&rootp(&t).join("run/b.json"), "garbage");
    put(&rootp(&t).join("run/c.json"), &"x".repeat(5000));
    assert_eq!(live_run_records(&root), 0);
    child.kill().unwrap();
    child.wait().unwrap();
    let rep = remove_all(&root).unwrap();
    assert!(!exists(&rootp(&t).join("ours-1")));
    assert!(!rep.failed);
}

#[test]
fn time_formatting() {
    assert_eq!(iso8601(0), "1970-01-01T00:00:00Z");
    assert_eq!(iso8601(1_700_000_000), "2023-11-14T22:13:20Z");
    assert_eq!(iso8601(951_782_400), "2000-02-29T00:00:00Z");
    assert!(now_iso8601().ends_with('Z'));
}

#[test]
fn staging_names() {
    let n = new_staging_name();
    assert!(is_staging_name(&n));
    assert!(!is_staging_name(".staging-"));
    assert!(!is_staging_name(&format!(
        "{STAGING_PREFIX}{}",
        "A".repeat(32)
    )));
    assert!(!is_staging_name("staging-aaaa"));
}

#[test]
fn stat_rel_does_not_follow_links_in_the_middle() {
    let t = TempDir::new();
    let root = t.root();
    let (out, _) = t.sentinel();
    put(&rootp(&t).join("v/a/b"), "x");
    assert!(stat_rel(root.fd(), "v/a/b").is_some());
    symlink(&out, rootp(&t).join("v/link")).unwrap();
    assert!(stat_rel(root.fd(), "v/link/sentinel").is_none());
    assert!(stat_rel(root.fd(), "v/../v/a/b").is_none());
    assert!(stat_rel(root.fd(), "/etc/passwd").is_none());
}

/// Puts `content` at `dir/name` as a different object than whatever is there: the new file is
/// created under another name first (so the old inode cannot be reused) and renamed over.
#[cfg(target_os = "linux")]
fn replace_with_foreign(dir: &Path, name: &str, content: &str) {
    let side = dir.join(format!(".side-{}", random_hex(4)));
    std::fs::write(&side, content).unwrap();
    std::fs::rename(&side, dir.join(name)).unwrap();
}

#[cfg(target_os = "linux")]
fn clear_hooks() {
    BEFORE_SWAP.with(|h| *h.borrow_mut() = None);
    AFTER_SWAP.with(|h| *h.borrow_mut() = None);
    BEFORE_UNLINK.with(|h| *h.borrow_mut() = None);
}

#[cfg(target_os = "linux")]
fn tmp_files(t: &TempDir) -> Vec<(String, Vec<u8>)> {
    std::fs::read_dir(rootp(t))
        .unwrap()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().contains(".tmp-"))
        .map(|e| {
            (
                e.file_name().to_string_lossy().into_owned(),
                std::fs::read(e.path()).unwrap(),
            )
        })
        .collect()
}

#[cfg(target_os = "linux")]
#[test]
fn cas_swap_back_never_deletes_a_file_a_third_writer_put_at_the_temp_name() {
    let t = TempDir::new();
    let root = t.root();
    write_record(root.fd(), "x.json", b"1").unwrap();
    // A foreign record replaces x.json, so the exchange displaces it and the check fails.
    BEFORE_SWAP.with(|h| {
        *h.borrow_mut() = Some(Box::new(|p: &Path| {
            replace_with_foreign(p, "x.json", "foreign")
        }));
    });
    // After the exchange a third writer replaces x.json (which holds our new bytes) before the
    // swap back, so the swap back brings the third writer's file to the temp name.
    AFTER_SWAP.with(|h| {
        *h.borrow_mut() = Some(Box::new(|p: &Path| {
            replace_with_foreign(p, "x.json", "third")
        }));
    });
    let r = write_record_cas(root.fd(), "x.json", b"3", b"1");
    clear_hooks();
    assert_eq!(r, Err(Fail("record_changed_left")));
    assert_eq!(std::fs::read(rootp(&t).join("x.json")).unwrap(), b"foreign");
    let left = tmp_files(&t);
    assert_eq!(left.len(), 1, "the third writer's file stays");
    assert_eq!(left[0].1, b"third");
}

#[cfg(target_os = "linux")]
#[test]
fn cas_never_deletes_a_replacement_of_the_displaced_copy() {
    let t = TempDir::new();
    let root = t.root();
    write_record(root.fd(), "x.json", b"1").unwrap();
    // The record verifies, and the displaced copy is replaced just before it is removed.
    BEFORE_UNLINK.with(|h| {
        *h.borrow_mut() = Some(Box::new(|p: &Path| {
            let name = std::fs::read_dir(p)
                .unwrap()
                .flatten()
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .find(|n| n.contains(".tmp-"))
                .unwrap();
            replace_with_foreign(p, &name, "someone else's note");
        }));
    });
    let r = write_record_cas(root.fd(), "x.json", b"3", b"1");
    clear_hooks();
    assert_eq!(r, Ok(()));
    assert_eq!(std::fs::read(rootp(&t).join("x.json")).unwrap(), b"3");
    let left = tmp_files(&t);
    assert_eq!(left.len(), 1);
    assert_eq!(left[0].1, b"someone else's note");
}

#[cfg(target_os = "linux")]
#[test]
fn unlink_if_same_leaves_a_replacement_and_a_link() {
    let t = TempDir::new();
    let root = t.root();
    let id = write_new_file_id(root.fd(), "a", b"1", 0o600).unwrap();
    // Keep the original open: an unlinked file that is still open keeps its inode number, so no
    // replacement below can be handed the same (device, inode) and look like the original.
    let _keep = std::fs::File::open(rootp(&t).join("a")).unwrap();
    replace_with_foreign(&rootp(&t), "a", "2");
    assert_eq!(
        unlink_if_same(root.fd(), "a", &id),
        Err(Fail("record_changed"))
    );
    assert!(exists(&rootp(&t).join("a")));
    let (_, outside) = t.sentinel();
    std::fs::remove_file(rootp(&t).join("a")).unwrap();
    symlink(&outside, rootp(&t).join("a")).unwrap();
    assert!(unlink_if_same(root.fd(), "a", &id).is_err());
    assert_sentinel(&outside);
}

#[cfg(target_os = "linux")]
#[test]
fn remove_leaves_every_record_file_swapped_in_after_the_ownership_decision() {
    let t = TempDir::new();
    let root = t.root();
    make_version(&t, "ours-1", true);
    write_record_file(&t, &record("ours-1"));
    let tmp_name = "install.json.tmp-0123456789abcdef";
    put(&rootp(&t).join(tmp_name), &record("ours-1").to_json());
    put(&rootp(&t).join(PENDING_NAME), &pending_json("old-1"));
    put(
        &rootp(&t).join(CONFIG_NAME),
        r#"{"_oabInstallerOwned":true}"#,
    );
    // The unlinks run in this order: the record, then the others by name. Each call swaps in a
    // foreign file for the one that is about to be unlinked.
    let order = [RECORD_NAME, tmp_name, PENDING_NAME, CONFIG_NAME];
    let n = std::rc::Rc::new(std::cell::Cell::new(0usize));
    let n2 = n.clone();
    BEFORE_UNLINK.with(|h| {
        *h.borrow_mut() = Some(Box::new(move |p: &Path| {
            let i = n2.get();
            n2.set(i + 1);
            if let Some(name) = order.get(i) {
                replace_with_foreign(p, name, "foreign");
            }
        }));
    });
    let rep = remove_all(&root).unwrap();
    clear_hooks();
    assert_eq!(n.get(), 4);
    for name in order {
        assert_eq!(
            std::fs::read(rootp(&t).join(name)).unwrap(),
            b"foreign",
            "{name} was deleted or overwritten"
        );
        assert!(
            rep.left.iter().any(|(l, _)| l == name),
            "{name} not reported"
        );
        assert!(!rep.removed.iter().any(|r| r == name));
    }
}

#[cfg(target_os = "linux")]
#[test]
fn pending_cleanup_leaves_a_pending_record_swapped_in_before_its_unlink() {
    let t = TempDir::new();
    let root = t.root();
    make_version(&t, "new-2", true);
    let mut r = record("new-2");
    r.previous = Some("old-1".into());
    write_record_file(&t, &r);
    make_version(&t, "old-1", true);
    put(&rootp(&t).join(PENDING_NAME), &pending_json("old-1"));
    BEFORE_UNLINK.with(|h| {
        *h.borrow_mut() = Some(Box::new(|p: &Path| {
            replace_with_foreign(p, PENDING_NAME, "foreign")
        }));
    });
    let out = run_pending_cleanup(&root);
    clear_hooks();
    assert_eq!(out.unwrap(), Some("old-1".into()));
    assert!(!exists(&rootp(&t).join("old-1")));
    assert_eq!(
        std::fs::read(rootp(&t).join(PENDING_NAME)).unwrap(),
        b"foreign"
    );
}

/// #132: a temp record is claimed by the rule of the record itself, not by its shape. One that
/// parses but names a version directory without the installer's marker is left in place.
#[test]
fn a_temp_record_naming_an_unmarked_version_is_left_in_place() {
    let t = TempDir::new();
    let root = t.root();
    make_version(&t, "id-1", true);
    make_version(&t, "id-2", false);
    write_record_file(&t, &record("id-1"));
    let stray = rootp(&t).join("install.json.tmp-0123456789abcdef");
    put(&stray, &record("id-2").to_json());
    let marked = rootp(&t).join("install.json.tmp-fedcba9876543210");
    put(&marked, &record("id-1").to_json());
    let rep = remove_all(&root).unwrap();
    assert!(
        exists(&stray),
        "a record that names an unmarked version was deleted"
    );
    assert!(!exists(&marked), "a record of ours was left");
    assert!(rep
        .left
        .iter()
        .any(|(n, _)| n == "install.json.tmp-0123456789abcdef"));
}

// ---- the base of the short temporary directories (#132) ---------------------------------------

fn uid() -> u32 {
    rustix::process::geteuid().as_raw()
}

fn dir_with_mode(p: &Path, mode: u32) {
    std::fs::create_dir_all(p).unwrap();
    std::fs::set_permissions(p, std::fs::Permissions::from_mode(mode)).unwrap();
}

fn base_of(t: &TempDir, candidate: Option<&Path>) -> R<PathBuf> {
    open_private_base_in(candidate, &t.path.join("tmp"), uid()).map(|(_, p)| p)
}

#[test]
fn a_private_runtime_dir_is_the_base_and_the_shared_tmp_is_untouched() {
    let t = TempDir::new();
    dir_with_mode(&t.path.join("tmp"), 0o1777);
    let rt = t.path.join("run");
    dir_with_mode(&rt, 0o700);
    assert_eq!(base_of(&t, Some(&rt)).unwrap(), rt);
    assert_eq!(std::fs::read_dir(t.path.join("tmp")).unwrap().count(), 0);
}

#[test]
fn a_symlinked_runtime_dir_is_not_followed() {
    let t = TempDir::new();
    dir_with_mode(&t.path.join("tmp"), 0o1777);
    let real = t.path.join("real");
    dir_with_mode(&real, 0o700);
    let link = t.path.join("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    let got = base_of(&t, Some(&link)).unwrap();
    assert_eq!(got, t.path.join("tmp").join(format!("oab-{}", uid())));
    assert_eq!(std::fs::read_dir(&real).unwrap().count(), 0);
}

#[test]
fn a_runtime_dir_others_can_write_or_of_another_owner_or_of_the_wrong_shape_is_refused() {
    let t = TempDir::new();
    dir_with_mode(&t.path.join("tmp"), 0o1777);
    let fallback = t.path.join("tmp").join(format!("oab-{}", uid()));
    for mode in [0o777, 0o770, 0o707, 0o720] {
        let rt = t.path.join(format!("run-{mode:o}"));
        dir_with_mode(&rt, mode);
        assert_eq!(base_of(&t, Some(&rt)).unwrap(), fallback, "mode {mode:o}");
    }
    // Relative, over 40 bytes, and not a directory.
    assert_eq!(base_of(&t, Some(Path::new("run"))).unwrap(), fallback);
    let long = t.path.join("x".repeat(60));
    dir_with_mode(&long, 0o700);
    assert_eq!(base_of(&t, Some(&long)).unwrap(), fallback);
    let file = t.path.join("file");
    std::fs::write(&file, b"x").unwrap();
    assert_eq!(base_of(&t, Some(&file)).unwrap(), fallback);
    // A directory that is ours but is checked as another user's: the owner rule.
    let rt = t.path.join("run-ok");
    dir_with_mode(&rt, 0o700);
    let other = uid().wrapping_add(1);
    let r = open_private_base_in(Some(&rt), &t.path.join("tmp"), other);
    assert!(r.is_err(), "a directory of another owner is never a base");
}

#[test]
fn the_fallback_is_a_per_user_directory_created_0700_and_reused() {
    let t = TempDir::new();
    dir_with_mode(&t.path.join("tmp"), 0o1777);
    let want = t.path.join("tmp").join(format!("oab-{}", uid()));
    assert_eq!(base_of(&t, None).unwrap(), want);
    assert_eq!(
        std::fs::metadata(&want).unwrap().permissions().mode() & 0o7777,
        0o700
    );
    assert_eq!(
        base_of(&t, None).unwrap(),
        want,
        "an existing good one is reused"
    );
}

#[test]
fn a_planted_or_loose_fallback_directory_is_refused() {
    let t = TempDir::new();
    dir_with_mode(&t.path.join("tmp"), 0o1777);
    let name = format!("oab-{}", uid());
    // A symlink planted at the fallback name: nothing is created through it.
    let target = t.path.join("elsewhere");
    dir_with_mode(&target, 0o700);
    std::os::unix::fs::symlink(&target, t.path.join("tmp").join(&name)).unwrap();
    assert_eq!(base_of(&t, None).err(), Some(Fail("tmp_unavailable")));
    assert_eq!(std::fs::read_dir(&target).unwrap().count(), 0);
    std::fs::remove_file(t.path.join("tmp").join(&name)).unwrap();
    // A directory with a loose mode.
    dir_with_mode(&t.path.join("tmp").join(&name), 0o755);
    assert_eq!(base_of(&t, None).err(), Some(Fail("tmp_unavailable")));
    // A regular file in the way.
    std::fs::remove_dir(t.path.join("tmp").join(&name)).unwrap();
    std::fs::write(t.path.join("tmp").join(&name), b"x").unwrap();
    assert_eq!(base_of(&t, None).err(), Some(Fail("tmp_unavailable")));
    // A fallback of ours checked as another user's is refused too.
    std::fs::remove_file(t.path.join("tmp").join(&name)).unwrap();
    let other = uid().wrapping_add(1);
    dir_with_mode(&t.path.join("tmp").join(format!("oab-{other}")), 0o700);
    assert!(open_private_base_in(None, &t.path.join("tmp"), other).is_err());
}
