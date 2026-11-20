// Custom cursor image encoding (message 11), matching `station/native/screen/src/cursor_image.rs`
// and `station/src/screens/source.ts` (`cursorImageShape`):
// [w_pt, h_pt, hot_x_pt, hot_y_pt] + 16 lowercase hex FNV-1a id + PNG (<= 64 KiB).

pub const PNG_MOST: usize = 65536;

/// 64-bit FNV-1a over `parts` one after another.
pub fn fnv1a(parts: &[&[u8]]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for part in parts {
        for byte in *part {
            hash ^= *byte as u64;
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
    }
    hash
}

/// The size and hot spot in points of a pointer `size` wide and high at `scale` (clamped >= 1.0);
/// `None` if either side is outside `1..=128` points.
pub fn points(size: (u32, u32), hot: (u32, u32), scale: f64) -> Option<[u8; 4]> {
    let scale = if scale.is_finite() {
        scale.max(1.0)
    } else {
        1.0
    };
    let at = |v: u32| (v as f64 / scale).round() as u32;
    let (w, h) = (at(size.0), at(size.1));
    if !(1..=128).contains(&w) || !(1..=128).contains(&h) {
        return None;
    }
    Some([w as u8, h as u8, at(hot.0).min(w) as u8, at(hot.1).min(h) as u8])
}

/// Build `(id, payload)` for message 11 from `head`, raw pixel bytes, and encoded PNG bytes.
pub fn payload(head: [u8; 4], pixels: &[u8], png: &[u8]) -> Option<(String, Vec<u8>)> {
    if png.is_empty() || png.len() > PNG_MOST {
        return None;
    }
    let id = format!("{:016x}", fnv1a(&[pixels, &head]));
    let mut out = Vec::with_capacity(20 + png.len());
    out.extend_from_slice(&head);
    out.extend_from_slice(id.as_bytes());
    out.extend_from_slice(png);
    Some((id, out))
}

/// Convert XFixes premultiplied ARGB32 (`u32` words) to straight RGBA8 bytes.
pub fn argb32_premul_to_rgba(argb: &[u32]) -> Vec<u8> {
    let mut rgba = Vec::with_capacity(argb.len() * 4);
    for &px in argb {
        let a = ((px >> 24) & 0xff) as u8;
        let r = ((px >> 16) & 0xff) as u8;
        let g = ((px >> 8) & 0xff) as u8;
        let b = (px & 0xff) as u8;
        if a == 0 {
            rgba.extend_from_slice(&[0, 0, 0, 0]);
        } else if a == 255 {
            rgba.extend_from_slice(&[r, g, b, 255]);
        } else {
            let a16 = a as u16;
            let unpremul = |c: u8| (((c as u16) * 255 + a16 / 2) / a16).min(255) as u8;
            rgba.extend_from_slice(&[unpremul(r), unpremul(g), unpremul(b), a]);
        }
    }
    rgba
}

/// Encode straight RGBA8 pixels as a PNG image.
pub fn encode_png(rgba: &[u8], width: u32, height: u32) -> Option<Vec<u8>> {
    if width == 0 || height == 0 || rgba.len() != (width as usize) * (height as usize) * 4 {
        return None;
    }
    let mut buf = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut buf, width, height);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header().ok()?;
        writer.write_image_data(rgba).ok()?;
    }
    if buf.len() > PNG_MOST {
        return None;
    }
    Some(buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fnv1a_matches_standard() {
        assert_eq!(fnv1a(&[]), 0xcbf2_9ce4_8422_2325);
        assert_eq!(fnv1a(&[b"a"]), 0xaf63_dc4c_8601_ec8c);
        assert_eq!(fnv1a(&[b"a", b"b"]), fnv1a(&[b"ab"]));
    }

    #[test]
    fn points_at_scale() {
        assert_eq!(points((32, 32), (0, 0), 1.0), Some([32, 32, 0, 0]));
        assert_eq!(points((48, 48), (9, 15), 1.5), Some([32, 32, 6, 10]));
        assert_eq!(points((32, 32), (40, 3), 1.0), Some([32, 32, 32, 3]));
        assert_eq!(points((256, 256), (0, 0), 2.0), Some([128, 128, 0, 0]));
        assert_eq!(points((258, 32), (0, 0), 2.0), None);
        assert_eq!(points((0, 32), (0, 0), 1.0), None);
        assert_eq!(points((32, 32), (0, 0), 0.5), Some([32, 32, 0, 0]));
    }

    #[test]
    fn encodes_png_and_payload() {
        let argb = vec![0x8040_2010u32; 16];
        let rgba = argb32_premul_to_rgba(&argb);
        assert_eq!(rgba.len(), 64);
        assert_eq!(rgba[3], 0x80);
        let png = encode_png(&rgba, 4, 4).unwrap();
        assert_eq!(&png[..8], &[0x89, b'P', b'N', b'G', 13, 10, 26, 10]);
        let (id, p) = payload([4, 4, 1, 1], &rgba, &png).unwrap();
        assert_eq!(id.len(), 16);
        assert!(id.bytes().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
        assert_eq!(&p[..4], &[4, 4, 1, 1]);
        assert_eq!(&p[4..20], id.as_bytes());
        assert_eq!(&p[20..], &png[..]);
        assert!(payload([4, 4, 1, 1], &rgba, &[]).is_none());
        assert!(payload([4, 4, 1, 1], &rgba, &vec![0; PNG_MOST + 1]).is_none());
    }
}
