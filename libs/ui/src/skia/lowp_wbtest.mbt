///|
fn fill_pattern_pixmap(pm : Pixmap) -> Unit {
  let n = pm.width * pm.height
  for i in 0..<n {
    let a = 40 + i * 37 % 216
    let r = i * 53 % (a + 1)
    let g = i * 97 % (a + 1)
    let b = i * 131 % (a + 1)
    pm.data[i * 4] = r.to_byte()
    pm.data[i * 4 + 1] = g.to_byte()
    pm.data[i * 4 + 2] = b.to_byte()
    pm.data[i * 4 + 3] = a.to_byte()
  }
}

///|
fn fill_pattern_mask(m : Mask) -> Unit {
  let n = m.width * m.height
  for i in 0..<n {
    m.data[i] = ((i * 43 + 17) % 256).to_byte()
  }
}

///|
fn assert_bytes_eq(a : FixedArray[Byte], b : FixedArray[Byte]) -> Unit raise {
  assert_eq(a.length(), b.length())
  for i in 0..<a.length() {
    if a[i] != b[i] {
      assert_eq(a[i], b[i])
    }
  }
}

///|
test "lowp fast paths byte-exact equivalence with generic stage pipeline" {
  let w = 23
  let h = 4
  let rect = ScreenIntRect::from_xywh(0, 0, w, h).unwrap()

  let check_rgba = fn(
    stages : Array[Stage],
    rgba : (Int, Int, Int, Int),
    cov : Float,
    aa : AAMaskCtx,
    r : ScreenIntRect,
  ) -> Unit raise {
    let pm_fast = Pixmap::new(w, h).unwrap()
    let pm_ref = Pixmap::new(w, h).unwrap()
    fill_pattern_pixmap(pm_fast)
    fill_pattern_pixmap(pm_ref)
    let ctx = Context::new()
    ctx.uniform_rgba = rgba
    ctx.current_coverage = cov
    lowp_start(stages, r, aa, mask_none, ctx, pm_fast.as_subpixmap())
    lowp_start_generic(stages, r, aa, mask_none, ctx, pm_ref.as_subpixmap())
    assert_bytes_eq(pm_fast.data, pm_ref.data)
  }

  let check_u8 = fn(
    stages : Array[Stage],
    rgba : (Int, Int, Int, Int),
    cov : Float,
    aa : AAMaskCtx,
    r : ScreenIntRect,
  ) -> Unit raise {
    let m_fast = Mask::new(w, h).unwrap()
    let m_ref = Mask::new(w, h).unwrap()
    fill_pattern_mask(m_fast)
    fill_pattern_mask(m_ref)
    let ctx = Context::new()
    ctx.uniform_rgba = rgba
    ctx.current_coverage = cov
    lowp_start(stages, r, aa, mask_none, ctx, m_fast.as_subpixmap())
    lowp_start_generic(stages, r, aa, mask_none, ctx, m_ref.as_subpixmap())
    assert_bytes_eq(m_fast.data, m_ref.data)
  }

  let rect2 = ScreenIntRect::from_xywh(3, 1, 2, 1).unwrap()
  let rect1 = ScreenIntRect::from_xywh(4, 1, 1, 1).unwrap()
  let aa2 : AAMaskCtx = { p0: 180, p1: 75, stride: w, shift: w * 1 + 3 }
  let invalid_pm1 = (240, 200, 180, 100)
  let invalid_pm2 = (255, 255, 255, 0)

  // 1. [UniformColor, Store]
  check_rgba([UniformColor, Store], (120, 45, 200, 210), 1.0, aa_mask_none, rect)
  check_rgba([UniformColor, Store], invalid_pm1, 1.0, aa_mask_none, rect)
  check_rgba([UniformColor, Store], invalid_pm2, 1.0, aa_mask_none, rect)

  // 2. [UniformColor, SourceOverRgba] — opaque, translucent, zero, invalid premultiplied
  check_rgba([UniformColor, SourceOverRgba], (200, 100, 50, 255), 1.0, aa_mask_none, rect)
  check_rgba([UniformColor, SourceOverRgba], (90, 40, 110, 128), 1.0, aa_mask_none, rect)
  check_rgba([UniformColor, SourceOverRgba], (0, 0, 0, 0), 1.0, aa_mask_none, rect)
  check_rgba([UniformColor, SourceOverRgba], invalid_pm1, 1.0, aa_mask_none, rect)
  check_rgba([UniformColor, SourceOverRgba], invalid_pm2, 1.0, aa_mask_none, rect)

  // 3. [UniformColor, StoreU8]
  check_u8([UniformColor, StoreU8], (0, 0, 0, 199), 1.0, aa_mask_none, rect)

  // 4. [UniformColor, LoadDestinationU8, Lerp1Float, StoreU8]
  check_u8([UniformColor, LoadDestinationU8, Lerp1Float, StoreU8], (0, 0, 0, 220), 0.61, aa_mask_none, rect)
  check_u8([UniformColor, LoadDestinationU8, Lerp1Float, StoreU8], (0, 0, 0, 220), 0.0, aa_mask_none, rect)
  check_u8([UniformColor, LoadDestinationU8, Lerp1Float, StoreU8], (0, 0, 0, 220), 1.0, aa_mask_none, rect)

  // 5. [UniformColor, LoadDestination, Lerp1Float, Store] (opaque AA edge)
  check_rgba([UniformColor, LoadDestination, Lerp1Float, Store], (180, 90, 240, 255), 0.37, aa_mask_none, rect)
  check_rgba([UniformColor, LoadDestination, Lerp1Float, Store], (180, 90, 240, 255), 0.0, aa_mask_none, rect)
  check_rgba([UniformColor, LoadDestination, Lerp1Float, Store], (180, 90, 240, 255), 1.0, aa_mask_none, rect)
  check_rgba([UniformColor, LoadDestination, Lerp1Float, Store], invalid_pm1, 0.55, aa_mask_none, rect)
  check_rgba([UniformColor, LoadDestination, Lerp1Float, Store], invalid_pm2, 0.55, aa_mask_none, rect)

  // 6. [UniformColor, LoadDestination, LerpU8, Store] (opaque AA hairline 1px/2px/23px)
  check_rgba([UniformColor, LoadDestination, LerpU8, Store], (150, 80, 210, 255), 1.0, aa2, rect2)
  check_rgba([UniformColor, LoadDestination, LerpU8, Store], (150, 80, 210, 255), 1.0, aa2, rect1)
  check_rgba([UniformColor, LoadDestination, LerpU8, Store], (150, 80, 210, 255), 1.0, aa2, rect)
  check_rgba([UniformColor, LoadDestination, LerpU8, Store], invalid_pm1, 1.0, aa2, rect2)
  check_rgba([UniformColor, LoadDestination, LerpU8, Store], invalid_pm2, 1.0, aa2, rect)

  // 7. [UniformColor, LoadDestinationU8, LerpU8, StoreU8] (mask AA hairline 1px/2px/23px)
  check_u8([UniformColor, LoadDestinationU8, LerpU8, StoreU8], (0, 0, 0, 230), 1.0, aa2, rect2)
  check_u8([UniformColor, LoadDestinationU8, LerpU8, StoreU8], (0, 0, 0, 230), 1.0, aa2, rect1)
  check_u8([UniformColor, LoadDestinationU8, LerpU8, StoreU8], (0, 0, 0, 230), 1.0, aa2, rect)

  // 8. [UniformColor, Scale1Float, LoadDestination, StSourceOver, Store]
  let s_scale1f = [UniformColor, Scale1Float, LoadDestination, StSourceOver, Store]
  check_rgba(s_scale1f, (180, 90, 240, 255), 0.37, aa_mask_none, rect)
  check_rgba(s_scale1f, (180, 90, 240, 255), 1.0, aa_mask_none, rect)
  check_rgba(s_scale1f, (180, 90, 240, 255), 0.0, aa_mask_none, rect)
  check_rgba(s_scale1f, invalid_pm1, 0.55, aa_mask_none, rect)
  check_rgba(s_scale1f, invalid_pm2, 0.55, aa_mask_none, rect)

  // 9. [UniformColor, LoadDestination, StSourceOver, Lerp1Float, Store]
  let s_lerp1f = [UniformColor, LoadDestination, StSourceOver, Lerp1Float, Store]
  check_rgba(s_lerp1f, (100, 60, 140, 175), 0.73, aa_mask_none, rect)
  check_rgba(s_lerp1f, (100, 60, 140, 175), 0.0, aa_mask_none, rect)
  check_rgba(s_lerp1f, (100, 60, 140, 175), 1.0, aa_mask_none, rect)
  check_rgba(s_lerp1f, invalid_pm1, 0.73, aa_mask_none, rect)
  check_rgba(s_lerp1f, invalid_pm2, 0.73, aa_mask_none, rect)

  // 10. [UniformColor, ScaleU8, LoadDestination, StSourceOver, Store] — 1px, 2px hairline AA & 23px span
  let s_scaleu8 = [UniformColor, ScaleU8, LoadDestination, StSourceOver, Store]
  check_rgba(s_scaleu8, (150, 80, 210, 230), 1.0, aa2, rect2)
  check_rgba(s_scaleu8, (150, 80, 210, 230), 1.0, aa2, rect1)
  check_rgba(s_scaleu8, (150, 80, 210, 230), 1.0, aa2, rect)
  check_rgba(s_scaleu8, invalid_pm1, 1.0, aa2, rect2)
  check_rgba(s_scaleu8, invalid_pm2, 1.0, aa2, rect)
}

