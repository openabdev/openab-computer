//! A small, bounded ELF64 reader for the preflight (ADR linux-browser-tier D16, R3.5; L1b). It reads
//! the dynamic section of a file with `pread` only, never the whole file, and returns the needed
//! libraries, the interpreter, the `GLIBC_x.y` versions the file requires and the ones it defines.
//! Malformed or hostile input is an `Err`, never a panic, and every table is capped.
//!
//! Little-endian ELF64 only, which covers both supported architectures; anything else is
//! `Unsupported`.

use std::fs::File;
use std::os::unix::fs::FileExt;
use std::path::Path;

const MAX_PHDRS: usize = 256;
const MAX_DYN: usize = 4096;
const MAX_VERSION_RECORDS: usize = 4096;
const MAX_STRTAB: u64 = 1 << 20;
const MAX_NAME: usize = 256;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ElfError {
    NotElf,
    Unsupported,
    Malformed,
    Io,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ElfInfo {
    pub interp: Option<String>,
    pub needed: Vec<String>,
    /// The highest `GLIBC_x.y` the file needs, if any.
    pub glibc_need: Option<(u32, u32)>,
    /// The highest `GLIBC_x.y` the file defines (a libc), if any.
    pub glibc_def: Option<(u32, u32)>,
}

struct Reader<'a> {
    f: &'a File,
    len: u64,
}

impl Reader<'_> {
    fn at(&self, off: u64, buf: &mut [u8]) -> Result<(), ElfError> {
        if off
            .checked_add(buf.len() as u64)
            .is_none_or(|e| e > self.len)
        {
            return Err(ElfError::Malformed);
        }
        self.f.read_exact_at(buf, off).map_err(|_| ElfError::Io)
    }
    fn u16(&self, off: u64) -> Result<u16, ElfError> {
        let mut b = [0u8; 2];
        self.at(off, &mut b)?;
        Ok(u16::from_le_bytes(b))
    }
    fn u32(&self, off: u64) -> Result<u32, ElfError> {
        let mut b = [0u8; 4];
        self.at(off, &mut b)?;
        Ok(u32::from_le_bytes(b))
    }
    fn u64(&self, off: u64) -> Result<u64, ElfError> {
        let mut b = [0u8; 8];
        self.at(off, &mut b)?;
        Ok(u64::from_le_bytes(b))
    }
}

struct Load {
    vaddr: u64,
    off: u64,
    filesz: u64,
}

/// `a + b`, or `Malformed` when the sum does not fit: every offset below comes from the file.
fn add(a: u64, b: u64) -> Result<u64, ElfError> {
    a.checked_add(b).ok_or(ElfError::Malformed)
}

/// The file offset of virtual address `v`, `None` when no segment holds it. An offset that does
/// not fit in 64 bits is `None` too (a header lying about where its segment sits).
fn vaddr_to_off(loads: &[Load], v: u64) -> Option<u64> {
    loads
        .iter()
        .find(|l| v >= l.vaddr && v - l.vaddr < l.filesz)
        .and_then(|l| l.off.checked_add(v - l.vaddr))
}

/// `GLIBC_2.28` to `(2, 28)`. Patch levels (`GLIBC_2.2.5`) keep their first two numbers.
pub fn parse_glibc_version(s: &str) -> Option<(u32, u32)> {
    let rest = s.strip_prefix("GLIBC_")?;
    let mut it = rest.split('.');
    let a = it.next()?.parse().ok()?;
    let b = it.next()?.parse().ok()?;
    it.all(|p| p.parse::<u32>().is_ok()).then_some((a, b))
}

