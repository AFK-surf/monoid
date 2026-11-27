// Progressive (variable) blur frosted glass (`Glass::frosted(..., progressive=true)`):
// emits kind 5 with slot 22 == -1.0, takes an isolated negative capture id (never merging with
// adjacent frosted glass or being reused via `shares_capture`), preserves `View::fades` slots 52..55,
// degrades to solid kind 0 with preserved fades under `set_glass_solid(Some(true))`, and leaves
// regular `Glass::frosted` unchanged (slot 22 == 0.0).

///|
fn gp_approx(a : Double, b : Double) -> Bool {
  (a - b).abs() < 1.0e-5
}

///|
test "progressive frosted glass emits slot 22 == -1.0, isolated capture id, and fade slots 52..55" {
  let regular = Glass::frosted(blur=14.0, tint=0xFFFFFFCC, solid=0xFFFFFFFF)
  let prog = Glass::frosted(blur=14.0, tint=0xFFFFFFE0, solid=0xFFFFFFFF, saturation=1.08, progressive=true)
  let shared = Glass::frosted(blur=14.0, tint=0xFFFFFFCC, solid=0xFFFFFFFF, shares_capture=true)
  assert_true(!regular.progressive)
  assert_true(prog.progressive)
  assert_true(!Glass::liquid().progressive)

  let t = Tester::new(fn(_c) {  }, w=300.0, h=200.0)
  set_view_app(fn(root) {
    root.box(fn(bg) { bg.over(Is(true)).ground(Is(0x3366CCFFL)) |> ignore }) |> ignore
    // 1) Regular frosted glass at top-left (y: 0..40)
    root.box(fn(n) {
      n
      .over(Is(true))
      .offset(Is((0.0, 0.0)))
      .width(Is(Some(100.0)))
      .height(Is(Some(40.0)))
      .glass(Is(Some(regular)))
      |> ignore
    })
    |> ignore
    // 2) Progressive frosted glass inside a bottom-fading host (y: 50..110, bottom fade 24pt)
    root.box(fn(host) {
      host
      .over(Is(true))
      .offset(Is((0.0, 50.0)))
      .width(Is(Some(200.0)))
      .height(Is(Some(60.0)))
      .fades(Is((0.0, 0.0, 0.0, 24.0)))
      |> ignore
      host.box(fn(fill) {
        fill
        .width_share(Is(1.0))
        .height_share(Is(1.0))
        .points(Is(false))
        .glass(Is(Some(prog)))
        |> ignore
        let _ = fill.pointed()
      })
      |> ignore
    })
    |> ignore
    // 3) Regular frosted glass right after progressive (same blur, non-overlapping): must NOT merge with progressive
    root.box(fn(n) {
      n
      .over(Is(true))
      .offset(Is((0.0, 120.0)))
      .width(Is(Some(100.0)))
      .height(Is(Some(30.0)))
      .glass(Is(Some(regular)))
      |> ignore
    })
    |> ignore
    // 4) Frosted glass with shares_capture=true after progressive: must reuse regular capture, not progressive
    root.box(fn(n) {
      n
      .over(Is(true))
      .offset(Is((120.0, 120.0)))
      .width(Is(Some(80.0)))
      .height(Is(Some(30.0)))
      .glass(Is(Some(shared)))
      |> ignore
    })
    |> ignore
  })
  t.draw()

  let insts = t.drawn_instances().filter(fn(a) { a.length() >= 60 && a[5] == 5.0 })
  assert_eq(insts.length(), 4)
  let r0 = insts[0]
  let p1 = insts[1]
  let r2 = insts[2]
  let s3 = insts[3]

  // Regular frosted glass keeps slot 22 == 0.0
  assert_true(gp_approx(r0[22], 0.0))
  assert_true(gp_approx(r2[22], 0.0))
  assert_true(gp_approx(s3[22], 0.0))

  // Progressive frosted glass emits kind 5, slot 22 == -1.0, and negative isolated capture id
  assert_true(gp_approx(p1[5], 5.0))
  assert_true(gp_approx(p1[22], -1.0))
  assert_true(p1[20] < 0.0)
  assert_true(p1[20] != r0[20], msg="progressive must not merge with preceding frosted glass")
  assert_true(r2[20] != p1[20], msg="following frosted glass must not merge with progressive")
  assert_true(s3[20] != p1[20], msg="shares_capture must not reuse progressive capture")
  assert_true(gp_approx(s3[20], r2[20]), msg="shares_capture should reuse the last regular frosted capture")

  // Progressive frosted glass preserves bottom fade in slots 52..55 (y1=110, fade_h=24)
  assert_true(gp_approx(p1[54], 110.0), msg="expected fade bottom edge 110.0, got \{p1[54]}")
  assert_true(gp_approx(p1[55], 24.0), msg="expected fade bottom band 24.0, got \{p1[55]}")
}

