// Tests for `row_height_node.mbt` and `page_skeleton_node.mbt`:
// 1. `list_page_node` 500-item scroll block reuse (O(visible) nodes made, scrolled text accurate).
// 2. `list_page_node` loading -> empty -> data three-state switching without leftovers.
// 3. `reused_page_node` 100-block default block reuse with a single builder callback.
// 4. `detail_page_node` narrow (390x844, 1.0x/1.3x, light/dark) and wide (1280x800, light/dark) full audit.
// 5. `cached_row_height` / `fixed_row_node` single-cell cache hit, 1.0x->1.3x recompute, zero `fixed_outgrown` & audit.

///|
fn run_list_500(reuse : Bool) -> (Int, Int, Int) raise {
  let scroll = @view.Scroll::list()
  let keys = Array::makei(500, fn(i) { i })
  let item_made = Ref(0)
  let t = @ui.Tester::tree(w=390.0, h=844.0, platform=2, theme=fn() { ui_theme() }, fn(root) {
    root.box(fn(b) {
      b.height(Is(Some(844.0))).width(Is(Some(390.0))) |> ignore
      let opts : ListPageOpts[Int] = {
        ..ListPageOpts::default(),
        reuses: fn(_) { reuse },
        scroll: Some(scroll),
        width: Some(fn() { 390.0 }),
        est: 56.0,
      }
      list_page_node(
        b,
        fn() { "Items" },
        fn() { keys },
        fn(room, key) {
          item_made.val = item_made.val + 1
          fixed_row_node(room, fn() { "Row #\{key()}" }, press=fn() {  }, fn(row) { row.chevron() })
        },
        on_back=fn() {  },
        opts~,
      )
    })
    |> ignore
  })
  t.draw()
  let tree = @ui.view_tree().unwrap()
  let initial_made = tree.work().made
  assert_true(t.rect_of("Row #0") is Some(_), msg="initial top row visible")
  // Scroll 10 screens down (~8000 px) in smooth 120 px steps
  for step in 1..<=67 {
    scroll.put(step.to_double() * 120.0)
    t.draw()
    t.draw()
  }
  let after_made = tree.work().made
  let visible_rows = tree
    .drawn()
    .filter(fn(d) { d.words.has_prefix("Row #") && d.y + d.h > 0.0 && d.y < 844.0 })
    .map(fn(d) { d.words })
  assert_true(visible_rows.length() > 0, msg="rows visible after 10 screens")
  let rows_s = visible_rows.join(", ")
  assert_true(!visible_rows.contains("Row #0"), msg="scrolled past Row #0: \{rows_s}")
  assert_true(
    visible_rows.iter().any(fn(s) {
      let num = s.strip_prefix("Row #").unwrap_or("0")
      num.length() >= 3
    }),
    msg="expected high-index rows at y=8000, got \{rows_s}",
  )
  assert_eq(t.fixed_outgrown(), [])
  assert_eq(t.audit(), [])
  (item_made.val, initial_made, after_made)
}

///|
test "list_page_node: 500 items scrolled 10 screens reuses blocks (O(visible) made) and updates visible labels" {
  let (fresh_items, fresh_init, fresh_after) = run_list_500(false)
  let (reused_items, reused_init, reused_after) = run_list_500(true)
  let fresh_delta = fresh_after - fresh_init
  let reused_delta = reused_after - reused_init
  // Block reuse proof: item builder called O(visible) vs O(scrolled rows) without reuse
  assert_true(fresh_items >= 140, msg="fresh_items=\{fresh_items}")
  assert_true(reused_items > 0 && reused_items < 40, msg="reused_items=\{reused_items} (fresh=\{fresh_items})")
  assert_true(
    reused_delta * 3 < fresh_delta,
    msg="reused_delta=\{reused_delta} vs fresh_delta=\{fresh_delta} (reused_after=\{reused_after}, fresh_after=\{fresh_after})",
  )
}

