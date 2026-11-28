///|
test "highp unnorm matches round_int reference on all byte boundaries and edge floats" {
  let ref_unnorm = fn(v : Float) -> Int {
    round_int(smin(smax(v, 0.0), 1.0) * 255.0) & 0xFF
  }
  // Exact 0..=255 roundtrip via fi(b) * (1.0 / 255.0)
  let inv255 : Float = 1.0 / 255.0
  for b in 0..=255 {
    let f = fi(b) * inv255
    assert_eq(unnorm(f), b)
    assert_eq(unnorm(f), ref_unnorm(f))
  }
  assert_true(fi(255) * inv255 == 1.0)
  // Ties-to-even half-integers and +/- 1 ULP around every half-integer
  for k in 0..<255 {
    let half = (fi(k) + 0.5) / 255.0
    let bits = half.reinterpret_as_uint()
    let prev = Float::reinterpret_from_uint(bits - 1U)
    let next = Float::reinterpret_from_uint(bits + 1U)
    assert_eq(unnorm(half), ref_unnorm(half))
    assert_eq(unnorm(prev), ref_unnorm(prev))
    assert_eq(unnorm(next), ref_unnorm(next))
  }
  // Edge floats: negative, -0.0, >1, inf, -inf, NaN
  let edges : Array[Float] = [
    -100.0,
    -0.5,
    -0.0,
    0.0,
    1.0,
    1.5,
    1000.0,
    Float::reinterpret_from_uint(0x7f800000U),
    Float::reinterpret_from_uint(0xff800000U),
    Float::reinterpret_from_uint(0x7fc00000U),
  ]
  for v in edges {
    assert_eq(unnorm(v), ref_unnorm(v))
  }
}