///|
fn ref_blend1(
  r : FixedArray[Int],
  g : FixedArray[Int],
  b : FixedArray[Int],
  a : FixedArray[Int],
  dr : FixedArray[Int],
  dg : FixedArray[Int],
  db : FixedArray[Int],
  da : FixedArray[Int],
  f : (Int, Int, Int, Int) -> Int,
) -> Unit {
  for i in 0..<16 {
    let sa = a[i]
    let d_a = da[i]
    r[i] = f(r[i], dr[i], sa, d_a)
    g[i] = f(g[i], dg[i], sa, d_a)
    b[i] = f(b[i], db[i], sa, d_a)
    a[i] = f(sa, d_a, sa, d_a)
  }
}

///|
fn ref_blend2(
  r : FixedArray[Int],
  g : FixedArray[Int],
  b : FixedArray[Int],
  a : FixedArray[Int],
  dr : FixedArray[Int],
  dg : FixedArray[Int],
  db : FixedArray[Int],
  da : FixedArray[Int],
  f : (Int, Int, Int, Int) -> Int,
) -> Unit {
  for i in 0..<16 {
    let sa = a[i]
    let d_a = da[i]
    r[i] = f(r[i], dr[i], sa, d_a)
    g[i] = f(g[i], dg[i], sa, d_a)
    b[i] = f(b[i], db[i], sa, d_a)
    a[i] = w16(sa + div255(mul16(d_a, inv255(sa))))
  }
}

