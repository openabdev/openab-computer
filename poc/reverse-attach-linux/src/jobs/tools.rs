//! The four MCP job tools. Names, arguments and `structuredContent` match the
//! Swift `AsyncExecTools`; the shell is `bash -c` (the Linux `bash` tool's shell)
//! instead of `zsh -f -c`.

use std::time::Duration;

use serde_json::{json, Map, Value};

use super::{
    file_size, iso8601, read_log, registry, JobState, Registry, StartSpec, KEEP_FINISHED,
    MAX_POLL_BYTES, SIGKILL, SIGTERM,
};

pub(crate) const JOB_TOOL_NAMES: &[&str] = &["exec_start", "exec_poll", "exec_list", "exec_cancel"];

type ToolReturn = Result<Value, (i64, String)>;

/// `tools/list` entries, in `JOB_TOOL_NAMES` order.
pub(crate) fn tool_specs() -> Vec<Value> {
    vec![
        json!({
            "name": "exec_start",
            "description": "Start a shell command in the background and return a job_id immediately, \
                            for work that outlives one request (for example a build, or anything over \
                            100 s on a reverse attach). Runs with `bash -c` as the daemon user, like \
                            `bash`. Poll it with `exec_poll` and stop it with `exec_cancel`. The job \
                            keeps running if the attach that started it drops. Prefer plain `bash` \
                            for anything that finishes in a few seconds.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "command":      { "type": "string", "description": "Shell command line, run via `bash -c`." },
                    "cwd":          { "type": "string", "description": "Working directory (a leading ~ is expanded). Default: the daemon user's home." },
                    "timeout_secs": { "type": "number", "description": "Kill the job after this many seconds. 0 = no timeout (stop it with exec_cancel). Default 0." },
                    "env":          { "type": "object", "additionalProperties": { "type": "string" }, "description": "Extra environment variables." }
                },
                "required": ["command"]
            }
        }),
        json!({
            "name": "exec_poll",
            "description": "Fetch a background job's state and any output produced since your last poll. \
                            Pass the `job_id` from exec_start and, to get only new output, the \
                            `stdout_next`/`stderr_next` offsets of the previous poll as \
                            `stdout_since`/`stderr_since`. When `state` is `exited` or `killed`, \
                            `exit_code` is set and no more output will appear. Output is read from the \
                            job's log files (never truncated; at most 1 MiB per stream per poll, poll \
                            again from the returned offsets for the rest). The files are \
                            $XDG_STATE_HOME/oab-instance-mcp/jobs/<job_id>.out/.err (default \
                            ~/.local/state/...); `out_path`/`err_path` give the exact paths.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "job_id":       { "type": "string" },
                    "stdout_since": { "type": "integer", "description": "Byte offset from a prior poll; omit for all stdout." },
                    "stderr_since": { "type": "integer", "description": "Byte offset from a prior poll; omit for all stderr." }
                },
                "required": ["job_id"]
            }
        }),
        json!({
            "name": "exec_list",
            "description": "List background jobs: all currently running ones plus the 10 most recently \
                            finished. For each: job_id, state (running/exited/killed), pid, exit_code, \
                            command, cwd, started_at, finished_at, and current stdout/stderr byte sizes. \
                            Use it to recover a forgotten job_id or to see what is running; then \
                            `exec_poll` a specific job.",
            "inputSchema": { "type": "object", "properties": {} }
        }),
        json!({
            "name": "exec_cancel",
            "description": "Stop a background job by signalling its process group, or drop a finished \
                            job from the list. `signal` is `KILL` (default, immediate) or `TERM` (let it \
                            clean up). Poll once more afterwards to read the final output.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "job_id": { "type": "string" },
                    "signal": { "type": "string", "enum": ["KILL", "TERM"], "default": "KILL" }
                },
                "required": ["job_id"]
            }
        }),
    ]
}

/// Dispatch one of `JOB_TOOL_NAMES` against the daemon's registry.
pub(crate) fn call(name: &str, arguments: &Value) -> ToolReturn {
    match registry() {
        Ok(reg) => call_on(reg, name, arguments),
        Err(e) => Ok(tool_error(format!("background jobs are unavailable: {e}"))),
    }
}

