// The library's lines to type in as nodes (input_node, textarea_node) drawn as the old ones (input, textarea) are, each
// instance at the same moment: at rest, the pointer on the field, written in (tapped, the caret there) and a word typed;
// started with keyboard and mouse or touch, at the system's size of words 1 and 2; one line, one in a small panel,
// lines. Each in the app's theme, as both are drawn in the app (the old in ui_theme, the tree in ui_theme_now).

///|
/// Which line to type in: one line, one a small panel's (`small`), lines (textarea).
#derive(Debug)
priv enum FieldKind {
  OneLine
  SmallLine
  ManyLines
}

///|
/// A line to type in of `kind` in a column 300 wide at the window's top left, started as `platform`, words `scale` as
/// big, holding `f`. The Tester.
fn field_look_case(kind : FieldKind, platform : Int, scale : Double, f : @ui.Field) -> @ui.Tester {
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=400.0, h=300.0, platform~)
  t.set_font_scale(scale)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(b) {
      b.width(Is(Some(300.0))) |> ignore
      match kind {
        OneLine => input_node(b, f, placeholder="名字") |> ignore
        SmallLine => input_node(b, f, placeholder="名字", small=true) |> ignore
        ManyLines => textarea_node(b, f, placeholder="名字") |> ignore
      }
    })
    |> ignore
  })
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// What is drawn now, each instance rounded to a hundredth (a glyph's atlas place said as its kind), in order.
fn field_look_drawn(t : @ui.Tester) -> Array[String] {
  let all = t.drawn_instances().map(fn(a) {
    a
    .mapi(fn(j, x) {
      if a[5] == 1.0 && j == 12 {
        if x >= 16384.0 { "colour" } else { "mono" }
      } else if a[5] == 1.0 && j == 13 {
        "-"
      } else {
        ((x * 100.0).round() / 100.0).to_string()
      }
    })
    .join(",")
  })
  all.sort()
  all
}

///|
/// The case's states, each drawn: at rest; with a mouse, the pointer on the field's middle; tapped there (written in);
/// a word typed. Named.
fn field_look_states(kind : FieldKind, platform : Int, scale : Double) -> Array[(String, Array[String])] {
  let f = @ui.Field::new()
  let t = field_look_case(kind, platform, scale, f)
  let out = [("unlit", field_look_drawn(t))]
  // (on its words' line, past its padding: 40 in, 17 down)
  let (x, y) = (40.0, 17.0)
  if platform == 0 {
    t.move_to(x, y)
    t.run_for(@ui.move_most_ms)
    out.push(("pointed", field_look_drawn(t)))
  }
  t.tap(x, y)
  t.run_for(@ui.move_most_ms)
  out.push(("written in", field_look_drawn(t)))
  t.type_text("字")
  t.run_for(@ui.move_most_ms)
  out.push(("typed", field_look_drawn(t)))
  out
}

///|
test "input_node and textarea_node draw across rest, hover, focus and typed states at scales 1 and 2" {
  for kind in [OneLine, SmallLine, ManyLines] {
    for platform in [0, 2] {
      for scale in [1.0, 2.0] {
        let made = field_look_states(kind, platform, scale)
        for s in made {
          assert_true(s.1.length() > 0, msg="\{Repr(kind)} platform \{platform} scale \{scale} \{s.0}")
        }
        assert_true(made[made.length() - 1].1 != made[0].1, msg="typed differs from unlit")
      }
    }
  }
}

///|
test "input_node, keyboard and mouse: hovering padding lights field and hovering text shows I-beam cursor" {
  let t = field_look_case(OneLine, 0, 1.0, @ui.Field::new())
  let unlit = field_look_drawn(t)
  t.move_to(4.0, 17.0)
  t.run_for(@ui.move_most_ms)
  assert_true(field_look_drawn(t) != unlit, msg="padding lit")
  t.move_to(40.0, 17.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.cursor(), @ui.Cursor::IBeam)
}

///|
test "input_node, keyboard and mouse: a layer over it, the pointer on the layer where the field is under it: not lit" {
  let over = @signals.signal(false)
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=400.0, h=300.0, platform=0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(b) {
      b.width(Is(Some(300.0))) |> ignore
      input_node(b, @ui.Field::new(), placeholder="名字") |> ignore
    })
    |> ignore
    root.show(fn() { over.get() }, fn(layer) {
      layer.over(Is(true)).width(Is(Some(400.0))).height(Is(Some(300.0))).presses(Is(true)).on_press(fn() {  }).ground(Is(0x00000001L)) |> ignore
    })
    |> ignore
  })
  t.run_for(@ui.move_most_ms)
  let (x, y) = (40.0, 17.0)
  let unlit = field_look_drawn(t)
  t.move_to(x, y)
  t.run_for(@ui.move_most_ms)
  let lit = field_look_drawn(t) != unlit
  over.set(true)
  t.run_for(@ui.move_most_ms)
  let covered = field_look_drawn(t)
  over.set(false)
  t.run_for(@ui.move_most_ms)
  let back = field_look_drawn(t)
  // (covered: its own instances as at rest, the layer's ground over them)
  let under = covered.filter(fn(i) { unlit.contains(i) }).length()
  assert_eq((lit, under == unlit.length(), back != unlit), (true, true, true))
}

///|
/// A solid line to type in (on a card's ground: input_node's `solid`) in a column 300 wide at the window's
/// top left, started as `platform`; its states as field_look_states says them.
fn field_solid_states(platform : Int) -> Array[(String, Array[String])] {
  let f = @ui.Field::new()
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=400.0, h=300.0, platform~)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(b) {
      b.width(Is(Some(300.0))) |> ignore
      input_node(b, f, placeholder="名字", solid=true) |> ignore
    })
    |> ignore
  })
  t.run_for(@ui.move_most_ms)
  let out = [("unlit", field_look_drawn(t))]
  let (x, y) = (40.0, 17.0)
  if platform == 0 {
    t.move_to(x, y)
    t.run_for(@ui.move_most_ms)
    out.push(("pointed", field_look_drawn(t)))
  }
  t.tap(x, y)
  t.run_for(@ui.move_most_ms)
  out.push(("written in", field_look_drawn(t)))
  t.type_text("字")
  t.run_for(@ui.move_most_ms)
  out.push(("typed", field_look_drawn(t)))
  out
}

///|
test "input_node solid draws distinct ground from plain input_node across desktop and touch" {
  for platform in [0, 2] {
    let made = field_solid_states(platform)
    let plain = field_look_states(OneLine, platform, 1.0)
    assert_true(plain[0].1 != made[0].1, msg="platform \{platform}: solid as the plain one at rest")
    assert_true(made[made.length() - 1].1 != made[0].1, msg="platform \{platform}: typed differs from unlit")
  }
}