///|
test "progressive frosted glass degrades to solid kind 0 with fade slots 52..55 under set_glass_solid(Some(true))" {
  let prog = Glass::frosted(blur=14.0, tint=0x112233E0, solid=0x445566FF, saturation=1.08, progressive=true)
  let t = Tester::new(fn(_c) {  }, w=300.0, h=200.0)
  set_glass_solid(Some(true))
  set_view_app(fn(root) {
    root.box(fn(host) {
      host
      .over(Is(true))
      .offset(Is((0.0, 40.0)))
      .width(Is(Some(200.0)))
      .height(Is(Some(60.0)))
      .fades(Is((0.0, 0.0, 0.0, 24.0)))
      |> ignore
      host.box(fn(fill) {
        fill
        .width_share(Is(1.0))
        .height_share(Is(1.0))
        .points(Is(false))
        .glass(Is(Some(prog)))
        |> ignore
        let _ = fill.pointed()
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  set_glass_solid(None)

  assert_eq(t.drawn_glass(), [])
  let solid_insts = t
    .drawn_instances()
    .filter(fn(a) { a.length() >= 60 && a[5] == 0.0 && gp_approx(a[1], 40.0) && gp_approx(a[3], 60.0) })
  assert_eq(solid_insts.length(), 1)
  let inst = solid_insts[0]
  assert_true(gp_approx(inst[54], 100.0), msg="expected solid fallback fade bottom edge 100.0, got \{inst[54]}")
  assert_true(gp_approx(inst[55], 24.0), msg="expected solid fallback fade bottom band 24.0, got \{inst[55]}")
}

///|
test "View::fades tail (< 0.2 opacity) does not occlude hits underneath glass overlay while bar body (>= 0.2) still covers" {
  let prog = Glass::frosted(blur=8.0, tint=0xFFFFFF5C, solid=0xFFFFFFFF, saturation=1.25, progressive=true)
  let top_hits = Ref(0)
  let tail_hits = Ref(0)
  let t = Tester::new(fn(_c) {  }, w=300.0, h=200.0)
  set_view_app(fn(root) {
    // Underlying pressable targets in normal flow:
    // - top_btn at y: 0..44 (under the upper body of the overlay, fade_r = 1.0 >= 0.2)
    // - tail_btn at y: 84..100 (under the bottom fade tail of the overlay, y1=100, fade_h=56 -> at y=92, fade_r = 8/56 = 0.143 < 0.2)
    root.box(fn(b) {
      b
      .over(Is(true))
      .offset(Is((20.0, 0.0)))
      .width(Is(Some(200.0)))
      .height(Is(Some(44.0)))
      .on_press(fn() { top_hits.val = top_hits.val + 1 })
      |> ignore
    })
    |> ignore
    root.box(fn(b) {
      b
      .over(Is(true))
      .offset(Is((20.0, 84.0)))
      .width(Is(Some(200.0)))
      .height(Is(Some(16.0)))
      .on_press(fn() { tail_hits.val = tail_hits.val + 1 })
      |> ignore
    })
    |> ignore
    // Progressive soft-edge glass overlay covering y: 0..100 with 56pt bottom fade band (fade_r < 0.2 for y > 88.8)
    root.box(fn(host) {
      host
      .over(Is(true))
      .offset(Is((0.0, 0.0)))
      .width(Is(Some(300.0)))
      .height(Is(Some(100.0)))
      .fades(Is((0.0, 0.0, 0.0, 56.0)))
      |> ignore
      host.box(fn(fill) {
        fill
        .width_share(Is(1.0))
        .height_share(Is(1.0))
        .points(Is(false))
        .glass(Is(Some(prog)))
        |> ignore
        let _ = fill.pointed()
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()

  // Tap in the opaque upper body (y=20, fade_r=1.0 >= 0.2): glass overlay covers and blocks the tap
  t.tap(100.0, 20.0)
  assert_eq(top_hits.val, 0)

  // Tap in the bottom fade tail (y=92, fade_r=8/56=0.143 < 0.2): glass overlay does NOT cover, tap reaches tail_btn
  t.tap(100.0, 92.0)
  assert_eq(tail_hits.val, 1)
}

///|
test "transform_insts scaling preserves kind 5 progressive blur marker slot 22 == -1.0" {
  let prog = Glass::frosted(blur=8.5, tint=0x141519F5, solid=0x141519FF, saturation=1.0, progressive=true)
  let t = Tester::new(fn(_c) {  }, w=300.0, h=200.0)
  set_view_app(fn(root) {
    root.box(fn(scaled) {
      scaled.scale(Is(0.4)).width(Is(Some(200.0))).height(Is(Some(80.0))) |> ignore
      scaled.box(fn(host) {
        host.width(Is(Some(200.0))).height(Is(Some(80.0))).fades(Is((0.0, 0.0, 0.0, 40.0))) |> ignore
        host.box(fn(fill) {
          fill.width_share(Is(1.0)).height_share(Is(1.0)).glass(Is(Some(prog))) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let insts = t.drawn_instances().filter(fn(a) { a.length() >= 56 && a[5] == 5.0 })
  assert_eq(insts.length(), 1)
  assert_true(gp_approx(insts[0][22], -1.0), msg="expected slot 22 preserved at -1.0 under scale 0.4, got \{insts[0][22]}")
}
