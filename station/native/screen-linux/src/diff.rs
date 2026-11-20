// 32x32 dirty-tile pixel diffing, even-dimension fitting, BGRA crop + bilinear scaling,
// BGRA -> I420 (YUV420p) conversion, and software cursor alpha-blending (for JPEG views).

pub const DIRTY_TILE: usize = 32;

/// Compare two BGRA frames of `width x height` in 32x32 tiles.
/// Returns `true` if any pixel differs or buffer sizes do not match.
pub fn has_dirty_tile(prev: &[u8], curr: &[u8], width: usize, height: usize) -> bool {
    let expected = width.saturating_mul(height).saturating_mul(4);
    if prev.len() != expected || curr.len() != expected {
        return true;
    }
    let stride = width * 4;
    let mut ty = 0;
    while ty < height {
        let th = DIRTY_TILE.min(height - ty);
        let mut tx = 0;
        while tx < width {
            let tw = DIRTY_TILE.min(width - tx);
            let row_bytes = tw * 4;
            for dy in 0..th {
                let off = (ty + dy) * stride + tx * 4;
                if prev[off..off + row_bytes] != curr[off..off + row_bytes] {
                    return true;
                }
            }
            tx += DIRTY_TILE;
        }
        ty += DIRTY_TILE;
    }
    false
}

/// Fit `src_w x src_h` inside `max_w x max_h` without upscaling, rounded down to even dimensions (>= 2).
pub fn fitted_size(src_w: u32, src_h: u32, max_w: u32, max_h: u32) -> (u32, u32) {
    let sw = src_w.max(2) as f64;
    let sh = src_h.max(2) as f64;
    let mw = max_w.max(2) as f64;
    let mh = max_h.max(2) as f64;
    let scale = (mw / sw).min(mh / sh).min(1.0);
    let w = (((sw * scale).floor() as u32) & !1).max(2);
    let h = (((sh * scale).floor() as u32) & !1).max(2);
    (w, h)
}

/// Crop `crop = (cx, cy, cw, ch)` from `src` (`src_w x src_h` BGRA) and bilinearly scale into `dst_w x dst_h` BGRA.
pub fn crop_scale_bgra(
    src: &[u8],
    src_w: u32,
    src_h: u32,
    crop: (u32, u32, u32, u32),
    dst_w: u32,
    dst_h: u32,
    dst: &mut Vec<u8>,
) {
    let (cx, cy, cw, ch) = crop;
    let dw = dst_w as usize;
    let dh = dst_h as usize;
    let sw = src_w as usize;
    dst.resize(dw * dh * 4, 0);

    if cw == 0 || ch == 0 || dw == 0 || dh == 0 || src_w == 0 || src_h == 0 {
        return;
    }

    // Fast path: full-frame 1:1 copy.
    if cx == 0 && cy == 0 && cw == src_w && ch == src_h && dst_w == src_w && dst_h == src_h {
        let len = dw * dh * 4;
        if src.len() >= len {
            dst[..len].copy_from_slice(&src[..len]);
        }
        return;
    }

    // Fast path: cropped 1:1 row copy.
    if cw == dst_w && ch == dst_h {
        let src_stride = sw * 4;
        let dst_stride = dw * 4;
        let cx_b = (cx as usize) * 4;
        for y in 0..dh {
            let sy = (cy as usize + y).min(src_h as usize - 1);
            let s_off = sy * src_stride + cx_b;
            let d_off = y * dst_stride;
            if s_off + dst_stride <= src.len() {
                dst[d_off..d_off + dst_stride].copy_from_slice(&src[s_off..s_off + dst_stride]);
            }
        }
        return;
    }

    // Bilinear scaling using 16.16 fixed-point coordinates.
    let x_step = ((cw as u64) << 16) / (dst_w as u64);
    let y_step = ((ch as u64) << 16) / (dst_h as u64);
    let max_sx = (cx + cw - 1).min(src_w - 1) as usize;
    let max_sy = (cy + ch - 1).min(src_h - 1) as usize;
    let src_stride = sw * 4;

    for dy in 0..dh {
        let sy_fp = ((cy as u64) << 16) + (dy as u64) * y_step;
        let sy0 = (sy_fp >> 16) as usize;
        let sy1 = (sy0 + 1).min(max_sy);
        let fy = (sy_fp & 0xffff) as u32;
        let iy = 65536 - fy;
        let row0 = sy0.min(max_sy) * src_stride;
        let row1 = sy1 * src_stride;
        let dst_row = dy * dw * 4;

        for dx in 0..dw {
            let sx_fp = ((cx as u64) << 16) + (dx as u64) * x_step;
            let sx0 = ((sx_fp >> 16) as usize).min(max_sx);
            let sx1 = (sx0 + 1).min(max_sx);
            let fx = (sx_fp & 0xffff) as u32;
            let ix = 65536 - fx;

            let p00 = row0 + sx0 * 4;
            let p10 = row0 + sx1 * 4;
            let p01 = row1 + sx0 * 4;
            let p11 = row1 + sx1 * 4;

            let w00 = ((ix as u64 * iy as u64) >> 16) as u32;
            let w10 = ((fx as u64 * iy as u64) >> 16) as u32;
            let w01 = ((ix as u64 * fy as u64) >> 16) as u32;
            let w11 = ((fx as u64 * fy as u64) >> 16) as u32;

            let out = dst_row + dx * 4;
            for c in 0..3 {
                let v = (src[p00 + c] as u32 * w00
                    + src[p10 + c] as u32 * w10
                    + src[p01 + c] as u32 * w01
                    + src[p11 + c] as u32 * w11
                    + 32768)
                    >> 16;
                dst[out + c] = v.min(255) as u8;
            }
            dst[out + 3] = 255;
        }
    }
}

