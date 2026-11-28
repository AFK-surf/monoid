///|
fn ref_multiply_alpha(d : FixedArray[Byte]) -> Unit {
  let n = d.length() / 4
  for i in 0..<n {
    let a = fi(d[i * 4 + 3].to_int()) / 255.0
    for k in 0..<3 {
      d[i * 4 + k] = f2u8(fi(d[i * 4 + k].to_int()) * a + 0.5).to_byte()
    }
  }
}

///|
fn ref_demultiply_alpha(d : FixedArray[Byte]) -> Unit {
  let n = d.length() / 4
  for i in 0..<n {
    let a = fi(d[i * 4 + 3].to_int()) / 255.0
    for k in 0..<3 {
      d[i * 4 + k] = f2u8(fi(d[i * 4 + k].to_int()) / a + 0.5).to_byte()
    }
  }
}

///|
fn ref_map_rgb(d : FixedArray[Byte], table : FixedArray[Byte]) -> Unit {
  let n = d.length() / 4
  for i in 0..<n {
    for k in 0..<3 {
      d[i * 4 + k] = table[d[i * 4 + k].to_int()]
    }
  }
}

///|
fn ref_box_blur_line(radius : Int, src : FixedArray[Byte], dst : FixedArray[Byte], start : Int, step : Int, count : Int) -> Unit {
  let iarr : Float = 1.0 / fi(radius + radius + 1)
  let line_end = start + step * (count - 1)
  let mut ti = start
  let mut li = ti
  let mut ri = ti + radius * step
  let mut vr = 0
  let mut vg = 0
  let mut vb = 0
  let mut va = 0
  let px = fn(i : Int, k : Int) { src[i * 4 + k].to_int() }
  let lim = if radius < count { radius } else { count }
  for j in 0..<lim {
    let i = ti + j * step
    vr += px(i, 0)
    vg += px(i, 1)
    vb += px(i, 2)
    va += px(i, 3)
  }
  let n1 = if count < radius + 1 { count } else { radius + 1 }
  for _ in 0..<n1 {
    if ri <= line_end {
      vr += px(ri, 0)
      vg += px(ri, 1)
      vb += px(ri, 2)
      va += px(ri, 3)
    }
    ri += step
    dst[ti * 4] = f2u8(bround(fi(vr) * iarr)).to_byte()
    dst[ti * 4 + 1] = f2u8(bround(fi(vg) * iarr)).to_byte()
    dst[ti * 4 + 2] = f2u8(bround(fi(vb) * iarr)).to_byte()
    dst[ti * 4 + 3] = f2u8(bround(fi(va) * iarr)).to_byte()
    ti += step
  }
  if count <= radius {
    return
  }
  for _ in (radius + 1)..<(count - radius) {
    vr += px(ri, 0) - px(li, 0)
    vg += px(ri, 1) - px(li, 1)
    vb += px(ri, 2) - px(li, 2)
    va += px(ri, 3) - px(li, 3)
    ri += step
    li += step
    dst[ti * 4] = f2u8(bround(fi(vr) * iarr)).to_byte()
    dst[ti * 4 + 1] = f2u8(bround(fi(vg) * iarr)).to_byte()
    dst[ti * 4 + 2] = f2u8(bround(fi(vb) * iarr)).to_byte()
    dst[ti * 4 + 3] = f2u8(bround(fi(va) * iarr)).to_byte()
    ti += step
  }
  let n3 = if count - radius - 1 < radius { count - radius - 1 } else { radius }
  for _ in 0..<n3 {
    if li >= start {
      vr -= px(li, 0)
      vg -= px(li, 1)
      vb -= px(li, 2)
      va -= px(li, 3)
    }
    li += step
    dst[ti * 4] = f2u8(bround(fi(vr) * iarr)).to_byte()
    dst[ti * 4 + 1] = f2u8(bround(fi(vg) * iarr)).to_byte()
    dst[ti * 4 + 2] = f2u8(bround(fi(vb) * iarr)).to_byte()
    dst[ti * 4 + 3] = f2u8(bround(fi(va) * iarr)).to_byte()
    ti += step
  }
}

