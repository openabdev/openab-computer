use super::*;
use std::process::Command;

/// A `$` that is not half of a `$$` pair: systemd would try to expand it.
fn lone_dollar(s: &str) -> bool {
    let mut it = s.chars().peekable();
    while let Some(c) = it.next() {
        if c == '$' {
            if it.peek() == Some(&'$') {
                it.next();
            } else {
                return true;
            }
        }
    }
    false
}

// ---- the argv ---------------------------------------------------------------------------------

#[test]
fn the_probe_argv_has_no_lone_dollar_and_no_percent_for_systemd_to_read() {
    // The scripts themselves are full of `$`, and have no `%`.
    assert!(lone_dollar(BASE_SCRIPT) && lone_dollar(MOUNT_SCRIPT));
    assert!(!BASE_SCRIPT.contains('%') && !MOUNT_SCRIPT.contains('%'));
    let args = vec![
        "$HOME".to_string(),
        "a${b}c".to_string(),
        "x$$y".to_string(),
    ];
    for script in [BASE_SCRIPT, MOUNT_SCRIPT] {
        let a = probe_argv("oab-x-probe-0", &[], script, &args).unwrap();
        for w in &a {
            assert!(!lone_dollar(w), "{w}");
            assert!(!w.contains('%'), "{w}");
        }
    }
}

#[test]
fn a_percent_in_any_piece_means_no_probe_is_started() {
    let props = vec!["ReadWritePaths=/a%h".to_string()];
    assert!(probe_argv("oab-x-probe-0", &props, BASE_SCRIPT, &[]).is_none());
    assert!(probe_argv("oab-x-probe-0", &[], BASE_SCRIPT, &["100%".into()]).is_none());
    assert!(probe_argv("oab-x-probe-0", &[], "echo %d", &[]).is_none());
    assert!(probe_argv("oab-x-probe-0", &[], BASE_SCRIPT, &["ok".into()]).is_some());
}

#[test]
fn the_probe_command_is_env_i_sh_c_and_host_values_are_only_positional() {
    let props = unit::base_props(1 << 30, 100);
    let a = probe_argv(
        "oab-x-probe-0",
        &props,
        BASE_SCRIPT,
        &[
            "SENTINEL-1".into(),
            "SENTINEL-2".into(),
            "SENTINEL-3".into(),
        ],
    )
    .unwrap();
    let dash = a.iter().position(|x| x == "--").unwrap();
    assert_eq!(
        &a[dash + 1..dash + 5],
        ["/usr/bin/env", "-i", "/bin/sh", "-c"]
    );
    let script = &a[dash + 5];
    assert_eq!(*script, escape(BASE_SCRIPT));
    assert!(
        !script.contains("SENTINEL"),
        "a host value is inside the script text"
    );
    assert_eq!(a[dash + 6], "sh");
    assert_eq!(&a[dash + 7..], ["SENTINEL-1", "SENTINEL-2", "SENTINEL-3"]);
    // Bounded, transient, collected, and carrying exactly the production list.
    assert!(a.windows(2).any(|w| w == ["-p", "RuntimeMaxSec=20"]));
    assert!(
        a.contains(&"--collect".to_string()) && a.contains(&"--unit=oab-x-probe-0".to_string())
    );
    let carried: Vec<&String> = a[..dash]
        .windows(2)
        .filter(|w| w[0] == "-p" && w[1] != "RuntimeMaxSec=20")
        .map(|w| &w[1])
        .collect();
    assert_eq!(carried, props.iter().collect::<Vec<_>>());
}

#[test]
fn the_scripts_use_shell_builtins_only() {
    let external = [
        "awk", "sed", "grep", "cat ", "cut ", "tr ", "head", "tail", "ls ", "find", "python",
        "perl", "curl", "wget", "touch", "mkdir", "rm ",
    ];
    for w in external {
        assert!(!BASE_SCRIPT.contains(w), "{w} in the base script");
        assert!(!MOUNT_SCRIPT.contains(w), "{w} in the mount script");
    }
    assert!(!BASE_SCRIPT.contains("stat ") && !MOUNT_SCRIPT.contains("stat "));
    assert!(!BASE_SCRIPT.contains("/usr/bin/") && !MOUNT_SCRIPT.contains("/usr/bin/"));
    // Nothing the probes do writes a file or opens a port.
    for s in [BASE_SCRIPT, MOUNT_SCRIPT] {
        assert!(!s.contains(">>"), "{s}");
        for tail in s.split('>').skip(1) {
            let t = tail.trim_start();
            assert!(
                t.starts_with("/dev/null") || t.starts_with('&'),
                "a redirect to {t:.20}"
            );
        }
        assert!(!s.contains("--port") && !s.contains("8794"));
    }
}

