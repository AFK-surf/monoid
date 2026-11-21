// Continuous materialisation strength (`Glass.strength` & `Glass::at_strength`) for frosted and liquid glass:
// zero instances / zero backdrop captures with preserved shadows at `t <= 0.001`, exact optical interpolation with
// preserved `bezel` at mid-strength, overshoot clamping for spring bounce, and smooth solid-fallback fade under
// `MBUI_GLASS=solid`.

///|
fn gs_approx(a : Double, b : Double) -> Bool {
  (a - b).abs() < 1.0e-6
}

///|
test "Glass::at_strength interpolates optical parameters, preserves bezel, and clamps spring overshoot" {
  let base = Glass::liquid(
    blur=8.0,
    tint=0xFDFCFDD9L,
    solid=0xFFFFFFFFL,
    saturation=1.4,
    rim=0.6,
    bezel=16.0,
    refraction=22.0,
    chroma=0.18,
    zoom=1.5,
  )
  let mid = base.at_strength(0.5)
  assert_true(gs_approx(mid.blur, 4.0))
  assert_true(gs_approx(mid.refraction, 11.0))
  assert_true(gs_approx(mid.rim, 0.3))
  assert_true(gs_approx(mid.chroma, 0.09))
  assert_true(gs_approx(mid.saturation, 1.2))
  assert_true(gs_approx(mid.zoom, 1.25))
  assert_true(gs_approx(mid.bezel, 16.0))
  assert_true(gs_approx(mid.strength, 0.5))

  let frosted = Glass::frosted(
    blur=20.0,
    tint=0xFFFFFF80L,
    solid=0xEEEEEEFFL,
    saturation=1.6,
    rim_edge=0.4,
    rim_lit=0.5,
    rim_back=0.2,
  )
  let fmid = frosted.at_strength(0.5)
  assert_true(gs_approx(fmid.blur, 10.0))
  assert_true(gs_approx(fmid.saturation, 1.3))
  assert_true(gs_approx(fmid.rim_edge, 0.2))
  assert_true(gs_approx(fmid.rim_lit, 0.25))
  assert_true(gs_approx(fmid.rim_back, 0.1))
  assert_true(gs_approx(fmid.strength, 0.5))

  // Spring overshoots (< 0 and > 1) clamp cleanly into [0.0, 1.0].
  let under = base.at_strength(-0.2)
  assert_true(gs_approx(under.strength, 0.0))
  assert_true(gs_approx(under.blur, 0.0))
  assert_true(gs_approx(under.refraction, 0.0))
  assert_true(gs_approx(under.rim, 0.0))
  assert_true(gs_approx(under.chroma, 0.0))
  assert_true(gs_approx(under.saturation, 1.0))
  assert_true(gs_approx(under.zoom, 1.0))
  assert_true(gs_approx(under.bezel, 16.0))

  let over = base.at_strength(1.3)
  assert_eq(over, base)

  // Constructor clamping and Glass::clear strength passthrough.
  assert_true(gs_approx(Glass::frosted(blur=8.0, tint=0xFFFFFF40L, solid=0xEEEEEEFFL, strength=1.5).strength, 1.0))
  assert_true(gs_approx(Glass::liquid(strength=-0.4).strength, 0.0))
  assert_true(gs_approx(Glass::clear(strength=0.4).strength, 0.4))
}

