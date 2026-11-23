// The library's outlined controls (control_edge.mbt): a field, lines to type in, a select, a filter pill, an
// accordion's card and the choices' cards each edged in one hairline, the theme's line at rest and its border pointed
// at or written in, light and dark; a chosen card's ring of the ink kept; nothing the audit or the corners find.

///|
/// A window 600 wide, keyboard and mouse, the library's theme light or `dark`, holding what `make` makes, 16 in from
/// its sides, 16 apart.
fn edge_case(dark : Bool, make : (@view.View) -> Unit, solid? : Bool = false) -> @ui.Tester {
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=640.0, platform=0)
  t.check_looks(false)
  set_dark(Some(dark))
  @ui.set_glass_solid(if solid { Some(true) } else { None })
  // (the library's theme the tree's: set_view_app lets the tree's theme before it go)
  @ui.set_view_app(
    fn(root) {
      root.padding(Is((16.0, 16.0, 16.0, 16.0))).gap(Is(16.0)) |> ignore
      make(root)
    },
    theme=ui_theme_now,
  )
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// The boxes edged now at least `w` wide (not a radio's ring), each its edge's width and colour, in order.
fn edged(t : @ui.Tester, w? : Double = 60.0) -> Array[@ui.Laid] {
  t.boxes_held().filter(fn(b) { b.border_w > 0.0 && b.w >= w })
}

///|
fn edge_of(b : @ui.Laid) -> (Double, Int64) {
  (b.border_w, b.border_c)
}

///|
/// The pointer on `b`'s middle, its moment run.
fn point_at(t : @ui.Tester, b : @ui.Laid) -> Unit {
  t.move_to(b.x + b.w / 2.0, b.y + b.h / 2.0)
  t.run_for(@ui.move_most_ms)
}

///|
fn edges_said(t : @ui.Tester) -> String {
  edged(t, w=0.0).map(fn(b) { "\{b.kind} \{b.w}x\{b.h} \{b.border_w} \{b.border_c.to_string(radix=16)}" }).join("; ")
}

///|
fn edge_clean(t : @ui.Tester, what : String) -> Unit raise {
  assert_eq(t.audit(), [], msg="\{what}: \{edges_said(t)} line \{theme().p.line.to_string(radix=16)} strong \{theme().p.line_strong.to_string(radix=16)}")
  assert_eq(t.corner_faults(), [], msg="\{what}: \{edges_said(t)} line \{theme().p.line.to_string(radix=16)} strong \{theme().p.line_strong.to_string(radix=16)}")
}

///|
test "a field and lines to type in: a hairline of the line at rest, of the border written in; solid, the ground's; light and dark" {
  for dark in [false, true] {
    for kind in ["input", "textarea", "solid"] {
      let what = "\{kind} dark \{dark}"
      let t = edge_case(dark, fn(root) {
        root.box(fn(b) {
          b.width(Is(Some(300.0))) |> ignore
          match kind {
            "input" => input_node(b, @ui.Field::new(), placeholder="名字") |> ignore
            "textarea" => textarea_node(b, @ui.Field::new(), placeholder="指令") |> ignore
            _ => input_node(b, @ui.Field::new(), placeholder="名字", solid=true) |> ignore
          }
        })
        |> ignore
      })
      let p = theme().p
      let rest = edged(t)
      assert_eq(rest.length(), 1, msg="\{what}: \{edges_said(t)} line \{theme().p.line.to_string(radix=16)} strong \{theme().p.line_strong.to_string(radix=16)}")
      let ground = @ui.tree_theme().color(Bg)
      assert_eq(edge_of(rest[0]), (0.5, if kind == "solid" { ground } else { p.line }), msg="\{what}: \{edges_said(t)} line \{theme().p.line.to_string(radix=16)} strong \{theme().p.line_strong.to_string(radix=16)}")
      edge_clean(t, what)
      t.tap(rest[0].x + 40.0, rest[0].y + 17.0)
      t.run_for(@ui.move_most_ms)
      let hot = edged(t)
      assert_eq(hot.length(), 1, msg="\{what}: \{edges_said(t)} line \{theme().p.line.to_string(radix=16)} strong \{theme().p.line_strong.to_string(radix=16)}")
      assert_eq(edge_of(hot[0]), (0.5, p.line_strong), msg="\{what} written in")
    }
  }
}

