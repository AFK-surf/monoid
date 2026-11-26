// The window's glass material (liquid, frosted, solid) and the system's increase contrast, as every glass surface is
// painted with them (glass.mbt effective_glass, view_host.mbt's blocks made again as they change).

///|
test "effective_glass: liquid glass without increase contrast is each surface's own recipe" {
  let liq = Glass::liquid()
  assert_eq(effective_glass(liq, Liquid, false), liq)
  let fr = Glass::frosted(blur=10.0, tint=0xFFFFFF80L, solid=0xF5F5F7FFL, rim_edge=0.2)
  assert_eq(effective_glass(fr, Liquid, false), fr)
  // (solid glass is not drawn as glass: Ctx::glass_solid; its recipe untouched here)
  assert_eq(effective_glass(liq, Solid, false), liq)
}

///|
test "effective_glass: frosted glass blurs deep, tints denser toward its solid ground and bends nothing" {
  let liq = Glass::liquid(blur=2.0, tint=0xFFFFFF1AL, solid=0x1C1C1EFFL, refraction=10.0, rim=0.55, bezel=14.0, chroma=0.06)
  let out = effective_glass(liq, Frosted, false)
  // alpha 0.10 -> 0.10 + (0.94 - 0.10) * 0.5 = 0.52 (133)
  assert_eq((out.tint & 0xFFL).to_int(), 133)
  // red mixed a quarter toward the solid's: 255 + (28 - 255) * 0.25
  assert_eq(((out.tint >> 24) & 0xFFL).to_int(), 198)
  assert_eq(out.blur, 20.0)
  assert_eq(out.refraction, 0.0)
  assert_eq(out.chroma, 0.0)
  // its rim and bezel light kept, as liquid as it was
  assert_eq(out.rim, liq.rim)
  assert_eq(out.bezel, liq.bezel)
  assert_true(out.liquid)
  // a blur deeper than frosted's own kept
  let panel = Glass::liquid(blur=24.0, tint=0xFDFCFD80L, solid=0xF7F7FAFFL, refraction=16.0)
  assert_eq(effective_glass(panel, Frosted, false).blur, 24.0)
  // frosted bars: blurred as deep, tinted as dense
  let bar = Glass::frosted(blur=8.0, tint=0xFFFFFF40L, solid=0xF5F5F7FFL, rim_edge=0.2)
  let out_b = effective_glass(bar, Frosted, false)
  assert_eq(out_b.blur, 20.0)
  assert_true((out_b.tint & 0xFFL) > (bar.tint & 0xFFL))
  assert_eq(out_b.rim_edge, bar.rim_edge)
}

///|
test "effective_glass: clear magnifying lenses and progressive scroll edges stay as they are in every material" {
  let lens = Glass::liquid(blur=0.0, tint=0xFFFFFF00L, zoom=1.5, refraction=14.0)
  let prog = Glass::frosted(blur=8.0, tint=0xFFFFFF40L, solid=0xFFFFFFFFL, progressive=true)
  for m in [Liquid, Frosted] {
    assert_eq(effective_glass(lens, m, true), lens)
    assert_eq(effective_glass(prog, m, true), prog)
    assert_eq(effective_glass(lens, m, false), lens)
    assert_eq(effective_glass(prog, m, false), prog)
  }
}

///|
test "effective_glass: increase contrast boosts tint alpha and rim/rim_edge highlights, on liquid and frosted glass" {
  let liq = Glass::liquid(blur=2.0, tint=0xFFFFFF1AL, solid=0xECECF0FFL, rim=0.5)
  let out_l = effective_glass(liq, Liquid, true)
  assert_true((out_l.tint & 0xFFL) > (liq.tint & 0xFFL))
  assert_true((out_l.rim - 0.745).abs() < 0.01, msg="liquid rim=\{out_l.rim}")
  let fr = Glass::frosted(blur=16.0, tint=0xFFFFFF60L, solid=0xECECF0FFL, rim_edge=0.2)
  let out_f = effective_glass(fr, Liquid, true)
  assert_true((out_f.tint & 0xFFL) > (fr.tint & 0xFFL))
  assert_eq(out_f.blur, 16.0)
  assert_true((out_f.rim_edge - 0.35).abs() < 0.01, msg="frosted rim_edge=\{out_f.rim_edge}")
  // frosted glass and contrast: denser still than frosted alone, its rim lit more
  let frosted = effective_glass(liq, Frosted, false)
  let both = effective_glass(liq, Frosted, true)
  assert_true((both.tint & 0xFFL) > (frosted.tint & 0xFFL))
  assert_true(both.rim > frosted.rim)
  assert_eq(both.blur, 20.0)
}

