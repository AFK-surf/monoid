// tiny-skia's high precision pipeline: 8 pixels at a time in floats, lane by lane as the
// SIMD types compute them (src/wide: SSE's min, max and conversions; reciprocals exact).
// Optimized with per-blitter reusable scratch buffers (`HighPScratch`, zero global mutable state,
// thread-safe and reentrant across concurrent draws), inlined blend stages (zero closures),
// allocation-free bilinear/bicubic sampling, and direct scanline fast paths for integer-translate
// nearest-neighbor pixmap blits (`Gather`).
// Invariant: lanes `>= p.tail` are never stored to `dst` and no stage reads across lanes except
// `MaskU8`, which zeros `>= p.tail`.

///|
priv struct HighPScratch {
  r : FixedArray[Float]
  g : FixedArray[Float]
  b : FixedArray[Float]
  a : FixedArray[Float]
  dr : FixedArray[Float]
  dg : FixedArray[Float]
  db : FixedArray[Float]
  da : FixedArray[Float]
  mask_c : FixedArray[Float]
  cx : FixedArray[Float]
  cy : FixedArray[Float]
  xs : FixedArray[Float]
  ys : FixedArray[Float]
  wx : FixedArray[Float]
  wy : FixedArray[Float]
}

///|
fn HighPScratch::new() -> HighPScratch {
  {
    r: FixedArray::make(8, 0.0),
    g: FixedArray::make(8, 0.0),
    b: FixedArray::make(8, 0.0),
    a: FixedArray::make(8, 0.0),
    dr: FixedArray::make(8, 0.0),
    dg: FixedArray::make(8, 0.0),
    db: FixedArray::make(8, 0.0),
    da: FixedArray::make(8, 0.0),
    mask_c: FixedArray::make(8, 0.0),
    cx: FixedArray::make(8, 0.0),
    cy: FixedArray::make(8, 0.0),
    xs: FixedArray::make(8, 0.0),
    ys: FixedArray::make(8, 0.0),
    wx: FixedArray::make(32, 0.0),
    wy: FixedArray::make(32, 0.0),
  }
}

///|
/// _mm_max_ps: a where a > b, else b.
fn smax(a : Float, b : Float) -> Float {
  if a > b {
    a
  } else {
    b
  }
}

///|
/// _mm_min_ps: a where a < b, else b.
fn smin(a : Float, b : Float) -> Float {
  if a < b {
    a
  } else {
    b
  }
}

///|
/// cvttps: towards zero; NaN and what is out of range i32::MIN.
fn trunc_int(x : Float) -> Int {
  if x.is_nan() || x >= 2147483648.0 || x < -2147483648.0 {
    -2147483648
  } else {
    x.to_double().to_int()
  }
}

///|
/// cvtps: to the nearest, ties to even; NaN and what is out of range i32::MIN.
fn round_int(x : Float) -> Int {
  if x.is_nan() || x >= 2147483648.0 || x < -2147483648.0 {
    return -2147483648
  }
  let r = round_even(x)
  r.to_double().to_int()
}

///|
fn round_even(x : Float) -> Float {
  let t = x.trunc()
  let d = x - t
  if d.abs() == 0.5 {
    // to the even one of t and t ± 1
    let ti = t.to_double().to_int()
    if (ti & 1) == 0 {
      t
    } else if x > 0.0 {
      t + 1.0
    } else {
      t - 1.0
    }
  } else if d.abs() > 0.5 {
    if x > 0.0 {
      t + 1.0
    } else {
      t - 1.0
    }
  } else {
    t
  }
}

///|
/// f32x8::floor: the truncation, less 1 where it is above.
fn lfloor(x : Float) -> Float {
  let rt = fi(trunc_int(x))
  if rt > x {
    rt - 1.0
  } else {
    rt
  }
}

///|
fn lnormalize(x : Float) -> Float {
  smin(smax(x, 0.0), 1.0)
}

///|
priv struct HighP {
  r : FixedArray[Float]
  g : FixedArray[Float]
  b : FixedArray[Float]
  a : FixedArray[Float]
  dr : FixedArray[Float]
  dg : FixedArray[Float]
  db : FixedArray[Float]
  da : FixedArray[Float]
  mask_c : FixedArray[Float]
  cx : FixedArray[Float]
  cy : FixedArray[Float]
  xs : FixedArray[Float]
  ys : FixedArray[Float]
  wx : FixedArray[Float]
  wy : FixedArray[Float]
  mut tail : Int
  mut dx : Int
  mut dy : Int
  ctx : Context
  mask_ctx : MaskCtx
  aa_mask_ctx : AAMaskCtx
  src : Pixmap
  dst : SubPixmap
}

///|
fn highp_start_generic(
  stages : Array[Stage],
  rect : ScreenIntRect,
  aa_mask_ctx : AAMaskCtx,
  mask_ctx : MaskCtx,
  ctx : Context,
  src : Pixmap,
  dst : SubPixmap,
  scratch : HighPScratch,
) -> Unit {
  let p : HighP = {
    r: scratch.r,
    g: scratch.g,
    b: scratch.b,
    a: scratch.a,
    dr: scratch.dr,
    dg: scratch.dg,
    db: scratch.db,
    da: scratch.da,
    mask_c: scratch.mask_c,
    cx: scratch.cx,
    cy: scratch.cy,
    xs: scratch.xs,
    ys: scratch.ys,
    wx: scratch.wx,
    wy: scratch.wy,
    tail: 0,
    dx: 0,
    dy: 0,
    ctx,
    mask_ctx,
    aa_mask_ctx,
    src,
    dst,
  }
  for y in rect.y..<rect.bottom() {
    let mut x = rect.x
    let end = rect.right()
    while x + 8 <= end {
      p.dx = x
      p.dy = y
      p.tail = 8
      p.run(stages)
      x += 8
    }
    if x != end {
      p.dx = x
      p.dy = y
      p.tail = end - x
      p.run(stages)
    }
  }
}

