// A part of the window not in use (View::in_use): the keyboard's focus none of it (Tree::takes_keys). All it holds, a
// node and an old view's widget, gone to by no Tab and read out as taking no focus, the focus in it let go of at the
// moment it stops being in use; the hand's as ever (a press, a hold its cover hands through); in use again, all of it
// as before from that moment.

///|
/// A node "甲" beside a part in use while `on` holds, a node "乙" and an old view's button "丙" in it, each 80 by 40 in
/// a row; a cover over "丙" alone, its hold going through. What each was told, in order.
fn in_use_tester(on : @signals.Signal[Bool]) -> (Tester, Array[String]) {
  let said : Array[String] = []
  let note = fn(s : String) {
    if said.last() != Some(s) {
      said.push(s)
    }
  }
  let t = Tester::new(fn(_c) {  }, w=400.0, h=200.0, platform=2)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.row(Is(true)) |> ignore
    root.box(fn(a) {
      a
      .width(Is(Some(80.0)))
      .height(Is(Some(40.0)))
      .says(Is(Some(@view.said(Button, label="甲"))))
      .focusable(Is(true))
      .on_press(fn() { note("甲 pressed") })
      |> ignore
    })
    |> ignore
    root.box(fn(part) {
      part.row(Is(true)).in_use(By(fn() { on.get() })) |> ignore
      part.box(fn(b) {
        b
        .width(Is(Some(80.0)))
        .height(Is(Some(40.0)))
        .says(Is(Some(@view.said(Button, label="乙"))))
        .focusable(Is(true))
        .on_press(fn() { note("乙 pressed") })
        |> ignore
      })
      |> ignore
      part.box(fn(h) {
        h.width(Is(Some(80.0))).height(Is(Some(40.0))) |> ignore
        old(h, fn(c) {
          let id = c.id("丙")
          c.interact(id) |> ignore
          c.on_press(id, fn() { note("丙 clicked") })
          if c.held_long(id) {
            note("丙 held")
          }
          let i = c.box(w=Px(80.0), h=Px(40.0), id~, fn() {  })
          c.semantics(i, Button, id~, label="丙", actions=[Activate])
        })
        .grow(Is(1.0))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    // (the cover, over "丙" alone)
    root.box(fn(cv) {
      cv
      .over(Is(true))
      .width(Is(Some(80.0)))
      .height(Is(Some(40.0)))
      .offset(Is((160.0, 0.0)))
      .gesture(touch_slop(), tap=fn(_) { note("cover tap") }, through=long_press_ms)
      |> ignore
    })
    |> ignore
  })
  t.draw()
  (t, said)
}

///|
/// The names Tab goes to, from what has the focus round to it again (8 at most).
fn in_use_round(t : Tester) -> Array[String] {
  let first = t.focus_said()
  let out = []
  for _ in 0..<8 {
    t.tab()
    if t.focus_said() == first {
      break
    }
    out.push(t.focused().map(fn(s) { s.label }).unwrap_or(""))
  }
  out
}

///|
/// Whether what is called `label` is read out as able to take the focus.
fn in_use_focusable(t : Tester, label : String) -> Bool {
  t.semantics().iter().any(fn(s) { s.label == label && (s.actions.contains(Focus) || s.focused) })
}

///|
/// Whether what is called `label` is read out.
fn in_use_read(t : Tester, label : String) -> Bool {
  t.semantics().iter().any(fn(s) { s.label == label && !s.hidden })
}

///|
test "a part in use: Tab goes to the node and the old view's widget in it, both read out" {
  let on = @signals.signal(true, same=fn(a, b) { a == b })
  let (t, _) = in_use_tester(on)
  t.act(Button, Focus, label="甲")
  assert_eq(in_use_round(t), ["乙", "丙"])
  assert_true(in_use_read(t, "乙") && in_use_read(t, "丙"))
}

///|
test "a part not in use: the focus in it let go of at that moment; Tab goes to none of it, nothing of it read out as taking the focus; pressed as ever; in use again, all of it at that moment" {
  let on = @signals.signal(true, same=fn(a, b) { a == b })
  let (t, said) = in_use_tester(on)
  t.act(Button, Focus, label="乙")
  assert_eq(t.focused().map(fn(s) { s.label }), Some("乙"))
  // (said between frames: at once, no frame drawn)
  on.set(false)
  assert_eq(view_app.val.unwrap().focused_now().0, None, msg="the focus kept in what is not in use")
  t.draw()
  t.act(Button, Focus, label="甲")
  assert_eq(in_use_round(t), [], msg="Tab went into what is not in use")
  assert_false(in_use_focusable(t, "乙"), msg="乙 read out as taking the focus")
  assert_true(in_use_read(t, "乙") && in_use_read(t, "丙"), msg="read out as before")
  // (the hand's as ever: a tap on it presses it, a finger held on its cover past a long press is handed through)
  t.tap(120.0, 20.0)
  assert_true(said.contains("乙 pressed"), msg="\{Repr(said)}")
  t.touch(0, 180.0, 20.0)
  t.draw()
  t.run_for(long_press_ms + through_later_ms)
  t.touch(2, 180.0, 20.0)
  t.draw()
  assert_true(said.contains("丙 held"), msg="\{Repr(said)}")
  // in use again: at that moment, no frame drawn
  on.set(true)
  assert_true(in_use_focusable(t, "乙"), msg="乙 may take the focus at that moment")
  t.draw()
  t.act(Button, Focus, label="甲")
  assert_eq(in_use_round(t), ["乙", "丙"])
}

///|
/// An old view the whole window, in a part in use while `in_use` holds, holding a button "旧按钮"; while `open`, a
/// modal layer of the tree's over it holding "取消", giving the focus to it as it opens, leaving over
/// layer_focus_leave_ms (layer_focus_wbtest's layer_page_tester, the part not in use in the place of its page put away).
fn in_use_layer_tester(open : @signals.Signal[Bool], in_use : @signals.Signal[Bool]) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(h) {
      h.grow(Is(1.0)).in_use(By(fn() { in_use.get() })) |> ignore
      old(h, fn(c) {
        let id = c.id("旧按钮")
        c.focusable(id)
        let b = c.box(id~, w=Px(120.0), h=Px(40.0), top=100.0, left=0.0, fn() {  })
        c.semantics(b, Button, id~, label="旧按钮", actions=[Activate])
      }).grow(Is(1.0))
      |> ignore
    })
    |> ignore
    root.show(fn() { open.get() }, fn(l) {
      l.over(Is(true)).modal(By(fn() { !l.leaving() })) |> ignore
      let no = l.box(fn(x) {
        x
        .width(Is(Some(80.0)))
        .height(Is(Some(40.0)))
        .presses(Is(true))
        .focusable(Is(true))
        .says(Is(Some(@view.said(Button, label="取消"))))
        .on_press(fn() {  })
        |> ignore
      })
      l.focus_opens(no) |> ignore
    }, leave=layer_focus_leave_ms)
  })
  t.draw()
  t
}

