// reverse-attach: makes a Linux node a lendable "hands" node for openab-pty
// reverse-attach. Single self-contained binary: a minimal HTTP/1.1 control
// server (POST/GET /attach, GET/DELETE /attach/{id}) plus a WebSocket dialer that
// connects outbound to a runtime and serves an MCP tool surface.
//
// Synchronous, std threads only. Deps: serde_json + tungstenite (which
// re-exports `http`) + rustls (ring provider, for wss://). Target: aarch64
// Debian 13, Rust 1.98.

mod attach;
mod audit;
mod auth;
// L2 (#119): the managed child, its containment and the router. See the module docs.
mod backend;
// L1a and L1b (#119): the managed Playwright tier. `oab-computer browser ...` reaches all of it
// from `main`, so the 6 MiB size check in CI measures the real code.
mod browser_cli;
mod cancel;
mod catalog;
mod child;
mod consent;
mod containment;
mod download;
#[cfg(test)]
mod e2e_tests;
mod elf;
mod external;
mod extract;
mod health;
mod http;
#[cfg(test)]
mod http_conformance;
mod install;
mod jobs;
mod manifest;
#[cfg(test)]
mod manifest_conformance;
mod mcp;
mod npm;
mod platform;
mod preflight;
mod probe;
mod proc;
mod procnet;
#[cfg(test)]
mod profile_conformance;
mod run_record;
mod schema_shape;
mod sigstop;
mod state;
mod stdio_client;
mod sweep;
#[cfg(test)]
mod tool_schema_shape_tests;
mod tools;
mod unit;
#[cfg(test)]
mod wire_conformance;

/// Install rustls's ring provider as the process default, once. tungstenite builds
/// its rustls `ClientConfig` from the process default; with no provider a wss://
/// dial panics the dial thread (#66). The `ring` feature alone lets rustls pick it,
/// but that auto-pick fails again as soon as any dependency also enables
/// `aws-lc-rs`, so we install it explicitly. Tests call it too, through the same
/// `Once`.
pub(crate) fn install_crypto_provider() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        // Err only means a provider is already installed, which is what we want.
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

fn main() {
    install_crypto_provider();
    // `oab-computer browser <plan|preflight|install|update|remove|status>`: the managed Playwright
    // installer (L1b). Anything else keeps the daemon behaviour.
    // `args_os`: a non-UTF-8 argument must not panic the daemon on start (#132). For `browser` it is
    // a usage error.
    let args: Vec<std::ffi::OsString> = std::env::args_os().collect();
    if args.get(1).is_some_and(|a| a == "browser") {
        let Some(rest) = args[2..]
            .iter()
            .map(|a| a.to_str().map(str::to_string))
            .collect::<Option<Vec<String>>>()
        else {
            eprintln!("browser: arguments must be UTF-8");
            std::process::exit(2);
        };
        std::process::exit(browser_cli::run(&rest));
    }
    // SIGTERM, SIGINT and SIGHUP stop the managed child and its tree, then end the daemon. SIGKILL
    // cannot be handled: the transient unit (BindsTo the daemon unit) is what covers it.
    if let Err(e) = sigstop::install_daemon_handlers(sigstop::stop_all) {
        eprintln!("signal handlers not installed: {e}");
    }
    // Input devices first, so clients see pointer/keyboard capabilities before any tool
    // call (see platform/linux/seat.rs). Non-fatal: a node without a seat still serves bash.
    platform::linux::seat::warm_up(platform::linux::wlroots::seat_command);
    http::serve();
}
