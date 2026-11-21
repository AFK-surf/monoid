///|
fn glass_scene(c : @ui.Ctx) -> Unit {
  let frost = @ui.Glass::frosted(blur=24.0, tint=0xF5F3EFB3L, solid=0xF5F3EFFFL)
  c.box(w=Fill(1.0), h=Fill(1.0), bg=0x1559C4FFL, fn() {
    c.layer(fn() {
      // two bars one after the other: one capture
      c.box(w=Fill(1.0), h=Px(50.0), glass=frost, fn() {  }) |> ignore
      c.box(w=Fill(1.0), h=Px(30.0), glass=frost, fn() {  }) |> ignore
      c.spacer()
      // a floating capsule with words in it, its shadow outside it
      c.box(
        w=Px(200.0),
        h=Px(44.0),
        radius=22.0,
        glass=@ui.Glass::frosted(blur=20.0, tint=0xFFFFFFB8L, solid=0xFFFFFFFFL),
        shadow=2.0,
        fn() { c.text("在这里输入", wrap=false) |> ignore },
      )
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
test "glass one after another shares a capture; glass after something drawn takes its own" {
  let t = @ui.Tester::new(glass_scene)
  let gs = t.drawn_glass()
  assert_eq(gs.length(), 3)
  let (_, y0, _, h0, k0, run0) = gs[0]
  let (_, y1, _, _, _, run1) = gs[1]
  let (_, _, w2, h2, _, run2) = gs[2]
  assert_eq((y0, h0, k0), (0.0, 50.0, 5))
  assert_eq(y1, 50.0)
  assert_eq(run0, run1)
  // the capsule's glass: a capture of its own
  assert_eq((w2, h2), (200.0, 44.0))
  assert_true(run2 != run0)
  // its ground is glass, not a rectangle of its tint
  assert_true(
    t.drawn_rects().iter().all(fn(r) { r.4 != 0xF5F3EFB3L && r.4 != 0xFFFFFFB8L }),
  )
}

///|
test "contained glass frosts its own box alone: a capture of its own even right after glass of the same blur" {
  let contained = @ui.Glass::frosted(blur=14.0, tint=0L, solid=0L, contained=true)
  let t = @ui.Tester::new(fn(c) {
    c.box(w=Fill(1.0), h=Fill(1.0), bg=0x1559C4FFL, fn() {
      c.layer(fn() {
        c.box(w=Fill(1.0), h=Px(50.0), glass=contained, fn() {  }) |> ignore
        c.box(w=Fill(1.0), h=Px(30.0), glass=contained, fn() {  }) |> ignore
        c.box(w=Fill(1.0), h=Px(30.0), glass=@ui.Glass::frosted(blur=14.0, tint=0L, solid=0L), fn() {  }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  let gs = t.drawn_glass()
  assert_eq(gs.length(), 3)
  assert_eq(t.drawn_glass_contained(), [true, true, false])
  assert_true(gs[0].5 != gs[1].5)
  assert_true(gs[1].5 != gs[2].5)
}

///|
test "where less transparency is asked for, glass is its solid ground" {
  let t = @ui.Tester::new(glass_scene)
  t.set_reduce_transparency(true)
  t.frame()
  assert_eq(t.drawn_glass().length(), 0)
  let rects = t.drawn_rects()
  assert_true(rects.iter().any(fn(r) { r.1 == 0.0 && r.3 == 50.0 && r.4 == 0xF5F3EFFFL }))
  assert_true(rects.iter().any(fn(r) { r.2 == 200.0 && r.4 == 0xFFFFFFFFL }))
  t.set_reduce_transparency(false)
  t.frame()
  assert_eq(t.drawn_glass().length(), 3)
}

///|
test "frosted glass sharing a capture takes the last frosted one, past liquid glass drawn between" {
  let frost = @ui.Glass::frosted(blur=20.0, tint=0xFFFFFFB8L, solid=0xFDFCFBFFL)
  let t = @ui.Tester::new(fn(c) {
    c.box(w=Fill(1.0), h=Fill(1.0), bg=0x1559C4FFL, fn() {
      c.box(w=Px(300.0), h=Px(60.0), glass=frost, fn() {  }) |> ignore
      c.box(w=Px(56.0), h=Px(56.0), radius=28.0, glass=@ui.Glass::liquid(), fn() {  }) |> ignore
      c.box(w=Px(56.0), h=Px(56.0), radius=28.0, glass=frost.sharing(), fn() {  }) |> ignore
    })
    |> ignore
  })
  let runs = t.drawn_glass().map(fn(g) { g.5 })
  assert_eq(runs.length(), 3)
  assert_true(runs[1] != runs[0])
  assert_eq(runs[2], runs[0])
}

///|
test "liquid glass of a group merges with none drawn right before or after it" {
  let t = @ui.Tester::new(fn(c) {
    c.box(w=Fill(1.0), h=Fill(1.0), bg=0xE5704AFFL, fn() {
      c.box(w=Px(56.0), h=Px(56.0), radius=28.0, glass=@ui.Glass::liquid(), fn() {  }) |> ignore
      c.box(dir=Row, gap=8.0, glass_group=true, fn() {
        for _ in 0..<2 {
          c.box(w=Px(56.0), h=Px(56.0), radius=28.0, glass=@ui.Glass::liquid(), fn() {  }) |> ignore
        }
      })
      |> ignore
      c.box(w=Px(56.0), h=Px(56.0), radius=28.0, glass=@ui.Glass::liquid(), fn() {  }) |> ignore
    })
    |> ignore
  })
  let runs = t.drawn_glass().map(fn(g) { g.5 })
  assert_eq(runs.length(), 4)
  assert_eq(runs[1], runs[2])
  assert_true(runs[0] != runs[1])
  assert_true(runs[3] != runs[2])
}

///|
test "liquid glass of a group is drawn first, as one capture, its words inked by what is under it" {
  let t = @ui.Tester::new(fn(c) {
    c.box(w=Fill(1.0), h=Fill(1.0), bg=0xE5704AFFL, fn() {
      c.box(dir=Row, gap=8.0, glass_group=true, fn() {
        for i in 0..<3 {
          c.box(w=Px(56.0), h=Px(56.0), radius=28.0, glass=@ui.Glass::liquid(), fn() {
            c.text("\{i}", wrap=false) |> ignore
          })
          |> ignore
        }
      })
      |> ignore
      c.box(
        w=Px(120.0),
        h=Px(40.0),
        glass=@ui.Glass::liquid(adaptive=false),
        fn() { c.text("plain", wrap=false) |> ignore },
      )
      |> ignore
    })
    |> ignore
  })
  let gs = t.drawn_glass()
  assert_eq(gs.length(), 4)
  let runs = gs.map(fn(g) { g.5 })
  assert_eq(runs[0], runs[1])
  assert_eq(runs[1], runs[2])
  assert_true(runs[3] != runs[0])
  assert_eq(gs.map(fn(g) { g.4 }), [6, 6, 6, 6])
  assert_eq(gs.map(fn(g) { g.0 }), [0.0, 64.0, 128.0, 0.0])
  // "0", "1", "2" inked by the glass; "plain" as it was asked
  assert_eq(t.adaptive_glyphs(), 3)
}

///|
/// A bar with a notch cut into its top, a line drawn over it, then a ball and a disc of glass over it that
/// frost what the bar frosts.
fn notched_scene(c : @ui.Ctx) -> Unit {
  let frost = @ui.Glass::frosted(blur=20.0, tint=0xFFFFFFB8L, solid=0xFDFCFBFFL)
  c.box(w=Fill(1.0), h=Fill(1.0), bg=0x1559C4FFL, fn() {
    c.layer(fn() {
      c.spacer()
      c.box(w=Px(346.0), h=Px(56.0), radius=28.0, glass=frost, notch_y=-4.0, notch_r=34.0, notch_fillet=8.0, fn() {
        c.box(w=Fill(1.0), h=Px(1.0), bg=0xFFFFFFB3L, fn() {  }) |> ignore
        c.box(w=Px(68.0), h=Px(68.0), radius=34.0, glass=frost.sharing(), shadow=4.0, fn() {  }) |> ignore
      })
      |> ignore
    })
    |> ignore
    c.layer(fn() {
      c.box(w=Px(56.0), h=Px(56.0), radius=28.0, glass=frost.sharing(), fn() {  }) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
test "a notch is cut into a box's glass, and into its ground where glass is solid" {
  let t = @ui.Tester::new(notched_scene)
  let ns = t.drawn_notches()
  assert_eq(ns.length(), 1)
  let (kind, _, cy, r, f) = ns[0]
  assert_eq((kind, cy, r, f), (5, -4.0, 34.0, 8.0))
  t.set_reduce_transparency(true)
  t.frame()
  let ns = t.drawn_notches()
  assert_eq(ns.length(), 1)
  let (kind, _, cy, r, f) = ns[0]
  assert_eq((kind, cy, r, f), (0, -4.0, 34.0, 8.0))
  t.set_reduce_transparency(false)
  t.frame()
}

///|
test "glass made to share a capture frosts what the glass before it frosts, over it and after what is drawn between" {
  let t = @ui.Tester::new(notched_scene)
  let gs = t.drawn_glass()
  assert_eq(gs.length(), 3)
  let (_, _, _, _, _, bar) = gs[0]
  let (_, _, _, _, _, ball) = gs[1]
  let (_, _, _, _, _, disc) = gs[2]
  assert_eq(ball, bar)
  assert_eq(disc, bar)
  // the shared glass has no notch of its own
  assert_eq(t.drawn_notches().length(), 1)
}

///|
test "liquid glass says where the pointer lights it (14): none 0; a spot each of x and y at half a point from 256 before its top left" {
  let t = @ui.Tester::new(fn(c) {
    c.box(w=Fill(1.0), h=Fill(1.0), bg=0xE5704AFFL, gap=8.0, fn() {
      c.box(w=Px(120.0), h=Px(44.0), radius=22.0, glass=@ui.Glass::liquid(spot=Some((12.5, 8.0))), fn() {  })
      |> ignore
      c.box(w=Px(60.0), h=Px(10.0), bg=0x000000FFL, fn() {  }) |> ignore
      c.box(w=Px(120.0), h=Px(44.0), radius=22.0, glass=@ui.Glass::liquid(), fn() {  }) |> ignore
      c.box(w=Px(60.0), h=Px(10.0), bg=0x000000FFL, fn() {  }) |> ignore
      // (far past its edge either way: held at the packing's ends)
      c.box(w=Px(120.0), h=Px(44.0), radius=22.0, glass=@ui.Glass::liquid(spot=Some((-900.0, 5000.0))), fn() {  })
      |> ignore
      // (frosted glass's 14 is its rim's back, as ever)
      c.box(w=Px(120.0), h=Px(44.0), glass=@ui.Glass::frosted(blur=8.0, tint=0L, solid=0L, rim_back=0.25), fn() {  })
      |> ignore
    })
    |> ignore
  })
  let glass = t.drawn_instances().filter(fn(a) { a[5] == 6.0 || a[5] == 5.0 })
  assert_eq(glass.map(fn(a) { (a[5], a[14]) }), [
    (6.0, 537.0 * 4096.0 + 528.0 + 1.0),
    (6.0, 0.0),
    (6.0, 0.0 * 4096.0 + 4095.0 + 1.0),
    (5.0, 0.25),
  ])
  // (taken apart as the renderers take it, by a power of two: the point it said, from the glass's own top left)
  let q = glass[0][14] - 1.0
  let qx = (q * 0.000244140625).floor()
  let qy = q - qx * 4096.0
  assert_eq((qx * 0.5 - 256.0, qy * 0.5 - 256.0), (12.5, 8.0))
}

///|
test "unmerged liquid glass (merge=0) shares a capture across shadow when sharing() with matching blur, auto-merges when non-overlapping, and keeps per-corner radii" {
  let g21 = @ui.Glass::liquid(blur=2.1, merge=0.0)
  let g21_spot = @ui.Glass::liquid(blur=2.1, merge=0.0, spot=Some((28.0, 28.0)))
  let g40 = @ui.Glass::liquid(blur=4.0, merge=0.0)
  let t = @ui.Tester::new(fn(c) {
    c.box(w=Fill(1.0), h=Fill(1.0), bg=0xE5704AFFL, gap=8.0, fn() {
      // first unmerged liquid with shadow (kind 2) drawn right after it
      c.box(w=Px(120.0), h=Px(44.0), radius=22.0, glass=g21, shadow=4.0, fn() {  }) |> ignore
      // second marked sharing() with same blur and its own spot: shares first's capture across the shadow
      c.box(w=Px(44.0), h=Px(44.0), radius=22.0, glass=g21_spot.sharing(), shadow=4.0, fn() {  }) |> ignore
      // third marked sharing() with different blur: must not share
      c.box(w=Px(44.0), h=Px(44.0), radius=22.0, glass=g40.sharing(), fn() {  }) |> ignore
      // fourth adjacent non-overlapping (gap=8 > 4) with same blur as third: shares third's capture
      c.box(w=Px(44.0), h=Px(44.0), radius=22.0, glass=g40, fn() {  }) |> ignore
    })
    |> ignore
  })
  let gs = t.drawn_instances().filter(fn(a) { a[5] == 6.0 })
  assert_eq(gs.length(), 4)
  assert_true(gs[0][20] < 0.0)
  assert_eq(gs[1][20], gs[0][20])
  assert_true(gs[1][14] > 0.5)
  assert_true(gs[2][20] < 0.0 && gs[2][20] != gs[0][20])
  assert_eq(gs[3][20], gs[2][20])

  // overlapping (or within 2pt quad growth: gap < 4) unmerged liquid instances take separate captures
  let t2 = @ui.Tester::new(fn(c) {
    c.box(w=Fill(1.0), h=Fill(1.0), bg=0xE5704AFFL, gap=2.0, fn() {
      c.box(w=Px(80.0), h=Px(44.0), radius=22.0, glass=g21, fn() {  }) |> ignore
      c.box(w=Px(80.0), h=Px(44.0), radius=22.0, glass=g21, fn() {  }) |> ignore
    })
    |> ignore
  })
  let gs2 = t2.drawn_instances().filter(fn(a) { a[5] == 6.0 })
  assert_eq(gs2.length(), 2)
  assert_true(gs2[0][20] != gs2[1][20])

  // unmerged liquid glass keeps per-corner radii in a[36..39]
  let t3 = @ui.Tester::new(fn(c) {
    c.box(w=Fill(1.0), h=Fill(1.0), bg=0xE5704AFFL, fn() {
      c.box(style=@ui.style(radius=Corners(20.0, 4.0, 12.0, 0.0)), w=Px(120.0), h=Px(60.0), glass=g21, fn() {  })
      |> ignore
    })
    |> ignore
  })
  let gs3 = t3.drawn_instances().filter(fn(a) { a[5] == 6.0 })
  assert_eq(gs3.map(fn(a) { (a[4], a[36], a[37], a[38], a[39]) }), [(20.0, 20.0, 4.0, 12.0, 0.0)])
}

///|
test "merged liquid glass keeps independent 4-corner radii and Glass::clear defaults" {
  let cl = @ui.Glass::clear()
  assert_eq((cl.liquid, cl.blur, cl.tint, cl.solid, cl.saturation), (true, 0.0, 0xFFFFFF1AL, 0xECECF0FFL, 1.0))
  assert_eq((cl.rim, cl.bezel, cl.refraction, cl.chroma, cl.merge, cl.adaptive), (0.6, 14.0, 16.0, 0.0, 16.0, true))
  let t = @ui.Tester::new(fn(c) {
    c.box(w=Fill(1.0), h=Fill(1.0), bg=0x111827FFL, fn() {
      c.box(dir=Row, gap=6.0, glass_group=true, fn() {
        c.box(
          style=@ui.style(radius=Corners(24.0, 24.0, 0.0, 0.0)),
          w=Px(140.0),
          h=Px(64.0),
          glass=@ui.Glass::liquid(merge=16.0),
          fn() {  },
        )
        |> ignore
        c.box(w=Px(48.0), h=Px(48.0), radius=24.0, glass=cl, fn() {  }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  let gs = t.drawn_instances().filter(fn(a) { a[5] == 6.0 })
  assert_eq(gs.length(), 2)
  assert_eq((gs[0][4], gs[0][36], gs[0][37], gs[0][38], gs[0][39]), (24.0, 24.0, 24.0, 0.0, 0.0))
  assert_eq((gs[1][4], gs[1][36], gs[1][37], gs[1][38], gs[1][39]), (24.0, 24.0, 24.0, 24.0, 24.0))
  assert_eq((gs[1][7], gs[1][12], gs[1][13], gs[1][21], gs[1][22], gs[1][23]), (0.0, 0.6, 14.0, 16.0, 0.0, 16.0))
}

///|
test "liquid glass clear-lens zoom encodes negative slot 7, shares capture with blur=0 liquid, and light_angle signal resets cleanly" {
  let cl0 = @ui.Glass::clear(merge=0.0)
  let clz = @ui.Glass::clear(merge=0.0, zoom=1.25)
  let cl_clamp = @ui.Glass::liquid(blur=0.0, merge=0.0, zoom=5.0)
  let blurred_zoom = @ui.Glass::liquid(blur=2.0, merge=0.0, zoom=1.5)
  assert_eq((cl0.zoom, clz.zoom), (1.0, 1.25))
  let t = @ui.Tester::new(fn(c) {
    c.box(w=Fill(1.0), h=Fill(1.0), bg=0x111827FFL, gap=8.0, fn() {
      c.box(w=Px(80.0), h=Px(44.0), radius=22.0, glass=cl0, fn() {  }) |> ignore
      // zoomed clear lens right after blur=0 clear glass shares the same capture (both effective blur 0.0)
      c.box(w=Px(80.0), h=Px(44.0), radius=22.0, glass=clz, fn() {  }) |> ignore
      // zoom > 3.0 clamps to 3.0 -> slot 7 = -2.0; sharing() also joins the blur=0 liquid capture
      c.box(w=Px(80.0), h=Px(44.0), radius=22.0, glass=cl_clamp.sharing(), fn() {  }) |> ignore
      // blur > 0 ignores zoom and writes positive blur
      c.box(w=Px(80.0), h=Px(44.0), radius=22.0, glass=blurred_zoom, fn() {  }) |> ignore
    })
    |> ignore
  })
  let gs = t.drawn_instances().filter(fn(a) { a[5] == 6.0 })
  assert_eq(gs.length(), 4)
  assert_eq((gs[0][7], gs[1][7], gs[2][7], gs[3][7]), (0.0, -0.25, -2.0, 2.0))
  assert_eq(gs[1][20], gs[0][20])
  assert_eq(gs[2][20], gs[0][20])
  assert_true(gs[3][20] != gs[0][20])
  // negative slot 7 on liquid (kind 6) must never be reported as frosted `contained`
  assert_eq(t.drawn_glass_contained(), [false, false, false, false])

  // global ambient light angle signal updates and resets cleanly
  assert_eq(@ui.glass_light_angle(), 0.0)
  @ui.set_glass_light_angle(0.75)
  assert_eq(@ui.glass_light_angle(), 0.75)
  @ui.set_glass_light_angle(0.0)
  assert_eq(@ui.glass_light_angle(), 0.0)
}
