//! `conformance/pins_vectors.json` (ADR linux-browser-tier D1) against the Rust validator. Each
//! case mutates the tracked `release/playwright-pins/pins.json` and states the exact sorted list
//! of problem names. The Swift `PlaywrightManifest.validate` is the other implementation
//! (`PinsVectorTests`); both must give these answers.

use std::collections::BTreeSet;

use serde_json::Value;

use crate::manifest::{Manifest, PlatformId, PINS_JSON};

const VECTORS: &str = include_str!("../../../conformance/pins_vectors.json");

fn doc() -> Value {
    serde_json::from_str(VECTORS).expect("pins_vectors.json is JSON")
}

fn pins() -> Value {
    serde_json::from_str(PINS_JSON).expect("pins.json is JSON")
}

fn path(op: &Value, key: &str) -> Vec<String> {
    op[key]
        .as_array()
        .unwrap_or_else(|| panic!("{key} is a path"))
        .iter()
        .map(|s| s.as_str().expect("path component").to_string())
        .collect()
}

fn get<'a>(root: &'a Value, p: &[String]) -> Option<&'a Value> {
    let mut cur = root;
    for k in p {
        cur = cur.get(k)?;
    }
    Some(cur)
}

/// Set (`Some`) or remove (`None`) the value at `p`, creating objects on the way.
fn put(root: &mut Value, p: &[String], value: Option<Value>) {
    let (last, parents) = p.split_last().expect("non-empty path");
    let mut cur = root;
    for k in parents {
        if cur.get(k).is_none_or(|v| !v.is_object()) {
            cur[k] = serde_json::json!({});
        }
        cur = cur.get_mut(k).unwrap();
    }
    let obj = cur.as_object_mut().expect("object parent");
    match value {
        Some(v) => {
            obj.insert(last.clone(), v);
        }
        None => {
            obj.remove(last);
        }
    }
}

/// `{browserVersion}`, `{revision}` and `{nodeVersion}`, taken from the pins being mutated.
fn expand(v: &Value, base: &Value) -> Value {
    let Some(s) = v.as_str() else {
        return v.clone();
    };
    let field = |a: &str, b: &str| base[a][b].as_str().expect("pins field").to_string();
    Value::String(
        s.replace("{browserVersion}", &field("chromium", "browserVersion"))
            .replace("{revision}", &field("chromium", "revision"))
            .replace("{nodeVersion}", &field("node", "version")),
    )
}

fn apply(op: &Value, obj: &mut Value, base: &Value) {
    let p = path(op, "path");
    match op["op"].as_str().expect("op") {
        "set" => put(obj, &p, Some(expand(&op["value"], base))),
        "remove" => put(obj, &p, None),
        "copy" => {
            let v = get(obj, &path(op, "from")).expect("copy source").clone();
            put(obj, &p, Some(v));
        }
        "replace" => {
            let s = get(obj, &p)
                .and_then(Value::as_str)
                .expect("replace target")
                .to_string();
            let from = expand(&op["from"], base);
            let to = expand(&op["to"], base);
            let (from, to) = (from.as_str().unwrap(), to.as_str().unwrap());
            assert!(s.contains(from), "replace target {from} not found");
            put(obj, &p, Some(Value::String(s.replace(from, to))));
        }
        other => panic!("unknown op {other}"),
    }
}

#[test]
fn every_pins_vector_gives_the_same_problems_as_the_oracle() {
    let d = doc();
    let cases = d["cases"].as_array().expect("cases");
    assert!(cases.len() >= 40, "{} cases", cases.len());
    let base = pins();
    let mut names = BTreeSet::new();
    for c in cases {
        let name = c["name"].as_str().expect("name");
        assert!(names.insert(name.to_string()), "duplicate case {name}");
        let mut obj = base.clone();
        for op in c["ops"].as_array().expect("ops") {
            apply(op, &mut obj, &base);
        }
        let m = Manifest::decode(&serde_json::to_string(&obj).unwrap())
            .unwrap_or_else(|e| panic!("{name}: {e}"));
        let mut got = m.validate();
        got.sort();
        let mut want: Vec<String> = c["problems"]
            .as_array()
            .expect("problems")
            .iter()
            .map(|s| s.as_str().unwrap().to_string())
            .collect();
        want.sort();
        assert_eq!(got, want, "{name}");
        assert_eq!(got.is_empty(), c["valid"].as_bool().unwrap(), "{name}");
    }
}

#[test]
fn platform_selection_vectors() {
    let d = doc();
    let rows = d["selection"].as_array().expect("selection");
    assert!(rows.len() >= 8, "{} rows", rows.len());
    for r in rows {
        let (os, arch) = (r["os"].as_str().unwrap(), r["arch"].as_str().unwrap());
        assert_eq!(
            PlatformId::select(os, arch).map(PlatformId::as_str),
            r["platform"].as_str(),
            "{os}/{arch}"
        );
    }
}

#[test]
fn the_shipped_pins_cover_all_four_platforms_with_no_silent_skip() {
    let m = Manifest::embedded();
    let all: BTreeSet<&str> = PlatformId::ALL.iter().map(|p| p.as_str()).collect();
    assert_eq!(
        all,
        BTreeSet::from(["darwin-arm64", "darwin-x64", "linux-x64", "linux-arm64"])
    );
    for p in PlatformId::ALL {
        assert!(m.node_artifact(p).is_some(), "node/{}", p.as_str());
        let c = m
            .chromium_artifact(p)
            .unwrap_or_else(|| panic!("chromium/{}", p.as_str()));
        assert!(c.source.is_some());
        if p.is_linux() {
            assert!(c.min_glibc.is_some());
        }
    }
}