///|
fn highp_fill_const_run(
  sdata : FixedArray[Byte],
  so : Int,
  ddata : FixedArray[Byte],
  do_start : Int,
  count : Int,
  has_scale : Bool,
  cov : Float,
  cov_finite_unit : Bool,
  mode : Int,
) -> Unit {
  let inv255 : Float = 1.0 / 255.0
  let s0 = sdata[so].to_int()
  let s1 = sdata[so + 1].to_int()
  let s2 = sdata[so + 2].to_int()
  let s3 = sdata[so + 3].to_int()
  let mut do_ = do_start
  let do_end = do_ + count * 4
  if !has_scale {
    if mode == 0 || s3 == 255 {
      let b0 = sdata[so]
      let b1 = sdata[so + 1]
      let b2 = sdata[so + 2]
      let b3 = sdata[so + 3]
      while do_ < do_end {
        ddata[do_] = b0
        ddata[do_ + 1] = b1
        ddata[do_ + 2] = b2
        ddata[do_ + 3] = b3
        do_ += 4
      }
    } else if s3 != 0 || s0 != 0 || s1 != 0 || s2 != 0 {
      let sr = fi(s0) * inv255
      let sg = fi(s1) * inv255
      let sb = fi(s2) * inv255
      let sa = fi(s3) * inv255
      let ia : Float = 1.0 - sa
      while do_ < do_end {
        ddata[do_] = unnorm(fi(ddata[do_].to_int()) * inv255 * ia + sr).to_byte()
        ddata[do_ + 1] = unnorm(fi(ddata[do_ + 1].to_int()) * inv255 * ia + sg).to_byte()
        ddata[do_ + 2] = unnorm(fi(ddata[do_ + 2].to_int()) * inv255 * ia + sb).to_byte()
        ddata[do_ + 3] = unnorm(fi(ddata[do_ + 3].to_int()) * inv255 * ia + sa).to_byte()
        do_ += 4
      }
    }
  } else {
    let sr = (fi(s0) * inv255) * cov
    let sg = (fi(s1) * inv255) * cov
    let sb = (fi(s2) * inv255) * cov
    let sa = (fi(s3) * inv255) * cov
    if mode == 0 {
      let b0 = unnorm(sr).to_byte()
      let b1 = unnorm(sg).to_byte()
      let b2 = unnorm(sb).to_byte()
      let b3 = unnorm(sa).to_byte()
      while do_ < do_end {
        ddata[do_] = b0
        ddata[do_ + 1] = b1
        ddata[do_ + 2] = b2
        ddata[do_ + 3] = b3
        do_ += 4
      }
    } else if !(cov_finite_unit && s3 == 0 && s0 == 0 && s1 == 0 && s2 == 0) {
      let ia : Float = 1.0 - sa
      while do_ < do_end {
        ddata[do_] = unnorm(fi(ddata[do_].to_int()) * inv255 * ia + sr).to_byte()
        ddata[do_ + 1] = unnorm(fi(ddata[do_ + 1].to_int()) * inv255 * ia + sg).to_byte()
        ddata[do_ + 2] = unnorm(fi(ddata[do_ + 2].to_int()) * inv255 * ia + sb).to_byte()
        ddata[do_ + 3] = unnorm(fi(ddata[do_ + 3].to_int()) * inv255 * ia + sa).to_byte()
        do_ += 4
      }
    }
  }
}

///|
/// Direct scanline blit for `SeedShader -> [int-translate StTransform] -> Gather -> [Scale1Float] -> (Store | SourceOverRgba)`.
/// `mode == 0` is `Store`; `mode == 1` is `SourceOverRgba`.
/// Caller must ensure `!physical_equal(src.data, dst.data)` and `src.width/height > 0`.
fn highp_blit_gather_translate(
  src : Pixmap,
  dst : SubPixmap,
  rect : ScreenIntRect,
  itx : Int,
  ity : Int,
  has_scale : Bool,
  cov : Float,
  mode : Int,
) -> Unit {
  let sdata = src.data
  let ddata = dst.data
  let sw = src.width
  let sh = src.height
  let rx = rect.x
  let rw = rect.width
  let rend = rx + rw
  let ry = rect.y
  let rbot = rect.bottom()
  let inv255 : Float = 1.0 / 255.0
  let cov_finite_unit = cov >= 0.0 && cov <= 1.0
  let x_in_lo = if rx > -itx { rx } else { -itx }
  let x_in_hi = if rend < sw - itx { rend } else { sw - itx }
  let mut y = ry
  while y < rbot {
    let sy_raw = y + ity
    let sy = if sy_raw < 0 { 0 } else if sy_raw >= sh { sh - 1 } else { sy_raw }
    let src_row = sy * sw
    // Left clamped prefix (sx == 0)
    let left_end = if x_in_lo < rend { x_in_lo } else { rend }
    if rx < left_end {
      highp_fill_const_run(
        sdata,
        src_row * 4,
        ddata,
        dst.offset_at(rx, y) * 4,
        left_end - rx,
        has_scale,
        cov,
        cov_finite_unit,
        mode,
      )
    }
    // Unclamped interior (sx == x + itx)
    if x_in_lo < x_in_hi {
      let count = x_in_hi - x_in_lo
      let mut so = (src_row + x_in_lo + itx) * 4
      let mut do_ = dst.offset_at(x_in_lo, y) * 4
      let do_end = do_ + count * 4
      if !has_scale {
        if mode == 0 {
          sdata.blit_to(ddata, len=count * 4, src_offset=so, dst_offset=do_)
        } else {
          while do_ < do_end {
            let b3 = sdata[so + 3]
            if b3 == b'\xFF' {
              ddata[do_] = sdata[so]
              ddata[do_ + 1] = sdata[so + 1]
              ddata[do_ + 2] = sdata[so + 2]
              ddata[do_ + 3] = b'\xFF'
            } else {
              let b0 = sdata[so]
              let b1 = sdata[so + 1]
              let b2 = sdata[so + 2]
              if b3 != b'\x00' || b0 != b'\x00' || b1 != b'\x00' || b2 != b'\x00' {
                if ddata[do_ + 3] == b'\x00' &&
                  ddata[do_] == b'\x00' &&
                  ddata[do_ + 1] == b'\x00' &&
                  ddata[do_ + 2] == b'\x00' {
                  ddata[do_] = b0
                  ddata[do_ + 1] = b1
                  ddata[do_ + 2] = b2
                  ddata[do_ + 3] = b3
                } else {
                  let sr = fi(b0.to_int()) * inv255
                  let sg = fi(b1.to_int()) * inv255
                  let sb = fi(b2.to_int()) * inv255
                  let sa = fi(b3.to_int()) * inv255
                  let ia : Float = 1.0 - sa
                  ddata[do_] = unnorm(fi(ddata[do_].to_int()) * inv255 * ia + sr).to_byte()
                  ddata[do_ + 1] = unnorm(fi(ddata[do_ + 1].to_int()) * inv255 * ia + sg).to_byte()
                  ddata[do_ + 2] = unnorm(fi(ddata[do_ + 2].to_int()) * inv255 * ia + sb).to_byte()
                  ddata[do_ + 3] = unnorm(fi(ddata[do_ + 3].to_int()) * inv255 * ia + sa).to_byte()
                }
              }
            }
            so += 4
            do_ += 4
          }
        }
      } else if mode == 0 {
        while do_ < do_end {
          let b0 = sdata[so]
          let b1 = sdata[so + 1]
          let b2 = sdata[so + 2]
          let b3 = sdata[so + 3]
          if cov_finite_unit && b3 == b'\x00' && b0 == b'\x00' && b1 == b'\x00' && b2 == b'\x00' {
            ddata[do_] = b'\x00'
            ddata[do_ + 1] = b'\x00'
            ddata[do_ + 2] = b'\x00'
            ddata[do_ + 3] = b'\x00'
          } else {
            ddata[do_] = unnorm((fi(b0.to_int()) * inv255) * cov).to_byte()
            ddata[do_ + 1] = unnorm((fi(b1.to_int()) * inv255) * cov).to_byte()
            ddata[do_ + 2] = unnorm((fi(b2.to_int()) * inv255) * cov).to_byte()
            ddata[do_ + 3] = unnorm((fi(b3.to_int()) * inv255) * cov).to_byte()
          }
          so += 4
          do_ += 4
        }
      } else {
        while do_ < do_end {
          let b0 = sdata[so]
          let b1 = sdata[so + 1]
          let b2 = sdata[so + 2]
          let b3 = sdata[so + 3]
          if !(cov_finite_unit && b3 == b'\x00' && b0 == b'\x00' && b1 == b'\x00' && b2 == b'\x00') {
            let sr = (fi(b0.to_int()) * inv255) * cov
            let sg = (fi(b1.to_int()) * inv255) * cov
            let sb = (fi(b2.to_int()) * inv255) * cov
            let sa = (fi(b3.to_int()) * inv255) * cov
            let ia : Float = 1.0 - sa
            ddata[do_] = unnorm(fi(ddata[do_].to_int()) * inv255 * ia + sr).to_byte()
            ddata[do_ + 1] = unnorm(fi(ddata[do_ + 1].to_int()) * inv255 * ia + sg).to_byte()
            ddata[do_ + 2] = unnorm(fi(ddata[do_ + 2].to_int()) * inv255 * ia + sb).to_byte()
            ddata[do_ + 3] = unnorm(fi(ddata[do_ + 3].to_int()) * inv255 * ia + sa).to_byte()
          }
          so += 4
          do_ += 4
        }
      }
    }
    // Right clamped suffix (sx == sw - 1)
    let right_start = if x_in_hi > rx { x_in_hi } else { rx }
    if right_start < rend {
      highp_fill_const_run(
        sdata,
        (src_row + sw - 1) * 4,
        ddata,
        dst.offset_at(right_start, y) * 4,
        rend - right_start,
        has_scale,
        cov,
        cov_finite_unit,
        mode,
      )
    }
    y += 1
  }
}