///|
test "list_page_node: loading -> empty -> data three-state switch with no leftovers" {
  let loading = @signals.signal(true)
  let keys : @signals.Signal[Array[Int]] = @signals.signal([])
  let t = @ui.Tester::tree(w=390.0, h=844.0, platform=2, theme=fn() { ui_theme() }, fn(root) {
    root.box(fn(b) {
      b.height(Is(Some(844.0))).width(Is(Some(390.0))) |> ignore
      let opts : ListPageOpts[Int] = {
        ..ListPageOpts::default(),
        width: Some(fn() { 390.0 }),
        loading: Some(fn() { loading.get() }),
        empty: Some(fn(e) { empty_state_node(e, "list", fn() { "暂无记录" }) |> ignore }),
      }
      list_page_node(
        b,
        fn() { "Records" },
        fn() { keys.get() },
        fn(room, key) { fixed_row_node(room, fn() { "Entry \{key()}" }, fn(_) {  }) },
        on_back=fn() {  },
        opts~,
      )
    })
    |> ignore
  })
  t.draw()
  // 1. Loading state: skeleton cards shown, neither empty state nor data rows
  assert_true(t.rect_of("暂无记录") is None, msg="empty hidden while loading")
  assert_true(t.rect_of("Entry 0") is None, msg="data hidden while loading")
  assert_true(t.drawn_rects().length() > 0, msg="skeleton rects drawn")
  assert_eq(t.audit(), [], msg="loading audit")

  // 2. Empty state: empty_state_node shown, no data rows
  loading.set(false)
  t.draw()
  assert_true(t.rect_of("暂无记录") is Some(_), msg="empty state visible")
  assert_true(t.rect_of("Entry 0") is None, msg="data still absent")
  assert_eq(t.audit(), [], msg="empty audit")

  // 3. Data state: rows shown, empty state gone
  keys.set([0, 1, 2])
  t.draw()
  assert_true(t.rect_of("暂无记录") is None, msg="empty state removed")
  assert_true(t.rect_of("Entry 0") is Some(_), msg="Entry 0 visible")
  assert_true(t.rect_of("Entry 2") is Some(_), msg="Entry 2 visible")
  assert_eq(t.fixed_outgrown(), [])
  assert_eq(t.audit(), [], msg="data audit")
}

///|
test "reused_page_node: 100 blocks default pooled reuse with single builder" {
  let blocks = Array::makei(100, fn(i) { "k\{i}" })
  let made = Ref(0)
  let t = @ui.Tester::tree(w=390.0, h=800.0, platform=2, theme=fn() { ui_theme() }, fn(root) {
    root.box(fn(b) {
      b.height(Is(Some(800.0))).width(Is(Some(390.0))) |> ignore
      // Use a small wrapper with reused_page_node; scroll via wheel
      reused_page_node(
        b,
        fn() { "Reused" },
        fn() { blocks },
        fn(room, kind, key) {
          if kind == 0 {
            made.val = made.val + 1
          }
          room.box(fn(r) { r.height(Is(Some(60.0))).words(By(fn() { "blk " + key() })) |> ignore }) |> ignore
        },
        on_back=fn() {  },
        width=fn() { 390.0 },
      )
    })
    |> ignore
  })
  t.draw()
  assert_true(t.rect_of("blk k0") is Some(_), msg="k0 visible at top")
  // Scroll several screens via wheel (positive dy scrolls down)
  for _ in 0..<25 {
    t.wheel(195.0, 400.0, 120.0)
    t.draw()
  }
  let tree = @ui.view_tree().unwrap()
  let visible = tree
    .drawn()
    .filter(fn(d) { d.words.has_prefix("blk ") && d.y + d.h > 0.0 && d.y < 800.0 })
    .map(fn(d) { d.words })
  let vis_s = visible.join(", ")
  assert_true(visible.length() > 0, msg="blocks visible after scrolling")
  assert_true(!visible.contains("blk k0"), msg="scrolled past k0: \{vis_s}")
  assert_true(made.val > 0 && made.val < 40, msg="reused_page_node made=\{made.val} (expected << 100)")
  assert_eq(t.audit(), [])
}

