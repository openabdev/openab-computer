use super::*;
use crate::child::tests::{sup, Fx, GOOD};
use crate::containment::SYSTEMD;
use crate::mcp::{handle_tool_call_with, tool_list_with, INVALID_PARAMS};

fn env(off: Option<&str>, backend: Option<&str>, upstream: Option<&str>) -> EnvIn {
    EnvIn {
        off: off.map(str::to_string),
        backend: backend.map(str::to_string),
        upstream: upstream.map(str::to_string),
    }
}

const LINE: &str = "browser=http://127.0.0.1:8794/mcp";

fn pick(e: &EnvIn, i: Installed) -> (Choice, bool) {
    let d = select(e, i);
    (d.choice, d.external_ignored)
}

#[test]
fn managed_wins_whenever_it_is_installed_and_a_stale_line_is_ignored_and_reported() {
    use Choice::*;
    let line = Some(LINE);
    assert_eq!(
        pick(&env(None, None, line), Installed::Yes),
        (Managed, true)
    );
    assert_eq!(
        pick(&env(None, None, None), Installed::Yes),
        (Managed, false)
    );
    assert_eq!(
        pick(&env(None, Some("managed"), line), Installed::Yes),
        (Managed, true)
    );
    // Other upstream names are not the browser line.
    assert_eq!(
        pick(
            &env(None, None, Some("other=http://127.0.0.1:1/x")),
            Installed::Yes
        ),
        (Managed, false)
    );
}

#[test]
fn external_needs_the_explicit_trust_act_when_managed_is_installed() {
    use Choice::*;
    assert_eq!(
        pick(&env(None, Some("external"), Some(LINE)), Installed::Yes),
        (External, false)
    );
    // Explicit external with no line: unavailable, and never the managed install (R4.2).
    for i in [Installed::Yes, Installed::No, Installed::Invalid] {
        assert_eq!(
            pick(&env(None, Some("external"), None), i),
            (Unavailable("external_not_configured"), false),
            "{i:?}"
        );
    }
}

#[test]
fn with_nothing_installed_the_line_alone_is_external() {
    use Choice::*;
    assert_eq!(
        pick(&env(None, None, Some(LINE)), Installed::No),
        (External, false)
    );
    assert_eq!(
        pick(&env(None, None, None), Installed::No),
        (Unavailable("not_installed"), false)
    );
    assert_eq!(
        pick(&env(None, Some("managed"), Some(LINE)), Installed::No),
        (Unavailable("not_installed"), false),
        "an explicit managed never falls to the line"
    );
}

#[test]
fn a_damaged_install_is_unavailable_and_never_falls_to_external() {
    use Choice::*;
    assert_eq!(
        pick(&env(None, None, Some(LINE)), Installed::Invalid),
        (Unavailable("install_invalid"), true)
    );
}

#[test]
fn off_switches_managed_off_and_the_line_alone_still_serves_as_before_the_cutover() {
    use Choice::*;
    assert_eq!(
        pick(&env(Some("off"), None, None), Installed::Yes),
        (Off, false)
    );
    assert_eq!(
        pick(&env(Some("off"), None, None), Installed::No),
        (Off, false)
    );
    // With a managed install the stale line is not adopted without the explicit flag (D5, R4.1).
    assert_eq!(
        pick(&env(Some("off"), None, Some(LINE)), Installed::Yes),
        (Off, true)
    );
    assert_eq!(
        pick(&env(Some("off"), None, Some(LINE)), Installed::No),
        (External, false)
    );
    assert_eq!(
        pick(
            &env(Some("off"), Some("external"), Some(LINE)),
            Installed::Yes
        ),
        (External, false)
    );
    assert_eq!(
        pick(
            &env(Some("off"), Some("managed"), Some(LINE)),
            Installed::Yes
        ),
        (Off, true)
    );
    // Only the exact word turns it off.
    assert_eq!(
        pick(&env(Some("0"), None, None), Installed::Yes),
        (Managed, false)
    );
    assert_eq!(
        pick(&env(Some(" off "), None, None), Installed::Yes),
        (Off, false)
    );
}

#[test]
fn an_unknown_backend_name_is_unavailable() {
    assert_eq!(
        pick(&env(None, Some("Managed"), Some(LINE)), Installed::Yes),
        (Choice::Unavailable("backend_invalid"), false)
    );
}

#[test]
fn the_upstream_line_parses_names_and_urls() {
    assert_eq!(
        parse_upstream_line(
            "browser=http://127.0.0.1:1/mcp, other = http://127.0.0.1:2/x ,bad,=x,n=,a b=u"
        ),
        [
            ("browser".to_string(), "http://127.0.0.1:1/mcp".to_string()),
            ("other".to_string(), "http://127.0.0.1:2/x".to_string())
        ]
    );
    assert!(parse_upstream_line("").is_empty());
}