// ---- the parser -------------------------------------------------------------------------------

#[test]
fn the_parser_accepts_only_known_tokens_and_values() {
    let all = "no_new_privs=1\nseccomp_filter=1\numask=1\nmemory_max=na\ntasks_max=0\n\
               kernel_tunables=1\ncontrol_groups=1\nkernel_modules=1\n";
    let v = parse(all, &BASE_TOKENS).unwrap();
    assert_eq!(v[3], Val::Na);
    assert_eq!(v[4], Val::Zero);
    assert_eq!(v[0], Val::One);
    // A missing token reads Na, not One.
    let v = parse("umask=1\n", &BASE_TOKENS).unwrap();
    assert_eq!(v[2], Val::One);
    assert!(v.iter().enumerate().all(|(i, x)| i == 2 || *x == Val::Na));
    for bad in [
        "bogus=1\n",
        "umask=2\n",
        "umask=yes\n",
        "umask\n",
        "umask=1\numask=0\n",
        "umask=1\numask=1\n",
        "umask=1 extra\n",
        "NO_NEW_PRIVS=1\n",
        "",
        "\n\n",
    ] {
        assert!(parse(bad, &BASE_TOKENS).is_none(), "{bad:?}");
    }
    // Tokens of the other tier are unknown here.
    assert!(parse("private_tmp=1\n", &BASE_TOKENS).is_none());
    assert!(parse("private_tmp=1\n", &MOUNT_TOKENS).is_some());
}

#[test]
fn a_flood_of_output_is_not_a_result() {
    let line = "umask=1\n";
    let flood = line.repeat(64 * 1024 / line.len() + 1);
    assert!(flood.len() >= 64 * 1024);
    assert!(parse(&flood, &BASE_TOKENS).is_none());
}

// ---- the reporting rule -----------------------------------------------------------------------

fn base(v: Val) -> BaseVals {
    [v; BASE_TOKENS.len()]
}

#[test]
fn a_tier_is_verified_only_when_every_token_is_one() {
    let mut t = Tiers {
        base: Some(base(Val::One)),
        mount: MountTier::Applied([Val::One; 4]),
    };
    assert_eq!(t.base_state(), "verified");
    assert_eq!(t.mount_state(), "verified");
    assert_eq!(t.unverified_text(), "none");
    // `na` and `0` are both "not verified".
    for v in [Val::Na, Val::Zero] {
        t.mount = MountTier::Applied([Val::One; 4]);
        let mut b = base(Val::One);
        b[3] = v;
        t.base = Some(b);
        assert_eq!(t.base_state(), "partial");
        assert_eq!(t.unverified_tokens(), ["memory_max"]);
        let mut m = [Val::One; 4];
        m[1] = v;
        t.mount = MountTier::Applied(m);
        assert_eq!(t.mount_state(), "partial");
        assert_eq!(t.unverified_tokens(), ["memory_max", "protect_home"]);
        assert_eq!(t.unverified_text(), "memory_max,protect_home");
    }
}

#[test]
fn the_states_of_a_dropped_missing_and_unprobed_tier() {
    assert_eq!(Tiers::NONE.base_state(), "not_checked");
    assert_eq!(Tiers::NONE.mount_state(), "not_checked");
    assert_eq!(Tiers::NONE.unverified_text(), "not_checked");
    let t = Tiers {
        base: Some(base(Val::One)),
        mount: MountTier::Dropped,
    };
    assert_eq!(t.mount_state(), "dropped");
    // A dropped tier is not applied, so its tokens are not listed.
    assert_eq!(t.unverified_text(), "none");
    let t = Tiers {
        base: Some(base(Val::One)),
        mount: MountTier::NotApplicable,
    };
    assert_eq!(t.mount_state(), "not_applicable");
    assert_eq!(
        t.log_line(),
        "browser: hardening base=verified mount=not_applicable unverified=none"
    );
}

#[test]
fn the_unverified_list_only_ever_holds_tokens_of_the_fixed_vocabulary() {
    let t = Tiers {
        base: Some(base(Val::Zero)),
        mount: MountTier::Applied([Val::Na; 4]),
    };
    let all: Vec<&str> = BASE_TOKENS
        .iter()
        .chain(MOUNT_TOKENS.iter())
        .copied()
        .collect();
    assert_eq!(t.unverified_tokens(), all);
    for tok in t.unverified_tokens() {
        assert!(tok.bytes().all(|b| b.is_ascii_lowercase() || b == b'_'));
    }
}

