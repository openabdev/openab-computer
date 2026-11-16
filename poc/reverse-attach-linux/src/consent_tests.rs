use super::*;
use crate::manifest::PlatformId;

fn sel(m: &Manifest) -> Selection<'_> {
    m.select(Some(PlatformId::LinuxArm64)).unwrap()
}

#[test]
fn the_numbers_are_the_manifests_and_the_word_safe_never_appears() {
    let m = Manifest::embedded();
    for p in [PlatformId::LinuxArm64, PlatformId::LinuxX64] {
        let s = m.select(Some(p)).unwrap();
        let t = text(
            m,
            &s,
            Path::new("/home/u/.local/share/oab-computer/playwright"),
            Some(Path::new("/home/u")),
        );
        assert!(!t.to_lowercase().contains("safe"), "{t}");
        assert!(t.contains(&megabytes(download_bytes(m, &s))), "{t}");
        assert!(t.contains(&megabytes(disk_needed(m, &s))), "{t}");
        assert!(t.contains("~/.local/share/oab-computer/playwright"), "{t}");
        assert!(t.contains(&m.id) && t.contains(p.as_str()));
        for h in &m.hosts {
            assert!(t.contains(h.as_str()), "{h}");
        }
        assert!(t.contains(&m.node.version) && t.contains(&m.chromium.browser_version));
        // The download figure is the sum of the three pinned downloads, never lower.
        let sum = s.node.size + s.chromium.size + m.mcp.npm_download_bytes;
        assert_eq!(download_bytes(m, &s) as i64, sum);
        assert!(disk_needed(m, &s) >= download_bytes(m, &s));
    }
}

#[test]
fn the_offline_text_says_nothing_is_downloaded() {
    let m = Manifest::embedded();
    let s = sel(m);
    let t = text_offline(
        m,
        &s,
        Path::new("/h/.local/share/oab-computer/playwright"),
        Some(Path::new("/h")),
        Path::new("/mnt/files"),
    );
    assert!(
        t.contains("/mnt/files") && t.contains("Nothing is downloaded"),
        "{t}"
    );
    assert!(
        !t.contains("Downloads about") && !t.contains("internet connection"),
        "{t}"
    );
    assert!(!t.to_lowercase().contains("safe"));
    assert!(t.contains(&megabytes(disk_needed(m, &s))) && t.contains(&m.id));
}

#[test]
fn megabytes_round_up() {
    assert_eq!(megabytes(0), "0 MB");
    assert_eq!(megabytes(1), "1 MB");
    assert_eq!(megabytes(1_000_000), "1 MB");
    assert_eq!(megabytes(1_000_001), "2 MB");
}

#[test]
fn display_path_shows_home_as_tilde() {
    let h = Path::new("/home/u");
    assert_eq!(display_path(Path::new("/home/u"), Some(h)), "~");
    assert_eq!(display_path(Path::new("/home/u/a/b"), Some(h)), "~/a/b");
    assert_eq!(display_path(Path::new("/home/uu/a"), Some(h)), "/home/uu/a");
    assert_eq!(display_path(Path::new("/x"), None), "/x");
    assert_eq!(display_path(Path::new("/x"), Some(Path::new(""))), "/x");
}

#[test]
fn disk_needed_is_the_larger_of_factor_and_expanded() {
    let m = Manifest::embedded();
    let s = sel(m);
    let dl = download_bytes(m, &s);
    assert!(disk_needed(m, &s) >= m.free_disk_factor as u64 * dl);
    assert!(disk_needed(m, &s) >= disk_bytes(m, &s));
    let mut m2 = m.clone();
    m2.free_disk_factor = 1000;
    let s2 = sel(&m2);
    assert_eq!(disk_needed(&m2, &s2), 1000 * dl);
}
