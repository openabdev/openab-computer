//! Parsers for `/proc/net/{tcp,tcp6,udp,udp6,unix}` (R4.3, V12; ADR "No listener"; L2).
//!
//! Two jobs, both fail-closed:
//!
//! - [`peer_owner_uid`]: the uid that owns the server end of a loopback connection this process
//!   just made, so an external Playwright is used only when it belongs to the same user. The table
//!   is read after the connection exists and before a byte of the request is sent. A table that
//!   cannot be read, a missing row, or a different uid is `listener_owner_unknown`.
//! - [`listeners_of_tree`]: the TCP, UDP and Unix listeners owned by a set of processes, for the
//!   `status` self-check. Counts and kinds only; no address leaves.
//!
//! The reader is injected (`Source`), so tests feed fixtures and an unreadable table. Every table
//! is read through a cap (`TABLE_CAP`); a longer one is an error, never a partial answer.

use std::collections::HashSet;
use std::io::Read;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

pub const TABLE_CAP: u64 = 16 * 1024 * 1024;
/// File descriptors looked at per process.
const FD_LIMIT: usize = 4096;

pub const UNKNOWN: &str = "listener_owner_unknown";

/// Where the tables come from.
pub trait Source {
    /// The text of `/proc/net/<table>` (`tcp`, `tcp6`, `udp`, `udp6`, `unix`).
    fn table(&self, name: &str) -> std::io::Result<String>;
}

/// The real `/proc`.
pub struct Proc;

impl Source for Proc {
    fn table(&self, name: &str) -> std::io::Result<String> {
        let mut s = String::new();
        std::fs::File::open(format!("/proc/net/{name}"))?
            .take(TABLE_CAP + 1)
            .read_to_string(&mut s)?;
        if s.len() as u64 > TABLE_CAP {
            return Err(std::io::Error::other("table too large"));
        }
        Ok(s)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub local: SocketAddr,
    pub remote: SocketAddr,
    pub state: u8,
    pub uid: u32,
    pub inode: u64,
}

fn hex_addr(s: &str, v6: bool) -> Option<IpAddr> {
    if !v6 {
        if s.len() != 8 {
            return None;
        }
        // The kernel prints the network-order word in host order.
        let w = u32::from_str_radix(s, 16).ok()?;
        return Some(IpAddr::V4(Ipv4Addr::from(w.to_ne_bytes())));
    }
    if s.len() != 32 {
        return None;
    }
    let mut b = [0u8; 16];
    for i in 0..4 {
        let w = u32::from_str_radix(s.get(i * 8..i * 8 + 8)?, 16).ok()?;
        b[i * 4..i * 4 + 4].copy_from_slice(&w.to_ne_bytes());
    }
    Some(IpAddr::V6(Ipv6Addr::from(b)))
}

fn sock_addr(s: &str, v6: bool) -> Option<SocketAddr> {
    let (a, p) = s.split_once(':')?;
    Some(SocketAddr::new(
        hex_addr(a, v6)?,
        u16::from_str_radix(p, 16).ok()?,
    ))
}

/// Parses an inet table. Lines that do not parse are skipped, so a missing row stays missing.
pub fn parse_inet(text: &str, v6: bool) -> Vec<Row> {
    text.lines()
        .skip(1)
        .filter_map(|l| {
            let f: Vec<&str> = l.split_whitespace().collect();
            Some(Row {
                local: sock_addr(f.get(1)?, v6)?,
                remote: sock_addr(f.get(2)?, v6)?,
                state: u8::from_str_radix(f.get(3)?, 16).ok()?,
                uid: f.get(7)?.parse().ok()?,
                inode: f.get(9)?.parse().ok()?,
            })
        })
        .collect()
}

/// `Num RefCount Protocol Flags Type St Inode [Path]`: listening Unix sockets carry
/// `__SO_ACCEPTCON` (0x10000) in the flags. Returns their inodes.
#[cfg(test)]
pub fn parse_unix_listeners(text: &str) -> Vec<u64> {
    parse_unix_listener_paths(text)
        .into_iter()
        .map(|(inode, _)| inode)
        .collect()
}

/// The same rows with the path the socket was bound to (`""` for an unnamed socket; an abstract
/// name keeps its leading `@`). The kernel prints the path as the program passed it to `bind`.
pub fn parse_unix_listener_paths(text: &str) -> Vec<(u64, String)> {
    text.lines()
        .skip(1)
        .filter_map(|l| {
            let f: Vec<&str> = l.split_whitespace().collect();
            let flags = u32::from_str_radix(f.get(3)?, 16).ok()?;
            if flags & 0x10000 == 0 {
                return None;
            }
            Some((f.get(6)?.parse().ok()?, f.get(7..)?.join(" ")))
        })
        .collect()
}

/// Whether the Unix socket bound as `path` lies physically inside the private directory
/// `private_real`, which the caller has already resolved with `canonicalize`.
///
/// The kernel prints the bind path as the program spelled it, so `path` is judged by where its
/// directory really is: the directory is canonicalized (every link in it is followed), then compared
/// with `Path::starts_with`, which compares whole components (a sibling `<dir>x` is outside). The
/// node itself must still exist as a socket. A socket unlinked after the bind prints ` (deleted)` in
/// the table and fails here. A relative path, or a directory that cannot be resolved, is outside.
pub fn inside_resolved(path: &str, private_real: &std::path::Path) -> bool {
    use std::os::unix::fs::FileTypeExt;
    let p = std::path::Path::new(path);
    if !p.is_absolute() {
        return false;
    }
    match std::fs::symlink_metadata(p) {
        Ok(m) if m.file_type().is_socket() => {}
        _ => return false,
    }
    let Some(dir) = p.parent() else {
        return false;
    };
    std::fs::canonicalize(dir).is_ok_and(|real| real.starts_with(private_real))
}

/// What is wrong with the child's private `TMPDIR`, or `ok`. Read without following a link.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TmpState {
    Ok,
    /// Nothing at the expected path.
    Missing,
    /// Not a directory (a link or a file in its place).
    NotDir,
    /// A directory whose mode is not exactly `0700`.
    Mode,
    /// A directory not owned by the daemon's uid.
    Owner,
    Unreadable,
}

