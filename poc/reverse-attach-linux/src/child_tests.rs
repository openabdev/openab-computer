use super::*;
use crate::containment::{Direct, Mechanism, Mode, SYSTEMD, UNVERIFIED};
use crate::state::tests::TempDir;
use std::os::unix::fs::PermissionsExt;
use std::sync::atomic::{AtomicU64, AtomicUsize};

fn rec(id: &str) -> InstallRecord {
    InstallRecord {
        manifest_id: id.into(),
        version: id.into(),
        platform: "linux-arm64".into(),
        chromium_executable: "chrome-x/chrome".into(),
        chromium_revision: "1".into(),
        chromium_released_at: "2026-01-01".into(),
        installed_at: "2026-01-01T00:00:00Z".into(),
        previous: None,
        digests: Default::default(),
    }
}

pub(crate) const GOOD: &str = r#"#!/bin/sh
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"serverInfo":{"name":"Playwright"}}}\n' "$id";;
    *'"method":"tools/list"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"browser_navigate"},{"name":"extra_tool"}]}}\n' "$id";;
    *'"method":"ping"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id";;
    *'"method":"die"'*) exit 5;;
    *'"method":"tools/call"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"ok"}]}}\n' "$id";;
  esac
done
"#;

/// An installed root whose "node" is a shell script.
pub(crate) struct Fx {
    pub t: TempDir,
}

impl Fx {
    pub(crate) fn new(node: &str) -> Fx {
        let t = TempDir::new();
        let root = t.root();
        let v = root.abs_path().join("pw-1");
        for (p, mode) in [
            ("node/bin/node", 0o755),
            ("pkg/node_modules/@playwright/mcp/cli.js", 0o644),
            ("chromium/chrome-x/chrome", 0o755),
        ] {
            let f = v.join(p);
            std::fs::create_dir_all(f.parent().unwrap()).unwrap();
            std::fs::write(&f, if p.ends_with("node") { node } else { "x" }).unwrap();
            std::fs::set_permissions(&f, std::fs::Permissions::from_mode(mode)).unwrap();
        }
        std::fs::write(v.join(state::OWNED), MARKER_TEXT).unwrap();
        std::fs::set_permissions(&v, std::fs::Permissions::from_mode(0o700)).unwrap();
        let run = state::create_dir_at(root.fd(), "run").unwrap();
        state::write_new_file(&run, OWNED_DATA, MARKER_TEXT, 0o600).unwrap();
        state::write_record(
            root.fd(),
            state::RECORD_NAME,
            rec("pw-1").to_json().as_bytes(),
        )
        .unwrap();
        Fx { t }
    }

    pub(crate) fn root(&self) -> Root {
        Root::open(&self.t.base(), false).unwrap().unwrap()
    }
}

pub(crate) struct Sup {
    pub sup: Supervisor,
    pub mech: Arc<Direct>,
    pub ms: Arc<AtomicU64>,
}

pub(crate) fn sup(fx: &Fx, verify: Result<Mode, &'static str>) -> Sup {
    let mech = Arc::new(Direct::new(verify));
    let ms = Arc::new(AtomicU64::new(1_000));
    let clock = Arc::clone(&ms);
    let mut cfg = Config::production(fx.t.base());
    cfg.clock = Arc::new(move || Duration::from_millis(clock.load(Ordering::SeqCst)));
    cfg.seat = Arc::new(|| None);
    cfg.init_timeout = Duration::from_secs(5);
    let m: Arc<dyn Mechanism> = mech.clone();
    Sup {
        sup: Supervisor::new(cfg, Arc::new(Availability::new(m))),
        mech,
        ms,
    }
}

fn spawned(s: &Sup) -> usize {
    s.mech.spawned.load(Ordering::SeqCst)
}

fn tick(s: &Sup, secs: u64) {
    s.ms.fetch_add(secs * 1000, Ordering::SeqCst);
}

const T: Duration = Duration::from_secs(5);

// ---- launch vector (item: tests 9) ----------------------------------------------------------

fn vector(seat: Option<&Seat>) -> Vector {
    launch_vector(
        &rec("pw-1"),
        Path::new("/d/oab-computer/playwright"),
        Path::new("/run/user/1000/oab-pw-ab"),
        seat,
    )
}

