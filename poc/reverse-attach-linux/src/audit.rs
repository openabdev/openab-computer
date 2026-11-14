//! The audit trail for retired profile names (#59).
//!
//! When an attach request or a stored grant names the retired `desktop` and the
//! node serves `observe` instead, it appends one JSON line here as well as logging
//! it. The file is append-only and separate from the journal, so the record
//! survives log rotation. Same record shape as the macOS daemon.
//!
//! Path: `MCP_AUDIT_FILE`, else `$XDG_STATE_HOME/oab-computer/audit.jsonl`,
//! else `~/.local/state/oab-computer/audit.jsonl`. `MCP_AUDIT_FILE=off`
//! disables it. Mode 600 in a 0700 directory. Writing is best-effort: a failure
//! is logged and never blocks the grant.

use std::fs;
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use serde_json::{json, Value};

static AUDIT: OnceLock<Option<PathBuf>> = OnceLock::new();
static WRITE: Mutex<()> = Mutex::new(());

/// Configure the audit file once at startup. Returns the path in use, if any.
/// Until this runs (unit tests), recording is a no-op.
pub(crate) fn init_from_env() -> Option<PathBuf> {
    AUDIT.get_or_init(default_path).clone()
}

fn default_path() -> Option<PathBuf> {
    match std::env::var("MCP_AUDIT_FILE") {
        Ok(v) if v == "off" => return None,
        Ok(v) if !v.is_empty() => return Some(PathBuf::from(v)),
        _ => {}
    }
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/state")))?;
    Some(base.join("oab-computer/audit.jsonl"))
}

/// One `profile_mapped` record. `source` is `attach` or `resume`.
pub(crate) fn profile_mapped_record(
    source: &str,
    grant: &str,
    session: &str,
    principal: &str,
    requested: &str,
    profile: &str,
    now_epoch_secs: u64,
) -> Value {
    json!({
        "event": "profile_mapped",
        "source": source,
        "grant": grant,
        "session": session,
        "principal": principal,
        "requested_profile": requested,
        "profile": profile,
        "ts_epoch_secs": now_epoch_secs,
    })
}

/// Append a `profile_mapped` record to the configured audit file, if any.
pub(crate) fn profile_mapped(
    source: &str,
    grant: &str,
    session: &str,
    principal: &str,
    requested: &str,
    profile: &str,
) {
    let Some(Some(path)) = AUDIT.get() else {
        return;
    };
    let record = profile_mapped_record(
        source,
        grant,
        session,
        principal,
        requested,
        profile,
        crate::attach::now_epoch_secs(),
    );
    if let Err(e) = append(path, &record) {
        eprintln!("audit: could not append to {}: {e}", path.display());
    }
}

pub(crate) fn append(path: &Path, record: &Value) -> std::io::Result<()> {
    let _guard = WRITE.lock().unwrap_or_else(|p| p.into_inner());
    if let Some(dir) = path.parent() {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)?;
    }
    let mut f = fs::OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .open(path)?;
    if f.metadata()?.permissions().mode() & 0o077 != 0 {
        f.set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    let mut line = record.to_string();
    line.push('\n');
    f.write_all(line.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_are_private_appended_json_lines() {
        let dir = std::env::temp_dir().join(format!("audit-{}", std::process::id()));
        let path = dir.join("sub/audit.jsonl");
        let a = profile_mapped_record("attach", "g1", "s", "p", "desktop", "observe", 1_700);
        let b = profile_mapped_record("resume", "g1", "s", "p", "desktop", "observe", 1_701);
        append(&path, &a).unwrap();
        append(&path, &b).unwrap();
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        let dir_mode = fs::metadata(path.parent().unwrap())
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(dir_mode, 0o700);
        let text = fs::read_to_string(&path).unwrap();
        let lines: Vec<Value> = text
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        assert_eq!(lines, vec![a, b]);
        assert_eq!(lines[0]["event"], "profile_mapped");
        assert_eq!(lines[1]["source"], "resume");
        assert_eq!(lines[1]["ts_epoch_secs"], 1_701);
        let _ = fs::remove_dir_all(&dir);
    }
}