///|
fn ref_blend_stage(
  s : Stage,
  r : FixedArray[Int],
  g : FixedArray[Int],
  b : FixedArray[Int],
  a : FixedArray[Int],
  dr : FixedArray[Int],
  dg : FixedArray[Int],
  db : FixedArray[Int],
  da : FixedArray[Int],
) -> Unit {
  match s {
    StClear => ref_blend1(r, g, b, a, dr, dg, db, da, fn(_s, _d, _sa, _da) { 0 })
    StSourceAtop =>
      ref_blend1(r, g, b, a, dr, dg, db, da, fn(s, d, sa, da) {
        div255(w16(mul16(s, da) + mul16(d, inv255(sa))))
      })
    StDestinationAtop =>
      ref_blend1(r, g, b, a, dr, dg, db, da, fn(s, d, sa, da) {
        div255(w16(mul16(d, sa) + mul16(s, inv255(da))))
      })
    StSourceIn => ref_blend1(r, g, b, a, dr, dg, db, da, fn(s, _d, _sa, da) { div255(mul16(s, da)) })
    StDestinationIn => ref_blend1(r, g, b, a, dr, dg, db, da, fn(_s, d, sa, _da) { div255(mul16(d, sa)) })
    StSourceOut => ref_blend1(r, g, b, a, dr, dg, db, da, fn(s, _d, _sa, da) { div255(mul16(s, inv255(da))) })
    StDestinationOut => ref_blend1(r, g, b, a, dr, dg, db, da, fn(_s, d, sa, _da) { div255(mul16(d, inv255(sa))) })
    StSourceOver =>
      ref_blend1(r, g, b, a, dr, dg, db, da, fn(s, d, sa, _da) { w16(s + div255(mul16(d, inv255(sa)))) })
    StDestinationOver =>
      ref_blend1(r, g, b, a, dr, dg, db, da, fn(s, d, _sa, da) { w16(d + div255(mul16(s, inv255(da)))) })
    StModulate => ref_blend1(r, g, b, a, dr, dg, db, da, fn(s, d, _sa, _da) { div255(mul16(s, d)) })
    StMultiply =>
      ref_blend1(r, g, b, a, dr, dg, db, da, fn(s, d, sa, da) {
        div255(w16(w16(mul16(s, inv255(da)) + mul16(d, inv255(sa))) + mul16(s, d)))
      })
    StScreen =>
      ref_blend1(r, g, b, a, dr, dg, db, da, fn(s, d, _sa, _da) { w16(w16(s + d) - div255(mul16(s, d))) })
    StXor =>
      ref_blend1(r, g, b, a, dr, dg, db, da, fn(s, d, sa, da) {
        div255(w16(mul16(s, inv255(da)) + mul16(d, inv255(sa))))
      })
    StPlus =>
      ref_blend1(r, g, b, a, dr, dg, db, da, fn(s, d, _sa, _da) {
        let v = w16(s + d)
        if v < 255 {
          v
        } else {
          255
        }
      })
    StDarken =>
      ref_blend2(r, g, b, a, dr, dg, db, da, fn(s, d, sa, da) {
        let x = mul16(s, da)
        let y = mul16(d, sa)
        w16(w16(s + d) - div255(if x > y { x } else { y }))
      })
    StLighten =>
      ref_blend2(r, g, b, a, dr, dg, db, da, fn(s, d, sa, da) {
        let x = mul16(s, da)
        let y = mul16(d, sa)
        w16(w16(s + d) - div255(if x < y { x } else { y }))
      })
    StExclusion =>
      ref_blend2(r, g, b, a, dr, dg, db, da, fn(s, d, _sa, _da) {
        w16(w16(s + d) - mul16(2, div255(mul16(s, d))))
      })
    StDifference =>
      ref_blend2(r, g, b, a, dr, dg, db, da, fn(s, d, sa, da) {
        let x = mul16(s, da)
        let y = mul16(d, sa)
        w16(w16(s + d) - mul16(2, div255(if x < y { x } else { y })))
      })
    StHardLight =>
      ref_blend2(r, g, b, a, dr, dg, db, da, fn(s, d, sa, da) {
        let k = if w16(s + s) <= sa {
          mul16(mul16(2, s), d)
        } else {
          w16(mul16(sa, da) - mul16(mul16(2, w16(sa - s)), w16(da - d)))
        }
        div255(w16(w16(mul16(s, inv255(da)) + mul16(d, inv255(sa))) + k))
      })
    StOverlay =>
      ref_blend2(r, g, b, a, dr, dg, db, da, fn(s, d, sa, da) {
        let k = if w16(d + d) <= da {
          mul16(mul16(2, s), d)
        } else {
          w16(mul16(sa, da) - mul16(mul16(2, w16(sa - s)), w16(da - d)))
        }
        div255(w16(w16(mul16(s, inv255(da)) + mul16(d, inv255(sa))) + k))
      })
    _ => @halt.saying("ref_blend_stage: unexpected stage")
  }
}