///|
test "highp gather-translate fast paths byte-exact equivalence with generic stage pipeline" {
  let sw = 19
  let sh = 7
  let src = Pixmap::new(sw, sh).unwrap()
  // Include opaque (a=255), transparent (0,0,0,0), semi-transparent, and non-zero RGB with a=0
  for i in 0..<(sw * sh) {
    let mode = i % 5
    if mode == 0 {
      src.data[i * 4] = b'\x00'
      src.data[i * 4 + 1] = b'\x00'
      src.data[i * 4 + 2] = b'\x00'
      src.data[i * 4 + 3] = b'\x00'
    } else if mode == 1 {
      src.data[i * 4] = ((i * 41) % 256).to_byte()
      src.data[i * 4 + 1] = ((i * 73) % 256).to_byte()
      src.data[i * 4 + 2] = ((i * 97) % 256).to_byte()
      src.data[i * 4 + 3] = b'\xFF'
    } else if mode == 2 {
      src.data[i * 4] = ((i * 29 + 1) % 256).to_byte()
      src.data[i * 4 + 1] = ((i * 19 + 3) % 256).to_byte()
      src.data[i * 4 + 2] = ((i * 11 + 5) % 256).to_byte()
      src.data[i * 4 + 3] = b'\x00'
    } else {
      let a = 1 + (i * 53) % 254
      src.data[i * 4] = ((i * 37) % (a + 1)).to_byte()
      src.data[i * 4 + 1] = ((i * 61) % (a + 1)).to_byte()
      src.data[i * 4 + 2] = ((i * 89) % (a + 1)).to_byte()
      src.data[i * 4 + 3] = a.to_byte()
    }
  }
  let dw = 25
  let dh = 11
  let rect = ScreenIntRect::from_xywh(1, 1, 23, 9).unwrap()

  let check = fn(stages : Array[Stage], ts : Transform, cov : Float, empty_dst : Bool) -> Unit raise {
    let dst_fast = Pixmap::new(dw, dh).unwrap()
    let dst_ref = Pixmap::new(dw, dh).unwrap()
    if !empty_dst {
      fill_pattern_pixmap(dst_fast)
      fill_pattern_pixmap(dst_ref)
    }
    let ctx = Context::new()
    ctx.transform = ts
    ctx.current_coverage = cov
    highp_start(stages, rect, aa_mask_none, mask_none, ctx, src, dst_fast.as_subpixmap())
    highp_start_generic(stages, rect, aa_mask_none, mask_none, ctx, src, dst_ref.as_subpixmap())
    assert_bytes_eq(dst_fast.data, dst_ref.data)
  }

  let id = Transform::identity()
  // Translations exercising left clamp, unclamped interior, right clamp, top/bottom clamp
  let translations : Array[Transform] = [
    Transform::from_translate(0.0, 0.0),
    Transform::from_translate(-5.0, -3.0),
    Transform::from_translate(4.0, 2.0),
    Transform::from_translate(-30.0, 15.0),
    Transform::from_translate(2.5, -1.25),
  ]

  for empty_dst in [false, true] {
    check([SeedShader, Gather, Store], id, 1.0, empty_dst)
    check([SeedShader, Gather, SourceOverRgba], id, 1.0, empty_dst)
    check([SeedShader, Gather, Scale1Float, Store], id, 0.63, empty_dst)
    check([SeedShader, Gather, Scale1Float, SourceOverRgba], id, 0.63, empty_dst)
    check([SeedShader, Gather, Scale1Float, SourceOverRgba], id, 0.0, empty_dst)
    for ts in translations {
      check([SeedShader, StTransform, Gather, Store], ts, 1.0, empty_dst)
      check([SeedShader, StTransform, Gather, SourceOverRgba], ts, 1.0, empty_dst)
      check([SeedShader, StTransform, Gather, Scale1Float, Store], ts, 0.47, empty_dst)
      check([SeedShader, StTransform, Gather, Scale1Float, SourceOverRgba], ts, 0.47, empty_dst)
    }
  }

  // Self-aliasing fallback must match generic exactly
  let self_fast = Pixmap::new(sw, sh).unwrap()
  let self_ref = Pixmap::new(sw, sh).unwrap()
  fill_pattern_pixmap(self_fast)
  fill_pattern_pixmap(self_ref)
  let ctx_alias = Context::new()
  ctx_alias.transform = Transform::from_translate(-2.0, 0.0)
  let r_alias = ScreenIntRect::from_xywh(0, 0, sw, sh).unwrap()
  highp_start([SeedShader, StTransform, Gather, Store], r_alias, aa_mask_none, mask_none, ctx_alias, self_fast, self_fast.as_subpixmap())
  highp_start_generic([SeedShader, StTransform, Gather, Store], r_alias, aa_mask_none, mask_none, ctx_alias, self_ref, self_ref.as_subpixmap())
  assert_bytes_eq(self_fast.data, self_ref.data)
}

///|
fn ref_hp_blend1(
  r : FixedArray[Float],
  g : FixedArray[Float],
  b : FixedArray[Float],
  a : FixedArray[Float],
  dr : FixedArray[Float],
  dg : FixedArray[Float],
  db : FixedArray[Float],
  da : FixedArray[Float],
  f : (Float, Float, Float, Float) -> Float,
) -> Unit {
  for i in 0..<8 {
    let sa = a[i]
    let d_a = da[i]
    r[i] = f(r[i], dr[i], sa, d_a)
    g[i] = f(g[i], dg[i], sa, d_a)
    b[i] = f(b[i], db[i], sa, d_a)
    a[i] = f(sa, d_a, sa, d_a)
  }
}

///|
fn ref_hp_blend2(
  r : FixedArray[Float],
  g : FixedArray[Float],
  b : FixedArray[Float],
  a : FixedArray[Float],
  dr : FixedArray[Float],
  dg : FixedArray[Float],
  db : FixedArray[Float],
  da : FixedArray[Float],
  f : (Float, Float, Float, Float) -> Float,
) -> Unit {
  for i in 0..<8 {
    let sa = a[i]
    let d_a = da[i]
    r[i] = f(r[i], dr[i], sa, d_a)
    g[i] = f(g[i], dg[i], sa, d_a)
    b[i] = f(b[i], db[i], sa, d_a)
    a[i] = d_a * (1.0 - sa) + sa
  }
}