/// Convert BGRA8 (`width x height`, even dimensions) into planar I420 (BT.601 studio range).
pub fn bgra_to_i420(
    bgra: &[u8],
    width: usize,
    height: usize,
    y_plane: &mut Vec<u8>,
    u_plane: &mut Vec<u8>,
    v_plane: &mut Vec<u8>,
) {
    let cw = width / 2;
    let ch = height / 2;
    y_plane.resize(width * height, 16);
    u_plane.resize(cw * ch, 128);
    v_plane.resize(cw * ch, 128);

    let stride = width * 4;
    for row in 0..height {
        let src_row = row * stride;
        let y_row = row * width;
        for col in 0..width {
            let p = src_row + col * 4;
            let b = bgra[p] as i32;
            let g = bgra[p + 1] as i32;
            let r = bgra[p + 2] as i32;
            let y = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
            y_plane[y_row + col] = y.clamp(0, 255) as u8;
        }
    }

    for row in 0..ch {
        let r0 = (row * 2) * stride;
        let r1 = (row * 2 + 1) * stride;
        let uv_row = row * cw;
        for col in 0..cw {
            let c0 = col * 8;
            let c1 = c0 + 4;
            let b = (bgra[r0 + c0] as i32
                + bgra[r0 + c1] as i32
                + bgra[r1 + c0] as i32
                + bgra[r1 + c1] as i32
                + 2)
                >> 2;
            let g = (bgra[r0 + c0 + 1] as i32
                + bgra[r0 + c1 + 1] as i32
                + bgra[r1 + c0 + 1] as i32
                + bgra[r1 + c1 + 1] as i32
                + 2)
                >> 2;
            let r = (bgra[r0 + c0 + 2] as i32
                + bgra[r0 + c1 + 2] as i32
                + bgra[r1 + c0 + 2] as i32
                + bgra[r1 + c1 + 2] as i32
                + 2)
                >> 2;
            let u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
            let v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
            u_plane[uv_row + col] = u.clamp(0, 255) as u8;
            v_plane[uv_row + col] = v.clamp(0, 255) as u8;
        }
    }
}

