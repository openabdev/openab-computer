use super::*;
use crate::state::tests::TempDir;
use std::collections::HashMap;
use std::os::unix::fs::symlink;
use std::path::PathBuf;

struct Tables(HashMap<&'static str, String>);

impl Source for Tables {
    fn table(&self, name: &str) -> std::io::Result<String> {
        self.0
            .get(name)
            .cloned()
            .ok_or_else(|| std::io::Error::other("none"))
    }
}

const HEAD: &str = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n";

/// 0x225A is 8794. A row is `state` (0A = LISTEN) on `port` (4 hex digits).
fn row(port: &str, state: &str) -> String {
    format!(
        "   0: 0100007F:{port} 00000000:0000 {state} 00000000:00000000 00:00000000 00000000  1000        0 12345 1 0000000000000000 100 0 0 10 0\n"
    )
}

fn tables(tcp: String) -> Tables {
    Tables(HashMap::from([
        ("tcp", format!("{HEAD}{tcp}")),
        ("tcp6", HEAD.to_string()),
    ]))
}

fn quiet() -> Tables {
    tables(String::new())
}

fn home(t: &TempDir) -> PathBuf {
    let h = t.path.join("home");
    fs::create_dir_all(&h).unwrap();
    h
}

fn put(h: &Path, rel: &str, body: &str) {
    let p = h.join(rel);
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    fs::write(p, body).unwrap();
}

const UNITS: &str = ".config/systemd/user";

/// Every file below `dir` with its bytes, and every directory, to compare before and after.
fn snapshot(dir: &Path) -> Vec<(String, Option<Vec<u8>>)> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        for e in fs::read_dir(&d).unwrap().flatten() {
            let p = e.path();
            let m = fs::symlink_metadata(&p).unwrap();
            let rel = p.strip_prefix(dir).unwrap().display().to_string();
            if m.is_dir() {
                out.push((rel, None));
                stack.push(p);
            } else if m.file_type().is_symlink() {
                out.push((
                    format!("{rel} -> {}", fs::read_link(&p).unwrap().display()),
                    None,
                ));
            } else {
                out.push((rel, Some(fs::read(&p).unwrap())));
            }
        }
    }
    out.sort();
    out
}

#[test]
fn an_empty_home_has_nothing_legacy() {
    let t = TempDir::new();
    let l = gather(Some(&home(&t)), &quiet());
    assert_eq!(l, Legacy::none());
    assert!(!l.present());
}

#[test]
fn each_legacy_unit_file_is_listed_by_its_fixed_name() {
    for name in UNIT_FILES {
        let t = TempDir::new();
        let h = home(&t);
        put(&h, &format!("{UNITS}/{name}"), "[Service]\nExecStart=/x\n");
        let l = gather(Some(&h), &quiet());
        assert_eq!(l.units, name);
        assert_eq!((l.paths.as_str(), l.listener.as_str()), ("none", "none"));
        assert!(l.present());
    }
    // Both, in the fixed order.
    let t = TempDir::new();
    let h = home(&t);
    for name in UNIT_FILES.iter().rev() {
        put(&h, &format!("{UNITS}/{name}"), "x");
    }
    assert_eq!(
        gather(Some(&h), &quiet()).units,
        "oab-pw-mcp.service,oab-computer-pw-mcp.service"
    );
}

#[test]
fn the_new_unit_alongside_is_not_legacy() {
    let t = TempDir::new();
    let h = home(&t);
    for n in [
        "oab-computer.service",
        "oab-computer-pw-mcp.service.bak",
        "oab-seat.service",
    ] {
        put(&h, &format!("{UNITS}/{n}"), "[Service]\n");
    }
    assert_eq!(gather(Some(&h), &quiet()), Legacy::none());
    // A legacy unit next to the new one is the only thing listed.
    put(&h, &format!("{UNITS}/oab-computer-pw-mcp.service"), "x");
    let l = gather(Some(&h), &quiet());
    assert_eq!(l.units, "oab-computer-pw-mcp.service");
}

