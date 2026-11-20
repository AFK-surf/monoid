// Regression tests for:
// 1. View tree single-line soft_min / last_resort (including wrapping rows)
// 2. View::show / View::pick single-child bare structure box row pass-through
// 3. Tester::squeeze_faults detecting horizontal overflow past unclipped shows_ground cards

///|
fn drawn_words_box(prefix : String) -> @view.Drawn {
  let hits = view_tree().unwrap().drawn().filter(fn(d) { d.words.has_prefix(prefix) })
  if hits.is_empty() {
    @halt.saying("no drawn words with prefix: " + prefix)
  }
  hits[0]
}

///|
test "view row last_resort squeezes widest one-line words and containers while keeping buttons whole" {
  let t = Tester::tree(fn(root) {
    root.box(fn(row) {
      row.row(Is(true)).width(Is(Some(160.0))).gap(Is(6.0)) |> ignore
      // wrapped in a plain container box (soft_min = -1.0)
      row.box(fn(wrap) {
        wrap.box(fn(v) {
          v.words(Is("very long descriptive label for this item"), look=sq_look()).allow_ellipsis(Is(true)) |> ignore
        })
        |> ignore
      })
      |> ignore
      row.box(fn(v) {
        v.words(Is("another long piece of text"), look=sq_look()).allow_ellipsis(Is(true)) |> ignore
      })
      |> ignore
      row.box(fn(btn) {
        btn.row(Is(true)).pad(Is(6.0)).on_press(fn() {  }) |> ignore
        btn.box(fn(v) { v.words(Is("Cancel"), look=sq_look()) |> ignore }) |> ignore
      })
      |> ignore
    })
    |> ignore
  }, w=400.0, h=120.0)
  t.draw()
  let c = g()
  let full_cancel = layout_text("Cancel", c.sp(10.0), 400, 1.0e9, false, line=c.sp(14.0), style=view_words_style()).w
  let full_first = layout_text(
    "very long descriptive label for this item",
    c.sp(10.0),
    400,
    1.0e9,
    false,
    line=c.sp(14.0),
    style=view_words_style(),
  ).w
  let cancel = drawn_words_box("Cancel")
  let first = drawn_words_box("very long")
  let second = drawn_words_box("another long")
  assert_true((cancel.w - full_cancel).abs() < 0.5, msg="Cancel width \{cancel.w} vs full \{full_cancel}")
  assert_true(first.w < full_first - 1.0, msg="first width \{first.w} not squeezed below \{full_first}")
  assert_true(cancel.x + cancel.w + 6.0 <= 160.0 + 0.5, msg="button right \{cancel.x + cancel.w + 6.0} past 160")
  assert_true(second.x + second.w <= 160.0 + 0.5, msg="second right \{second.x + second.w} past 160")
  assert_eq(t.squeeze_faults(), [])
}

