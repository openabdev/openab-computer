//! The 32 real `browser_*` tool names the pinned Playwright MCP serves (L1b). The installer's health
//! check requires every one of them; L2's router reuses the list. A test compares it with the
//! Swift `BrowserToolCatalog` so the two cannot drift.

pub const BROWSER_TOOLS: [&str; 32] = [
    "browser_navigate",
    "browser_navigate_back",
    "browser_snapshot",
    "browser_find",
    "browser_click",
    "browser_type",
    "browser_fill_form",
    "browser_press_key",
    "browser_hover",
    "browser_select_option",
    "browser_wait_for",
    "browser_tabs",
    "browser_take_screenshot",
    "browser_console_messages",
    "browser_resize",
    "browser_evaluate",
    "browser_run_code_unsafe",
    "browser_file_upload",
    "browser_drop",
    "browser_pdf_save",
    "browser_network_requests",
    "browser_network_request",
    "browser_handle_dialog",
    "browser_emulate_media",
    "browser_close",
    "browser_drag",
    "browser_mouse_move_xy",
    "browser_mouse_click_xy",
    "browser_mouse_drag_xy",
    "browser_mouse_down",
    "browser_mouse_up",
    "browser_mouse_wheel",
];

#[cfg(test)]
mod tests {
    use super::BROWSER_TOOLS;

    #[test]
    fn matches_the_swift_catalog() {
        let swift =
            include_str!("../../../Sources/InstanceMCPCore/Browser/BrowserToolCatalog.swift");
        let mut from_swift: Vec<&str> = Vec::new();
        for part in swift.split("(\"").skip(1) {
            if let Some(name) = part.split('"').next() {
                if name.starts_with("browser_") {
                    from_swift.push(name);
                }
            }
        }
        assert_eq!(from_swift, BROWSER_TOOLS.to_vec());
    }

    #[test]
    fn names_are_unique() {
        let mut v = BROWSER_TOOLS.to_vec();
        v.sort_unstable();
        v.dedup();
        assert_eq!(v.len(), 32);
    }
}
