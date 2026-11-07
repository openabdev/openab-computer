//! Frame bytes from `grim`: binary PPM (P6) in, JPEG out, and the size of a PNG. Debian's
//! grim is built without libjpeg, so JPEG is encoded here instead of by grim (#32 item 5).

use crate::platform::desktop::DesktopError;

/// An 8-bit RGB image borrowed from a PPM buffer.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Rgb<'a> {
    pub width: u32,
    pub height: u32,
    pub pixels: &'a [u8],
}

/// Parse a binary PPM (`P6`, maxval 255), the format `grim -t ppm` writes.
pub(crate) fn parse_ppm(buf: &[u8]) -> Result<Rgb<'_>, DesktopError> {
    let mut at = 0usize;
    // Header: "P6" then width, height, maxval, separated by whitespace and `#` comments,
    // then exactly one whitespace byte before the pixels.
    let mut fields = [0u32; 3];
    if buf.get(0..2) != Some(b"P6") {
        return Err("ppm: not a binary PPM (P6)".into());
    }
    at += 2;
    for field in fields.iter_mut() {
        loop {
            match buf.get(at) {
                Some(b) if b.is_ascii_whitespace() => at += 1,
                Some(b'#') => {
                    while buf.get(at).is_some_and(|&b| b != b'\n') {
                        at += 1;
                    }
                }
                Some(_) => break,
                None => return Err("ppm: truncated header".into()),
            }
        }
        let start = at;
        while buf.get(at).is_some_and(u8::is_ascii_digit) {
            at += 1;
        }
        *field = std::str::from_utf8(&buf[start..at])
            .ok()
            .and_then(|s| s.parse().ok())
            .ok_or("ppm: bad header number")?;
    }
    if !buf.get(at).is_some_and(u8::is_ascii_whitespace) {
        return Err("ppm: truncated header".into());
    }
    at += 1;
    let [width, height, maxval] = fields;
    if maxval != 255 {
        return Err(format!("ppm: maxval {maxval} unsupported (want 255)"));
    }
    if width == 0 || height == 0 {
        return Err("ppm: empty image".into());
    }
    let len = (width as usize)
        .checked_mul(height as usize)
        .and_then(|n| n.checked_mul(3))
        .ok_or("ppm: image too large")?;
    let pixels = buf
        .get(at..)
        .and_then(|rest| rest.get(..len))
        .ok_or_else(|| format!("ppm: {width}x{height} needs {len} pixel bytes"))?;
    Ok(Rgb {
        width,
        height,
        pixels,
    })
}

/// Encode RGB pixels as baseline JPEG at `quality` 1–100.
pub(crate) fn encode_jpeg(img: &Rgb<'_>, quality: u8) -> Result<Vec<u8>, DesktopError> {
    let (Ok(w), Ok(h)) = (u16::try_from(img.width), u16::try_from(img.height)) else {
        return Err(format!(
            "jpeg: {}x{} exceeds 65535 px per side",
            img.width, img.height
        ));
    };
    let mut out = Vec::with_capacity(img.pixels.len() / 8);
    jpeg_encoder::Encoder::new(&mut out, quality.clamp(1, 100))
        .encode(img.pixels, w, h, jpeg_encoder::ColorType::Rgb)
        .map_err(|e| format!("jpeg: {e}"))?;
    Ok(out)
}

/// (width, height) from a PNG's IHDR chunk.
pub(crate) fn png_dimensions(buf: &[u8]) -> Result<(u32, u32), DesktopError> {
    const SIG: &[u8] = b"\x89PNG\r\n\x1a\n";
    if buf.get(0..8) != Some(SIG) || buf.get(12..16) != Some(b"IHDR") {
        return Err("png: missing signature or IHDR".into());
    }
    let be = |at: usize| u32::from_be_bytes(buf[at..at + 4].try_into().unwrap());
    if buf.len() < 24 {
        return Err("png: truncated IHDR".into());
    }
    Ok((be(16), be(20)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ppm(width: u32, height: u32, header_extra: &str) -> Vec<u8> {
        let mut v = format!("P6\n{header_extra}{width} {height}\n255\n").into_bytes();
        for y in 0..height {
            for x in 0..width {
                v.extend_from_slice(&[(x * 255 / width.max(1)) as u8, (y * 7) as u8, 128]);
            }
        }
        v
    }

    /// (width, height) from the SOF0 marker of a baseline JPEG.
    fn jpeg_sof0(buf: &[u8]) -> Option<(u16, u16)> {
        let at = buf.windows(2).position(|w| w == [0xFF, 0xC0])?;
        let h = u16::from_be_bytes([buf[at + 5], buf[at + 6]]);
        let w = u16::from_be_bytes([buf[at + 7], buf[at + 8]]);
        Some((w, h))
    }

    #[test]
    fn parses_grims_ppm_including_comments() {
        let buf = ppm(3, 2, "# grim\n");
        let img = parse_ppm(&buf).unwrap();
        assert_eq!((img.width, img.height), (3, 2));
        assert_eq!(img.pixels.len(), 18);
        assert_eq!(&img.pixels[..3], &[0, 0, 128]);
        assert_eq!(&img.pixels[15..], &[170, 7, 128]);
    }

    #[test]
    fn rejects_malformed_ppm() {
        assert!(parse_ppm(b"P3\n1 1\n255\n\0\0\0").is_err(), "ascii PPM");
        assert!(
            parse_ppm(b"P6\n1 1\n65535\n\0\0\0\0\0\0").is_err(),
            "16-bit"
        );
        assert!(parse_ppm(b"P6\n2 2\n255\n\0\0\0").is_err(), "short pixels");
        assert!(parse_ppm(b"P6\n0 1\n255\n").is_err(), "empty");
        assert!(parse_ppm(b"P6\n1").is_err(), "truncated header");
        assert!(parse_ppm(b"P6\nx 1\n255\n\0\0\0").is_err(), "non-numeric");
        assert!(
            parse_ppm(b"P6\n99999999999 1\n255\n").is_err(),
            "u32 overflow"
        );
    }

    #[test]
    fn encodes_a_known_buffer_as_jpeg_with_its_size() {
        let buf = ppm(64, 48, "");
        let img = parse_ppm(&buf).unwrap();
        let jpg = encode_jpeg(&img, 70).unwrap();
        assert_eq!(&jpg[..2], &[0xFF, 0xD8], "SOI");
        assert_eq!(&jpg[jpg.len() - 2..], &[0xFF, 0xD9], "EOI");
        assert_eq!(jpeg_sof0(&jpg), Some((64, 48)));
    }

    #[test]
    fn higher_quality_is_not_smaller() {
        let buf = ppm(128, 96, "");
        let img = parse_ppm(&buf).unwrap();
        let low = encode_jpeg(&img, 10).unwrap().len();
        let high = encode_jpeg(&img, 95).unwrap().len();
        assert!(low < high, "q10 {low} B vs q95 {high} B");
    }

    #[test]
    fn jpeg_refuses_sides_over_u16() {
        let img = Rgb {
            width: 70_000,
            height: 1,
            pixels: &[],
        };
        assert!(encode_jpeg(&img, 70).is_err());
    }

    #[test]
    fn reads_png_ihdr() {
        let mut png = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        png.extend_from_slice(&1920u32.to_be_bytes());
        png.extend_from_slice(&1080u32.to_be_bytes());
        assert_eq!(png_dimensions(&png).unwrap(), (1920, 1080));
        assert!(png_dimensions(&png[..20]).is_err());
        assert!(png_dimensions(b"GIF89a").is_err());
    }
}
