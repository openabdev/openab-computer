use super::*;
use crate::elf::tests::build_elf;
use crate::manifest::PlatformId;
use crate::state::tests::TempDir;
use std::os::unix::fs::PermissionsExt;

const LDCONF: &str = "1234 libs found in cache `/etc/ld.so.cache'
\tlibc.so.6 (libc6,AArch64, OS ABI: Linux 3.7.0) => /lib/aarch64-linux-gnu/libc.so.6
\tlibc.so.6 (libc6, OS ABI: Linux 3.2.0) => /lib/arm-linux-gnueabihf/libc.so.6
\tlibm.so.6 (libc6,AArch64, OS ABI: Linux 3.7.0) => /lib/aarch64-linux-gnu/libm.so.6
\tld-linux-aarch64.so.1 (libc6,AArch64, OS ABI: Linux 3.7.0) => /lib/ld-linux-aarch64.so.1
\tlibnss3.so (libc6,AArch64) => /usr/lib/aarch64-linux-gnu/libnss3.so
garbage line without arrow
";

fn ld() -> Vec<LdEntry> {
    parse_ldconfig(LDCONF)
}

fn healthy(m: &Manifest, sel: &Selection<'_>) -> Facts {
    // Every soname either artifact needs is "installed".
    let mut text = String::new();
    for a in [sel.node, sel.chromium] {
        for n in a.needed.iter().flatten() {
            text.push_str(&format!("\t{n} (libc6,AArch64) => /lib/{n}\n"));
        }
    }
    let _ = m;
    Facts {
        libc: Libc::Glibc(Some((2, 41))),
        ld: Some(parse_ldconfig(&text)),
        os_release: "ID=debian\n".into(),
        userns: Userns::default(),
        free_disk: Some(u64::MAX / 2),
        seat: false,
        data_base: PathBuf::from("/home/u/.local/share"),
    }
}

fn arm(m: &Manifest) -> Selection<'_> {
    m.select(Some(PlatformId::LinuxArm64)).unwrap()
}

#[test]
fn ldconfig_output_is_parsed() {
    let l = ld();
    assert_eq!(l.len(), 5);
    assert_eq!(l[0].soname, "libc.so.6");
    assert!(l[0].desc.contains("AArch64"));
    assert_eq!(l[0].path, "/lib/aarch64-linux-gnu/libc.so.6");
    assert_eq!(parse_ldconfig("").len(), 0);
}

#[test]
fn only_the_hosts_architecture_counts() {
    let l = ld();
    assert!(in_cache(&l, "AArch64", "libc.so.6"));
    assert!(!in_cache(&l, "x86-64", "libc.so.6"));
    assert_eq!(
        missing_libraries(
            &l,
            "AArch64",
            &["libc.so.6", "libgbm.so.1", "libasound.so.2", "libgbm.so.1"]
        ),
        ["libasound.so.2", "libgbm.so.1"]
    );
}

#[test]
fn libc_detection() {
    let l = ld();
    assert_eq!(
        detect_libc(Some("/lib/ld-musl-aarch64.so.1"), &l, false),
        Libc::Musl
    );
    assert_eq!(
        detect_libc(Some("/lib/ld-linux-aarch64.so.1"), &l, true),
        Libc::Glibc(None)
    );
    // A static binary on a host with only a musl loader.
    assert_eq!(detect_libc(None, &[], true), Libc::Musl);
    assert_eq!(detect_libc(None, &l, true), Libc::Glibc(None));
}

#[test]
fn a_healthy_host_passes_and_the_report_is_honest_about_what_it_checks() {
    let m = Manifest::embedded();
    let s = arm(m);
    let r = evaluate(m, &s, &healthy(m, &s), 1_000_000);
    assert!(r.ok(), "{r:?}");
    let text = render(&r);
    assert!(text.contains("preflight: ok"));
    assert!(
        text.contains("build time"),
        "the list is described as build-time only"
    );
    assert!(text.contains("final test"));
    assert!(!text.to_lowercase().contains("safe"));
    assert!(r.root_actions.is_empty());
}

#[test]
fn every_missing_library_is_listed_in_one_run_with_a_root_action_that_is_only_printed() {
    let m = Manifest::embedded();
    let s = arm(m);
    let mut f = healthy(m, &s);
    f.ld = Some(ld()); // only libc, libm, ld-linux, libnss3 exist
    let r = evaluate(m, &s, &f, 1_000_000);
    assert!(!r.ok());
    assert!(r.missing.len() > 3, "{:?}", r.missing);
    assert!(
        r.missing.windows(2).all(|w| w[0] < w[1]),
        "sorted and unique"
    );
    for n in &r.missing {
        assert!(render(&r).contains(n.as_str()), "{n}");
    }
    assert!(!r.missing.contains(&"libc.so.6".to_string()));
    assert_eq!(r.root_actions.len(), 1);
    let a = &r.root_actions[0];
    assert!(
        a.command.starts_with("sudo apt-get install libasound2 "),
        "{}",
        a.command
    );
    let text = render(&r);
    assert!(text.contains("needs root (not run by this tool): sudo apt-get install"));
    assert!(text.contains("preflight: blocked"));
}

