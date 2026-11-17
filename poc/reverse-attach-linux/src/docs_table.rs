//! The generated flags and environment table of `docs/linux-setup.md`, and its CI check (L3; Req 3.2).
//!
//! Test-only: it adds nothing to the binary. One table here describes every flag of
//! `scripts/install-linux.sh` and `oab-computer browser` and every environment variable the daemon
//! reads. `render()` produces the block that sits between the two `GENERATED` markers in the doc.
//!
//! The tests (run by `cargo test --release` in the `Linux hands node` jobs):
//!
//! 1. the block in the doc equals `render()` byte for byte. When it does not, the failure prints the
//!    command that rewrites it: `OAB_UPDATE_DOCS=1 cargo test --release docs_table`;
//! 2. every `browser` row parses with `browser_cli::parse`, and every `--flag` that `parse` names is
//!    in the table (or is one of the two it refuses);
//! 3. the flags of the installer's `case` arms are the flags in the table;
//! 4. the environment variable names read in non-test source files are the names in the table;
//! 5. the block carries the password-store sentence, and the doc carries the figures of the
//!    embedded manifest (sizes, versions, hosts, the glibc floor).

use std::path::PathBuf;

const BEGIN: &str = "<!-- BEGIN GENERATED: linux-flags-env (source: poc/reverse-attach-linux/src/docs_table.rs; rewrite with OAB_UPDATE_DOCS=1 cargo test --release docs_table) -->";
const END: &str = "<!-- END GENERATED: linux-flags-env -->";

const INSTALLER: &str = "scripts/install-linux.sh";

/// `(command, flag, what it does)`. `flag` is `-` when the command takes none. `sample` is a
/// command line that `browser_cli::parse` must accept (empty for installer rows).
struct Flag {
    cmd: &'static str,
    flag: &'static str,
    what: &'static str,
    sample: &'static [&'static str],
}

const fn f(
    cmd: &'static str,
    flag: &'static str,
    what: &'static str,
    sample: &'static [&'static str],
) -> Flag {
    Flag {
        cmd,
        flag,
        what,
        sample,
    }
}

const FLAGS: &[Flag] = &[
    f(INSTALLER, "`--allow-login LOGIN`", "The Tailscale login that may use this node. Default: the login this node is signed in with.", &[]),
    f(INSTALLER, "`--browser MODE`", "`managed` downloads and installs the pinned browser (after showing what it downloads and asking, unless `--yes`); `none` skips it. With no terminal and neither `--browser managed` nor `--yes`, nothing is downloaded and the installer prints the command to run later.", &[]),
    f(INSTALLER, "`--no-browser`", "Same as `--browser none`. Cannot be combined with `--browser managed` or `--yes`.", &[]),
    f(INSTALLER, "`--yes`", "Agrees to the browser download without asking. It runs no root action.", &[]),
    f(INSTALLER, "`--apply-system-changes`", "Runs the root actions the installer prints (linger, `tailscale serve`, the AppArmor profile, missing libraries, fonts), each with `sudo`. Without it they are only printed.", &[]),
    f(INSTALLER, "`--headless-seat`", "No desktop on this node: install sway and run it headless as the user unit `oab-seat.service`.", &[]),
    f(INSTALLER, "`--port N`", "The daemon's loopback port. Default 8795.", &[]),
    f(INSTALLER, "`--serve-port N`", "The HTTPS port `tailscale serve` uses. Default 8444.", &[]),
    f("`oab-computer browser plan`", "-", "Prints what an install downloads, from where, how much, and where it goes. Downloads and writes nothing.", &["plan"]),
    f("`oab-computer browser preflight`", "-", "Checks this host (libc and its floor, user namespaces, disk, seat, missing libraries). Installs nothing and never uses root.", &["preflight"]),
    f("`oab-computer browser preflight`", "`--root-actions`", "Prints only the root actions, one `command`, a tab and the reason per line. The installer reads this.", &["preflight", "--root-actions"]),
    f("`oab-computer browser install`", "-", "Installs the pinned browser from the network.", &["install"]),
    f("`oab-computer browser install`", "`--from-dir DIR`", "Installs from files in DIR instead of the network. The same checks apply.", &["install", "--from-dir", "d"]),
    f("`oab-computer browser update`", "`--yes`", "Updates without asking. Without it a terminal is needed.", &["update", "--yes"]),
    f("`oab-computer browser update`", "`--from-dir DIR`", "Updates from files in DIR.", &["update", "--from-dir", "d"]),
    f("`oab-computer browser remove`", "-", "Deletes what the installer created and nothing else. It prints what it left.", &["remove"]),
    f("`oab-computer browser status`", "`--json`", "Prints the state as one JSON object.", &["status", "--json"]),
    f("`oab-computer browser status`", "`--retry`", "Clears the unavailable latch and runs the containment check again.", &["status", "--retry"]),
    f("`oab-computer browser signin`", "`--url URL`", "Opens a window on the node's seat on the persistent profile, at URL (`http://` or `https://`, default a blank page), and waits for Enter. Run it over `ssh -t`.", &["signin", "--url", "https://example.com/"]),
    f("`oab-computer browser install`, `update`, `remove`, `status`", "`--apply-system-changes`", "Refused with exit 2. This flag belongs to the installer script.", &[]),
    f("`oab-computer browser install`, `update`", "`--use-system-chromium`", "Refused with exit 2: not available in this build.", &[]),
];