///|
fn ref_hp_blend_stage(
  s : Stage,
  r : FixedArray[Float],
  g : FixedArray[Float],
  b : FixedArray[Float],
  a : FixedArray[Float],
  dr : FixedArray[Float],
  dg : FixedArray[Float],
  db : FixedArray[Float],
  da : FixedArray[Float],
) -> Unit {
  match s {
    StClear => ref_hp_blend1(r, g, b, a, dr, dg, db, da, fn(_s, _d, _sa, _da) { 0.0 })
    StSourceAtop => ref_hp_blend1(r, g, b, a, dr, dg, db, da, fn(s, d, sa, da) { s * da + d * (1.0 - sa) })
    StDestinationAtop => ref_hp_blend1(r, g, b, a, dr, dg, db, da, fn(s, d, sa, da) { d * sa + s * (1.0 - da) })
    StSourceIn => ref_hp_blend1(r, g, b, a, dr, dg, db, da, fn(s, _d, _sa, da) { s * da })
    StDestinationIn => ref_hp_blend1(r, g, b, a, dr, dg, db, da, fn(_s, d, sa, _da) { d * sa })
    StSourceOut => ref_hp_blend1(r, g, b, a, dr, dg, db, da, fn(s, _d, _sa, da) { s * (1.0 - da) })
    StDestinationOut => ref_hp_blend1(r, g, b, a, dr, dg, db, da, fn(_s, d, sa, _da) { d * (1.0 - sa) })
    StSourceOver => ref_hp_blend1(r, g, b, a, dr, dg, db, da, fn(s, d, sa, _da) { d * (1.0 - sa) + s })
    StDestinationOver => ref_hp_blend1(r, g, b, a, dr, dg, db, da, fn(s, d, _sa, da) { s * (1.0 - da) + d })
    StModulate => ref_hp_blend1(r, g, b, a, dr, dg, db, da, fn(s, d, _sa, _da) { s * d })
    StMultiply => ref_hp_blend1(r, g, b, a, dr, dg, db, da, fn(s, d, sa, da) { s * (1.0 - da) + d * (1.0 - sa) + s * d })
    StScreen => ref_hp_blend1(r, g, b, a, dr, dg, db, da, fn(s, d, _sa, _da) { s + d - s * d })
    StXor => ref_hp_blend1(r, g, b, a, dr, dg, db, da, fn(s, d, sa, da) { s * (1.0 - da) + d * (1.0 - sa) })
    StPlus => ref_hp_blend1(r, g, b, a, dr, dg, db, da, fn(s, d, _sa, _da) { smin(s + d, 1.0) })
    StDarken => ref_hp_blend2(r, g, b, a, dr, dg, db, da, fn(s, d, sa, da) { s + d - smax(s * da, d * sa) })
    StLighten => ref_hp_blend2(r, g, b, a, dr, dg, db, da, fn(s, d, sa, da) { s + d - smin(s * da, d * sa) })
    StDifference =>
      ref_hp_blend2(r, g, b, a, dr, dg, db, da, fn(s, d, sa, da) {
        let m = smin(s * da, d * sa)
        s + d - (m + m)
      })
    StExclusion =>
      ref_hp_blend2(r, g, b, a, dr, dg, db, da, fn(s, d, _sa, _da) {
        let m = s * d
        s + d - (m + m)
      })
    StColorBurn =>
      ref_hp_blend2(r, g, b, a, dr, dg, db, da, fn(s, d, sa, da) {
        if d == da {
          d + s * (1.0 - da)
        } else if s == 0.0 {
          d * (1.0 - sa)
        } else {
          sa * (da - smin(da, (da - d) * sa * (1.0 / s))) + s * (1.0 - da) + d * (1.0 - sa)
        }
      })
    StColorDodge =>
      ref_hp_blend2(r, g, b, a, dr, dg, db, da, fn(s, d, sa, da) {
        if d == 0.0 {
          s * (1.0 - da)
        } else if s == sa {
          s + d * (1.0 - sa)
        } else {
          sa * smin(da, d * sa * (1.0 / (sa - s))) + s * (1.0 - da) + d * (1.0 - sa)
        }
      })
    StHardLight =>
      ref_hp_blend2(r, g, b, a, dr, dg, db, da, fn(s, d, sa, da) {
        s * (1.0 - da) +
        d * (1.0 - sa) +
        (if s + s <= sa {
          let m = s * d
          m + m
        } else {
          let m = (da - d) * (sa - s)
          sa * da - (m + m)
        })
      })
    StOverlay =>
      ref_hp_blend2(r, g, b, a, dr, dg, db, da, fn(s, d, sa, da) {
        s * (1.0 - da) +
        d * (1.0 - sa) +
        (if d + d <= da {
          let m = s * d
          m + m
        } else {
          let m = (da - d) * (sa - s)
          sa * da - (m + m)
        })
      })
    StSoftLight =>
      ref_hp_blend2(r, g, b, a, dr, dg, db, da, fn(s, d, sa, da) {
        let m : Float = if da > 0.0 { d / da } else { 0.0 }
        let s2 = s + s
        let m4 = m + m + (m + m)
        let dark_src = d * (sa + (s2 - sa) * (1.0 - m))
        let dark_dst = (m4 * m4 + m4) * (m - 1.0) + 7.0 * m
        let lite_dst = m.sqrt() - m
        let d4 = d + d + (d + d)
        let lite_src = d * sa + da * (s2 - sa) * (if d4 <= da { dark_dst } else { lite_dst })
        s * (1.0 - da) + d * (1.0 - sa) + (if s2 <= sa { dark_src } else { lite_src })
      })
    _ => @halt.saying("ref_hp_blend_stage: unexpected stage")
  }
}