#[test]
fn non_debian_hosts_get_no_apt_line() {
    let m = Manifest::embedded();
    let s = arm(m);
    let mut f = healthy(m, &s);
    f.ld = Some(vec![]);
    f.os_release = "ID=fedora\n".into();
    let r = evaluate(m, &s, &f, 0);
    assert!(!r.ok());
    assert!(r.root_actions.is_empty());
    assert!(render(&r).contains("best effort"));
    // ID_LIKE counts.
    f.os_release = "ID=pop\nID_LIKE=\"ubuntu debian\"\n".into();
    assert_eq!(evaluate(m, &s, &f, 0).root_actions.len(), 1);
}

#[test]
fn musl_old_glibc_and_low_disk_are_blockers() {
    let m = Manifest::embedded();
    let s = arm(m);
    let mut f = healthy(m, &s);
    f.libc = Libc::Musl;
    let r = evaluate(m, &s, &f, 0);
    assert!(!r.ok() && render(&r).contains("musl"));
    f.libc = Libc::Glibc(Some((2, 17)));
    let r = evaluate(m, &s, &f, 0);
    assert!(!r.ok() && render(&r).contains("older than"));
    f.libc = Libc::Glibc(Some((2, 28)));
    assert!(evaluate(m, &s, &f, 0).ok(), "exactly the floor passes");
    f.libc = Libc::Glibc(Some((2, 41)));
    f.free_disk = Some(100_000_000);
    let r = evaluate(m, &s, &f, 900_000_000);
    assert!(!r.ok());
    let t = render(&r);
    assert!(
        t.contains("needs about 900 MB") && t.contains("100 MB free"),
        "{t}"
    );
    f.free_disk = None;
    assert!(
        evaluate(m, &s, &f, 900_000_000).ok(),
        "unknown free space is reported, not a blocker"
    );
    assert!(render(&evaluate(m, &s, &f, 900_000_000)).contains("free space unknown"));
}

#[test]
fn user_namespace_and_apparmor_state_are_reported() {
    let m = Manifest::embedded();
    let s = arm(m);
    let mut f = healthy(m, &s);
    f.userns = Userns {
        clone: Some(false),
        max: Some(0),
        apparmor_restricted: Some(true),
    };
    let r = evaluate(m, &s, &f, 0);
    let t = render(&r);
    assert!(t.contains("user namespaces: disabled"));
    assert!(t.contains("apparmor user namespace restriction: on"));
    assert_eq!(r.root_actions.len(), 1);
    assert!(
        r.ok(),
        "the health check at install decides, not these settings"
    );
    f.userns = Userns {
        clone: None,
        max: None,
        apparmor_restricted: None,
    };
    assert!(render(&evaluate(m, &s, &f, 0)).contains("unknown"));
}