/// `(name, read by, meaning)`.
const ENV: &[(&str, &str, &str)] = &[
    ("BIND", "daemon", "Listen address. The unit sets `127.0.0.1:8795`. Anything but loopback is refused unless the token and login checks are on."),
    ("MCP_TOKEN", "daemon", "The bearer token, inline. Prefer `MCP_TOKEN_FILE`."),
    ("MCP_TOKEN_FILE", "daemon", "A file that holds the bearer token. The installer writes it with mode 600."),
    ("MCP_ALLOW_LOGIN", "daemon", "The Tailscale login that may call without the token, by the `Tailscale-User-Login` header that `tailscale serve` adds."),
    ("MCP_INSECURE_LOCAL", "daemon", "Allows unauthenticated loopback calls. For tests only."),
    ("MCP_AUDIT_FILE", "daemon", "Where the audit log is written. Default: `$XDG_STATE_HOME` or `~/.local/state`."),
    ("MCP_GRANTS_FILE", "daemon", "Where lend grants are stored. Same default directory."),
    ("MCP_UPSTREAM", "daemon", "`name=url` entries of tool servers the daemon forwards to. Every URL must be a literal loopback address, `http://127.0.0.1:PORT` or `http://[::1]:PORT`; any other host stops the daemon with exit 64. The installer no longer writes it. Used only for the old external browser."),
    ("MCP_BROWSER_BACKEND", "daemon", "`external` is the explicit decision to use the `browser=` entry of `MCP_UPSTREAM` even when a managed install exists. Unset: a managed install wins."),
    ("OAB_BROWSER", "daemon", "`off` switches the managed tier off. With a managed install the result is no `browser_*` tools at all, and a stale `MCP_UPSTREAM` line is ignored. With nothing installed, a lone `MCP_UPSTREAM browser=` line still serves as external."),
    ("WAYLAND_DISPLAY", "daemon, `browser signin`", "The seat's socket name. The units set it. `signin` falls back to the highest `wayland-N` socket in `XDG_RUNTIME_DIR`."),
    ("XDG_RUNTIME_DIR", "daemon, `browser`", "The user's runtime directory (`/run/user/UID`). Needed for the seat, the child's short `TMPDIR` and the containment check."),
    ("XDG_DATA_HOME", "`browser`", "Where the browser is installed: `$XDG_DATA_HOME/oab-computer/playwright`. Default `~/.local/share`."),
    ("XDG_STATE_HOME", "daemon", "Base of the audit log, the grants file and the job store. Default `~/.local/state`."),
    ("HOME", "daemon, `browser`", "The user's home. `~/.local/oab-computer` holds the installer's binary, `~/.config/oab-computer` the token."),
    ("DBUS_SESSION_BUS_ADDRESS", "daemon, `browser`", "Lets the containment check reach the user manager."),
    ("PATH", "daemon, `browser`", "Where `systemd-run` and `systemctl` are found."),
    ("TERM", "daemon", "Set to `xterm-256color` for a terminal job when it is unset."),
];