#[test]
fn the_launch_vector_always_carries_the_password_store_and_never_the_forbidden_flags() {
    let seat = Seat {
        runtime_dir: PathBuf::from("/run/user/1000"),
        display: "wayland-1".into(),
    };
    for (name, v) in [("headless", vector(None)), ("headed", vector(Some(&seat)))] {
        let cfg: Value = serde_json::from_str(&v.config).unwrap();
        assert_eq!(
            cfg["browser"]["launchOptions"]["args"],
            json!([PASSWORD_STORE]),
            "{name}"
        );
        assert_eq!(cfg["_oabInstallerOwned"], true, "{name}");
        for a in &v.args {
            for bad in ["--no-sandbox", "--port", "--host", "--allowed-hosts"] {
                assert!(!a.starts_with(bad), "{name}: {a}");
            }
        }
        assert!(v.args.contains(&"--sandbox".to_string()), "{name}");
        assert!(!v.config.contains("no-sandbox") && !v.config.contains("--port"));
    }
    assert!(vector(None).args.contains(&"--headless".to_string()));
    assert_eq!(
        serde_json::from_str::<Value>(&vector(None).config).unwrap()["browser"]["launchOptions"]
            ["headless"],
        true
    );
    let headed = vector(Some(&seat));
    assert!(!headed.args.contains(&"--headless".to_string()));
    assert_eq!(
        serde_json::from_str::<Value>(&headed.config).unwrap()["browser"]["launchOptions"]
            ["headless"],
        false
    );
}

#[test]
fn the_child_environment_is_the_allow_list_and_the_seat_adds_two_names() {
    let names = |v: &Vector| -> Vec<String> { v.env.iter().map(|(k, _)| k.clone()).collect() };
    assert_eq!(names(&vector(None)), ["HOME", "TMPDIR", "LANG", "PATH"]);
    let seat = Seat {
        runtime_dir: PathBuf::from("/run/user/1000"),
        display: "wayland-1".into(),
    };
    assert_eq!(
        names(&vector(Some(&seat))),
        [
            "HOME",
            "TMPDIR",
            "LANG",
            "PATH",
            "XDG_RUNTIME_DIR",
            "WAYLAND_DISPLAY"
        ]
    );
    let v = vector(None);
    let home = &v.env.iter().find(|(k, _)| k == "HOME").unwrap().1;
    assert_eq!(home, "/d/oab-computer/playwright/home");
}