///|
test "highp inlined blend stages match closure reference bit-for-bit" {
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
    StDifference,
    StExclusion,
    StColorBurn,
    StColorDodge,
    StHardLight,
    StOverlay,
    StSoftLight,
  ]
  let vals : Array[Float] = [0.0, 0.05, 0.25, 0.5, 0.75, 0.95, 1.0, 0.37]
  let pm = Pixmap::new(8, 1).unwrap()
  let ctx = Context::new()
  for st in stages {
    for batch in 0..<4 {
      let r = FixedArray::make(8, (0.0 : Float))
      let g = FixedArray::make(8, (0.0 : Float))
      let b = FixedArray::make(8, (0.0 : Float))
      let a = FixedArray::make(8, (0.0 : Float))
      let dr = FixedArray::make(8, (0.0 : Float))
      let dg = FixedArray::make(8, (0.0 : Float))
      let db = FixedArray::make(8, (0.0 : Float))
      let da = FixedArray::make(8, (0.0 : Float))
      let rr = FixedArray::make(8, (0.0 : Float))
      let rg = FixedArray::make(8, (0.0 : Float))
      let rb = FixedArray::make(8, (0.0 : Float))
      let ra = FixedArray::make(8, (0.0 : Float))
      let rdr = FixedArray::make(8, (0.0 : Float))
      let rdg = FixedArray::make(8, (0.0 : Float))
      let rdb = FixedArray::make(8, (0.0 : Float))
      let rda = FixedArray::make(8, (0.0 : Float))
      for i in 0..<8 {
        let idx = batch * 8 + i
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
      let p : HighP = {
        r,
        g,
        b,
        a,
        dr,
        dg,
        db,
        da,
        tail: 8,
        dx: 0,
        dy: 0,
        ctx,
        mask_ctx: mask_none,
        aa_mask_ctx: aa_mask_none,
        src: empty_src,
        dst: pm.as_subpixmap(),
      }
      assert_true(p.stage(st))
      ref_hp_blend_stage(st, rr, rg, rb, ra, rdr, rdg, rdb, rda)
      for i in 0..<8 {
        assert_eq(p.r[i].reinterpret_as_uint(), rr[i].reinterpret_as_uint())
        assert_eq(p.g[i].reinterpret_as_uint(), rg[i].reinterpret_as_uint())
        assert_eq(p.b[i].reinterpret_as_uint(), rb[i].reinterpret_as_uint())
        assert_eq(p.a[i].reinterpret_as_uint(), ra[i].reinterpret_as_uint())
      }
    }
  }
}