///|
fn highp_try_gather_translate(
  stages : Array[Stage],
  rect : ScreenIntRect,
  ctx : Context,
  src : Pixmap,
  dst : SubPixmap,
) -> Bool {
  let slen = stages.length()
  if slen < 3 || slen > 5 {
    return false
  }
  guard stages[0] is SeedShader else { return false }
  if physical_equal(src.data, dst.data) ||
    src.width <= 0 ||
    src.height <= 0 ||
    src.width > 4194304 ||
    src.height > 4194304 ||
    rect.right() >= 4194304 ||
    rect.bottom() >= 4194304 {
    return false
  }
  let mut idx = 1
  let mut itx = 0
  let mut ity = 0
  if stages[idx] is StTransform {
    let ts = ctx.transform
    if !ts.is_translate() ||
      ts.tx != ts.tx.trunc() ||
      ts.ty != ts.ty.trunc() ||
      ts.tx.abs() >= 4194304.0 ||
      ts.ty.abs() >= 4194304.0 {
      return false
    }
    itx = ts.tx.to_int()
    ity = ts.ty.to_int()
    idx += 1
  }
  if idx >= slen || !(stages[idx] is Gather) {
    return false
  }
  idx += 1
  let mut has_scale = false
  if idx < slen && stages[idx] is Scale1Float {
    has_scale = true
    idx += 1
  }
  if idx + 1 != slen {
    return false
  }
  let mode = match stages[idx] {
    Store => 0
    SourceOverRgba => 1
    _ => return false
  }
  highp_blit_gather_translate(src, dst, rect, itx, ity, has_scale, ctx.current_coverage, mode)
  true
}

///|
fn highp_start(
  stages : Array[Stage],
  rect : ScreenIntRect,
  aa_mask_ctx : AAMaskCtx,
  mask_ctx : MaskCtx,
  ctx : Context,
  src : Pixmap,
  dst : SubPixmap,
  scratch : PipelineScratch,
) -> Unit {
  if highp_try_gather_translate(stages, rect, ctx, src, dst) {
    return
  }
  highp_start_generic(stages, rect, aa_mask_ctx, mask_ctx, ctx, src, dst, scratch.highp())
}

///|
fn HighP::run(self : HighP, stages : Array[Stage]) -> Unit {
  for s in stages {
    if !self.stage(s) {
      return
    }
  }
}

