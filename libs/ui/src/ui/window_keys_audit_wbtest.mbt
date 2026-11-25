// Unit tests for Tester::window_keys_faults (K0 contract, K1 overlap/clearance, K2 alignment/band, K3 hard edge).

///|
fn wk_make_capsule(root : @view.View, x : Double, y : Double, w : Double, h : Double) -> @view.View {
  let cap_ref : Ref[@view.View?] = Ref(None)
  root.box(fn(layer) {
    layer.over(Is(true)).over_all(Is(true)).padding(Is((x, y, 0.0, 0.0))) |> ignore
    let cap = layer.box(fn(p) {
      p.width(Is(Some(w))).height(Is(Some(h))).ground(Is(0x33333366L)) |> ignore
      p.box(fn(btn) {
        btn
        .width(Is(Some(32.0)))
        .height(Is(Some(32.0)))
        .says(Is(Some(@view.said(Button, label="close"))))
        .on_press(fn() { () })
        |> ignore
      })
      |> ignore
    })
    cap_ref.val = Some(cap)
  })
  |> ignore
  cap_ref.val.unwrap()
}

///|
test "window_keys_faults: returns empty when keeps_away is not set" {
  let t = Tester::tree(
    fn(root) {
      root.box(fn(b) {
        b.width(Is(Some(800.0))).height(Is(Some(45.0))).ground(Is(0xFFFFFFFFL)) |> ignore
      })
      |> ignore
    },
    w=800.0,
    h=600.0,
  )
  t.frame()
  assert_eq(t.window_keys_faults(), [])
}