#[test]
fn a_drop_in_counts_only_when_it_sets_mcp_upstream_and_its_content_is_never_reported() {
    let t = TempDir::new();
    let h = home(&t);
    let secret = "Environment=MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp\nEnvironment=TOKEN=s3cr3t-token-value\n";
    put(
        &h,
        &format!("{UNITS}/oab-computer.service.d/browser.conf"),
        &format!("[Service]\n{secret}"),
    );
    // No MCP_UPSTREAM: not legacy. A commented line: not legacy. A file that is not `*.conf`: ignored.
    put(
        &h,
        &format!("{UNITS}/oab-instance-mcp.service.d/other.conf"),
        "[Service]\nEnvironment=FOO=1\n# MCP_UPSTREAM=browser=http://x\n; MCP_UPSTREAM=y\nUnsetEnvironment=MCP_UPSTREAM\n",
    );
    put(
        &h,
        &format!("{UNITS}/oab-instance-mcp.service.d/old.txt"),
        "Environment=MCP_UPSTREAM=browser=http://x\n",
    );
    let l = gather(Some(&h), &quiet());
    assert_eq!(l.units, "drop-in:oab-computer.service.d");
    let all = format!("{l:?}");
    for bad in ["http", "127.0.0.1", "s3cr3t", "8794/mcp", "browser="] {
        assert!(!all.contains(bad), "{bad}: {all}");
    }
    // The second directory counts once a conf in it sets the variable (quoted form too).
    put(
        &h,
        &format!("{UNITS}/oab-instance-mcp.service.d/up.conf"),
        "[Service]\nEnvironment=\"MCP_UPSTREAM=browser=http://a\"\n",
    );
    assert_eq!(
        gather(Some(&h), &quiet()).units,
        "drop-in:oab-computer.service.d,drop-in:oab-instance-mcp.service.d"
    );
}

#[test]
fn a_symlinked_drop_in_directory_or_conf_is_not_followed() {
    let t = TempDir::new();
    let h = home(&t);
    let real = t.path.join("elsewhere");
    fs::create_dir_all(&real).unwrap();
    fs::write(real.join("a.conf"), "Environment=MCP_UPSTREAM=x\n").unwrap();
    fs::create_dir_all(h.join(UNITS)).unwrap();
    symlink(&real, h.join(UNITS).join("oab-computer.service.d")).unwrap();
    // A real directory whose only conf is a link.
    let d = h.join(UNITS).join("oab-instance-mcp.service.d");
    fs::create_dir_all(&d).unwrap();
    symlink(real.join("a.conf"), d.join("link.conf")).unwrap();
    assert_eq!(gather(Some(&h), &quiet()).units, "none");
    // A dangling unit link still shows that something is there.
    symlink("/nonexistent", h.join(UNITS).join("oab-pw-mcp.service")).unwrap();
    assert_eq!(gather(Some(&h), &quiet()).units, "oab-pw-mcp.service");
}

#[test]
fn legacy_paths_are_listed_with_sizes_and_the_old_profile_is_flagged() {
    let t = TempDir::new();
    let h = home(&t);
    put(
        &h,
        ".local/oab-computer/pw-mcp/node_modules/a.js",
        &"x".repeat(3000),
    );
    put(&h, ".local/oab-computer/pw-mcp/b.js", &"y".repeat(100));
    put(&h, ".local/oab-computer/pw-profile/Default/Cookies", "c");
    put(&h, ".local/oab-computer/pw-config.json", "{}");
    put(&h, ".local/oab-computer/pw-mcp.sh", &"s".repeat(2048));
    put(&h, ".cache/ms-playwright/chromium-1/x", "z");
    let l = gather(Some(&h), &quiet());
    let parts: Vec<&str> = l.paths.split(',').collect();
    assert_eq!(parts.len(), 5, "{}", l.paths);
    // Directory sizes are the sum of apparent file and directory-entry lengths; assert the shape and
    // the fixed unit, and the exact size for the two plain files.
    assert!(parts[0].starts_with("~/.local/oab-computer/pw-mcp:") && parts[0].ends_with(" KiB"));
    assert!(parts[1].starts_with("~/.local/oab-computer/pw-profile:"));
    assert!(parts[1].ends_with(":holds_cookies"), "{}", parts[1]);
    assert_eq!(parts[2], "~/.local/oab-computer/pw-config.json:2 B");
    assert_eq!(parts[3], "~/.local/oab-computer/pw-mcp.sh:2 KiB");
    assert!(parts[4].starts_with("~/.cache/ms-playwright:"));
    // Only the old profile carries the flag.
    assert_eq!(l.paths.matches("holds_cookies").count(), 1);
    // The home directory is never spelled out.
    assert!(!l.paths.contains(h.to_str().unwrap()));
    // The other two fixed paths, when present, come in the fixed order.
    put(&h, ".local/oab-instance-mcp/pw-mcp/p", "1");
    fs::create_dir_all(h.join(".local/oab-computer/pw-output")).unwrap();
    let l = gather(Some(&h), &quiet());
    let names: Vec<&str> = l
        .paths
        .split(',')
        .map(|p| p.split(':').next().unwrap())
        .collect();
    assert_eq!(
        names,
        [
            "~/.local/oab-computer/pw-mcp",
            "~/.local/oab-computer/pw-profile",
            "~/.local/oab-computer/pw-output",
            "~/.local/oab-computer/pw-config.json",
            "~/.local/oab-computer/pw-mcp.sh",
            "~/.local/oab-instance-mcp/pw-mcp",
            "~/.cache/ms-playwright",
        ]
    );
}

