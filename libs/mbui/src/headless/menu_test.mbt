// The headless menu (@headless.menu, Menu::item, Menu::check_item, Menu::radio_item), under a look of the tests' own:
// read out a Menu of MenuItem, MenuItemCheckbox and MenuItemRadio items; ↓/↑ around the enabled items, Home and End,
// from nowhere ↓ the first and ↑ the last; pressed by the pointer, Enter or Activate, never while disabled; Escape and
// a submenu's arrow back telling on_close; items made by View::each. Each window is made by `window` (window_test.mbt),
// which holds that menu.mbt draws and lays out nothing.

///|
/// A row of the tests' look: 120 by 28, its ground the pressed one while the keys are on it.
fn menu_row(v : @view.View, s : @headless.MenuItem) -> Unit {
  v
  .width(Is(Some(120.0)))
  .height(Is(Some(28.0)))
  .ground(By(fn() { if s.focused() || s.hovered() { c_pressed } else { c_rest } }))
  |> ignore
}

///|
/// What the focus is on, by its name ("" none).
fn focus_name(t : @ui.Tester) -> String {
  t.focused().map(fn(s) { s.label }).unwrap_or("")
}

///|
test "a menu and its items: read out a Menu of an action, a check and a radio; ↓/↑ wrap and pass a disabled item by, Home and End go to the ends; Enter, a click and Activate do an item, a disabled one never" {
  let done : Array[String] = []
  let wrap_on = @signals.signal(false)
  let paste_off = @signals.signal(true)
  let sort = @signals.signal("名称")
  let closed = Ref(0)
  let menu_box : Ref[@headless.Menu?] = Ref(None)
  let t = window(fn(root) {
    @headless.menu(
      root,
      label=fn() { "编辑" },
      on_close=fn() { closed.val += 1 },
      fn(m, menu) {
        menu_box.val = Some(menu)
        menu.item(m, fn() { "复制" }, fn(_) { done.push("复制") }, menu_row) |> ignore
        menu.item(m, fn() { "粘贴" }, fn(_) { done.push("粘贴") }, menu_row, disabled=fn() { paste_off.get() })
        |> ignore
        menu.check_item(
          m,
          fn() { "自动换行" },
          fn() { wrap_on.get() },
          fn(_) {
            done.push("自动换行")
            wrap_on.set(!wrap_on.get())
          },
          menu_row,
        )
        |> ignore
        for name in ["名称", "日期"] {
          menu.radio_item(
            m,
            fn() { name },
            fn() { sort.get() == name },
            fn(_) {
              done.push(name)
              sort.set(name)
            },
            menu_row,
          )
          |> ignore
        }
      },
    )
    |> ignore
  })
  assert_true(t.query(Menu, label="编辑") is Some(_))
  assert_eq(
    (
      t.get(MenuItem, label="粘贴").disabled,
      t.get(MenuItemCheckbox, label="自动换行").check,
      t.get(MenuItemRadio, label="名称").check,
      t.get(MenuItemRadio, label="日期").check,
    ),
    (true, Some(@view.Check::Off), Some(@view.Check::On), Some(@view.Check::Off)),
  )
  // nothing has the focus: ↓ comes to the first item; ↓ passes "粘贴" (disabled) by; End, ↓ wraps, ↑ wraps back,
  // Home
  t.key(@ui.key_code_down)
  let first = focus_name(t)
  t.key(@ui.key_code_down)
  let past_off = focus_name(t)
  t.key(@ui.key_code_end)
  let at_end = focus_name(t)
  t.key(@ui.key_code_down)
  let wrapped = focus_name(t)
  t.key(@ui.key_code_up)
  let back = focus_name(t)
  t.key(@ui.key_code_home)
  let home = focus_name(t)
  assert_eq((first, past_off, at_end, wrapped, back, home), ("复制", "自动换行", "日期", "复制", "日期", "复制"))
  // Enter on "复制"; the focus shows, as it came by the keys
  t.enter()
  assert_eq((done.copy(), t.focused().map(fn(s) { s.focused }).unwrap_or(false)), (["复制"], true))
  // a click on "自动换行" turns it, read out On then; Activate on "日期" chooses it
  t.click(MenuItemCheckbox, label="自动换行")
  t.act(MenuItemRadio, Activate, label="日期")
  assert_eq(
    (t.get(MenuItemCheckbox, label="自动换行").check, t.get(MenuItemRadio, label="日期").check, sort.get()),
    (Some(@view.Check::On), Some(@view.Check::On), "日期"),
  )
  // a click and Activate on the disabled "粘贴" do nothing; enabled, ↓ from "复制" comes to it and Enter does it
  t.click(MenuItem, label="粘贴")
  let before = done.length()
  paste_off.set(false)
  t.frame()
  match menu_box.val {
    Some(m) => assert_true(m.focus_first())
    None => fail("no menu")
  }
  t.draw()
  t.key(@ui.key_code_down)
  let to_paste = focus_name(t)
  t.enter()
  assert_eq((before, to_paste, done.last(), closed.val), (3, "粘贴", Some("粘贴"), 0))
  // Escape with the focus in it tells on_close once
  t.key(@ui.key_escape)
  assert_eq(closed.val, 1)
}