/// Alpha-blend a straight RGBA8 cursor onto a BGRA8 frame (used only for JPEG views).
pub fn blend_cursor_bgra(
    bgra: &mut [u8],
    width: u32,
    height: u32,
    cursor_rgba: &[u8],
    cw: u32,
    ch: u32,
    cx: i32,
    cy: i32,
) {
    let w = width as i32;
    let h = height as i32;
    for dy in 0..ch as i32 {
        let py = cy + dy;
        if py < 0 || py >= h {
            continue;
        }
        for dx in 0..cw as i32 {
            let px = cx + dx;
            if px < 0 || px >= w {
                continue;
            }
            let c_off = ((dy as u32 * cw + dx as u32) * 4) as usize;
            if c_off + 4 > cursor_rgba.len() {
                continue;
            }
            let a = cursor_rgba[c_off + 3] as u32;
            if a == 0 {
                continue;
            }
            let d_off = ((py as u32 * width + px as u32) * 4) as usize;
            if d_off + 4 > bgra.len() {
                continue;
            }
            let sr = cursor_rgba[c_off] as u32;
            let sg = cursor_rgba[c_off + 1] as u32;
            let sb = cursor_rgba[c_off + 2] as u32;
            if a == 255 {
                bgra[d_off] = sb as u8;
                bgra[d_off + 1] = sg as u8;
                bgra[d_off + 2] = sr as u8;
            } else {
                let ia = 255 - a;
                bgra[d_off] = ((sb * a + bgra[d_off] as u32 * ia + 127) / 255) as u8;
                bgra[d_off + 1] = ((sg * a + bgra[d_off + 1] as u32 * ia + 127) / 255) as u8;
                bgra[d_off + 2] = ((sr * a + bgra[d_off + 2] as u32 * ia + 127) / 255) as u8;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dirty_tile_detects_single_pixel_change() {
        let w = 64;
        let h = 48;
        let a = vec![10u8; w * h * 4];
        let mut b = a.clone();
        assert!(!has_dirty_tile(&a, &b, w, h));
        // Change one pixel in the bottom-right tile.
        b[(47 * w + 63) * 4] = 11;
        assert!(has_dirty_tile(&a, &b, w, h));
        // Mismatched lengths always count as dirty.
        assert!(has_dirty_tile(&a[..4], &b, w, h));
    }

    #[test]
    fn fitted_size_even_and_no_upscale() {
        assert_eq!(fitted_size(1920, 1080, 1280, 720), (1280, 720));
        assert_eq!(fitted_size(1280, 720, 3840, 2160), (1280, 720));
        assert_eq!(fitted_size(1001, 999, 501, 501), (500, 498));
        assert_eq!(fitted_size(10, 10, 1, 1), (2, 2));
    }

    #[test]
    fn crop_scale_and_i420_and_cursor_blend() {
        let mut src = vec![0u8; 8 * 8 * 4];
        for px in src.chunks_exact_mut(4) {
            px.copy_from_slice(&[20, 100, 200, 255]); // B=20, G=100, R=200
        }
        let mut dst = Vec::new();
        crop_scale_bgra(&src, 8, 8, (0, 0, 8, 8), 4, 4, &mut dst);
        assert_eq!(dst.len(), 4 * 4 * 4);
        assert_eq!(&dst[..4], &[20, 100, 200, 255]);

        // Blend an opaque green cursor at (1, 1).
        let cursor = [0u8, 255, 0, 255];
        blend_cursor_bgra(&mut dst, 4, 4, &cursor, 1, 1, 1, 1);
        let off = (4 + 1) * 4;
        assert_eq!(&dst[off..off + 3], &[0, 255, 0]);

        let (mut y, mut u, mut v) = (Vec::new(), Vec::new(), Vec::new());
        bgra_to_i420(&dst, 4, 4, &mut y, &mut u, &mut v);
        assert_eq!(y.len(), 16);
        assert_eq!(u.len(), 4);
        assert_eq!(v.len(), 4);
    }

    #[test]
    fn jpeg_cursor_blend_in_scratch_does_not_pollute_prev_diff() {
        let prev = vec![42u8; 32 * 32 * 4];
        let curr = prev.clone();
        let mut jpeg_scratch = curr.clone();
        let cursor = [255u8, 0, 0, 255];
        blend_cursor_bgra(&mut jpeg_scratch, 32, 32, &cursor, 1, 1, 10, 10);
        // Scratch buffer has the cursor composited, while cursor-free diff remains clean.
        assert!(has_dirty_tile(&prev, &jpeg_scratch, 32, 32));
        assert!(!has_dirty_tile(&prev, &curr, 32, 32));
    }
}
