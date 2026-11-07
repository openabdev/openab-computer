// reverse-attach: makes a Linux node a lendable "hands" node for openab-pty
// reverse-attach. Single self-contained binary: a minimal HTTP/1.1 control
// server (POST/GET /attach, GET/DELETE /attach/{id}) plus a WebSocket dialer that
// connects outbound to a runtime and serves an MCP tool surface.
//
// Synchronous, std threads only. Deps: serde_json + tungstenite (which
// re-exports `http`) + rustls (ring provider, for wss://). Target: aarch64
// Debian 13, Rust 1.98.

mod attach;
mod auth;
mod http;
#[cfg(test)]
mod http_conformance;
mod jobs;
mod mcp;
mod platform;
mod tools;
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
    // Input devices first, so clients see pointer/keyboard capabilities before any tool
    // call (see platform/linux/seat.rs). Non-fatal: a node without a seat still serves bash.
    platform::linux::seat::warm_up(platform::linux::wlroots::seat_command);
    http::serve();
}