///|
test "a submenu that does not wrap, its items made by each: ↓ stops at the last, ↑ at the first; ← (its close key) and Escape close it only while the focus is in it; Menu::focus_last" {
  let names = @signals.signal(["甲", "乙", "丙"])
  let closed : Array[String] = []
  let sub : Ref[@headless.Menu?] = Ref(None)
  let t = window(fn(root) {
    root.box(fn(before) {
      before
      .width(Is(Some(40.0)))
      .height(Is(Some(30.0)))
      .presses(Is(true))
      .focusable(Is(true))
      .says(Is(Some(@view.said(Button, label="外"))))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    @headless.menu(
      root,
      label=fn() { "更多" },
      wraps=false,
      close_key=@headless.AnchorSide::Right.back_key(),
      on_close=fn() { closed.push("closed") },
      fn(m, menu) {
        sub.val = Some(menu)
        m.each(fn() { names.get() }, fn(k) { k }, fn(slot, k) {
          let name = k.untracked()
          menu.item(slot, fn() { name }, fn(_) {  }, menu_row, in_node=true) |> ignore
          slot.width(Is(Some(120.0))).height(Is(Some(28.0))) |> ignore
        })
      },
    )
    |> ignore
  })
  let m = sub.val.unwrap()
  assert_true(m.focus_last())
  t.draw()
  let last = focus_name(t)
  t.key(@ui.key_code_down)
  let stays = focus_name(t)
  t.key(@ui.key_code_home)
  t.key(@ui.key_code_up)
  let top = focus_name(t)
  assert_eq((last, stays, top), ("丙", "丙", "甲"))
  // an item that goes is passed by: "乙" gone, ↓ from "甲" comes to "丙"
  names.set(["甲", "丙"])
  t.frame()
  t.key(@ui.key_code_down)
  let after_gone = focus_name(t)
  // ← (the close key) closes it from inside
  t.key(@ui.key_code_left)
  let by_arrow = closed.length()
  // with the focus outside it ("外"), neither ← nor Escape nor ↓ is its
  t.act(Button, Focus, label="外")
  t.key(@ui.key_code_left)
  t.key(@ui.key_escape)
  t.key(@ui.key_code_down)
  assert_eq((after_gone, by_arrow, closed.length(), focus_name(t)), ("丙", 1, 1, "外"))
}

///|
test "a menu item in a row a structure made (in_node) is that row: read out a MenuItem with no node more" {
  let t = window(fn(root) {
    @headless.menu(root, fn(m, menu) {
      m.each(fn() { ["一"] }, fn(k) { k }, fn(slot, k) {
        let name = k.untracked()
        menu.item(slot, fn() { name }, fn(_) {  }, menu_row, in_node=true) |> ignore
      })
    })
    |> ignore
  })
  let item = t.get(MenuItem, label="一")
  assert_eq((t.all(Menu).length(), item.rect.2, item.rect.3), (1, 120.0, 28.0))
}

///|
test "a menu that takes the focus and roves: given the focus it holds it, no item lit, ↓ the first; Tab stops on the last item that had the focus, else the first enabled;" {
  let off = @signals.signal(false)
  let box : Ref[@headless.Menu?] = Ref(None)
  let node : Ref[@view.View?] = Ref(None)
  let t = window(fn(root) {
    root.box(fn(before) {
      before
      .width(Is(Some(40.0)))
      .height(Is(Some(30.0)))
      .presses(Is(true))
      .focusable(Is(true))
      .says(Is(Some(@view.said(Button, label="前"))))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    @headless.menu(root, label=fn() { "菜单" }, takes_focus=true, roving=true, fn(m, menu) {
      box.val = Some(menu)
      node.val = Some(m)
      for name in ["甲", "乙", "丙"] {
        menu.item(m, fn() { name }, fn(_) {  }, menu_row, disabled=fn() { name == "丙" && off.get() }) |> ignore
      }
    })
    |> ignore
  })
  // given the focus as a pointer opened it: the menu's own, nothing lit; ↓ the first
  assert_true(node.val.unwrap().ask_focus(visible=false))
  t.draw()
  let own = (focus_name(t), t.focused().map(fn(s) { s.role }))
  t.key(@ui.key_code_down)
  let first = focus_name(t)
  t.key(@ui.key_code_down)
  t.key(@ui.key_code_down)
  // Tab away and back: the menu itself, then its one item stop, the last with the focus ("丙")
  t.act(Button, Focus, label="前")
  t.tab()
  let menu_stop = focus_name(t)
  t.tab()
  let item_stop = focus_name(t)
  // "丙" disabled: the stop the first enabled, "甲"
  off.set(true)
  t.frame()
  t.act(Button, Focus, label="前")
  t.tab()
  t.tab()
  let fallen_back = focus_name(t)
  assert_eq((own, first, menu_stop, item_stop, fallen_back), (("菜单", Some(@view.Role::Menu)), "甲", "菜单", "丙", "甲"))
}