#[test]
fn facts_are_gathered_from_injected_sources() {
    let t = TempDir::new();
    let d = &t.path;
    std::fs::write(d.join("os-release"), "ID=debian\n").unwrap();
    std::fs::write(d.join("clone"), "1\n").unwrap();
    std::fs::write(d.join("max"), "63000\n").unwrap();
    std::fs::write(d.join("aa"), "1\n").unwrap();
    // A fake libc with GLIBC_2.36 definitions, and a fake ldconfig listing it.
    let libc = d.join("libc.so.6");
    std::fs::write(
        &libc,
        build_elf(None, &[], &[], &["libc.so.6", "GLIBC_2.17", "GLIBC_2.36"]),
    )
    .unwrap();
    let script = d.join("ldconfig");
    std::fs::write(
        &script,
        format!(
            "#!/bin/sh\ncase \"$1\" in -p) printf '\\tlibc.so.6 (libc6,AArch64) => {}\\n';; *) exit 3;; esac\n",
            libc.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    // A running "binary" whose interpreter is glibc's.
    let me = d.join("me");
    std::fs::write(
        &me,
        build_elf(Some("/lib/ld-linux-aarch64.so.1"), &["libc.so.6"], &[], &[]),
    )
    .unwrap();
    let src = Sources {
        ldconfig: vec![d.join("missing-ldconfig"), script.clone()],
        self_exe: me.clone(),
        os_release: d.join("os-release"),
        userns_clone: d.join("clone"),
        max_userns: d.join("max"),
        apparmor_userns: d.join("aa"),
        musl_loaders: vec![],
    };
    let f = Facts::gather(&src, PlatformId::LinuxArm64, d);
    assert_eq!(f.libc, Libc::Glibc(Some((2, 36))));
    assert_eq!(f.ld.as_ref().map(Vec::len), Some(1));
    assert_eq!(
        f.userns,
        Userns {
            clone: Some(true),
            max: Some(63000),
            apparmor_restricted: Some(true)
        }
    );
    assert!(f.os_release.contains("debian"));
    assert!(f.free_disk.is_some());

    // musl interpreter.
    std::fs::write(
        &me,
        build_elf(Some("/lib/ld-musl-aarch64.so.1"), &[], &[], &[]),
    )
    .unwrap();
    assert_eq!(
        Facts::gather(&src, PlatformId::LinuxArm64, d).libc,
        Libc::Musl
    );

    // No ldconfig at all: the library check is reported as not done.
    let none = Sources {
        ldconfig: vec![d.join("nope")],
        ..src
    };
    let f = Facts::gather(&none, PlatformId::LinuxArm64, d);
    assert!(f.ld.is_none());
    let m = Manifest::embedded();
    let s = arm(m);
    assert!(render(&evaluate(m, &s, &f, 0)).contains("not checked"));
}

#[test]
fn a_failing_ldconfig_is_treated_as_unavailable() {
    let t = TempDir::new();
    let script = t.path.join("ldconfig");
    std::fs::write(&script, "#!/bin/sh\necho partial\nexit 1\n").unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(run_ldconfig(&[script]).is_none());
}

#[test]
fn free_disk_walks_up_to_an_existing_ancestor() {
    let t = TempDir::new();
    assert!(free_disk(&t.path.join("a/b/c/not/yet")).is_some());
}

#[test]
fn the_staged_scan_finds_unsatisfied_needs_and_counts_trees_as_providers() {
    let t = TempDir::new();
    let tree = t.path.join("chromium");
    std::fs::create_dir_all(tree.join("sub")).unwrap();
    // chrome needs libfoo (shipped beside it), libbar (missing) and libc (host).
    std::fs::write(
        tree.join("chrome"),
        build_elf(
            None,
            &["libfoo.so", "libbar.so.1", "libc.so.6"],
            &[("libc.so.6", &["GLIBC_2.30"])],
            &[],
        ),
    )
    .unwrap();
    std::fs::write(
        tree.join("sub/libfoo.so"),
        build_elf(None, &["libc.so.6"], &[], &[]),
    )
    .unwrap();
    std::fs::write(tree.join("readme.txt"), "text").unwrap();
    std::os::unix::fs::symlink("/bin/sh", tree.join("link")).unwrap();
    let l = parse_ldconfig("\tlibc.so.6 (libc6,AArch64) => /lib/libc.so.6\n");
    let s = scan_trees(&[&tree], &l, "AArch64");
    assert_eq!(s.missing, ["libbar.so.1"]);
    assert_eq!(s.glibc_need, Some((2, 30)));
    assert!(s.files >= 3);
    // A tree that is not there is fine.
    assert!(scan_trees(&[&t.path.join("nope")], &l, "AArch64")
        .missing
        .is_empty());
}

#[test]
fn apparmor_restriction_prints_the_exact_command_and_never_runs_it() {
    let m = Manifest::embedded();
    let sel = arm(m);
    let mut f = healthy(m, &sel);
    f.userns.apparmor_restricted = Some(true);
    let r = evaluate(m, &sel, &f, 0);
    assert_eq!(r.root_actions.len(), 1);
    let a = &r.root_actions[0];
    assert_eq!(
        a.command,
        "printf '%s\\n' 'abi <abi/4.0>,' 'include <tunables/global>' \
         'profile oab-computer-chromium /home/u/.local/share/oab-computer/playwright/*/chromium/**/chrome flags=(unconfined) {' \
         '  userns,' '}' | sudo tee /etc/apparmor.d/oab-computer-chromium >/dev/null \
         && sudo apparmor_parser -r /etc/apparmor.d/oab-computer-chromium"
    );
    assert!(a.reason.contains("apparmor_restrict_unprivileged_userns"));
    let text = render(&r);
    assert!(text.contains(&format!("needs root (not run by this tool): {}", a.command)));
    assert!(r.ok(), "a root action is advice, not a blocker");

    // A path with a quote or a space is refused rather than written into a shell command.
    for bad in [
        "/home/a b/.local/share",
        "/home/it's/share",
        "/home/a*/share",
        "rel/share",
    ] {
        f.data_base = PathBuf::from(bad);
        let r = evaluate(m, &sel, &f, 0);
        assert!(r.root_actions.is_empty(), "{bad}");
        assert!(render(&r).contains("write a profile"), "{bad}");
    }
}
