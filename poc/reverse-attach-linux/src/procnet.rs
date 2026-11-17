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
pub fn parse_unix_listeners(text: &str) -> Vec<u64> {
    text.lines()
        .skip(1)
        .filter_map(|l| {
            let f: Vec<&str> = l.split_whitespace().collect();
            let flags = u32::from_str_radix(f.get(3)?, 16).ok()?;
            if flags & 0x10000 == 0 {
                return None;
            }
            f.get(6)?.parse().ok()
        })
        .collect()
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
}

impl Listeners {
    pub fn total(&self) -> usize {
        self.tcp + self.udp + self.unix
    }
}

/// Socket inodes held open by `pid` (`/proc/<pid>/fd/*` links of the form `socket:[N]`).
pub fn socket_inodes(pid: u32) -> HashSet<u64> {
    let mut set = HashSet::new();
    let Ok(rd) = std::fs::read_dir(format!("/proc/{pid}/fd")) else {
        return set;
    };
    for e in rd.flatten().take(FD_LIMIT) {
        if let Ok(t) = std::fs::read_link(e.path()) {
            if let Some(n) = t
                .to_str()
                .and_then(|s| s.strip_prefix("socket:["))
                .and_then(|s| s.strip_suffix(']'))
                .and_then(|s| s.parse::<u64>().ok())
            {
                set.insert(n);
            }
        }
    }
    set
}

/// Listeners among `inodes`: TCP in state LISTEN (0A), UDP sockets bound and not connected (07),
/// and Unix sockets that accept. An unreadable table is an error: "none" would be a claim.
pub fn listeners_among(src: &dyn Source, inodes: &HashSet<u64>) -> Result<Listeners, &'static str> {
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
    out.unix = parse_unix_listeners(&unix)
        .into_iter()
        .filter(|i| inodes.contains(i))
        .count();
    Ok(out)
}

/// Listeners owned by any of `pids`.
pub fn listeners_of_tree(src: &dyn Source, pids: &[u32]) -> Result<Listeners, &'static str> {
    let mut inodes = HashSet::new();
    for p in pids {
        inodes.extend(socket_inodes(*p));
    }
    listeners_among(src, &inodes)
}

#[cfg(test)]
#[path = "procnet_tests.rs"]
mod tests;