///|
test "Pixmap::apply_mask direct loop matches DestinationIn lowp math byte-for-byte" {
  let w = 23
  let h = 5
  let pm_fast = Pixmap::new(w, h).unwrap()
  let pm_ref = Pixmap::new(w, h).unwrap()
  fill_pattern_pixmap(pm_fast)
  fill_pattern_pixmap(pm_ref)
  let mask = Mask::new(w, h).unwrap()
  for i in 0..<(w * h) {
    mask.data[i] = match i % 4 {
      0 => b'\x00'
      1 => b'\xFF'
      _ => ((i * 53 + 17) % 256).to_byte()
    }
  }
  pm_fast.apply_mask(mask)
  for i in 0..<(w * h) {
    let sa = mask.data[i].to_int()
    let o = i * 4
    pm_ref.data[o] = (div255(mul16(pm_ref.data[o].to_int(), sa)) & 0xFF).to_byte()
    pm_ref.data[o + 1] = (div255(mul16(pm_ref.data[o + 1].to_int(), sa)) & 0xFF).to_byte()
    pm_ref.data[o + 2] = (div255(mul16(pm_ref.data[o + 2].to_int(), sa)) & 0xFF).to_byte()
    pm_ref.data[o + 3] = (div255(mul16(pm_ref.data[o + 3].to_int(), sa)) & 0xFF).to_byte()
  }
  assert_bytes_eq(pm_fast.data, pm_ref.data)
}

///|
test "highp gather-translate edge cases: subpixmap offset/stride, non-unit cov, 1x1/1xN/Nx1 src" {
  // Non-zero SubPixmap offset and real_width != width
  let src = Pixmap::new(9, 5).unwrap()
  fill_pattern_pixmap(src)
  let backing_fast = Pixmap::new(30, 14).unwrap()
  let backing_ref = Pixmap::new(30, 14).unwrap()
  fill_pattern_pixmap(backing_fast)
  fill_pattern_pixmap(backing_ref)
  let sub_rect = IntRect::from_xywh(4, 3, 19, 8).unwrap()
  let sub_fast = backing_fast.subpixmap(sub_rect).unwrap()
  let sub_ref = backing_ref.subpixmap(sub_rect).unwrap()
  let blit_rect = ScreenIntRect::from_xywh(1, 1, 17, 6).unwrap()
  let covs : Array[Float] = [
    0.55,
    -0.5,
    1.75,
    Float::reinterpret_from_uint(0x7fc00000U), // NaN
  ]
  for cov in covs {
    for stages in [
      [SeedShader, StTransform, Gather, Scale1Float, Store],
      [SeedShader, StTransform, Gather, Scale1Float, SourceOverRgba],
    ] {
      let ctx = Context::new()
      ctx.transform = Transform::from_translate(-3.0, -2.0)
      ctx.current_coverage = cov
      highp_start(stages, blit_rect, aa_mask_none, mask_none, ctx, src, sub_fast)
      highp_start_generic(stages, blit_rect, aa_mask_none, mask_none, ctx, src, sub_ref)
      assert_bytes_eq(backing_fast.data, backing_ref.data)
    }
  }

  // 1x1, 1x5, 5x1 sources
  for dims in [(1, 1), (1, 5), (5, 1)] {
    let (sw, sh) = dims
    let s = Pixmap::new(sw, sh).unwrap()
    fill_pattern_pixmap(s)
    let df = Pixmap::new(11, 7).unwrap()
    let dr = Pixmap::new(11, 7).unwrap()
    fill_pattern_pixmap(df)
    fill_pattern_pixmap(dr)
    let ctx = Context::new()
    ctx.transform = Transform::from_translate(-2.0, -1.0)
    ctx.current_coverage = 0.65
    let r = ScreenIntRect::from_xywh(0, 0, 11, 7).unwrap()
    for stages in [
      [SeedShader, StTransform, Gather, Store],
      [SeedShader, StTransform, Gather, SourceOverRgba],
      [SeedShader, StTransform, Gather, Scale1Float, SourceOverRgba],
    ] {
      highp_start(stages, r, aa_mask_none, mask_none, ctx, s, df.as_subpixmap())
      highp_start_generic(stages, r, aa_mask_none, mask_none, ctx, s, dr.as_subpixmap())
      assert_bytes_eq(df.data, dr.data)
    }
  }
}