///|
test "view wrapping row runs last_resort on a single overwide line" {
  let t = Tester::tree(fn(root) {
    root.box(fn(row) {
      row.row(Is(true)).wraps(Is(Some(4.0))).width(Is(Some(120.0))).gap(Is(6.0)) |> ignore
      row.box(fn(v) { v.words(Is("Tag"), look=sq_look()) |> ignore }) |> ignore
      row.box(fn(v) {
        v.words(Is("an overly wide line item that wraps onto its own line"), look=sq_look()).allow_ellipsis(Is(true))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  }, w=400.0, h=120.0)
  t.draw()
  let tag = drawn_words_box("Tag")
  let long = drawn_words_box("an overly wide")
  assert_true(long.y > tag.y + 1.0, msg="long item did not wrap: long.y=\{long.y} tag.y=\{tag.y}")
  assert_true(long.x + long.w <= 120.0 + 0.5, msg="wrapped line overflows: \{long.x} + \{long.w}")
  assert_eq(t.squeeze_faults(), [])
}

///|
test "view row last_resort does not cut words in vain when fixed-width sibling overflows" {
  let t = Tester::tree(fn(root) {
    root.box(fn(row) {
      row.row(Is(true)).width(Is(Some(100.0))) |> ignore
      row.box(fn(v) { v.words(Is("Size"), look=sq_look()) |> ignore }) |> ignore
      row.box(fn(v) { v.width(Is(Some(120.0))).height(Is(Some(20.0))) |> ignore }) |> ignore
    })
    |> ignore
  }, w=400.0, h=100.0)
  t.draw()
  let c = g()
  let full = layout_text("Size", c.sp(10.0), 400, 1.0e9, false, line=c.sp(14.0), style=view_words_style()).w
  let size = drawn_words_box("Size")
  assert_true((size.w - full).abs() < 0.5, msg="Size width \{size.w} vs full \{full}")
}

///|
test "view pressable row button does not cut its own direct text child via last_resort" {
  let t = Tester::tree(fn(root) {
    root.box(fn(btn) {
      btn.row(Is(true)).width(Is(Some(80.0))).sides(Is((12.0, 12.0))).on_press(fn() {  }) |> ignore
      btn.box(fn(v) { v.words(Is("Save to Photos"), look=sq_look()) |> ignore }) |> ignore
    })
    |> ignore
  }, w=400.0, h=100.0)
  t.draw()
  let c = g()
  let full = layout_text("Save to Photos", c.sp(10.0), 400, 1.0e9, false, line=c.sp(14.0), style=view_words_style()).w
  let label = drawn_words_box("Save to Photos")
  assert_true((label.w - full).abs() < 0.5, msg="button label width \{label.w} vs full \{full}")
}

///|
test "view show and pick single-child bare structure box forwards cuts in row while multi-child stays column" {
  let t = Tester::tree(fn(root) {
    root.box(fn(row1) {
      row1.row(Is(true)).width(Is(Some(120.0))).gap(Is(6.0)) |> ignore
      row1.show(fn() { true }, fn(a) {
        a.box(fn(w) { w.cuts(Is(true)).words(Is("very long shown label inside row"), look=sq_look()) |> ignore })
        |> ignore
      })
      row1.box(fn(b) { b.width(Is(Some(40.0))).height(Is(Some(16.0))).ground(Is(0x00FF00FFL)) |> ignore }) |> ignore
    })
    |> ignore
    root.box(fn(row2) {
      row2.row(Is(true)).width(Is(Some(120.0))).gap(Is(6.0)) |> ignore
      row2.pick(fn() { 1 }, fn(a, _) {
        a.box(fn(w) { w.cuts(Is(true)).words(Is("very long picked label inside row"), look=sq_look()) |> ignore })
        |> ignore
      })
      row2.box(fn(b) { b.width(Is(Some(40.0))).height(Is(Some(16.0))).ground(Is(0x00FF00FFL)) |> ignore }) |> ignore
    })
    |> ignore
    root.box(fn(row3) {
      row3.row(Is(true)).width(Is(Some(200.0))) |> ignore
      row3.show(fn() { true }, fn(col) {
        col.box(fn(v) { v.words(Is("TopLine"), look=sq_look()) |> ignore }) |> ignore
        col.box(fn(v) { v.words(Is("BottomLine"), look=sq_look()) |> ignore }) |> ignore
      })
    })
    |> ignore
  }, w=400.0, h=200.0)
  t.draw()
  let shown = drawn_words_box("very long shown")
  let picked = drawn_words_box("very long picked")
  let top = drawn_words_box("TopLine")
  let bot = drawn_words_box("BottomLine")
  assert_true(shown.x + shown.w <= 74.5, msg="shown right \{shown.x + shown.w} expected <= 74.5")
  assert_true(picked.x + picked.w <= 74.5, msg="picked right \{picked.x + picked.w} expected <= 74.5")
  assert_true(bot.y >= top.y + top.h - 0.5, msg="multi-child show did not stay column: top=\{top.y}+\{top.h} bot=\{bot.y}")
  assert_eq(t.squeeze_faults(), [])
}

///|
test "squeeze_faults catches child running past unclipped grounded card in view and ctx" {
  // View tree card with ground
  let v_ground = sq_tree(fn(root) {
    root.box(fn(card) {
      card.width(Is(Some(200.0))).ground(Is(0xFFFFFFFFL)) |> ignore
      card.box(fn(child) {
        child.width(Is(Some(240.0))).height(Is(Some(20.0))).ground(Is(0x00FF00FFL)) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  assert_true(sq_one(v_ground, "runs 40 past"), msg=v_ground.join("\n"))
  // View tree card with edge only
  let v_edge = sq_tree(fn(root) {
    root.box(fn(card) {
      card.width(Is(Some(200.0))).edge(Is((1.0, 0xCCCCCCFFL))) |> ignore
      card.box(fn(child) {
        child.width(Is(Some(240.0))).height(Is(Some(20.0))).ground(Is(0x00FF00FFL)) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  assert_true(sq_one(v_edge, "runs 40 past"), msg=v_edge.join("\n"))
  // Legacy Ctx card with ground
  let old_ground = sq_old(fn(c) {
    c.box(w=Px(200.0), bg=0xFFFFFFFFL, fn() {
      c.box(w=Px(240.0), h=Px(20.0), bg=0x00FF00FFL, fn() {  }) |> ignore
    })
    |> ignore
  })
  assert_true(sq_one(old_ground, "runs 40 past"), msg=old_ground.join("\n"))
  // Deliberate negative margin overhang: no fault
  let v_neg = sq_tree(fn(root) {
    root.box(fn(card) {
      card.width(Is(Some(200.0))).ground(Is(0xFFFFFFFFL)) |> ignore
      card.box(fn(child) {
        child
        .width(Is(Some(240.0)))
        .height(Is(Some(20.0)))
        .margin(Is((0.0, 0.0, -40.0, 0.0)))
        .ground(Is(0x00FF00FFL))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  assert_eq(v_neg, [])
  // Deliberate over(true) overlay: no fault
  let v_over = sq_tree(fn(root) {
    root.box(fn(card) {
      card.width(Is(Some(200.0))).height(Is(Some(40.0))).ground(Is(0xFFFFFFFFL)) |> ignore
      card.box(fn(child) {
        child.over(Is(true)).width(Is(Some(240.0))).height(Is(Some(20.0))).ground(Is(0x00FF00FFL)) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  assert_eq(v_over, [])
  // Deliberate horizontal scroll container inside card: no fault
  let sc = @view.Scroll::across()
  let v_scroll = sq_tree(fn(root) {
    root.box(fn(card) {
      card.width(Is(Some(200.0))).ground(Is(0xFFFFFFFFL)) |> ignore
      card.box(fn(s) {
        s.scrolls(sc, fn(inner) {
          inner.box(fn(child) {
            child.width(Is(Some(240.0))).height(Is(Some(20.0))).ground(Is(0x00FF00FFL)) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  assert_eq(v_scroll, [])
}