///|
test "a layer of the tree's opened from an old view's button with the focus, its part put out of use while it is open: closed, the focus given back to none of it; its part in use still, back on the button" {
  for behind in [false, true] {
    let open = @signals.signal(false)
    let in_use = @signals.signal(true)
    let t = in_use_layer_tester(open, in_use)
    t.act(Button, Focus, label="旧按钮")
    open.set(true)
    t.draw()
    let opened = layer_focused(t)
    // (the part put out of use as the layer stays open: 中屏's page, the sidebar brought over under a menu of its)
    if behind {
      in_use.set(false)
      t.draw()
    }
    open.set(false)
    let closed = layer_focused(t)
    t.run_for(layer_focus_leave_ms)
    let want = if behind { None } else { Some("旧按钮") }
    assert_eq((opened, closed, layer_focused(t)), (Some("取消"), want, want), msg="out of use: \{behind}")
  }
}

///|
/// A field (the tree's own where `tree_one`, else an old view's editor) in a part in use while `in_use` holds, made
/// while `mounted` does; while `open`, a modal layer of the tree's beside it holding "取消", giving the focus to it as
/// it opens. Field node or old view, 200 by 30.
fn in_use_field_tester(
  tree_one : Bool,
  f : Field,
  in_use : @signals.Signal[Bool],
  mounted? : @signals.Signal[Bool] = @signals.signal(true),
  open? : @signals.Signal[Bool] = @signals.signal(false),
) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=2)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(part) {
      part.width(Is(Some(200.0))).height(Is(Some(30.0))).in_use(By(fn() { in_use.get() })) |> ignore
      part.show(fn() { mounted.get() }, fn(h) {
        if tree_one {
          field(h, f, label="输入", max_lines=1) |> ignore
        } else {
          old(h, fn(c) { c.box(w=Px(200.0), h=Px(30.0), fn() { c.editor("e", field=f, max_lines=1, plain=true) |> ignore }) |> ignore })
          .grow(Is(1.0))
          |> ignore
        }
      })
    })
    |> ignore
    root.show(fn() { open.get() }, fn(l) {
      l.over(Is(true)).offset(Is((0.0, 100.0))).modal(By(fn() { !l.leaving() })) |> ignore
      let no = l.box(fn(x) {
        x
        .width(Is(Some(80.0)))
        .height(Is(Some(40.0)))
        .presses(Is(true))
        .focusable(Is(true))
        .says(Is(Some(@view.said(Button, label="取消"))))
        .on_press(fn() {  })
        |> ignore
      })
      l.focus_opens(no) |> ignore
    }, leave=layer_focus_leave_ms)
  })
  t.draw()
  t
}

