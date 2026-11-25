// The presenters (presenters.mbt), each at the Small tier with a finger (a sheet) and at the Large tier with a mouse
// (the web's: beside what opened it, or in the middle of the window).

///|
/// A phone's window (Small, a finger) and a desktop's (Large, a mouse).
let phone : (Int, Double, Double) = (2, 390.0, 844.0)

///|
let desk : (Int, Double, Double) = (0, 1280.0, 800.0)

///|
test "an anchored panel animates both entering and leaving before its presenter is removed" {
  let t = presenting_tester(desk, fn(from) {
    panel_nodes("动画面板", from~, fn(v, _) { words_node(v, fn() { "面板内容" }, fn() { paragraph }) |> ignore })
  })
  // (how far its words are seen, as drawn: None where they are not)
  let seen = fn() { t.words().iter().find_first(fn(w) { w.0 == "面板内容" }).map(fn(w) { w.5 }) }
  t.tap_text("打开")
  t.run_for(@motion.pop_ms / 2.0)
  let entering = seen().unwrap()
  assert_true(entering > 0.0 && entering < 1.0, msg="entering \{entering}")
  t.run_for(@motion.pop_ms)
  close_presented()
  t.frame()
  t.run_for(@motion.pop_out_ms / 2.0)
  let leaving = seen().unwrap()
  assert_true(leaving > 0.0 && leaving < 1.0, msg="leaving \{leaving}")
  t.run_for(@motion.pop_out_ms)
  assert_true(seen() is None)
}

///|
/// A test host that wraps an old-view page under `presented_nodes` in the window's tree.
fn presented_tree(view : (@ui.Ctx) -> Unit) -> (@view.View) -> Unit {
  fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    @ui.old(root, view).grow(Is(1.0)) |> ignore
    presented_nodes(root)
  }
}

///|
/// A page with one trigger, 打开 (`at` its top, its middle, or its foot as a composer's choices are), that opens what
/// `open` presents (given what opened it), and the host over it.
fn presenting_view(open : (Anchor) -> Unit, at? : @ui.Justify = JStart) -> (@ui.Ctx) -> Unit {
  fn(c) {
    begin(c) |> ignore
    c.with_theme(ui_theme(), fn() {
      let t = theme()
      let h = button_height()
      c.box(w=Fill(1.0), h=Fill(1.0), pad=40.0, justify=at, fn() {
        let from = c.id("open")
        c.on_press(from, fn() { open(At(40.0, 40.0, 60.0, h)) })
        c.box(id=from, h=Px(h), padx=button_padx, bg=t.p.chip, radius=h / 2.0, align=ACenter, justify=JCenter, fn() {
          c.text(
            "打开",
            size=t.t.ui,
            weight=if t.touch { 600 } else { 500 },
            color=t.p.text,
            wrap=false,
            line=t.t.ui_line,
          )
          |> ignore
        })
        |> ignore
      })
      |> ignore
      presented(c)
    })
  }
}

///|
/// A test host with one button, 打开 (`at` its top, its middle, or its foot as a composer's choices are), that opens
/// what `open` presents (given what opened it), and `presented_nodes` over it.
fn presenting_tester(at : (Int, Double, Double), open : (Anchor) -> Unit, button_at? : @ui.Justify = JStart) -> @ui.Tester {
  presenters_reset()
  // (the words their keys, as these tests press them (`common.cancel`): a file run before this one in the same
  // program may have given the library its own, player_wbtest's table says 取消 for it, and they stay as given)
  set_words(fn(key, _) { key })
  let (platform, w, h) = at
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w~, h~, platform~)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(box) {
      box.grow(Is(1.0)).padding(Is((40.0, 40.0, 40.0, 40.0))).lines_up(Is(Some(Start))) |> ignore
      let align : @view.Lies = match button_at {
        JEnd => End
        JCenter => Middle
        _ => Start
      }
      box.lies_along(Is(align)) |> ignore
      button_opens_node(box, fn() { "打开" }, fn(b) { open(Node(b)) }) |> ignore
    })
    |> ignore
    @ui.old(root, fn(c) {
      begin(c) |> ignore
      c.with_theme(ui_theme(), fn() { presented(c) })
    }).over(Is(true)) |> @ui.old_takes_own |> ignore
    presented_nodes(root)
  })
  t.draw()
  t
}

///|
/// What opened it as a menu's or a pick's (what presenting_tester opened it by: its 打开).
fn beside_of(from : Anchor) -> Beside {
  match from {
    Anchor::Node(v) => Node(v)
    Anchor::At(x, y, w, h) => At(x, y, w, h)
    Unanchored => @halt.saying("a menu or a pick is opened beside what opened it")
  }
}

///|
/// 打开 pressed, and what it opened come in: a sheet risen, else the web's in.
fn open_it(t : @ui.Tester) -> Unit {
  t.tap_text("打开")
  if presented_how == [AsSheet] {
    t.run_for(presented_rest() - t.time())
  } else {
    t.run_for(@motion.presence_in_ms)
  }
}

///|
test "a panel's long list draws its rows in the panel's arrangement" {
  for at in [phone, desk] {
    let seen : Array[Look] = []
    let t = presenting_tester(at, fn(from) {
      panel_nodes("账号", from~, tall=0.8, grows=true, fn(v, _) {
        panel_list_node(v, fn() { Array::makei(12, fn(i) { i }) }, fn(b, i) {
          seen.push(look_node(b))
          words_node(b, fn() { "账号 " + i.to_string() }, fn() { paragraph }) |> ignore
        }, est=48.0)
        |> ignore
      })
    })
    open_it(t)
    t.draw()
    assert_true(!seen.is_empty(), msg="the list draws rows")
    let expected = if at == phone { Narrow } else { Wide }
    for arrangement in seen {
      assert_true(arrangement == expected, msg="each row takes the panel's arrangement")
    }
  }
}

///|
test "a capped sheet lays out lists that arrive after it opens" {
  let shown = @signals.signal(false)
  let t = presenting_tester(phone, fn(from) {
    panel_nodes("内容", from~, tall=0.8, fn(v, _) {
      button_node(v, fn() { "显示列表" }, fn() { shown.set(true) }) |> ignore
      v.show(fn() { shown.get() }, fn(l) {
        panel_list_node(l, fn() { [0] }, fn(b, _) {
          b.height(Is(Some(96.0))) |> ignore
          words_node(b, fn() { "第一组" }, fn() { paragraph }) |> ignore
        }, est=20.0)
        |> ignore
        panel_list_node(l, fn() { [0] }, fn(b, _) {
          b.height(Is(Some(80.0))) |> ignore
          words_node(b, fn() { "第二组" }, fn() { paragraph }) |> ignore
        }, est=20.0)
        |> ignore
      })
    })
  }, button_at=JEnd)
  open_it(t)
  t.tap_text("显示列表")
  t.draw()
  assert_true(t.find("第一组") is Some(_))
  assert_true(t.find("第二组") is Some(_))
}

///|
/// Where `words` are drawn, or a failure.
fn where_is(t : @ui.Tester, words : String) -> (Double, Double) raise {
  match t.find(words) {
    Some(at) => at
    None => fail("no \{words}")
  }
}

///|
fn menu_items_of(said : Array[String]) -> Array[MenuItem?] {
  [
    Some(menu_item_of("重命名", fn() { said.push("rename") }, icon="edit")),
    None,
    Some(menu_item_of("删掉", fn() { said.push("delete") }, danger=true)),
  ]
}

///|
test "a menu with a finger at Small: a sheet from the foot; an item tapped closes it and does what it says" {
  let said : Array[String] = []
  let t = presenting_tester(phone, fn(from) { menu(menu_items_of(said), from=beside_of(from)) }, button_at=JEnd)
  open_it(t)
  assert_eq(presented_how, [AsSheet])
  // in the sheet's rows, low in the window
  assert_true(where_is(t, "重命名").1 > phone.2 / 2.0)
  t.tap_text("删掉")
  assert_eq(said, ["delete"])
  assert_true(!presenting())
}