/// The sentence the ADR requires wherever the browser's saved passwords are mentioned (D11).
fn password_store_sentence() -> String {
    format!(
        "The browser always starts with `{}`: saved passwords and cookies are protected by obfuscation under a profile directory only you can read, not strong encryption. Anyone who can read your home directory as you can recover them.",
        crate::child::PASSWORD_STORE
    )
}

/// The block, markers included, that `docs/linux-setup.md` holds.
pub fn render() -> String {
    let mut o = String::new();
    o.push_str(BEGIN);
    o.push_str("\n\n");
    o.push_str("| Command | Flag | What it does |\n| --- | --- | --- |\n");
    for r in FLAGS {
        let cmd = if r.cmd == INSTALLER {
            format!("`{INSTALLER}`")
        } else {
            r.cmd.to_string()
        };
        o.push_str(&format!("| {cmd} | {} | {} |\n", r.flag, r.what));
    }
    o.push_str("\n| Variable | Read by | Meaning |\n| --- | --- | --- |\n");
    for (n, by, what) in ENV {
        o.push_str(&format!("| `{n}` | {by} | {what} |\n"));
    }
    o.push('\n');
    o.push_str(&password_store_sentence());
    o.push_str("\n\n");
    o.push_str(END);
    o.push('\n');
    o
}

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn doc_path() -> PathBuf {
    repo().join("docs/linux-setup.md")
}

