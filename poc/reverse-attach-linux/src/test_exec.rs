//! Test helpers for fixtures that write an executable and then run it (#147).
//!
//! Linux refuses to `exec` a file that any process still holds open for writing (`ETXTBSY`). A
//! fixture that wrote the file and closed it is not enough on its own: while the test binary runs
//! many threads, another thread's `fork` can copy the writer's descriptor into a child that keeps
//! it until that child's own `exec`. An `exec` of the new file in that window fails. The fixtures
//! therefore write, `fsync`, close, and then wait until no process holds the file open for writing
//! (`settle`). Once our own writer is closed no new fork can inherit it, so after `settle` returns
//! no writer can remain. Only the test helpers retry (`spawn_retry`), and only on `ETXTBSY`;
//! production code never retries.

use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::process::{Child, Command};
use std::time::{Duration, Instant};

/// `ETXTBSY` ("text file busy") on Linux.
const ETXTBSY: i32 = 26;

/// Writes `bytes` to a new file with mode 0755, syncs and closes it, and returns only once no
/// process holds it open for writing.
pub(crate) fn write_exec(path: &Path, bytes: &[u8]) {
    {
        // A fixture may be rewritten; unlink first so a still-running old copy is not written to.
        let _ = std::fs::remove_file(path);
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o755)
            .open(path)
            .unwrap();
        f.write_all(bytes).unwrap();
        f.sync_all().unwrap();
        // Close before settling: the fd must not be ours any more.
        drop(f);
    }
    settle(path);
}

/// Copies `src` to `dst` as an executable, through memory (not `fs::copy`, which leaves the
/// destination open while it copies and whose mode follows the source).
pub(crate) fn copy_exec(src: &Path, dst: &Path) {
    let bytes = std::fs::read(src).unwrap();
    write_exec(dst, &bytes);
}

/// Waits until no process holds `path` open for writing. Panics after 20 s, naming the file.
pub(crate) fn settle(path: &Path) {
    let target = std::fs::canonicalize(path).unwrap();
    let end = Instant::now() + Duration::from_secs(20);
    while writer_open(&target) {
        assert!(
            Instant::now() < end,
            "{} is still open for writing after 20 s",
            target.display()
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// True when any process visible in `/proc` has `target` open with a write access mode.
fn writer_open(target: &Path) -> bool {
    let Ok(procs) = std::fs::read_dir("/proc") else {
        return false;
    };
    for p in procs.flatten() {
        let name = p.file_name();
        let Some(pid) = name
            .to_str()
            .filter(|n| n.bytes().all(|b| b.is_ascii_digit()))
        else {
            continue;
        };
        let Ok(fds) = std::fs::read_dir(format!("/proc/{pid}/fd")) else {
            continue;
        };
        for fd in fds.flatten() {
            if std::fs::read_link(fd.path()).is_ok_and(|l| l == target) {
                let info = format!("/proc/{pid}/fdinfo/{}", fd.file_name().to_string_lossy());
                if opened_for_writing(&info) {
                    return true;
                }
            }
        }
    }
    false
}

/// Reads the octal `flags:` line of an fdinfo file; the low two bits are the access mode
/// (0 = read only).
fn opened_for_writing(fdinfo: &str) -> bool {
    std::fs::read_to_string(fdinfo)
        .ok()
        .and_then(|s| {
            s.lines()
                .find_map(|l| l.strip_prefix("flags:"))
                .and_then(|v| u32::from_str_radix(v.trim(), 8).ok())
        })
        .is_some_and(|flags| flags & 3 != 0)
}

/// `spawn`, retried on `ETXTBSY` only, for at most 10 s.
pub(crate) fn spawn_retry(c: &mut Command) -> io::Result<Child> {
    retry_busy(Duration::from_secs(10), || c.spawn())
}

/// Runs `attempt` until it does not fail with `ETXTBSY` or `limit` has passed. Any other error
/// returns at once.
fn retry_busy<T>(limit: Duration, mut attempt: impl FnMut() -> io::Result<T>) -> io::Result<T> {
    let end = Instant::now() + limit;
    let mut pause = 10;
    loop {
        match attempt() {
            Err(e) if e.raw_os_error() == Some(ETXTBSY) && Instant::now() < end => {
                std::thread::sleep(Duration::from_millis(pause));
                pause = (pause * 2).min(50);
            }
            r => return r,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::tests::TempDir;
    use std::cell::Cell;
    use std::sync::mpsc;

    #[test]
    fn settle_returns_at_once_for_a_closed_file() {
        let t = TempDir::new();
        let p = t.path.join("f");
        write_exec(&p, b"#!/bin/sh\n");
        let start = Instant::now();
        settle(&p);
        assert!(start.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn settle_blocks_while_a_writer_is_open_and_returns_after_it_closes() {
        let t = TempDir::new();
        let p = t.path.join("f");
        let f = std::fs::File::create(&p).unwrap();
        let (tx, rx) = mpsc::channel();
        let q = p.clone();
        let h = std::thread::spawn(move || {
            settle(&q);
            tx.send(()).unwrap();
        });
        // The writer is open, so settle must not have returned.
        assert!(rx.recv_timeout(Duration::from_millis(300)).is_err());
        drop(f);
        rx.recv_timeout(Duration::from_secs(10)).unwrap();
        h.join().unwrap();
    }

    #[test]
    fn a_read_only_holder_does_not_block_settle() {
        let t = TempDir::new();
        let p = t.path.join("f");
        std::fs::write(&p, b"x").unwrap();
        let _r = std::fs::File::open(&p).unwrap();
        settle(&p);
    }

    #[test]
    fn retry_busy_retries_etxtbsy_only() {
        let n = Cell::new(0);
        let r = retry_busy(Duration::from_secs(5), || {
            n.set(n.get() + 1);
            if n.get() < 3 {
                Err(io::Error::from_raw_os_error(ETXTBSY))
            } else {
                Ok(n.get())
            }
        });
        assert_eq!(r.unwrap(), 3);

        let n = Cell::new(0);
        let r: io::Result<()> = retry_busy(Duration::from_secs(5), || {
            n.set(n.get() + 1);
            Err(io::Error::from_raw_os_error(2))
        });
        assert_eq!(r.unwrap_err().raw_os_error(), Some(2));
        assert_eq!(n.get(), 1, "another error is not retried");
    }

    #[test]
    fn retry_busy_gives_up_at_the_deadline() {
        let start = Instant::now();
        let r: io::Result<()> = retry_busy(Duration::from_millis(150), || {
            Err(io::Error::from_raw_os_error(ETXTBSY))
        });
        assert_eq!(r.unwrap_err().raw_os_error(), Some(ETXTBSY));
        assert!(start.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn a_written_executable_runs_the_first_time_under_concurrent_forks() {
        let t = TempDir::new();
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let forkers: Vec<_> = (0..3)
            .map(|_| {
                let stop = stop.clone();
                std::thread::spawn(move || {
                    while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                        let _ = Command::new("/bin/true").status();
                        std::thread::sleep(Duration::from_millis(1));
                    }
                })
            })
            .collect();
        for i in 0..100 {
            let p = t.path.join(format!("x{i}"));
            write_exec(&p, b"#!/bin/sh\nexit 0\n");
            // No retry here: the helper alone must make the first exec safe.
            let st = Command::new(&p).status().unwrap();
            assert!(st.success());
        }
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        for f in forkers {
            f.join().unwrap();
        }
    }
}
