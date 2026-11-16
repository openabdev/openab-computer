//! ELF reader tests over small generated ELF64 files.

use super::*;
use std::os::unix::fs::symlink;

fn p16(v: &mut Vec<u8>, x: u16) {
    v.extend_from_slice(&x.to_le_bytes());
}
fn p32(v: &mut Vec<u8>, x: u32) {
    v.extend_from_slice(&x.to_le_bytes());
}
fn p64(v: &mut Vec<u8>, x: u64) {
    v.extend_from_slice(&x.to_le_bytes());
}

/// A minimal dynamically linked ELF64 (little endian) with one PT_LOAD covering the whole file, so
/// virtual addresses equal file offsets.
pub(crate) fn build_elf(
    interp: Option<&str>,
    needed: &[&str],
    verneed: &[(&str, &[&str])],
    verdef: &[&str],
) -> Vec<u8> {
    let mut strtab: Vec<u8> = vec![0];
    let mut add = |s: &str| -> u32 {
        let o = strtab.len() as u32;
        strtab.extend_from_slice(s.as_bytes());
        strtab.push(0);
        o
    };
    let needed_offs: Vec<u32> = needed.iter().map(|n| add(n)).collect();
    let mut vn: Vec<u8> = Vec::new();
    for (i, (file, vers)) in verneed.iter().enumerate() {
        let fo = add(file);
        let last = i + 1 == verneed.len();
        p16(&mut vn, 1);
        p16(&mut vn, vers.len() as u16);
        p32(&mut vn, fo);
        p32(&mut vn, 16);
        p32(&mut vn, if last { 0 } else { 16 + 16 * vers.len() as u32 });
        for (j, v) in vers.iter().enumerate() {
            let no = add(v);
            p32(&mut vn, 0);
            p16(&mut vn, 0);
            p16(&mut vn, 0);
            p32(&mut vn, no);
            p32(&mut vn, if j + 1 == vers.len() { 0 } else { 16 });
        }
    }
    let mut vd: Vec<u8> = Vec::new();
    for (i, name) in verdef.iter().enumerate() {
        let no = add(name);
        p16(&mut vd, 1);
        p16(&mut vd, 0);
        p16(&mut vd, i as u16 + 1);
        p16(&mut vd, 1);
        p32(&mut vd, 0);
        p32(&mut vd, 20);
        p32(&mut vd, if i + 1 == verdef.len() { 0 } else { 28 });
        p32(&mut vd, no);
        p32(&mut vd, 0);
    }
    let nph = 2 + interp.is_some() as usize;
    let ph_off = 64u64;
    let mut off = ph_off + 56 * nph as u64;
    let dyn_count = needed.len() + 7;
    let dyn_off = off;
    off += 16 * dyn_count as u64;
    let str_off = off;
    off += strtab.len() as u64;
    let vn_off = off;
    off += vn.len() as u64;
    let vd_off = off;
    off += vd.len() as u64;
    let interp_off = off;
    let interp_bytes: Vec<u8> = interp
        .map(|s| {
            let mut b = s.as_bytes().to_vec();
            b.push(0);
            b
        })
        .unwrap_or_default();
    off += interp_bytes.len() as u64;
    let total = off;

    let mut f: Vec<u8> = Vec::new();
    f.extend_from_slice(b"\x7fELF\x02\x01\x01");
    f.resize(16, 0);
    p16(&mut f, 3);
    p16(&mut f, 0xb7);
    p32(&mut f, 1);
    p64(&mut f, 0);
    p64(&mut f, ph_off);
    p64(&mut f, 0);
    p32(&mut f, 0);
    p16(&mut f, 64);
    p16(&mut f, 56);
    p16(&mut f, nph as u16);
    p16(&mut f, 64);
    p16(&mut f, 0);
    p16(&mut f, 0);
    let ph = |f: &mut Vec<u8>, ty: u32, o: u64, sz: u64| {
        p32(f, ty);
        p32(f, 4);
        p64(f, o);
        p64(f, o);
        p64(f, o);
        p64(f, sz);
        p64(f, sz);
        p64(f, 8);
    };
    ph(&mut f, 1, 0, total);
    ph(&mut f, 2, dyn_off, 16 * dyn_count as u64);
    if interp.is_some() {
        ph(&mut f, 3, interp_off, interp_bytes.len() as u64);
    }
    for o in &needed_offs {
        p64(&mut f, 1);
        p64(&mut f, *o as u64);
    }
    for (tag, val) in [
        (5u64, str_off),
        (10, strtab.len() as u64),
        (0x6fff_fffe, if vn.is_empty() { 0 } else { vn_off }),
        (0x6fff_ffff, verneed.len() as u64),
        (0x6fff_fffc, if vd.is_empty() { 0 } else { vd_off }),
        (0x6fff_fffd, verdef.len() as u64),
        (0, 0),
    ] {
        p64(&mut f, tag);
        p64(&mut f, val);
    }
    f.extend_from_slice(&strtab);
    f.extend_from_slice(&vn);
    f.extend_from_slice(&vd);
    f.extend_from_slice(&interp_bytes);
    assert_eq!(f.len() as u64, total);
    f
}

