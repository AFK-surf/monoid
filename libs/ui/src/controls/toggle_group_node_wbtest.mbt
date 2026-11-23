// The library's toggle group (toggle_group_node.mbt): a group read out by its name, each button pressed while on; at
// most one on (Single) or each its own (Multiple); one stop of Tab's, the arrow keys, Home and End moving along it and
// turning nothing, Space or Enter turning the one the keyboard is on; a disabled button passed by and never turned;
// its track and buttons concentric in both shapes and sizes, an icon alone square, nothing the audit finds.

///|
/// What a toggle group case keeps: its window, what was told.
struct Tog2 {
  t : @ui.Tester
  told : Array[(String, Bool)]
}

///|
/// A toggle group 视图 of 列表, 分栏 and 树 (树 disabled), 列表 on, each its icon beside its words (or alone, `icon_only`);
/// `kind`, `size` and `shape` as given, in a window `w` wide.
fn tog2(
  kind? : @headless.ToggleGroupKind = Single,
  size? : ToggleGroupSize = Regular,
  shape? : ToggleGroupShape = Rounded,
  icon_only? : Bool = false,
  w? : Double = 600.0,
) -> Tog2 {
  let on : @signals.Signal[Array[String]] = @signals.signal(["列表"])
  let told : Array[(String, Bool)] = []
  let single = kind is Single
  let t = w2_case(w~, fn(root) {
    root.box(fn(row) {
      row.row(Is(true)) |> ignore
      toggle_group_node(
        row,
        fn() { "视图" },
        [
          toggle_item("列表", fn() { "列表" }, icon="list", icon_only~),
          toggle_item("分栏", fn() { "分栏" }, icon="view-columns", icon_only~),
          toggle_item("树", fn() { "树" }, icon="view-tree", icon_only~, disabled=fn() { true }),
        ],
        fn(k) { on.get().contains(k) },
        fn(k, to) {
          told.push((k, to))
          let now = on.get().filter(fn(x) { x != k })
          on.set(if !to { now } else if single { [k] } else { now + [k] })
        },
        kind~,
        size~,
        shape~,
      )
      |> ignore
    })
    |> ignore
  })
  { t, told }
}

///|
/// The buttons read out pressed.
fn tog2_on(t : @ui.Tester) -> Array[String] {
  t.all(Button).filter(fn(s) { s.pressed == Some(true) }).map(fn(s) { s.label })
}

///|
test "toggle group, at most one on: read out a group of buttons, the one on pressed; a press on another turns it on and the one before off; a press on the one on turns it off; nothing the audit finds" {
  let k = tog2()
  assert_eq(k.t.all(Group, label="视图").length(), 1)
  assert_eq(tog2_on(k.t), ["列表"])
  assert_eq(k.t.audit(), [])
  k.t.click(Button, label="分栏")
  k.t.run_for(@ui.move_most_ms)
  assert_eq(tog2_on(k.t), ["分栏"])
  k.t.click(Button, label="分栏")
  k.t.run_for(@ui.move_most_ms)
  assert_eq(tog2_on(k.t), [])
  assert_eq(k.told, [("分栏", true), ("分栏", false)])
}

///|
test "toggle group, each its own: a press on another turns it on beside the one on" {
  let k = tog2(kind=Multiple)
  k.t.click(Button, label="分栏")
  k.t.run_for(@ui.move_most_ms)
  assert_eq(tog2_on(k.t), ["列表", "分栏"])
}

///|
test "toggle group keys: Tab stops once, on the one on; → ← Home End move along it past the disabled one, turning nothing; Space and Enter turn the one the keyboard is on; Tab leaves it (round to 别处)" {
  let k = tog2(kind=Multiple)
  let at = fn() { k.t.focused().map(fn(s) { s.label }).unwrap_or("none") }
  k.t.act(Button, Focus, label="别处")
  k.t.tab()
  let first = at()
  k.t.key(@ui.key_code_right)
  let right = at()
  k.t.key(@ui.key_code_right)
  let round = at()
  k.t.key(@ui.key_code_end)
  let end = at()
  k.t.key(@ui.key_code_home)
  let home = at()
  assert_eq([first, right, round, end, home], ["列表", "分栏", "列表", "分栏", "列表"])
  assert_eq(k.told, [])
  k.t.key(@ui.key_space)
  k.t.key(@ui.key_code_right)
  k.t.enter()
  k.t.run_for(@ui.move_most_ms)
  assert_eq(tog2_on(k.t), ["分栏"])
  k.t.tab()
  assert_eq(at(), "别处")
}

///|
test "toggle group, a disabled button: read out disabled, a press on it turns nothing" {
  let k = tog2()
  assert_true(k.t.get(Button, label="树").disabled)
  k.t.click(Button, label="树")
  k.t.run_for(@ui.move_most_ms)
  assert_eq(k.told, [])
}

///|
test "toggle group, both shapes and sizes, words and icons alone, in a phone's width and a wide one: its buttons as high as the size says, an icon alone square, concentric with the track; nothing the audit finds" {
  for shape in [Rounded, Pill] {
    for size in [Compact, Regular] {
      for icon_only in [false, true] {
        for w in [390.0, 1280.0] {
          let k = tog2(shape~, size~, icon_only~, w~)
          let b = k.t.get(Button, label="列表").rect
          let h = if size is Compact { toggle_group_compact_h } else { toggle_group_h }
          let what = "\{if shape is Pill { "pill" } else { "rounded" }} \{h} \{icon_only} \{w}"
          assert_eq(b.3, h, msg=what)
          if icon_only {
            assert_eq(b.2, h, msg=what)
          }
          assert_eq(k.t.audit(), [], msg=what)
        }
      }
    }
  }
}

///|
test "toggle_group_node: 1.0x keeps exact height, Regular keeps 28pt at 1.3x, 2.0x scales with zero fixed_outgrown or squeeze_faults" {
  for shape in [Rounded, Pill] {
    for size in [Compact, Regular] {
      let base_h = if size is Compact { toggle_group_compact_h } else { toggle_group_h }
      let k = tog2(shape~, size~)
      assert_eq(k.t.get(Button, label="列表").rect.3, base_h, msg="1.0x \{Repr(shape)} \{Repr(size)}")
      assert_eq(k.t.fixed_outgrown(), [], msg="1.0x fixed_outgrown \{Repr(shape)} \{Repr(size)}")
      assert_eq(k.t.squeeze_faults(), [], msg="1.0x squeeze_faults \{Repr(shape)} \{Repr(size)}")
      k.t.set_font_scale(1.3)
      k.t.draw()
      if size is Regular {
        assert_eq(k.t.get(Button, label="列表").rect.3, base_h, msg="1.3x Regular keeps 28pt \{Repr(shape)}")
      }
      assert_eq(k.t.fixed_outgrown(), [], msg="1.3x fixed_outgrown \{Repr(shape)} \{Repr(size)}")
      assert_eq(k.t.squeeze_faults(), [], msg="1.3x squeeze_faults \{Repr(shape)} \{Repr(size)}")
      k.t.set_font_scale(2.0)
      k.t.draw()
      let h2 = k.t.get(Button, label="列表").rect.3
      assert_true(h2 > base_h, msg="2.0x height grew \{Repr(shape)} \{Repr(size)}: \{h2}")
      assert_eq(k.t.fixed_outgrown(), [], msg="2.0x fixed_outgrown \{Repr(shape)} \{Repr(size)}")
      assert_eq(k.t.squeeze_faults(), [], msg="2.0x squeeze_faults \{Repr(shape)} \{Repr(size)}")
    }
  }
}