///|
test "a menu with a mouse at Large: beside what opened it; Escape closes it, an item chosen does what it says" {
  let said : Array[String] = []
  let t = presenting_tester(desk, fn(from) { menu(menu_items_of(said), from=beside_of(from)) })
  let (_, by) = where_is(t, "打开")
  open_it(t)
  assert_eq(presented_how, [AsPopover])
  // under the button, not far
  let (_, y) = where_is(t, "重命名")
  assert_true(y > by && y < by + 80.0)
  assert_true(t.key_named("esc"))
  assert_true(!presenting())
  assert_eq(said, [])
  open_it(t)
  t.tap_text("重命名")
  assert_eq(said, ["rename"])
  assert_true(!presenting())
}

///|
/// The colours the glyphs of the first words containing `words` are drawn in (those whose quads start in the words'
/// upper half).
fn inks_of(t : @ui.Tester, words : String) -> Array[Int64] raise {
  let (x, y, w, h) = match t.rect_of(words) {
    Some(r) => r
    None => fail("no \{words}")
  }
  let out = []
  for g in t.drawn_glyphs() {
    if g.0 >= x - 1.0 && g.0 <= x + w + 1.0 && g.1 >= y - 1.0 && g.1 < y + h / 2.0 && !out.contains(g.2) {
      out.push(g.2)
    }
  }
  out
}

///|
test "a confirmation warning is red in both a sheet and a dialog" {
  for at in [phone, desk] {
    let t = presenting_tester(at, fn(from) {
      confirm("分享账号？", "其他 station 会发送请求", "分享账号", fn() {  }, warning="请确认安全访问", from~)
    })
    open_it(t)
    t.run_for(@ui.move_most_ms)
    t.draw()
    let warning_ink = inks_of(t, "请确认安全访问")
    let words_ink = inks_of(t, "其他 station 会发送请求")
    let desc_ok = if at == phone {
      words_ink == [light_palette.muted] || words_ink == [web_light.muted]
    } else {
      let desc_light = @ui.over(light_palette.muted, alpha(light_palette.text, 0.25))
      let desc_web = @ui.over(web_light.muted, alpha(web_light.text, 0.25))
      words_ink == [desc_light] || words_ink == [desc_web]
    }
    assert_true(warning_ink == [light_palette.red] || warning_ink == [web_light.red], msg="warning at \{Repr(at)}")
    assert_true(desc_ok, msg="description at \{Repr(at)}")
    assert_true(words_ink != warning_ink, msg="description differs from warning at \{Repr(at)}")
  }
}

///|
test "a confirmation drawn in the window's tree shows its warning in red" {
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=1280.0, h=800.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    @ui.old(root, fn(c) {
      begin(c) |> ignore
      c.with_theme(ui_theme(), fn() { presented(c) })
    }).over(Is(true)) |> @ui.old_takes_own |> ignore
    presented_nodes(root)
  })
  t.draw()
  confirm("分享账号？", "其他 station 会发送请求", "分享账号", fn() {  }, warning="请确认安全访问")
  t.run_for(@ui.move_most_ms)
  t.draw()
  assert_eq(inks_of(t, "请确认安全访问"), [@ui.tree_theme().color(Danger)])
  assert_eq(inks_of(t, "其他 station 会发送请求"), [overlay_muted_ink()])
}

///|
test "a menu with a mouse at Large: an item not to be chosen now in the subtle ink (it is never lit), clicked does nothing" {
  let said : Array[String] = []
  let items = [
    Some(menu_item_of("重命名", fn() { said.push("rename") }, icon="edit")),
    Some(menu_item_of("启动", fn() { said.push("start") }, icon="play", disabled=true)),
  ]
  let t = presenting_tester(desk, fn(from) { menu(items, from=beside_of(from)) })
  open_it(t)
  assert_eq(presented_how, [AsPopover])
  let p = theme().p
  assert_eq(inks_of(t, "启动"), [p.subtle])
  assert_eq(inks_of(t, "重命名"), [p.text])
  t.tap_text("启动")
  assert_eq(said, [])
  assert_true(presenting())
}

///|
/// Choices to pick from, `n` of them: 第1项 … 第n项, known as c1 … cn. (No words are told in a test: a key is said
/// as it is, common.search.)
fn choices_of(n : Int) -> Array[Choice] {
  Array::makei(n, fn(i) { choice("c\{i + 1}", "第\{i + 1}项", note=if i == 0 { "最近用过" } else { "" }) })
}

///|
test "a pick with a finger at Small: a sheet of the choices; one tapped is chosen and it closes" {
  let chosen = Ref("c1")
  let t = presenting_tester(phone, fn(from) { pick("选一个", choices_of(3), chosen.val, fn(k) { chosen.val = k }, from=beside_of(from)) }, button_at=JEnd)
  open_it(t)
  assert_eq(presented_how, [AsSheet])
  assert_true(t.find("选一个") is Some(_))
  assert_true(t.find("最近用过") is Some(_))
  t.tap_text("第3项")
  assert_eq(chosen.val, "c3")
  assert_true(!presenting())
}

///|
test "a long pick with a mouse at Large: its search over it finds by the words, Enter picks the first found" {
  let chosen = Ref("c1")
  let t = presenting_tester(desk, fn(from) {
    pick("选一个", choices_of(pick_search_from + 4), chosen.val, fn(k) { chosen.val = k }, from=beside_of(from))
  })
  open_it(t)
  assert_eq(presented_how, [AsPopover])
  assert_true(t.find("第2项") is Some(_))
  t.type_text("第11")
  // (what no longer matches closing its room, gone once it has)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("第2项") is None)
  assert_true(t.find("第11项") is Some(_))
  t.type_text("x")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("common.noMatch") is Some(_))
  t.backspace()
  t.run_for(@ui.move_most_ms)
  assert_true(t.key_named("enter"))
  assert_eq(chosen.val, "c11")
  assert_true(!presenting())
}

///|
test "a long pick with a finger at Small: the search in its sheet finds by the words" {
  let chosen = Ref("c1")
  let t = presenting_tester(phone, fn(from) {
    pick("选一个", choices_of(pick_search_from + 4), chosen.val, fn(k) { chosen.val = k }, from=beside_of(from))
  }, button_at=JEnd)
  open_it(t)
  assert_eq(presented_how, [AsSheet])
  t.tap_text("common.search")
  t.type_text("第12")
  // (what is not found makes its way out: View::each's)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("第3项") is None)
  t.tap_text("第12项")
  assert_eq(chosen.val, "c12")
}

///|
/// A panel's body: its words.
fn panel_body() -> (@view.View, () -> Unit) -> Unit {
  fn(v, _) {
    words_node(v, fn() { "面板里的话" }, fn() { paragraph }) |> ignore
  }
}

///|
test "a panel with a finger at Small: a sheet; back closes it" {
  let said : Array[String] = []
  let t = presenting_tester(phone, fn(from) { panel_nodes("面板", panel_body(), foot=ok_foot(said), from~) }, button_at=JEnd)
  open_it(t)
  assert_eq(presented_how, [AsSheet])
  assert_true(t.find("面板里的话") is Some(_))
  t.back()
  assert_true(!presenting())
  open_it(t)
  t.tap_text("好的")
  assert_eq(said, ["ok"])
  assert_true(!presenting())
}

///|
test "a panel with a mouse at Large: beside what opened it; a press outside closes it" {
  let said : Array[String] = []
  let t = presenting_tester(desk, fn(from) { panel_nodes("面板", panel_body(), foot=ok_foot(said), from~) })
  open_it(t)
  assert_eq(presented_how, [AsPopover])
  let (_, by) = where_is(t, "打开")
  assert_true(where_is(t, "面板").1 > by)
  t.tap(desk.1 - 40.0, desk.2 - 40.0)
  assert_true(!presenting())
  assert_eq(said, [])
}

///|
/// A panel's body of `n` lines (第1行 … 第n行).
fn lines_body(n : Int) -> (@view.View, () -> Unit) -> Unit {
  fn(v, _) {
    for i in 1..=n {
      words_node(v, fn() { "第\{i}行" }, fn() { paragraph }) |> ignore
    }
  }
}

