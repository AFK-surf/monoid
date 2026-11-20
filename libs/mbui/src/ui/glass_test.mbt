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
/// A Backdrop lens's packed numbers taken apart as the renderers take them (kind 6, c2.z below 0): bits `at` on, `n`
/// of them, of minus `v`.
fn lens_bits(v : Double, at : Int, n : Int) -> Int {
  ((-v).round().to_int() >> at) & ((1 << n) - 1)
}

///|
/// Lenses side by side over a ground, something drawn between each (so each a capture of its own): each one's 6, 14
/// and 23.
fn lens_slots(lenses : Array[@ui.Glass]) -> Array[(Double, Double, Double)] {
  let t = @ui.Tester::new(fn(c) {
    c.box(w=Fill(1.0), h=Fill(1.0), bg=0xE5704AFFL, gap=4.0, fn() {
      for gl in lenses {
        c.box(w=Px(120.0), h=Px(40.0), radius=20.0, glass=gl, fn() {  }) |> ignore
        c.box(w=Px(10.0), h=Px(4.0), bg=0x000000FFL, fn() {  }) |> ignore
      }
    })
    |> ignore
  })
  t.drawn_instances().filter(fn(a) { a[5] == 6.0 }).map(fn(a) { (a[6], a[14], a[23]) })
}

///|
test "a Backdrop lens said as before is drawn as before: saturation one, its highlight -1 or -2, its shadow's radius" {
  let lens = fn(ambient : Bool, inner_shadow : Double) {
    @ui.Glass::backdrop_lens(height=10.0, amount=14.0, blur=0.0, tint=0xFFFFFF40L, solid=0xFFFFFFFFL, highlight=0.7,
      ambient~, dispersion=true, inner_shadow~)
  }
  assert_eq(lens_slots([lens(false, 0.0), lens(true, 0.0), lens(false, 8.0)]), [
    (1.0, -1.0, 0.0),
    (1.0, -2.0, 0.0),
    (1.0, -1.0, 8.0),
  ])
  // (what it says of the rest: as Glass::liquid's, nothing of a lens's own)
  let gl = lens(true, 8.0)
  assert_eq(
    (gl.backdrop_highlight, gl.saturation, gl.brightness, gl.contrast, gl.depth_effect, gl.tint_hue, gl.spot_alpha),
    (2, 1.0, 0.0, 1.0, false, false, 0.0),
  )
  assert_eq((gl.highlight_angle, gl.highlight_falloff, gl.inner_shadow_full, gl.spot), (45.0, 1.0, false, None))
  // (a style said is the style, whatever `ambient` says)
  let plain = @ui.Glass::backdrop_lens(height=1.0, amount=1.0, blur=0.0, tint=0L, solid=0L, highlight=1.0,
    ambient=true, style=Some(Plain))
  assert_eq(plain.backdrop_highlight, 3)
}

///|
test "a Backdrop lens's new numbers, packed whole under 2^23 and taken apart again to what it said" {
  let gl = @ui.Glass::backdrop_lens(
    height=10.0,
    amount=14.0,
    blur=2.0,
    tint=0x3366FFBFL,
    solid=0xFFFFFFFFL,
    highlight=1.0,
    style=Some(Plain),
    saturation=1.5,
    brightness=0.2,
    contrast=0.8,
    depth_effect=true,
    highlight_angle=100.0,
    highlight_falloff=2.0,
    tint_hue=true,
    spot=Some((30.0, 10.0)),
    spot_alpha=0.6,
    inner_shadow=8.0,
    inner_shadow_full=true,
  )
  let s = lens_slots([gl])
  assert_eq(s.length(), 1)
  let (sat, mode, rim) = s[0]
  for v in [sat, mode, rim] {
    assert_true(v < 0.0 && v > -8388608.0 && v == v.round())
  }
  // (14: the style, depth, hue, the shadow a whole radius lower, the angle, the falloff, the brightness)
  assert_eq(
    (lens_bits(mode, 0, 2), lens_bits(mode, 2, 1), lens_bits(mode, 3, 1), lens_bits(mode, 4, 1)),
    (3, 1, 1, 1),
  )
  assert_eq((lens_bits(mode, 5, 7) - 1).to_double() * 360.0 / 126.0, 100.0)
  assert_eq(lens_bits(mode, 12, 4).to_double() * 0.5, 2.0)
  assert_eq(lens_bits(mode, 16, 7), 64 + 13)
  // (6: saturation and contrast to a thousandth)
  assert_eq((lens_bits(sat, 0, 12), lens_bits(sat, 12, 11)), (1500, 800))
  // (23: the spot at 32 127ths across and down, lit 38 63rds, the shadow two fours)
  assert_eq((lens_bits(rim, 0, 7), lens_bits(rim, 7, 7), lens_bits(rim, 14, 6), lens_bits(rim, 20, 3)), (32, 32, 38, 2))
  // no spot where it lights nothing; a contrast of one its saturation as ever, none below 0
  let quiet = { ..gl, spot_alpha: 0.0, contrast: 1.0, saturation: -2.0 }
  let (sat, _, rim) = lens_slots([quiet])[0]
  assert_eq((sat, rim), (0.0, 8.0))
}