impl TmpState {
    pub fn word(self) -> &'static str {
        match self {
            TmpState::Ok => "ok",
            TmpState::Missing => "missing",
            TmpState::NotDir => "not_dir",
            TmpState::Mode => "mode",
            TmpState::Owner => "owner",
            TmpState::Unreadable => "unreadable",
        }
    }
}

/// `ok` only for a real directory (not a link) owned by `uid` with mode exactly `0700`.
///
/// The TMPDIR state and the listener table are read at different times, so a verdict that uses
/// both is a point-in-time self-report, not an atomic snapshot.
pub fn tmp_state(path: &std::path::Path, uid: u32) -> TmpState {
    use std::os::unix::fs::MetadataExt;
    let m = match std::fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return TmpState::Missing,
        Err(_) => return TmpState::Unreadable,
    };
    if !m.file_type().is_dir() {
        TmpState::NotDir
    } else if m.uid() != uid {
        TmpState::Owner
    } else if m.mode() & 0o7777 != 0o700 {
        TmpState::Mode
    } else {
        TmpState::Ok
    }
}

fn inet_rows(src: &dyn Source, v6: bool, proto: &str) -> std::io::Result<Vec<Row>> {
    let name = format!("{proto}{}", if v6 { "6" } else { "" });
    Ok(parse_inet(&src.table(&name)?, v6))
}

/// `a` with an IPv4-mapped IPv6 address (`::ffff:a.b.c.d`) turned into the plain IPv4 address.
fn canonical(a: SocketAddr) -> SocketAddr {
    SocketAddr::new(a.ip().to_canonical(), a.port())
}

/// The uid that owns the server end of the connection `client -> server`: the row whose local
/// address is `server` and whose remote address is `client`. `Err(listener_owner_unknown)` when
/// the table cannot be read, has no such row, or has rows of more than one uid.
///
/// An IPv4 server may be a dual-stack listener: an `AF_INET6` socket bound to `::` shows its IPv4
/// peers in `tcp6` as `::ffff:a.b.c.d`. So for an IPv4 server `tcp` and `tcp6` are both searched, and
/// addresses are compared in their canonical form; an IPv6 server searches `tcp6` only. The table of
/// the server's own family must be readable. `tcp6` as the second table for an IPv4 server is
/// best effort (a host without IPv6 has none): an unreadable one can only hide a row, which is
/// `listener_owner_unknown` anyway, never turn a missing row into a match.
pub fn peer_owner_uid(
    src: &dyn Source,
    client: SocketAddr,
    server: SocketAddr,
) -> Result<u32, &'static str> {
    let (client, server) = (canonical(client), canonical(server));
    let mut uids: Vec<u32> = Vec::new();
    let mut search = |v6: bool, required: bool| -> Result<(), &'static str> {
        let rows = match inet_rows(src, v6, "tcp") {
            Ok(r) => r,
            Err(_) if required => return Err(UNKNOWN),
            Err(_) => return Ok(()),
        };
        for r in rows {
            if canonical(r.local) == server
                && canonical(r.remote) == client
                && !uids.contains(&r.uid)
            {
                uids.push(r.uid);
            }
        }
        Ok(())
    };
    if server.is_ipv6() {
        search(true, true)?;
    } else {
        search(false, true)?;
        search(true, false)?;
    }
    match uids.as_slice() {
        [uid] => Ok(*uid),
        // No row, or rows that disagree about the owner: fail closed.
        _ => Err(UNKNOWN),
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Listeners {
    pub tcp: usize,
    pub udp: usize,
    pub unix: usize,
    /// Of `unix`, the listeners that are not inside the verified private `TMPDIR` (V2). With no
    /// verified directory every Unix listener is outside.
    pub unix_outside: usize,
}

impl Listeners {
    pub fn total(&self) -> usize {
        self.tcp + self.udp + self.unix
    }

    /// The V2 rule (R1.1 as decided): no TCP or UDP listener, and no Unix listener outside the
    /// private per-run `TMPDIR`. A tree that listens on nothing passes.
    pub fn passes_v2(&self) -> bool {
        self.tcp == 0 && self.udp == 0 && self.unix_outside == 0
    }
}

/// Socket inodes held open by `pid` (`/proc/<pid>/fd/*` links of the form `socket:[N]`). A failure to
/// read the fd table is `UNKNOWN`, never an empty set: "no sockets" would be a claim.
pub fn socket_inodes(pid: u32) -> Result<HashSet<u64>, &'static str> {
    socket_inodes_in(std::path::Path::new(&format!("/proc/{pid}/fd")))
}