///|
/// A panel's foot: 好的, which says so and closes it.
fn ok_foot(said : Array[String]) -> (@view.View, () -> Unit) -> Unit {
  fn(v, close) {
    button_node(v, fn() { "好的" }, fn() {
      said.push("ok")
      close()
    }, tone=Primary)
    |> ignore
  }
}

///|
test "a sheet's action buttons keep their words whole, sharing the row or going onto another" {
  for (first, second, separate, disabled) in [
    ("取消", "添加到此 workspace", false, false),
    ("取消", "添加到此 workspace", false, true),
    ("Doesn't match, deny", "Turn off security mode", true, false),
  ] {
    let t = presenting_tester((2, 320.0, 844.0), fn(from) {
      panel_nodes("Actions", from~, fn(v, _) { words_node(v, fn() { "Content" }, fn() { paragraph }) |> ignore }, foot=fn(v, _) {
        button_node(v, fn() { first }, fn() {  }) |> ignore
        button_node(v, fn() { second }, fn() {  }, tone=Primary, disabled=fn() { disabled }) |> ignore
      })
    }, button_at=JEnd)
    open_it(t)
    assert_eq(t.lines_of(first), [first], msg="first: \{Repr(t.lines_of(first))}")
    assert_eq(t.lines_of(second), [second], msg="second: \{Repr(t.lines_of(second))}")
    let a = t.rect_of(first).unwrap()
    let b = t.rect_of(second).unwrap()
    if separate {
      assert_true(b.1 >= a.1 + a.3, msg="buttons overlap: \{Repr(a)}, \{Repr(b)}")
    } else {
      assert_true((a.1 - b.1).abs() < 1.0, msg="the buttons fit side by side: \{Repr(a)}, \{Repr(b)}")
    }
  }
}

///|
/// Where `words` are drawn now (their top and bottom, moved as what holds them scrolls), or a failure.
fn drawn_span(t : @ui.Tester, words : String) -> (Double, Double) raise {
  match t.words().iter().find_first(fn(w) { w.0 == words }) {
    Some((_, _, y, _, h, _)) => (y, y + h)
    None => fail("\{words} not drawn")
  }
}

///|
test "a panel with a mouse beside what opened it, as tall as what it holds where that fits" {
  let t = presenting_tester(desk, fn(from) { panel_nodes("面板", lines_body(3), from~, foot=ok_foot([])) })
  open_it(t)
  assert_eq(presented_how, [AsPopover])
  // its foot right under what it holds
  let (_, last) = drawn_span(t, "第3行")
  let (foot, _) = drawn_span(t, "好的")
  assert_true(foot > last && foot < last + 60.0)
}

///|
test "a panel with a mouse opened at the window's foot, with the room over it: over it, as tall as what it holds" {
  let short = (0, 1280.0, 360.0)
  let t = presenting_tester(short, fn(from) { panel_nodes("面板", lines_body(3), from~, foot=ok_foot([])) }, button_at=JEnd)
  let (_, by) = where_is(t, "打开")
  open_it(t)
  let (_, bottom) = drawn_span(t, "好的")
  assert_true(bottom < by, msg="not over what opened it")
}

///|
test "a panel with a mouse taller than the room on either side of what opened it, not than the window: moved over it to stay in, as tall as what it holds" {
  let mid = (0, 1280.0, 400.0)
  let t = presenting_tester(mid, fn(from) { panel_nodes("面板", lines_body(10), from~, foot=ok_foot([])) }, button_at=JCenter)
  let (_, by) = where_is(t, "打开")
  open_it(t)
  // all of it in the window, over the button rather than shortened
  let (top, _) = drawn_span(t, "面板")
  let (_, bottom) = drawn_span(t, "好的")
  assert_true(top > 0.0 && bottom < mid.2, msg="out of the window")
  assert_true(top < by && bottom > by, msg="not moved over what opened it")
  assert_true(drawn_span(t, "第10行").1 < bottom)
}

///|
test "a panel with a mouse taller than the window: as tall as the window lets it, its title and foot in it, what it holds scrolled to" {
  let said : Array[String] = []
  let short = (0, 1280.0, 320.0)
  let t = presenting_tester(short, fn(from) { panel_nodes("面板", lines_body(40), from~, foot=ok_foot(said)) })
  open_it(t)
  assert_eq(presented_how, [AsPopover])
  let (top, _) = drawn_span(t, "面板")
  let (_, bottom) = drawn_span(t, "好的")
  assert_true(top > 0.0, msg="its title out of the window")
  assert_true(bottom < short.2, msg="its foot out of the window")
  // its last line under the foot until what it holds is scrolled, then over it
  let (foot, _) = drawn_span(t, "好的")
  assert_true(drawn_span(t, "第40行").0 > foot)
  let (lx, ly) = where_is(t, "第1行")
  t.wheel(lx, ly, 2000.0)
  assert_true(drawn_span(t, "第40行").1 < foot, msg="what it holds not scrolled to its end")
  assert_true(drawn_span(t, "面板").0 == top, msg="its title scrolled with what it holds")
  t.tap_text("好的")
  assert_eq(said, ["ok"])
  assert_true(!presenting())
}

///|
test "a confirm with a finger at Small: a sheet; its action does it, the cancel does not" {
  let said : Array[String] = []
  let t = presenting_tester(phone, fn(from) {
    confirm("归档这个对话？", "归档后仍可在归档里找到。", "确认归档", fn() { said.push("archived") }, danger=true, from~)
  })
  open_it(t)
  assert_eq(presented_how, [AsSheet])
  t.tap_text("common.cancel")
  assert_eq(said, [])
  assert_true(!presenting())
  open_it(t)
  t.tap_text("确认归档")
  assert_eq(said, ["archived"])
  assert_true(!presenting())
}

///|
test "a confirm with a mouse at Large: a dialog in the middle of the window; Escape closes it, its action does it" {
  let said : Array[String] = []
  let t = presenting_tester(desk, fn(from) {
    confirm("归档这个对话？", "归档后仍可在归档里找到。", "确认归档", fn() { said.push("archived") }, from~)
  })
  open_it(t)
  assert_eq(presented_how, [AsDialog])
  let (x, _) = where_is(t, "归档后仍可在归档里找到。")
  assert_true(x > desk.1 / 2.0 - confirm_w / 2.0 && x < desk.1 / 2.0 + confirm_w / 2.0)
  assert_true(t.key_named("esc"))
  assert_true(!presenting())
  open_it(t)
  t.tap_text("确认归档")
  assert_eq(said, ["archived"])
  assert_true(!presenting())
}

///|
test "a question with a finger at Small: a sheet with its line; its action, once the line differs, goes on with it" {
  let said : Array[String] = []
  let t = presenting_tester(phone, fn(from) {
    ask("重命名", "保存", fn(line) { said.push(line) }, value="旧名字", from~)
  })
  open_it(t)
  assert_eq(presented_how, [AsSheet])
  // the same line as it was: nothing to save
  t.tap_text("保存")
  assert_eq(said, [])
  t.type_text(" 新的 ")
  t.tap_text("保存")
  assert_eq(said, ["旧名字 新的"])
  assert_true(!presenting())
}

///|
test "a question with a mouse at Large: a dialog with its line; Enter says it" {
  let said : Array[String] = []
  let t = presenting_tester(desk, fn(from) { ask("重命名", "保存", fn(line) { said.push(line) }, placeholder="名字", from~) })
  open_it(t)
  assert_eq(presented_how, [AsDialog])
  assert_true(t.key_named("enter"))
  assert_eq(said, [])
  t.type_text("新名字")
  assert_true(t.key_named("enter"))
  assert_eq(said, ["新名字"])
  assert_true(!presenting())
}

///|
test "one over another: a confirm from a menu's item comes when the menu has gone; back closes the topmost first" {
  let said : Array[String] = []
  let t = presenting_tester(phone, fn(from) {
    panel_nodes("面板", fn(v, _) {
      button_node(v, fn() { "删除它" }, fn() { confirm("删掉吗？", "删掉后不能恢复。", "删掉", fn() { said.push("deleted") }, danger=true) })
      |> ignore
    }, from~)
  }, button_at=JEnd)
  open_it(t)
  t.tap_text("删除它")
  t.run_for(presented_rest() - t.time())
  assert_eq(presented_how, [AsSheet, AsSheet])
  t.back()
  assert_eq(presented_how, [AsSheet])
  t.back()
  assert_true(!presenting())
  assert_eq(said, [])
}