///|
test "Pixmap::draw_pixmap fast path matches generic highp pipeline byte-for-byte" {
  let src = Pixmap::new(17, 9).unwrap()
  fill_pattern_pixmap(src)
  for i in 0..<17 {
    src.data[i * 4] = b'\x00'
    src.data[i * 4 + 1] = b'\x00'
    src.data[i * 4 + 2] = b'\x00'
    src.data[i * 4 + 3] = b'\x00'
  }
  let modes : Array[BlendMode] = [SourceOver, Source]
  let opacities : Array[Float] = [1.0, 0.55, 0.0]
  let offsets : Array[(Int, Int)] = [(0, 0), (5, 3), (-4, -2), (18, 6)]
  for mode in modes {
    for opacity in opacities {
      for off in offsets {
        let (ox, oy) = off
        let dst_fast = Pixmap::new(25, 13).unwrap()
        let dst_ref = Pixmap::new(25, 13).unwrap()
        fill_pattern_pixmap(dst_fast)
        fill_pattern_pixmap(dst_ref)
        let pp : PixmapPaint = { opacity, blend_mode: mode, quality: Bilinear }
        dst_fast.draw_pixmap(ox, oy, src, pp, Transform::identity(), None)
        // Independent reference: build stages explicitly and invoke highp_start_generic directly
        let pb = RasterPipelineBuilder::new()
        let patt = Pattern::new(src, Pad, Bilinear, opacity, Transform::from_translate(fi(ox), fi(oy)))
        assert_true(patt.push_stages(Linear, pb))
        if mode == SourceOver {
          pb.push(SourceOverRgba)
        } else {
          pb.push(Store)
        }
        let rp = pb.compile()
        assert_true(!rp.low)
        let src_rect = src.size().to_int_rect(ox, oy)
        let dst_bounds = dst_ref.size().to_screen_int_rect(0, 0).to_int_rect()
        match src_rect.intersect(dst_bounds) {
          Some(ir) =>
            match ir.to_screen_int_rect() {
              Some(sr) => highp_start_generic(rp.stages, sr, aa_mask_none, mask_none, rp.ctx, src, dst_ref.as_subpixmap())
              None => ()
            }
          None => ()
        }
        assert_bytes_eq(dst_fast.data, dst_ref.data)
      }
    }
  }
}

///|
/// Reference allocating bilinear (n=2) / bicubic (n=4) sampler matching original implementation.
fn ref_sampler(
  src : Pixmap,
  ctx : Context,
  n : Int,
  r : FixedArray[Float],
  g : FixedArray[Float],
  b : FixedArray[Float],
  a : FixedArray[Float],
) -> Unit {
  let cx = FixedArray::makei(8, fn(i) { r[i] })
  let cy = FixedArray::makei(8, fn(i) { g[i] })
  let wx = Array::makei(n, fn(_) { FixedArray::make(8, (0.0 : Float)) })
  let wy = Array::makei(n, fn(_) { FixedArray::make(8, (0.0 : Float)) })
  for i in 0..<8 {
    let fx = (cx[i] + 0.5) - lfloor(cx[i] + 0.5)
    let fy = (cy[i] + 0.5) - lfloor(cy[i] + 0.5)
    if n == 2 {
      wx[0][i] = 1.0 - fx
      wx[1][i] = fx
      wy[0][i] = 1.0 - fy
      wy[1][i] = fy
    } else {
      wx[0][i] = bicubic_far(1.0 - fx)
      wx[1][i] = bicubic_near(1.0 - fx)
      wx[2][i] = bicubic_near(fx)
      wx[3][i] = bicubic_far(fx)
      wy[0][i] = bicubic_far(1.0 - fy)
      wy[1][i] = bicubic_near(1.0 - fy)
      wy[2][i] = bicubic_near(fy)
      wy[3][i] = bicubic_far(fy)
    }
  }
  for i in 0..<8 {
    r[i] = 0.0
    g[i] = 0.0
    b[i] = 0.0
    a[i] = 0.0
  }
  let start : Float = if n == 2 { -0.5 } else { -1.5 }
  let ys = FixedArray::makei(8, fn(i) { cy[i] + start })
  let w_ulp = ulp_sub(fi(src.width))
  let h_ulp = ulp_sub(fi(src.height))
  let inv255 : Float = 1.0 / 255.0
  for j in 0..<n {
    let xs = FixedArray::makei(8, fn(i) { cx[i] + start })
    for k in 0..<n {
      for i in 0..<8 {
        let tx = tile(xs[i], ctx.sampler_spread, fi(src.width), ctx.sampler_inv_width)
        let ty = tile(ys[i], ctx.sampler_spread, fi(src.height), ctx.sampler_inv_height)
        let x = smin(smax(tx, 0.0), w_ulp)
        let y = smin(smax(ty, 0.0), h_ulp)
        let o = (trunc_int(y) * src.width + trunc_int(x)) * 4
        let w = wx[k][i] * wy[j][i]
        r[i] = w * (fi(src.data[o].to_int()) * inv255) + r[i]
        g[i] = w * (fi(src.data[o + 1].to_int()) * inv255) + g[i]
        b[i] = w * (fi(src.data[o + 2].to_int()) * inv255) + b[i]
        a[i] = w * (fi(src.data[o + 3].to_int()) * inv255) + a[i]
        xs[i] = xs[i] + 1.0
      }
    }
    for i in 0..<8 {
      ys[i] = ys[i] + 1.0
    }
  }
}