#[test]
fn pw_config_is_rewritten_when_an_edit_dropped_the_flag_and_a_foreign_file_is_left() {
    let fx = Fx::new(GOOD);
    let root = fx.root();
    let good = vector(None).config;
    write_config(&root, &good).unwrap();
    let p = root.abs_path().join("pw-config.json");
    assert_eq!(std::fs::read_to_string(&p).unwrap(), good);
    // An edit that removed the flag but kept the marker.
    std::fs::write(
        &p,
        r#"{"_oabInstallerOwned":true,"browser":{"launchOptions":{"args":[]}}}"#,
    )
    .unwrap();
    write_config(&root, &good).unwrap();
    assert_eq!(std::fs::read_to_string(&p).unwrap(), good);
    assert!(std::fs::read_to_string(&p)
        .unwrap()
        .contains(PASSWORD_STORE));
    // A file the installer did not write is never replaced.
    std::fs::write(&p, r#"{"mine":1}"#).unwrap();
    assert_eq!(write_config(&root, &good), Err("config_foreign"));
    assert_eq!(std::fs::read_to_string(&p).unwrap(), r#"{"mine":1}"#);
}

// ---- restart rules (R1.5), on an injected clock ----------------------------------------------

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

#[test]
fn backoff_is_one_two_four_up_to_thirty_seconds() {
    let mut h = Health::default();
    let mut t = ms(0);
    let mut waits = Vec::new();
    for _ in 0..4 {
        h.failure(t);
        let mut w = 0;
        while h.gate(t + ms(w)).is_err() {
            w += 100;
        }
        waits.push(w);
        t += ms(w);
    }
    assert_eq!(waits, [1000, 2000, 4000, 8000]);
    // Exactly at the boundary the gate is open, a tick earlier it is not.
    let mut h = Health::default();
    h.failure(ms(10_000));
    assert_eq!(h.gate(ms(10_999)), Err("backoff"));
    assert_eq!(h.gate(ms(11_000)), Ok(()));
    // The cap.
    let mut h = Health::default();
    for i in 0..4 {
        h.failure(ms(i * 200_000));
    }
    h.consecutive = 40;
    h.failure(ms(900_000));
    assert_eq!(h.gate(ms(900_000 + 29_999)), Err("backoff"));
    assert_eq!(h.gate(ms(900_000 + 30_000)), Ok(()));
}

#[test]
fn five_failures_in_two_minutes_latch_and_old_failures_do_not_count() {
    let mut h = Health::default();
    for i in 0..4 {
        h.failure(ms(i * 10_000));
    }
    assert!(!h.is_latched());
    h.failure(ms(40_000));
    assert!(h.is_latched());
    assert_eq!(h.gate(ms(10_000_000)), Err("unavailable_after_failures"));
    h.reset();
    assert_eq!(h.gate(ms(0)), Ok(()));
    // Five failures spread over more than two minutes never latch.
    for i in 0..8 {
        h.failure(ms(i * 40_000));
        assert!(!h.is_latched(), "after {i}");
    }
}

#[test]
fn a_success_resets_the_backoff_and_a_permanent_class_is_never_retried() {
    let mut h = Health::default();
    h.failure(ms(0));
    h.failure(ms(1000));
    h.success();
    assert_eq!(h.gate(ms(1000)), Ok(()));
    h.permanent("sandbox_unavailable");
    assert_eq!(h.gate(ms(10_000_000)), Err("sandbox_unavailable"));
}

#[test]
fn memory_max_follows_the_host_between_the_bounds() {
    const MIB: u64 = 1 << 20;
    assert_eq!(memory_max_for(None), 2048 * MIB);
    assert_eq!(memory_max_for(Some(512 * 1024)), 512 * MIB);
    assert_eq!(memory_max_for(Some(64 * 1024 * 1024)), 4096 * MIB);
    let mid = memory_max_for(Some(4 * 1024 * 1024));
    assert!(mid > 2048 * MIB && mid < 3000 * MIB, "{mid}");
}

// ---- the thread rule ------------------------------------------------------------------------

#[cfg(target_os = "linux")]
fn sleeper_spec(t: &TempDir) -> crate::proc::Spec {
    crate::proc::Spec {
        exe: PathBuf::from("/bin/sleep"),
        args: vec!["30".into()],
        env: vec![],
        cwd: t.path.clone(),
    }
}

/// `PR_SET_PDEATHSIG` is tied to the thread that forked: a child forked from a short-lived thread
/// dies when that thread ends; one forked from the spawner thread outlives its caller.
#[cfg(target_os = "linux")]
#[test]
fn pdeathsig_follows_the_forking_thread_not_the_process() {
    let t = TempDir::new();
    let spec = sleeper_spec(&t);
    let scope = t.path.clone();
    let short = std::thread::spawn({
        let (spec, scope) = (
            crate::proc::Spec {
                exe: spec.exe.clone(),
                args: spec.args.clone(),
                env: vec![],
                cwd: spec.cwd.clone(),
            },
            scope.clone(),
        );
        move || crate::proc::Child::spawn(&spec, false, false, 1024, &scope).unwrap()
    })
    .join()
    .unwrap();
    let mut short = short;
    let end = Instant::now() + T;
    while Instant::now() < end && !short.has_exited() {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(short.has_exited(), "a child of an exited thread survived");
    short.stop();

    let sp = Spawner::new();
    let (spec2, scope2) = (sleeper_spec(&t), scope.clone());
    let mut long = sp
        .run(move || crate::proc::Child::spawn(&spec2, false, false, 1024, &scope2).unwrap())
        .unwrap();
    // The caller's thread is irrelevant; the spawner thread is still alive.
    std::thread::sleep(Duration::from_millis(400));
    assert!(!long.has_exited(), "the spawner's child died");
    long.stop();
}

#[test]
fn a_panicking_job_does_not_kill_the_spawner() {
    let sp = Spawner::new();
    assert!(sp.run(|| -> u8 { panic!("boom") }).is_none());
    assert_eq!(sp.run(|| 7u8), Some(7));
}

// ---- the supervisor (a stub node, a scripted mechanism) -------------------------------------

#[cfg(target_os = "linux")]
#[test]
fn a_host_where_nothing_verified_starts_no_child() {
    let fx = Fx::new(GOOD);
    let s = sup(&fx, Err(UNVERIFIED));
    for _ in 0..3 {
        assert_eq!(s.sup.ensure().err(), Some(UNVERIFIED));
    }
    assert_eq!(spawned(&s), 0);
    assert!(!s.sup.is_running());
    assert_eq!(s.sup.containment(), "unverified");
    assert_eq!(
        s.mech.verified.load(Ordering::SeqCst),
        1,
        "the answer is cached"
    );
    assert!(
        run_record::latch_is_set(&fx.root()),
        "retry needs the latch"
    );
    // `browser status --retry` removes the latch file; the next call verifies again.
    assert!(run_record::latch_clear(&fx.root()));
    assert_eq!(s.sup.ensure().err(), Some(UNVERIFIED));
    assert_eq!(s.mech.verified.load(Ordering::SeqCst), 2);
    assert_eq!(spawned(&s), 0);
}

#[cfg(target_os = "linux")]
#[test]
fn a_verified_host_starts_the_child_once_and_calls_reach_it() {
    let fx = Fx::new(GOOD);
    let s = sup(&fx, Ok(SYSTEMD));
    let r = s.sup.call("tools/list", json!({}), T).unwrap();
    assert_eq!(r["tools"][0]["name"], "browser_navigate");
    assert_eq!(s.sup.reason(), "ok");
    assert_eq!(s.sup.containment(), "systemd");
    let r2 = s.sup.call("tools/call", json!({"name": "x"}), T).unwrap();
    assert_eq!(r2["content"][0]["text"], "ok");
    assert_eq!(spawned(&s), 1);
    assert!(s.sup.is_running());
    let pid = s.sup.leader_pid().unwrap();
    assert_eq!(run_record::live(&fx.root()).len(), 1);
    assert_eq!(run_record::live(&fx.root())[0].pid, pid);
    // The launch rewrote pw-config.json with the flag.
    let cfg = std::fs::read_to_string(fx.root().abs_path().join("pw-config.json")).unwrap();
    assert!(cfg.contains(PASSWORD_STORE));
    // Stop ends the child and removes its record.
    s.sup.stop();
    assert!(!s.sup.is_running());
    assert!(run_record::live(&fx.root()).is_empty());
    assert_eq!(s.sup.ensure().err(), Some("stopping"));
}

#[cfg(target_os = "linux")]
#[test]
fn a_dead_child_is_restarted_on_the_next_call_after_the_backoff_and_not_before() {
    let fx = Fx::new(GOOD);
    let s = sup(&fx, Ok(SYSTEMD));
    s.sup.call("tools/list", json!({}), T).unwrap();
    // The child exits while handling a call.
    assert!(s.sup.call("die", json!({}), T).is_err());
    assert!(!s.sup.is_running());
    // No background restart.
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(spawned(&s), 1);
    // Next call, inside the backoff: refused without a start.
    assert_eq!(
        s.sup.call("tools/list", json!({}), T).err(),
        Some("backoff")
    );
    assert_eq!(spawned(&s), 1);
    tick(&s, 1);
    assert!(s.sup.call("tools/list", json!({}), T).is_ok());
    assert_eq!(spawned(&s), 2);
    s.sup.stop();
}

#[cfg(target_os = "linux")]
#[test]
fn five_failures_in_two_minutes_make_the_backend_unavailable_until_retry() {
    let fx = Fx::new("#!/bin/sh\nexit 1\n");
    let s = sup(&fx, Ok(SYSTEMD));
    let mut classes = Vec::new();
    for _ in 0..5 {
        classes.push(s.sup.ensure().err().unwrap());
        tick(&s, 20);
    }
    assert_eq!(classes, ["start_failed"; 5]);
    assert_eq!(spawned(&s), 5);
    assert_eq!(s.sup.ensure().err(), Some("unavailable_after_failures"));
    tick(&s, 600);
    assert_eq!(s.sup.ensure().err(), Some("unavailable_after_failures"));
    assert_eq!(spawned(&s), 5, "a latched backend starts nothing");
    assert!(run_record::latch_is_set(&fx.root()));
    // `browser status --retry`.
    assert!(run_record::latch_clear(&fx.root()));
    assert_eq!(s.sup.ensure().err(), Some("start_failed"));
    assert_eq!(spawned(&s), 6);
}

#[cfg(target_os = "linux")]
#[test]
fn a_missing_sandbox_is_recorded_and_never_retried() {
    let fx = Fx::new("#!/bin/sh\necho 'No usable sandbox!' >&2\nexit 1\n");
    let s = sup(&fx, Ok(SYSTEMD));
    assert_eq!(s.sup.ensure().err(), Some("sandbox_unavailable"));
    tick(&s, 3600);
    assert_eq!(s.sup.ensure().err(), Some("sandbox_unavailable"));
    assert_eq!(spawned(&s), 1);
    assert_eq!(
        run_record::refusal_get(&fx.root()).as_deref(),
        Some("sandbox_unavailable")
    );
}

#[cfg(target_os = "linux")]
#[test]
fn a_profile_locked_by_a_live_holder_is_not_retried_but_a_stale_lock_is() {
    let script = "#!/bin/sh\necho 'The profile appears to be in use by another Chromium process' >&2\nexit 1\n";
    // No live holder: an ordinary failure.
    let fx = Fx::new(script);
    let s = sup(&fx, Ok(SYSTEMD));
    assert_eq!(s.sup.ensure().err(), Some("start_failed"));
    // A live holder (a run record naming a live process).
    let fx2 = Fx::new(script);
    let mut holder = std::process::Command::new("sleep")
        .arg("30")
        .spawn()
        .unwrap();
    let _h = run_record::write(&fx2.root(), "cli", holder.id(), None).unwrap();
    let s2 = sup(&fx2, Ok(SYSTEMD));
    assert_eq!(s2.sup.ensure().err(), Some("profile_locked"));
    tick(&s2, 3600);
    assert_eq!(s2.sup.ensure().err(), Some("profile_locked"));
    assert_eq!(spawned(&s2), 1);
    holder.kill().unwrap();
    holder.wait().unwrap();
}

#[cfg(target_os = "linux")]
#[test]
fn a_wrong_server_is_not_accepted() {
    let notpw = GOOD.replace("Playwright", "Something Else");
    let fx = Fx::new(&notpw);
    let s = sup(&fx, Ok(SYSTEMD));
    assert_eq!(s.sup.ensure().err(), Some("start_failed"));
    assert!(!s.sup.is_running());
}

#[cfg(target_os = "linux")]
#[test]
fn a_canary_in_stderr_and_stdout_reaches_no_error_no_file_and_no_record() {
    let canary = "CANARY-TOKEN-5d2e91";
    let script = format!(
        "#!/bin/sh\necho {canary} >&2\necho '{canary}'\nprintf '{{\"x\":\"{canary}\"}}\\n'\nexit 1\n"
    );
    let fx = Fx::new(&script);
    let s = sup(&fx, Ok(SYSTEMD));
    let e = s.sup.ensure().err().unwrap();
    assert!(!e.contains(canary) && !s.sup.reason().contains(canary));
    // Every file under the data root.
    fn scan(dir: &Path, canary: &str, hits: &mut Vec<PathBuf>) {
        for e in std::fs::read_dir(dir).unwrap().flatten() {
            let p = e.path();
            let ft = e.file_type().unwrap();
            if ft.is_dir() {
                scan(&p, canary, hits);
            } else if ft.is_file()
                && std::fs::read(&p).is_ok_and(|b| {
                    String::from_utf8_lossy(&b).contains(canary) && !p.ends_with("node/bin/node")
                })
            {
                hits.push(p);
            }
        }
    }
    let mut hits = Vec::new();
    scan(fx.root().abs_path(), canary, &mut hits);
    assert!(hits.is_empty(), "{hits:?}");
}

#[cfg(target_os = "linux")]
#[test]
fn a_damaged_or_missing_install_starts_nothing() {
    let fx = Fx::new(GOOD);
    // A damaged install: the start refuses and spawns nothing.
    std::fs::remove_file(fx.root().abs_path().join("pw-1/node/bin/node")).unwrap();
    let s = sup(&fx, Ok(SYSTEMD));
    assert_eq!(s.sup.ensure().err(), Some("install_invalid"));
    assert_eq!(spawned(&s), 0);
    let empty = Sup {
        sup: Supervisor::new(
            Config::production(TempDir::new().base()),
            Arc::new(Availability::new(Arc::new(Direct::new(Ok(SYSTEMD))))),
        ),
        mech: Arc::new(Direct::new(Ok(SYSTEMD))),
        ms: Arc::new(AtomicU64::new(0)),
    };
    assert_eq!(empty.sup.ensure().err(), Some("not_installed"));
}

#[cfg(target_os = "linux")]
#[test]
fn concurrent_callers_share_one_child() {
    let fx = Fx::new(GOOD);
    let s = Arc::new(sup(&fx, Ok(SYSTEMD)));
    let n = Arc::new(AtomicUsize::new(0));
    let hs: Vec<_> = (0..8)
        .map(|_| {
            let (s, n) = (Arc::clone(&s), Arc::clone(&n));
            std::thread::spawn(move || {
                if s.sup.call("tools/list", json!({}), T).is_ok() {
                    n.fetch_add(1, Ordering::SeqCst);
                }
            })
        })
        .collect();
    for h in hs {
        h.join().unwrap();
    }
    assert_eq!(n.load(Ordering::SeqCst), 8);
    assert_eq!(spawned(&s), 1);
    s.sup.stop();
}

/// Chromium starts at the first navigation, so a missing sandbox shows as an error result of a tool
/// call, not as a failed start. The result reaches the caller, the child stops, the refusal is
/// recorded and the backend is not retried.
#[cfg(target_os = "linux")]
#[test]
fn a_sandbox_refusal_seen_at_the_first_tool_call_is_recorded_and_latches() {
    let script = GOOD.replace(
        r#"*'"method":"tools/call"'*) printf"#,
        r#"*'"method":"tools/call"'*) echo "No usable sandbox! Update your kernel" >&2; printf"#,
    ).replace(r#""text":"ok"}]}}"#, r#""text":"launch failed"}],"isError":true}}"#);
    assert!(script.contains("isError") && script.contains("No usable sandbox"));
    let fx = Fx::new(&script);
    let s = sup(&fx, Ok(SYSTEMD));
    let r = s
        .sup
        .call("tools/call", json!({"name": "browser_navigate"}), T)
        .unwrap();
    // The caller still gets the tool's own result.
    assert_eq!(r["isError"], true);
    assert!(!s.sup.is_running(), "the child was left running");
    assert_eq!(s.sup.reason(), "sandbox_unavailable");
    assert_eq!(
        run_record::refusal_get(&fx.root()).as_deref(),
        Some("sandbox_unavailable")
    );
    tick(&s, 3600);
    assert_eq!(s.sup.ensure().err(), Some("sandbox_unavailable"));
    assert_eq!(spawned(&s), 1);
}

/// An error result with ordinary stderr noise is not a refusal: the child stays and nothing is
/// recorded.
#[cfg(target_os = "linux")]
#[test]
fn an_ordinary_tool_error_is_not_a_refusal() {
    let script = GOOD
        .replace(
            r#"*'"method":"tools/call"'*) printf"#,
            r#"*'"method":"tools/call"'*) echo "EACCES: permission denied, open /x" >&2; printf"#,
        )
        .replace(r#""text":"ok"}]}}"#, r#""text":"nope"}],"isError":true}}"#);
    let fx = Fx::new(&script);
    let s = sup(&fx, Ok(SYSTEMD));
    let r = s
        .sup
        .call("tools/call", json!({"name": "browser_click"}), T)
        .unwrap();
    assert_eq!(r["isError"], true);
    assert!(s.sup.is_running());
    assert_eq!(run_record::refusal_get(&fx.root()), None);
    s.sup.stop();
}
