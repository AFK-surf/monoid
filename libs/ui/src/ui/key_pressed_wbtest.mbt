// White-box tests for package-private `Ctx::key_pressed` (moved from black-box `overlay_test.mbt`,
// `focus_test.mbt`, and `desktop_test.mbt` when `Ctx::key_pressed` became package-private).

///|
fn key_pressed_wb_btn(c : Ctx, label : String, keys? : Int = 3, w? : Size = Auto) -> Response {
  let id = c.id(label)
  let r = c.interact(id, keys~)
  let i = c.box(w~, padx=8.0, pady=4.0, id~, fn() { c.text(label, wrap=false) |> ignore })
  c.semantics(i, Button, id~, actions=[Activate])
  r
}

///|
test "an open layer the focus is in has the keys: the page under it reads none (Escape, a letter, its raw keys); the layer reads them" {
  let open = Ref(true)
  let log : Array[String] = []
  let t = Tester::new(fn(c) {
    // a page reading keys as a list's rows do (Ctx::keys) and as its shortcuts do (Ctx::key_pressed)
    for k in c.keys() {
      log.push("page key \{k.0}")
    }
    if c.key_pressed(key_escape) || c.key_pressed(key_escape, in_field=true) {
      log.push("page escape")
    }
    if open.val {
      // (as a menu opened is: the focus on its first)
      let o = c.overlay("menu", initial_focus=-1, fn() {
        if c.key_pressed(key_of_char('a')) {
          log.push("menu a")
        }
        key_pressed_wb_btn(c, "inside") |> ignore
      })
      if o.dismissed is Some(d) {
        log.push("dismissed \{d}")
        open.val = false
      }
    }
  })
  t.draw()
  t.key(key_of_char('a'))
  t.frame()
  assert_eq(log, ["menu a"])
  t.key(key_escape)
  t.frame()
  assert_eq(log, ["menu a", "dismissed Escape"])
  assert_false(open.val)
  // closed: the page's again
  t.key(key_of_char('a'))
  t.frame()
  assert_eq(log, ["menu a", "dismissed Escape", "page key \{key_of_char('a')}"])
}

///|
test "a modal layer Escape does not dismiss (a file over the window) has the keys and its own Escape; a toast over it has neither" {
  let toast = Ref(false)
  let log : Array[String] = []
  let t = Tester::new(fn(c) {
    // a page with its shortcuts: Space (a chat's 回到输入框), Escape (a panel of it closed)
    if c.key_pressed(key_space) {
      log.push("page space")
    }
    if c.key_pressed(key_escape) || c.key_pressed(key_escape, in_field=true) {
      log.push("page escape")
    }
    let o = c.overlay("over", modal=true, escape=false, outside=false, initial_focus=0, fn() {
      if c.key_pressed(key_space) {
        log.push("over space")
      }
      if c.key_pressed(key_escape) {
        log.push("over escape")
      }
    })
    if o.dismissed is Some(d) {
      log.push("dismissed \{d}")
    }
    // (as kit's toast is: no keys, not dismissed by Escape, over everything built before it)
    if toast.val {
      c.overlay("toast", escape=false, outside=false, initial_focus=0, fn() {  }) |> ignore
    }
  })
  t.draw()
  t.key(key_space)
  t.frame()
  t.key(key_escape)
  t.frame()
  assert_eq(log, ["over space", "over escape"])
  toast.val = true
  t.frame()
  t.key(key_space)
  t.frame()
  t.key(key_escape)
  t.frame()
  assert_eq(log, ["over space", "over escape", "over space", "over escape"])
}

