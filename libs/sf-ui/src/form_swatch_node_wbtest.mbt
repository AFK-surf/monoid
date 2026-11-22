// The library's form parts (form_swatch_node.mbt): permissions folded and ticked, the avatars picked by their names,
// the colour's swatch and field, a place picked, words pressed quietly, each with no words over words and nothing
// outgrowing what holds it.

///|
fn u18_sections() -> Array[CheckSection] {
  [
    {
      title: "消息",
      groups: [
        { id: "read", label: "读消息", tip: "读频道里的消息", fixed: true, admin: false },
        { id: "write", label: "发消息", tip: "在频道里回复", fixed: false, admin: false },
        { id: "files", label: "文件", tip: "读和传文件", fixed: false, admin: false },
        { id: "users", label: "成员", tip: "读成员资料", fixed: false, admin: true },
      ],
    },
  ]
}

///|
fn u18_said() -> CheckGroupsSaid {
  {
    summary: fn(on, all) { "权限 \{on}/\{all}" },
    all_on: fn() { "全部开启" },
    select_all: fn() { "全选" },
    select_none: fn() { "全不选" },
    admin: fn() { "需管理员" },
  }
}

///|
test "permissions folded: counted on their line, opened by it, ticked, all turned on from it" {
  let on : LiveMap[String, Bool] = LiveMap::new()
  on["read"] = true
  on["write"] = true
  let open = @signals.signal(false)
  let tips = TipLayer::new(fn() { None })
  let t = u5_case(fn(root) {
    check_groups_node(
      root,
      u18_sections,
      fn(id) { on.get(id).unwrap_or(false) },
      fn(id, now) { on[id] = now },
      fn() { open.get() },
      fn() { open.set(!open.untracked()) },
      u18_said(),
      tips,
    )
  })
  assert_true(t.rect_of("权限 2/4") is Some(_))
  assert_true(t.rect_of("文件") is None)
  t.click(Button, label="权限 2/4")
  t.run_for(@ui.move_most_ms)
  assert_true(t.rect_of("文件") is Some(_))
  assert_true(t.rect_of("需管理员") is Some(_))
  t.click(Checkbox, label="文件")
  t.run_for(@ui.move_most_ms)
  assert_true(t.rect_of("权限 3/4") is Some(_))
  t.click(Button, label="全部开启")
  t.run_for(@ui.move_most_ms)
  assert_true(t.rect_of("权限 4/4") is Some(_))
  // (all on: its line's way to turn all on gone, the section's toggle turns them off but the fixed one)
  assert_true(t.rect_of("全部开启") is None)
  t.click(Button, label="全不选")
  t.run_for(@ui.move_most_ms)
  assert_true(t.rect_of("权限 1/4") is Some(_))
  assert_eq(on.get("read"), Some(true))
  assert_eq(t.fixed_outgrown(), [])
}

///|
/// Permissions open in a box `w` wide (words at `scale`): five groups, each a box to tick (so their names start alike in
/// a column), `admin` said of the fourth.
fn u18_open_at(w : Double, admin : Bool, scale? : Double = 1.0) -> @ui.Tester {
  let tips = TipLayer::new(fn() { None })
  let sections = fn() -> Array[CheckSection] {
    [
      {
        title: "消息",
        groups: [
          { id: "read", label: "读消息", tip: "读频道里的消息", fixed: false, admin: false },
          { id: "write", label: "发消息", tip: "在频道里回复", fixed: false, admin: false },
          { id: "files", label: "文件", tip: "读和传文件", fixed: false, admin: false },
          { id: "users", label: "成员", tip: "读成员资料", fixed: false, admin: admin },
          { id: "channels", label: "频道", tip: "列出频道", fixed: false, admin: false },
        ],
      },
    ]
  }
  u5_case(scale~, fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(w))) |> ignore
      check_groups_node(b, sections, fn(id) { id == "read" }, fn(_, _) {  }, fn() { true }, fn() {  }, u18_said(), tips)
    })
    |> ignore
  })
}

///|
fn u18_at(t : @ui.Tester, words : String) -> (Double, Double, Double, Double) {
  t.rect_of(words).unwrap()
}

///|
test "permissions three to a line where the room has it, a short line's last ones in the columns over them" {
  let t = u18_open_at(600.0, false)
  let (x0, y0, _, _) = u18_at(t, "读消息")
  let (x1, y1, _, _) = u18_at(t, "发消息")
  let (x2, y2, _, _) = u18_at(t, "文件")
  let (x3, y3, _, _) = u18_at(t, "成员")
  let (x4, y4, _, _) = u18_at(t, "频道")
  assert_eq((y1, y2), (y0, y0))
  assert_true(x0 < x1 && x1 < x2)
  // (the second line's two where the first two are, each a third of the line, not its half)
  assert_true(y3 > y0)
  assert_eq(y4, y3)
  assert_eq((x3, x4), (x0, x1))
  assert_eq(t.audit(), [])
}

