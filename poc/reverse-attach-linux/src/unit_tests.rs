use super::*;

fn req(kind: Kind) -> Req {
    Req {
        name: "oab-browser-0a1b2c3d".into(),
        kind,
        cwd: PathBuf::from("/data/oab-computer/playwright/pw-1"),
        env: vec![
            ("HOME".into(), "/data/oab-computer/playwright/home".into()),
            ("LANG".into(), "C.UTF-8".into()),
            ("PATH".into(), "/data/pw-1/node/bin:/usr/bin:/bin".into()),
        ],
        exe: PathBuf::from("/data/pw-1/node/bin/node"),
        args: vec!["/data/pw-1/cli.js".into(), "--sandbox".into()],
        mount_rw: vec![],
        memory_max: 2 << 30,
        tasks_max: 4096,
    }
}

fn managed() -> Req {
    req(Kind::Managed {
        daemon_unit: "oab-computer.service".into(),
    })
}

fn props(a: &[String]) -> Vec<&str> {
    a.windows(2)
        .filter(|w| w[0] == "-p")
        .map(|w| w[1].as_str())
        .collect()
}

#[test]
fn the_command_begins_with_env_i_and_lists_exactly_the_allow_list() {
    let r = managed();
    let a = run_args(&r).unwrap();
    let dash = a.iter().position(|x| x == "--").unwrap();
    let cmd = &a[dash + 1..];
    assert_eq!(&cmd[..2], ["/usr/bin/env", "-i"]);
    // `-C <cwd>`: no `WorkingDirectory=` and no `--working-directory` reach systemd.
    assert_eq!(&cmd[2..4], ["-C", "/data/oab-computer/playwright/pw-1"]);
    let pairs: Vec<&String> = cmd[4..4 + r.env.len()].iter().collect();
    let expect: Vec<String> = r.env.iter().map(|(k, v)| format!("{k}={v}")).collect();
    assert_eq!(pairs, expect.iter().collect::<Vec<_>>());
    assert_eq!(cmd[4 + r.env.len()], "/data/pw-1/node/bin/node");
    assert!(!a
        .iter()
        .any(|x| x.contains("WorkingDirectory") || x.starts_with("--working-directory")));
    assert!(!a.iter().any(|x| x == "-E"
        || x.starts_with("--setenv")
        || x.starts_with("--property=Environment")
        || x.starts_with("Environment")
        || x.starts_with("PassEnvironment")
        || x.starts_with("EnvironmentFile")));
}

#[test]
fn a_managed_unit_is_bound_to_the_daemon_and_carries_every_listed_property() {
    let a = run_args(&managed()).unwrap();
    assert!(a.contains(&"--user".to_string()));
    assert!(a.contains(&"--collect".to_string()));
    assert!(a.contains(&"--pipe".to_string()));
    assert!(a.contains(&"--unit=oab-browser-0a1b2c3d".to_string()));
    let p = props(&a);
    for want in COMMON_PROPS {
        assert!(p.contains(&want), "{want}");
    }
    for want in [
        "KillMode=control-group",
        "SendSIGKILL=yes",
        "TimeoutStopSec=10",
        "BindsTo=oab-computer.service",
        "After=oab-computer.service",
        "UMask=0077",
        "MemoryMax=2147483648",
        "TasksMax=4096",
    ] {
        assert!(p.contains(&want), "{want}");
    }
    assert!(!p.iter().any(|x| x.starts_with("RuntimeMaxSec")));
}

#[test]
fn a_cli_unit_has_a_runtime_bound_and_binds_to_nothing() {
    let a = run_args(&req(Kind::Cli {
        runtime_max: Duration::from_secs(300),
    }))
    .unwrap();
    let p = props(&a);
    assert!(p.contains(&"RuntimeMaxSec=300"));
    assert!(p.contains(&"KillMode=control-group"));
    assert!(!p
        .iter()
        .any(|x| x.starts_with("BindsTo") || x.starts_with("After") || x.starts_with("Requires")));
}

#[test]
fn the_namespace_properties_never_appear_and_the_mount_tier_only_when_asked() {
    for r in [
        managed(),
        req(Kind::Cli {
            runtime_max: Duration::from_secs(9),
        }),
    ] {
        let a = run_args(&r).unwrap();
        for never in NEVER {
            assert!(!a.iter().any(|x| x.contains(never)), "{never}");
        }
        assert!(!props(&a).iter().any(|x| x.starts_with("PrivateTmp")));
    }
    let mut r = managed();
    r.mount_rw = vec![
        PathBuf::from("/data/oab-computer/playwright"),
        PathBuf::from("/run/user/1000/oab-pw-ab"),
    ];
    let a = run_args(&r).unwrap();
    let p = props(&a);
    for want in [
        "PrivateTmp=yes",
        "ProtectHome=read-only",
        "ProtectSystem=full",
        "ReadWritePaths=/data/oab-computer/playwright /run/user/1000/oab-pw-ab",
    ] {
        assert!(p.contains(&want), "{want}");
    }
    for never in NEVER {
        assert!(!a.iter().any(|x| x.contains(never)), "{never}");
    }
}

#[test]
fn requests_systemd_would_reinterpret_are_refused() {
    type Mutate = Box<dyn Fn(&mut Req)>;
    let bad: Vec<Mutate> = vec![
        Box::new(|r| r.name = "x".into()),
        Box::new(|r| r.name = "oab-a b".into()),
        Box::new(|r| r.name = "oab-../x".into()),
        Box::new(|r| r.cwd = PathBuf::from("relative")),
        Box::new(|r| r.cwd = PathBuf::from("nul\0/x")),
        Box::new(|r| r.exe = PathBuf::from("node")),
        Box::new(|r| r.env.push(("lower".into(), "x".into()))),
        Box::new(|r| r.env.push(("A".into(), "line\nbreak".into()))),
        Box::new(|r| r.env.push(("1A".into(), "x".into()))),
        Box::new(|r| r.args.push("nul\0".into())),
        Box::new(|r| {
            r.kind = Kind::Managed {
                daemon_unit: "--bad".into(),
            }
        }),
        Box::new(|r| r.mount_rw = vec![PathBuf::from("/a b")]),
    ];
    for (i, f) in bad.iter().enumerate() {
        let mut r = managed();
        f(&mut r);
        assert_eq!(run_args(&r), Err(INVALID), "case {i}");
    }
}