struct Dir(std::path::PathBuf);
impl Dir {
    fn new() -> Dir {
        let p = std::env::temp_dir().join(format!("l1b-elf-{}", crate::state::random_hex(8)));
        std::fs::create_dir_all(&p).unwrap();
        Dir(p)
    }
    fn file(&self, name: &str, b: &[u8]) -> std::path::PathBuf {
        let p = self.0.join(name);
        std::fs::write(&p, b).unwrap();
        p
    }
}
impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn reads_needed_interp_and_glibc_versions() {
    let d = Dir::new();
    let b = build_elf(
        Some("/lib/ld-linux-aarch64.so.1"),
        &["libc.so.6", "libm.so.6", "libstdc++.so.6"],
        &[
            ("libc.so.6", &["GLIBC_2.17", "GLIBC_2.28"]),
            ("libm.so.6", &["GLIBC_2.2.5"]),
        ],
        &[],
    );
    let i = read_elf(&d.file("a", &b)).unwrap();
    assert_eq!(i.interp.as_deref(), Some("/lib/ld-linux-aarch64.so.1"));
    assert_eq!(i.needed, ["libc.so.6", "libm.so.6", "libstdc++.so.6"]);
    assert_eq!(i.glibc_need, Some((2, 28)));
    assert_eq!(i.glibc_def, None);
}

#[test]
fn reads_the_versions_a_libc_defines() {
    let d = Dir::new();
    let b = build_elf(
        None,
        &[],
        &[],
        &["libc.so.6", "GLIBC_2.17", "GLIBC_2.41", "GLIBC_PRIVATE"],
    );
    let i = read_elf(&d.file("libc", &b)).unwrap();
    assert_eq!(i.glibc_def, Some((2, 41)));
    assert!(i.needed.is_empty());
}

#[test]
fn a_file_with_no_dynamic_section_is_fine() {
    let d = Dir::new();
    let mut b = build_elf(None, &[], &[], &[]);
    // Turn PT_DYNAMIC into PT_NULL.
    b[64 + 56..64 + 56 + 4].copy_from_slice(&0u32.to_le_bytes());
    let i = read_elf(&d.file("s", &b)).unwrap();
    assert_eq!(i, ElfInfo::default());
}

#[test]
fn not_elf_unsupported_and_truncated_files_are_errors() {
    let d = Dir::new();
    assert_eq!(
        read_elf(&d.file("t", b"#!/bin/sh\necho hi\n")),
        Err(ElfError::NotElf)
    );
    assert_eq!(read_elf(&d.file("e", b"")), Err(ElfError::NotElf));
    let mut be = build_elf(None, &["a.so"], &[], &[]);
    be[5] = 2; // big endian
    assert_eq!(read_elf(&d.file("be", &be)), Err(ElfError::Unsupported));
    let mut c32 = build_elf(None, &["a.so"], &[], &[]);
    c32[4] = 1;
    assert_eq!(read_elf(&d.file("c32", &c32)), Err(ElfError::Unsupported));
    let full = build_elf(None, &["libc.so.6"], &[("libc.so.6", &["GLIBC_2.28"])], &[]);
    for cut in [10, 64, 100, 150, full.len() - 3] {
        let r = read_elf(&d.file("cut", &full[..cut]));
        assert!(r.is_err(), "cut at {cut} must fail, got {r:?}");
    }
}