#[test]
fn a_symlinked_legacy_directory_is_reported_and_not_followed() {
    let t = TempDir::new();
    let h = home(&t);
    let big = t.path.join("big");
    fs::create_dir_all(&big).unwrap();
    fs::write(big.join("f"), vec![0u8; 5 * 1024 * 1024]).unwrap();
    fs::create_dir_all(h.join(".local/oab-computer")).unwrap();
    symlink(&big, h.join(".local/oab-computer/pw-profile")).unwrap();
    // A link inside a listed tree counts as its own length and is not entered.
    put(&h, ".cache/ms-playwright/a", "a");
    symlink(&big, h.join(".cache/ms-playwright/link")).unwrap();
    let l = gather(Some(&h), &quiet());
    assert!(
        l.paths
            .contains("~/.local/oab-computer/pw-profile:symlink:holds_cookies"),
        "{}",
        l.paths
    );
    let cache = l
        .paths
        .split(',')
        .find(|p| p.contains("ms-playwright"))
        .unwrap();
    assert!(cache.ends_with(" B") || cache.ends_with(" KiB"), "{cache}");
    assert!(!cache.contains("MiB"), "{cache}");
}

#[test]
fn a_tree_past_a_cap_or_a_permission_error_is_size_unknown() {
    let t = TempDir::new();
    let d = t.path.join("tree");
    for i in 0..5 {
        fs::create_dir_all(d.join("sub")).unwrap();
        fs::write(d.join(format!("f{i}")), "x").unwrap();
    }
    assert!(dir_size_with(&d, 100, 8).is_some());
    assert_eq!(dir_size_with(&d, 3, 8), None, "entry cap");
    let deep = t.path.join("deep/a/b/c/d");
    fs::create_dir_all(&deep).unwrap();
    assert!(dir_size_with(&t.path.join("deep"), 100, 8).is_some());
    assert_eq!(
        dir_size_with(&t.path.join("deep"), 100, 2),
        None,
        "depth cap"
    );
    assert_eq!(dir_size_with(&t.path.join("missing"), 100, 8), None);
    // Through `gather`: a legacy directory that cannot be listed.
    use std::os::unix::fs::PermissionsExt;
    let h = home(&t);
    put(&h, ".local/oab-computer/pw-output/f", "x");
    let out = h.join(".local/oab-computer/pw-output");
    fs::set_permissions(&out, fs::Permissions::from_mode(0o000)).unwrap();
    let l = gather(Some(&h), &quiet());
    fs::set_permissions(&out, fs::Permissions::from_mode(0o700)).unwrap();
    // Root can list a mode 000 directory; there is nothing to assert for it.
    if rustix::process::geteuid().as_raw() != 0 {
        assert_eq!(l.paths, "~/.local/oab-computer/pw-output:size_unknown");
    }
}

#[test]
fn sizes_use_a_fixed_unit_rounded_up() {
    assert_eq!(format_size(0), "0 B");
    assert_eq!(format_size(1023), "1023 B");
    assert_eq!(format_size(1024), "1 KiB");
    assert_eq!(format_size(1025), "2 KiB");
    assert_eq!(format_size(1024 * 1024), "1 MiB");
    assert_eq!(format_size(1024 * 1024 + 1), "2 MiB");
    assert_eq!(format_size(3 * 1024 * 1024 * 1024), "3 GiB");
}