///|
/// A panel opened by nothing (a form's dialog): its words, its foot's button closing it as said; what it lets go of
/// as it closes unsaid.
fn dialog_panel(said : Array[String]) -> (Anchor) -> Unit {
  fn(_) {
    panel_nodes(
      "添加一项",
      fn(v, _) { words_node(v, fn() { "填好下面的内容" }, fn() { paragraph }) |> ignore },
      from=Unanchored,
      description="每项都会加密保存",
      foot=fn(v, close) {
        button_node(v, fn() { "确认添加" }, fn() {
          said.push("added")
          close()
        })
        |> ignore
      },
      gone=fn() { said.push("gone") },
    )
  }
}

///|
/// How many grounds over the whole window dim what is under them in the last frame (`at`'s window).
fn scrims_drawn(t : @ui.Tester, at : (Int, Double, Double)) -> Int {
  let (_, w, h) = at
  t
  .drawn_rects()
  .filter(fn(r) { r.0 <= 0.0 && r.1 <= 0.0 && r.2 >= w && r.3 >= h && (r.4 & 0xFFL) > 0L && (r.4 & 0xFFL) < 0xFFL })
  .length()
}

///|
/// Whether something less than the window is dimmed over itself in the last frame, in the colour the window is dimmed
/// with (a dialog with another over it).
fn veiled_drawn(t : @ui.Tester, at : (Int, Double, Double)) -> Bool {
  veiled_in(t.drawn_rects(), at.1, at.2)
}

///|
/// Whether of `rects` one less than the window (`w` by `h`) is drawn in the colour one over all of it dims it with.
fn veiled_in(rects : Array[(Double, Double, Double, Double, Int64)], w : Double, h : Double) -> Bool {
  let see_through = fn(c : Int64) { (c & 0xFFL) > 0L && (c & 0xFFL) < 0xFFL }
  match rects.iter().find_first(fn(r) { r.0 <= 0.0 && r.1 <= 0.0 && r.2 >= w && r.3 >= h && see_through(r.4) }) {
    Some(scrim) => rects.iter().any(fn(r) { (r.2 < w || r.3 < h) && see_through(r.4) && (r.4 >> 8) == (scrim.4 >> 8) })
    None => false
  }
}

///|
/// A panel (opened by 打开, `from` it or by nothing) with 删掉 in it, which asks a confirm over it.
fn panel_with_confirm(at : (Int, Double, Double), by_nothing? : Bool = false) -> @ui.Tester {
  presenting_tester(at, fn(from) {
    panel_nodes(
      "面板",
      from=if by_nothing { Unanchored } else { from },
      fn(v, _) {
        words_node(v, fn() { "面板内容" }, fn() { paragraph }) |> ignore
      },
      foot=fn(v, _) {
        button_node(v, fn() { "删掉" }, fn() { confirm("删掉这个？", "删掉后找不回来。", "确认删掉", fn() {  }, danger=true) }) |> ignore
      },
    )
  }, button_at=JEnd)
}

///|
test "one over another with a finger at Small: one scrim however many sheets, the one under pushed up out of the way and down again" {
  let t = panel_with_confirm(phone)
  open_it(t)
  assert_eq(scrims_drawn(t, phone), 1)
  let (_, y0) = t.drawn_of("面板内容").unwrap()
  t.tap_text("删掉")
  t.run_for(presented_rest() - t.time())
  t.run_for(@ui.move_most_ms)
  assert_eq(presented_how, [AsSheet, AsSheet])
  // (no darker for the second: the one under dims, the one over it not)
  assert_eq(scrims_drawn(t, phone), 1)
  // (the one under pushed up out of its way, whole over it, not laid under it: its words over the confirm's title)
  let (_, y1) = t.drawn_of("面板内容").unwrap()
  let (_, title) = t.drawn_of("删掉这个？").unwrap()
  assert_true(y1 < y0 - pushed_gap && y1 < title, msg="\{y0} \{y1} \{title}")
  // (the two not laid one over the other: the one under ends, foot and all, pushed_gap over the one over it)
  let sheets = t.drawn_glass().copy()
  sheets.sort_by_key(fn(g) { g.1 })
  assert_eq(sheets.length(), 2, msg="\{Repr(sheets)}")
  assert_true(sheets[0].1 + sheets[0].3 + pushed_gap <= sheets[1].1 + 0.5, msg="\{Repr(sheets)}")
  // (the one under taking nothing while it is up: dimmed over itself as the window is, not the window twice)
  assert_true(
    t.drawn_rects().iter().any(fn(r) { r.4 == sheet_scrim && r.3 < phone.2 }),
    msg="\{Repr(t.drawn_rects().filter(fn(r) { (r.4 & 0xFFL) < 0xFFL }))}",
  )
  // (the one over it gone: the one under forward again, its scrim as it was all along)
  t.back()
  t.run_for(presented_rest() - t.time())
  t.run_for(@ui.move_most_ms)
  assert_eq(presented_how, [AsSheet])
  assert_eq(scrims_drawn(t, phone), 1)
  let (_, y2) = t.drawn_of("面板内容").unwrap()
  assert_true((y2 - y0).abs() < 0.5, msg="\{y0} \{y2}")
}

///|
/// The one sheet drawn in the last frame: its top and how tall (a failure where there is none, or more).
fn one_sheet(t : @ui.Tester) -> (Double, Double) raise {
  let sheets = t.drawn_glass().filter(fn(g) { g.3 > 100.0 })
  guard sheets.length() == 1 else { fail("\{sheets.length()} sheets: \{Repr(sheets)}") }
  (sheets[0].1, sheets[0].3)
}

///|
/// How dark the ground over the whole window dims what is under it in the last frame (`at`'s window; 0: none does).
fn scrim_alpha(t : @ui.Tester, at : (Int, Double, Double)) -> Int64 {
  let (_, w, h) = at
  t.drawn_rects().iter().filter(fn(r) { r.0 <= 0.0 && r.1 <= 0.0 && r.2 >= w && r.3 >= h && (r.4 & 0xFFL) < 0xFFL }).fold(
    init=0L,
    fn(a, r) { a + (r.4 & 0xFFL) },
  )
}

///|
/// A menu (重命名, 归档, 固定, 分享) whose 分享 opens a menu from the same place, 分享 (复制链接, 分享图片): each said as
/// it is chosen, `gone` and `level gone` as each is let go of with nothing chosen.
fn menu_with_more(said : Array[String]) -> (Anchor) -> Unit {
  fn(from) {
    let beside = beside_of(from)
    menu(
      [
        Some(menu_item_of("重命名", fn() { said.push("rename") })),
        Some(menu_item_of("归档", fn() { said.push("archive") })),
        Some(menu_item_of("固定", fn() { said.push("pin") })),
        Some(
          menu_item_of("分享", fn() {
            menu(
              [
                Some(menu_item_of("复制链接", fn() { said.push("copy") })),
                Some(menu_item_of("分享图片", fn() { said.push("image") })),
              ],
              from=beside,
              title="分享",
              gone=fn() { said.push("level gone") },
            )
          }, further=true),
        ),
      ],
      from=beside,
      gone=fn() { said.push("gone") },
    )
  }
}

///|
/// The frames a sheet's way takes at most, each looked at.
let way_frames : Int = 40