///|
test "tree glass at strength <= 0.001 emits zero glass and zero captures while keeping shadow; strength=0.5 scales slot 15" {
  let strength = @signals.signal(0.0, same=fn(a, b) { a == b })
  let base = Glass::liquid(
    blur=8.0,
    tint=0xFDFCFDD9L,
    solid=0xEEEEEEFFL,
    saturation=1.4,
    rim=0.6,
    bezel=16.0,
    refraction=22.0,
    chroma=0.18,
  )
  let t = Tester::new(fn(_c) {  }, w=300.0, h=200.0)
  set_view_app(fn(root) {
    root.box(fn(bg) { bg.over(Is(true)).ground(Is(0x3366CCFFL)) |> ignore }) |> ignore
    root.box(fn(n) {
      n
      .over(Is(true))
      .offset(Is((20.0, 20.0)))
      .width(Is(Some(120.0)))
      .height(Is(Some(60.0)))
      .radius(Is(18.0))
      .glass(By(fn() { Some(base.at_strength(strength.get())) }))
      .shadow(Is((8.0, 4.0, 0x00000040L)))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  // t = 0.0: zero glass instances, zero captures, shadow still emitted.
  assert_eq(t.drawn_glass(), [])
  assert_eq(t.drawn_shadows().length(), 1)

  // t = 0.001 (at cutoff): still zero glass instances, shadow still emitted.
  strength.set(0.001)
  t.run_for(frame_period_default)
  assert_eq(t.drawn_glass(), [])
  assert_eq(t.drawn_shadows().length(), 1)

  // t = 0.5: 1 liquid glass instance with interpolated slots and full bezel.
  strength.set(0.5)
  t.run_for(frame_period_default)
  assert_eq(t.drawn_glass().length(), 1)
  assert_eq(t.drawn_glass()[0].4, 6)
  let glass_insts = t.drawn_instances().filter(fn(a) { a.length() > 22 && a[5] == 6.0 })
  assert_eq(glass_insts.length(), 1)
  let inst = glass_insts[0]
  assert_true(gs_approx(inst[6], 1.2))
  assert_true(gs_approx(inst[7], 4.0))
  assert_true(gs_approx(inst[12], 0.3))
  assert_true(gs_approx(inst[13], 16.0))
  assert_true(gs_approx(inst[15], 0.5))
  assert_true(gs_approx(inst[21], 11.0))
  assert_true(gs_approx(inst[22], 0.09))
  assert_eq(t.drawn_shadows().length(), 1)

  // Overshoot t = -0.2 clamps to 0 (no glass); t = 1.3 clamps to 1.0 (full glass).
  strength.set(-0.2)
  t.run_for(frame_period_default)
  assert_eq(t.drawn_glass(), [])
  assert_eq(t.drawn_shadows().length(), 1)

  strength.set(1.3)
  t.run_for(frame_period_default)
  let full_insts = t.drawn_instances().filter(fn(a) { a.length() > 22 && a[5] == 6.0 })
  assert_eq(full_insts.length(), 1)
  assert_true(gs_approx(full_insts[0][7], 8.0))
  assert_true(gs_approx(full_insts[0][13], 16.0))
  assert_true(gs_approx(full_insts[0][15], 1.0))
  assert_true(gs_approx(full_insts[0][21], 22.0))
}

///|
test "tree glass under MBUI_GLASS=solid fades solid fallback alpha by strength and omits rect at strength <= 0.001" {
  let strength = @signals.signal(0.0, same=fn(a, b) { a == b })
  let base = Glass::liquid(blur=8.0, tint=0xFDFCFDD9L, solid=0x224466FFL)
  let t = Tester::new(fn(_c) {  }, w=300.0, h=200.0)
  set_glass_solid(Some(true))
  set_view_app(fn(root) {
    root.box(fn(n) {
      n
      .over(Is(true))
      .offset(Is((20.0, 20.0)))
      .width(Is(Some(120.0)))
      .height(Is(Some(60.0)))
      .radius(Is(18.0))
      .glass(By(fn() { Some(base.at_strength(strength.get())) }))
      .shadow(Is((8.0, 4.0, 0x00000040L)))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let solid_alpha = fn() {
    t
    .drawn_rects()
    .filter(fn(r) { (r.0 - 20.0).abs() < 0.5 && (r.2 - 120.0).abs() < 0.5 && ((r.4 >> 8) & 0xFFFFFFL) == 0x224466L })
    .map(fn(r) { (r.4 & 0xFFL).to_int() })
  }
  assert_eq(t.drawn_glass(), [])
  assert_eq(solid_alpha(), [])
  assert_eq(t.drawn_shadows().length(), 1)

  strength.set(0.5)
  t.run_for(frame_period_default)
  assert_eq(t.drawn_glass(), [])
  let a50 = solid_alpha()
  assert_eq(a50.length(), 1)
  assert_true(a50[0] >= 126 && a50[0] <= 129, msg="expected ~128, got \{a50[0]}")

  strength.set(1.0)
  t.run_for(frame_period_default)
  set_glass_solid(None)
  assert_eq(t.drawn_glass(), [])
  assert_eq(solid_alpha(), [255])
}