///|
test "a Backdrop lens's corners each its own, its radius the roundest" {
  let gl = @ui.Glass::backdrop_lens(height=10.0, amount=14.0, blur=0.0, tint=0L, solid=0xFFFFFFFFL, highlight=1.0)
  let t = @ui.Tester::new(fn(c) {
    c.box(w=Fill(1.0), h=Fill(1.0), bg=0xE5704AFFL, fn() {
      c.box(style=@ui.style(radius=Corners(20.0, 4.0, 12.0, 0.0)), w=Px(120.0), h=Px(60.0), glass=gl, fn() {  })
      |> ignore
    })
    |> ignore
  })
  let lens = t.drawn_instances().filter(fn(a) { a[5] == 6.0 })
  assert_eq(lens.map(fn(a) { (a[4], a[36], a[37], a[38], a[39]) }), [(20.0, 20.0, 4.0, 12.0, 0.0)])
}

///|
test "Backdrop lenses share a capture across non-glass when sharing() with matching blur, and when adjacent non-overlapping" {
  let lens4 = @ui.Glass::backdrop_lens(height=10.0, amount=14.0, blur=4.0, tint=0xFFFFFF40L, solid=0xFFFFFFFFL, highlight=0.7)
  let lens8 = @ui.Glass::backdrop_lens(height=10.0, amount=14.0, blur=8.0, tint=0xFFFFFF40L, solid=0xFFFFFFFFL, highlight=0.7)
  let t = @ui.Tester::new(fn(c) {
    c.box(w=Fill(1.0), h=Fill(1.0), bg=0xE5704AFFL, gap=8.0, fn() {
      // first lens with its own shadow (kind 2) drawn right after it
      c.box(w=Px(120.0), h=Px(44.0), radius=22.0, glass=lens4, shadow=4.0, fn() {  }) |> ignore
      // second lens marked sharing() with same blur: shares first lens's capture across the shadow
      c.box(w=Px(44.0), h=Px(44.0), radius=22.0, glass=lens4.sharing(), shadow=4.0, fn() {  }) |> ignore
      // third lens marked sharing() with different blur: must not share
      c.box(w=Px(44.0), h=Px(44.0), radius=22.0, glass=lens8.sharing(), fn() {  }) |> ignore
      // fourth lens adjacent non-overlapping with same blur as third: shares third's capture
      c.box(w=Px(44.0), h=Px(44.0), radius=22.0, glass=lens8, fn() {  }) |> ignore
    })
    |> ignore
  })
  let lenses = t.drawn_instances().filter(fn(a) { a[5] == 6.0 })
  assert_eq(lenses.length(), 4)
  assert_true(lenses[0][20] < 0.0)
  assert_eq(lenses[1][20], lenses[0][20])
  assert_true(lenses[2][20] < 0.0 && lenses[2][20] != lenses[0][20])
  assert_eq(lenses[3][20], lenses[2][20])
}
