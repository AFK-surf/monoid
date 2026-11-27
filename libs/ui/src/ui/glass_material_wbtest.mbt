// The window's glass material (liquid, frosted, solid) and the system's increase contrast, as every glass surface is
// painted with them (glass.mbt material_glass and effective_glass, view_host.mbt's blocks made again as they change).

///|
test "material_glass: liquid and solid keep each surface's own recipe, frosted glass stays as it is" {
  let liq = Glass::liquid(blur=2.0, tint=0xFFFFFF1AL, solid=0x1C1C1EFFL, refraction=10.0, rim=0.55)
  assert_eq(material_glass(liq, Liquid), liq)
  assert_eq(material_glass(liq, Solid), liq)
  let fr = Glass::frosted(blur=10.0, tint=0xFFFFFF80L, solid=0xF5F5F7FFL, rim_edge=0.2)
  assert_eq(material_glass(fr, Frosted), fr)
  let prog = Glass::frosted(blur=8.0, tint=0xFFFFFF40L, solid=0xFFFFFFFFL, progressive=true)
  assert_eq(material_glass(prog, Frosted), prog)
  // a clear magnifying lens keeps magnifying
  let lens = Glass::liquid(blur=0.0, tint=0xFFFFFF00L, zoom=1.5, refraction=14.0)
  assert_eq(material_glass(lens, Frosted), lens)
}

///|
test "material_glass: frosted makes liquid glass flat frosted glass, none of its shading left" {
  let liq = Glass::liquid(
    blur=2.0,
    tint=0xFFFFFF1AL,
    solid=0x1C1C1EFFL,
    refraction=10.0,
    rim=0.55,
    bezel=14.0,
    chroma=0.06,
    merge=12.0,
    adaptive=true,
    spot=Some((4.0, 4.0)),
  )
  let out = material_glass(liq, Frosted)
  assert_false(out.liquid)
  assert_eq(out.blur, 14.0)
  assert_eq(out.saturation, 1.65)
  // alpha 0.102 -> 0.102 + (0.90 - 0.102) * 0.22 = 0.278 (71); red 0.11 toward the solid's: 255 + (28 - 255) * 0.11 = 230
  assert_eq((out.tint & 0xFFL).to_int(), 71)
  assert_eq(((out.tint >> 24) & 0xFFL).to_int(), 230)
  assert_eq((out.rim, out.bezel, out.refraction, out.chroma, out.merge), (0.0, 0.0, 0.0, 0.0, 0.0))
  assert_eq((out.adaptive, out.spot, out.droplet_role, out.layer), (false, None, 0, 0))
  assert_eq(out.rim_edge, 0.0)
  assert_eq(out.solid, liq.solid)
  // a deeper blur kept, and desaturated media viewer recipes keep their low saturation
  let panel = Glass::liquid(blur=30.0, tint=0xFDFCFD80L, solid=0xF7F7FAFFL, saturation=0.55, refraction=16.0)
  let panel_out = material_glass(panel, Frosted)
  assert_eq(panel_out.blur, 30.0)
  assert_eq(panel_out.saturation, 0.55)
  // a clear droplet takes its solid ground's colour, frosted as the rest
  let drop = Glass::liquid(blur=0.0, tint=0xFFFFFF00L, solid=0x1C1C1EFFL, refraction=9.0, droplet_role=2)
  let d = material_glass(drop, Frosted)
  assert_false(d.liquid)
  assert_eq(d.droplet_role, 0)
  assert_eq(d.tint, 0x1C1C1E32L)
}

///|
test "effective_glass: no contrast leaves glass as it is, clear lenses and progressive edges stay with contrast" {
  let liq = Glass::liquid()
  assert_eq(effective_glass(liq, false), liq)
  let lens = Glass::liquid(blur=0.0, tint=0xFFFFFF00L, zoom=1.5, refraction=14.0)
  assert_eq(effective_glass(lens, true), lens)
  let prog = Glass::frosted(blur=8.0, tint=0xFFFFFF40L, solid=0xFFFFFFFFL, progressive=true)
  assert_eq(effective_glass(prog, true), prog)
}