#[test]
fn tables_over_the_caps_and_bad_offsets_are_errors_not_panics() {
    let d = Dir::new();
    // Program header count over the cap.
    let mut b = build_elf(None, &["a.so"], &[], &[]);
    b[56..58].copy_from_slice(&1000u16.to_le_bytes());
    assert_eq!(read_elf(&d.file("ph", &b)), Err(ElfError::Malformed));
    // Entry size too small.
    let mut b = build_elf(None, &["a.so"], &[], &[]);
    b[54..56].copy_from_slice(&8u16.to_le_bytes());
    assert_eq!(read_elf(&d.file("pe", &b)), Err(ElfError::Malformed));
    // DT_STRTAB pointing outside every PT_LOAD.
    let mut b = build_elf(None, &["a.so"], &[], &[]);
    let dyn_off = 64 + 56 * 2;
    // entries: NEEDED, STRTAB ...
    b[dyn_off + 16 + 8..dyn_off + 16 + 16].copy_from_slice(&u64::MAX.to_le_bytes());
    assert_eq!(read_elf(&d.file("st", &b)), Err(ElfError::Malformed));
    // A needed name offset past the string table.
    let mut b = build_elf(None, &["a.so"], &[], &[]);
    b[dyn_off + 8..dyn_off + 16].copy_from_slice(&0xffff_ffffu64.to_le_bytes());
    assert_eq!(read_elf(&d.file("no", &b)), Err(ElfError::Malformed));
    // A version chain that loops back on itself must stop at the caps.
    let mut b = build_elf(None, &[], &[("libc.so.6", &["GLIBC_2.1"])], &[]);
    let vn_off = u64::from_le_bytes(
        b[dyn_off + 16 * 2 + 8..dyn_off + 16 * 2 + 16]
            .try_into()
            .unwrap(),
    ) as usize;
    b[vn_off + 12..vn_off + 16].copy_from_slice(&0u32.to_le_bytes()); // next = 0 ends it
    let dyn_n = dyn_off + 16 * 3;
    b[dyn_n + 8..dyn_n + 16].copy_from_slice(&u64::MAX.to_le_bytes()); // verneednum huge
    assert!(read_elf(&d.file("loop", &b)).is_ok());
    // A cyclic aux chain (next points to itself).
    let mut b = build_elf(
        None,
        &[],
        &[("libc.so.6", &["GLIBC_2.1", "GLIBC_2.2"])],
        &[],
    );
    let vn_off = u64::from_le_bytes(
        b[dyn_off + 16 * 2 + 8..dyn_off + 16 * 2 + 16]
            .try_into()
            .unwrap(),
    ) as usize;
    // aux starts at vn_off+16; make its next = 0xffffffff (huge forward jump)
    b[vn_off + 16 + 12..vn_off + 16 + 16].copy_from_slice(&0xffff_fff0u32.to_le_bytes());
    assert!(read_elf(&d.file("cyc", &b)).is_err());
}

#[test]
fn a_symlink_is_not_followed() {
    let d = Dir::new();
    let real = d.file("real", &build_elf(None, &["x.so"], &[], &[]));
    let link = d.0.join("link");
    symlink(&real, &link).unwrap();
    assert!(read_elf(&link).is_err());
    assert!(read_elf(&real).is_ok());
}

#[test]
fn glibc_version_names() {
    assert_eq!(parse_glibc_version("GLIBC_2.28"), Some((2, 28)));
    assert_eq!(parse_glibc_version("GLIBC_2.2.5"), Some((2, 2)));
    assert_eq!(parse_glibc_version("GLIBC_PRIVATE"), None);
    assert_eq!(parse_glibc_version("GLIBCXX_3.4"), None);
    assert_eq!(parse_glibc_version("GLIBC_2"), None);
    assert_eq!(parse_glibc_version("GLIBC_2.x"), None);
}