pub fn read_elf(path: &Path) -> Result<ElfInfo, ElfError> {
    // `O_NOFOLLOW`: a symlink is not read, and `O_NONBLOCK` keeps a FIFO from hanging the open.
    let fd = rustix::fs::open(
        path,
        rustix::fs::OFlags::RDONLY
            | rustix::fs::OFlags::NOFOLLOW
            | rustix::fs::OFlags::NONBLOCK
            | rustix::fs::OFlags::CLOEXEC,
        rustix::fs::Mode::empty(),
    )
    .map_err(|_| ElfError::Io)?;
    let f = File::from(fd);
    let len = f.metadata().map_err(|_| ElfError::Io)?.len();
    let r = Reader { f: &f, len };
    let mut ident = [0u8; 16];
    if len < 64 {
        return Err(ElfError::NotElf);
    }
    r.at(0, &mut ident)?;
    if &ident[..4] != b"\x7fELF" {
        return Err(ElfError::NotElf);
    }
    if ident[4] != 2 || ident[5] != 1 {
        return Err(ElfError::Unsupported);
    }
    let phoff = r.u64(32)?;
    let phentsize = r.u16(54)? as u64;
    let phnum = r.u16(56)? as usize;
    if phentsize < 56 || phnum > MAX_PHDRS {
        return Err(ElfError::Malformed);
    }
    let mut loads = Vec::new();
    let mut interp: Option<(u64, u64)> = None;
    let mut dynamic: Option<(u64, u64)> = None;
    for i in 0..phnum {
        let o = add(phoff, i as u64 * phentsize)?;
        let ty = r.u32(o)?;
        let off = r.u64(add(o, 8)?)?;
        let vaddr = r.u64(add(o, 16)?)?;
        let filesz = r.u64(add(o, 32)?)?;
        match ty {
            1 => loads.push(Load { vaddr, off, filesz }),
            3 => interp = Some((off, filesz)),
            2 => dynamic = Some((off, filesz)),
            _ => {}
        }
    }
    let mut info = ElfInfo::default();
    if let Some((off, sz)) = interp {
        if sz == 0 || sz > MAX_NAME as u64 {
            return Err(ElfError::Malformed);
        }
        let mut b = vec![0u8; sz as usize];
        r.at(off, &mut b)?;
        let end = b.iter().position(|c| *c == 0).unwrap_or(b.len());
        info.interp = Some(String::from_utf8_lossy(&b[..end]).into_owned());
    }
    let Some((doff, dsz)) = dynamic else {
        return Ok(info);
    };
    // A table larger than its cap is refused, not read short: a truncated table would report a
    // clean answer for a file we did not fully read. The dynamic section must also sit in the file.
    if dsz % 16 != 0 || dsz / 16 > MAX_DYN as u64 || add(doff, dsz)? > len {
        return Err(ElfError::Malformed);
    }
    let count = (dsz / 16) as usize;
    let mut needed_offs = Vec::new();
    let (mut strtab, mut strsz) = (0u64, 0u64);
    let (mut verneed, mut verneednum, mut verdef, mut verdefnum) = (0u64, 0u64, 0u64, 0u64);
    for i in 0..count {
        let o = add(doff, i as u64 * 16)?;
        let tag = r.u64(o)?;
        let val = r.u64(add(o, 8)?)?;
        match tag {
            0 => break,
            1 => needed_offs.push(val),
            5 => strtab = val,
            10 => strsz = val,
            0x6fff_fffe => verneed = val,
            0x6fff_ffff => verneednum = val,
            0x6fff_fffc => verdef = val,
            0x6fff_fffd => verdefnum = val,
            _ => {}
        }
    }
    if needed_offs.is_empty() && verneed == 0 && verdef == 0 {
        return Ok(info);
    }
    let str_off = vaddr_to_off(&loads, strtab).ok_or(ElfError::Malformed)?;
    if strsz > MAX_STRTAB
        || verneednum > MAX_VERSION_RECORDS as u64
        || verdefnum > MAX_VERSION_RECORDS as u64
    {
        return Err(ElfError::Malformed);
    }
    let str_len = strsz;
    let mut table = vec![0u8; str_len as usize];
    r.at(str_off, &mut table)?;
    let name_at = |o: u64| -> Result<String, ElfError> {
        let start = usize::try_from(o).map_err(|_| ElfError::Malformed)?;
        if start >= table.len() {
            return Err(ElfError::Malformed);
        }
        let end = table[start..]
            .iter()
            .position(|c| *c == 0)
            .ok_or(ElfError::Malformed)?;
        if end > MAX_NAME {
            return Err(ElfError::Malformed);
        }
        Ok(String::from_utf8_lossy(&table[start..start + end]).into_owned())
    };
    for o in needed_offs {
        info.needed.push(name_at(o)?);
    }
    if verneed != 0 {
        let mut o = vaddr_to_off(&loads, verneed).ok_or(ElfError::Malformed)?;
        let mut seen = 0usize;
        for _ in 0..verneednum {
            let cnt = r.u16(add(o, 2)?)? as u64;
            let aux = r.u32(add(o, 8)?)? as u64;
            let next = r.u32(add(o, 12)?)? as u64;
            let mut a = add(o, aux)?;
            for _ in 0..cnt {
                seen += 1;
                if seen > MAX_VERSION_RECORDS {
                    return Err(ElfError::Malformed);
                }
                let name = name_at(r.u32(add(a, 8)?)? as u64)?;
                if let Some(v) = parse_glibc_version(&name) {
                    info.glibc_need = info.glibc_need.max(Some(v));
                }
                let anext = r.u32(add(a, 12)?)? as u64;
                if anext == 0 {
                    break;
                }
                a = add(a, anext)?;
            }
            if next == 0 {
                break;
            }
            o = add(o, next)?;
        }
    }
    if verdef != 0 {
        let mut o = vaddr_to_off(&loads, verdef).ok_or(ElfError::Malformed)?;
        let mut seen = 0usize;
        for _ in 0..verdefnum {
            seen += 1;
            if seen > MAX_VERSION_RECORDS {
                return Err(ElfError::Malformed);
            }
            let aux = r.u32(add(o, 12)?)? as u64;
            let next = r.u32(add(o, 16)?)? as u64;
            let a = add(o, aux)?;
            let name = name_at(r.u32(a)? as u64)?;
            if let Some(v) = parse_glibc_version(&name) {
                info.glibc_def = info.glibc_def.max(Some(v));
            }
            if next == 0 {
                break;
            }
            o = add(o, next)?;
        }
    }
    Ok(info)
}

#[cfg(test)]
#[path = "elf_tests.rs"]
pub(crate) mod tests;