///|
test "highp allocation-free sampler matches reference bit-for-bit across Pad/Repeat/Reflect and tails" {
  let src = Pixmap::new(8, 7).unwrap()
  fill_pattern_pixmap(src)
  let spreads : Array[SpreadMode] = [Pad, Repeat, Reflect]
  let ts = Transform::from_scale(1.7, 1.3).post_rotate(15.0).invert().unwrap()
  let pm = Pixmap::new(19, 13).unwrap()
  for spread in spreads {
    for n in [2, 4] {
      for tail in [1, 3, 5, 8] {
        let ctx = Context::new()
        ctx.sampler_spread = spread
        ctx.sampler_inv_width = 1.0 / fi(src.width)
        ctx.sampler_inv_height = 1.0 / fi(src.height)
        ctx.transform = ts
        let r = FixedArray::make(8, (0.0 : Float))
        let g = FixedArray::make(8, (0.0 : Float))
        let b = FixedArray::make(8, (0.0 : Float))
        let a = FixedArray::make(8, (0.0 : Float))
        let rr = FixedArray::make(8, (0.0 : Float))
        let rg = FixedArray::make(8, (0.0 : Float))
        let rb = FixedArray::make(8, (0.0 : Float))
        let ra = FixedArray::make(8, (0.0 : Float))
        for i in 0..<8 {
          let sx = fi(3 + i) + 0.5
          let sy = fi(5) + 0.5
          let tx = sx * ts.sx + (sy * ts.kx + ts.tx)
          let ty = sx * ts.ky + (sy * ts.sy + ts.ty)
          r[i] = tx
          g[i] = ty
          rr[i] = tx
          rg[i] = ty
        }
        let p : HighP = {
          r,
          g,
          b,
          a,
          dr: FixedArray::make(8, 0.0),
          dg: FixedArray::make(8, 0.0),
          db: FixedArray::make(8, 0.0),
          da: FixedArray::make(8, 0.0),
          tail,
          dx: 3,
          dy: 5,
          ctx,
          mask_ctx: mask_none,
          aa_mask_ctx: aa_mask_none,
          src,
          dst: pm.as_subpixmap(),
        }
        p.sampler(n)
        ref_sampler(src, ctx, n, rr, rg, rb, ra)
        for i in 0..<tail {
          assert_eq(p.r[i].reinterpret_as_uint(), rr[i].reinterpret_as_uint())
          assert_eq(p.g[i].reinterpret_as_uint(), rg[i].reinterpret_as_uint())
          assert_eq(p.b[i].reinterpret_as_uint(), rb[i].reinterpret_as_uint())
          assert_eq(p.a[i].reinterpret_as_uint(), ra[i].reinterpret_as_uint())
        }
      }
    }
  }
}