#[test]
fn sys_info_before_the_router_exists_reports_nothing_available() {
    let v = sys_info_field();
    // The fixed set of fields, and nothing else.
    let mut keys: Vec<&String> = v.as_object().unwrap().keys().collect();
    keys.sort();
    assert_eq!(
        keys,
        [
            "backend",
            "containment",
            "display",
            "external_upstream_ignored",
            "reason"
        ]
    );
    assert_ne!(v["backend"], "managed");
}

// ---- Managed over a stub child ---------------------------------------------------------------

fn managed(
    fx: &Fx,
    verify: Result<crate::containment::Mode, &'static str>,
) -> (Arc<Managed>, crate::child::tests::Sup) {
    let s = sup(fx, verify);
    // `Sup` owns the supervisor; Managed shares an Arc of a second one over the same pieces.
    let sup2 = Arc::new(Supervisor::new(
        {
            let mut c = Config::production(fx.t.base());
            c.seat = Arc::new(|| None);
            c
        },
        Arc::new(Availability::new(s.mech.clone())),
    ));
    (Arc::new(Managed::new(sup2)), s)
}

#[cfg(target_os = "linux")]
#[test]
fn managed_lists_exactly_the_catalog_names_the_child_serves_and_owner_sees_them_observe_none() {
    let fx = Fx::new(GOOD);
    let (m, s) = managed(&fx, Ok(SYSTEMD));
    let names: Vec<String> = m
        .tools()
        .iter()
        .map(|t| t["name"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(
        names,
        ["browser_navigate"],
        "extra_tool is filtered out (D15)"
    );
    let ups: Vec<Arc<dyn Upstream>> = vec![m.clone()];
    let owner = tool_list_with("owner", &ups);
    let listed: Vec<&str> = owner
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    assert!(listed.contains(&"browser_navigate") && !listed.contains(&"extra_tool"));
    let observe = tool_list_with("observe", &ups);
    assert!(!observe
        .as_array()
        .unwrap()
        .iter()
        .any(|t| t["name"].as_str().unwrap().starts_with("browser_")));
    // Listing under `observe` asked the child for nothing: it was started once, for the owner.
    assert_eq!(
        s.mech.spawned.load(std::sync::atomic::Ordering::SeqCst),
        1,
        "observe started a child"
    );
    // A call under `observe` is an unknown tool and never reaches the child.
    let err = handle_tool_call_with(
        &json!({"name": "browser_navigate", "arguments": {}}),
        "observe",
        None,
        &ups,
    )
    .unwrap_err();
    assert_eq!(err.0, INVALID_PARAMS);
    // Under `owner` it reaches the child and returns its result.
    let ok = handle_tool_call_with(
        &json!({"name": "browser_navigate", "arguments": {}}),
        "owner",
        None,
        &ups,
    )
    .unwrap();
    assert_eq!(ok["content"][0]["text"], "ok");
    assert_eq!(m.status().backend, "managed");
    assert_eq!(m.status().containment, "systemd");
    m.supervisor().stop();
}

#[cfg(target_os = "linux")]
#[test]
fn a_tool_outside_the_catalog_is_never_forwarded_to_the_child() {
    let fx = Fx::new(GOOD);
    let (m, s) = managed(&fx, Ok(SYSTEMD));
    assert_eq!(
        m.call("extra_tool", json!({})).unwrap_err(),
        "upstream_unknown_tool"
    );
    assert_eq!(s.mech.spawned.load(std::sync::atomic::Ordering::SeqCst), 0);
    assert!(!m.owns("extra_tool") && m.owns("browser_close"));
}

#[cfg(target_os = "linux")]
#[test]
fn unverified_containment_is_unavailable_with_no_child_and_no_fall_to_external() {
    let fx = Fx::new(GOOD);
    let (m, s) = managed(&fx, Err(crate::containment::UNVERIFIED));
    // Before the self-test has run nothing is reported available.
    assert_ne!(m.status().backend, "managed");
    m.supervisor().verify_now();
    let st = m.status();
    assert_eq!(
        (st.backend, st.reason.as_str()),
        ("unavailable", "containment_unverified")
    );
    assert_eq!(st.containment, "unverified");
    assert_eq!(
        m.call("browser_navigate", json!({})).unwrap_err(),
        "containment_unverified"
    );
    assert!(m.tools().is_empty());
    assert_eq!(s.mech.spawned.load(std::sync::atomic::Ordering::SeqCst), 0);
    assert!(!m.supervisor().is_running());
}

#[cfg(target_os = "linux")]
#[test]
fn a_down_backend_answers_with_its_class_not_unknown_tool() {
    let fx = Fx::new("#!/bin/sh\nexit 1\n");
    let (m, _s) = managed(&fx, Ok(SYSTEMD));
    let ups: Vec<Arc<dyn Upstream>> = vec![m];
    let err = handle_tool_call_with(
        &json!({"name": "browser_click", "arguments": {}}),
        "owner",
        None,
        &ups,
    )
    .unwrap_err();
    assert_eq!(err, (-32000, "start_failed".to_string()));
}