/// [`socket_inodes`] for the fd directory at `dir`. An unreadable directory, an unreadable entry, an
/// unreadable link, or more than `FD_LIMIT` entries is `UNKNOWN`: a listener could be among the
/// descriptors that were not read.
pub fn socket_inodes_in(dir: &std::path::Path) -> Result<HashSet<u64>, &'static str> {
    let rd = std::fs::read_dir(dir).map_err(|_| UNKNOWN)?;
    let mut set = HashSet::new();
    for (i, e) in rd.enumerate() {
        if i >= FD_LIMIT {
            return Err(UNKNOWN);
        }
        let e = e.map_err(|_| UNKNOWN)?;
        let t = std::fs::read_link(e.path()).map_err(|_| UNKNOWN)?;
        if let Some(n) = t
            .to_str()
            .and_then(|s| s.strip_prefix("socket:["))
            .and_then(|s| s.strip_suffix(']'))
            .and_then(|s| s.parse::<u64>().ok())
        {
            set.insert(n);
        }
    }
    Ok(set)
}

/// Listeners among `inodes`: TCP in state LISTEN (0A), UDP sockets bound and not connected (07),
/// and Unix sockets that accept. An unreadable table is an error: "none" would be a claim.
#[cfg(test)]
pub fn listeners_among(src: &dyn Source, inodes: &HashSet<u64>) -> Result<Listeners, &'static str> {
    listeners_among_in(src, inodes, None)
}

/// Like [`listeners_among`]. `private` is the child's private `TMPDIR`, resolved with `canonicalize`
/// and passed only when it was verified (`TmpState::Ok`); a Unix listener is "outside" unless its
/// directory resolves below it (see [`inside_resolved`]).
pub fn listeners_among_in(
    src: &dyn Source,
    inodes: &HashSet<u64>,
    private: Option<&std::path::Path>,
) -> Result<Listeners, &'static str> {
    let mut out = Listeners::default();
    for v6 in [false, true] {
        for r in inet_rows(src, v6, "tcp").map_err(|_| UNKNOWN)? {
            if r.state == 0x0A && inodes.contains(&r.inode) {
                out.tcp += 1;
            }
        }
        for r in inet_rows(src, v6, "udp").map_err(|_| UNKNOWN)? {
            if r.state == 0x07 && inodes.contains(&r.inode) {
                out.udp += 1;
            }
        }
    }
    let unix = src.table("unix").map_err(|_| UNKNOWN)?;
    for (inode, path) in parse_unix_listener_paths(&unix) {
        if !inodes.contains(&inode) {
            continue;
        }
        out.unix += 1;
        if !private.is_some_and(|p| inside_resolved(&path, p)) {
            out.unix_outside += 1;
        }
    }
    Ok(out)
}

/// Listeners owned by any of `pids`.
#[cfg(test)]
pub fn listeners_of_tree(src: &dyn Source, pids: &[u32]) -> Result<Listeners, &'static str> {
    listeners_of_tree_in(src, pids, None)
}

/// Like [`listeners_of_tree`], with the verified private `TMPDIR` (see [`listeners_among_in`]).
pub fn listeners_of_tree_in(
    src: &dyn Source,
    pids: &[u32],
    private: Option<&std::path::Path>,
) -> Result<Listeners, &'static str> {
    let mut inodes = HashSet::new();
    for p in pids {
        inodes.extend(socket_inodes(*p)?);
    }
    listeners_among_in(src, &inodes, private)
}

#[cfg(test)]
#[path = "procnet_tests.rs"]
mod tests;