///|
fn HighP::stage(self : HighP, s : Stage) -> Bool {
  let p = self
  match s {
    MoveDestinationToSource =>
      for i in 0..<8 {
        p.r[i] = p.dr[i]
        p.g[i] = p.dg[i]
        p.b[i] = p.db[i]
        p.a[i] = p.da[i]
      }
    Clamp0 =>
      for i in 0..<8 {
        p.r[i] = smax(p.r[i], 0.0)
        p.g[i] = smax(p.g[i], 0.0)
        p.b[i] = smax(p.b[i], 0.0)
        p.a[i] = smax(p.a[i], 0.0)
      }
    ClampA =>
      for i in 0..<8 {
        p.r[i] = smin(p.r[i], 1.0)
        p.g[i] = smin(p.g[i], 1.0)
        p.b[i] = smin(p.b[i], 1.0)
        p.a[i] = smin(p.a[i], 1.0)
      }
    Premultiply =>
      for i in 0..<8 {
        p.r[i] = p.r[i] * p.a[i]
        p.g[i] = p.g[i] * p.a[i]
        p.b[i] = p.b[i] * p.a[i]
      }
    UniformColor => {
      let (r, g, b, a) = p.ctx.uniform
      for i in 0..<8 {
        p.r[i] = r
        p.g[i] = g
        p.b[i] = b
        p.a[i] = a
      }
    }
    SeedShader =>
      for i in 0..<8 {
        p.r[i] = fi(p.dx) + (fi(i) + 0.5)
        p.g[i] = fi(p.dy) + 0.5
        p.b[i] = 1.0
        p.a[i] = 0.0
        p.dr[i] = 0.0
        p.dg[i] = 0.0
        p.db[i] = 0.0
        p.da[i] = 0.0
      }
    LoadDestination => p.load_dst()
    Store => p.store()
    LoadDestinationU8 | StoreU8 => return false
    Gather => {
      let pix = p.src
      let pw = pix.width
      let w = ulp_sub(fi(pw))
      let h = ulp_sub(fi(pix.height))
      let d = pix.data
      let inv255 : Float = 1.0 / 255.0
      for i in 0..<p.tail {
        let x = smin(smax(p.r[i], 0.0), w)
        let y = smin(smax(p.g[i], 0.0), h)
        let o = (trunc_int(y) * pw + trunc_int(x)) * 4
        p.r[i] = fi(d[o].to_int()) * inv255
        p.g[i] = fi(d[o + 1].to_int()) * inv255
        p.b[i] = fi(d[o + 2].to_int()) * inv255
        p.a[i] = fi(d[o + 3].to_int()) * inv255
      }
    }
    MaskU8 => {
      let offset = p.mask_ctx.at(p.dx, p.dy)
      let mut all_zero = true
      for i in 0..<8 {
        let v : Float = if i < p.tail { fi(p.mask_ctx.data[offset + i].to_int()) / 255.0 } else { 0.0 }
        p.mask_c[i] = v
        if v != 0.0 {
          all_zero = false
        }
      }
      if all_zero {
        return false
      }
      for i in 0..<8 {
        let ci = p.mask_c[i]
        p.r[i] = p.r[i] * ci
        p.g[i] = p.g[i] * ci
        p.b[i] = p.b[i] * ci
        p.a[i] = p.a[i] * ci
      }
    }
    ScaleU8 => {
      let (d0, d1) = p.aa_mask_ctx.copy_at_xy(p.dx, p.dy, p.tail)
      for i in 0..<8 {
        let c : Float = if i == 0 { fi(d0) / 255.0 } else if i == 1 { fi(d1) / 255.0 } else { 0.0 }
        p.r[i] = p.r[i] * c
        p.g[i] = p.g[i] * c
        p.b[i] = p.b[i] * c
        p.a[i] = p.a[i] * c
      }
    }
    LerpU8 => {
      let (d0, d1) = p.aa_mask_ctx.copy_at_xy(p.dx, p.dy, p.tail)
      for i in 0..<8 {
        let c : Float = if i == 0 { fi(d0) / 255.0 } else if i == 1 { fi(d1) / 255.0 } else { 0.0 }
        p.r[i] = hlerp(p.dr[i], p.r[i], c)
        p.g[i] = hlerp(p.dg[i], p.g[i], c)
        p.b[i] = hlerp(p.db[i], p.b[i], c)
        p.a[i] = hlerp(p.da[i], p.a[i], c)
      }
    }
    Scale1Float => {
      let c = p.ctx.current_coverage
      for i in 0..<8 {
        p.r[i] = p.r[i] * c
        p.g[i] = p.g[i] * c
        p.b[i] = p.b[i] * c
        p.a[i] = p.a[i] * c
      }
    }
    Lerp1Float => {
      let c = p.ctx.current_coverage
      for i in 0..<8 {
        p.r[i] = hlerp(p.dr[i], p.r[i], c)
        p.g[i] = hlerp(p.dg[i], p.g[i], c)
        p.b[i] = hlerp(p.db[i], p.b[i], c)
        p.a[i] = hlerp(p.da[i], p.a[i], c)
      }
    }
    StClear =>
      for i in 0..<8 {
        p.r[i] = 0.0
        p.g[i] = 0.0
        p.b[i] = 0.0
        p.a[i] = 0.0
      }
    StSourceAtop =>
      for i in 0..<8 {
        let sa = p.a[i]
        let da = p.da[i]
        let isa : Float = 1.0 - sa
        p.r[i] = p.r[i] * da + p.dr[i] * isa
        p.g[i] = p.g[i] * da + p.dg[i] * isa
        p.b[i] = p.b[i] * da + p.db[i] * isa
        p.a[i] = sa * da + da * isa
      }
    StDestinationAtop =>
      for i in 0..<8 {
        let sa = p.a[i]
        let da = p.da[i]
        let ida : Float = 1.0 - da
        p.r[i] = p.dr[i] * sa + p.r[i] * ida
        p.g[i] = p.dg[i] * sa + p.g[i] * ida
        p.b[i] = p.db[i] * sa + p.b[i] * ida
        p.a[i] = da * sa + sa * ida
      }
    StSourceIn =>
      for i in 0..<8 {
        let da = p.da[i]
        p.r[i] = p.r[i] * da
        p.g[i] = p.g[i] * da
        p.b[i] = p.b[i] * da
        p.a[i] = p.a[i] * da
      }
    StDestinationIn =>
      for i in 0..<8 {
        let sa = p.a[i]
        p.r[i] = p.dr[i] * sa
        p.g[i] = p.dg[i] * sa
        p.b[i] = p.db[i] * sa
        p.a[i] = p.da[i] * sa
      }
    StSourceOut =>
      for i in 0..<8 {
        let ida : Float = 1.0 - p.da[i]
        p.r[i] = p.r[i] * ida
        p.g[i] = p.g[i] * ida
        p.b[i] = p.b[i] * ida
        p.a[i] = p.a[i] * ida
      }
    StDestinationOut =>
      for i in 0..<8 {
        let isa : Float = 1.0 - p.a[i]
        p.r[i] = p.dr[i] * isa
        p.g[i] = p.dg[i] * isa
        p.b[i] = p.db[i] * isa
        p.a[i] = p.da[i] * isa
      }
    StSourceOver =>
      for i in 0..<8 {
        let sa = p.a[i]
        let isa : Float = 1.0 - sa
        p.r[i] = p.dr[i] * isa + p.r[i]
        p.g[i] = p.dg[i] * isa + p.g[i]
        p.b[i] = p.db[i] * isa + p.b[i]
        p.a[i] = p.da[i] * isa + sa
      }
    StDestinationOver =>
      for i in 0..<8 {
        let da = p.da[i]
        let ida : Float = 1.0 - da
        p.r[i] = p.r[i] * ida + p.dr[i]
        p.g[i] = p.g[i] * ida + p.dg[i]
        p.b[i] = p.b[i] * ida + p.db[i]
        p.a[i] = p.a[i] * ida + da
      }
    StModulate =>
      for i in 0..<8 {
        p.r[i] = p.r[i] * p.dr[i]
        p.g[i] = p.g[i] * p.dg[i]
        p.b[i] = p.b[i] * p.db[i]
        p.a[i] = p.a[i] * p.da[i]
      }
    StMultiply =>
      for i in 0..<8 {
        let sa = p.a[i]
        let da = p.da[i]
        let isa : Float = 1.0 - sa
        let ida : Float = 1.0 - da
        p.r[i] = p.r[i] * ida + p.dr[i] * isa + p.r[i] * p.dr[i]
        p.g[i] = p.g[i] * ida + p.dg[i] * isa + p.g[i] * p.dg[i]
        p.b[i] = p.b[i] * ida + p.db[i] * isa + p.b[i] * p.db[i]
        p.a[i] = sa * ida + da * isa + sa * da
      }
    StScreen =>
      for i in 0..<8 {
        p.r[i] = p.r[i] + p.dr[i] - p.r[i] * p.dr[i]
        p.g[i] = p.g[i] + p.dg[i] - p.g[i] * p.dg[i]
        p.b[i] = p.b[i] + p.db[i] - p.b[i] * p.db[i]
        p.a[i] = p.a[i] + p.da[i] - p.a[i] * p.da[i]
      }
    StXor =>
      for i in 0..<8 {
        let sa = p.a[i]
        let da = p.da[i]
        let isa : Float = 1.0 - sa
        let ida : Float = 1.0 - da
        p.r[i] = p.r[i] * ida + p.dr[i] * isa
        p.g[i] = p.g[i] * ida + p.dg[i] * isa
        p.b[i] = p.b[i] * ida + p.db[i] * isa
        p.a[i] = sa * ida + da * isa
      }
    StPlus =>
      for i in 0..<8 {
        p.r[i] = smin(p.r[i] + p.dr[i], 1.0)
        p.g[i] = smin(p.g[i] + p.dg[i], 1.0)
        p.b[i] = smin(p.b[i] + p.db[i], 1.0)
        p.a[i] = smin(p.a[i] + p.da[i], 1.0)
      }
    StDarken =>
      for i in 0..<8 {
        let sa = p.a[i]
        let da = p.da[i]
        p.r[i] = p.r[i] + p.dr[i] - smax(p.r[i] * da, p.dr[i] * sa)
        p.g[i] = p.g[i] + p.dg[i] - smax(p.g[i] * da, p.dg[i] * sa)
        p.b[i] = p.b[i] + p.db[i] - smax(p.b[i] * da, p.db[i] * sa)
        p.a[i] = da * (1.0 - sa) + sa
      }
    StLighten =>
      for i in 0..<8 {
        let sa = p.a[i]
        let da = p.da[i]
        p.r[i] = p.r[i] + p.dr[i] - smin(p.r[i] * da, p.dr[i] * sa)
        p.g[i] = p.g[i] + p.dg[i] - smin(p.g[i] * da, p.dg[i] * sa)
        p.b[i] = p.b[i] + p.db[i] - smin(p.b[i] * da, p.db[i] * sa)
        p.a[i] = da * (1.0 - sa) + sa
      }
    StDifference =>
      for i in 0..<8 {
        let sa = p.a[i]
        let da = p.da[i]
        let mr = smin(p.r[i] * da, p.dr[i] * sa)
        p.r[i] = p.r[i] + p.dr[i] - (mr + mr)
        let mg = smin(p.g[i] * da, p.dg[i] * sa)
        p.g[i] = p.g[i] + p.dg[i] - (mg + mg)
        let mb = smin(p.b[i] * da, p.db[i] * sa)
        p.b[i] = p.b[i] + p.db[i] - (mb + mb)
        p.a[i] = da * (1.0 - sa) + sa
      }
    StExclusion =>
      for i in 0..<8 {
        let sa = p.a[i]
        let da = p.da[i]
        let mr = p.r[i] * p.dr[i]
        p.r[i] = p.r[i] + p.dr[i] - (mr + mr)
        let mg = p.g[i] * p.dg[i]
        p.g[i] = p.g[i] + p.dg[i] - (mg + mg)
        let mb = p.b[i] * p.db[i]
        p.b[i] = p.b[i] + p.db[i] - (mb + mb)
        p.a[i] = da * (1.0 - sa) + sa
      }
    StColorBurn =>
      for i in 0..<8 {
        let sa = p.a[i]
        let da = p.da[i]
        let isa : Float = 1.0 - sa
        let ida : Float = 1.0 - da
        let sr = p.r[i]
        let dr = p.dr[i]
        p.r[i] = if dr == da {
          dr + sr * ida
        } else if sr == 0.0 {
          dr * isa
        } else {
          sa * (da - smin(da, (da - dr) * sa * (1.0 / sr))) + sr * ida + dr * isa
        }
        let sg = p.g[i]
        let dg = p.dg[i]
        p.g[i] = if dg == da {
          dg + sg * ida
        } else if sg == 0.0 {
          dg * isa
        } else {
          sa * (da - smin(da, (da - dg) * sa * (1.0 / sg))) + sg * ida + dg * isa
        }
        let sb = p.b[i]
        let db = p.db[i]
        p.b[i] = if db == da {
          db + sb * ida
        } else if sb == 0.0 {
          db * isa
        } else {
          sa * (da - smin(da, (da - db) * sa * (1.0 / sb))) + sb * ida + db * isa
        }
        p.a[i] = da * isa + sa
      }
    StColorDodge =>
      for i in 0..<8 {
        let sa = p.a[i]
        let da = p.da[i]
        let isa : Float = 1.0 - sa
        let ida : Float = 1.0 - da
        let sr = p.r[i]
        let dr = p.dr[i]
        p.r[i] = if dr == 0.0 {
          sr * ida
        } else if sr == sa {
          sr + dr * isa
        } else {
          sa * smin(da, dr * sa * (1.0 / (sa - sr))) + sr * ida + dr * isa
        }
        let sg = p.g[i]
        let dg = p.dg[i]
        p.g[i] = if dg == 0.0 {
          sg * ida
        } else if sg == sa {
          sg + dg * isa
        } else {
          sa * smin(da, dg * sa * (1.0 / (sa - sg))) + sg * ida + dg * isa
        }
        let sb = p.b[i]
        let db = p.db[i]
        p.b[i] = if db == 0.0 {
          sb * ida
        } else if sb == sa {
          sb + db * isa
        } else {
          sa * smin(da, db * sa * (1.0 / (sa - sb))) + sb * ida + db * isa
        }
        p.a[i] = da * isa + sa
      }
    StHardLight =>
      for i in 0..<8 {
        let sa = p.a[i]
        let da = p.da[i]
        let isa : Float = 1.0 - sa
        let ida : Float = 1.0 - da
        let sr = p.r[i]
        let dr = p.dr[i]
        p.r[i] = sr * ida +
          dr * isa +
          (if sr + sr <= sa {
            let m = sr * dr
            m + m
          } else {
            let m = (da - dr) * (sa - sr)
            sa * da - (m + m)
          })
        let sg = p.g[i]
        let dg = p.dg[i]
        p.g[i] = sg * ida +
          dg * isa +
          (if sg + sg <= sa {
            let m = sg * dg
            m + m
          } else {
            let m = (da - dg) * (sa - sg)
            sa * da - (m + m)
          })
        let sb = p.b[i]
        let db = p.db[i]
        p.b[i] = sb * ida +
          db * isa +
          (if sb + sb <= sa {
            let m = sb * db
            m + m
          } else {
            let m = (da - db) * (sa - sb)
            sa * da - (m + m)
          })
        p.a[i] = da * isa + sa
      }
    StOverlay =>
      for i in 0..<8 {
        let sa = p.a[i]
        let da = p.da[i]
        let isa : Float = 1.0 - sa
        let ida : Float = 1.0 - da
        let sr = p.r[i]
        let dr = p.dr[i]
        p.r[i] = sr * ida +
          dr * isa +
          (if dr + dr <= da {
            let m = sr * dr
            m + m
          } else {
            let m = (da - dr) * (sa - sr)
            sa * da - (m + m)
          })
        let sg = p.g[i]
        let dg = p.dg[i]
        p.g[i] = sg * ida +
          dg * isa +
          (if dg + dg <= da {
            let m = sg * dg
            m + m
          } else {
            let m = (da - dg) * (sa - sg)
            sa * da - (m + m)
          })
        let sb = p.b[i]
        let db = p.db[i]
        p.b[i] = sb * ida +
          db * isa +
          (if db + db <= da {
            let m = sb * db
            m + m
          } else {
            let m = (da - db) * (sa - sb)
            sa * da - (m + m)
          })
        p.a[i] = da * isa + sa
      }
    StSoftLight =>
      for i in 0..<8 {
        let sa = p.a[i]
        let da = p.da[i]
        let isa : Float = 1.0 - sa
        let ida : Float = 1.0 - da
        p.r[i] = highp_soft_light_ch(p.r[i], p.dr[i], sa, da, isa, ida)
        p.g[i] = highp_soft_light_ch(p.g[i], p.dg[i], sa, da, isa, ida)
        p.b[i] = highp_soft_light_ch(p.b[i], p.db[i], sa, da, isa, ida)
        p.a[i] = da * isa + sa
      }
    StHue => p.blend3(0)
    StSaturation => p.blend3(1)
    StColor => p.blend3(2)
    StLuminosity => p.blend3(3)
    SourceOverRgba => {
      p.load_dst()
      for i in 0..<8 {
        let ia : Float = 1.0 - p.a[i]
        p.r[i] = p.dr[i] * ia + p.r[i]
        p.g[i] = p.dg[i] * ia + p.g[i]
        p.b[i] = p.db[i] * ia + p.b[i]
        p.a[i] = p.da[i] * ia + p.a[i]
      }
      p.store()
    }
    StTransform => {
      let ts = p.ctx.transform
      for i in 0..<8 {
        let x = p.r[i]
        let y = p.g[i]
        p.r[i] = x * ts.sx + (y * ts.kx + ts.tx)
        p.g[i] = x * ts.ky + (y * ts.sy + ts.ty)
      }
    }
    StReflect => {
      let (sx, ix) = p.ctx.limit_x
      let (sy, iy) = p.ctx.limit_y
      for i in 0..<8 {
        p.r[i] = exclusive_reflect(p.r[i], sx, ix)
        p.g[i] = exclusive_reflect(p.g[i], sy, iy)
      }
    }
    StRepeat => {
      let (sx, ix) = p.ctx.limit_x
      let (sy, iy) = p.ctx.limit_y
      for i in 0..<8 {
        p.r[i] = exclusive_repeat(p.r[i], sx, ix)
        p.g[i] = exclusive_repeat(p.g[i], sy, iy)
      }
    }
    StBilinear => p.sampler(2)
    StBicubic => p.sampler(4)
    PadX1 => for i in 0..<8 { p.r[i] = lnormalize(p.r[i]) }
    ReflectX1 =>
      for i in 0..<8 {
        let x = p.r[i]
        let f = lfloor((x - 1.0) * 0.5)
        p.r[i] = lnormalize((x - 1.0 - (f + f) - 1.0).abs())
      }
    RepeatX1 => for i in 0..<8 { p.r[i] = lnormalize(p.r[i] - lfloor(p.r[i])) }
    StGradient => {
      let g = p.ctx.gradient
      for i in 0..<8 {
        let t = p.r[i]
        let mut idx = 0
        for k in 1..<g.len {
          if t >= g.t_values[k] {
            idx += 1
          }
        }
        let f = g.factors[idx]
        let bb = g.biases[idx]
        p.r[i] = t * f.r + bb.r
        p.g[i] = t * f.g + bb.g
        p.b[i] = t * f.b + bb.b
        p.a[i] = t * f.a + bb.a
      }
    }
    EvenlySpaced2StopGradient => {
      let f = p.ctx.es2_factor
      let bb = p.ctx.es2_bias
      for i in 0..<8 {
        let t = p.r[i]
        p.r[i] = t * f.r + bb.r
        p.g[i] = t * f.g + bb.g
        p.b[i] = t * f.b + bb.b
        p.a[i] = t * f.a + bb.a
      }
    }
    XYToUnitAngle =>
      for i in 0..<8 {
        let x = p.r[i]
        let y = p.g[i]
        let x_abs = x.abs()
        let y_abs = y.abs()
        let slope = smin(x_abs, y_abs) / smax(x_abs, y_abs)
        let s = slope * slope
        let mut phi = slope *
          (0.15912117063999176025390625 +
          s *
          (-5.185396969318389892578125e-2 +
          s * (2.476101927459239959716796875e-2 + s * -7.0547382347285747528076171875e-3)))
        phi = if x_abs < y_abs { 0.25 - phi } else { phi }
        phi = if x < 0.0 { 0.5 - phi } else { phi }
        phi = if y < 0.0 { 1.0 - phi } else { phi }
        phi = if phi != phi { 0.0 } else { phi }
        p.r[i] = phi
      }
    XYToRadius =>
      for i in 0..<8 {
        let x2 = p.r[i] * p.r[i]
        let y2 = p.g[i] * p.g[i]
        p.r[i] = (x2 + y2).sqrt()
      }
    XYTo2PtConicalFocalOnCircle =>
      for i in 0..<8 {
        let x = p.r[i]
        let y = p.g[i]
        p.r[i] = x + y * y / x
      }
    XYTo2PtConicalWellBehaved =>
      for i in 0..<8 {
        let x = p.r[i]
        let y = p.g[i]
        p.r[i] = (x * x + y * y).sqrt() - x * p.ctx.conical_p0
      }
    XYTo2PtConicalGreater =>
      for i in 0..<8 {
        let x = p.r[i]
        let y = p.g[i]
        p.r[i] = (x * x - y * y).sqrt() - x * p.ctx.conical_p0
      }
    XYTo2PtConicalSmaller =>
      for i in 0..<8 {
        let x = p.r[i]
        let y = p.g[i]
        p.r[i] = -(x * x - y * y).sqrt() - x * p.ctx.conical_p0
      }
    XYTo2PtConicalStrip =>
      for i in 0..<8 {
        let x = p.r[i]
        let y = p.g[i]
        p.r[i] = x + (p.ctx.conical_p0 - y * y).sqrt()
      }
    Mask2PtConicalNan =>
      for i in 0..<8 {
        let t = p.r[i]
        let degenerate = t != t
        p.r[i] = if degenerate { 0.0 } else { t }
        p.ctx.conical_mask[i] = !degenerate
      }
    Mask2PtConicalDegenerates =>
      for i in 0..<8 {
        let t = p.r[i]
        let degenerate = t <= 0.0 || t != t
        p.r[i] = if degenerate { 0.0 } else { t }
        p.ctx.conical_mask[i] = !degenerate
      }
    ApplyVectorMask =>
      for i in 0..<8 {
        if !p.ctx.conical_mask[i] {
          p.r[i] = 0.0
          p.g[i] = 0.0
          p.b[i] = 0.0
          p.a[i] = 0.0
        }
      }
    Alter2PtConicalCompensateFocal => for i in 0..<8 { p.r[i] = p.r[i] + p.ctx.conical_p1 }
    Alter2PtConicalUnswap => for i in 0..<8 { p.r[i] = 1.0 - p.r[i] }
    NegateX => for i in 0..<8 { p.r[i] = -p.r[i] }
    ApplyConcentricScaleBias => for i in 0..<8 { p.r[i] = p.r[i] * p.ctx.conical_p0 + p.ctx.conical_p1 }
    GammaExpand2 =>
      for i in 0..<8 {
        p.r[i] = p.r[i] * p.r[i]
        p.g[i] = p.g[i] * p.g[i]
        p.b[i] = p.b[i] * p.b[i]
      }
    GammaExpandDestination2 =>
      for i in 0..<8 {
        p.dr[i] = p.dr[i] * p.dr[i]
        p.dg[i] = p.dg[i] * p.dg[i]
        p.db[i] = p.db[i] * p.db[i]
      }
    GammaCompress2 =>
      for i in 0..<8 {
        p.r[i] = p.r[i].sqrt()
        p.g[i] = p.g[i].sqrt()
        p.b[i] = p.b[i].sqrt()
      }
    GammaExpand22 =>
      for i in 0..<8 {
        p.r[i] = lane_powf(p.r[i], 2.2)
        p.g[i] = lane_powf(p.g[i], 2.2)
        p.b[i] = lane_powf(p.b[i], 2.2)
      }
    GammaExpandDestination22 =>
      for i in 0..<8 {
        p.dr[i] = lane_powf(p.dr[i], 2.2)
        p.dg[i] = lane_powf(p.dg[i], 2.2)
        p.db[i] = lane_powf(p.db[i], 2.2)
      }
    GammaCompress22 =>
      for i in 0..<8 {
        p.r[i] = lane_powf(p.r[i], 0.45454545)
        p.g[i] = lane_powf(p.g[i], 0.45454545)
        p.b[i] = lane_powf(p.b[i], 0.45454545)
      }
    GammaExpandSrgb =>
      for i in 0..<8 {
        p.r[i] = srgb_expand(p.r[i])
        p.g[i] = srgb_expand(p.g[i])
        p.b[i] = srgb_expand(p.b[i])
      }
    GammaExpandDestinationSrgb =>
      for i in 0..<8 {
        p.dr[i] = srgb_expand(p.dr[i])
        p.dg[i] = srgb_expand(p.dg[i])
        p.db[i] = srgb_expand(p.db[i])
      }
    GammaCompressSrgb =>
      for i in 0..<8 {
        p.r[i] = srgb_compress(p.r[i])
        p.g[i] = srgb_compress(p.g[i])
        p.b[i] = srgb_compress(p.b[i])
      }
  }
  true
}

