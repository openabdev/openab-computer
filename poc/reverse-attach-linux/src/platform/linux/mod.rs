//! Linux backends. Only wlroots today; a portal backend (GNOME/KDE) would sit beside it.

pub(crate) mod frame;
pub mod seat;
pub mod wlroots;