///|
test "effective_glass: increase contrast boosts tint alpha and rim/rim_edge highlights, on liquid and frosted glass" {
  let liq = Glass::liquid(blur=2.0, tint=0xFFFFFF1AL, solid=0xECECF0FFL, rim=0.5)
  let out_l = effective_glass(liq, true)
  assert_true((out_l.tint & 0xFFL) > (liq.tint & 0xFFL))
  assert_true((out_l.rim - 0.745).abs() < 0.01, msg="liquid rim=\{out_l.rim}")
  let fr = Glass::frosted(blur=16.0, tint=0xFFFFFF60L, solid=0xECECF0FFL, rim_edge=0.2)
  let out_f = effective_glass(fr, true)
  assert_true((out_f.tint & 0xFFL) > (fr.tint & 0xFFL))
  assert_eq(out_f.blur, 16.0)
  assert_true((out_f.rim_edge - 0.35).abs() < 0.01, msg="frosted rim_edge=\{out_f.rim_edge}")
  // liquid glass made frosted, then contrast: denser still, its hairline lit more
  let frosted = material_glass(liq, Frosted)
  let both = effective_glass(frosted, true)
  assert_true((both.tint & 0xFFL) > (frosted.tint & 0xFFL))
  assert_true(both.rim_edge > frosted.rim_edge)
  assert_eq(both.blur, 14.0)
}

///|
test "effective_glass: increase contrast zeroes chroma on regular liquid glass, never on droplets" {
  let panel = Glass::liquid(blur=6.0, tint=0xFDFCFDBFL, solid=0xFFFFFFFFL, bezel=20.0, refraction=26.0, rim=0.6, chroma=0.03)
  assert_eq(effective_glass(panel, true).chroma, 0.0)
  let drop = Glass::liquid(blur=0.0, tint=0xFFFFFF00L, solid=0xFFFFFFFFL, refraction=9.0, chroma=0.04, droplet_role=2)
  assert_eq(effective_glass(drop, true).chroma, 0.04)
}