///|
fn hlerp(from : Float, to : Float, t : Float) -> Float {
  (to - from) * t + from
}

///|
fn highp_soft_light_ch(s : Float, d : Float, sa : Float, da : Float, isa : Float, ida : Float) -> Float {
  let m : Float = if da > 0.0 { d / da } else { 0.0 }
  let s2 = s + s
  let m4 = m + m + (m + m)
  let dark_src = d * (sa + (s2 - sa) * (1.0 - m))
  let dark_dst = (m4 * m4 + m4) * (m - 1.0) + 7.0 * m
  let lite_dst = m.sqrt() - m
  let d4 = d + d + (d + d)
  let lite_src = d * sa + da * (s2 - sa) * (if d4 <= da { dark_dst } else { lite_dst })
  s * ida + d * isa + (if s2 <= sa { dark_src } else { lite_src })
}

///|
/// The non-separable modes: 0 hue, 1 saturation, 2 color, 3 luminosity.
fn HighP::blend3(self : HighP, mode : Int) -> Unit {
  for i in 0..<8 {
    let r = self.r[i]
    let g = self.g[i]
    let b = self.b[i]
    let a = self.a[i]
    let dr = self.dr[i]
    let dg = self.dg[i]
    let db = self.db[i]
    let da = self.da[i]
    let (rr, gg, bb) = match mode {
      0 => {
        let (rr, gg, bb) = set_sat(r * a, g * a, b * a, sat(dr, dg, db) * a)
        let (rr, gg, bb) = set_lum(rr, gg, bb, lum(dr, dg, db) * a)
        clip_color(rr, gg, bb, a * da)
      }
      1 => {
        let (rr, gg, bb) = set_sat(dr * a, dg * a, db * a, sat(r, g, b) * da)
        let (rr, gg, bb) = set_lum(rr, gg, bb, lum(dr, dg, db) * a)
        clip_color(rr, gg, bb, a * da)
      }
      2 => {
        let (rr, gg, bb) = set_lum(r * da, g * da, b * da, lum(dr, dg, db) * a)
        clip_color(rr, gg, bb, a * da)
      }
      _ => {
        let (rr, gg, bb) = set_lum(dr * a, dg * a, db * a, lum(r, g, b) * da)
        clip_color(rr, gg, bb, a * da)
      }
    }
    self.r[i] = r * (1.0 - da) + dr * (1.0 - a) + rr
    self.g[i] = g * (1.0 - da) + dg * (1.0 - a) + gg
    self.b[i] = b * (1.0 - da) + db * (1.0 - a) + bb
    self.a[i] = a + da - a * da
  }
}