///|
fn assert_filter_bytes_eq(a : FixedArray[Byte], b : FixedArray[Byte]) -> Unit raise {
  assert_eq(a.length(), b.length())
  for i in 0..<a.length() {
    if a[i] != b[i] {
      assert_eq(a[i], b[i])
    }
  }
}

///|
test "filter multiply/demultiply and fused into_srgb/into_linear match 3-pass reference byte-for-byte" {
  // Cover all 256 alpha values plus edge cases (alpha == 0 with RGB > 0, RGB == 0, RGB > alpha, alpha == 255)
  let n = 512
  let init = FixedArray::make(n * 4, b'\x00')
  for i in 0..<n {
    let o = i * 4
    if i < 16 {
      init[o] = (i * 17).to_byte()
      init[o + 1] = (i * 31 % 256).to_byte()
      init[o + 2] = (if i == 0 { 0 } else { 255 }).to_byte()
      init[o + 3] = b'\x00'
    } else {
      let a = (i - 16) % 256
      init[o] = ((i * 53) % 256).to_byte()
      init[o + 1] = ((i * 97) % 256).to_byte()
      init[o + 2] = ((i * 131) % 256).to_byte()
      init[o + 3] = a.to_byte()
    }
  }
  let a1 = init.copy()
  let b1 = init.copy()
  multiply_alpha(a1)
  ref_multiply_alpha(b1)
  assert_filter_bytes_eq(a1, b1)

  let a2 = init.copy()
  let b2 = init.copy()
  demultiply_alpha(a2)
  ref_demultiply_alpha(b2)
  assert_filter_bytes_eq(a2, b2)

  let a3 = init.copy()
  let b3 = init.copy()
  into_srgb(a3)
  ref_demultiply_alpha(b3)
  ref_map_rgb(b3, linear_to_srgb)
  ref_multiply_alpha(b3)
  assert_filter_bytes_eq(a3, b3)

  let a4 = init.copy()
  let b4 = init.copy()
  into_linear(a4)
  ref_demultiply_alpha(b4)
  ref_map_rgb(b4, srgb_to_linear)
  ref_multiply_alpha(b4)
  assert_filter_bytes_eq(a4, b4)
}

///|
test "filter row-major box_blur_vert and closure-free box_blur_horz match box_blur_line across all boundary sizes" {
  for radius in [0, 1, 2, 4] {
    let heights = [1, radius, radius + 1, 2 * radius, 2 * radius + 1, 2 * radius + 2]
    for w in [1, 3, 7] {
      for h in heights {
        if h <= 0 {
          continue
        }
        let len = w * h * 4
        let src = FixedArray::make(len, b'\x00')
        for i in 0..<len {
          src[i] = ((i * 37 + 19) % 256).to_byte()
        }
        let dst_v_fast = FixedArray::make(len, b'\x00')
        let dst_v_ref = FixedArray::make(len, b'\x00')
        box_blur_vert(radius, src, dst_v_fast, w, h)
        if radius == 0 {
          for i in 0..<len {
            dst_v_ref[i] = src[i]
          }
        } else {
          for col in 0..<w {
            ref_box_blur_line(radius, src, dst_v_ref, col, w, h)
          }
        }
        assert_filter_bytes_eq(dst_v_fast, dst_v_ref)

        let dst_h_fast = FixedArray::make(len, b'\x00')
        let dst_h_ref = FixedArray::make(len, b'\x00')
        box_blur_horz(radius, src, dst_h_fast, w, h)
        if radius == 0 {
          for i in 0..<len {
            dst_h_ref[i] = src[i]
          }
        } else {
          for row in 0..<h {
            ref_box_blur_line(radius, src, dst_h_ref, row * w, 1, w)
          }
        }
        assert_filter_bytes_eq(dst_h_fast, dst_h_ref)
      }
    }
  }
}