///|
test "a field in a part not in use: Field::focus before or after its node is made gives it the focus as the part comes into use" {
  for tree_one in [false, true] {
    for before_mount in [true, false] {
      let in_use = @signals.signal(false)
      let mounted = @signals.signal(!before_mount)
      let f = Field::new()
      let t = in_use_field_tester(tree_one, f, in_use, mounted~)
      let case = "tree: \{tree_one}, before made: \{before_mount}"
      f.focus()
      if before_mount {
        mounted.set(true)
        t.draw()
      }
      assert_false(f.focused(), msg="\{case}: focused out of use")
      in_use.set(true)
      if tree_one {
        // (at that moment, no frame drawn)
        assert_true(f.focused(), msg="\{case}: not focused as its part came into use")
      }
      t.draw()
      t.type_text("hi")
      assert_eq((f.focused(), f.text()), (true, "hi"), msg=case)
    }
  }
}

///|
test "a field of the tree's in a part not in use: an action setting in_use and calling Field::focus in one event gives it the focus in that event" {
  let in_use = @signals.signal(false)
  let f = Field::new()
  let told_at : Ref[Double] = Ref(-1.0)
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=2)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.on_action("open.part", fn(_) {
      in_use.set(true)
      f.focus()
      true
    })
    |> ignore
    root.box(fn(part) {
      part.width(Is(Some(200.0))).height(Is(Some(30.0))).in_use(By(fn() { in_use.get() })) |> ignore
      let fv = field(part, f, label="输入", max_lines=1)
      field_focus_told(fv, fn(on) {
        if on {
          told_at.val = view_moment()
        }
      })
    })
    |> ignore
  })
  t.draw()
  // (the event a while after the last frame: its moment its own, not a frame's)
  t.advance(layer_focus_leave_ms)
  assert_true(view_app.val.unwrap().ask_action("open.part", t.time()))
  // (in that event, no frame drawn)
  assert_eq((f.focused(), told_at.val), (true, t.time()))
}

///|
test "a field of the tree's asked focus in a part not in use: let_go cancels the ask, and once given it is not given again after going out of use" {
  // (let go of before its part came into use: not given)
  let in_use = @signals.signal(false)
  let f = Field::new()
  let t = in_use_field_tester(true, f, in_use)
  f.focus()
  f.let_go()
  in_use.set(true)
  t.draw()
  assert_false(f.focused(), msg="given after let_go")
  // (given once: out of use and in again, not given again)
  let in_use = @signals.signal(false)
  let f = Field::new()
  let t = in_use_field_tester(true, f, in_use)
  f.focus()
  in_use.set(true)
  t.draw()
  assert_true(f.focused(), msg="not given as its part came into use")
  in_use.set(false)
  t.draw()
  assert_false(f.focused(), msg="kept out of use")
  in_use.set(true)
  t.draw()
  assert_false(f.focused(), msg="given again")
}

///|
test "a field of the tree's in a part not in use: a modal layer opening and closing elsewhere keeps its prior ask, while asking under an open modal layer is ignored" {
  // (asked before a modal layer opened and closed elsewhere: given as its part comes into use)
  let in_use = @signals.signal(false)
  let open = @signals.signal(false)
  let f = Field::new()
  let t = in_use_field_tester(true, f, in_use, open~)
  f.focus()
  open.set(true)
  t.draw()
  open.set(false)
  t.draw()
  assert_false(f.focused(), msg="focused out of use")
  in_use.set(true)
  t.draw()
  assert_true(f.focused(), msg="the ask lost to a modal layer elsewhere")
  // (asked under an open modal layer: not kept)
  let in_use = @signals.signal(false)
  let open = @signals.signal(true)
  let f = Field::new()
  let t = in_use_field_tester(true, f, in_use, open~)
  f.focus()
  in_use.set(true)
  open.set(false)
  t.draw()
  t.run_for(layer_focus_leave_ms)
  assert_false(f.focused(), msg="asked under a modal layer, given after")
}