///|
test "a menu's item that opens a menu, with a finger at Small: a level of the same sheet, one sheet and the scrim as it was all the way; back is back to the menu" {
  let said : Array[String] = []
  let t = presenting_tester(phone, menu_with_more(said), button_at=JEnd)
  open_it(t)
  let (top0, _) = one_sheet(t)
  let dim = scrim_alpha(t, phone)
  assert_true(dim > 0L)
  t.tap_text("分享")
  // (the frame it was chosen in: the menu's sheet where it stood, the window as dim; nothing let go of)
  assert_eq(presented_how, [AsSheet])
  assert_true((one_sheet(t).0 - top0).abs() < 0.5, msg="\{Repr(one_sheet(t))} \{top0}")
  assert_eq(scrim_alpha(t, phone), dim)
  // (on its way to the level's height, shorter: down only, never two sheets, the window never brighter)
  let mut last = top0
  for _ in 0..<way_frames {
    t.run_for(@ui.frame_period_default)
    let (top, _) = one_sheet(t)
    assert_eq(scrim_alpha(t, phone), dim)
    assert_true(top >= last - 0.5, msg="\{top} after \{last}")
    last = top
  }
  assert_true(last > top0 + 20.0, msg="\{last} \{top0}")
  assert_true(t.find("复制链接") is Some(_) && t.find("重命名") is None)
  // (its title over its rows)
  assert_true(where_is(t, "分享").1 < where_is(t, "复制链接").1)
  assert_eq(said, [])
  // back: the menu again, as tall as it was; the level let go of, the menu not
  t.back()
  assert_true(presenting())
  for _ in 0..<way_frames {
    t.run_for(@ui.frame_period_default)
    one_sheet(t) |> ignore
    assert_eq(scrim_alpha(t, phone), dim)
  }
  assert_true(t.find("重命名") is Some(_) && t.find("复制链接") is None)
  assert_true((one_sheet(t).0 - top0).abs() < 0.5, msg="\{Repr(one_sheet(t))} \{top0}")
  assert_eq(said, ["level gone"])
  t.back()
  assert_true(!presenting())
  t.run_for(@ui.move_most_ms)
  assert_eq(said, ["level gone", "gone"])
  // chosen in the level: done, all of it closed, nothing let go of unsaid
  open_it(t)
  t.tap_text("分享")
  t.run_for(@ui.move_most_ms)
  t.tap_text("复制链接")
  assert_true(!presenting())
  t.run_for(@ui.move_most_ms)
  assert_eq(said, ["level gone", "gone", "copy"])
  // gone back to from the level, the menu chosen in as ever: what it does done, all of it closed
  open_it(t)
  t.tap_text("分享")
  t.run_for(@ui.move_most_ms)
  t.back()
  t.run_for(@ui.move_most_ms)
  t.tap_text("归档")
  assert_true(!presenting())
  t.run_for(@ui.move_most_ms)
  assert_eq(said, ["level gone", "gone", "copy", "level gone", "archive"])
}

///|
test "a menu's item that opens a menu, with a mouse at Large: submenu pushes in the same popover; back pops level, esc closes all" {
  let said : Array[String] = []
  let t = presenting_tester(desk, menu_with_more(said))
  open_it(t)
  t.tap_text("分享")
  t.run_for(@motion.presence_in_ms)
  assert_eq(presented_how, [AsPopover])
  assert_true(t.find("复制链接") is Some(_))
  assert_true(t.key_named("esc"))
  assert_true(!presenting())
  assert_eq(said, ["level gone", "gone"])
}

///|
test "what a sheet's item opens with a finger at Small: a sheet in its place, from as tall as that one stood, the scrim as it was, never two" {
  let said : Array[String] = []
  let t = presenting_tester(phone, fn(from) {
    menu(
      [
        Some(menu_item_of("重命名", fn() { ask("重命名", "保存", fn(line) { said.push(line) }, value="旧名字", from~) })),
        Some(menu_item_of("归档", fn() { said.push("archive") })),
        Some(menu_item_of("固定", fn() { said.push("pin") })),
        Some(menu_item_of("静音", fn() { said.push("mute") })),
        Some(menu_item_of("隐藏", fn() { said.push("hide") })),
        Some(
          menu_item_of(
            "删掉",
            fn() { confirm("删掉吗？", "删掉后不能恢复。", "删掉它", fn() { said.push("deleted") }, danger=true, from~) },
            danger=true,
          ),
        ),
      ],
      from=beside_of(from),
    )
  }, button_at=JEnd)
  for opened in [("删掉", "删掉吗？", "删掉它"), ("重命名", "保存", "保存")] {
    let (item, words, action) = opened
    open_it(t)
    let (top0, _) = one_sheet(t)
    let dim = scrim_alpha(t, phone)
    assert_true(dim > 0L)
    t.tap_text(item)
    // (the frame it was chosen in: what it opened where the menu stood, the menu gone, the window as dim)
    assert_eq(presented_how, [AsSheet], msg=item)
    assert_true((one_sheet(t).0 - top0).abs() < 0.5, msg="\{item}: \{Repr(one_sheet(t))} \{top0}")
    assert_eq(scrim_alpha(t, phone), dim, msg=item)
    assert_true(t.find(words) is Some(_) && t.find("归档") is None, msg=item)
    // (on its way to its own height, shorter: down only, never two sheets, the window never brighter)
    let mut last = top0
    for _ in 0..<way_frames {
      t.run_for(@ui.frame_period_default)
      let (top, _) = one_sheet(t)
      assert_eq(scrim_alpha(t, phone), dim, msg=item)
      assert_true(top >= last - 0.5, msg="\{item}: \{top} after \{last}")
      last = top
    }
    assert_true(last > top0 + 20.0, msg="\{item}: \{last} \{top0}")
    // (as tall as what it holds: its action over the window's foot)
    assert_true(where_is(t, action).1 < phone.2, msg=item)
    t.back()
    assert_true(!presenting(), msg=item)
    t.run_for(@ui.move_most_ms)
  }
  assert_eq(said, [])
}

///|
/// A panel, 信息 (opened by 打开, by nothing), whose 看详情 closes it and opens another, 详情: each `gone` said as it is
/// let go of unsaid.
fn panel_with_more(said : Array[String]) -> (Anchor) -> Unit {
  fn(_) {
    panel_nodes(
      "信息",
      fn(v, close) {
        words_node(v, fn() { "信息内容" }, fn() { paragraph }) |> ignore
        words_node(v, fn() { "信息的第二行" }, fn() { paragraph }) |> ignore
        words_node(v, fn() { "信息的第三行" }, fn() { paragraph }) |> ignore
        button_node(v, fn() { "看详情" }, fn() {
          close()
          panel_nodes("详情", fn(v, _) { words_node(v, fn() { "详情内容" }, fn() { paragraph }) |> ignore }, from=Unanchored, gone=fn() {
            said.push("detail gone")
          })
        })
        |> ignore
      },
      from=Unanchored,
      gone=fn() { said.push("info gone") },
    )
  }
}

///|
test "a panel a panel's button opens as it closes, with a finger at Small: a step further in, in its place; back is back to the first, a press outside closes all" {
  let said : Array[String] = []
  let t = presenting_tester(phone, panel_with_more(said))
  open_it(t)
  let (top0, _) = one_sheet(t)
  let dim = scrim_alpha(t, phone)
  assert_true(dim > 0L)
  t.tap_text("看详情")
  // (the frame it was pressed in: the next where the first stood, the window as dim)
  assert_eq(presented_how, [AsSheet])
  assert_true((one_sheet(t).0 - top0).abs() < 0.5, msg="\{Repr(one_sheet(t))} \{top0}")
  assert_eq(scrim_alpha(t, phone), dim)
  // (a page of the same sheet: sliding in over the first, which slides off)
  assert_true(t.find("详情内容") is Some(_))
  for _ in 0..<way_frames {
    t.run_for(@ui.frame_period_default)
    one_sheet(t) |> ignore
    assert_eq(scrim_alpha(t, phone), dim)
  }
  assert_true(t.find("信息内容") is None)
  let (top1, _) = one_sheet(t)
  assert_true(top1 > top0 + 10.0, msg="\{top1} \{top0}")
  assert_eq(said, [])
  // back: the first again where this one stood, on to as tall as it was; this one let go of, the first not
  t.back()
  assert_true(presenting())
  assert_true(t.find("信息内容") is Some(_))
  assert_true((one_sheet(t).0 - top1).abs() < 0.5, msg="\{Repr(one_sheet(t))} \{top1}")
  assert_eq(scrim_alpha(t, phone), dim)
  for _ in 0..<way_frames {
    t.run_for(@ui.frame_period_default)
    one_sheet(t) |> ignore
    assert_eq(scrim_alpha(t, phone), dim)
  }
  assert_true((one_sheet(t).0 - top0).abs() < 0.5, msg="\{Repr(one_sheet(t))} \{top0}")
  assert_eq(said, ["detail gone"])
  // in again and back again, then back from the first: closed
  t.tap_text("看详情")
  t.run_for(@ui.move_most_ms)
  t.back()
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("信息内容") is Some(_))
  t.back()
  assert_true(!presenting())
  t.run_for(@ui.move_most_ms)
  assert_eq(said, ["detail gone", "detail gone", "info gone"])
  // a press outside the step further in: all of it closed
  open_it(t)
  t.tap_text("看详情")
  t.run_for(@ui.move_most_ms)
  t.tap(phone.1 / 2.0, 40.0)
  assert_true(!presenting())
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("信息内容") is None && t.find("详情内容") is None)
}

