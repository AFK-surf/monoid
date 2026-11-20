// A pointer of an app's own, said before the first message 6 that names it as "custom:<id>" (message 11, the payload
// ScreenView.swift's is): its size and hot spot in points (1 byte each: width and height 1..=128, hot spot within),
// its id (the 64-bit FNV-1a hash of its pixels, size and hot spot, as 16 lowercase hex digits), then its picture as a
// PNG of at most 64 KiB.

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

/// The size and hot spot in points of a pointer `pixels` wide and high at `scale` (the display's, 1 at 96 DPI): none
/// where it is not 1..=128 points a side.
pub fn points(size: (u32, u32), hot: (u32, u32), scale: f64) -> Option<[u8; 4]> {
    let scale = if scale.is_finite() { scale.max(1.0) } else { 1.0 };
    let at = |v: u32| (v as f64 / scale).round() as u32;
    let (w, h) = (at(size.0), at(size.1));
    if !(1..=128).contains(&w) || !(1..=128).contains(&h) {
        return None;
    }
    Some([w as u8, h as u8, at(hot.0).min(w) as u8, at(hot.1).min(h) as u8])
}

/// Its id and message 11's payload, from its points (`points`), its pixels (BGRA) and its PNG; none for a PNG too large.
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fnv1a_is_the_standard_one() {
        assert_eq!(fnv1a(&[]), 0xcbf2_9ce4_8422_2325);
        assert_eq!(fnv1a(&[b"a"]), 0xaf63_dc4c_8601_ec8c);
        assert_eq!(fnv1a(&[b"a", b"b"]), fnv1a(&[b"ab"]));
    }

    #[test]
    fn points_at_the_displays_scale() {
        assert_eq!(points((32, 32), (0, 0), 1.0), Some([32, 32, 0, 0]));
        assert_eq!(points((48, 48), (9, 15), 1.5), Some([32, 32, 6, 10]));
        assert_eq!(points((32, 32), (40, 3), 1.0), Some([32, 32, 32, 3]), "a hot spot outside kept within");
        assert_eq!(points((256, 256), (0, 0), 2.0), Some([128, 128, 0, 0]));
        assert_eq!(points((258, 32), (0, 0), 2.0), None);
        assert_eq!(points((0, 32), (0, 0), 1.0), None);
        assert_eq!(points((32, 32), (0, 0), 0.5), Some([32, 32, 0, 0]), "never larger than its pixels");
    }

    #[test]
    fn its_payload() {
        let png = [0x89, b'P', b'N', b'G', 13, 10, 26, 10, 1];
        let (id, p) = payload([32, 32, 4, 2], &[1, 2, 3, 4], &png).unwrap();
        assert_eq!(id.len(), 16);
        assert!(id.bytes().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
        assert_eq!(&p[..4], &[32, 32, 4, 2]);
        assert_eq!(&p[4..20], id.as_bytes());
        assert_eq!(&p[20..], &png);
        assert_ne!(payload([32, 32, 4, 3], &[1, 2, 3, 4], &png).unwrap().0, id, "another hot spot, another id");
        assert_ne!(payload([32, 32, 4, 2], &[1, 2, 3, 5], &png).unwrap().0, id, "other pixels, another id");
        assert!(payload([32, 32, 4, 2], &[], &[]).is_none());
        assert!(payload([32, 32, 4, 2], &[], &vec![0; PNG_MOST + 1]).is_none());
    }
}