///|
fn sat(r : Float, g : Float, b : Float) -> Float {
  smax(r, smax(g, b)) - smin(r, smin(g, b))
}

///|
fn lum(r : Float, g : Float, b : Float) -> Float {
  r * 0.30 + g * 0.59 + b * 0.11
}

///|
fn set_sat(r : Float, g : Float, b : Float, s : Float) -> (Float, Float, Float) {
  let mn = smin(r, smin(g, b))
  let mx = smax(r, smax(g, b))
  let sat = mx - mn
  if sat == 0.0 {
    (0.0, 0.0, 0.0)
  } else {
    ((r - mn) * s / sat, (g - mn) * s / sat, (b - mn) * s / sat)
  }
}

///|
fn set_lum(r : Float, g : Float, b : Float, l : Float) -> (Float, Float, Float) {
  let diff = l - lum(r, g, b)
  (r + diff, g + diff, b + diff)
}

///|
fn clip_ch(c : Float, mn : Float, mx : Float, l : Float, a : Float) -> Float {
  let c = if mx >= 0.0 { c } else { l + (c - l) * l / (l - mn) }
  let c = if mx > a { l + (c - l) * (a - l) / (mx - l) } else { c }
  smax(c, 0.0)
}

///|
fn clip_color(r : Float, g : Float, b : Float, a : Float) -> (Float, Float, Float) {
  let mn = smin(r, smin(g, b))
  let mx = smax(r, smax(g, b))
  let l = lum(r, g, b)
  (clip_ch(r, mn, mx, l, a), clip_ch(g, mn, mx, l, a), clip_ch(b, mn, mx, l, a))
}

