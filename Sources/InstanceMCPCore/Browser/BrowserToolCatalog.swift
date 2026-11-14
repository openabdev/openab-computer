import Foundation

/// The 32 real `browser_*` tool names and, for Tier A (Apple Events), how well each is served
/// (requirements R3). One source for the router filter, the Phase 2 backend and the tests.
/// A name an upstream adds later is not in this list and is filtered out on macOS (R1.5).
public enum BrowserToolCatalog {
    public enum Support: String, Sendable { case full, limited, no }

    /// Tier A support, in the order of the requirements table.
    public static let tierA: [(name: String, support: Support)] = [
        ("browser_navigate", .full), ("browser_navigate_back", .full), ("browser_snapshot", .limited),
        ("browser_find", .limited), ("browser_click", .limited), ("browser_type", .limited),
        ("browser_fill_form", .full), ("browser_press_key", .limited), ("browser_hover", .limited),
        ("browser_select_option", .full), ("browser_wait_for", .full), ("browser_tabs", .limited),
        ("browser_take_screenshot", .no), ("browser_console_messages", .no), ("browser_resize", .limited),
        ("browser_evaluate", .limited), ("browser_run_code_unsafe", .no), ("browser_file_upload", .no),
        ("browser_drop", .no), ("browser_pdf_save", .no), ("browser_network_requests", .no),
        ("browser_network_request", .no), ("browser_handle_dialog", .no), ("browser_emulate_media", .no),
        ("browser_close", .full), ("browser_drag", .no), ("browser_mouse_move_xy", .no),
        ("browser_mouse_click_xy", .no), ("browser_mouse_drag_xy", .no), ("browser_mouse_down", .no),
        ("browser_mouse_up", .no), ("browser_mouse_wheel", .limited),
    ]

    public static let allNames: [String] = tierA.map(\.name)
    public static let allNameSet: Set<String> = Set(allNames)

    public static func tierASupport(_ name: String) -> Support? {
        tierA.first { $0.name == name }?.support
    }
}