///|
test "a panel a panel's button opens as it closes, with a mouse at Large: a step further in, a dialog with a back key; its back key and Escape are back to the first, a press outside closes all" {
  let said : Array[String] = []
  let t = presenting_tester(desk, panel_with_more(said))
  open_it(t)
  t.tap_text("看详情")
  t.run_for(@motion.presence_in_ms)
  assert_true(t.find("详情内容") is Some(_) && t.find("信息内容") is None)
  // its back key, before its title: back to the first
  t.click(Button, label="common.back")
  t.run_for(@motion.presence_in_ms)
  assert_true(presenting())
  assert_true(t.find("信息内容") is Some(_) && t.find("详情内容") is None)
  assert_eq(said, ["detail gone"])
  // (the first has none: nothing before it)
  assert_true(t.query(Button, label="common.back") is None)
  // Escape: back to the first, then closed
  t.tap_text("看详情")
  t.run_for(@motion.presence_in_ms)
  assert_true(t.key_named("esc"))
  t.run_for(@motion.presence_in_ms)
  assert_true(presenting() && t.find("信息内容") is Some(_))
  assert_true(t.key_named("esc"))
  assert_true(!presenting())
  assert_eq(said, ["detail gone", "detail gone", "info gone"])
  // a press outside the step further in: all of it closed
  open_it(t)
  t.tap_text("看详情")
  t.run_for(@motion.presence_in_ms)
  t.tap(8.0, 8.0)
  assert_true(!presenting())
}

///|
/// Each kind of presenter, presented by what `from` opened: what in it is called `word` (a menu's item, a pick's
/// choice, a confirm's and a question's action, a button in a panel of nodes, of nodes a share of the window tall) closes it and does `then`.
fn kinds_of(from : Anchor, word : String, then : () -> Unit) -> Array[(String, () -> Unit)] {
  let beside = beside_of(from)
  [
    ("a menu", fn() { menu([Some(menu_item_of("别的", fn() {  })), Some(menu_item_of(word, then))], from=beside) }),
    ("a pick", fn() { pick("选一个", [choice("a", "别的"), choice("b", word)], "a", fn(_) { then() }, from=beside) }),
    ("a confirm", fn() { confirm("确定吗？", "这里说明它做什么。", word, then, from~) }),
    ("a question", fn() { ask("写一句", word, fn(_) { then() }, empty=true, from~) }),
    (
      "a panel of nodes",
      fn() {
        panel_nodes(
          "节点面板",
          fn(v, close) {
            button_node(v, fn() { word }, fn() {
              close()
              then()
            })
            |> ignore
          },
          from=Unanchored,
        )
      },
    ),
    (
      "a tall panel of nodes",
      fn() {
        panel_nodes(
          "高的节点面板",
          fn(v, close) {
            button_node(v, fn() { word }, fn() {
              close()
              then()
            })
            |> ignore
          },
          from=Unanchored,
          tall=0.6,
        )
      },
    ),
  ]
}

///|
test "with a finger at Small, whatever kind of sheet closes for whatever kind: that one in its place where the first stood, one sheet and the scrim as it was on every frame" {
  let kinds = kinds_of(At(0.0, 0.0, 0.0, 0.0), "", fn() {  }).length()
  for i in 0..<kinds {
    for j in 0..<kinds {
      let named : Ref[String] = Ref("")
      let t = presenting_tester(phone, fn(from) {
        let nexts = kinds_of(from, "完成", fn() {  })
        let firsts = kinds_of(from, "下一步", nexts[j].1)
        named.val = "\{firsts[i].0}, then \{nexts[j].0}"
        (firsts[i].1)()
      }, button_at=JEnd)
      t.tap_text("打开")
      t.run_for(@ui.move_most_ms + @motion.sheet_scrim_ms)
      let at = named.val
      let first = t.drawn_glass().filter(fn(g) { g.3 > 100.0 })
      assert_eq(first.length(), 1, msg="\{at}: the first: \{Repr(first)}")
      let top0 = first[0].1
      let dim = scrim_alpha(t, phone)
      assert_true(dim > 0L, msg=at)
      // (a question's action said once its line has words)
      if at.has_prefix("a question") {
        t.type_text("一句")
      }
      t.tap_text("下一步")
      // (the frame it was chosen in, and every frame of its way: one sheet, the window as dim; in that frame where the
      // first stood)
      for k in 0..<way_frames {
        let sheets = t.drawn_glass().filter(fn(g) { g.3 > 100.0 })
        assert_eq(sheets.length(), 1, msg="\{at}, frame \{k}: \{Repr(sheets)}")
        assert_eq(scrim_alpha(t, phone), dim, msg="\{at}, frame \{k}")
        if k == 0 {
          assert_true((sheets[0].1 - top0).abs() < 0.5, msg="\{at}: \{sheets[0].1} where the first stood \{top0}")
        }
        t.run_for(@ui.frame_period_default)
      }
      assert_true(t.find("完成") is Some(_), msg=at)
      // closed, however many steps back that is
      for _ in 0..<3 {
        if presenting() {
          t.back()
          t.run_for(@ui.move_most_ms + @motion.sheet_scrim_ms)
        }
      }
      assert_true(!presenting(), msg=at)
    }
  }
}

///|
test "one over another with a mouse at Large: a confirm over a dialog dims no darker" {
  let t = panel_with_confirm(desk, by_nothing=true)
  open_it(t)
  assert_eq(presented_how, [AsDialog])
  assert_eq(scrims_drawn(t, desk), 1)
  t.tap_text("删掉")
  t.run_for(@motion.presence_in_ms)
  assert_eq(presented_how, [AsDialog, AsDialog])
  assert_eq(scrims_drawn(t, desk), 1)
  // (the dialog under it taking nothing: dimmed over itself, as the window is)
  t.run_for(confirm_ground_ms)
  assert_true(veiled_drawn(t, desk), msg="\{Repr(t.drawn_rects())}")
  // (the confirm closed: the dialog's scrim as it was all along, none fading over it)
  assert_true(t.key_named("esc"))
  t.run_for(@motion.presence_in_ms)
  assert_eq(scrims_drawn(t, desk), 1)
}

///|
test "a panel opened by nothing with a mouse at Large: a dialog in the middle; Escape lets go of it, its foot says it" {
  let said : Array[String] = []
  let t = presenting_tester(desk, dialog_panel(said))
  open_it(t)
  assert_eq(presented_how, [AsDialog])
  assert_true(t.find("每项都会加密保存") is Some(_))
  let (x, _) = where_is(t, "填好下面的内容")
  assert_true(x > desk.1 / 2.0 - dialog_w / 2.0 && x < desk.1 / 2.0 + dialog_w / 2.0)
  assert_true(t.key_named("esc"))
  assert_true(!presenting())
  assert_eq(said, ["gone"])
  open_it(t)
  t.tap_text("确认添加")
  assert_true(!presenting())
  assert_eq(said, ["gone", "added"])
}

///|
test "a panel opened by nothing with a finger at Small: a sheet with its words and its foot" {
  let said : Array[String] = []
  let t = presenting_tester(phone, dialog_panel(said))
  open_it(t)
  assert_eq(presented_how, [AsSheet])
  assert_true(t.find("每项都会加密保存") is Some(_))
  t.tap_text("确认添加")
  assert_eq(said, ["added"])
  assert_true(!presenting())
}