///|
test "glass_material: blocks made again as the material and contrast change, Solid draws solid grounds" {
  let t = Tester::tree(w=400.0, h=300.0, fn(root) {
    root.box(fn(b) {
      b
      .width(Is(Some(120.0)))
      .height(Is(Some(60.0)))
      .glass(Is(Some(Glass::liquid(blur=2.0, tint=0xFFFFFF1AL, solid=0xECECF0FFL, refraction=10.0, rim=0.5))))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_eq(glass_material(), Liquid)
  let find_glass = fn() -> (Double, Double, Double, Double)? {
    let c = the_ctx.val
    let n = c.ninst
    for i in 0..<n {
      let b = i * inst_size
      if c.inst[b + 5] == 6.0 || c.inst[b + 5] == 5.0 {
        return Some((c.inst[b + 5], c.inst[b + 7], c.inst[b + 11], c.inst[b + 12]))
      }
    }
    None
  }
  guard find_glass() is Some((kind0, blur0, alpha0, rim0)) else { fail("expected liquid glass instance") }
  assert_eq(kind0, 6.0)
  assert_true((blur0 - 2.0).abs() < 0.01)

  // Frosted: the cached block made again as flat frosted glass (kind 5), blurred deep, denser
  set_glass_material(Frosted)
  t.draw()
  assert_eq(glass_material(), Frosted)
  guard find_glass() is Some((kind_f, blur_f, alpha_f, rim_f)) else { fail("expected frosted glass instance") }
  assert_eq(kind_f, 5.0)
  assert_true((blur_f - 14.0).abs() < 0.01, msg="frosted blur=\{blur_f}")
  assert_true(alpha_f > alpha0 + 0.15, msg="alpha did not rise: \{alpha0} -> \{alpha_f}")
  assert_eq(rim_f, 0.0)
  // its hairline round it: a ring of no fill over its edge, dark round light glass
  let ring = the_ctx.val.inst
  let mut ringed = false
  for i in 0..<the_ctx.val.ninst {
    let b = i * inst_size
    if ring[b + 5] == 0.0 && ring[b + 6] == frosted_ring_w && ring[b + 2] == 120.0 && ring[b + 12] == 0.0 && ring[b + 15] > 0.08 {
      ringed = true
    }
  }
  assert_true(ringed, msg="frosted glass must be ringed by its hairline")

  // Increase Contrast: made again with a stronger rim and alpha
  t.set_increase_contrast(true)
  t.draw()
  guard find_glass() is Some((_, _, alpha_c, rim_c)) else { fail("expected glass instance under contrast") }
  assert_true(alpha_c > alpha_f, msg="contrast should raise alpha: \{alpha_f} -> \{alpha_c}")
  assert_true(rim_c > rim_f + 0.1, msg="contrast should boost the hairline: \{rim_f} -> \{rim_c}")

  // Solid: no glass instance, its solid ground instead
  set_glass_material(Solid)
  t.draw()
  assert_true(the_ctx.val.glass_solid(), msg="Solid should make glass_solid")
  assert_true(find_glass() is None, msg="Solid should draw a solid rect instead of glass")

  // the app's set_glass_solid(Some(false)) still overrides Solid
  set_glass_solid(Some(false))
  t.draw()
  assert_false(the_ctx.val.glass_solid())
  assert_true(find_glass() is Some(_))
  set_glass_solid(None)

  // back to Liquid: the surface's own recipe again
  set_glass_material(Liquid)
  t.set_increase_contrast(false)
  t.draw()
  guard find_glass() is Some((kind_b, blur_b, alpha_b, rim_b)) else { fail("expected liquid glass instance again") }
  assert_eq((kind_b, blur_b, alpha_b, rim_b), (kind0, blur0, alpha0, rim0))
}

///|
test "droplet_role: slot 7 packing survives at_strength while slot 21 scales linearly, public clear stays 0.0" {
  let roles : Array[(Int, Double, Double)] = [
    (1, -16.0, 3.0),
    (2, -32.0, 9.0),
    (3, -48.0, 9.0),
    (4, -64.0, 9.0),
  ]
  for entry in roles {
    let (role, exp_slot7, base_refr) = entry
    let base = Glass::liquid(blur=0.0, tint=0xFFFFFF00L, refraction=base_refr, droplet_role=role)
    for s in [0.5, 0.8, 1.0] {
      let scaled = base.at_strength(s)
      assert_eq(scaled.droplet_role, role)
      let t = Tester::tree(w=200.0, h=120.0, fn(root) {
        root.box(fn(b) {
          b.width(Is(Some(80.0))).height(Is(Some(40.0))).glass(Is(Some(scaled))) |> ignore
        }) |> ignore
      })
      t.draw()
      let c = the_ctx.val
      let mut found = false
      for i in 0..<c.ninst {
        let b = i * inst_size
        if c.inst[b + 5] == 6.0 {
          assert_true((c.inst[b + 7] - exp_slot7).abs() < 0.001, msg="role=\{role} s=\{s} slot7=\{c.inst[b + 7]}")
          assert_true((c.inst[b + 21] - base_refr * s).abs() < 0.01, msg="role=\{role} s=\{s} refr=\{c.inst[b + 21]}")
          found = true
          break
        }
      }
      assert_true(found, msg="expected kind 6 for role=\{role} s=\{s}")
    }
  }
  // Public Glass::liquid(blur=0, tint=0xFFFFFF00, refraction=9.0) must emit slot 7 == 0.0 (default path)
  let pub_gl = Glass::liquid(blur=0.0, tint=0xFFFFFF00L, refraction=9.0)
  let t_pub = Tester::tree(w=200.0, h=120.0, fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(80.0))).height(Is(Some(40.0))).glass(Is(Some(pub_gl))) |> ignore
    }) |> ignore
  })
  t_pub.draw()
  let c = the_ctx.val
  let mut found_pub = false
  for i in 0..<c.ninst {
    let b = i * inst_size
    if c.inst[b + 5] == 6.0 {
      assert_true(c.inst[b + 7].abs() < 0.001, msg="public clear must keep slot7=0.0, got \{c.inst[b + 7]}")
      found_pub = true
      break
    }
  }
  assert_true(found_pub)
}