///|
test "lowp inlined blend stages match closure reference" {
  let stages : Array[Stage] = [
    StClear,
    StSourceAtop,
    StDestinationAtop,
    StSourceIn,
    StDestinationIn,
    StSourceOut,
    StDestinationOut,
    StSourceOver,
    StDestinationOver,
    StModulate,
    StMultiply,
    StScreen,
    StXor,
    StPlus,
    StDarken,
    StLighten,
    StExclusion,
    StDifference,
    StHardLight,
    StOverlay,
  ]
  // Boundary values (0, 1, 127, 128, 254, 255) and invalid premultiplied (r/g/b > a)
  let vals : Array[Int] = [0, 1, 127, 128, 254, 255, 64, 192]
  let pm = Pixmap::new(16, 1).unwrap()
  let ctx = Context::new()

  for st in stages {
    for batch in 0..<4 {
      let r = FixedArray::make(16, 0)
      let g = FixedArray::make(16, 0)
      let b = FixedArray::make(16, 0)
      let a = FixedArray::make(16, 0)
      let dr = FixedArray::make(16, 0)
      let dg = FixedArray::make(16, 0)
      let db = FixedArray::make(16, 0)
      let da = FixedArray::make(16, 0)
      let rr = FixedArray::make(16, 0)
      let rg = FixedArray::make(16, 0)
      let rb = FixedArray::make(16, 0)
      let ra = FixedArray::make(16, 0)
      let rdr = FixedArray::make(16, 0)
      let rdg = FixedArray::make(16, 0)
      let rdb = FixedArray::make(16, 0)
      let rda = FixedArray::make(16, 0)

      for i in 0..<16 {
        let idx = batch * 16 + i
        let sr = vals[idx % 8]
        let sg = vals[(idx * 3 + 1) % 8]
        let sb = vals[(idx * 5 + 2) % 8]
        let sa = vals[(idx * 7 + 3) % 8]
        let d_r = vals[(idx * 3 + 5) % 8]
        let d_g = vals[(idx * 5 + 4) % 8]
        let d_b = vals[(idx * 7 + 1) % 8]
        let d_a = vals[(idx + 2) % 8]
        r[i] = sr
        g[i] = sg
        b[i] = sb
        a[i] = sa
        dr[i] = d_r
        dg[i] = d_g
        db[i] = d_b
        da[i] = d_a
        rr[i] = sr
        rg[i] = sg
        rb[i] = sb
        ra[i] = sa
        rdr[i] = d_r
        rdg[i] = d_g
        rdb[i] = d_b
        rda[i] = d_a
      }

      let p : LowP = {
        r,
        g,
        b,
        a,
        dr,
        dg,
        db,
        da,
        fx: FixedArray::make(16, 0.0),
        fy: FixedArray::make(16, 0.0),
        tail: 16,
        dx: 0,
        dy: 0,
        ctx,
        mask_ctx: mask_none,
        aa_mask_ctx: aa_mask_none,
        dst: pm.as_subpixmap(),
      }
      assert_true(p.stage(st))
      ref_blend_stage(st, rr, rg, rb, ra, rdr, rdg, rdb, rda)
      for i in 0..<16 {
        assert_eq(p.r[i], rr[i])
        assert_eq(p.g[i], rg[i])
        assert_eq(p.b[i], rb[i])
        assert_eq(p.a[i], ra[i])
      }
    }
  }
}

///|
test "lowp end-to-end AA circle + translucent rect sanity" {
  let pm = Pixmap::new(64, 48).unwrap()
  let circle = PathBuilder::from_circle(32.0, 24.0, 14.0).unwrap()
  let rect = Rect::from_xywh(6.0, 6.0, 52.0, 36.0).unwrap()
  let p_solid = Paint::default()
  p_solid.set_color_rgba8(30, 120, 220, 255)
  p_solid.anti_alias = true
  let p_alpha = Paint::default()
  p_alpha.set_color_rgba8(240, 80, 60, 128)
  p_alpha.anti_alias = true
  for _ in 0..<2 {
    pm.fill_rect(rect, p_alpha, Transform::identity(), None)
    pm.fill_path(circle, p_solid, FillRule::Winding, Transform::identity(), None)
  }
  assert_eq(pm.pixel(32, 24).unwrap().a, 255)
  assert_eq(pm.pixel(32, 24).unwrap().r, 30)
  let outside = pm.pixel(10, 10).unwrap()
  assert_true(outside.a > 128 && outside.a < 255)
}