/// The block as the doc holds it, and the doc text around it.
fn split(doc: &str) -> Option<(&str, &str, &str)> {
    let b = doc.find(BEGIN)?;
    let e = doc.find(END)? + END.len();
    let e = if doc[e..].starts_with('\n') { e + 1 } else { e };
    Some((&doc[..b], &doc[b..e], &doc[e..]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::browser_cli::{parse, Cmd};
    use std::collections::BTreeSet;

    fn read(p: &std::path::Path) -> String {
        std::fs::read_to_string(p).unwrap_or_else(|e| panic!("{}: {e}", p.display()))
    }

    #[test]
    fn the_block_in_the_doc_is_the_rendered_table() {
        let doc = read(&doc_path());
        let want = render();
        if std::env::var_os("OAB_UPDATE_DOCS").is_some() {
            let new = match split(&doc) {
                Some((a, _, c)) => format!("{a}{want}{c}"),
                None => panic!("docs/linux-setup.md has no GENERATED markers; add the BEGIN and END lines first"),
            };
            std::fs::write(doc_path(), new).unwrap();
            return;
        }
        let (_, have, _) = split(&doc).expect("docs/linux-setup.md has the GENERATED markers");
        assert!(
            have == want,
            "the generated flags and environment table in docs/linux-setup.md is out of date.\nRun: OAB_UPDATE_DOCS=1 cargo test --release docs_table   (in poc/reverse-attach-linux), and commit the diff"
        );
    }

    #[test]
    fn every_browser_row_parses_and_every_parsed_flag_is_in_the_table() {
        for r in FLAGS.iter().filter(|r| !r.sample.is_empty()) {
            let args: Vec<String> = r.sample.iter().map(|s| s.to_string()).collect();
            let parsed = parse(&args);
            assert!(parsed.is_ok(), "{:?} does not parse: {parsed:?}", r.sample);
            if let Some(f) = r.flag.strip_prefix('`') {
                let flag = f.split([' ', '`']).next().unwrap();
                assert!(r.sample.contains(&flag), "{flag} is not in {:?}", r.sample);
            }
        }
        assert_eq!(
            parse(&["signin".into()]),
            Ok(Cmd::Signin { url: None }),
            "signin takes no argument"
        );
        // The flags `parse` names in its source.
        let src = read(&PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src/browser_cli.rs"));
        let body = &src[src.find("pub fn parse").unwrap()..src.find("fn one_line").unwrap()];
        let named: BTreeSet<String> = body
            .split('"')
            .skip(1)
            .step_by(2)
            .filter(|s| {
                s.starts_with("--") && s.chars().all(|c| c.is_ascii_lowercase() || c == '-')
            })
            .map(str::to_string)
            .collect();
        let table: BTreeSet<String> = FLAGS
            .iter()
            .filter(|r| r.cmd != INSTALLER)
            .filter_map(|r| r.flag.strip_prefix('`'))
            .map(|f| f.split([' ', '`']).next().unwrap().to_string())
            .collect();
        assert_eq!(named, table, "browser flags: parse() against the table");
    }

    fn installer_flags_in_script() -> BTreeSet<String> {
        let sh = read(&repo().join(INSTALLER));
        sh.lines()
            .filter_map(|l| {
                let t = l.trim_start();
                let flag: String = t
                    .chars()
                    .take_while(|c| *c == '-' || c.is_ascii_lowercase())
                    .collect();
                (flag.starts_with("--") && t[flag.len()..].starts_with(')')).then_some(flag)
            })
            .collect()
    }

    #[test]
    fn the_installers_flags_are_the_tables_flags() {
        let table: BTreeSet<String> = FLAGS
            .iter()
            .filter(|r| r.cmd == INSTALLER)
            .filter_map(|r| r.flag.strip_prefix('`'))
            .map(|f| f.split([' ', '`']).next().unwrap().to_string())
            .collect();
        assert_eq!(installer_flags_in_script(), table);
    }

    #[test]
    fn the_environment_names_in_source_are_the_tables_names() {
        let mut found: BTreeSet<String> = BTreeSet::new();
        let mut stack = vec![PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src")];
        while let Some(d) = stack.pop() {
            for e in std::fs::read_dir(&d).unwrap().flatten() {
                let p = e.path();
                let name = p.file_name().unwrap().to_string_lossy().into_owned();
                if p.is_dir() {
                    stack.push(p);
                    continue;
                }
                if !name.ends_with(".rs")
                    || name.ends_with("tests.rs")
                    || name.contains("conformance")
                    || name == "docs_table.rs"
                {
                    continue;
                }
                for line in read(&p).lines() {
                    if !(line.contains("var(")
                        || line.contains("var_os(")
                        || line.contains("get(\""))
                    {
                        continue;
                    }
                    for lit in line.split('"').skip(1).step_by(2) {
                        if lit.len() > 1
                            && lit.starts_with(|c: char| c.is_ascii_uppercase())
                            && lit
                                .chars()
                                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
                        {
                            found.insert(lit.to_string());
                        }
                    }
                }
            }
        }
        let table: BTreeSet<String> = ENV.iter().map(|(n, _, _)| n.to_string()).collect();
        assert_eq!(
            found, table,
            "environment variables: source against the table"
        );
    }

    #[test]
    fn the_block_says_obfuscation_not_strong_encryption_and_names_the_flag() {
        let b = render();
        assert!(b.contains("obfuscation"), "{b}");
        assert!(b.contains("not strong encryption"), "{b}");
        assert!(b.contains(crate::child::PASSWORD_STORE));
        assert_eq!(crate::child::PASSWORD_STORE, "--password-store=basic");
    }

    #[test]
    fn the_doc_carries_the_figures_of_the_embedded_manifest() {
        use crate::consent::{disk_bytes, disk_needed, download_bytes, megabytes};
        use crate::manifest::{Manifest, PlatformId};
        let doc = read(&doc_path());
        let m = Manifest::embedded();
        let pins: serde_json::Value =
            serde_json::from_str(&read(&repo().join("release/playwright-pins/pins.json"))).unwrap();
        let mut want: Vec<String> = vec![
            m.node.version.clone(),
            m.chromium.browser_version.clone(),
            pins["mcp"]["version"].as_str().unwrap().to_string(),
        ];
        want.extend(m.hosts.iter().cloned());
        let mut floors = BTreeSet::new();
        for p in [PlatformId::LinuxX64, PlatformId::LinuxArm64] {
            let sel = m.select(Some(p)).unwrap();
            want.push(megabytes(download_bytes(m, &sel)));
            want.push(megabytes(disk_bytes(m, &sel)));
            want.push(megabytes(disk_needed(m, &sel)));
            for a in [sel.node, sel.chromium] {
                floors.extend(a.min_glibc.clone());
            }
        }
        // One floor for the table: the highest of the pinned minimums.
        let floor = floors
            .iter()
            .filter_map(|v| crate::preflight::parse_version(v))
            .max()
            .map(|(a, b)| format!("{a}.{b}"))
            .unwrap();
        want.push(format!("glibc {floor}"));
        for w in want {
            assert!(
                doc.contains(&w),
                "docs/linux-setup.md does not contain `{w}`"
            );
        }
    }
}
