// Global liquid/frosted glass frost modulation and system increase-contrast linkage (glass.mbt, view_host.mbt).

///|
test "effective_glass: zero-overhead fast path at frost=0 and contrast=false" {
  let liq = Glass::liquid()
  assert_eq(effective_glass(liq, 0.0, false), liq)
  let fr = Glass::frosted(blur=10.0, tint=0xFFFFFF80L, solid=0xF5F5F7FFL, rim_edge=0.2)
  assert_eq(effective_glass(fr, 0.0, false), fr)
}

///|
test "effective_glass: frost=0.5 raises tint alpha, lifts low blur, and calms refraction" {
  let liq = Glass::liquid(blur=2.0, tint=0xFFFFFF1AL, solid=0x1C1C1EFFL, refraction=10.0, rim=0.55)
  let out = effective_glass(liq, 0.5, false)
  let orig_a = (liq.tint & 0xFFL).to_int()
  let out_a = (out.tint & 0xFFL).to_int()
  assert_true(out_a > orig_a + 80, msg="tint alpha should rise strongly: \{orig_a} -> \{out_a}")
  // RGB mixes 0.25 towards solid (0x1C < 0xFF)
  let out_r = ((out.tint >> 24) & 0xFFL).to_int()
  assert_true(out_r < 255 && out_r > 150, msg="tint red should mix toward solid: \{out_r}")
  // blur lifts from 2.0 towards 14.0 by 0.25 -> 5.0
  assert_true((out.blur - 5.0).abs() < 0.01, msg="blur=\{out.blur}")
  // refraction reduces by 1 - 0.55 * 0.5 = 0.725 -> 7.25
  assert_true((out.refraction - 7.25).abs() < 0.01, msg="refraction=\{out.refraction}")
  // rim unchanged without contrast
  assert_eq(out.rim, liq.rim)
}

///|
test "effective_glass: exempts clear optical magnifying lenses and progressive scroll edges" {
  let lens = Glass::liquid(blur=0.0, tint=0xFFFFFF00L, zoom=1.5, refraction=14.0)
  assert_eq(effective_glass(lens, 0.7, true), lens)
  let prog = Glass::frosted(blur=8.0, tint=0xFFFFFF40L, solid=0xFFFFFFFFL, progressive=true)
  assert_eq(effective_glass(prog, 0.7, true), prog)
}

///|
test "effective_glass: contrast=true boosts tint alpha and rim/rim_edge highlights" {
  let liq = Glass::liquid(blur=2.0, tint=0xFFFFFF1AL, solid=0xECECF0FFL, rim=0.5)
  let out_l = effective_glass(liq, 0.0, true)
  assert_true((out_l.tint & 0xFFL) > (liq.tint & 0xFFL))
  assert_true((out_l.rim - 0.745).abs() < 0.01, msg="liquid rim=\{out_l.rim}")
  let fr = Glass::frosted(blur=16.0, tint=0xFFFFFF60L, solid=0xECECF0FFL, rim_edge=0.2)
  let out_f = effective_glass(fr, 0.0, true)
  assert_true((out_f.tint & 0xFFL) > (fr.tint & 0xFFL))
  assert_eq(out_f.blur, 16.0)
  assert_true((out_f.rim_edge - 0.35).abs() < 0.01, msg="frosted rim_edge=\{out_f.rim_edge}")
}

///|
test "glass_frost: ViewBlock invalidates on frost and contrast changes, and frost=1.0 switches to solid" {
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
  assert_eq(glass_frost(), 0.0)
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
  guard find_glass() is Some((blur0, alpha0, rim0, refr0)) else { fail("expected liquid glass instance at frost=0") }
  assert_true((blur0 - 2.0).abs() < 0.01)
  assert_true((refr0 - 10.0).abs() < 0.01)

  // Raise frost to 0.5: cached ViewBlock must rebuild with higher blur/alpha and lower refraction.
  set_glass_frost(0.5)
  t.draw()
  assert_eq(glass_frost(), 0.5)
  guard find_glass() is Some((blur50, alpha50, rim50, refr50)) else { fail("expected liquid glass instance at frost=0.5") }
  assert_true(blur50 > blur0 + 1.0, msg="blur did not increase: \{blur0} -> \{blur50}")
  assert_true(alpha50 > alpha0 + 0.25, msg="alpha did not increase: \{alpha0} -> \{alpha50}")
  assert_true(refr50 < refr0 - 1.0, msg="refraction did not decrease: \{refr0} -> \{refr50}")
  assert_true((rim50 - rim0).abs() < 0.01)

  // Enable system Increase Contrast: cached ViewBlock must rebuild with stronger rim and alpha.
  t.set_increase_contrast(true)
  t.draw()
  guard find_glass() is Some((_, alpha_c, rim_c, _)) else { fail("expected liquid glass instance under contrast") }
  assert_true(alpha_c > alpha50, msg="contrast should raise alpha: \{alpha50} -> \{alpha_c}")
  assert_true(rim_c > rim50 + 0.1, msg="contrast should boost rim: \{rim50} -> \{rim_c}")

  // Frost at 1.0 switches glass_solid() to true: no kind 6 glass instance emitted.
  set_glass_frost(1.0)
  t.draw()
  assert_true(the_ctx.val.glass_solid(), msg="frost=1.0 should enable glass_solid")
  assert_true(find_glass() is None, msg="frost=1.0 should draw solid rect instead of glass instance")

  // Explicit set_glass_solid(Some(false)) still overrides frost=1.0.
  set_glass_solid(Some(false))
  t.draw()
  assert_false(the_ctx.val.glass_solid())
  assert_true(find_glass() is Some(_))
  set_glass_solid(None)
  set_glass_frost(0.0)
  t.set_increase_contrast(false)
}
