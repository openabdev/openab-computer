//! `screenshot`: the display as MCP `image` content. Same arguments and result shape as the
//! Swift `ScreenshotTool`: `format` jpeg (default) | png, `quality` 0–1 (or 1–100), `scale`,
//! `region` {x,y,width,height} in display pixels, `display` 0.

use serde_json::{json, Value};

use crate::platform;
use crate::platform::desktop::{Format, Rect};

const DEFAULT_SCALE: f64 = 0.5;
/// The Swift default, 0.7.
const DEFAULT_QUALITY: u8 = 70;
const REGION_ERR: &str = "region needs x, y, width>0, height>0";

/// A requested crop, as given (display pixels, possibly fractional or off-screen).
#[derive(Clone, Copy, Debug, PartialEq)]
struct RegionArg {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

#[derive(Debug, PartialEq)]
struct Request {
    scale: f64,
    format: Format,
    region: Option<RegionArg>,
}

fn invalid(msg: impl Into<String>) -> (i64, String) {
    (-32602, msg.into())
}

/// `arguments[key]`, with JSON `null` treated as absent.
fn arg<'a>(arguments: &'a Value, key: &str) -> Option<&'a Value> {
    arguments.get(key).filter(|v| !v.is_null())
}

/// JPEG quality as 10–100. Values 0–1 are a fraction (the Swift contract, and what Connect
/// sends), floored at 0.1 like Swift; 10–100 is already a percentage. Values between 1 and 10
/// are ambiguous (a fraction slightly over 1, or a tiny percentage) and rejected.
fn quality_percent(q: f64) -> Option<u8> {
    let pct = if (0.0..=1.0).contains(&q) {
        q.max(0.1) * 100.0
    } else if (10.0..=100.0).contains(&q) {
        q
    } else {
        return None;
    };
    Some(pct.round() as u8)
}

fn parse(arguments: &Value) -> Result<Request, (i64, String)> {
    if let Some(d) = arg(arguments, "display") {
        match d.as_u64() {
            Some(0) => {}
            Some(n) => {
                return Err((
                    -32000,
                    format!("display {n} out of range; 1 display(s) available"),
                ))
            }
            None => return Err(invalid("display must be a non-negative integer")),
        }
    }
    let scale = match arg(arguments, "scale") {
        None => DEFAULT_SCALE,
        Some(v) => v
            .as_f64()
            .ok_or_else(|| invalid("scale must be a number"))?,
    };
    if !(0.05..=2.0).contains(&scale) {
        return Err(invalid("scale must be in 0.05..=2.0"));
    }
    let png = match arg(arguments, "format") {
        None => false,
        Some(v) => match v.as_str() {
            Some("jpeg") => false,
            Some("png") => true,
            _ => return Err(invalid("format must be jpeg or png")),
        },
    };
    let quality = match arg(arguments, "quality") {
        None => DEFAULT_QUALITY,
        Some(v) => v
            .as_f64()
            .and_then(quality_percent)
            .ok_or_else(|| invalid("quality must be 0-1 (fraction) or 10-100 (percent)"))?,
    };
    let region = match arg(arguments, "region") {
        None => None,
        Some(r) => {
            let num = |k: &str| r.get(k).and_then(Value::as_f64).filter(|v| v.is_finite());
            let (Some(x), Some(y), Some(width), Some(height)) =
                (num("x"), num("y"), num("width"), num("height"))
            else {
                return Err(invalid(REGION_ERR));
            };
            if width <= 0.0 || height <= 0.0 {
                return Err(invalid(REGION_ERR));
            }
            Some(RegionArg {
                x,
                y,
                width,
                height,
            })
        }
    };
    Ok(Request {
        scale,
        format: if png {
            Format::Png
        } else {
            Format::Jpeg { quality }
        },
        region,
    })
}