///|
test "droplet_role: liquid keeps the clear switch lens (slot7=-32), frosted makes it flat frosted glass, contrast frosts it, Solid makes it solid" {
  let sw_gl = Glass::liquid(blur=0.0, tint=0xFFFFFF00L, solid=0xFFFFFFFFL, refraction=9.0, rim=1.0, bezel=9.0, droplet_role=2)
  let t = Tester::tree(w=200.0, h=120.0, fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(60.0))).height(Is(Some(38.0))).glass(Is(Some(sw_gl))) |> ignore
    }) |> ignore
  })
  let find_glass = fn() -> (Double, Double, Double)? {
    let c = the_ctx.val
    for i in 0..<c.ninst {
      let b = i * inst_size
      if c.inst[b + 5] == 6.0 || c.inst[b + 5] == 5.0 {
        return Some((c.inst[b + 7], c.inst[b + 11], c.inst[b + 5]))
      }
    }
    None
  }
  set_glass_material(Liquid)
  t.set_increase_contrast(false)
  t.draw()
  guard find_glass() is Some((slot7_0, alpha_0, _)) else { fail("expected switch glass") }
  assert_true((slot7_0 - -32.0).abs() < 0.001, msg="liquid must keep slot7=-32.0, got \{slot7_0}")
  assert_true(alpha_0 < 0.001, msg="liquid must keep clear alpha=0, got \{alpha_0}")
  // Frosted: a flat frosted pill (kind 5) like every other surface, blur 14 in slot 7, denser tint
  set_glass_material(Frosted)
  t.draw()
  guard find_glass() is Some((slot7_f, alpha_f, kind_f)) else { fail("expected frosted switch glass") }
  assert_eq(kind_f, 5.0)
  assert_true((slot7_f - 14.0).abs() < 0.01, msg="frosted slot7=\{slot7_f}")
  assert_true(alpha_f > 0.15, msg="frosted alpha=\{alpha_f}")
  // back to Liquid: the crystal droplet again
  set_glass_material(Liquid)
  t.draw()
  guard find_glass() is Some((slot7_back, alpha_back, _)) else { fail("expected switch glass restored") }
  assert_true((slot7_back - -32.0).abs() < 0.001, msg="restored slot7=\{slot7_back}")
  assert_true(alpha_back < 0.001, msg="restored alpha=\{alpha_back}")
  // Increase Contrast disables crystal droplet mode -> positive blur & tint alpha
  t.set_increase_contrast(true)
  t.draw()
  guard find_glass() is Some((slot7_c, alpha_c, _)) else { fail("expected frosted glass under contrast=true") }
  assert_true(slot7_c > 0.5, msg="contrast=true should yield positive blur, got \{slot7_c}")
  assert_true(alpha_c > 0.15, msg="contrast=true should raise tint alpha, got \{alpha_c}")
  t.set_increase_contrast(false)
  // Solid -> opaque solid, zero kind 6 glass instances
  set_glass_material(Solid)
  t.draw()
  assert_true(find_glass() is None, msg="Solid must emit zero glass instances")
  set_glass_material(Liquid)
}

///|
test "slot 21: a negative refraction is written as 0.0 (the renderers' reach of what is outside the glass never goes inward), a positive one as it is" {
  for entry in [(-20.0, 0.0), (-0.5, 0.0), (0.0, 0.0), (16.0, 16.0)] {
    let (refraction, want) = entry
    let gl = Glass::liquid(blur=14.0, tint=0xFDFCFD80L, refraction~)
    let t = Tester::tree(w=200.0, h=120.0, fn(root) {
      root.box(fn(b) { b.width(Is(Some(80.0))).height(Is(Some(40.0))).glass(Is(Some(gl))) |> ignore })
      |> ignore
    })
    t.draw()
    let c = the_ctx.val
    let mut found = false
    for i in 0..<c.ninst {
      let b = i * inst_size
      if c.inst[b + 5] == 6.0 {
        assert_true(c.inst[b + 21] == want, msg="refraction=\{refraction} slot21=\{c.inst[b + 21]}")
        found = true
        break
      }
    }
    assert_true(found, msg="expected kind 6 for refraction=\{refraction}")
  }
}


