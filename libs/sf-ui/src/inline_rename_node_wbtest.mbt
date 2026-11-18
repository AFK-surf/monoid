// The library's name changed in its place (inline_rename_node), as a desktop's file manager has it: the focus in it as
// it comes, what of the name is picked then as asked; Enter keeps a name changed (trimmed), lets be one empty or as it
// was; Escape lets it be; a press outside keeps it as Enter does; it ends once.

///|
/// A node "别处" taking presses and the focus at the window's top, then, opened after the window was first drawn (as a
/// menu's 重命名 opens it), in a box 300 wide a name changed in place editing `f` (its name as it was `was`), what it
/// kept or let be told in `ends`.
fn rename_case(f : @ui.Field, was : String, ends : Array[String], picks? : RenamePick = NameAsGiven) -> @ui.Tester {
  f.set(was)
  let opened = @signals.signal(false)
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=400.0, h=400.0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(e) {
      e
      .width(Is(Some(50.0)))
      .height(Is(Some(50.0)))
      .presses(Is(true))
      .focusable(Is(true))
      .says(Is(Some(@view.said(Button, label="别处"))))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    root.show(fn() { opened.get() }, fn(s) {
      s.box(fn(b) {
        b.width(Is(Some(300.0))) |> ignore
        inline_rename_node(b, f, was, "重命名", fn(w) { ends.push("keep:" + w) }, fn() { ends.push("cancel") }, picks~)
        |> ignore
      })
      |> ignore
    })
  })
  t.draw()
  opened.set(true)
  t.draw()
  t
}

///|
test "inline_rename_node: the focus in it as it comes; Enter keeps a changed name, trimmed, once" {
  let f = @ui.Field::new()
  let ends = []
  let t = rename_case(f, "旧名", ends)
  let focused = t.focused().map(fn(s) { s.label })
  f.set("  新名 ")
  t.draw()
  t.key_named("enter") |> ignore
  t.key_named("enter") |> ignore
  assert_eq((focused, ends), (Some("重命名"), ["keep:新名"]))
}

///|
test "inline_rename_node: Enter on a name as it was, or empty, lets it be" {
  for typed in ["旧名", "   "] {
    let f = @ui.Field::new()
    let ends = []
    let t = rename_case(f, "旧名", ends)
    f.set(typed)
    t.draw()
    t.key_named("enter") |> ignore
    assert_eq(ends, ["cancel"], msg=typed)
  }
}

///|
test "inline_rename_node: Escape lets a changed name be" {
  let f = @ui.Field::new()
  let ends = []
  let t = rename_case(f, "旧名", ends)
  f.set("新名")
  t.draw()
  t.key_named("escape") |> ignore
  assert_eq(ends, ["cancel"])
}

///|
test "inline_rename_node: a press outside keeps a changed name, as a file manager does; outside on one unchanged lets it be" {
  for typed in ["新名", "旧名"] {
    let f = @ui.Field::new()
    let ends = []
    let t = rename_case(f, "旧名", ends)
    f.set(typed)
    t.draw()
    let (x, y, w, h) = t.get(Button, label="别处").rect
    t.tap(x + w / 2.0, y + h / 2.0)
    t.draw()
    let want = if typed == "新名" { ["keep:新名"] } else { ["cancel"] }
    assert_eq(ends, want, msg=typed)
  }
}

///|
test "inline_rename_node: what is picked as it comes, all of a name or a file's name but its extension" {
  let whole = @ui.Field::new()
  rename_case(whole, "周报.final.md", [], picks=NameWhole) |> ignore
  let stem = @ui.Field::new()
  rename_case(stem, "周报.final.md", [], picks=NameStem) |> ignore
  let dot = @ui.Field::new()
  rename_case(dot, ".gitignore", [], picks=NameStem) |> ignore
  assert_eq((whole.selection(), stem.selection(), dot.selection()), ((0, 11), (0, 8), (0, 10)))
}