///|
test "window_keys_faults: clean 50pt top bar with aligned 32pt button and hairline at y=49 passes" {
  let t = Tester::tree(
    fn(root) {
      root.box(fn(bar) {
        bar
        .width(Is(Some(800.0)))
        .height(Is(Some(50.0)))
        .ground(Is(0xFFFFFFFFL))
        .row(Is(true))
        .lines_up(Is(Some(Middle)))
        .padding(Is((12.0, 5.0, 125.0, 1.0)))
        |> ignore
        bar.box(fn(btn) {
          btn
          .width(Is(Some(32.0)))
          .height(Is(Some(32.0)))
          .says(Is(Some(@view.said(Button, label="action"))))
          .on_press(fn() { () })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      // Hairline at y=49..50 (below ky + kh + 3 = 48)
      root.box(fn(hl) {
        hl.over(Is(true)).padding(Is((0.0, 49.0, 0.0, 0.0))) |> ignore
        hl.box(fn(line) { line.width(Is(Some(800.0))).height(Is(Some(1.0))).ground(Is(0x00000022L)) |> ignore }) |> ignore
      })
      |> ignore
      let cap = wk_make_capsule(root, 687.0, 9.0, 104.0, 36.0)
      root.tree.keeps_away(Some((687.0, 9.0, 104.0, 36.0)), owner=cap.id(), band=false)
    },
    w=800.0,
    h=600.0,
  )
  t.frame()
  assert_eq(t.window_keys_faults(), [])
}

///|
test "window_keys_faults: K0 catches drift between kept_away and owner rect" {
  let t = Tester::tree(
    fn(root) {
      let cap = wk_make_capsule(root, 687.0, 12.0, 104.0, 36.0)
      root.tree.keeps_away(Some((687.0, 9.0, 104.0, 36.0)), owner=cap.id(), band=false)
    },
    w=800.0,
    h=600.0,
  )
  t.frame()
  let faults = t.window_keys_faults()
  assert_true(faults.any(fn(f) { f.contains("[WINDOW_KEYS_K0]") }))
}

///|
test "window_keys_faults: K1 catches control overlapping window-keys zone or 4pt left clearance" {
  let t = Tester::tree(
    fn(root) {
      root.box(fn(layer) {
        layer.over(Is(true)).padding(Is((660.0, 11.0, 0.0, 0.0))) |> ignore
        layer.box(fn(btn) {
          btn
          .width(Is(Some(32.0)))
          .height(Is(Some(32.0)))
          .says(Is(Some(@view.said(Button, label="overlap"))))
          .on_press(fn() { () })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      let cap = wk_make_capsule(root, 687.0, 9.0, 104.0, 36.0)
      root.tree.keeps_away(Some((687.0, 9.0, 104.0, 36.0)), owner=cap.id(), band=false)
    },
    w=800.0,
    h=600.0,
  )
  t.frame()
  let faults = t.window_keys_faults()
  assert_true(faults.any(fn(f) { f.contains("[WINDOW_KEYS_K1]") }))
}

///|
test "window_keys_faults: K2 catches 5pt vertical centerline misalignment on top bar" {
  let t = Tester::tree(
    fn(root) {
      root.box(fn(layer) {
        layer.over(Is(true)).padding(Is((12.0, 6.0, 0.0, 0.0))) |> ignore
        layer.box(fn(btn) {
          btn
          .width(Is(Some(32.0)))
          .height(Is(Some(32.0)))
          .says(Is(Some(@view.said(Button, label="misaligned"))))
          .on_press(fn() { () })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      let cap = wk_make_capsule(root, 687.0, 9.0, 104.0, 36.0)
      root.tree.keeps_away(Some((687.0, 9.0, 104.0, 36.0)), owner=cap.id(), band=false)
    },
    w=800.0,
    h=600.0,
  )
  t.frame()
  let faults = t.window_keys_faults()
  assert_true(faults.any(fn(f) { f.contains("[WINDOW_KEYS_K2]") }))
}

///|
test "window_keys_faults: K2 catches control intruding into Small dedicated top band" {
  let t = Tester::tree(
    fn(root) {
      root.box(fn(layer) {
        layer.over(Is(true)).padding(Is((12.0, 20.0, 0.0, 0.0))) |> ignore
        layer.box(fn(btn) {
          btn
          .width(Is(Some(32.0)))
          .height(Is(Some(32.0)))
          .says(Is(Some(@view.said(Button, label="intruder"))))
          .on_press(fn() { () })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      let cap = wk_make_capsule(root, 277.0, 9.0, 104.0, 36.0)
      root.tree.keeps_away(Some((277.0, 9.0, 104.0, 36.0)), owner=cap.id(), band=true)
    },
    w=390.0,
    h=844.0,
  )
  t.frame()
  let faults = t.window_keys_faults()
  assert_true(faults.any(fn(f) { f.contains("[WINDOW_KEYS_K2]") }))
}

///|
test "window_keys_faults: K3 catches 45pt opaque top bar and allows soft translucent scrim" {
  let t_bad = Tester::tree(
    fn(root) {
      root.box(fn(bar) {
        bar.width(Is(Some(800.0))).height(Is(Some(45.0))).ground(Is(0xFFFFFFFFL)) |> ignore
      })
      |> ignore
      let cap = wk_make_capsule(root, 687.0, 9.0, 104.0, 36.0)
      root.tree.keeps_away(Some((687.0, 9.0, 104.0, 36.0)), owner=cap.id(), band=false)
    },
    w=800.0,
    h=600.0,
  )
  t_bad.frame()
  let faults_bad = t_bad.window_keys_faults()
  assert_true(faults_bad.any(fn(f) { f.contains("[WINDOW_KEYS_K3]") }))
  let t_scrim = Tester::tree(
    fn(root) {
      // Soft translucent scrim (alpha 0x40 < 0xC0) is not a hard bar edge.
      root.box(fn(scrim) {
        scrim.width(Is(Some(800.0))).height(Is(Some(45.0))).ground(Is(0xFFFFFF40L)) |> ignore
      })
      |> ignore
      let cap = wk_make_capsule(root, 687.0, 9.0, 104.0, 36.0)
      root.tree.keeps_away(Some((687.0, 9.0, 104.0, 36.0)), owner=cap.id(), band=false)
    },
    w=800.0,
    h=600.0,
  )
  t_scrim.frame()
  assert_eq(t_scrim.window_keys_faults(), [])
}

///|
test "window_keys_faults: K3 catches 0.5pt rule_line hairline intruding and allows one at y=49" {
  let t_bad = Tester::tree(
    fn(root) {
      root.box(fn(hl) {
        hl.over(Is(true)).padding(Is((0.0, 44.5, 0.0, 0.0))) |> ignore
        hl.box(fn(line) { line.width(Is(Some(800.0))).height(Is(Some(0.5))).ground(Is(0x00000022L)) |> ignore }) |> ignore
      })
      |> ignore
      let cap = wk_make_capsule(root, 687.0, 9.0, 104.0, 36.0)
      root.tree.keeps_away(Some((687.0, 9.0, 104.0, 36.0)), owner=cap.id(), band=false)
    },
    w=800.0,
    h=600.0,
  )
  t_bad.frame()
  assert_true(t_bad.window_keys_faults().any(fn(f) { f.contains("[WINDOW_KEYS_K3]") }))
  let t_ok = Tester::tree(
    fn(root) {
      root.box(fn(hl) {
        hl.over(Is(true)).padding(Is((0.0, 49.0, 0.0, 0.0))) |> ignore
        hl.box(fn(line) { line.width(Is(Some(800.0))).height(Is(Some(0.5))).ground(Is(0x00000022L)) |> ignore }) |> ignore
      })
      |> ignore
      let cap = wk_make_capsule(root, 687.0, 9.0, 104.0, 36.0)
      root.tree.keeps_away(Some((687.0, 9.0, 104.0, 36.0)), owner=cap.id(), band=false)
    },
    w=800.0,
    h=600.0,
  )
  t_ok.frame()
  assert_eq(t_ok.window_keys_faults(), [])
}

///|
test "window_keys_faults: composite-alpha and glass occlusion only exempt opaque or progressive scrims" {
  // 1. Fading-in white overlay (node alpha = 0.05) must NOT hide an underlying overlapping icon.
  let t_fade = Tester::tree(
    fn(root) {
      root.box(fn(layer) {
        layer.over(Is(true)).padding(Is((690.0, 16.0, 0.0, 0.0))) |> ignore
        layer.box(fn(ic) {
          ic.width(Is(Some(16.0))).height(Is(Some(16.0))).ground(Is(0x111111FFL)) |> ignore
        })
        |> ignore
      })
      |> ignore
      root.box(fn(veil) {
        veil.over(Is(true)).width(Is(Some(800.0))).height(Is(Some(50.0))).ground(Is(0xFFFFFFFFL)).alpha(Is(0.05)) |> ignore
      })
      |> ignore
      let cap = wk_make_capsule(root, 687.0, 9.0, 104.0, 36.0)
      root.tree.keeps_away(Some((687.0, 9.0, 104.0, 36.0)), owner=cap.id(), band=false)
    },
    w=800.0,
    h=600.0,
  )
  t_fade.frame()
  assert_true(t_fade.window_keys_faults().any(fn(f) { f.contains("[WINDOW_KEYS_K1]") }))

  // 2. Non-progressive transparent glass must NOT hide an underlying overlapping icon.
  let t_glass = Tester::tree(
    fn(root) {
      root.box(fn(layer) {
        layer.over(Is(true)).padding(Is((690.0, 16.0, 0.0, 0.0))) |> ignore
        layer.box(fn(ic) {
          ic.width(Is(Some(16.0))).height(Is(Some(16.0))).ground(Is(0x111111FFL)) |> ignore
        })
        |> ignore
      })
      |> ignore
      root.box(fn(gl) {
        gl
        .over(Is(true))
        .width(Is(Some(800.0)))
        .height(Is(Some(50.0)))
        .glass(Is(Some(@paint.Glass::frosted(blur=6.0, tint=0xFFFFFF20L, solid=0xFFFFFFFFL))))
        |> ignore
      })
      |> ignore
      let cap = wk_make_capsule(root, 687.0, 9.0, 104.0, 36.0)
      root.tree.keeps_away(Some((687.0, 9.0, 104.0, 36.0)), owner=cap.id(), band=false)
    },
    w=800.0,
    h=600.0,
  )
  t_glass.frame()
  assert_true(t_glass.window_keys_faults().any(fn(f) { f.contains("[WINDOW_KEYS_K1]") }))

  // 3. Zero-strength progressive glass (skipped by renderer at strength <= 0.001) must NOT hide an overlapping icon.
  let t_zero_prog = Tester::tree(
    fn(root) {
      root.box(fn(layer) {
        layer.over(Is(true)).padding(Is((690.0, 16.0, 0.0, 0.0))) |> ignore
        layer.box(fn(ic) {
          ic.width(Is(Some(16.0))).height(Is(Some(16.0))).ground(Is(0x111111FFL)) |> ignore
        })
        |> ignore
      })
      |> ignore
      root.box(fn(gl) {
        gl
        .over(Is(true))
        .width(Is(Some(800.0)))
        .height(Is(Some(50.0)))
        .glass(Is(Some(@paint.Glass::frosted(blur=8.5, tint=0xFFFFFF80L, solid=0xFFFFFFFFL, progressive=true, strength=0.0))))
        |> ignore
      })
      |> ignore
      let cap = wk_make_capsule(root, 687.0, 9.0, 104.0, 36.0)
      root.tree.keeps_away(Some((687.0, 9.0, 104.0, 36.0)), owner=cap.id(), band=false)
    },
    w=800.0,
    h=600.0,
  )
  t_zero_prog.frame()
  assert_true(t_zero_prog.window_keys_faults().any(fn(f) { f.contains("[WINDOW_KEYS_K1]") }))

  // 4. Full-opacity solid bar (alpha = 1.0, ground = 0xFFFFFFFF) drawn over scrolled content DOES occlude it.
  let t_opaque = Tester::tree(
    fn(root) {
      root.box(fn(layer) {
        layer.over(Is(true)).padding(Is((690.0, 16.0, 0.0, 0.0))) |> ignore
        layer.box(fn(ic) {
          ic.width(Is(Some(16.0))).height(Is(Some(16.0))).ground(Is(0x111111FFL)) |> ignore
        })
        |> ignore
      })
      |> ignore
      root.box(fn(bar) {
        bar.over(Is(true)).width(Is(Some(800.0))).height(Is(Some(50.0))).ground(Is(0xFFFFFFFFL)) |> ignore
      })
      |> ignore
      let cap = wk_make_capsule(root, 687.0, 9.0, 104.0, 36.0)
      root.tree.keeps_away(Some((687.0, 9.0, 104.0, 36.0)), owner=cap.id(), band=false)
    },
    w=800.0,
    h=600.0,
  )
  t_opaque.frame()
  assert_eq(t_opaque.window_keys_faults(), [])
}

///|
test "window_keys_faults: paint clips, clips_past, cut_across, and bounds_input are tracked accurately" {
  // 1. Parent with clips=true (without bounds_input) clips out an overflowing icon -> no K1 false positive.
  let t_clipped = Tester::tree(
    fn(root) {
      root.box(fn(c) {
        c.over(Is(true)).width(Is(Some(600.0))).height(Is(Some(50.0))).clips(Is(true)) |> ignore
        c.box(fn(ic) {
          ic.over(Is(true)).offset(Is((690.0, 16.0))).width(Is(Some(16.0))).height(Is(Some(16.0))).ground(Is(0x111111FFL))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      let cap = wk_make_capsule(root, 687.0, 9.0, 104.0, 36.0)
      root.tree.keeps_away(Some((687.0, 9.0, 104.0, 36.0)), owner=cap.id(), band=false)
    },
    w=800.0,
    h=600.0,
  )
  t_clipped.frame()
  assert_eq(t_clipped.window_keys_faults(), [])

  // 2. Parent with bounds_input=true (without clips) leaves an overflowing icon visually drawn -> K1 fires.
  let t_unclipped = Tester::tree(
    fn(root) {
      root.box(fn(c) {
        c.over(Is(true)).width(Is(Some(600.0))).height(Is(Some(50.0))).bounds_input(Is(true)) |> ignore
        c.box(fn(ic) {
          ic.over(Is(true)).offset(Is((690.0, 16.0))).width(Is(Some(16.0))).height(Is(Some(16.0))).ground(Is(0x111111FFL))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      let cap = wk_make_capsule(root, 687.0, 9.0, 104.0, 36.0)
      root.tree.keeps_away(Some((687.0, 9.0, 104.0, 36.0)), owner=cap.id(), band=false)
    },
    w=800.0,
    h=600.0,
  )
  t_unclipped.frame()
  assert_true(t_unclipped.window_keys_faults().any(fn(f) { f.contains("[WINDOW_KEYS_K1]") }))

  // 3. Parent height=20 with clips=true and clips_past=20 extends paint clip to y=40 -> child icon at y=24..36 IS drawn -> K1 fires.
  let t_clips_past = Tester::tree(
    fn(root) {
      root.box(fn(c) {
        c.over(Is(true)).width(Is(Some(800.0))).height(Is(Some(20.0))).clips(Is(true)).clips_past(Is(20.0)) |> ignore
        c.box(fn(ic) {
          ic.over(Is(true)).offset(Is((690.0, 24.0))).width(Is(Some(16.0))).height(Is(Some(12.0))).ground(Is(0x111111FFL))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      let cap = wk_make_capsule(root, 687.0, 9.0, 104.0, 36.0)
      root.tree.keeps_away(Some((687.0, 9.0, 104.0, 36.0)), owner=cap.id(), band=false)
    },
    w=800.0,
    h=600.0,
  )
  t_clips_past.frame()
  assert_true(t_clips_past.window_keys_faults().any(fn(f) { f.contains("[WINDOW_KEYS_K1]") }))

  // 4. Parent width=800 with clips=true and cut_across=(0, 600) clips out child icon at x=690 -> no K1 false positive.
  let t_cut_across = Tester::tree(
    fn(root) {
      root.box(fn(c) {
        c
        .over(Is(true))
        .width(Is(Some(800.0)))
        .height(Is(Some(50.0)))
        .clips(Is(true))
        .cut_across(Is(Some((0.0, 600.0))))
        |> ignore
        c.box(fn(ic) {
          ic.over(Is(true)).offset(Is((690.0, 16.0))).width(Is(Some(16.0))).height(Is(Some(16.0))).ground(Is(0x111111FFL))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      let cap = wk_make_capsule(root, 687.0, 9.0, 104.0, 36.0)
      root.tree.keeps_away(Some((687.0, 9.0, 104.0, 36.0)), owner=cap.id(), band=false)
    },
    w=800.0,
    h=600.0,
  )
  t_cut_across.frame()
  assert_eq(t_cut_across.window_keys_faults(), [])
}

///|
test "window_keys_faults: K0 catches unmounted or undrawn explicit owner node" {
  let shown : @signals.Signal[Bool] = @signals.signal(true)
  let t = Tester::tree(
    fn(root) {
      root.show(fn() { shown.get() }, fn(s) {
        let cap = wk_make_capsule(s, 687.0, 9.0, 104.0, 36.0)
        root.tree.keeps_away(Some((687.0, 9.0, 104.0, 36.0)), owner=cap.id(), band=false)
      })
    },
    w=800.0,
    h=600.0,
  )
  t.frame()
  assert_eq(t.window_keys_faults(), [])
  shown.set(false)
  t.frame()
  assert_true(t.window_keys_faults().any(fn(f) { f.contains("[WINDOW_KEYS_K0]") }))
}

///|
test "window_keys_faults: secondary window uses its own viewport size instead of main window's" {
  // Main window is narrow (480x720), secondary window is wide (800x720). A 0.5pt hairline under the
  // secondary window's right-side capsule (x=600..800, beyond main window's 480) must still trigger K3.
  let t = Tester::new(fn(_c) {  }, w=480.0, h=720.0)
  t.check_looks(false)
  t.set_windows_in_process(true)
  set_window_tree(fn(_wid, _what) {
    fn(root) {
      root.box(fn(rule) {
        rule
        .over(Is(true))
        .offset(Is((600.0, 44.5)))
        .width(Is(Some(200.0)))
        .height(Is(Some(0.5)))
        .ground(Is(0x00000033L))
        |> ignore
      })
      |> ignore
      let cap = wk_make_capsule(root, 687.0, 9.0, 104.0, 36.0)
      root.tree.keeps_away(Some((687.0, 9.0, 104.0, 36.0)), owner=cap.id(), band=false)
    }
  })
  set_view_app(fn(_root) {  })
  t.draw()
  let wid = window_open_here("子窗口")
  t.set_window_beside_size(wid, 800.0, 720.0)
  t.draw()
  let faults : Ref[Array[String]] = Ref([])
  t.in_window(wid, fn() { faults.val = t.window_keys_faults() })
  assert_true(
    faults.val.any(fn(f) { f.contains("[WINDOW_KEYS_K3]") }),
    msg="expected K3 in 800px secondary window under 480px main window, got \{Repr(faults.val)}",
  )
}

///|
test "window_keys_faults: progressive glass faded out to zero at overlap does NOT occlude K1" {
  // Unclipped 24pt parent with bottom fade=(0,0,0,24) holding a 50pt progressive glass (strength=1.0):
  // shader discards pixels for y >= 24 (fade_r == 0), so an icon at y=30..40 is uncovered -> K1 fires.
  let t_faded = Tester::tree(
    fn(root) {
      root.box(fn(layer) {
        layer.over(Is(true)).padding(Is((690.0, 30.0, 0.0, 0.0))) |> ignore
        layer.box(fn(ic) {
          ic.width(Is(Some(16.0))).height(Is(Some(10.0))).ground(Is(0x111111FFL)) |> ignore
        })
        |> ignore
      })
      |> ignore
      root.box(fn(scrim) {
        scrim
        .over(Is(true))
        .width(Is(Some(800.0)))
        .height(Is(Some(24.0)))
        .fades(Is((0.0, 0.0, 0.0, 24.0)))
        |> ignore
        scrim.box(fn(gl) {
          gl
          .over(Is(true))
          .width(Is(Some(800.0)))
          .height(Is(Some(50.0)))
          .glass(Is(Some(@paint.Glass::frosted(blur=8.5, tint=0xFFFFFF80L, solid=0xFFFFFFFFL, progressive=true, strength=1.0))))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      let cap = wk_make_capsule(root, 687.0, 9.0, 104.0, 36.0)
      root.tree.keeps_away(Some((687.0, 9.0, 104.0, 36.0)), owner=cap.id(), band=false)
    },
    w=800.0,
    h=600.0,
  )
  t_faded.frame()
  assert_true(
    t_faded.window_keys_faults().any(fn(f) { f.contains("[WINDOW_KEYS_K1]") }),
    msg="faded-out progressive glass (fade_r=0 at y=30..40) must not occlude K1",
  )

  // Real 66pt top scroll-edge scrim with fade=(0,0,0,66) covering y=16..32 (min fade_r = 34/66 > 0.5) DOES occlude.
  let t_real_scrim = Tester::tree(
    fn(root) {
      root.box(fn(layer) {
        layer.over(Is(true)).padding(Is((690.0, 16.0, 0.0, 0.0))) |> ignore
        layer.box(fn(ic) {
          ic.width(Is(Some(16.0))).height(Is(Some(16.0))).ground(Is(0x111111FFL)) |> ignore
        })
        |> ignore
      })
      |> ignore
      root.box(fn(scrim) {
        scrim
        .over(Is(true))
        .width(Is(Some(800.0)))
        .height(Is(Some(66.0)))
        .fades(Is((0.0, 0.0, 0.0, 66.0)))
        |> ignore
        scrim.box(fn(gl) {
          gl
          .width_share(Is(1.0))
          .height_share(Is(1.0))
          .glass(Is(Some(@paint.Glass::frosted(blur=8.5, tint=0xFFFFFF80L, solid=0xFFFFFFFFL, progressive=true, strength=1.0))))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      let cap = wk_make_capsule(root, 687.0, 9.0, 104.0, 36.0)
      root.tree.keeps_away(Some((687.0, 9.0, 104.0, 36.0)), owner=cap.id(), band=false)
    },
    w=800.0,
    h=600.0,
  )
  t_real_scrim.frame()
  assert_eq(t_real_scrim.window_keys_faults(), [])
}