///|
fn exclusive_reflect(v : Float, limit : Float, inv_limit : Float) -> Float {
  (v - limit - (limit + limit) * lfloor((v - limit) * (inv_limit * 0.5)) - limit).abs()
}

///|
fn exclusive_repeat(v : Float, limit : Float, inv_limit : Float) -> Float {
  v - lfloor(v * inv_limit) * limit
}

///|
/// f32x8::powf: approx_powf in lanes, 0 and 1 kept.
fn lane_powf(x : Float, exp : Float) -> Float {
  if x == 0.0 || x == 1.0 {
    return x
  }
  let e = fi(x.reinterpret_as_int()) * (1.0 / 8388608.0)
  let m = Float::reinterpret_from_uint((x.reinterpret_as_uint() & 0x007fffffU) | 0x3f000000U)
  let log2_x = e - 124.225514990 - 1.498030302 * m - 1.725879990 / (0.3520887068 + m)
  let x2 = log2_x * exp
  let f = x2 - lfloor(x2)
  let mut a = x2 + 121.274057500
  a = a - f * 1.490129070
  a = a + 27.728023300 / (4.84252568 - f)
  a = a * 8388608.0
  let inf_bits = Float::from_uint(0x7f800000U)
  Float::reinterpret_from_int(round_int(smin(smax(a, 0.0), inf_bits)))
}