/// The whole-pixel rectangle covering `r`, intersected with `layout`; `None` when they do
/// not overlap.
fn clip(r: RegionArg, layout: Rect) -> Option<Rect> {
    let (lx0, ly0) = (layout.x as f64, layout.y as f64);
    let (lx1, ly1) = (lx0 + layout.width as f64, ly0 + layout.height as f64);
    let x0 = r.x.floor().max(lx0);
    let y0 = r.y.floor().max(ly0);
    let x1 = (r.x + r.width).ceil().min(lx1);
    let y1 = (r.y + r.height).ceil().min(ly1);
    if x1 <= x0 || y1 <= y0 {
        return None;
    }
    Some(Rect {
        x: x0 as i32,
        y: y0 as i32,
        width: (x1 - x0) as u32,
        height: (y1 - y0) as u32,
    })
}

pub fn tool_screenshot(arguments: &Value) -> Result<Value, (i64, String)> {
    let req = parse(arguments)?;
    let desktop = platform::desktop();
    // The layout gives `points` and bounds a crop. If the outputs cannot be read, a
    // full-frame capture still works; a crop does not.
    let layout = desktop.layout();
    let region = match (req.region, &layout) {
        (None, _) => None,
        (Some(r), Ok(l)) => Some(
            clip(r, *l).ok_or_else(|| (-32000, "region lies outside the display".to_string()))?,
        ),
        (Some(_), Err(e)) => return Err((-32000, format!("cannot read the output layout: {e}"))),
    };

    let cap = desktop
        .capture(region, req.scale, req.format)
        .map_err(|e| (-32000, e))?;
    let mime = if cap.format == "png" {
        "image/png"
    } else {
        "image/jpeg"
    };
    let data = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &cap.bytes);
    let rect = |r: Rect| json!({ "x": r.x, "y": r.y, "width": r.width, "height": r.height });
    let shown = region.or(layout.as_ref().ok().copied());
    let mut structured = json!({
        "display": 0,
        "image": { "width": cap.width, "height": cap.height, "bytes": cap.bytes.len() },
        "scale": req.scale,
        // Kept from the first Linux shape.
        "bytes": cap.bytes.len(),
        "format": cap.format,
    });
    if let Ok(l) = &layout {
        structured["points"] = json!({ "width": l.width, "height": l.height });
    }
    if let Some(r) = shown {
        structured["region"] = rect(r);
    }
    let crop = region
        .map(|r| format!(" region {},{} {}×{}px", r.x, r.y, r.width, r.height))
        .unwrap_or_default();
    let size = layout
        .as_ref()
        .map(|l| format!("{}×{} px", l.width, l.height))
        .unwrap_or_else(|_| "layout unknown".to_string());
    let caption = format!(
        "display 0: {size}{crop} → {}×{} px {mime} ({} KiB), scale {}",
        cap.width,
        cap.height,
        cap.bytes.len() / 1024,
        req.scale
    );
    Ok(json!({
        "content": [
            { "type": "image", "mimeType": mime, "data": data },
            { "type": "text", "text": caption }
        ],
        "structuredContent": structured
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    const LAYOUT: Rect = Rect {
        x: 0,
        y: 0,
        width: 1920,
        height: 1080,
    };

    fn region(x: f64, y: f64, width: f64, height: f64) -> RegionArg {
        RegionArg {
            x,
            y,
            width,
            height,
        }
    }

    #[test]
    fn defaults_match_the_swift_tool() {
        let req = parse(&json!({})).unwrap();
        assert_eq!(req.format, Format::Jpeg { quality: 70 });
        assert_eq!(req.scale, 0.5);
        assert_eq!(req.region, None);
    }

    #[test]
    fn connect_shaped_call_parses() {
        let req =
            parse(&json!({"display": 0, "scale": 1, "quality": 0.6, "format": "jpeg"})).unwrap();
        assert_eq!(req.format, Format::Jpeg { quality: 60 });
        assert_eq!(req.scale, 1.0);
        let png = parse(&json!({"format": "png", "quality": 10})).unwrap();
        assert_eq!(png.format, Format::Png);
        assert_eq!(
            parse(&json!({"format": null})).unwrap().format,
            Format::Jpeg { quality: 70 }
        );
    }

    #[test]
    fn quality_accepts_fractions_and_percentages() {
        for (q, want) in [
            (0.6, 60),
            (0.7, 70),
            (1.0, 100),
            (0.0, 10),
            (0.004, 10),
            (0.1, 10),
            (10.0, 10),
            (60.0, 60),
            (100.0, 100),
        ] {
            assert_eq!(quality_percent(q), Some(want), "{q}");
        }
        for q in [-0.1, 1.0001, 1.5, 5.0, 9.99, 100.5, f64::NAN, f64::INFINITY] {
            assert_eq!(quality_percent(q), None, "{q}");
        }
        assert_eq!(
            parse(&json!({"quality": 80})).unwrap().format,
            Format::Jpeg { quality: 80 }
        );
    }

    #[test]
    fn invalid_arguments_are_rejected() {
        for args in [
            json!({"scale": 0.04}),
            json!({"scale": 2.01}),
            json!({"scale": "1"}),
            json!({"format": "gif"}),
            json!({"format": 1}),
            json!({"quality": 101}),
            json!({"quality": 1.5}),
            json!({"quality": -1}),
            json!({"quality": "high"}),
            json!({"display": -1}),
            json!({"display": "0"}),
            json!({"region": {"x": 0, "y": 0, "width": 10}}),
            json!({"region": {"x": 0, "y": 0, "width": 0, "height": 10}}),
            json!({"region": {"x": 0, "y": 0, "width": 10, "height": -1}}),
            json!({"region": {"x": "0", "y": 0, "width": 10, "height": 10}}),
            json!({"region": [0, 0, 10, 10]}),
        ] {
            assert_eq!(parse(&args).unwrap_err().0, -32602, "{args}");
        }
        assert_eq!(parse(&json!({"display": 1})).unwrap_err().0, -32000);
        for ok in [
            json!({"scale": 0.05}),
            json!({"scale": 2.0}),
            json!({"display": 0}),
        ] {
            assert!(parse(&ok).is_ok(), "{ok}");
        }
    }

    #[test]
    fn region_is_clipped_to_the_layout() {
        let inside = clip(region(100.0, 50.0, 300.0, 200.0), LAYOUT).unwrap();
        assert_eq!(
            inside,
            Rect {
                x: 100,
                y: 50,
                width: 300,
                height: 200
            }
        );
        // Fractional edges grow outwards to whole pixels.
        let frac = clip(region(10.5, 20.25, 5.0, 5.0), LAYOUT).unwrap();
        assert_eq!(
            frac,
            Rect {
                x: 10,
                y: 20,
                width: 6,
                height: 6
            }
        );
        let partial = clip(region(-50.0, 1000.0, 100.0, 500.0), LAYOUT).unwrap();
        assert_eq!(
            partial,
            Rect {
                x: 0,
                y: 1000,
                width: 50,
                height: 80
            }
        );
        let huge = clip(region(-1e300, -1e300, 1e301, 1e301), LAYOUT).unwrap();
        assert_eq!(huge, LAYOUT);
    }

    #[test]
    fn region_outside_the_layout_is_none() {
        assert_eq!(clip(region(1920.0, 0.0, 10.0, 10.0), LAYOUT), None);
        assert_eq!(clip(region(0.0, -20.0, 10.0, 20.0), LAYOUT), None);
        assert_eq!(clip(region(5000.0, 5000.0, 1.0, 1.0), LAYOUT), None);
    }

    #[test]
    fn region_respects_a_layout_origin() {
        let layout = Rect {
            x: -1920,
            y: 0,
            width: 3840,
            height: 1080,
        };
        let r = clip(region(-2000.0, 0.0, 200.0, 100.0), layout).unwrap();
        assert_eq!(
            r,
            Rect {
                x: -1920,
                y: 0,
                width: 120,
                height: 100
            }
        );
    }
}