///|
test "a list's rows in a layer are of it, built as the list is laid out: a field in one takes the focus, the keys are theirs" {
  let ask = Ref(false)
  let log : Array[String] = []
  let t = Tester::new(fn(c) {
    c.overlay("sheet", modal=true, fn() {
      c.box(h=Px(300.0), fn() {
        c.list("rows", 1, 40.0, fn(_) {
          c.editor("in-row") |> ignore
          if ask.val {
            c.focus_editor("in-row")
          }
          if c.key_pressed(key_space) {
            log.push("row space")
          }
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.key(key_space)
  assert_eq(log, ["row space"])
  ask.val = true
  t.frame()
  assert_true(t.ctx().field_focused())
}

///|
test "Enter and Space press what has the focus, as it says; the key is taken from the view" {
  let log : Array[String] = []
  let seen_enter = Ref(0)
  let t = Tester::new(fn(c) {
    if c.key_pressed(key_code_enter) {
      seen_enter.val = seen_enter.val + 1
    }
    c.column(fn() {
      if key_pressed_wb_btn(c, "both").clicked {
        log.push("both")
      }
      if key_pressed_wb_btn(c, "space only", keys=press_space).clicked {
        log.push("space only")
      }
    })
    |> ignore
  })
  t.tab()
  t.press("Enter")
  t.press("Space")
  assert_eq(log, ["both", "both"])
  assert_eq(seen_enter.val, 0)
  t.tab()
  t.press("Enter")
  assert_eq(log, ["both", "both"])
  // not taken by it: the view sees it
  assert_eq(seen_enter.val, 1)
  t.press("Space")
  assert_eq(log, ["both", "both", "space only"])
}

///|
test "desktop: keys with the command key are shortcuts; Escape reaches the app with a field focused" {
  let seen : Array[String] = []
  let t = Tester::new(
    fn(c) {
      if c.shortcut('k') {
        seen.push("cmd-k")
      }
      if c.key_pressed(key_escape) {
        seen.push("esc")
      }
      if c.key_pressed(key_code_enter) {
        seen.push("enter")
      }
      c.editor("field", placeholder="words") |> ignore
    },
    w=400.0,
    h=300.0,
    platform=0,
  )
  t.key(key_of_char('k'), mods=mod_cmd)
  // Ctrl+K is not macOS's shortcut
  t.key(key_of_char('k'), mods=mod_ctrl)
  let (fx, fy) = t.find("words").unwrap()
  t.tap(fx, fy)
  t.key(key_escape)
  // the field's Enter is the field's
  t.key(key_code_enter)
  assert_eq(seen, ["cmd-k", "esc"])
}

///|
test "desktop: a script hovers, right clicks, presses keys and resizes the window" {
  let seen : Array[String] = []
  let t = Tester::new(
    fn(c) {
      let row = c.id("row")
      c.takes_presses(row)
      if c.right_clicked(row) is Some(_) {
        seen.push("menu")
      }
      if c.shortcut('k') {
        seen.push("cmd-k")
      }
      if c.key_pressed(key_code_down, mods=mod_alt) {
        seen.push("alt-down")
      }
      seen.push("w \{c.width.to_int()}")
      c.box(id=row, fn() { c.text("a row", wrap=false) |> ignore }) |> ignore
    },
    w=400.0,
    h=300.0,
    platform=0,
  )
  seen.clear()
  let logs = t.drive("hover a row\nrightclick a row\nkey cmd+k\nkey alt+down\nresize 900 700\nwait 50\nexit")
  assert_true(logs.iter().any(fn(l) { l.contains("DRIVE PASS") }))
  assert_eq(t.cursor(), Hand)
  assert_true(seen.contains("menu"))
  assert_true(seen.contains("cmd-k"))
  assert_true(seen.contains("alt-down"))
  assert_true(seen.contains("w 900"))
}

///|
test "a field leaving keys to the app: ↑ keeps its caret, Enter sends nothing; the app still reads them" {
  let f = Field::new(text="one\ntwo")
  let leaves : Ref[Array[Int]] = Ref([])
  let up = Ref(false)
  let enter = Ref(false)
  let sent : Ref[String?] = Ref(None)
  let t = Tester::new(fn(c) {
    let r = c.editor("e", field=f, leaves=leaves.val)
    if r.submitted is Some(_) {
      sent.val = r.submitted
    }
    if c.key_pressed(key_code_up, in_field=true) {
      up.val = true
    }
    if c.key_pressed(key_code_enter, in_field=true) {
      enter.val = true
    }
  })
  t.draw()
  t.tap(100.0, 20.0)
  f.set("one\ntwo", caret=7)
  leaves.val = [key_code_up, key_code_down, key_code_enter]
  t.draw()
  t.key(key_code_up)
  assert_eq(f.selection(), (7, 7))
  assert_true(up.val)
  t.key(key_code_enter)
  assert_true(enter.val)
  assert_eq(sent.val, None)
  assert_eq(f.text(), "one\ntwo")
  // Tab too: the focus stays in the field
  leaves.val = [key_tab]
  t.draw()
  t.key(key_tab)
  assert_true(t.ctx().editor_focused("e"))
  // given back: ↑ goes up a line
  leaves.val = []
  t.draw()
  t.key(key_code_up)
  assert_true(f.selection().1 < 4)
}