///|
test "a select: a hairline of the line at rest, of the border under the pointer; light and dark" {
  for dark in [false, true] {
    let what = "dark \{dark}"
    let t = edge_case(dark, fn(root) {
      select_node(root, fn() { "a" }, fn() { [("a", "Office-Host-2"), ("b", "Studio")] }, fn(_) {  }, label=fn() {
        "Station"
      })
    })
    let p = theme().p
    let rest = edged(t)
    assert_eq(rest.length(), 1, msg="\{what}: \{edges_said(t)} line \{theme().p.line.to_string(radix=16)} strong \{theme().p.line_strong.to_string(radix=16)}")
    assert_eq(edge_of(rest[0]), (0.5, p.line), msg="\{what}: \{edges_said(t)} line \{theme().p.line.to_string(radix=16)} strong \{theme().p.line_strong.to_string(radix=16)}")
    edge_clean(t, what)
    point_at(t, rest[0])
    assert_eq(edged(t).map(edge_of), [(0.5, p.line_strong)], msg="\{what} pointed at")
  }
}

///|
test "a filter pill: a hairline of the line, picked or not; light and dark" {
  for dark in [false, true] {
    for picked in [false, true] {
      let what = "picked \{picked} dark \{dark}"
      let t = edge_case(dark, fn(root) {
        root.box(fn(row) {
          row.row(Is(true)) |> ignore
          filter_pill_node(row, fn() { "Office" }, fn(_) {  }, picked=fn() { picked }) |> ignore
        })
        |> ignore
      })
      assert_eq(edged(t).map(edge_of), [(0.5, theme().p.line)], msg="\{what}: \{edges_said(t)} line \{theme().p.line.to_string(radix=16)} strong \{theme().p.line_strong.to_string(radix=16)}")
      edge_clean(t, what)
    }
  }
}

///|
test "an accordion's card: a hairline of the line; light and dark" {
  for dark in [false, true] {
    let what = "dark \{dark}"
    let t = edge_case(dark, fn(root) {
      let section = fn(name : String) {
        accordion_section(name, fn() { name }, fn(p) { words_node(p, fn() { name + "的内容" }, fn() { paragraph }) |> ignore })
      }
      accordion_node(root, [section("概览"), section("权限")], fn(k) { k == "概览" }, fn(_) {  }) |> ignore
    })
    assert_eq(edged(t).map(edge_of), [(0.5, theme().p.line)], msg="\{what}: \{edges_said(t)} line \{theme().p.line.to_string(radix=16)} strong \{theme().p.line_strong.to_string(radix=16)}")
    edge_clean(t, what)
  }
}

///|
test "choices: the others a hairline of the line, of the border under the pointer; the chosen one ringed 2 in the ink; light and dark" {
  for dark in [false, true] {
    let what = "dark \{dark}"
    let t = edge_case(dark, fn(root) {
      choices_node(
        root,
        fn() { "auto" },
        fn() { [("auto", "自动选择", "按工作区的默认设置挑选最合适的一台"), ("pick", "指定机器", "")] },
        fn(_) {  },
        label=fn() { "在哪里运行" },
      )
    })
    let p = theme().p
    let ink = @ui.tree_theme().color(Fg)
    let rest = edged(t)
    assert_eq(rest.map(edge_of), [(2.0, ink), (0.5, p.line)], msg="\{what}: \{edges_said(t)} line \{theme().p.line.to_string(radix=16)} strong \{theme().p.line_strong.to_string(radix=16)}")
    edge_clean(t, what)
    point_at(t, rest[1])
    assert_eq(edged(t).map(edge_of), [(2.0, ink), (0.5, p.line_strong)], msg="\{what} pointed at")
  }
}

///|
test "float_button_node and pick_bar_node use hairline control_edge_w (0.5pt) in solid mode and no extra edge on liquid glass" {
  for dark in [false, true] {
    let tg = edge_case(dark, fn(root) {
      root.lines_up(Is(Some(Start))) |> ignore
      float_button_node(root, "arrow-down", fn() { "最新" }, fn() {  }) |> ignore
      pick_bar_node(root, [{ label: "复制", icon: "copy", mark: false, press: fn() {  } }]) |> ignore
    })
    assert_eq(edged(tg, w=20.0).length(), 0, msg="glass dark \{dark}: \{edges_said(tg)}")
    edge_clean(tg, "float_button & pick_bar glass dark \{dark}")

    let ts = edge_case(
      dark,
      fn(root) {
        root.lines_up(Is(Some(Start))) |> ignore
        float_button_node(root, "arrow-down", fn() { "最新" }, fn() {  }) |> ignore
        pick_bar_node(root, [{ label: "复制", icon: "copy", mark: false, press: fn() {  } }]) |> ignore
      },
      solid=true,
    )
    let bs = edged(ts, w=20.0)
    assert_eq(bs.length(), 2, msg="solid dark \{dark}: \{edges_said(ts)}")
    for b in bs {
      assert_eq(edge_of(b), (control_edge_w, theme().p.line), msg="solid dark \{dark}: \{edges_said(ts)}")
    }
    edge_clean(ts, "float_button & pick_bar solid dark \{dark}")
  }
  @ui.set_glass_solid(None)
  set_dark(None)
}
