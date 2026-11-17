use super::*;
use std::collections::HashMap;

struct Fixture(HashMap<&'static str, std::io::Result<String>>);

impl Source for Fixture {
    fn table(&self, name: &str) -> std::io::Result<String> {
        match self.0.get(name) {
            Some(Ok(s)) => Ok(s.clone()),
            Some(Err(_)) => Err(std::io::Error::other("unreadable")),
            None => Err(std::io::Error::other("absent")),
        }
    }
}

const HEAD: &str = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n";

fn tcp() -> String {
    format!(
        "{HEAD}   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 12345 1 0000000000000000 100 0 0 10 0\n   \
         1: 0100007F:1F90 0100007F:D2A4 01 00000000:00000000 00:00000000 00000000  1001        0 12346 1 0000000000000000 20 4 30 10 -1\n   \
         2: garbage\n"
    )
}

fn tcp6() -> String {
    format!(
        "{HEAD}   0: 00000000000000000000000001000000:1F91 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 22345 1 0000000000000000 100 0 0 10 0\n   \
         1: 00000000000000000000000001000000:1F91 00000000000000000000000001000000:C350 01 00000000:00000000 00:00000000 00000000  1002        0 22346 1 0000000000000000 20 4 30 10 -1\n"
    )
}

fn addr(s: &str) -> SocketAddr {
    s.parse().unwrap()
}

#[cfg(target_endian = "little")]
#[test]
fn rows_parse_from_real_table_lines() {
    let rows = parse_inet(&tcp(), false);
    assert_eq!(rows.len(), 2, "the garbage line is skipped");
    assert_eq!(rows[0].local, addr("127.0.0.1:8080"));
    assert_eq!(rows[0].state, 0x0A);
    assert_eq!(rows[0].uid, 1000);
    assert_eq!(rows[0].inode, 12345);
    assert_eq!(rows[1].remote, addr("127.0.0.1:53924"));
    let rows6 = parse_inet(&tcp6(), true);
    assert_eq!(rows6[0].local, addr("[::1]:8081"));
    assert_eq!(rows6[1].uid, 1002);
}

#[cfg(target_endian = "little")]
#[test]
fn the_owner_is_the_uid_of_the_server_end_of_this_connection() {
    let src = Fixture(
        [("tcp", Ok(tcp())), ("tcp6", Ok(tcp6()))]
            .into_iter()
            .collect(),
    );
    assert_eq!(
        peer_owner_uid(&src, addr("127.0.0.1:53924"), addr("127.0.0.1:8080")),
        Ok(1001)
    );
    assert_eq!(
        peer_owner_uid(&src, addr("[::1]:50000"), addr("[::1]:8081")),
        Ok(1002)
    );
    // No row for this connection: fail closed, never "the listener row's uid".
    assert_eq!(
        peer_owner_uid(&src, addr("127.0.0.1:1"), addr("127.0.0.1:8080")),
        Err(UNKNOWN)
    );
}

#[test]
fn an_unreadable_or_missing_table_fails_closed() {
    let unreadable = Fixture(
        [("tcp", Err(std::io::Error::other("x")))]
            .into_iter()
            .collect(),
    );
    let c = addr("127.0.0.1:53924");
    let s = addr("127.0.0.1:8080");
    assert_eq!(peer_owner_uid(&unreadable, c, s), Err(UNKNOWN));
    assert_eq!(peer_owner_uid(&Fixture(HashMap::new()), c, s), Err(UNKNOWN));
    assert!(listeners_among(&Fixture(HashMap::new()), &HashSet::new()).is_err());
}

#[test]
fn unix_listeners_are_the_accepting_sockets() {
    let t = "Num       RefCount Protocol Flags    Type St Inode Path\n\
             0000000000000000: 00000002 00000000 00010000 0001 01 777 /run/x/sock\n\
             0000000000000000: 00000003 00000000 00000000 0001 03 778\n\
             0000000000000000: 00000002 00000000 00010000 0001 01 779 @abstract\n";
    assert_eq!(parse_unix_listeners(t), [777, 779]);
}

#[cfg(target_endian = "little")]
#[test]
fn listeners_of_a_set_of_sockets_are_counted_by_kind() {
    let udp = format!(
        "{HEAD}   0: 0100007F:2000 00000000:0000 07 00000000:00000000 00:00000000 00000000  1000        0 31 2 0 0\n   \
         1: 0100007F:2001 0100007F:2002 01 00000000:00000000 00:00000000 00000000  1000        0 32 2 0 0\n"
    );
    let unix = "Num RefCount Protocol Flags Type St Inode Path\n0: 2 0 00010000 0001 01 41 /s\n";
    let src = Fixture(
        [
            ("tcp", Ok(tcp())),
            ("tcp6", Ok(tcp6())),
            ("udp", Ok(udp)),
            ("udp6", Ok(HEAD.to_string())),
            ("unix", Ok(unix.to_string())),
        ]
        .into_iter()
        .collect(),
    );
    let all: HashSet<u64> = [12345, 12346, 22345, 31, 32, 41].into();
    assert_eq!(
        listeners_among(&src, &all),
        Ok(Listeners {
            tcp: 2,
            udp: 1,
            unix: 1
        })
    );
    let none: HashSet<u64> = [12346, 32].into();
    assert_eq!(listeners_among(&src, &none).unwrap().total(), 0);
}

#[cfg(target_os = "linux")]
#[test]
fn a_stub_that_binds_tcp_udp_and_unix_is_reported_as_each() {
    let t = crate::state::tests::TempDir::new();
    let _tcp = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let _udp = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    let _unix = std::os::unix::net::UnixListener::bind(t.path.join("s")).unwrap();
    let me = std::process::id();
    let l = listeners_of_tree(&Proc, &[me]).unwrap();
    assert!(l.tcp >= 1 && l.udp >= 1 && l.unix >= 1, "{l:?}");
    // A process that holds no socket is reported as holding none.
    let mut sleeper = std::process::Command::new("sleep")
        .arg("5")
        .spawn()
        .unwrap();
    assert_eq!(
        listeners_of_tree(&Proc, &[sleeper.id()]).unwrap().total(),
        0
    );
    sleeper.kill().unwrap();
    sleeper.wait().unwrap();
}

#[cfg(target_os = "linux")]
#[test]
fn the_real_table_gives_this_users_uid_for_a_loopback_connection() {
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let server = l.local_addr().unwrap();
    let c = std::net::TcpStream::connect(server).unwrap();
    let (_accepted, _) = l.accept().unwrap();
    let client = c.local_addr().unwrap();
    let uid = rustix::process::geteuid().as_raw();
    assert_eq!(peer_owner_uid(&Proc, client, server), Ok(uid));
    // A connection that does not exist has no owner.
    assert_eq!(
        peer_owner_uid(&Proc, addr("127.0.0.1:1"), server),
        Err(UNKNOWN)
    );
}

// ---- a dual-stack listener shows its IPv4 peers as `::ffff:a.b.c.d` in tcp6 (#132) ------------

/// `0000000000000000FFFF00000100007F`: `::ffff:127.0.0.1` in the table's per-word byte order.
const MAPPED_LOOPBACK: &str = "0000000000000000FFFF00000100007F";

fn row6(local: &str, remote: &str, uid: u32) -> String {
    format!("   0: {local} {remote} 01 00000000:00000000 00:00000000 00000000  {uid}        0 30000 1 0000000000000000 20 4 30 10 -1\n")
}

#[cfg(target_endian = "little")]
#[test]
fn a_v4_mapped_row_in_tcp6_is_the_server_end_of_an_ipv4_connection() {
    // Port 0x1F90 = 8080, 0xD2A4 = 53924.
    let t6 = format!(
        "{HEAD}{}",
        row6(
            &format!("{MAPPED_LOOPBACK}:1F90"),
            &format!("{MAPPED_LOOPBACK}:D2A4"),
            1234
        )
    );
    // `tcp` has only the client end of the pair (local and remote swapped): not the server's row.
    let t4 = format!(
        "{HEAD}   0: 0100007F:D2A4 0100007F:1F90 01 00000000:00000000 00:00000000 00000000  4321        0 30001 1 0000000000000000 20 4 30 10 -1\n"
    );
    let src = Fixture([("tcp", Ok(t4)), ("tcp6", Ok(t6))].into_iter().collect());
    assert_eq!(
        peer_owner_uid(&src, addr("127.0.0.1:53924"), addr("127.0.0.1:8080")),
        Ok(1234)
    );
    // The same connection named in its mapped form resolves the same way.
    assert_eq!(
        peer_owner_uid(
            &src,
            addr("[::ffff:127.0.0.1]:53924"),
            addr("[::ffff:127.0.0.1]:8080")
        ),
        Ok(1234)
    );
    // A different peer port has no row.
    assert_eq!(
        peer_owner_uid(&src, addr("127.0.0.1:1"), addr("127.0.0.1:8080")),
        Err(UNKNOWN)
    );
}

#[cfg(target_endian = "little")]
#[test]
fn the_same_row_in_plain_tcp_is_still_found_and_tcp6_is_best_effort_for_an_ipv4_server() {
    let src = Fixture([("tcp", Ok(tcp()))].into_iter().collect());
    // No `tcp6` at all (a host without IPv6): the IPv4 row still answers.
    assert_eq!(
        peer_owner_uid(&src, addr("127.0.0.1:53924"), addr("127.0.0.1:8080")),
        Ok(1001)
    );
    // An unreadable `tcp6` cannot turn a missing row into a match.
    let bad6 = Fixture(
        [
            ("tcp", Ok(tcp())),
            ("tcp6", Err(std::io::Error::other("x"))),
        ]
        .into_iter()
        .collect(),
    );
    assert_eq!(
        peer_owner_uid(&bad6, addr("127.0.0.1:53924"), addr("127.0.0.1:8080")),
        Ok(1001)
    );
    assert_eq!(
        peer_owner_uid(&bad6, addr("127.0.0.1:1"), addr("127.0.0.1:8080")),
        Err(UNKNOWN)
    );
}

#[cfg(target_endian = "little")]
#[test]
fn rows_of_different_owners_for_one_connection_fail_closed() {
    let t6 = format!(
        "{HEAD}{}",
        row6(
            &format!("{MAPPED_LOOPBACK}:D2A4"),
            &format!("{MAPPED_LOOPBACK}:1F90"),
            9999
        )
    );
    // `tcp()` has the 8080 <- 53924 row owned by 1001; give tcp6 the same pair with another uid.
    let t6 = format!(
        "{t6}{}",
        row6(
            &format!("{MAPPED_LOOPBACK}:1F90"),
            &format!("{MAPPED_LOOPBACK}:D2A4"),
            2222
        )
    );
    let src = Fixture([("tcp", Ok(tcp())), ("tcp6", Ok(t6))].into_iter().collect());
    assert_eq!(
        peer_owner_uid(&src, addr("127.0.0.1:53924"), addr("127.0.0.1:8080")),
        Err(UNKNOWN)
    );
    // The same uid twice is not a conflict.
    let t6 = format!(
        "{HEAD}{}",
        row6(
            &format!("{MAPPED_LOOPBACK}:1F90"),
            &format!("{MAPPED_LOOPBACK}:D2A4"),
            1001
        )
    );
    let src = Fixture([("tcp", Ok(tcp())), ("tcp6", Ok(t6))].into_iter().collect());
    assert_eq!(
        peer_owner_uid(&src, addr("127.0.0.1:53924"), addr("127.0.0.1:8080")),
        Ok(1001)
    );
}

#[cfg(target_endian = "little")]
#[test]
fn an_ipv6_server_reads_tcp6_only_and_an_unreadable_own_table_fails_closed() {
    // For `[::1]` only `tcp6` is searched: a `tcp` that would be unreadable does not matter.
    let src = Fixture([("tcp6", Ok(tcp6()))].into_iter().collect());
    assert_eq!(
        peer_owner_uid(&src, addr("[::1]:50000"), addr("[::1]:8081")),
        Ok(1002)
    );
    let none = Fixture([("tcp", Ok(tcp()))].into_iter().collect());
    assert_eq!(
        peer_owner_uid(&none, addr("[::1]:50000"), addr("[::1]:8081")),
        Err(UNKNOWN)
    );
}