///|
test "effective_glass: increase contrast zeroes chroma on regular liquid glass, never on droplets" {
  let panel = Glass::liquid(
    blur=6.0,
    tint=0xFDFCFDBFL,
    solid=0xFFFFFFFFL,
    bezel=20.0,
    refraction=26.0,
    rim=0.6,
    chroma=0.03,
  )
  assert_eq(effective_glass(panel, Liquid, true).chroma, 0.0)
  let drop = Glass::liquid(blur=0.0, tint=0xFFFFFF00L, solid=0xFFFFFFFFL, refraction=9.0, chroma=0.04, droplet_role=2)
  assert_eq(effective_glass(drop, Liquid, true).chroma, 0.04)
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
      if c.inst[b + 5] == 6.0 {
        return Some((c.inst[b + 7], c.inst[b + 11], c.inst[b + 12], c.inst[b + 21]))
      }
    }
    None
  }
  guard find_glass() is Some((blur0, alpha0, rim0, refr0)) else { fail("expected liquid glass instance") }
  assert_true((blur0 - 2.0).abs() < 0.01)
  assert_true((refr0 - 10.0).abs() < 0.01)

  // Frosted: the cached block made again, blurred deep, denser, bending nothing
  set_glass_material(Frosted)
  t.draw()
  assert_eq(glass_material(), Frosted)
  guard find_glass() is Some((blur_f, alpha_f, rim_f, refr_f)) else { fail("expected frosted glass instance") }
  assert_true((blur_f - 20.0).abs() < 0.01, msg="frosted blur=\{blur_f}")
  assert_true(alpha_f > alpha0 + 0.3, msg="alpha did not rise: \{alpha0} -> \{alpha_f}")
  assert_eq(refr_f, 0.0)
  assert_true((rim_f - rim0).abs() < 0.01)

  // Increase Contrast: made again with a stronger rim and alpha
  t.set_increase_contrast(true)
  t.draw()
  guard find_glass() is Some((_, alpha_c, rim_c, _)) else { fail("expected glass instance under contrast") }
  assert_true(alpha_c > alpha_f, msg="contrast should raise alpha: \{alpha_f} -> \{alpha_c}")
  assert_true(rim_c > rim_f + 0.1, msg="contrast should boost rim: \{rim_f} -> \{rim_c}")

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
  guard find_glass() is Some((blur_b, alpha_b, _, refr_b)) else { fail("expected liquid glass instance again") }
  assert_eq((blur_b, alpha_b, refr_b), (blur0, alpha0, refr0))
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
test "droplet_role: liquid keeps the clear switch lens (slot7=-32), frosted and contrast frost it, Solid makes it solid" {
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
      if c.inst[b + 5] == 6.0 {
        return Some((c.inst[b + 7], c.inst[b + 11], c.inst[b + 21]))
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
  // Frosted: a frosted pill like every other surface (blur 20 in slot 7, denser tint, no bending)
  set_glass_material(Frosted)
  t.draw()
  guard find_glass() is Some((slot7_f, alpha_f, refr_f)) else { fail("expected frosted switch glass") }
  assert_true((slot7_f - 20.0).abs() < 0.001, msg="frosted slot7=\{slot7_f}")
  assert_true(alpha_f > 0.4, msg="frosted alpha=\{alpha_f}")
  assert_eq(refr_f, 0.0)
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