pub(crate) fn call_on(reg: &Registry, name: &str, arguments: &Value) -> ToolReturn {
    match name {
        "exec_start" => exec_start(reg, arguments),
        "exec_poll" => exec_poll(reg, arguments),
        "exec_list" => Ok(exec_list(reg)),
        "exec_cancel" => exec_cancel(reg, arguments),
        other => Err((-32601, format!("unknown tool: {other}"))),
    }
}

/// A tool result the model sees as a failure (`isError`), like Swift `ToolResult.error`.
fn tool_error(message: String) -> Value {
    json!({ "content": [ { "type": "text", "text": message } ], "isError": true })
}

fn with_text(text: String, structured: Value) -> Value {
    json!({ "content": [ { "type": "text", "text": text } ], "structuredContent": structured })
}

fn job_id(arguments: &Value) -> Result<&str, (i64, String)> {
    arguments
        .get("job_id")
        .and_then(|v| v.as_str())
        .ok_or_else(|| (-32602, "job_id is required".to_string()))
}

fn resolve_cwd(arguments: &Value) -> Result<String, String> {
    let home = std::env::var("HOME").unwrap_or_default();
    let cwd = match arguments.get("cwd").and_then(|v| v.as_str()) {
        None => home,
        Some(c) => match c.strip_prefix('~') {
            Some(rest) => format!("{home}{rest}"),
            None => c.to_string(),
        },
    };
    if cwd.is_empty() || !std::path::Path::new(&cwd).is_dir() {
        return Err(format!("cwd is not a directory: {cwd}"));
    }
    Ok(cwd)
}

fn exec_start(reg: &Registry, arguments: &Value) -> ToolReturn {
    let command = arguments
        .get("command")
        .and_then(|c| c.as_str())
        .filter(|c| !c.is_empty())
        .ok_or_else(|| (-32602, "command is required".to_string()))?;
    let timeout = arguments
        .get("timeout_secs")
        .and_then(|v| v.as_f64())
        .filter(|t| t.is_finite() && *t > 0.0)
        .and_then(|t| Duration::try_from_secs_f64(t).ok());
    let mut env = Vec::new();
    if let Some(extra) = arguments.get("env").and_then(|e| e.as_object()) {
        for (k, v) in extra {
            let Some(v) = v.as_str() else { continue };
            if k.is_empty() || k.contains('=') || k.contains('\0') || v.contains('\0') {
                return Err((-32602, format!("invalid env entry: {k:?}")));
            }
            env.push((k.clone(), v.to_string()));
        }
    }
    let cwd = match resolve_cwd(arguments) {
        Ok(c) => c,
        Err(why) => return Ok(tool_error(why)),
    };
    let job = match reg.start(StartSpec {
        command,
        cwd: &cwd,
        env,
        timeout,
    }) {
        Ok(j) => j,
        Err(why) => return Ok(tool_error(why)),
    };
    Ok(with_text(
        format!("started {} (pid {}); poll with exec_poll", job.id, job.pid),
        json!({
            "job_id": job.id,
            "pid": job.pid,
            "state": job.state().as_str(),
            "cwd": cwd,
        }),
    ))
}