///|
test "permissions two to a line where the room has not three, 需管理员 beside its name over nothing" {
  let t = u18_open_at(400.0, true)
  let (x0, y0, _, _) = u18_at(t, "读消息")
  let (x1, y1, _, _) = u18_at(t, "发消息")
  let (x2, y2, _, _) = u18_at(t, "文件")
  let (x3, y3, w3, _) = u18_at(t, "成员")
  let (xa, ya, wa, _) = u18_at(t, "需管理员")
  assert_eq(y1, y0)
  assert_true(x1 > x0)
  assert_true(y2 > y0)
  assert_eq((x2, y3, x3), (x0, y2, x1))
  // (its name whole, then 需管理员, within the box)
  assert_eq(ya > y3 - 8.0 && ya < y3 + 8.0, true)
  assert_true(xa >= x3 + w3)
  assert_true(xa + wa <= 400.0)
  assert_eq(t.audit(), [])
  // (words at 1.3: three no longer have the room at 600)
  let big = u18_open_at(600.0, true, scale=1.3)
  let (bx0, by0, _, _) = u18_at(big, "读消息")
  let (bx2, by2, _, _) = u18_at(big, "文件")
  assert_eq(bx2, bx0)
  assert_true(by2 > by0)
  assert_eq(big.audit(), [])
}

///|
test "permissions one to a line in a narrow box" {
  let t = u18_open_at(300.0, true)
  let rows = ["读消息", "发消息", "文件", "成员", "频道"].map(fn(w) { u18_at(t, w) })
  for i in 1..<rows.length() {
    assert_eq(rows[i].0, rows[0].0)
    assert_true(rows[i].1 > rows[i - 1].1)
  }
  assert_eq(t.audit(), [])
}

///|
test "a colour's swatch beside its field, and the icon's well pressed for a picture" {
  let hex = @ui.Field::new(text="#3B82F6")
  let shown = @signals.signal("")
  let pressed = Ref(0)
  let t = u5_case(fn(root) {
    root.box(fn(r) {
      r.row(Is(true)).gap(Is(16.0)) |> ignore
      icon_well_node(r, fn() { "上传图标" }, fn() { pressed.val += 1 }, fn() { 0x3B82F6FFL }, fn() { 0xFFFFFFFFL }, fn() { shown.get() }, fn() {
        "上传"
      }, 1024)
      |> ignore
      swatch_field_node(r, hex, fn() { 0x3B82F6FFL }, "颜色") |> ignore
    })
    |> ignore
  })
  assert_true(t.rect_of("上传") is Some(_))
  t.click(Button, label="上传图标")
  t.draw()
  assert_eq(pressed.val, 1)
  @ui.add_image("mem:well-icon/1", b"\xFF\xD8\xFF\xD9")
  t.add_image("mem:well-icon/1", 1024, 1024)
  shown.set("mem:well-icon/1")
  t.draw()
  t.draw()
  assert_true(t.drawlist_images().iter().any(fn(i) { i.1 == "mem:well-icon/1" }), msg="well icon missing from drawlist")
  let drawn = t.drawn_images()
  assert_eq(drawn.length(), 1)
  assert_true(drawn[0][2] >= 120.0 && drawn[0][3] >= 120.0, msg="icon image must fill well, got \{drawn[0][2]}×\{drawn[0][3]}")
  assert_eq(t.fixed_outgrown(), [])
}

///|
test "a place picked by a press, one that cannot be taking none; words pressed quietly" {
  let chosen = @signals.signal("")
  let quiet = Ref(0)
  let t = u5_case(fn(root) {
    for name in ["#dev", "#ops"] {
      place_row_node(
        root,
        fn() { name },
        fn(_) {  },
        fn() { chosen.get() == name },
        selected=fn() { chosen.get() == name },
        can=fn() { name != "#ops" },
        press=fn() { if name != "#ops" { chosen.set(name) } },
        end=fn(e) { place_note_node(e, fn() { "在频道里" }, fn() { chosen.get() == name }) |> ignore },
      )
    }
    quiet_action_node(root, fn() { "手动创建" }, fn() { quiet.val += 1 }) |> ignore
  })
  t.click(Button, label="#dev")
  t.run_for(@ui.move_most_ms)
  assert_eq(chosen.get(), "#dev")
  t.click(Button, label="#ops")
  t.run_for(@ui.move_most_ms)
  assert_eq(chosen.get(), "#dev")
  t.click(Button, label="手动创建")
  t.draw()
  assert_eq(quiet.val, 1)
  assert_eq(t.fixed_outgrown(), [])
}