///|
test "detail_page_node: narrow (390x844, 1.0x/1.3x, light/dark) and wide (1280x800, light/dark) full audit" {
  let cases : Array[(Double, Double, Int, Double, Bool)] = [
    (390.0, 844.0, 2, 1.0, false),
    (390.0, 844.0, 2, 1.0, true),
    (390.0, 844.0, 2, 1.3, false),
    (390.0, 844.0, 2, 1.3, true),
    (1280.0, 800.0, 0, 1.0, false),
    (1280.0, 800.0, 0, 1.0, true),
  ]
  for c in cases {
    let (w, h, platform, scale, dark) = c
    let loading = @signals.signal(false)
    let t = @ui.Tester::tree(w~, h~, platform~, dark~, theme=fn() { ui_theme() }, fn(root) {
      root.box(fn(b) {
        b.height(Is(Some(h))).width(Is(Some(w))) |> ignore
        detail_page_node(
          b,
          fn() { "Detail Page" },
          fn(room) {
            group_node(room, fn(g) {
              fixed_row_node(g, fn() { "Account" }, press=fn() {  }, fn(row) {
                row.value(fn() { "Active" })
                row.chevron()
              })
              fixed_row_node(g, fn() { "Notifications" }, press=fn() {  }, two_line=true, fn(row) {
                row.note(fn() { "Alerts and updates" }, cut=true)
                row.chevron()
              })
            })
          },
          on_back=fn() {  },
          frame=fn() { { back: Some("Back"), top: 12.0, foot: 16.0, named: false } },
          width=fn() { w },
          actions=fn(a) { button_node(a, fn() { "Edit" }, fn() {  }) |> ignore },
          loading=fn() { loading.get() },
        )
      })
      |> ignore
    })
    if scale != 1.0 {
      t.set_font_scale(scale)
    }
    t.draw()
    let tag = "\{w}x\{h} scale=\{scale} dark=\{dark}"
    assert_true(t.rect_of("Detail Page") is Some(_), msg="\{tag}: title visible")
    assert_true(t.rect_of("Account") is Some(_), msg="\{tag}: row visible")
    assert_eq(t.fixed_outgrown(), [], msg="\{tag}: fixed_outgrown")
    let faults = t.audit()
    let faults_s = faults.join("; ")
    assert_eq(faults, [], msg="\{tag}: audit: \{faults_s}")

    // Also verify loading skeleton passes audit
    loading.set(true)
    t.draw()
    assert_true(t.rect_of("Account") is None, msg="\{tag}: body hidden while loading")
    let load_faults = t.audit()
    let load_faults_s = load_faults.join("; ")
    assert_eq(load_faults, [], msg="\{tag}: loading audit: \{load_faults_s}")
  }
}

///|
test "cached_row_height and fixed_row_node: single-cell cache hit and 1.0x->1.3x recompute with zero fixed_outgrown" {
  let calls = Ref(0)
  let cached_fn : Ref[(() -> Double)?] = Ref(None)
  let h1_fn : Ref[(() -> Double)?] = Ref(None)
  let h2_fn : Ref[(() -> Double)?] = Ref(None)
  let t = @ui.Tester::tree(w=390.0, h=844.0, platform=2, theme=fn() { ui_theme() }, fn(root) {
    root.box(fn(b) {
      b.height(Is(Some(844.0))).width(Is(Some(390.0))) |> ignore
      cached_fn.val = Some(
        cached_row_height(b, fn(scale) {
          calls.val = calls.val + 1
          (48.0 * scale).ceil()
        }),
      )
      h1_fn.val = Some(std_row_height(b, two_line=false))
      h2_fn.val = Some(std_row_height(b, two_line=true))
      page_block(b, fn(room) {
        group_node(room, fn(g) {
          fixed_row_node(g, fn() { "Single Line" }, press=fn() {  }, two_line=false, fn(row) { row.chevron() })
          fixed_row_node(g, fn() { "Two Line" }, press=fn() {  }, two_line=true, fn(row) {
            row.note(fn() { "Subtitle description" }, cut=true)
            row.chevron()
          })
        })
      })
    })
    |> ignore
  })
  t.draw()
  let getter = cached_fn.val.unwrap()
  let first = getter()
  let second = getter()
  let third = getter()
  assert_eq(first, 48.0)
  assert_eq(second, 48.0)
  assert_eq(third, 48.0)
  assert_eq(calls.val, 1, msg="measure called only once on repeated reads")

  let h1_10 = (h1_fn.val.unwrap())()
  let h2_10 = (h2_fn.val.unwrap())()
  assert_true(h1_10 >= 44.0, msg="single-line floor: \{h1_10}")
  assert_true(h2_10 >= 56.0 && h2_10 > h1_10, msg="two-line floor: \{h2_10} > \{h1_10}")
  assert_eq(t.fixed_outgrown(), [], msg="1.0x fixed_outgrown")
  let audit10 = t.audit()
  let audit10_s = audit10.join("; ")
  assert_eq(audit10, [], msg="1.0x audit: \{audit10_s}")

  // Switch font scale 1.0x -> 1.3x: cache invalidates, height grows, zero fixed_outgrown
  t.set_font_scale(1.3)
  t.draw()
  let scaled = getter()
  let scaled_again = getter()
  assert_eq(scaled, scaled_again)
  assert_true(scaled > first, msg="scaled \{scaled} > \{first}")
  assert_eq(calls.val, 2, msg="measure called once more after scale change")

  let h1_13 = (h1_fn.val.unwrap())()
  let h2_13 = (h2_fn.val.unwrap())()
  assert_true(h1_13 > h1_10, msg="1.3x single-line grew: \{h1_13} > \{h1_10}")
  assert_true(h2_13 > h2_10, msg="1.3x two-line grew: \{h2_13} > \{h2_10}")
  assert_eq(t.fixed_outgrown(), [], msg="1.3x fixed_outgrown")
  assert_eq(t.audit(), [], msg="1.3x audit")
}