fn exec_poll(reg: &Registry, arguments: &Value) -> ToolReturn {
    let id = job_id(arguments)?;
    let Some(job) = reg.get(id) else {
        return Ok(tool_error(format!(
            "unknown job_id: {id} (only running jobs and the {KEEP_FINISHED} most recently finished \
             are kept; the log files may still exist under {})",
            reg.dir().display()
        )));
    };
    let since = |k: &str| arguments.get(k).and_then(|v| v.as_u64()).unwrap_or(0);
    // State first: once it is terminal the shell has exited, so the read below
    // sees all of its output.
    let state = job.state();
    let exit_code = job.exit_code();
    let running = state == JobState::Running;
    let (out, out_next) = read_log(&job.out_path, since("stdout_since"), running);
    let (err, err_next) = read_log(&job.err_path, since("stderr_since"), running);
    let stdout = String::from_utf8_lossy(&out);
    let stderr = String::from_utf8_lossy(&err);

    let mut structured = json!({
        "job_id": id,
        "state": state.as_str(),
        "stdout": stdout,
        "stderr": stderr,
        "stdout_next": out_next,
        "stderr_next": err_next,
        "out_path": job.out_path.display().to_string(),
        "err_path": job.err_path.display().to_string(),
    });
    if let Some(code) = exit_code {
        structured["exit_code"] = json!(code);
    }

    let mut text = String::new();
    text.push_str(&stdout);
    if !stderr.is_empty() {
        if !text.is_empty() {
            text.push('\n');
        }
        text.push_str("[stderr]\n");
        text.push_str(&stderr);
    }
    if !text.is_empty() {
        text.push('\n');
    }
    text.push_str(&format!("[{}", state.as_str()));
    if let Some(code) = exit_code {
        text.push_str(&format!(" exit {code}"));
    }
    text.push(']');
    if out.len() + 3 >= MAX_POLL_BYTES || err.len() + 3 >= MAX_POLL_BYTES {
        text.push_str(" (more output: poll again from stdout_next/stderr_next)");
    }
    Ok(with_text(text, structured))
}

fn exec_list(reg: &Registry) -> Value {
    let jobs = reg.list();
    let entries: Vec<Value> = jobs
        .iter()
        .map(|j| {
            let mut o = Map::new();
            o.insert("job_id".into(), json!(j.id));
            o.insert("state".into(), json!(j.state().as_str()));
            o.insert("pid".into(), json!(j.pid));
            o.insert("command".into(), json!(j.command));
            o.insert("cwd".into(), json!(j.cwd));
            o.insert("started_at".into(), json!(iso8601(j.started_at)));
            o.insert("stdout_bytes".into(), json!(file_size(&j.out_path)));
            o.insert("stderr_bytes".into(), json!(file_size(&j.err_path)));
            if let Some(code) = j.exit_code() {
                o.insert("exit_code".into(), json!(code));
            }
            if let Some(fin) = j.finished_at() {
                o.insert("finished_at".into(), json!(iso8601(fin)));
            }
            Value::Object(o)
        })
        .collect();
    let running = jobs
        .iter()
        .filter(|j| j.state() == JobState::Running)
        .count();
    let text = if jobs.is_empty() {
        "no jobs".to_string()
    } else {
        let lines: Vec<String> = jobs
            .iter()
            .map(|j| {
                let ex = j
                    .exit_code()
                    .map(|c| format!(" exit {c}"))
                    .unwrap_or_default();
                format!(
                    "{}  {}{ex}  pid {}  {}",
                    j.id,
                    j.state().as_str(),
                    j.pid,
                    j.command
                )
            })
            .collect();
        format!(
            "{}\n[{running} running, {} recent finished]",
            lines.join("\n"),
            jobs.len() - running
        )
    };
    with_text(text, json!({ "jobs": entries }))
}

fn exec_cancel(reg: &Registry, arguments: &Value) -> ToolReturn {
    let id = job_id(arguments)?;
    let (sig, sig_name) = match arguments.get("signal").and_then(|s| s.as_str()) {
        None | Some("KILL") => (SIGKILL, "KILL"),
        Some("TERM") => (SIGTERM, "TERM"),
        Some(other) => {
            return Err((
                -32602,
                format!("signal must be KILL or TERM, not {other:?}"),
            ))
        }
    };
    let Some(job) = reg.get(id) else {
        return Ok(tool_error(format!("unknown job_id: {id}")));
    };
    let state = job.state();
    if state != JobState::Running {
        reg.drop_finished(id);
        let code = job.exit_code().unwrap_or(-1);
        return Ok(with_text(
            format!("job {id} already {} (exit {code}); dropped", state.as_str()),
            json!({ "job_id": id, "state": state.as_str(), "dropped": true }),
        ));
    }
    let ok = job.signal(sig);
    let text = if ok {
        format!("signalled {id} ({sig_name}); poll for final output")
    } else {
        format!("could not signal {id}: it had already exited; poll for final output")
    };
    Ok(with_text(
        text,
        json!({ "job_id": id, "signalled": ok, "state": job.state().as_str() }),
    ))
}