///|
test "a short pick with a mouse at Large: a menu of choices beside what opened it, the chosen checked; one clicked" {
  let chosen = Ref("c1")
  let t = presenting_tester(desk, fn(from) { pick("选一个", choices_of(3), chosen.val, fn(k) { chosen.val = k }, from=beside_of(from)) })
  let (_, by) = where_is(t, "打开")
  open_it(t)
  assert_eq(presented_how, [AsPopover])
  let (_, y) = where_is(t, "第1项")
  assert_true(y > by && y < by + 80.0)
  // its note at its end
  assert_true(t.find("最近用过") is Some(_))
  t.tap_text("第2项")
  assert_eq(chosen.val, "c2")
  assert_true(!presenting())
}

///|
/// The thin lines drawn (rects 2 high at most and 60 wide at least) with the menu of `items` open by 打开 in window `at`.
fn menu_rules_drawn(at : (Int, Double, Double), items : Array[MenuItem?]) -> Int {
  let t = presenting_tester(at, fn(from) { menu(items, from=beside_of(from)) }, button_at=JEnd)
  open_it(t)
  t.drawn_rects().filter(fn(d) { d.3 <= 2.0 && d.2 >= 60.0 }).length()
}

///|
test "a menu's lines: none at either end, never two together, whatever was given as None, as a sheet at Small and beside what opened it at Large" {
  let a = fn() { Some(menu_item_of("一", fn() {  })) }
  let b = fn() { Some(menu_item_of("二", fn() {  })) }
  assert_eq(menu_clean_items([None, a(), None, None, b(), None]).map(fn(x) { x is Some(_) }), [true, false, true])
  assert_eq(menu_clean_items([None, None]).length(), 0)
  for at in [phone, desk] {
    let none = menu_rules_drawn(at, [a(), b()])
    let one = menu_rules_drawn(at, [a(), None, b()])
    assert_eq(one, none + 1, msg="\{at.0}: a line between")
    assert_eq(menu_rules_drawn(at, [None, a(), None, None, b(), None]), one, msg="\{at.0}: still one, none at the ends")
  }
}

///|
test "Small upper-half triggers open popovers only for short Menu/Pick, while Panels, long lists, and lower-half triggers keep sheets" {
  // upper-half short menu (<= 12 items) -> AsPopover without scrim
  let t_menu = presenting_tester(phone, fn(from) { menu(menu_items_of([]), from=beside_of(from)) }, button_at=JStart)
  open_it(t_menu)
  assert_eq(presented_how, [AsPopover])
  assert_eq(scrims_drawn(t_menu, phone), 0)
  assert_true(where_is(t_menu, "重命名").1 < phone.2 / 2.0)

  // upper-half short pick (< pick_search_from) -> AsPopover without scrim
  let t_pick = presenting_tester(
    phone,
    fn(from) { pick("选一个", choices_of(3), "c1", fn(_) {  }, from=beside_of(from)) },
    button_at=JStart,
  )
  open_it(t_pick)
  assert_eq(presented_how, [AsPopover])
  assert_eq(scrims_drawn(t_pick, phone), 0)
  assert_true(where_is(t_pick, "第1项").1 < phone.2 / 2.0)

  // upper-half non-searchable pick with <= small_popover_menu_most items -> AsPopover without scrim
  let t_pick_nosearch = presenting_tester(
    phone,
    fn(from) { pick("选一个", choices_of(small_popover_menu_most), "c1", fn(_) {  }, from=beside_of(from), search=false) },
    button_at=JStart,
  )
  open_it(t_pick_nosearch)
  assert_eq(presented_how, [AsPopover])
  assert_eq(scrims_drawn(t_pick_nosearch, phone), 0)

  // upper-half explicit popover=true anchored panel -> AsPopover without scrim
  let t_panel_pop = presenting_tester(
    phone,
    fn(from) { panel_nodes("切换面板", panel_body(), from~, popover=true) },
    button_at=JStart,
  )
  open_it(t_panel_pop)
  assert_eq(presented_how, [AsPopover])
  assert_eq(scrims_drawn(t_panel_pop, phone), 0)
  assert_true(where_is(t_panel_pop, "面板里的话").1 < phone.2 / 2.0)

  // upper-half default Panels (popover=false), popover=true with unanchored/form/steps/grows,
  // long Menu (> 12), searchable long Pick (>= pick_search_from), non-searchable Pick (> 12), Confirm, Ask -> AsSheet with scrim
  let long_menu_items : Array[MenuItem?] = Array::makei(small_popover_menu_most + 1, fn(i) {
    Some(menu_item_of("第\{i + 1}项", fn() {  }))
  })
  let sheet_cases : Array[(String, (Anchor) -> Unit)] = [
    ("panel", fn(from) { panel_nodes("面板", panel_body(), from~) }),
    ("panel-tall-hugs", fn(from) { panel_nodes("半高面板", panel_body(), from~, tall=0.62, hugs=true) }),
    ("unanchored", fn(_) { panel_nodes("无锚点", panel_body(), from=Unanchored) }),
    ("popover-unanchored", fn(_) { panel_nodes("无锚点切换", panel_body(), from=Unanchored, popover=true) }),
    ("form", fn(from) { panel_nodes("表单", panel_body(), from~, form=true, popover=true) }),
    ("steps", fn(from) { panel_nodes("分步", panel_body(), from~, steps=true, popover=true) }),
    ("grows", fn(from) { panel_nodes("长列表", panel_body(), from~, grows=true, popover=true) }),
    ("long-menu", fn(from) { menu(long_menu_items, from=beside_of(from)) }),
    ("searchable-long-pick", fn(from) { pick("长选择", choices_of(pick_search_from), "c1", fn(_) {  }, from=beside_of(from)) }),
    ("overlong-nosearch-pick", fn(from) { pick("超长选择", choices_of(small_popover_menu_most + 1), "c1", fn(_) {  }, from=beside_of(from), search=false) }),
    ("confirm", fn(from) { confirm("确定？", "说明", "好", fn() {  }, from~) }),
    ("ask", fn(from) { ask("输入", "保存", fn(_) {  }, from~) }),
  ]
  for item in sheet_cases {
    let (name, open) = item
    let t = presenting_tester(phone, open, button_at=JStart)
    open_it(t)
    assert_eq(presented_how, [AsSheet], msg=name)
    assert_eq(scrims_drawn(t, phone), 1, msg=name)
  }

  // lower-half triggers (even short menu or popover=true panel) -> AsSheet
  let t_low = presenting_tester(phone, fn(from) { menu(menu_items_of([]), from=beside_of(from)) }, button_at=JEnd)
  open_it(t_low)
  assert_eq(presented_how, [AsSheet])
  assert_eq(scrims_drawn(t_low, phone), 1)

  let t_low_panel = presenting_tester(
    phone,
    fn(from) { panel_nodes("底部切换", panel_body(), from~, popover=true) },
    button_at=JEnd,
  )
  open_it(t_low_panel)
  assert_eq(presented_how, [AsSheet])
  assert_eq(scrims_drawn(t_low_panel, phone), 1)
}