///|
test "list_page_node and detail_page_node mount TipLayer overlay without blocking controls or audit faults" {
  // 1. list_page_node
  let list_tips : Ref[TipLayer?] = Ref(None)
  let list_pressed = Ref(false)
  let t1 = @ui.Tester::tree(w=1280.0, h=800.0, platform=0, theme=fn() { ui_theme() }, fn(root) {
    root.box(fn(b) {
      b.height(Is(Some(800.0))).width(Is(Some(1280.0))) |> ignore
      let opts : ListPageOpts[Int] = {
        ..ListPageOpts::default(),
        width: Some(fn() { 1280.0 }),
        actions: Some(fn(a) {
          button_node(a, fn() { "Refresh" }, fn() { list_pressed.val = true }) |> ignore
        }),
      }
      list_page_node(
        b,
        fn() { "List Tips" },
        fn() { [0, 1] },
        fn(room, key) {
          if list_tips.val is None {
            list_tips.val = room.lent(skeleton_tips_lent)
          }
          fixed_row_node(room, fn() { "Item \{key()}" }, fn(_) {  })
        },
        on_back=fn() {  },
        opts~,
      )
    })
    |> ignore
  })
  t1.draw()
  let lt = list_tips.val.unwrap()
  match (lt.layer)() {
    Some(host) => {
      host.box(fn(tip) { tip.words(Is("List Tip Ready")) |> ignore }) |> ignore
      t1.draw()
      assert_true(t1.rect_of("List Tip Ready") is Some(_), msg="list TipLayer renders mounted tip")
    }
    None => fail("list_page_node TipLayer host not mounted")
  }
  t1.act(Button, Activate, label="Refresh")
  assert_true(list_pressed.val, msg="list action button clickable under TipLayer overlay")
  assert_eq(t1.audit(), [], msg="list_page_node TipLayer audit")

  // 2. detail_page_node
  let detail_tips : Ref[TipLayer?] = Ref(None)
  let detail_pressed = Ref(false)
  let t2 = @ui.Tester::tree(w=1280.0, h=800.0, platform=0, theme=fn() { ui_theme() }, fn(root) {
    root.box(fn(b) {
      b.height(Is(Some(800.0))).width(Is(Some(1280.0))) |> ignore
      detail_page_node(
        b,
        fn() { "Detail Tips" },
        fn(room) {
          detail_tips.val = room.lent(skeleton_tips_lent)
          group_node(room, fn(g) { fixed_row_node(g, fn() { "Field" }, fn(_) {  }) })
        },
        on_back=fn() {  },
        width=fn() { 1280.0 },
        actions=fn(a) { button_node(a, fn() { "Save" }, fn() { detail_pressed.val = true }) |> ignore },
      )
    })
    |> ignore
  })
  t2.draw()
  let dt = detail_tips.val.unwrap()
  match (dt.layer)() {
    Some(host) => {
      host.box(fn(tip) { tip.words(Is("Detail Tip Ready")) |> ignore }) |> ignore
      t2.draw()
      assert_true(t2.rect_of("Detail Tip Ready") is Some(_), msg="detail TipLayer renders mounted tip")
    }
    None => fail("detail_page_node TipLayer host not mounted")
  }
  t2.act(Button, Activate, label="Save")
  assert_true(detail_pressed.val, msg="detail action button clickable under TipLayer overlay")
  assert_eq(t2.audit(), [], msg="detail_page_node TipLayer audit")
}
