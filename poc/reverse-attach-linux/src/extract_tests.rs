//! Hostile and benign archives, generated here, never fetched. Every rejection test checks the
//! exact reason, that the staging directory is still empty, and that a sentinel file next to it
//! is untouched.

use super::*;
use flate2::write::{DeflateEncoder, GzEncoder};
use flate2::Compression;
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

// ---- fixtures -------------------------------------------------------------------------------

struct Fx {
    root: PathBuf,
    archive: PathBuf,
    stage: PathBuf,
    outside: PathBuf,
}

impl Fx {
    fn new(bytes: &[u8]) -> Fx {
        static N: AtomicU32 = AtomicU32::new(0);
        let root = std::env::temp_dir().join(format!(
            "oab-l1a-x-{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = fs::remove_dir_all(&root);
        let (archive, stage, outside) = (
            root.join("archive.bin"),
            root.join("stage"),
            root.join("outside"),
        );
        fs::create_dir_all(&stage).unwrap();
        fs::create_dir_all(&outside).unwrap();
        fs::write(&archive, bytes).unwrap();
        fs::write(outside.join("sentinel"), b"sentinel").unwrap();
        fs::set_permissions(outside.join("sentinel"), fs::Permissions::from_mode(0o640)).unwrap();
        Fx {
            root,
            archive,
            stage,
            outside,
        }
    }
    fn art(&self) -> VerifiedArtifact {
        VerifiedArtifact::unchecked_for_tests(&self.archive)
    }
    fn stage_is_empty(&self) -> bool {
        fs::read_dir(&self.stage).unwrap().count() == 0
    }
    fn outside_untouched(&self) -> bool {
        let names: Vec<_> = fs::read_dir(&self.outside)
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        names.len() == 1
            && fs::read(self.outside.join("sentinel")).unwrap() == b"sentinel"
            && fs::metadata(self.outside.join("sentinel"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777
                == 0o640
    }
}

impl Drop for Fx {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn lim() -> Limits {
    Limits {
        max_entries: 100,
        max_total_bytes: 1 << 20,
        max_entry_bytes: 1 << 20,
        strip_components: 0,
        max_ratio: DEFAULT_MAX_RATIO,
    }
}

fn gz(b: &[u8]) -> Vec<u8> {
    let mut e = GzEncoder::new(Vec::new(), Compression::default());
    e.write_all(b).unwrap();
    e.finish().unwrap()
}

fn deflate(b: &[u8]) -> Vec<u8> {
    let mut e = DeflateEncoder::new(Vec::new(), Compression::default());
    e.write_all(b).unwrap();
    e.finish().unwrap()
}

fn crc(b: &[u8]) -> u32 {
    let mut c = Crc::new();
    c.update(b);
    c.sum()
}

// ---- tar builder ----------------------------------------------------------------------------

fn put_oct(dst: &mut [u8], v: u64, digits: usize) {
    let s = format!("{v:0digits$o}");
    dst[..s.len()].copy_from_slice(s.as_bytes());
}

fn tar_header(name: &[u8], typ: u8, mode: u32, size: u64, link: &str) -> [u8; 512] {
    let mut h = [0u8; 512];
    let n = name.len().min(100);
    h[..n].copy_from_slice(&name[..n]);
    put_oct(&mut h[100..108], u64::from(mode), 7);
    put_oct(&mut h[108..116], 0, 7);
    put_oct(&mut h[116..124], 0, 7);
    put_oct(&mut h[124..136], size, 11);
    put_oct(&mut h[136..148], 0, 11);
    h[148..156].copy_from_slice(b"        ");
    h[156] = typ;
    h[157..157 + link.len().min(100)].copy_from_slice(&link.as_bytes()[..link.len().min(100)]);
    h[257..263].copy_from_slice(b"ustar\0");
    h[263..265].copy_from_slice(b"00");
    let sum: u32 = h.iter().map(|b| u32::from(*b)).sum();
    h[148..156].copy_from_slice(format!("{sum:06o}\0 ").as_bytes());
    h
}

#[derive(Default)]
struct TarBuilder {
    out: Vec<u8>,
}

impl TarBuilder {
    fn raw(&mut self, h: [u8; 512], data: &[u8]) -> &mut Self {
        self.out.extend_from_slice(&h);
        self.out.extend_from_slice(data);
        self.out.resize(self.out.len().div_ceil(512) * 512, 0);
        self
    }
    fn file(&mut self, name: &str, data: &[u8], mode: u32) -> &mut Self {
        self.long(name);
        self.raw(
            tar_header(name.as_bytes(), b'0', mode, data.len() as u64, ""),
            data,
        )
    }
    fn dir(&mut self, name: &str) -> &mut Self {
        self.long(name);
        self.raw(tar_header(name.as_bytes(), b'5', 0o755, 0, ""), b"")
    }
    fn symlink(&mut self, name: &str, target: &str) -> &mut Self {
        self.long(name);
        self.raw(tar_header(name.as_bytes(), b'2', 0o777, 0, target), b"")
    }
    fn special(&mut self, name: &str, typ: u8) -> &mut Self {
        self.raw(tar_header(name.as_bytes(), typ, 0o644, 0, "x"), b"")
    }
    /// A GNU long-name record when the name does not fit the 100 byte field.
    fn long(&mut self, name: &str) {
        if name.len() > 100 {
            self.long_name(name);
        }
    }
    fn long_name(&mut self, name: &str) -> &mut Self {
        let mut d = name.as_bytes().to_vec();
        d.push(0);
        self.raw(
            tar_header(b"././@LongLink", b'L', 0, d.len() as u64, ""),
            &d,
        )
    }
    fn pax(&mut self, recs: &[(&str, &[u8])]) -> &mut Self {
        let mut d = Vec::new();
        for (k, v) in recs {
            let body_len = k.len() + v.len() + 3; // " " + "=" + "\n"
            let mut len = body_len + 1;
            while len.to_string().len() + body_len != len {
                len = len.to_string().len() + body_len;
            }
            d.extend_from_slice(format!("{len} {k}=").as_bytes());
            d.extend_from_slice(v);
            d.push(b'\n');
        }
        self.raw(
            tar_header(b"PaxHeader", b'x', 0o644, d.len() as u64, ""),
            &d,
        )
    }
    fn bytes(&self) -> Vec<u8> {
        let mut o = self.out.clone();
        o.extend_from_slice(&[0u8; 1024]);
        o
    }
    fn gz(&self) -> Vec<u8> {
        gz(&self.bytes())
    }
}

// ---- zip builder ----------------------------------------------------------------------------

#[derive(Clone)]
struct ZEntry {
    name: Vec<u8>,
    data: Vec<u8>,
    deflate: bool,
    unix_mode: u32,
    flags: u16,
    method: Option<u16>,
    /// Sizes and CRC the headers claim, when they should differ from the data.
    lie_usize: Option<u32>,
    lie_crc: Option<u32>,
    local_name: Option<Vec<u8>>,
}

impl ZEntry {
    fn file(name: &str, data: &[u8], deflate: bool, mode: u32) -> ZEntry {
        ZEntry {
            name: name.into(),
            data: data.to_vec(),
            deflate,
            unix_mode: 0o100000 | mode,
            flags: 0,
            method: None,
            lie_usize: None,
            lie_crc: None,
            local_name: None,
        }
    }
    fn dir(name: &str) -> ZEntry {
        let n = if name.ends_with('/') {
            name.to_string()
        } else {
            format!("{name}/")
        };
        ZEntry {
            unix_mode: 0o040755,
            ..ZEntry::file(&n, b"", false, 0)
        }
    }
    fn symlink(name: &str, target: &str) -> ZEntry {
        ZEntry {
            unix_mode: 0o120777,
            ..ZEntry::file(name, target.as_bytes(), false, 0)
        }
    }
}

fn zip_build(entries: &[ZEntry]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut central = Vec::new();
    for e in entries {
        let body = if e.deflate {
            deflate(&e.data)
        } else {
            e.data.clone()
        };
        let method = e.method.unwrap_or(if e.deflate { 8 } else { 0 });
        let c = e.lie_crc.unwrap_or_else(|| crc(&e.data));
        let usize_ = e.lie_usize.unwrap_or(e.data.len() as u32);
        let lho = out.len() as u32;
        let lname = e.local_name.clone().unwrap_or_else(|| e.name.clone());
        out.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
        out.extend_from_slice(&20u16.to_le_bytes());
        out.extend_from_slice(&e.flags.to_le_bytes());
        out.extend_from_slice(&method.to_le_bytes());
        out.extend_from_slice(&[0; 4]);
        out.extend_from_slice(&c.to_le_bytes());
        out.extend_from_slice(&(body.len() as u32).to_le_bytes());
        out.extend_from_slice(&usize_.to_le_bytes());
        out.extend_from_slice(&(lname.len() as u16).to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&lname);
        out.extend_from_slice(&body);
        central.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
        central.extend_from_slice(&((3u16 << 8) | 20).to_le_bytes());
        central.extend_from_slice(&20u16.to_le_bytes());
        central.extend_from_slice(&e.flags.to_le_bytes());
        central.extend_from_slice(&method.to_le_bytes());
        central.extend_from_slice(&[0; 4]);
        central.extend_from_slice(&c.to_le_bytes());
        central.extend_from_slice(&(body.len() as u32).to_le_bytes());
        central.extend_from_slice(&usize_.to_le_bytes());
        central.extend_from_slice(&(e.name.len() as u16).to_le_bytes());
        central.extend_from_slice(&[0; 2 + 2 + 2 + 2]);
        central.extend_from_slice(&(e.unix_mode << 16).to_le_bytes());
        central.extend_from_slice(&lho.to_le_bytes());
        central.extend_from_slice(&e.name);
    }
    let cd_off = out.len() as u32;
    out.extend_from_slice(&central);
    out.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
    out.extend_from_slice(&[0; 4]);
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    out.extend_from_slice(&(central.len() as u32).to_le_bytes());
    out.extend_from_slice(&cd_off.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out
}

// ---- format-neutral entry lists -------------------------------------------------------------

#[derive(Clone)]
enum E {
    F(&'static str, &'static [u8], u32),
    D(&'static str),
    L(&'static str, &'static str),
}

fn tar_of(ents: &[E]) -> Vec<u8> {
    let mut b = TarBuilder::default();
    for e in ents {
        match e {
            E::F(n, d, m) => b.file(n, d, *m),
            E::D(n) => b.dir(n),
            E::L(n, t) => b.symlink(n, t),
        };
    }
    b.gz()
}

fn zip_of(ents: &[E]) -> Vec<u8> {
    let z: Vec<ZEntry> = ents
        .iter()
        .map(|e| match e {
            E::F(n, d, m) => ZEntry::file(n, d, false, *m),
            E::D(n) => ZEntry::dir(n),
            E::L(n, t) => ZEntry::symlink(n, t),
        })
        .collect();
    zip_build(&z)
}

fn both(ents: &[E]) -> [(Format, Vec<u8>); 2] {
    [(Format::TarGz, tar_of(ents)), (Format::Zip, zip_of(ents))]
}

/// Stage 1 must refuse with `want`, stage 2 must never be reached, and nothing may be created.
fn rejects(format: Format, bytes: &[u8], limits: &Limits, want: Reason, label: &str) {
    let fx = Fx::new(bytes);
    let got = validate(&fx.art(), format, limits).map(|_| ()).unwrap_err();
    assert_eq!(got.reason(), want, "{label} ({format:?})");
    assert!(fx.stage_is_empty() && fx.outside_untouched(), "{label}");
}

fn rejects_both(ents: &[E], limits: &Limits, want: Reason, label: &str) {
    for (f, b) in both(ents) {
        rejects(f, &b, limits, want, label);
    }
}

fn extract_ok(format: Format, bytes: &[u8], limits: &Limits) -> (Fx, Plan) {
    let fx = Fx::new(bytes);
    let plan = validate(&fx.art(), format, limits).expect("valid");
    extract(&plan, &fx.art(), &fx.stage).expect("extracts");
    assert!(fx.outside_untouched());
    (fx, plan)
}

// ---- path rules, both formats ---------------------------------------------------------------

#[test]
fn unsafe_paths_are_refused_in_both_formats() {
    let long: &'static str = Box::leak(format!("{}/x", "a".repeat(1030)).into_boxed_str());
    let names: [&'static str; 8] = [
        "/etc/x",
        "../x",
        "a/../../x",
        "./../x",
        "a/../b",
        "a//b",
        "",
        long,
    ];
    for n in names {
        rejects_both(
            &[E::F(n, b"x", 0o644)],
            &lim(),
            Reason::UnsafePath,
            n.get(..12).unwrap_or(n),
        );
    }
    // A name over 1024 bytes is refused even when it needs a GNU long-name record to be stored.
    let mut b = TarBuilder::default();
    b.long_name(&"a".repeat(1025)).file("short", b"x", 0o644);
    rejects(
        Format::TarGz,
        &b.gz(),
        &lim(),
        Reason::UnsafePath,
        "gnu long name 1025",
    );
    // 1024 is fine, and a backslash is a plain name character.
    let ok: &'static str = Box::leak("b".repeat(1024).into_boxed_str());
    for (f, bytes) in both(&[E::F(ok, b"x", 0o644), E::F("back\\slash", b"y", 0o644)]) {
        let plan = validate(&Fx::new(&bytes).art(), f, &lim());
        assert!(plan.is_ok(), "{f:?}");
    }
}

#[test]
fn nul_in_a_pax_path_is_refused() {
    let mut b = TarBuilder::default();
    b.pax(&[("path", b"a\0b")]).file("x", b"x", 0o644);
    rejects(
        Format::TarGz,
        &b.gz(),
        &lim(),
        Reason::UnsafePath,
        "pax nul",
    );
    let z = zip_build(&[ZEntry::file("a\0b", b"x", false, 0o644)]);
    rejects(Format::Zip, &z, &lim(), Reason::UnsafePath, "zip nul");
}

#[test]
fn an_entry_never_passes_through_an_earlier_symlink() {
    rejects_both(
        &[E::D("d"), E::L("d/l", ".."), E::F("d/l/x", b"x", 0o644)],
        &lim(),
        Reason::UnsafePath,
        "write through link",
    );
    rejects_both(
        &[E::L("a", "b"), E::F("a/x", b"x", 0o644)],
        &lim(),
        Reason::UnsafePath,
        "symlink then child",
    );
    rejects_both(
        &[E::L("a", "b"), E::D("a/sub")],
        &lim(),
        Reason::UnsafePath,
        "symlink then dir child",
    );
}

#[test]
fn implicit_parent_directories_are_recorded() {
    // `a/x` makes `a` a directory; a later file or link named `a` is a conflict.
    rejects_both(
        &[E::F("a/x", b"x", 0o644), E::F("a", b"y", 0o644)],
        &lim(),
        Reason::Duplicate,
        "file over implicit dir",
    );
    rejects_both(
        &[E::F("a/x", b"x", 0o644), E::L("a", "b")],
        &lim(),
        Reason::Duplicate,
        "symlink over implicit dir",
    );
    rejects_both(
        &[E::F("a/b/x", b"x", 0o644), E::L("a/b", "c")],
        &lim(),
        Reason::Duplicate,
        "deep implicit",
    );
    // Parent files are never directories.
    rejects_both(
        &[E::F("a", b"y", 0o644), E::F("a/x", b"x", 0o644)],
        &lim(),
        Reason::UnsafePath,
        "file then child",
    );
}

#[test]
fn symlink_targets_that_leave_the_tree_are_refused() {
    for t in [
        "../../outside",
        "/etc",
        "a/../b",
        ".",
        "",
        "../",
        "x//y",
        "d/../..",
    ] {
        let t: &'static str = Box::leak(t.to_string().into_boxed_str());
        rejects_both(&[E::L("l", t)], &lim(), Reason::LinkEscape, t);
    }
    // A link one level down may climb one level, not two.
    for (f, b) in both(&[E::L("d/l", "../x")]) {
        assert!(validate(&Fx::new(&b).art(), f, &lim()).is_ok(), "{f:?}");
    }
    rejects_both(
        &[E::L("d/l", "../../x")],
        &lim(),
        Reason::LinkEscape,
        "two up from depth one",
    );
}

#[test]
fn setuid_setgid_are_refused() {
    for m in [0o4755, 0o2755, 0o6755] {
        let ent: &'static [E] = Box::leak(vec![E::F("f", b"x", m)].into_boxed_slice());
        rejects_both(ent, &lim(), Reason::Setuid, "setuid");
    }
}

#[test]
fn duplicate_and_case_colliding_names_are_refused() {
    rejects_both(
        &[E::F("a", b"1", 0o644), E::F("a", b"2", 0o644)],
        &lim(),
        Reason::Duplicate,
        "file+file",
    );
    rejects_both(
        &[E::F("a", b"1", 0o644), E::D("a")],
        &lim(),
        Reason::Duplicate,
        "file+dir",
    );
    rejects_both(
        &[E::D("a"), E::F("a", b"1", 0o644)],
        &lim(),
        Reason::Duplicate,
        "dir+file",
    );
    rejects_both(
        &[E::F("A", b"1", 0o644), E::F("a", b"2", 0o644)],
        &lim(),
        Reason::CaseCollision,
        "A,a",
    );
    rejects_both(
        &[E::F("a/x", b"1", 0o644), E::F("A/y", b"2", 0o644)],
        &lim(),
        Reason::CaseCollision,
        "a/x,A/y",
    );
    rejects_both(&[E::D("a"), E::D("a")], &lim(), Reason::Duplicate, "dir+dir");
    rejects_both(
        &[E::D("a"), E::F("a/x", b"1", 0o644), E::D("a")],
        &lim(),
        Reason::Duplicate,
        "dir+child+dir",
    );
    // An implicit parent declared explicitly later is allowed once.
    for (f, b) in both(&[E::F("a/x", b"1", 0o644), E::D("a")]) {
        let (fx, _) = extract_ok(f, &b, &lim());
        assert_eq!(fs::read(fx.stage.join("a/x")).unwrap(), b"1");
    }
}

#[test]
fn entry_count_and_size_caps() {
    let three = [
        E::F("a", b"1", 0o644),
        E::F("b", b"2", 0o644),
        E::F("c", b"3", 0o644),
    ];
    rejects_both(
        &three,
        &Limits {
            max_entries: 2,
            ..lim()
        },
        Reason::TooManyEntries,
        "count",
    );
    rejects_both(
        &[E::F("a", b"0123456789", 0o644)],
        &Limits {
            max_entry_bytes: 5,
            ..lim()
        },
        Reason::TooLarge,
        "entry",
    );
    rejects_both(
        &[E::F("a", b"1234", 0o644), E::F("b", b"1234", 0o644)],
        &Limits {
            max_total_bytes: 7,
            ..lim()
        },
        Reason::TooLarge,
        "total",
    );
}

// ---- tar only -------------------------------------------------------------------------------

#[test]
fn forbidden_and_unknown_tar_types() {
    for t in *b"13467S" {
        let mut b = TarBuilder::default();
        b.special("x", t);
        rejects(
            Format::TarGz,
            &b.gz(),
            &lim(),
            Reason::ForbiddenType,
            &format!("type {}", t as char),
        );
    }
    let mut b = TarBuilder::default();
    b.special("x", b'Z');
    rejects(
        Format::TarGz,
        &b.gz(),
        &lim(),
        Reason::Unsupported,
        "unknown type",
    );
    // A hardlink to a file outside the tree, and one inside, are both refused.
    for target in ["/etc/passwd", "inside"] {
        let mut b = TarBuilder::default();
        b.file("inside", b"x", 0o644)
            .raw(tar_header(b"h", b'1', 0o644, 0, target), b"");
        rejects(
            Format::TarGz,
            &b.gz(),
            &lim(),
            Reason::ForbiddenType,
            "hardlink",
        );
    }
}

#[test]
fn huge_declared_tar_sizes_are_too_large() {
    let mut b = TarBuilder::default();
    let h = tar_header(b"big", b'0', 0o644, 0o77777777777, "");
    b.raw(h, b"");
    rejects(
        Format::TarGz,
        &b.gz(),
        &lim(),
        Reason::TooLarge,
        "8 GiB octal",
    );
    // 1 TiB in GNU base-256.
    let mut h = tar_header(b"big", b'0', 0o644, 0, "");
    h[124] = 0x80;
    h[128..136].copy_from_slice(&(1u64 << 40).to_be_bytes());
    let sum: u32 = h
        .iter()
        .enumerate()
        .map(|(i, b)| {
            if (148..156).contains(&i) {
                0x20
            } else {
                u32::from(*b)
            }
        })
        .sum();
    h[148..156].copy_from_slice(format!("{sum:06o}\0 ").as_bytes());
    let mut b = TarBuilder::default();
    b.raw(h, b"");
    rejects(
        Format::TarGz,
        &b.gz(),
        &lim(),
        Reason::TooLarge,
        "1 TiB base-256",
    );
    // 1 << 50 is beyond what the parser follows at all.
    let mut h2 = h;
    h2[128..136].copy_from_slice(&(1u64 << 50).to_be_bytes());
    let sum: u32 = h2
        .iter()
        .enumerate()
        .map(|(i, b)| {
            if (148..156).contains(&i) {
                0x20
            } else {
                u32::from(*b)
            }
        })
        .sum();
    h2[148..156].copy_from_slice(format!("{sum:06o}\0 ").as_bytes());
    let mut b = TarBuilder::default();
    b.raw(h2, b"");
    rejects(
        Format::TarGz,
        &b.gz(),
        &lim(),
        Reason::TooLarge,
        "1 PiB base-256",
    );
}

#[test]
fn damaged_gzip_and_tar_streams() {
    let good = tar_of(&[E::F("a", &[7u8; 5000], 0o644)]);
    // Truncated gzip.
    rejects(
        Format::TarGz,
        &good[..good.len() - 12],
        &lim(),
        Reason::Malformed,
        "truncated gz",
    );
    rejects(
        Format::TarGz,
        &good[..20],
        &lim(),
        Reason::Malformed,
        "gz header only",
    );
    // Bytes after the member.
    let mut trailing = good.clone();
    trailing.extend_from_slice(b"junk");
    rejects(
        Format::TarGz,
        &trailing,
        &lim(),
        Reason::Malformed,
        "trailing bytes",
    );
    // A second gzip member is also trailing data.
    let mut two = good.clone();
    two.extend_from_slice(&gz(b""));
    rejects(
        Format::TarGz,
        &two,
        &lim(),
        Reason::Malformed,
        "second member",
    );
    // A flipped byte in the deflate data breaks the CRC or the stream.
    let mut flipped = good.clone();
    let mid = flipped.len() / 2;
    flipped[mid] ^= 0xFF;
    rejects(
        Format::TarGz,
        &flipped,
        &lim(),
        Reason::Malformed,
        "corrupt deflate",
    );
    // A valid gzip around a tar with no end blocks, one cut inside a body, one with a bad checksum.
    let mut b = TarBuilder::default();
    b.file("a", b"hello", 0o644);
    rejects(
        Format::TarGz,
        &gz(&b.out),
        &lim(),
        Reason::Malformed,
        "no end blocks",
    );
    rejects(
        Format::TarGz,
        &gz(&b.out[..600]),
        &lim(),
        Reason::Malformed,
        "cut inside body padding",
    );
    let mut bad = b.bytes();
    bad[148] ^= 1;
    rejects(
        Format::TarGz,
        &gz(&bad),
        &lim(),
        Reason::Malformed,
        "bad checksum",
    );
    let mut notzero = b.bytes();
    let n = notzero.len();
    notzero[n - 3] = 1;
    rejects(
        Format::TarGz,
        &gz(&notzero),
        &lim(),
        Reason::Malformed,
        "non-zero after end blocks",
    );
    // Not gzip at all.
    rejects(
        Format::TarGz,
        b"not an archive at all, just text, long enough to have a header",
        &lim(),
        Reason::Malformed,
        "not gzip",
    );
    rejects(Format::TarGz, b"", &lim(), Reason::Malformed, "empty");
}

#[test]
fn pax_records_are_bounded_and_checked() {
    let mut b = TarBuilder::default();
    b.pax(&[("size", b"5")]).file("a", b"hello", 0o644);
    rejects(
        Format::TarGz,
        &b.gz(),
        &lim(),
        Reason::Unsupported,
        "pax size",
    );
    let mut b = TarBuilder::default();
    b.raw(tar_header(b"PaxHeader", b'x', 0o644, 9, ""), b"5 a=bcd\n\0");
    b.file("a", b"x", 0o644);
    rejects(
        Format::TarGz,
        &b.gz(),
        &lim(),
        Reason::Malformed,
        "pax length lies",
    );
    let mut b = TarBuilder::default();
    b.raw(
        tar_header(b"PaxHeader", b'x', 0o644, 70_000, ""),
        &vec![b'a'; 70_000],
    );
    rejects(
        Format::TarGz,
        &b.gz(),
        &lim(),
        Reason::TooLarge,
        "pax record too big",
    );
    let mut b = TarBuilder::default();
    b.pax(&[
        ("comment", b"anything"),
        ("path", "dir/long-name.txt".as_bytes()),
    ])
    .file("short", b"hi", 0o644);
    let (fx, plan) = extract_ok(Format::TarGz, &b.gz(), &lim());
    assert_eq!(plan.entries()[0].path, "dir/long-name.txt");
    assert_eq!(fs::read(fx.stage.join("dir/long-name.txt")).unwrap(), b"hi");
    // GNU long names carry a 200 byte component.
    let name = format!("d/{}", "n".repeat(200));
    let mut b = TarBuilder::default();
    b.long_name(&name).file("x", b"hi", 0o644);
    let (fx, _) = extract_ok(Format::TarGz, &b.gz(), &lim());
    assert_eq!(fs::read(fx.stage.join(&name)).unwrap(), b"hi");
}

#[test]
fn a_gzip_bomb_stops_at_the_ratio_and_at_the_cap() {
    // 64 MiB of zeros inside one tar entry, gzipped to a few tens of KiB.
    let mut e = GzEncoder::new(Vec::new(), Compression::default());
    e.write_all(&tar_header(b"zeros", b'0', 0o644, 64 << 20, ""))
        .unwrap();
    let block = vec![0u8; 1 << 20];
    for _ in 0..64 {
        e.write_all(&block).unwrap();
    }
    e.write_all(&[0u8; 1024]).unwrap();
    let bomb = e.finish().unwrap();
    assert!(bomb.len() < 200_000, "{} bytes", bomb.len());
    let big = Limits {
        max_total_bytes: 1 << 30,
        max_entry_bytes: 1 << 30,
        ..lim()
    };
    let t = std::time::Instant::now();
    rejects(Format::TarGz, &bomb, &big, Reason::Ratio, "ratio");
    // With the ratio check out of the way the output cap still holds.
    let capped = Limits {
        max_ratio: 1 << 40,
        max_total_bytes: 1 << 20,
        max_entry_bytes: 1 << 20,
        ..lim()
    };
    rejects(Format::TarGz, &bomb, &capped, Reason::TooLarge, "cap");
    assert!(t.elapsed().as_secs() < 30);
}

// ---- zip only -------------------------------------------------------------------------------

fn patch_eocd(z: &mut [u8], f: impl FnOnce(&mut [u8])) {
    let n = z.len();
    f(&mut z[n - 22..]);
}

#[test]
fn zip_shapes_that_are_not_supported() {
    let base = || vec![ZEntry::file("a", b"hello hello hello", true, 0o644)];
    let mut e = base();
    e[0].flags = 0x1;
    rejects(
        Format::Zip,
        &zip_build(&e),
        &lim(),
        Reason::Unsupported,
        "encrypted",
    );
    for fl in [0x40u16, 0x2000] {
        let mut e = base();
        e[0].flags = fl;
        rejects(
            Format::Zip,
            &zip_build(&e),
            &lim(),
            Reason::Unsupported,
            "strong encryption or masked",
        );
    }
    let mut e = base();
    e[0].method = Some(12);
    rejects(
        Format::Zip,
        &zip_build(&e),
        &lim(),
        Reason::Unsupported,
        "bzip2",
    );
    let mut z = zip_build(&base());
    patch_eocd(&mut z, |t| {
        t[10..12].copy_from_slice(&0xFFFFu16.to_le_bytes())
    });
    patch_eocd(&mut z, |t| {
        t[8..10].copy_from_slice(&0xFFFFu16.to_le_bytes())
    });
    rejects(Format::Zip, &z, &lim(), Reason::Unsupported, "zip64 marker");
    let mut z = zip_build(&base());
    patch_eocd(&mut z, |t| t[4..6].copy_from_slice(&1u16.to_le_bytes()));
    rejects(Format::Zip, &z, &lim(), Reason::Unsupported, "multi disk");
    let mut z = zip_build(&base());
    let n = z.len();
    let mut with_locator = z[..n - 22].to_vec();
    with_locator.extend_from_slice(&[
        0x50, 0x4b, 6, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]);
    with_locator.extend_from_slice(&z[n - 22..]);
    z = with_locator;
    rejects(
        Format::Zip,
        &z,
        &lim(),
        Reason::Unsupported,
        "zip64 locator",
    );
}

#[test]
fn zip_headers_must_agree() {
    let mut e = vec![ZEntry::file("abc", b"hello", false, 0o644)];
    e[0].name = "xbc".into();
    e[0].local_name = Some(b"abc".to_vec());
    rejects(
        Format::Zip,
        &zip_build(&e),
        &lim(),
        Reason::Malformed,
        "local name differs",
    );
    let e = vec![ZEntry {
        name: vec![0xff, 0xfe, b'a'],
        local_name: Some(vec![0xff, 0xfe, b'a']),
        ..ZEntry::file("x", b"hi", false, 0o644)
    }];
    rejects(
        Format::Zip,
        &zip_build(&e),
        &lim(),
        Reason::Malformed,
        "name not utf-8",
    );
    // Two entries whose data ranges overlap: point the second local offset into the first.
    let mut z = zip_build(&[
        ZEntry::file("a", b"hello", false, 0o644),
        ZEntry::file("b", b"world", false, 0o644),
    ]);
    let n = z.len();
    let cd_off = u32::from_le_bytes(z[n - 6..n - 2].try_into().unwrap()) as usize;
    let second = cd_off + 46 + 1; // central entry 1 is 46 + len("a") bytes
    z[second + 42..second + 46].copy_from_slice(&0u32.to_le_bytes());
    rejects(
        Format::Zip,
        &z,
        &lim(),
        Reason::Malformed,
        "overlap or mismatch",
    );
    // Truncations.
    let good = zip_build(&[ZEntry::file("a", &[3u8; 4000], true, 0o644)]);
    rejects(
        Format::Zip,
        &good[..good.len() - 10],
        &lim(),
        Reason::Malformed,
        "no eocd",
    );
    rejects(Format::Zip, &good[..10], &lim(), Reason::Malformed, "tiny");
    let mut z = good.clone();
    patch_eocd(&mut z, |t| {
        t[16..20].copy_from_slice(&0x00FF_FFF0u32.to_le_bytes())
    });
    rejects(
        Format::Zip,
        &z,
        &lim(),
        Reason::Malformed,
        "central directory out of range",
    );
    // A directory entry that carries data, and a symlink entry that is empty.
    let d = ZEntry {
        data: b"x".to_vec(),
        ..ZEntry::dir("d")
    };
    rejects(
        Format::Zip,
        &zip_build(&[d]),
        &lim(),
        Reason::Malformed,
        "directory with data",
    );
    let mut s = ZEntry::symlink("l", "x");
    s.data.clear();
    rejects(
        Format::Zip,
        &zip_build(&[s]),
        &lim(),
        Reason::LinkEscape,
        "empty symlink",
    );
    // A FIFO and a character device in the external attributes.
    for m in [0o010000u32, 0o020000, 0o060000, 0o140000] {
        let f = ZEntry {
            unix_mode: m | 0o644,
            ..ZEntry::file("f", b"", false, 0)
        };
        rejects(
            Format::Zip,
            &zip_build(&[f]),
            &lim(),
            Reason::ForbiddenType,
            "special file",
        );
    }
}

#[test]
fn zip_stage_one_catches_lying_headers() {
    // Wrong CRC: refused while planning, so stage 2 never runs and staging stays empty.
    let e = ZEntry {
        lie_crc: Some(0x1234_5678),
        ..ZEntry::file("a", b"hello world", true, 0o755)
    };
    let fx = Fx::new(&zip_build(&[e]));
    assert_eq!(
        validate(&fx.art(), Format::Zip, &lim())
            .unwrap_err()
            .reason(),
        Reason::Malformed
    );
    assert!(fx.stage_is_empty());
    assert!(fx.outside_untouched());
    // The central directory claims more than the stream holds.
    let e = ZEntry {
        lie_usize: Some(999),
        ..ZEntry::file("a", b"hello world", true, 0o644)
    };
    let fx = Fx::new(&zip_build(&[e]));
    assert_eq!(
        validate(&fx.art(), Format::Zip, &lim())
            .unwrap_err()
            .reason(),
        Reason::Malformed
    );
    assert!(fx.stage_is_empty());
    // Stored entry whose compressed size differs from the real one.
    let e = ZEntry {
        method: Some(0),
        ..ZEntry::file("a", b"hello world", true, 0o644)
    };
    let fx = Fx::new(&zip_build(&[e]));
    assert_eq!(
        validate(&fx.art(), Format::Zip, &lim())
            .unwrap_err()
            .reason(),
        Reason::Malformed
    );
}

#[test]
fn a_zip_bomb_is_stopped_by_the_ratio_or_by_the_declared_size() {
    let zeros = vec![0u8; 64 << 20];
    let honest = ZEntry::file("bomb", &zeros, true, 0o644);
    let big = Limits {
        max_total_bytes: 1 << 30,
        max_entry_bytes: 1 << 30,
        ..lim()
    };
    rejects(
        Format::Zip,
        &zip_build(std::slice::from_ref(&honest)),
        &big,
        Reason::Ratio,
        "declared ratio",
    );
    // The header claims 1000 bytes; the stream inflates to 64 MiB. Stage 1 inflates with a
    // discarding sink and stops at the declared size, so nothing is ever written.
    let lying = ZEntry {
        lie_usize: Some(1000),
        ..honest
    };
    let fx = Fx::new(&zip_build(&[lying]));
    assert_eq!(
        validate(&fx.art(), Format::Zip, &lim())
            .unwrap_err()
            .reason(),
        Reason::TooLarge
    );
    assert!(fx.stage_is_empty());
    assert!(fx.outside_untouched());
}

// ---- stage two ------------------------------------------------------------------------------

#[test]
fn an_archive_that_changed_between_the_stages_is_refused() {
    for (f, b) in both(&[E::F("a", b"one", 0o644)]) {
        let fx = Fx::new(&b);
        let plan = validate(&fx.art(), f, &lim()).unwrap();
        let other = both(&[E::F("a", b"one", 0o644), E::F("b", b"two and more", 0o644)]);
        let swapped = if f == Format::TarGz {
            &other[0].1
        } else {
            &other[1].1
        };
        fs::write(&fx.archive, swapped).unwrap();
        assert_eq!(
            extract(&plan, &fx.art(), &fx.stage).unwrap_err().reason(),
            Reason::Changed,
            "{f:?}"
        );
        assert!(fx.stage_is_empty());
        // Replaced by a different file at the same path (new inode).
        let fx = Fx::new(&b);
        let plan = validate(&fx.art(), f, &lim()).unwrap();
        fs::remove_file(&fx.archive).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(30)); // past the filesystem's timestamp tick
        fs::write(&fx.archive, &b).unwrap();
        assert_eq!(
            extract(&plan, &fx.art(), &fx.stage).unwrap_err().reason(),
            Reason::Changed,
            "{f:?} new inode"
        );
    }
}

#[test]
fn a_same_size_in_place_edit_with_restored_mtime_is_refused() {
    use std::os::unix::fs::MetadataExt;
    for (f, b) in both(&[E::F("a", b"one", 0o644)]) {
        let fx = Fx::new(&b);
        let art = fx.art();
        let plan = validate(&art, f, &lim()).unwrap();
        let before = fs::metadata(&fx.archive).unwrap();
        let mut edited = b.clone();
        let last = edited.len() - 30;
        edited[last] ^= 0x01;
        {
            use std::io::Write;
            let mut h = fs::OpenOptions::new()
                .write(true)
                .open(&fx.archive)
                .unwrap();
            h.write_all(&edited).unwrap();
            let t = std::fs::FileTimes::new().set_modified(
                std::time::UNIX_EPOCH
                    + std::time::Duration::new(before.mtime() as u64, before.mtime_nsec() as u32),
            );
            h.set_times(t).unwrap();
        }
        assert_eq!(
            extract(&plan, &art, &fx.stage).unwrap_err().reason(),
            Reason::Changed,
            "{f:?}"
        );
        assert!(fx.stage_is_empty());
    }
}

#[test]
fn the_target_must_be_an_empty_real_directory() {
    for (f, b) in both(&[E::F("a", b"one", 0o644)]) {
        let fx = Fx::new(&b);
        let plan = validate(&fx.art(), f, &lim()).unwrap();
        fs::write(fx.stage.join("pre-existing"), b"x").unwrap();
        assert_eq!(
            extract(&plan, &fx.art(), &fx.stage).unwrap_err().reason(),
            Reason::Io
        );
        assert!(!fx.stage.join("a").exists());
        let link = fx.root.join("stage-link");
        std::os::unix::fs::symlink(&fx.outside, &link).unwrap();
        assert_eq!(
            extract(&plan, &fx.art(), &link).unwrap_err().reason(),
            Reason::Io
        );
        assert!(fx.outside_untouched());
        assert_eq!(
            extract(&plan, &fx.art(), &fx.root.join("missing"))
                .unwrap_err()
                .reason(),
            Reason::Io
        );
    }
}

#[test]
fn a_file_that_appears_at_a_planned_path_is_never_overwritten() {
    for (f, b) in both(&[E::F("a", b"one", 0o644), E::F("b", b"two", 0o644)]) {
        let fx = Fx::new(&b);
        let plan = validate(&fx.art(), f, &lim()).unwrap();
        let stage = fx.stage.clone();
        let mut hook = |i: usize, _: &PlannedEntry| {
            if i == 1 {
                fs::write(stage.join("b"), b"pre-existing").unwrap();
            }
        };
        assert_eq!(
            extract_with_hook(&plan, &fx.art(), &fx.stage, &mut hook)
                .unwrap_err()
                .reason(),
            Reason::Io,
            "{f:?}"
        );
        assert_eq!(fs::read(fx.stage.join("b")).unwrap(), b"pre-existing");
    }
}

#[test]
fn a_directory_swapped_for_a_symlink_cannot_lead_outside() {
    for (f, b) in both(&[
        E::D("a"),
        E::F("b", b"1", 0o644),
        E::F("a/x", b"payload", 0o644),
    ]) {
        let fx = Fx::new(&b);
        let plan = validate(&fx.art(), f, &lim()).unwrap();
        let (stage, outside) = (fx.stage.clone(), fx.outside.clone());
        let mut hook = |i: usize, _: &PlannedEntry| {
            if i == 2 {
                fs::remove_dir(stage.join("a")).unwrap();
                std::os::unix::fs::symlink(&outside, stage.join("a")).unwrap();
            }
        };
        let err = extract_with_hook(&plan, &fx.art(), &fx.stage, &mut hook).unwrap_err();
        assert_eq!(err.reason(), Reason::Io, "{f:?}");
        assert!(fx.outside_untouched(), "{f:?}: nothing may land outside");
    }
    // The same swap one level down, through the parent path: a symlink in
    // place of an intermediate directory.
    for (f, b) in both(&[
        E::D("p"),
        E::D("p/q"),
        E::F("z", b"1", 0o644),
        E::F("p/q/x", b"payload", 0o644),
    ]) {
        let fx = Fx::new(&b);
        let plan = validate(&fx.art(), f, &lim()).unwrap();
        let (stage, outside) = (fx.stage.clone(), fx.outside.clone());
        let mut hook = |i: usize, _: &PlannedEntry| {
            if i == 3 {
                fs::remove_dir_all(stage.join("p")).unwrap();
                std::os::unix::fs::symlink(&outside, stage.join("p")).unwrap();
            }
        };
        assert!(
            extract_with_hook(&plan, &fx.art(), &fx.stage, &mut hook).is_err(),
            "{f:?}"
        );
        assert!(fx.outside_untouched(), "{f:?}");
    }
}

#[test]
fn a_populated_parent_renamed_away_between_entries_is_not_written_through() {
    for (f, b) in both(&[
        E::D("a"),
        E::F("a/one", b"1", 0o644),
        E::F("a/two", b"2", 0o644),
    ]) {
        let fx = Fx::new(&b);
        let plan = validate(&fx.art(), f, &lim()).unwrap();
        let (stage, outside) = (fx.stage.clone(), fx.outside.clone());
        let mut hook = |i: usize, _: &PlannedEntry| {
            if i == 2 {
                fs::rename(stage.join("a"), outside.join("moved")).unwrap();
                std::os::unix::fs::symlink(&outside, stage.join("a")).unwrap();
            }
        };
        assert!(
            extract_with_hook(&plan, &fx.art(), &fx.stage, &mut hook).is_err(),
            "{f:?}"
        );
        assert!(!outside.join("moved").join("two").exists(), "{f:?}");
        assert!(!outside.join("two").exists(), "{f:?}");
    }
}

// ---- benign trees ---------------------------------------------------------------------------

fn mode_of(p: &Path) -> u32 {
    fs::symlink_metadata(p).unwrap().permissions().mode() & 0o7777
}

#[test]
fn a_node_shaped_tar_gz_extracts_with_masked_modes() {
    let mut b = TarBuilder::default();
    b.dir("node-v1/")
        .dir("node-v1/bin/")
        .file(
            "node-v1/bin/node",
            &[0x7f, b'E', b'L', b'F', 1, 2, 3],
            0o755,
        )
        .dir("node-v1/lib/node_modules/npm/bin/")
        .file(
            "node-v1/lib/node_modules/npm/bin/npm-cli.js",
            b"#!/usr/bin/env node\n",
            0o644,
        )
        .symlink("node-v1/bin/npm", "../lib/node_modules/npm/bin/npm-cli.js")
        .file("node-v1/CHANGELOG.md", b"changes", 0o666)
        .file("node-v1/sticky", b"s", 0o1755)
        .file("node-v1/empty", b"", 0o600);
    let limits = Limits {
        strip_components: 1,
        ..lim()
    };
    let bytes = b.gz();
    let fx = Fx::new(&bytes);
    let plan = validate(&fx.art(), Format::TarGz, &limits);
    // The sticky bit is not setuid/setgid, so it is masked off rather than refused... unless it
    // matches the 0o6000 test, which it does not.
    let plan = plan.expect("valid");
    extract(&plan, &fx.art(), &fx.stage).unwrap();
    let s = &fx.stage;
    assert_eq!(
        fs::read(s.join("bin/node")).unwrap(),
        [0x7f, b'E', b'L', b'F', 1, 2, 3]
    );
    assert_eq!(
        fs::read_link(s.join("bin/npm")).unwrap().to_str().unwrap(),
        "../lib/node_modules/npm/bin/npm-cli.js"
    );
    assert_eq!(
        fs::read(s.join("bin/npm")).unwrap(),
        b"#!/usr/bin/env node\n",
        "the link resolves inside the tree"
    );
    assert_eq!(mode_of(&s.join("bin/node")), 0o755);
    assert_eq!(
        mode_of(&s.join("lib/node_modules/npm/bin/npm-cli.js")),
        0o644
    );
    assert_eq!(
        mode_of(&s.join("CHANGELOG.md")),
        0o644,
        "world-write is masked off"
    );
    assert_eq!(mode_of(&s.join("sticky")), 0o755, "sticky is masked off");
    assert_eq!(mode_of(&s.join("empty")), 0o600 & 0o755);
    assert!(!s.join("node-v1").exists(), "top directory stripped");
    assert_eq!(plan.entries().len(), 8);
    assert_eq!(plan.total_bytes(), 7 + 20 + 7 + 1);
    for e in plan.entries() {
        assert_eq!(e.mode & 0o7002, 0, "{}", e.mode);
    }
    assert!(fx.outside_untouched());
}

#[test]
fn a_chromium_shaped_zip_extracts_with_crc_checked() {
    let exe: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
    let z = zip_build(&[
        ZEntry::dir("chrome-linux64"),
        ZEntry::file("chrome-linux64/chrome", &exe, true, 0o755),
        ZEntry::dir("chrome-linux64/locales"),
        ZEntry::file(
            "chrome-linux64/locales/en-US.pak",
            b"stored entry",
            false,
            0o644,
        ),
        ZEntry::file(
            "chrome-linux64/resources.pak",
            &vec![b'a'; 100_000],
            true,
            0o664,
        ),
        ZEntry::symlink("chrome-linux64/chrome-link", "chrome"),
        ZEntry::file("chrome-linux64/empty", b"", false, 0o644),
    ]);
    let (fx, plan) = extract_ok(Format::Zip, &z, &lim());
    let s = fx.stage.join("chrome-linux64");
    assert_eq!(fs::read(s.join("chrome")).unwrap(), exe);
    assert_eq!(mode_of(&s.join("chrome")), 0o755, "execute bit kept");
    assert_eq!(
        fs::read(s.join("locales/en-US.pak")).unwrap(),
        b"stored entry"
    );
    assert_eq!(mode_of(&s.join("resources.pak")), 0o644);
    assert_eq!(
        fs::read_link(s.join("chrome-link"))
            .unwrap()
            .to_str()
            .unwrap(),
        "chrome"
    );
    assert_eq!(plan.entries().len(), 7);
}

#[test]
fn limits_come_from_the_pin() {
    let m = crate::manifest::Manifest::embedded();
    let a = m
        .node_artifact(crate::manifest::PlatformId::LinuxX64)
        .unwrap();
    let l = Limits::from_artifact(a);
    assert_eq!(
        (l.max_entries, l.strip_components, l.max_ratio),
        (5888, 1, DEFAULT_MAX_RATIO)
    );
    assert_eq!(l.max_total_bytes, 201_778_667);
    // The real ratio of the shipped Node archive (about 3.5) is far below the default.
    assert!(a.expanded_bytes / a.size < DEFAULT_MAX_RATIO as i64);
}

// ---- unit tables ----------------------------------------------------------------------------

#[test]
fn normalize_table() {
    let n = |s: &str, strip: usize, dir: bool| normalize(s, strip, dir).map_err(|e| e.reason());
    assert_eq!(n("a/b", 0, false), Ok(Some("a/b".into())));
    assert_eq!(n("./a/./b/", 0, true), Ok(Some("a/b".into())));
    assert_eq!(n("top/a/b", 1, false), Ok(Some("a/b".into())));
    assert_eq!(n("top/", 1, true), Ok(None));
    assert_eq!(n("./", 0, true), Ok(None));
    assert_eq!(n("top", 1, false), Err(Reason::UnsafePath));
    assert_eq!(n("a/../b", 0, false), Err(Reason::UnsafePath));
    assert_eq!(n("/a", 0, false), Err(Reason::UnsafePath));
    assert_eq!(n("a\0b", 0, false), Err(Reason::UnsafePath));
    assert_eq!(n("a//b", 0, false), Err(Reason::UnsafePath));
    assert_eq!(n("", 0, true), Err(Reason::UnsafePath));
}

#[test]
fn link_and_number_tables() {
    let l = |t: &str, depth: usize| check_link(t, depth).map_err(|e| e.reason());
    assert_eq!(l("a/b", 0), Ok(()));
    assert_eq!(l("../a", 1), Ok(()));
    assert_eq!(l("../../a", 1), Err(Reason::LinkEscape));
    assert_eq!(l("../a/../b", 2), Err(Reason::LinkEscape));
    assert_eq!(l("a/", 0), Ok(()));
    assert_eq!(octal(b"0000644\0").unwrap(), 0o644);
    assert_eq!(octal(b"  644 \0\0").unwrap(), 0o644);
    assert_eq!(octal(b"0000008\0").unwrap_err().reason(), Reason::Malformed);
    assert_eq!(
        octal(&[0x80, 1, 2]).unwrap_err().reason(),
        Reason::Unsupported
    );
    assert_eq!(tar_size(b"00000000144\0").unwrap(), 100);
    let mut b256 = [0u8; 12];
    b256[0] = 0x80;
    b256[11] = 100;
    assert_eq!(tar_size(&b256).unwrap(), 100);
    b256[0] = 0xFF;
    assert_eq!(tar_size(&b256).unwrap_err().reason(), Reason::Malformed);
}

#[test]
fn errors_name_no_entry() {
    let fx = Fx::new(&tar_of(&[E::F("../secret-canary", b"x", 0o644)]));
    let e = validate(&fx.art(), Format::TarGz, &lim()).unwrap_err();
    for s in [format!("{e}"), format!("{e:?}")] {
        assert!(!s.contains("canary") && !s.contains("secret"), "{s}");
    }
}