#[test]
fn the_mount_state_of_a_mode_never_overstates() {
    // The constants carry no probe results, so they read "not checked", never "verified".
    assert_eq!(crate::containment::SYSTEMD.tiers, Tiers::NONE);
    assert_eq!(crate::containment::SYSTEMD_MOUNT.tiers, Tiers::NONE);
}

#[test]
fn host_mount_options_are_read_from_mountinfo() {
    let t = "25 1 0:22 / /etc rw,relatime - ext4 /dev/x rw\n\
             26 25 0:23 / /etc ro,nosuid,relatime shared:1 - ext4 /dev/x rw\n\
             27 1 0:24 / /usr rw - ext4 /dev/x rw\n";
    assert!(host_mount_is_ro(t, "/etc"), "the top mount wins");
    assert!(!host_mount_is_ro(t, "/usr"));
    assert!(!host_mount_is_ro(t, "/nope"));
    assert!(!host_mount_is_ro("garbage\n", "/etc"));
}

// ---- the scripts, run directly in a shell -----------------------------------------------------
//
// The scripts are plain shell with positional parameters, so their logic is tested here without a
// unit. What a unit adds (the effect of each property) is measured by the ignored tests of
// `containment_tests`.

fn run_script(script: &str, pre: &str, args: &[&str]) -> Vec<Val> {
    let text = format!("{pre}\n{script}");
    let out = Command::new("/bin/sh")
        .arg("-c")
        .arg(&text)
        .arg("sh")
        .args(args)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let toks = if script == BASE_SCRIPT {
        &BASE_TOKENS[..]
    } else {
        &MOUNT_TOKENS[..]
    };
    parse(&String::from_utf8(out.stdout).unwrap(), toks).expect("a parsable answer")
}

const NO_MOUNTINFO: &str = "/nonexistent-oab-mountinfo";

#[test]
fn the_base_script_reads_the_umask_and_never_answers_outside_the_vocabulary() {
    let v = run_script(BASE_SCRIPT, "umask 077", &[NO_MOUNTINFO, "100", "100", "-"]);
    assert_eq!(v.len(), BASE_TOKENS.len());
    assert_eq!(v[2], Val::One, "umask 077");
    let v = run_script(BASE_SCRIPT, "umask 022", &[NO_MOUNTINFO, "100", "100", "-"]);
    assert_eq!(v[2], Val::Zero, "umask 022");
    // No modules directory was passed and no mount table could be read: `na`.
    assert_eq!(v[7], Val::Na);
    assert_eq!(v[5], Val::Na);
    assert_eq!(v[6], Val::Na);
    // A directory this user can traverse is "not protected".
    let v = run_script(BASE_SCRIPT, "", &[NO_MOUNTINFO, "100", "100", "/"]);
    assert_eq!(v[7], Val::Zero);
    // A requested limit that is not the file's content is never `1`.
    let v = run_script(BASE_SCRIPT, "", &[NO_MOUNTINFO, "not-a-limit", "nope", "-"]);
    assert_ne!(v[3], Val::One);
    assert_ne!(v[4], Val::One);
}

fn mountinfo_file(t: &crate::state::tests::TempDir, text: &str) -> String {
    let p = t.path.join("mountinfo");
    std::fs::write(&p, text).unwrap();
    p.to_str().unwrap().to_string()
}

#[test]
fn the_base_script_reads_read_only_mounts_from_the_mount_table() {
    let t = crate::state::tests::TempDir::new();
    let ro = mountinfo_file(
        &t,
        "30 25 0:27 / /proc/sys ro,nosuid,nodev,noexec,relatime - proc proc rw\n\
         31 25 0:28 / /sys/fs/cgroup ro,nosuid,nodev,noexec,relatime - cgroup2 cgroup2 rw\n",
    );
    let v = run_script(BASE_SCRIPT, "", &[&ro, "1", "1", "-"]);
    assert_eq!((v[5], v[6]), (Val::One, Val::One));
    let rw = mountinfo_file(
        &t,
        "30 25 0:27 / /proc/sys rw,nosuid,nodev,noexec,relatime - proc proc rw\n\
         31 25 0:28 / /sys/fs/cgroup rw,nosuid,nodev,noexec,relatime - cgroup2 cgroup2 rw\n",
    );
    let v = run_script(BASE_SCRIPT, "", &[&rw, "1", "1", "-"]);
    assert_eq!((v[5], v[6]), (Val::Zero, Val::Zero));
    // `ro` as a substring of another option is not read-only.
    let tricky = mountinfo_file(
        &t,
        "30 25 0:27 / /proc/sys rw,nosuid,errors=remount-ro - proc proc rw\n",
    );
    let v = run_script(BASE_SCRIPT, "", &[&tricky, "1", "1", "-"]);
    assert_eq!(v[5], Val::Zero);
    // No entry at all for the mount point: it cannot be shown either way.
    let none = mountinfo_file(&t, "27 1 0:24 / /usr rw - ext4 /dev/x rw\n");
    let v = run_script(BASE_SCRIPT, "", &[&none, "1", "1", "-"]);
    assert_eq!((v[5], v[6]), (Val::Na, Val::Na));
}