#[test]
fn the_old_port_is_reported_only_when_something_listens_on_it() {
    let t = TempDir::new();
    let h = home(&t);
    // 0x225A = 8794, state 0A = LISTEN.
    let l = gather(Some(&h), &tables(row("225A", "0A")));
    assert_eq!(l.listener, "8794");
    assert!(l.present());
    // Another port, or the port in a state that is not LISTEN (an established connection).
    for tcp in [row("1F90", "0A"), row("225A", "01"), String::new()] {
        assert_eq!(gather(Some(&h), &tables(tcp)).listener, "none");
    }
    // tcp6 counts too.
    let mut t6 = quiet();
    t6.0.insert(
        "tcp6",
        format!(
            "{HEAD}   0: 00000000000000000000000001000000:225A 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1001        0 22345 1 0000000000000000 100 0 0 10 0\n"
        ),
    );
    assert_eq!(gather(Some(&h), &t6).listener, "8794");
    // An unreadable tcp table is `unknown`, never `none`; a missing tcp6 table (no IPv6) is fine.
    assert_eq!(
        gather(Some(&h), &Tables(HashMap::new())).listener,
        "unknown"
    );
    let only4 = Tables(HashMap::from([("tcp", HEAD.to_string())]));
    assert_eq!(gather(Some(&h), &only4).listener, "none");
    // `unknown` is not a finding.
    assert!(!gather(Some(&h), &Tables(HashMap::new())).present());
}

#[test]
fn only_an_active_environment_assignment_of_mcp_upstream_counts() {
    use super::sets_upstream as set;
    for yes in [
        "Environment=MCP_UPSTREAM=browser=http://x",
        "  Environment=MCP_UPSTREAM=a",
        "Environment=\"MCP_UPSTREAM=a\"",
        "Environment=FOO=1 MCP_UPSTREAM=a",
        "Environment=FOO=1 \"MCP_UPSTREAM=a\"",
    ] {
        assert!(set(yes), "{yes}");
    }
    for no in [
        "# Environment=MCP_UPSTREAM=a",
        "UnsetEnvironment=MCP_UPSTREAM",
        "UnsetEnvironment=MCP_UPSTREAM=a",
        "Environment=XMCP_UPSTREAM=a",
        "Environment=FOO=MCP_UPSTREAM",
        "Environment=FOO=1 # MCP_UPSTREAM=a",
        "ExecStart=/bin/true MCP_UPSTREAM=a",
        "Description=MCP_UPSTREAM=a",
    ] {
        assert!(!set(no), "{no}");
    }
}

#[test]
fn an_unknown_home_is_unknown_never_none() {
    for h in [None, Some(Path::new(""))] {
        let l = gather(h, &quiet());
        assert_eq!(
            (l.units.as_str(), l.paths.as_str(), l.listener.as_str()),
            ("unknown", "unknown", "none")
        );
        assert!(!l.present());
    }
}

#[test]
fn everything_present_is_listed_and_nothing_on_disk_changes() {
    let t = TempDir::new();
    let h = home(&t);
    for n in UNIT_FILES {
        put(&h, &format!("{UNITS}/{n}"), "[Service]\nExecStart=/old\n");
    }
    put(
        &h,
        &format!("{UNITS}/oab-computer.service.d/up.conf"),
        "Environment=MCP_UPSTREAM=browser=http://127.0.0.1:8794/mcp\n",
    );
    put(&h, ".local/oab-computer/pw-mcp/a", "1");
    put(&h, ".local/oab-computer/pw-profile/Cookies", "c");
    put(&h, ".local/oab-computer/pw-mcp.sh", "#!/bin/bash\n");
    put(&h, ".cache/ms-playwright/x", "z");
    let before = snapshot(&h);
    let l = gather(Some(&h), &tables(row("225A", "0A")));
    assert_ne!(l, Legacy::none());
    assert_eq!(snapshot(&h), before, "the listing changed something");
    // The rendered fields hold no URL, address or token-like text, and no absolute home path.
    let all = format!("{} {} {}", l.units, l.paths, l.listener);
    for bad in [
        "http",
        "127.0.0.1",
        "token",
        "Bearer",
        "://",
        h.to_str().unwrap(),
    ] {
        assert!(!all.contains(bad), "{bad}: {all}");
    }
    assert!(all
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b" ~/.:_,-".contains(&b)));
}
