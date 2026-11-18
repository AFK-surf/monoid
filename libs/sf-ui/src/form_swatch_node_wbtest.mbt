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
test "the avatars: each pressed by its name picks it, the one picked read out selected" {
  let picked = @signals.signal("")
  let got = Ref("")
  let tips = TipLayer::new(fn() { None })
  let tt = u5_case(fn(root) {
    avatar_tiles_node(root, fn() { app_makers }, fn() { picked.get() }, fn() { 560.0 }, fn(a) {
      got.val = a.id
      picked.set(a.id)
    }, tips)
    |> ignore
  })
  let first = app_makers[0]
  let label = if first.label.has_prefix("android-") { t(first.label) } else { first.label }
  tt.click(Button, label~)
  tt.run_for(@ui.move_most_ms)
  assert_eq(got.val, first.id)
  assert_eq(picked.get(), first.id)
  assert_eq(tt.fixed_outgrown(), [])
}

///|
test "a colour's swatch beside its field, and the icon's well pressed for a picture" {
  let hex = @ui.Field::new(text="#3B82F6")
  let pressed = Ref(0)
  let t = u5_case(fn(root) {
    root.box(fn(r) {
      r.row(Is(true)).gap(Is(16.0)) |> ignore
      icon_well_node(r, fn() { "上传图标" }, fn() { pressed.val += 1 }, fn() { 0x3B82F6FFL }, fn() { 0xFFFFFFFFL }, fn() { "" }, fn() {
        "上传"
      }, app_icon_px)
      |> ignore
      swatch_field_node(r, hex, fn() { hex_color(hex.text()).unwrap_or(0L) }, "颜色") |> ignore
    })
    |> ignore
  })
  assert_true(t.rect_of("上传") is Some(_))
  t.click(Button, label="上传图标")
  t.draw()
  assert_eq(pressed.val, 1)
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
