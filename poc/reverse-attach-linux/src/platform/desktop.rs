//! The desktop a hands node can see and touch, as a trait so the same tools run on any
//! backend: wlroots (grim/wlrctl/wtype, here), xdg-desktop-portal (GNOME/KDE, later),
//! ScreenCaptureKit/CGEvent (macOS, later).
//!
//! Coordinates are display pixels = screenshot pixels at scale 1.

pub type DesktopError = String;

/// A rectangle in layout coordinates (display pixels at scale 1, the space `mouse` uses).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

/// The encoding a capture is returned in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    Png,
    /// JPEG at `quality` 1–100.
    Jpeg {
        quality: u8,
    },
}

/// A captured frame, already encoded.
pub struct Capture {
    pub bytes: Vec<u8>,
    /// `png` or `jpeg`.
    pub format: &'static str,
    /// Encoded image size in pixels.
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Button {
    Left,
    Right,
}

/// A key combo already split into normalised modifiers and one named key.
pub struct Combo {
    /// `ctrl`, `shift`, `alt`, `logo`, `altgr` — backend-neutral names.
    pub modifiers: Vec<String>,
    /// xkb key name (`Return`, `Escape`, `a`, `F4`).
    pub key: String,
}

pub trait Desktop: Send + Sync {
    /// Whether a display is reachable right now (cheap probe). Drives
    /// `sys_info.displays` / `permissions.screen_recording`.
    fn display_ok(&self) -> bool;

    /// The whole output layout, in the coordinates `pointer_goto` takes.
    fn layout(&self) -> Result<Rect, DesktopError>;

    /// Capture `region` (default: the whole layout) at `scale` (output px per display px)
    /// in `format`.
    fn capture(
        &self,
        region: Option<Rect>,
        scale: f64,
        format: Format,
    ) -> Result<Capture, DesktopError>;

    /// Absolute pointer move.
    fn pointer_goto(&self, x: f64, y: f64) -> Result<(), DesktopError>;
    /// Relative pointer move.
    fn pointer_move_rel(&self, dx: f64, dy: f64) -> Result<(), DesktopError>;
    fn pointer_click(&self, button: Button) -> Result<(), DesktopError>;
    fn pointer_press(&self, button: Button) -> Result<(), DesktopError>;
    fn pointer_release(&self, button: Button) -> Result<(), DesktopError>;
    /// Positive `dy` scrolls down, positive `dx` scrolls right.
    fn pointer_scroll(&self, dx: f64, dy: f64) -> Result<(), DesktopError>;

    /// Type text (unicode, layout independent).
    fn key_type(&self, text: &str) -> Result<(), DesktopError>;
    /// Press and release a combo.
    fn key_press(&self, combo: &Combo) -> Result<(), DesktopError>;
}