#[test]
fn the_mount_script_reads_the_private_tmp_and_the_read_only_etc_from_the_mount_table() {
    let t = crate::state::tests::TempDir::new();
    let dir = t.path.to_str().unwrap().to_string();
    let private = mountinfo_file(
        &t,
        "40 25 8:2 /tmp/systemd-private-abc-oab-x.service-q/tmp /tmp rw,relatime - ext4 /dev/x rw\n\
         41 25 8:2 /etc /etc ro,relatime - ext4 /dev/x rw\n",
    );
    let v = run_script(MOUNT_SCRIPT, "", &[&private, &dir, "0", &dir]);
    assert_eq!((v[0], v[2]), (Val::One, Val::One));
    // The host's own /etc being read-only means the property cannot be shown.
    let v = run_script(MOUNT_SCRIPT, "", &[&private, &dir, "1", &dir]);
    assert_eq!(v[2], Val::Na);
    // An ordinary /tmp and a writable /etc: the effects are absent.
    let plain = mountinfo_file(&t, "40 25 8:2 / /tmp rw,relatime - ext4 /dev/x rw\n");
    let v = run_script(MOUNT_SCRIPT, "", &[&plain, &dir, "0", &dir]);
    assert_eq!((v[0], v[2]), (Val::Zero, Val::Zero));
    // No mount table: neither can be shown.
    let v = run_script(MOUNT_SCRIPT, "", &[NO_MOUNTINFO, &dir, "0", &dir]);
    assert_eq!((v[0], v[2]), (Val::Na, Val::Na));
}

#[test]
fn the_mount_script_checks_home_and_the_paths_and_never_creates_a_file() {
    let t = crate::state::tests::TempDir::new();
    let dir = t.path.to_str().unwrap().to_string();
    let before = std::fs::read_dir(&t.path).unwrap().count();
    // A home that is writable here is "not protected"; none passed is `na`.
    let v = run_script(MOUNT_SCRIPT, "", &[NO_MOUNTINFO, &dir, "1", &dir]);
    assert_eq!(v[1], Val::Zero);
    let v = run_script(MOUNT_SCRIPT, "", &[NO_MOUNTINFO, "-", "1", &dir]);
    assert_eq!(v[1], Val::Na);
    // Writable paths are `1`, an unwritable one `0`, none at all `na`.
    assert_eq!(v[3], Val::One);
    let v = run_script(
        MOUNT_SCRIPT,
        "",
        &[NO_MOUNTINFO, "-", "1", &dir, "/nonexistent-oab-path"],
    );
    assert_eq!(v[3], Val::Zero);
    let v = run_script(MOUNT_SCRIPT, "", &[NO_MOUNTINFO, "-", "1"]);
    assert_eq!(v[3], Val::Na);
    assert_eq!(std::fs::read_dir(&t.path).unwrap().count(), before);
}

#[test]
fn the_mount_tier_applies_only_where_the_child_can_write_and_protect_home_is_not_shown_absent() {
    use Val::{Na, One, Zero};
    // rw_paths One and protect_home One or Na (cannot be shown): applied.
    assert!(mount_applies(&[One, One, One, One]));
    assert!(
        mount_applies(&[One, Na, Zero, One]),
        "protect_home na stays, and is reported partial"
    );
    // No mount-namespace effect was observed at all (HOME unwritable, properties ignored): dropped.
    assert!(!mount_applies(&[Zero, Na, Zero, One]));
    // The user manager started the unit but ignored the properties (V11): dropped.
    assert!(!mount_applies(&[Zero, Zero, Zero, One]));
    assert!(!mount_applies(&[One, Zero, One, One]));
    // The child cannot write what it needs: dropped, whatever else is true.
    for rw in [Zero, Na] {
        assert!(!mount_applies(&[One, One, One, rw]));
    }
}