///|
fn srgb_expand(x : Float) -> Float {
  if x <= 0.04045 {
    x / 12.92
  } else {
    lane_powf((x + 0.055) / 1.055, 2.4)
  }
}

///|
fn srgb_compress(x : Float) -> Float {
  if x <= 0.0031308 {
    x * 12.92
  } else {
    lane_powf(x, 0.416666666) * 1.055 - 0.055
  }
}

///|
fn HighP::load_dst(self : HighP) -> Unit {
  let o = self.dst.offset_at(self.dx, self.dy) * 4
  let d = self.dst.data
  for i in 0..<8 {
    if i < self.tail {
      self.dr[i] = fi(d[o + i * 4].to_int()) * (1.0 / 255.0)
      self.dg[i] = fi(d[o + i * 4 + 1].to_int()) * (1.0 / 255.0)
      self.db[i] = fi(d[o + i * 4 + 2].to_int()) * (1.0 / 255.0)
      self.da[i] = fi(d[o + i * 4 + 3].to_int()) * (1.0 / 255.0)
    } else {
      self.dr[i] = 0.0
      self.dg[i] = 0.0
      self.db[i] = 0.0
      self.da[i] = 0.0
    }
  }
}

///|
fn unnorm(v : Float) -> Int {
  let x = smin(smax(v, 0.0), 1.0) * 255.0
  let ti = x.to_int()
  let d = x - fi(ti)
  if d > 0.5 {
    ti + 1
  } else if d == 0.5 {
    ti + (ti & 1)
  } else {
    ti
  }
}

///|
fn HighP::store(self : HighP) -> Unit {
  let o = self.dst.offset_at(self.dx, self.dy) * 4
  let d = self.dst.data
  for i in 0..<self.tail {
    d[o + i * 4] = unnorm(self.r[i]).to_byte()
    d[o + i * 4 + 1] = unnorm(self.g[i]).to_byte()
    d[o + i * 4 + 2] = unnorm(self.b[i]).to_byte()
    d[o + i * 4 + 3] = unnorm(self.a[i]).to_byte()
  }
}

///|
fn ulp_sub(v : Float) -> Float {
  Float::reinterpret_from_uint(v.reinterpret_as_uint() - 1U)
}

///|
fn bicubic_near(t : Float) -> Float {
  t * (t * ((-21.0 / 18.0 : Float) * t + (27.0 / 18.0 : Float)) + (9.0 / 18.0 : Float)) + (1.0 / 18.0 : Float)
}

///|
fn bicubic_far(t : Float) -> Float {
  t * t * ((7.0 / 18.0 : Float) * t + (-6.0 / 18.0 : Float))
}

///|
/// bilinear (n 2) and bicubic (n 4) sampling of the source, allocation-free via per-blitter scratch buffers.
fn HighP::sampler(self : HighP, n : Int) -> Unit {
  let tail = self.tail
  let start : Float = if n == 2 { -0.5 } else { -1.5 }
  let cx_buf = self.cx
  let cy_buf = self.cy
  let xs_buf = self.xs
  let ys_buf = self.ys
  let wx_buf = self.wx
  let wy_buf = self.wy
  for i in 0..<tail {
    let cx = self.r[i]
    let cy = self.g[i]
    cx_buf[i] = cx
    cy_buf[i] = cy
    ys_buf[i] = cy + start
    let fx = (cx + 0.5) - lfloor(cx + 0.5)
    let fy = (cy + 0.5) - lfloor(cy + 0.5)
    if n == 2 {
      wx_buf[i] = 1.0 - fx
      wx_buf[8 + i] = fx
      wy_buf[i] = 1.0 - fy
      wy_buf[8 + i] = fy
    } else {
      wx_buf[i] = bicubic_far(1.0 - fx)
      wx_buf[8 + i] = bicubic_near(1.0 - fx)
      wx_buf[16 + i] = bicubic_near(fx)
      wx_buf[24 + i] = bicubic_far(fx)
      wy_buf[i] = bicubic_far(1.0 - fy)
      wy_buf[8 + i] = bicubic_near(1.0 - fy)
      wy_buf[16 + i] = bicubic_near(fy)
      wy_buf[24 + i] = bicubic_far(fy)
    }
    self.r[i] = 0.0
    self.g[i] = 0.0
    self.b[i] = 0.0
    self.a[i] = 0.0
  }
  let pix = self.src
  let pw = pix.width
  let ph = pix.height
  let wf = fi(pw)
  let hf = fi(ph)
  let w_ulp = ulp_sub(wf)
  let h_ulp = ulp_sub(hf)
  let spread = self.ctx.sampler_spread
  let inv_w = self.ctx.sampler_inv_width
  let inv_h = self.ctx.sampler_inv_height
  let sdata = pix.data
  let inv255 : Float = 1.0 / 255.0
  for j in 0..<n {
    let wy_base = j * 8
    for i in 0..<tail {
      xs_buf[i] = cx_buf[i] + start
    }
    for k in 0..<n {
      let wx_base = k * 8
      for i in 0..<tail {
        let tx = tile(xs_buf[i], spread, wf, inv_w)
        let ty = tile(ys_buf[i], spread, hf, inv_h)
        let x = smin(smax(tx, 0.0), w_ulp)
        let y = smin(smax(ty, 0.0), h_ulp)
        let o = (trunc_int(y) * pw + trunc_int(x)) * 4
        let w = wx_buf[wx_base + i] * wy_buf[wy_base + i]
        self.r[i] = w * (fi(sdata[o].to_int()) * inv255) + self.r[i]
        self.g[i] = w * (fi(sdata[o + 1].to_int()) * inv255) + self.g[i]
        self.b[i] = w * (fi(sdata[o + 2].to_int()) * inv255) + self.b[i]
        self.a[i] = w * (fi(sdata[o + 3].to_int()) * inv255) + self.a[i]
        xs_buf[i] = xs_buf[i] + 1.0
      }
    }
    for i in 0..<tail {
      ys_buf[i] = ys_buf[i] + 1.0
    }
  }
}

///|
fn tile(v : Float, mode : SpreadMode, limit : Float, inv_limit : Float) -> Float {
  match mode {
    Pad => v
    Repeat => exclusive_repeat(v, limit, inv_limit)
    Reflect => exclusive_reflect(v, limit, inv_limit)
  }
}