///|
test "Small narrow 320pt short popover and popover=true panel clamp width and hug tall+hugs content" {
  let narrow = (2, 320.0, 568.0)
  let t_menu = presenting_tester(
    narrow,
    fn(from) { menu(menu_items_of([]), from=beside_of(from)) },
    button_at=JStart,
  )
  open_it(t_menu)
  assert_eq(presented_how, [AsPopover])
  let (mx, my, mw, _) = t_menu.rect_of("重命名").unwrap()
  assert_true(mx >= 0.0 && mx + mw <= narrow.1, msg="clamped menu width: \{mx} + \{mw}")
  assert_true(my < narrow.2 / 2.0, msg="menu in upper half: \{my}")

  let t_pick = presenting_tester(
    narrow,
    fn(from) { pick("选一个", choices_of(3), "c1", fn(_) {  }, from=beside_of(from)) },
    button_at=JStart,
  )
  open_it(t_pick)
  assert_eq(presented_how, [AsPopover])
  let (px, _, pw, _) = t_pick.rect_of("第1项").unwrap()
  assert_true(px >= 0.0 && px + pw <= narrow.1, msg="clamped pick width: \{px} + \{pw}")

  // popover=true panel clamped within 320pt viewport and tall=0.7 hugs=true fits 2 rows tightly
  let t_panel = presenting_tester(
    narrow,
    fn(from) {
      panel_nodes("窄屏切换", from~, w=420.0, tall=0.7, hugs=true, popover=true, fn(v, _) {
        words_node(v, fn() { "第一项" }, fn() { paragraph }) |> ignore
        words_node(v, fn() { "第二项" }, fn() { paragraph }) |> ignore
      })
    },
    button_at=JStart,
  )
  open_it(t_panel)
  assert_eq(presented_how, [AsPopover])
  let (p1_x, p1_y, p1_w, _) = t_panel.rect_of("第一项").unwrap()
  let (_, p2_y, _, p2_h) = t_panel.rect_of("第二项").unwrap()
  assert_true(p1_x >= 0.0 && p1_x + p1_w <= narrow.1, msg="clamped width: \{p1_x} + \{p1_w}")
  assert_true(p2_y + p2_h - p1_y < 160.0, msg="hugs height")
  let (_, panel_bot) = drawn_span(t_panel, "第二项")
  assert_true(panel_bot < narrow.2 * 0.55, msg="popover hugs content rather than taking 0.7 of window")
}

///|
test "Small sheet_node: tall=0.0 grows=true caps at sheet_most at rest, and tall=0.62 hugs=true grows=true grows to sheet_most on drag" {
  let tall_body = fn(v : @view.View, _ : () -> Unit) {
    for i in 0..<40 {
      words_node(v, fn() { "第\{i + 1}行内容" }, fn() { paragraph }) |> ignore
    }
  }
  // 1) tall=0.0, grows=true with very tall content: at rest (!dragging) capped at sheet_most (0.94 * h), never hits top (y=0)
  let t1 = presenting_tester(
    phone,
    fn(_) { panel_nodes("超长详情", tall_body, from=Unanchored, grows=true) },
    button_at=JStart,
  )
  open_it(t1)
  assert_eq(presented_how, [AsSheet])
  let dlg1 = t1.get(@ui.Role::Dialog)
  let cap1 = phone.2 * sheet_most
  assert_true(dlg1.rect.3 <= cap1 + 1.0, msg="grows=true at rest should not exceed sheet_most (\{cap1}): got \{Repr(dlg1.rect)}")
  assert_true(dlg1.rect.1 >= phone.2 * (1.0 - sheet_most) - 1.0, msg="grows=true at rest stays below top bar: \{Repr(dlg1.rect)}")

  // 2) tall=0.62, hugs=true, grows=true with very tall content: opens capped at 0.62 * h, dragging grabber up grows to sheet_most
  let t2 = presenting_tester(
    phone,
    fn(_) { panel_nodes("半高可扩展", tall_body, from=Unanchored, tall=0.62, hugs=true, grows=true) },
    button_at=JStart,
  )
  open_it(t2)
  assert_eq(presented_how, [AsSheet])
  let dlg2_init = t2.get(@ui.Role::Dialog)
  assert_true(dlg2_init.rect.3 <= phone.2 * 0.62 + 2.0, msg="tall=0.62 hugs=true opens capped at 0.62: \{Repr(dlg2_init.rect)}")
  // drag the grabber upward to expand to sheet_most
  let grab_y = dlg2_init.rect.1 + 12.0
  t2.drag(phone.1 / 2.0, grab_y, phone.1 / 2.0, 60.0)
  t2.run_for(@ui.move_most_ms)
  let dlg2_grown = t2.get(@ui.Role::Dialog)
  assert_true(dlg2_grown.rect.3 >= phone.2 * 0.9, msg="dragging tall=0.62 hugs=true grows=true expands to sheet_most: \{Repr(dlg2_grown.rect)}")
}

///|
test "Small sheet_node: a steps=true panel pushed into an existing sheet via panel_page steps deeper with panel_go_nodes" {
  let step2_left = Ref(0)
  let step3_left = Ref(0)
  let t = presenting_tester(
    phone,
    fn(_) {
      panel_nodes("外层抽屉", from=Unanchored, grows=true, fn(v, close) {
        button_node(v, fn() { "打开模型" }, fn() {
          close()
          panel_nodes(
            "模型",
            from=Unanchored,
            steps=true,
            ruled=true,
            foot=fn(f, _) { words_node(f, fn() { "页脚操作" }, fn() { paragraph }) |> ignore },
            fn(m, _) {
              button_node(m, fn() { "全部模型" }, fn() {
                panel_go_nodes(
                  "全部模型",
                  left=fn() { step2_left.val += 1 },
                  foot=fn(f, _) { words_node(f, fn() { "全部页脚" }, fn() { paragraph }) |> ignore },
                  fn(a, _) {
                    button_node(a, fn() { "Anthropic" }, fn() {
                      panel_go_nodes(
                        "Anthropic",
                        left=fn() { step3_left.val += 1 },
                        foot=fn(f, _) { words_node(f, fn() { "厂商页脚" }, fn() { paragraph }) |> ignore },
                        fn(k, _) { words_node(k, fn() { "Sonnet 5" }, fn() { paragraph }) |> ignore },
                      )
                    })
                    |> ignore
                  },
                )
              })
              |> ignore
            },
          )
        })
        |> ignore
      })
    },
    button_at=JStart,
  )
  open_it(t)
  assert_true(t.query(Button, label="打开模型") is Some(_))
  t.click(Button, label="打开模型")
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="全部模型") is Some(_), msg="model page opened inside existing sheet")
  // Step 1 -> Step 2 (全部模型)
  t.click(Button, label="全部模型")
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="Anthropic") is Some(_), msg="全部模型 step opened inside chained sheet")
  assert_true(t.query(Button, label="全部模型") is None, msg="previous page hidden while 全部模型 shows")
  assert_true(t.find("全部页脚") is Some(_), msg="step 2 footer rendered")
  // Step 2 -> Step 3 (Anthropic)
  t.click(Button, label="Anthropic")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("Sonnet 5") is Some(_), msg="maker step opened from 全部模型")
  assert_true(t.find("厂商页脚") is Some(_), msg="step 3 footer rendered")
  // Back unwinds step 3 -> step 2 -> step 1 -> outer sheet
  t.click(Button, label="common.back")
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="Anthropic") is Some(_) && step3_left.val == 1)
  t.click(Button, label="common.back")
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="全部模型") is Some(_) && step2_left.val == 1)
  t.click(Button, label="common.back")
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="打开模型") is Some(_))
}

///|
test "Small sheet_node: last_presented returns the reused sheet serial after panel_page when an overlay opened and closed earlier" {
  let reused_serial = Ref(0)
  let t = presenting_tester(
    phone,
    fn(_) {
      panel_nodes("外层抽屉", from=Unanchored, fn(v, close) {
        button_node(v, fn() { "临时浮层" }, fn() {
          panel_nodes("临时", from=Unanchored, fn(tmp, close_tmp) {
            button_node(tmp, fn() { "关掉临时" }, close_tmp) |> ignore
          })
        })
        |> ignore
        button_node(v, fn() { "下一步面板" }, fn() {
          close()
          panel_nodes("第二页", from=Unanchored, steps=true, fn(p2, _) {
            words_node(p2, fn() { "第二页内容" }, fn() { paragraph }) |> ignore
          })
          reused_serial.val = last_presented()
        })
        |> ignore
      })
    },
    button_at=JStart,
  )
  open_it(t)
  let base_serial = last_presented()
  t.click(Button, label="临时浮层")
  t.run_for(@ui.move_most_ms)
  let tmp_serial = last_presented()
  assert_true(tmp_serial > base_serial)
  t.click(Button, label="关掉临时")
  t.run_for(@ui.move_most_ms)
  assert_false(presented_open_of(tmp_serial))
  assert_true(presented_open_of(base_serial))
  t.click(Button, label="下一步面板")
  t.run_for(@ui.move_most_ms)
  assert_eq(reused_serial.val, base_serial)
  assert_true(presented_open_of(reused_serial.val))
}