///|
test "material_lens: a morphing surface's content lens kept whole in liquid glass, its defocus alone in frosted, none in solid" {
  let lens : @paint.ContentLens = { blur: 4.0, refraction: 3.0, bezel: 24.0, alpha: 0.6 }
  let t = Tester::tree(w=300.0, h=200.0, fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(160.0))).height(Is(Some(80.0))).content_lens(Is(lens)) |> ignore
      b.box(fn(w) { w.words(Is("held"), ink=0x222222FFL) |> ignore }) |> ignore
    })
    |> ignore
  })
  let lenses = fn() -> Int {
    let c = the_ctx.val
    let mut n = 0
    for i in 0..<c.ninst {
      if c.inst[i * inst_size + 5] == 8.0 {
        n += 1
      }
    }
    n
  }
  set_glass_material(Liquid)
  t.draw()
  assert_true(lenses() > 0, msg="liquid keeps the lens")
  assert_eq(material_lens(lens), lens)
  set_glass_material(Frosted)
  t.draw()
  assert_true(lenses() > 0, msg="frosted keeps its defocus")
  assert_eq(material_lens(lens), { ..lens, refraction: 0.0, bezel: 0.0 })
  set_glass_material(Solid)
  t.draw()
  assert_eq(lenses(), 0, msg="solid draws what it holds as it is")
  assert_eq(material_lens(lens), @paint.ContentLens::none())
  set_glass_material(Liquid)
}

///|
test "material_glass: frosted shares local unblocked captures (same blur, dy_gap <= 64) while isolating separated or overlapping layers" {
  let shared_liq = Glass::liquid(blur=1.1, tint=0xF7F7FA66L, solid=0xF7F7FAFFL, refraction=20.0).sharing()
  let t = Tester::tree(w=400.0, h=600.0, fn(root) {
    root.box(fn(top_row) {
      top_row.row(Is(true)).gap(Is(12.0)) |> ignore
      top_row.box(fn(p1) {
        p1.width(Is(Some(100.0))).height(Is(Some(40.0))).glass(Is(Some(shared_liq))) |> ignore
        p1.box(fn(w) { w.words(Is("Left"), ink=0x111111FFL) |> ignore }) |> ignore
      })
      |> ignore
      top_row.box(fn(p2) {
        p2.width(Is(Some(100.0))).height(Is(Some(40.0))).glass(Is(Some(shared_liq))) |> ignore
        p2.box(fn(w) { w.words(Is("Right"), ink=0x111111FFL) |> ignore }) |> ignore
      })
      |> ignore
    })
    |> ignore
    root.box(fn(overlay) {
      overlay
      .over(Is(true))
      .offset(Is((0.0, 0.0)))
      .width(Is(Some(120.0)))
      .height(Is(Some(60.0)))
      .glass(Is(Some(shared_liq)))
      |> ignore
    })
    |> ignore
    root.box(fn(mid) {
      mid.width(Is(Some(400.0))).height(Is(Some(300.0))).ground(Is(0x3366CCFFL)) |> ignore
    })
    |> ignore
    root.box(fn(bot) {
      bot.width(Is(Some(120.0))).height(Is(Some(40.0))).glass(Is(Some(shared_liq))) |> ignore
    })
    |> ignore
  })
  set_glass_material(Frosted)
  t.draw()
  let gs = t.drawn_glass()
  assert_eq(gs.length(), 4, msg="expected 4 frosted glass surfaces")
  assert_eq((gs[0].4, gs[1].4, gs[2].4, gs[3].4), (5, 5, 5, 5))
  assert_eq(gs[0].5, gs[1].5, msg="adjacent top-bar frosted pills should share 1 capture: \{gs[0].5} vs \{gs[1].5}")
  assert_true(gs[2].5 != gs[0].5, msg="overlapping frosted overlay must not share capture at dy_gap=0: \{gs[2].5} vs \{gs[0].5}")
  assert_true(gs[3].5 != gs[0].5 && gs[3].5 != gs[2].5, msg="separated bottom frosted surface must take its own capture")
  set_glass_material(Liquid)
}
