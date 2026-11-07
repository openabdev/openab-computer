//! `Desktop` for wlroots compositors (labwc, sway, wayfire): `grim` (wlr-screencopy) for
//! frames (JPEG encoded in-process, `frame.rs`), a persistent virtual pointer (`seat.rs`,
//! wlr virtual-pointer) for the mouse, and `wtype` (virtual-keyboard) behind a persistent keyboard anchor for keys. Transient
//! `wlrctl`/`wtype` devices alone are dropped on a seat with no physical input — see seat.rs.
//!
//! Every helper is run with `WAYLAND_DISPLAY` / `XDG_RUNTIME_DIR` defaulted to the seat's
//! usual values, because a systemd unit or an ssh-started daemon has neither.

use std::process::Command;

use super::{frame, seat};
use crate::platform::desktop::{Button, Capture, Combo, Desktop, DesktopError, Format, Rect};

pub struct Wlroots;

extern "C" {
    fn getuid() -> u32;
}

pub(crate) fn seat_command(bin: &str) -> Command {
    let mut cmd = Command::new(bin);
    if std::env::var_os("WAYLAND_DISPLAY").is_none() {
        cmd.env("WAYLAND_DISPLAY", "wayland-0");
    }
    if std::env::var_os("XDG_RUNTIME_DIR").is_none() {
        // SAFETY: getuid has no preconditions and cannot fail.
        cmd.env(
            "XDG_RUNTIME_DIR",
            format!("/run/user/{}", unsafe { getuid() }),
        );
    }
    cmd
}

fn run_seat(bin: &str, args: &[String]) -> Result<(), DesktopError> {
    let out = seat_command(bin)
        .args(args)
        .output()
        .map_err(|e| format!("{bin}: {e}"))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(format!(
            "{bin} {} failed ({}): {}",
            args.join(" "),
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        ))
    }
}

fn sv(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|s| s.to_string()).collect()
}

fn grim_command(scale: f64, region: Option<Rect>, filetype: &str) -> Command {
    let mut cmd = seat_command("grim");
    cmd.arg("-s").arg(format!("{scale}"));
    if let Some(r) = region {
        cmd.arg("-g").arg(grim_geometry(r));
    }
    cmd.arg("-t").arg(filetype);
    cmd.arg("-"); // stdout
    cmd
}

/// grim's `-g` syntax: `x,y wxh` in layout coordinates.
fn grim_geometry(r: Rect) -> String {
    format!("{},{} {}x{}", r.x, r.y, r.width, r.height)
}

impl Desktop for Wlroots {
    fn display_ok(&self) -> bool {
        grim_command(0.05, None, "png")
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    }

    fn layout(&self) -> Result<Rect, DesktopError> {
        let (x, y, width, height) = seat::layout()?;
        Ok(Rect {
            x,
            y,
            width,
            height,
        })
    }

    fn capture(
        &self,
        region: Option<Rect>,
        scale: f64,
        format: Format,
    ) -> Result<Capture, DesktopError> {
        // JPEG: grim writes raw PPM and we encode it, because Debian's grim has no libjpeg.
        let filetype = match format {
            Format::Png => "png",
            Format::Jpeg { .. } => "ppm",
        };
        let out = grim_command(scale, region, filetype)
            .output()
            .map_err(|e| format!("grim: {e}"))?;
        if !out.status.success() {
            let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
            return Err(format!("grim failed ({}): {err}", out.status));
        }
        match format {
            Format::Png => {
                let (width, height) = frame::png_dimensions(&out.stdout)?;
                Ok(Capture {
                    bytes: out.stdout,
                    format: "png",
                    width,
                    height,
                })
            }
            Format::Jpeg { quality } => {
                let img = frame::parse_ppm(&out.stdout)?;
                Ok(Capture {
                    bytes: frame::encode_jpeg(&img, quality)?,
                    format: "jpeg",
                    width: img.width,
                    height: img.height,
                })
            }
        }
    }

    /// Absolute motion over the whole output layout (screenshot pixels at scale 1).
    fn pointer_goto(&self, x: f64, y: f64) -> Result<(), DesktopError> {
        seat::pointer_goto(x, y)
    }

    fn pointer_move_rel(&self, dx: f64, dy: f64) -> Result<(), DesktopError> {
        seat::pointer_move_rel(dx, dy)
    }

    fn pointer_click(&self, button: Button) -> Result<(), DesktopError> {
        seat::pointer_click(button)
    }

    fn pointer_press(&self, button: Button) -> Result<(), DesktopError> {
        seat::pointer_press(button)
    }

    fn pointer_release(&self, button: Button) -> Result<(), DesktopError> {
        seat::pointer_release(button)
    }

    fn pointer_scroll(&self, dx: f64, dy: f64) -> Result<(), DesktopError> {
        seat::pointer_scroll(dx, dy)
    }

    fn key_type(&self, text: &str) -> Result<(), DesktopError> {
        seat::ensure_keyboard(seat_command)?;
        // `--` so text starting with '-' is not parsed as a flag.
        run_seat("wtype", &sv(&["--", text]))
    }

    fn key_press(&self, combo: &Combo) -> Result<(), DesktopError> {
        let mut args: Vec<String> = Vec::new();
        for m in &combo.modifiers {
            args.push("-M".into());
            args.push(m.clone());
        }
        if !combo.modifiers.is_empty() {
            // wtype's own keyboard arrives with a fresh keymap; give the client a moment to
            // apply it and the modifier state before the key, or shortcuts land as plain keys.
            args.push("-s".into());
            args.push("40".into());
        }
        args.push("-k".into());
        args.push(combo.key.clone());
        for m in combo.modifiers.iter().rev() {
            args.push("-m".into());
            args.push(m.clone());
        }
        seat::ensure_keyboard(seat_command)?;
        run_seat("wtype", &args)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grim_gets_scale_region_and_filetype() {
        let r = Rect {
            x: -10,
            y: 20,
            width: 300,
            height: 40,
        };
        let cmd = grim_command(0.5, Some(r), "ppm");
        let args: Vec<_> = cmd.get_args().map(|a| a.to_str().unwrap()).collect();
        assert_eq!(args, ["-s", "0.5", "-g", "-10,20 300x40", "-t", "ppm", "-"]);
        let cmd = grim_command(1.0, None, "png");
        let args: Vec<_> = cmd.get_args().map(|a| a.to_str().unwrap()).collect();
        assert_eq!(args, ["-s", "1", "-t", "png", "-"]);
    }
}
